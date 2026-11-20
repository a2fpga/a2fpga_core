/*
 * usbc_glue — board glue between the vendored USB-C PD stack (usbc_port.c /
 * fusb302.c, from DisplayPort_Verilog usb-c/) and the a2mega 1.0a3 hardware.
 *
 * The vendored esp32s3_integration.c skeleton assumes a GPIO-mode TUSB1046A;
 * the 1.0a3 board straps the mux into I2C mode (I2C_EN pulled up, CTL/HPD
 * pins NC), so this file provides its own usbc_port_hal_t instead:
 *
 *   - FUSB302B (0x22) + TUSB1046A (0x12) share one I2C bus (Wire on
 *     IO1=SCL / IO2=SDA).
 *   - DP enable = TUSB1046A General reg 0x0A: CTLSEL[1:0]=10 (four-lane DP)
 *     | FLIPSEL per orientation | HPDIN_OVRRIDE (pin 23 is NC). Disable =
 *     CTLSEL=01. RX EQ stays at defaults; AUX snooping (on by default)
 *     trims active lanes to whatever the FPGA trains. (usb-c/SPEC.md §6.)
 *   - HPD to the FPGA is a real wire (PIN_DP_HPD_OUT -> gateware
 *     hotplug_decode): level driven directly, IRQ = 0.75 ms low pulse
 *     generated here (SPEC.md §8; 0.5-1.0 ms window).
 *   - VBUS sourcing = TPS2553 EN on PIN_VBUS_SRC_EN (1 A limit in hardware).
 *
 * a2p25 (BOARD_REV 225): same model with a TUSB546A-DCI (register- and
 * pin-compatible sibling of the TUSB1046A; same General/DPEQ/DPCTL3 map)
 * and an SN75DP130 redriver (sn75dp130.c) on the same bus. The mux
 * address is probed at boot (0x12 expected, 0x10-0x17 scanned as a
 * fallback). HPD to the FPGA is a wire only in dp_test mode (IO10 ->
 * ball B2); with PIN_DP_HPD_OUT < 0 the level is just recorded.
 *
 * The PD policy task runs at 1 kHz and is woken immediately by the FUSB302B
 * INT_N falling edge, per the usbc_port_task() contract.
 */
#include "board_pins.h"

#if A2MEGA_HAS_USBC_PD

#include <Arduino.h>
#include <Wire.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_heap_caps.h"

extern "C" {
#include "usbc_port.h"
#include "osd_console.h"
}
#include "usbc_glue.h"
#include "fpga_link.h"   /* census second gate: DPCD caps regs 0x3C/0x3D */

#define TUSB1046_I2C_ADDR_DEFAULT 0x12
/* Mux address actually in use: 0x12 unless the boot probe finds the mux
 * elsewhere in 0x10-0x17 (TUSB546A A0/A1 strap table unverified locally). */
static uint8_t s_tusb_addr = TUSB1046_I2C_ADDR_DEFAULT;
#define TUSB1046_I2C_ADDR   s_tusb_addr
#define TUSB1046_REG_GENERAL 0x0A
#define TUSB_GEN_CTLSEL_USB3 0x01   /* DP lanes off (as-built disable state) */
#define TUSB_GEN_CTLSEL_DP4  0x02   /* four-lane DP, pin assignment C/E */
#define TUSB_GEN_FLIPSEL     0x04
#define TUSB_GEN_HPDIN_OVR   0x08   /* ignore the (NC) HPDIN pin */
#define TUSB_GEN_EQ_OVERRIDE 0x10   /* EQ from registers, not strap pins */
#define TUSB1046_REG_DPEQ10  0x10   /* DP1EQ_SEL[7:4] | DP0EQ_SEL[3:0] */
#define TUSB1046_REG_DPEQ32  0x11   /* DP3EQ_SEL[7:4] | DP2EQ_SEL[3:0] */
#define TUSB1046_REG_DPCTL3  0x13   /* AUX_SNOOP_DISABLE | AUX_SBU_OVR | DPx_DISABLE */
#define TUSB_DP_SNOOP_DIS    0x80   /* lanes governed by DPx_DISABLE (all default-enabled) */
/* DS Table 15: reg 0x13 bits [3:0] = DP3..DP0_DISABLE, honored only when
 * AUX_SNOOP_DISABLE=1 (our permanent policy). The FPGA drives mux inputs
 * DP0/DP1 only (both orientations — FLIPSEL does connector mapping), so
 * DP2+DP3 are pure bias load: 634 mW assumes all four channels lit.
 * M1 experiment (exercise plan): disable the unused pair, measure mux
 * temperature + warm-attach margin. Live-toggleable (telnet 'l') for
 * one-variable A/B. */
#define TUSB_DP23_DISABLE    0x0C

/* DP receiver EQ. CRITICAL (board #1 root-cause candidate, 2026-08-12):
 * in I2C mode the DPEQ strap pins double as address pins and float, so
 * the chip latches EQ setting 10 = 12.3 dB at reset (datasheet Table 7,
 * F/F row) — ~11 dB of over-equalization for a few-cm board trace,
 * enough to wreck the redriven eye at 2.7 Gb/s. EQ_OVERRIDE + low
 * register EQ is mandatory in I2C mode; SPEC.md always said EQ is
 * "register-settable instead of strap resistors". Setting 0 = 1.0 dB. */
static uint8_t s_dp_eq_setting = 0;

/* M1: unused-mux-lane disable state (default OFF = stock all-four-lit
 * behavior; toggle live via telnet 'l' for thermal/margin A/B). */
static bool s_lanes23_off = false;
static uint8_t s_dpctl3_last = 0;

static usbc_port_t s_port;
static SemaphoreHandle_t s_wake;
static bool s_running;

/* Status mirrors for the CLI / telnet 'pd' command. */
static volatile bool s_hpd_level;
static volatile bool s_vbus_on;
static volatile bool s_dp_mux_on;
static volatile bool s_fpga_dp_en;

/* ---- I2C (shared bus: FUSB302B + TUSB1046A) ------------------------------
 * Bus mutex: the 1 kHz PD task, the CLI (loop task), and the telnet task
 * (mux dumps / EQ cycling) all touch Wire — unlocked access produced
 * intermittent read failures (the 'x' dump's 0xEE noise). */

static SemaphoreHandle_t s_i2c_lock;

static void i2c_lock(void)
{
    if (s_i2c_lock)
        xSemaphoreTake(s_i2c_lock, portMAX_DELAY);
}

static void i2c_unlock(void)
{
    if (s_i2c_lock)
        xSemaphoreGive(s_i2c_lock);
}

static int i2c_read(void *ctx, uint8_t address, uint8_t reg,
                    uint8_t *data, size_t length)
{
    (void)ctx;
    i2c_lock();
    Wire.beginTransmission(address);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0) {
        i2c_unlock();
        return -1;
    }
    size_t got = Wire.requestFrom(address, (uint8_t)length);
    if (got != length) {
        i2c_unlock();
        return -1;
    }
    for (size_t i = 0; i < length; i++)
        data[i] = (uint8_t)Wire.read();
    i2c_unlock();
    return 0;
}

static int i2c_write(void *ctx, uint8_t address, uint8_t reg,
                     const uint8_t *data, size_t length)
{
    (void)ctx;
    i2c_lock();
    Wire.beginTransmission(address);
    Wire.write(reg);
    for (size_t i = 0; i < length; i++)
        Wire.write(data[i]);
    int rc = Wire.endTransmission(true) == 0 ? 0 : -1;
    i2c_unlock();
    return rc;
}

static void io_delay_us(void *ctx, uint32_t us)
{
    (void)ctx;
    delayMicroseconds(us);
}

/* Shared-bus access for other drivers (sn75dp130.c) and the CLI: same
 * mutex as the PD task. Valid once usbc_pd_init() has run Wire.begin. */
extern "C" int usbc_i2c_read(uint8_t address, uint8_t reg, uint8_t *data,
                             size_t length)
{
    return i2c_read(NULL, address, reg, data, length);
}

extern "C" int usbc_i2c_write(uint8_t address, uint8_t reg,
                              const uint8_t *data, size_t length)
{
    return i2c_write(NULL, address, reg, data, length);
}

/* Address-only probe (START, addr+W, STOP): true on ACK. */
extern "C" bool usbc_i2c_probe(uint8_t address)
{
    i2c_lock();
    Wire.beginTransmission(address);
    bool ack = Wire.endTransmission(true) == 0;
    i2c_unlock();
    return ack;
}

/* Scan 0x08-0x77 and report responders via osd_log (OSD + telnet tee) and
 * Serial. Expected on a2p25: 0x12 TUSB546A, 0x22 FUSB302B, 0x2C DP130. */
extern "C" void usbc_i2c_scan_log(void)
{
    char line[41];
    int n = snprintf(line, sizeof line, "I2C:");
    int found = 0;
    for (uint8_t a = 0x08; a < 0x78; a++) {
        if (!usbc_i2c_probe(a))
            continue;
        found++;
        if (n > (int)sizeof line - 4) {
            osd_log("%s", line);
            Serial.println(line);
            n = snprintf(line, sizeof line, "I2C:");
        }
        n += snprintf(line + n, sizeof line - n, " %02X", a);
    }
    if (found == 0)
        n += snprintf(line + n, sizeof line - n, " NO DEVICES");
    osd_log("%s", line);
    Serial.println(line);
}

/* Find the mux: 0x12 first, then the rest of 0x10-0x17 (skipping nothing
 * else lives there on either board). Returns true if one answered. */
static bool tusb_detect_addr(void)
{
    if (usbc_i2c_probe(TUSB1046_I2C_ADDR_DEFAULT)) {
        s_tusb_addr = TUSB1046_I2C_ADDR_DEFAULT;
        return true;
    }
    for (uint8_t a = 0x10; a <= 0x17; a++) {
        if (a != TUSB1046_I2C_ADDR_DEFAULT && usbc_i2c_probe(a)) {
            s_tusb_addr = a;
            Serial.printf("[usbc] DP mux found at 0x%02X (not 0x12)\n", a);
            osd_log("USBC: DP MUX AT 0x%02X (NOT 0x12)", a);
            return true;
        }
    }
    return false;
}

/* HPD wire to the FPGA (absent when PIN_DP_HPD_OUT < 0). LED1 mirrors it
 * on boards that have one. */
static void hpd_pin_write(bool level)
{
#if PIN_DP_HPD_OUT >= 0
    digitalWrite(PIN_DP_HPD_OUT, level ? HIGH : LOW);
#endif
#if PIN_LED1 >= 0
    digitalWrite(PIN_LED1, level ? HIGH : LOW);
#endif
    (void)level;
}

static uint8_t s_general_last = 0;   /* last value written to reg 0x0A */
static bool    s_flip_invert = false; /* live A/B: invert FLIPSEL convention */

static int tusb_write_general(uint8_t v)
{
    s_general_last = v;
    return i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_GENERAL, &v, 1);
}

/* ---- HAL callbacks ------------------------------------------------------- */

static uint32_t hal_millis(void *ctx)
{
    (void)ctx;
    return (uint32_t)millis();
}

static void hal_set_vbus(void *ctx, bool enable)
{
    (void)ctx;
    /* a2mega 1.0a3: strapping pin IO46 held low by R29 at reset;
     * a2p25: IO6 with R46 pull-down. Only ever driven here. */
    digitalWrite(PIN_VBUS_SRC_EN, enable ? HIGH : LOW);
    s_vbus_on = enable;
}

static void hal_set_usb_role(void *ctx, usbc_usb_role_t role)
{
    (void)ctx;
    /* The ESP32-S3's own USB (IO19/20, hardwired to the connector) is the
     * flashing/console CDC device; there is no role switch to perform on
     * this board. Recorded for visibility only. */
    Serial.printf("[usbc] usb role -> %s\n",
                  role == USBC_USB_ROLE_HOST ? "host" :
                  role == USBC_USB_ROLE_DEVICE ? "device" : "off");
}

static int tusb_write_dp_eq(uint8_t setting)
{
    uint8_t v = (uint8_t)((setting << 4) | (setting & 0x0F));
    int rc = i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_DPEQ10, &v, 1);
    rc |= i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_DPEQ32, &v, 1);
    return rc;
}

static void hal_set_tusb1046(void *ctx, bool dp_enable, bool flipped)
{
    (void)ctx;
    uint8_t v;
    if (dp_enable) {
        /* s_flip_invert: live A/B of the CC-orientation -> FLIPSEL
         * convention (telnet 'f'); needed up here for AUX_SBU_OVR too. */
        bool flip_eff = flipped ^ s_flip_invert;
        /* Program sane EQ BEFORE enabling the lanes (see s_dp_eq_setting
         * comment: floating straps latch a link-killing 12.3 dB). */
        if (tusb_write_dp_eq(s_dp_eq_setting) != 0)
            Serial.println("[usbc] TUSB1046A EQ reg write FAILED");
        /* POLICY (2026-08-13, permanent): AUX snooping stays DISABLED.
         * We own the link state machine; the snooper is a second, silent
         * state machine inferring lane state from AUX traffic, and it
         * bit us three ways: reg 0x12 resets per attach so a missed
         * LANE_COUNT_SET write leaves lanes muted; the D0 write was
         * never snooped at all; and AUX-less diagnostic bitstreams
         * (TX_PROBE) transmit into a muted mux forever. Its only benefit
         * is power savings — irrelevant on a slot-powered card. If lane
         * trimming is ever wanted, drive DPx_DISABLE explicitly from
         * known link state instead. With snoop disabled, DPx_DISABLE
         * governs and defaults to all-enabled.
         *
         * ALSO force the AUX<->SBU crossbar closed (AUX_SBU_OVR, Table 6:
         * override "regardless of CTLSEL1 and FLIPSEL"). Found 2026-08-13:
         * with the automatic mapping the SBU pins idled at ~0.5 V on BOTH
         * lines (AUXN's 100k-to-3V3 bias never crossed the chip) — the
         * switch was effectively open, our AUX bursts reached the monitor
         * only capacitively, and the sink never replied to ANY request.
         * 01 = AUXp->SBU1/AUXn->SBU2 (normal), 10 = crossed (flipped). */
        /* AUX crossing follows the DETECTED orientation only: it is proven
         * correct in both orientations (a2p25 bench 10-10). s_flip_invert
         * is a lane-only A/B — the SS-lane crosspoint is what never worked
         * reliably in one orientation on either TUSB (1046A or 546A). */
        uint8_t dc = TUSB_DP_SNOOP_DIS | (flipped ? 0x20 : 0x10) |
                     (s_lanes23_off ? TUSB_DP23_DISABLE : 0);
        s_dpctl3_last = dc;
        if (i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_DPCTL3, &dc, 1) != 0)
            Serial.println("[usbc] TUSB1046A snoop-disable/aux-ovr write FAILED");
        /* FLIPSEL steers BOTH the SBU/AUX crossbar and the SS-lane
         * crosspoint (flip_eff computed at the top of this branch). */
        v = TUSB_GEN_CTLSEL_DP4 | TUSB_GEN_HPDIN_OVR | TUSB_GEN_EQ_OVERRIDE |
            (flip_eff ? TUSB_GEN_FLIPSEL : 0);
    } else {
        v = TUSB_GEN_CTLSEL_USB3 | TUSB_GEN_HPDIN_OVR;
    }
    if (tusb_write_general(v) != 0)
        Serial.println("[usbc] TUSB1046A general reg write FAILED");
    s_dp_mux_on = dp_enable;
}

static void hal_set_tusb_hpd(void *ctx, bool level)
{
    (void)ctx;
    (void)level;
    /* I2C mode: pin 23 is NC and HPDIN_OVRRIDE is set — the mux never sees
     * HPD; lane trimming rides the AUX snooper. Nothing to do. */
}

static void hal_set_fpga_dp_enable(void *ctx, bool enable)
{
    (void)ctx;
    /* Gateware-side DP gating hook (SPEC.md §9: hold the DP source in
     * reset until DP Configure is ACKed). The bring-up gateware keys off
     * HPD alone; when a gate is added it will be an OSPI register write
     * here. Recorded for the status command meanwhile. */
    s_fpga_dp_en = enable;
}

static void hal_set_fpga_hpd(void *ctx, bool level)
{
    (void)ctx;
    hpd_pin_write(level);
    s_hpd_level = level;
}

/* Telnet 'r': drop HPD to the FPGA for ~250 ms and restore — restarts
 * the gateware's blind AUX/training ladder on demand (BLIND_SINK resets
 * on hpd_present falling). No cables touched, nothing power-cycles. */
/* Telnet 'v': virtual replug — full detach illusion (CC open + VBUS off
 * + DP down) for 3 s, then a from-scratch attach ceremony. The
 * renegotiation-inclusive re-roll the 'g' harness can't provide on
 * strict sinks (row 42). */
extern "C" void usbc_virtual_replug(void)
{
    osd_log("VIRTUAL REPLUG: detaching 3 s (CC open)");
    if (usbc_port_virtual_replug(&s_port, 3000u) != 0)
        osd_log("VIRTUAL REPLUG: port not running");
}

/* Auto-recovery variant (wedge_watch): 1.5 s hold — ample past
 * tCCDebounce for the hub to register a true detach, and half the
 * manual 'v' latency (recovery-time trim, ed 08-26). The manual path
 * keeps its field-proven 3 s. */
extern "C" void usbc_virtual_replug_fast(void)
{
    osd_log("VIRTUAL REPLUG (auto): detaching 1.5 s (CC open)");
    if (usbc_port_virtual_replug(&s_port, 1500u) != 0)
        osd_log("VIRTUAL REPLUG: port not running");
}

extern "C" void usbc_hpd_retrain(void)
{
    if (!s_hpd_level) {
        osd_log("RETRAIN: HPD is low (no sink) - nothing to pulse");
        return;
    }
#if PIN_DP_HPD_OUT < 0
    osd_log("RETRAIN: no HPD wire on this build");
    return;
#endif
    osd_log("RETRAIN: pulsing HPD low 250 ms (ladder restart)");
    hpd_pin_write(false);
    vTaskDelay(pdMS_TO_TICKS(250));
    hpd_pin_write(true);
}

/* Telnet 't': PD event trace (TX/RX/IRQ/state ring) — the PD-silent dig. */
extern "C" void usbc_trace_dump_log(void)
{
    if (!s_running) { osd_log("trace: PD STACK NOT RUNNING"); return; }
    usbc_port_trace_dump(&s_port);
}

/* Telnet 'u': raw FUSB302B status snapshot for in-slot attach debugging. */
extern "C" void usbc_fusb_dump_log(void)
{
    static const uint8_t regs[] = {0x08, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42};
    char line[80];
    char *w = line;
    w += snprintf(w, sizeof line, "FUSB");
    for (size_t i = 0; i < sizeof regs; i++) {
        uint8_t v = 0xEE;
        (void)i2c_read(NULL, 0x22, regs[i], &v, 1);
        w += snprintf(w, sizeof line - (w - line), " %02X:%02X", regs[i], v);
    }
    osd_log(line);
}

static void hal_pulse_fpga_hpd_irq(void *ctx)
{
    (void)ctx;
    /* IRQ_HPD = 0.5-1.0 ms low pulse while HPD is otherwise high
     * (hotplug_decode's IRQ threshold is 0.5 ms, disconnect is 2 ms). */
    if (!s_hpd_level)
        return;
    hpd_pin_write(false);
    delayMicroseconds(750);
    hpd_pin_write(true);
}

static void hal_log(void *ctx, usbc_log_level_t level, const char *message)
{
    (void)ctx;
    Serial.printf("[usbc] %s\n", message);
    if (level >= USBC_LOG_WARNING)
        osd_log("USBC: %s", message);
}

/* ---- task + interrupt ---------------------------------------------------- */

static void IRAM_ATTR fusb_int_isr(void)
{
    BaseType_t woke = pdFALSE;
    if (s_wake)
        xSemaphoreGiveFromISR(s_wake, &woke);
    if (woke)
        portYIELD_FROM_ISR();
}

static void usbc_task(void *arg)
{
    (void)arg;
    for (;;) {
        /* 1 ms cadence, woken early by INT_N falling. */
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(1));
        usbc_port_task(&s_port);
    }
}

/* ---- public -------------------------------------------------------------- */

extern "C" bool usbc_pd_init(void)
{
    if (s_running)
        return true;

    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 400000);
    /* Bus mutex before ANY traffic: other drivers (DP130) and the CLI
     * share the bus even if the PD PHY turns out to be missing. */
    if (!s_i2c_lock)
        s_i2c_lock = xSemaphoreCreateMutex();

    /* Park the mux in its documented disable state (DP lanes off, HPDIN
     * ignored) before PD policy starts. A NAK here usually means the board
     * is unpowered on the 3.3 V rail or the mux is missing. */
    if (!tusb_detect_addr())
        Serial.println("[usbc] warning: DP mux not found at 0x10-0x17");
    if (tusb_write_general(TUSB_GEN_CTLSEL_USB3 | TUSB_GEN_HPDIN_OVR) != 0)
        Serial.printf("[usbc] warning: DP mux (0x%02X) not responding\n",
                      s_tusb_addr);

    fusb302_io_t io = {};
    io.context = NULL;
    io.read = i2c_read;
    io.write = i2c_write;
    io.delay_us = io_delay_us;

    usbc_port_hal_t hal = {};
    hal.context = NULL;
    hal.millis = hal_millis;
    hal.set_vbus_source = hal_set_vbus;
    hal.set_usb_role = hal_set_usb_role;
    hal.set_tusb1046 = hal_set_tusb1046;
    hal.set_tusb_hpd = hal_set_tusb_hpd;
    hal.set_fpga_dp_enable = hal_set_fpga_dp_enable;
    hal.set_fpga_hpd = hal_set_fpga_hpd;
    hal.pulse_fpga_hpd_irq = hal_pulse_fpga_hpd_irq;
    hal.log = hal_log;

    usbc_port_config_t config;
    usbc_port_default_config(&config);   /* 5 V / 1 A single PDO */

    if (usbc_port_init(&s_port, &config, &hal, &io,
                       FUSB302_I2C_ADDRESS_DEFAULT) != 0) {
        Serial.println("[usbc] FUSB302B (0x22) init FAILED");
        osd_log("USBC: PD PHY NOT FOUND");
        return false;
    }
    if (usbc_port_enable(&s_port) != 0) {
        Serial.println("[usbc] port enable FAILED");
        return false;
    }

    s_wake = xSemaphoreCreateBinary();
    attachInterrupt(digitalPinToInterrupt(PIN_FUSB_INT), fusb_int_isr, FALLING);
    /* I2C + GPIO only, never ESP flash -> stack in PSRAM (heap diet 11-19) */
    if (xTaskCreatePinnedToCoreWithCaps(usbc_task, "usbc_pd", 4096, NULL, 6, NULL, 1,
                                        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) != pdPASS)
        xTaskCreatePinnedToCore(usbc_task, "usbc_pd", 4096, NULL, 6, NULL, 1);
    s_running = true;
    osd_log("USBC: PD STACK UP");
    return true;
}

extern "C" void usbc_pd_status(void)
{
    if (!s_running) {
        Serial.println("pd: stack not running");
        return;
    }
    Serial.printf("pd: state %s (%s power role, %s data role)\n",
                  usbc_port_state_name(s_port.state),
                  s_port.power_sink ? "sink" : "source",
                  s_port.data_dfp ? "DFP" : "UFP");
    Serial.printf("    orientation CC%d, HPD %d, VBUS-src %d, mux-DP %d, "
                  "fpga-dp-en %d\n",
                  s_port.polarity == FUSB302_POLARITY_CC2 ? 2 : 1,
                  (int)s_hpd_level, (int)s_vbus_on, (int)s_dp_mux_on,
                  (int)s_fpga_dp_en);    Serial.printf("    DP mux I2C 0x%02X, HPD wire %s\n", s_tusb_addr,
                  PIN_DP_HPD_OUT >= 0 ? "yes" : "none (register path)");
}

/* TUSB1046A register dump via osd_log (OSD + telnet tee). The DCI AUX
 * snooper sits directly on the AUX pair and parses our DPCD writes
 * (LANE_COUNT_SET, SET_POWER_STATE) to auto-trim lanes — its registers
 * are on-the-wire evidence of whether the FPGA's AUX transmissions are
 * well-formed, which nothing else on this board can observe. */
extern "C" void usbc_mux_dump_log(void)
{
    uint8_t v[8];
    char line[41];
    int n = 0;
    for (uint8_t r = 0x08; r <= 0x0B; r++)
        if (i2c_read(NULL, TUSB1046_I2C_ADDR, r, &v[n], 1) != 0)
            v[n] = 0xEE, n++;
        else
            n++;
    snprintf(line, sizeof(line), "MUX 08-0B: %02X %02X %02X %02X",
             v[0], v[1], v[2], v[3]);
    osd_log("%s", line);
    n = 0;
    for (uint8_t r = 0x10; r <= 0x13; r++)
        if (i2c_read(NULL, TUSB1046_I2C_ADDR, r, &v[n], 1) != 0)
            v[n] = 0xEE, n++;
        else
            n++;
    snprintf(line, sizeof(line), "MUX 10-13: %02X %02X %02X %02X",
             v[0], v[1], v[2], v[3]);
    osd_log("%s", line);
}

/* Cycle the DP receiver EQ through bring-up presets, live over telnet.
 * Table 7 gains at 4.05 GHz: 0=1.0 dB, 3=6.5 dB, 6=9.5 dB, 10=12.3 dB
 * (10 = the floating-strap default that motivated all of this). Writes
 * take effect immediately on the running link — A/B without reflashing. */
/* Full 16-step ladder, gains at 4.05 GHz (SLLA404 Table 1). The 'e'
 * cycle only visits 4 of these; '+'/'-' step through all 16 — the mux
 * has 12 settings (incl. a 14.4 dB top) the presets never reach. */
static const char *eq_gain_db[16] = {
    "1.0", "3.3", "4.9", "6.5", "7.5", "8.6", "9.5", "10.4",
    "11.1", "11.7", "12.3", "12.8", "13.2", "13.6", "14.0", "14.4" };

extern "C" void usbc_mux_eq_cycle(void)
{
    static const uint8_t presets[4] = { 0, 3, 6, 10 };
    static uint8_t idx = 0;
    idx = (uint8_t)((idx + 1) & 3);
    s_dp_eq_setting = presets[idx];
    if (tusb_write_dp_eq(s_dp_eq_setting) == 0)
        osd_log("MUX EQ: SETTING %u (%s DB)", s_dp_eq_setting,
                eq_gain_db[s_dp_eq_setting]);
    else
        osd_log("MUX EQ: WRITE FAILED");
}

/* Fine EQ step (telnet '+'/'-'), clamped at the ladder ends. Writes take
 * effect immediately on the running link, same as the preset cycle. */
extern "C" void usbc_mux_eq_step(int dir)
{
    int next = (int)s_dp_eq_setting + dir;
    if (next < 0 || next > 15) {
        osd_log("MUX EQ: AT LADDER END (SETTING %u, %s DB)",
                s_dp_eq_setting, eq_gain_db[s_dp_eq_setting]);
        return;
    }
    s_dp_eq_setting = (uint8_t)next;
    if (tusb_write_dp_eq(s_dp_eq_setting) == 0)
        osd_log("MUX EQ: SETTING %u (%s DB)", s_dp_eq_setting,
                eq_gain_db[s_dp_eq_setting]);
    else
        osd_log("MUX EQ: WRITE FAILED");
}

/* Toggle the main-lane FLIPSEL convention live (telnet 'f', serial
 * 'muxflip') and rewrite the mux General register in place. AUX crossing is
 * NOT affected (AUX_SBU_OVR in DPCTL3 follows the detected orientation), and
 * the inversion persists across attaches until toggled back or reboot. */
/* M1: live-toggle the unused mux DP inputs (DP2/DP3) for the thermal /
 * warm-attach A/B. Rewrites DPCTL3 in place on the running link — the
 * used pair (DP0/DP1) is untouched, so video must survive; if it dies,
 * the driven-input assumption was wrong and this instantly shows it. */
extern "C" void usbc_mux_lanes23_toggle(void)
{
    s_lanes23_off = !s_lanes23_off;
    uint8_t dc = (uint8_t)((s_dpctl3_last & (uint8_t)~TUSB_DP23_DISABLE) |
                           (s_lanes23_off ? TUSB_DP23_DISABLE : 0));
    if (i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_DPCTL3, &dc, 1) == 0) {
        s_dpctl3_last = dc;
        osd_log("MUX LANES 2/3: %s (DPCTL3=%02X)",
                s_lanes23_off ? "DISABLED" : "ENABLED", dc);
    } else
        osd_log("MUX LANES 2/3: WRITE FAILED");
}

/* Serial-console twin of usbc_mux_dump_log (a2p25 bring-up: no WiFi /
 * telnet needed). Prints the General and DP EQ/control registers plus the
 * live FLIPSEL convention. */
extern "C" void usbc_mux_dump_serial(void)
{
    uint8_t v;
    Serial.printf("mux @0x%02X  flip_invert=%d\n", TUSB1046_I2C_ADDR, (int)s_flip_invert);
    for (uint8_t r = 0x08; r <= 0x13; r++) {
        if (r > 0x0B && r < 0x10) continue;
        if (i2c_read(NULL, TUSB1046_I2C_ADDR, r, &v, 1) != 0)
            Serial.printf("  %02X: --\n", r);
        else
            Serial.printf("  %02X: %02X\n", r, v);
    }
}

extern "C" void usbc_mux_flip_toggle(void)
{
    s_flip_invert = !s_flip_invert;
    uint8_t v = (uint8_t)(s_general_last ^ TUSB_GEN_FLIPSEL);
    if (i2c_write(NULL, TUSB1046_I2C_ADDR, TUSB1046_REG_GENERAL, &v, 1) == 0) {
        s_general_last = v;
        osd_log("MUX FLIPSEL NOW %d (INVERT %d)",
                (v & TUSB_GEN_FLIPSEL) ? 1 : 0, (int)s_flip_invert);
    } else {
        osd_log("MUX FLIP: WRITE FAILED");
    }
}

/* Condensed PD status through osd_log: reaches the OSD *and* every telnet
 * console session (the tee) — the only live status path once a monitor
 * occupies the USB-C port. Lines fit the 40-col console. */
extern "C" void usbc_pd_status_log(void)
{
    if (!s_running) {
        osd_log("PD: STACK NOT RUNNING");
        return;
    }
    osd_log("PD: %s %s/%s", usbc_port_state_name(s_port.state),
            s_port.power_sink ? "SNK" : "SRC",
            s_port.data_dfp ? "DFP" : "UFP");
    osd_log("PD: CC%d HPD=%d SRC=%d MUX=%d EN=%d",
            s_port.polarity == FUSB302_POLARITY_CC2 ? 2 : 1,
            (int)s_hpd_level, (int)s_vbus_on, (int)s_dp_mux_on,
            (int)s_fpga_dp_en);
}

/* Census second gate: the DP sink/converter chip's OWN DPCD capabilities
 * (MAX_LINK_RATE / MAX_LANE_COUNT), invisible to the PD layer. The gateware
 * AUX engine reads DPCD 0x000-0x00B at every attach and latches bytes
 * 0x001/0x002 verbatim into regs 0x3C/0x3D (0x00 = no DPCD read completed
 * this HPD session — cleared on unplug, so unlike the PD-mode stash this
 * does NOT survive detach: dump while the adapter is plugged). */
static void census_log_sink_caps(void)
{
    if (!fpga_link_ok()) {
        /* dp_test (colorbars) bitstreams have no OSPI connector: the same
         * bytes stream on telemetry line D6 as 'O:rrll' instead. */
        osd_log("  sink caps: no OSPI link (dp_test bin? read D6 O:rrll)");
        return;
    }
    uint8_t rate  = fpga_reg_read(A2REG_DBG_DP_RATE);
    uint8_t lanes = fpga_reg_read(A2REG_DBG_DP_LANES);
    if (rate == 0u && lanes == 0u) {
        osd_log("  sink caps: no DPCD read this session (attach + wait for AUX)");
        return;
    }
    const char *rname = rate == 0x06u ? "RBR"
                      : rate == 0x0Au ? "HBR"
                      : rate == 0x14u ? "HBR2"
                      : rate == 0x1Eu ? "HBR3" : "rate?";
    osd_log("  sink caps: %sx%u%s (dpcd 01=%02x 02=%02x)",
            rname, (unsigned)(lanes & 0x0Fu),
            (lanes & 0x80u) ? " +ef" : "", rate, lanes);
}

/* Adapter lane census (telnet 'd'): decode the DP mode VDOs from the last
 * Discover Modes ACK. Data survives detach on purpose — plug the adapter,
 * unplug it, dump at leisure. Verdict semantics are the a2p25 RBR x4 plan's:
 * pin assignment C/E means the mux path carries 4 lanes (1080p60 from an
 * RBR-only source works); D/F means 2 lanes + USB3 (720p60 fallback). This
 * covers the PD/MUX gate; the second gate — the DP sink/converter's own
 * DPCD MAX_LANE_COUNT/MAX_LINK_RATE — is reported by the sink-caps line
 * below, captured FPGA-side by the AUX engine (regs 0x3C/0x3D). */
extern "C" void usbc_modes_census_log(void)
{
    if (!s_running) {
        osd_log("census: PD STACK NOT RUNNING");
        return;
    }
    if (s_port.dp_modes_count == 0u) {
        osd_log("census: no Discover Modes seen yet");
        osd_log("census: attach a DP alt-mode partner");
        census_log_sink_caps();
        return;
    }
    osd_log("census: %u DP mode(s), last partner:", s_port.dp_modes_count);
    for (uint8_t i = 0u; i < s_port.dp_modes_count; ++i) {
        const uint32_t mode = s_port.dp_modes_vdo[i];
        const uint8_t pins = usb_pd_dp_partner_pin_assignments(mode);
        char letters[7];
        uint8_t n = 0;
        if (pins & USB_PD_DP_PIN_A) letters[n++] = 'A';
        if (pins & USB_PD_DP_PIN_B) letters[n++] = 'B';
        if (pins & USB_PD_DP_PIN_C) letters[n++] = 'C';
        if (pins & USB_PD_DP_PIN_D) letters[n++] = 'D';
        if (pins & USB_PD_DP_PIN_E) letters[n++] = 'E';
        if (pins & USB_PD_DP_PIN_F) letters[n++] = 'F';
        letters[n] = '\0';
        osd_log("  vdo=%08lx pins=%s %s", (unsigned long)mode,
                n != 0 ? letters : "-",
                (pins & (USB_PD_DP_PIN_C | USB_PD_DP_PIN_E)) != 0u
                    ? "4-LANE OK"
                    : (pins & (USB_PD_DP_PIN_D | USB_PD_DP_PIN_F)) != 0u
                          ? "2-LANE ONLY" : "no DP pins");
    }
    census_log_sink_caps();
}

#endif /* A2MEGA_HAS_USBC_PD */
