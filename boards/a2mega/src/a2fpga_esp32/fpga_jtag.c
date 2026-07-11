/*
 * fpga_jtag.c — bit-banged JTAG to the GW5AT-60, ESP32-S3 side.
 *
 * The FPGA's JTAG pins are plain ESP32 GPIOs (schematic p.3):
 * TCK=GPIO40, TMS=GPIO41, TDI=GPIO42, TDO=GPIO45. The USB JTAG bridge
 * (a2fpga_jtag.cpp) drives the same pins from openFPGALoader over USB;
 * here we drive them from an internal sequencer so the FPGA's external
 * SPI config flash can be programmed with no PC attached (menu
 * "FPGA UPDATE" from the SD card).
 *
 * The GW5A family does NOT use the GW2A per-transaction IR-0x16 SPI mode.
 * Mirrored from openFPGALoader's gowin.cpp GW5A path instead:
 *  - gw5a_enable_spi(): CfgEnable, IR 0x3F, CfgDisable, NOOP, 1008 idle
 *    clocks, IR 0x16, IR 0x00, 5000 idle clocks, park in Test-Logic-Reset.
 *    After this the TAP pins ARE the SPI bus: TCK=SCLK, TDI=MOSI, TDO=MISO,
 *    and the TLR<->RTI TMS moves frame CS.
 *  - spi_put_gw5a(): from TLR, the single TMS=0 clock into RTI shifts the
 *    command's first (MSB) bit; 7 more clocks finish the command; len*8
 *    (+3 when reading) full-duplex payload clocks follow; 3 TMS=1 clocks
 *    return to TLR (CS deassert). MISO payload is offset by 3 bits.
 *  - MOSI changes on the falling SCLK edge, MISO samples on the rising
 *    edge (SPI mode 0 as seen by the flash).
 *
 * GW5A quirks vs GW2A (all from openFPGALoader):
 *  - IDCODE 0x0001481B (GW5AT-60) vs 0x0000081B (GW2AR-18).
 *  - eraseSRAM completion is DONE_FINAL (bit 13) going LOW.
 *  - A wedged config state (timeout/auto-boot-fail/bad-cmd status bits)
 *    needs a recovery sequence (CfgEnable, 0x3F, CfgDisable, NOOP,
 *    READ_IDCODE, NOOP, 1000 clocks) before the erase.
 */
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "soc/gpio_struct.h"

#include "fpga_jtag.h"

#define PIN_TCK 40
#define PIN_TMS 41
#define PIN_TDI 42
#define PIN_TDO 45

/* All four pins are >= 32, so they live in the out1/in1 register bank. */
#define TCK_BIT (1u << (PIN_TCK - 32))
#define TMS_BIT (1u << (PIN_TMS - 32))
#define TDI_BIT (1u << (PIN_TDI - 32))
#define TDO_BIT (1u << (PIN_TDO - 32))

static inline void gpio_set_bits(uint32_t bits)   { GPIO.out1_w1ts.val = bits; }
static inline void gpio_clear_bits(uint32_t bits) { GPIO.out1_w1tc.val = bits; }
static inline uint32_t gpio_in_bits(void)         { return GPIO.in1.val; }

/* Gowin JTAG instructions (UG290E / openFPGALoader gowinJtagDefs.h) */
#define GWIR_NOOP        0x02
#define GWIR_ERASE_SRAM  0x05
#define GWIR_XFER_DONE   0x09
#define GWIR_IDCODE      0x11
#define GWIR_CFG_ENABLE  0x15
#define GWIR_SPI_MODE    0x16
#define GWIR_CFG_DISABLE 0x3A
#define GWIR_RELOAD      0x3C
#define GWIR_GW5A_PRE    0x3F   /* GW5A pre/recovery instruction */
#define GWIR_STATUS      0x41

/* Status register bits */
#define GWSTAT_BAD_COMMAND      (1u << 1)
#define GWSTAT_TIMEOUT          (1u << 3)
#define GWSTAT_AUTOBOOT2_FAIL   (1u << 4)
#define GWSTAT_MEMORY_ERASE     (1u << 5)
#define GWSTAT_SYS_EDIT_MODE    (1u << 7)
#define GWSTAT_DONE_FINAL       (1u << 13)

static bool s_pins_ready;
static bool s_spi_mode;

void fpga_jtag_init_pins(void)
{
    if (s_pins_ready)
        return;
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << PIN_TCK) | (1ULL << PIN_TMS) | (1ULL << PIN_TDI),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&out);
    gpio_config_t in = {
        .pin_bit_mask = (1ULL << PIN_TDO),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&in);
    gpio_clear_bits(TCK_BIT | TMS_BIT | TDI_BIT);
    s_pins_ready = true;
}

void fpga_jtag_release_pins(void)
{
    if (!s_pins_ready)
        return;
    gpio_set_direction((gpio_num_t)PIN_TCK, GPIO_MODE_INPUT);
    gpio_set_direction((gpio_num_t)PIN_TMS, GPIO_MODE_INPUT);
    gpio_set_direction((gpio_num_t)PIN_TDI, GPIO_MODE_INPUT);
    s_pins_ready = false;
    s_spi_mode = false;
}

/* Keep every TCK phase comfortably wide for the TAP input path. */
static inline void jtag_dly(void)
{
    for (volatile int d = 0; d < 24; d++) { }
}

/* Standard JTAG clock: present TMS/TDI, sample TDO just before the rising
 * edge (TDO changes on falling edges). */
static inline int jtag_clk(int tms, int tdi)
{
    if (tms) gpio_set_bits(TMS_BIT); else gpio_clear_bits(TMS_BIT);
    if (tdi) gpio_set_bits(TDI_BIT); else gpio_clear_bits(TDI_BIT);
    jtag_dly();
    int tdo = (gpio_in_bits() & TDO_BIT) ? 1 : 0;
    gpio_set_bits(TCK_BIT);
    jtag_dly();
    gpio_clear_bits(TCK_BIT);
    return tdo;
}

/* SPI-mode clock: MOSI changes while SCLK low, MISO sampled after the
 * rising edge (write falling / read rising, as openFPGALoader sets for
 * GW5A SPI mode). */
static inline int spi_clk(int tms, int tdi)
{
    if (tms) gpio_set_bits(TMS_BIT); else gpio_clear_bits(TMS_BIT);
    if (tdi) gpio_set_bits(TDI_BIT); else gpio_clear_bits(TDI_BIT);
    jtag_dly();
    gpio_set_bits(TCK_BIT);
    jtag_dly();
    int tdo = (gpio_in_bits() & TDO_BIT) ? 1 : 0;
    gpio_clear_bits(TCK_BIT);
    return tdo;
}

/* Test-Logic-Reset, then park in Run-Test/Idle. */
void fpga_jtag_reset(void)
{
    for (int i = 0; i < 6; i++)
        jtag_clk(1, 0);
    jtag_clk(0, 0);
}

static void jtag_idle_clocks(uint32_t n)
{
    while (n--)
        jtag_clk(0, 0);
}

/* Shift an 8-bit instruction (LSB first), end back in Run-Test/Idle,
 * followed by 6 idle clocks (openFPGALoader send_command). */
static void jtag_ir(uint8_t code)
{
    jtag_clk(1, 0);                      /* RTI -> Select-DR   */
    jtag_clk(1, 0);                      /* -> Select-IR       */
    jtag_clk(0, 0);                      /* -> Capture-IR      */
    jtag_clk(0, 0);                      /* -> Shift-IR        */
    for (int i = 0; i < 8; i++)
        jtag_clk(i == 7, (code >> i) & 1);   /* TMS=1 on last -> Exit1 */
    jtag_clk(1, 0);                      /* -> Update-IR       */
    jtag_clk(0, 0);                      /* -> RTI             */
    for (int i = 0; i < 6; i++)
        jtag_clk(0, 0);
}

/* Read the 32-bit DR (LSB first) currently selected, from RTI. */
static uint32_t jtag_dr_read32(void)
{
    uint32_t v = 0;
    jtag_clk(1, 0);                      /* -> Select-DR  */
    jtag_clk(0, 0);                      /* -> Capture-DR */
    jtag_clk(0, 0);                      /* -> Shift-DR   */
    for (int i = 0; i < 32; i++)
        v |= (uint32_t)jtag_clk(i == 31, 0) << i;
    jtag_clk(1, 0);                      /* -> Update-DR  */
    jtag_clk(0, 0);                      /* -> RTI        */
    return v;
}

uint32_t fpga_jtag_idcode(void)
{
    fpga_jtag_reset();
    jtag_ir(GWIR_IDCODE);
    return jtag_dr_read32();
}

uint32_t fpga_jtag_status(void)
{
    jtag_ir(GWIR_STATUS);
    return jtag_dr_read32();
}

static bool wait_status(uint32_t mask, uint32_t want, int loops)
{
    while (loops--) {
        if ((fpga_jtag_status() & mask) == want)
            return true;
        vTaskDelay(1);
    }
    return false;
}

/* ---- GW5A SPI mode ------------------------------------------------------- */

/* openFPGALoader gw5a_enable_spi(). Ends parked in Test-Logic-Reset with
 * the TAP acting as an SPI master (CS framed by TLR<->RTI moves). */
static void gw5a_enable_spi(void)
{
    jtag_ir(GWIR_CFG_ENABLE);
    jtag_ir(GWIR_GW5A_PRE);
    jtag_ir(GWIR_CFG_DISABLE);
    jtag_ir(GWIR_NOOP);
    jtag_idle_clocks(126 * 8);
    jtag_ir(GWIR_SPI_MODE);
    jtag_ir(0x00);
    jtag_idle_clocks(625 * 8);
    for (int i = 0; i < 5; i++)          /* park in Test-Logic-Reset */
        jtag_clk(1, 0);
    s_spi_mode = true;
}

/* openFPGALoader gw5a_disable_spi(): a specific TMS dance out of SPI mode. */
static void gw5a_disable_spi(void)
{
    /* From TLR: Select-DR, Capture-DR, Exit1-DR, Exit2-DR, then six
     * Pause-DR/Exit2-DR bounces, Exit1... mirrored as TMS sequence. */
    jtag_clk(0, 0);                      /* TLR -> RTI (harmless entry) */
    jtag_clk(1, 0);                      /* -> Select-DR */
    jtag_clk(0, 0);                      /* -> Capture-DR */
    jtag_clk(1, 0);                      /* -> Exit1-DR */
    jtag_clk(0, 0);                      /* -> Pause-DR */
    jtag_clk(1, 0);                      /* -> Exit2-DR */
    for (int i = 0; i < 6; i++) {
        jtag_clk(0, 0);                  /* -> Pause-DR */
        jtag_clk(1, 0);                  /* -> Exit2-DR */
    }
    jtag_clk(1, 0);                      /* -> Update-DR */
    jtag_clk(1, 0);                      /* -> Select-DR */
    jtag_clk(1, 0);                      /* -> Select-IR */
    jtag_clk(1, 0);                      /* -> TLR */
    for (int i = 0; i < 5; i++)
        jtag_clk(1, 0);
    s_spi_mode = false;
}

/* One SPI transaction, mirroring openFPGALoader's spi_put_gw5a: from TLR,
 * the TMS=0 move into RTI shifts the command MSB; 7 clocks finish the
 * command; len*8 (+3 when reading) full-duplex payload clocks; 3 TMS=1
 * clocks back to TLR deassert CS. MISO payload is offset by 3 bits. */
void fpga_jtag_spi_xfer(uint8_t cmd, const uint8_t *tx, uint8_t *rx,
                        uint32_t len)
{
    if (rx)
        memset(rx, 0, len);

    int last_tdi = tx ? (tx[len ? len - 1 : 0] & 1) : (cmd & 1);

    /* Command byte, MSB first; first bit rides the TLR->RTI move. */
    spi_clk(0, (cmd >> 7) & 1);
    for (int i = 6; i >= 0; i--)
        spi_clk(0, (cmd >> i) & 1);

    /* Payload: full duplex, MSB first, +3 trailing clocks when reading. */
    uint32_t nbits = len * 8 + (rx ? 3 : 0);
    for (uint32_t b = 0; b < nbits; b++) {
        uint32_t byi = b >> 3, bii = b & 7;
        int mosi = last_tdi;
        if (tx && byi < len)
            mosi = (tx[byi] >> (7 - bii)) & 1;
        else if (!tx)
            mosi = last_tdi;
        int miso = spi_clk(0, mosi);
        if (rx && b >= 3) {
            uint32_t p = b - 3;          /* MISO delayed 3 clocks */
            if (p < len * 8 && miso)
                rx[p >> 3] |= 0x80u >> (p & 7);
        }
    }

    /* CS deassert: RTI -> Select-DR -> Select-IR -> TLR, then settle. */
    spi_clk(1, last_tdi);
    spi_clk(1, last_tdi);
    spi_clk(1, last_tdi);
    for (int i = 0; i < 5; i++)
        spi_clk(1, last_tdi);
}

/* Read n bytes of the config flash at addr (SPI 0x03). */
void fpga_jtag_flash_read(uint32_t addr, uint8_t *dst, uint32_t n)
{
    while (n) {
        uint32_t chunk = n > 64 ? 64 : n;
        uint8_t tx[3 + 64];
        uint8_t rxb[3 + 64];
        memset(tx, 0, sizeof(tx));
        tx[0] = (addr >> 16) & 0xFF;
        tx[1] = (addr >> 8) & 0xFF;
        tx[2] = addr & 0xFF;
        fpga_jtag_spi_xfer(0x03, tx, rxb, 3 + chunk);
        memcpy(dst, rxb + 3, chunk);
        dst += chunk;
        addr += chunk;
        n -= chunk;
    }
}

/* openFPGALoader GW5A prepare_flash_access: reset + long idle, erase the
 * SRAM (fabric dies), then switch to SPI mode. */
bool fpga_jtag_flash_enter(void)
{
    fpga_jtag_reset();
    jtag_idle_clocks(1000000);           /* GW5A settle (openFPGALoader) */

    uint32_t status = fpga_jtag_status();
    if (status & (GWSTAT_TIMEOUT | GWSTAT_AUTOBOOT2_FAIL | GWSTAT_BAD_COMMAND)) {
        /* GW5A wedged-config recovery sequence */
        jtag_ir(GWIR_CFG_ENABLE);
        jtag_ir(GWIR_GW5A_PRE);
        jtag_ir(GWIR_CFG_DISABLE);
        jtag_ir(GWIR_NOOP);
        jtag_ir(GWIR_IDCODE);
        jtag_ir(GWIR_NOOP);
        jtag_idle_clocks(125 * 8);
    }

    /* eraseSRAM */
    jtag_ir(GWIR_CFG_ENABLE);
    if (!wait_status(GWSTAT_SYS_EDIT_MODE, GWSTAT_SYS_EDIT_MODE, 1000))
        return false;
    jtag_ir(GWIR_ERASE_SRAM);
    jtag_ir(GWIR_NOOP);
    jtag_idle_clocks(4000);
    vTaskDelay(pdMS_TO_TICKS(20));
    /* GW5A: erase is complete when DONE_FINAL drops */
    wait_status(GWSTAT_DONE_FINAL, 0, 1000);
    jtag_ir(GWIR_XFER_DONE);
    jtag_ir(GWIR_NOOP);
    jtag_ir(GWIR_CFG_DISABLE);
    jtag_ir(GWIR_NOOP);
    if (fpga_jtag_status() & GWSTAT_DONE_FINAL)
        return false;                    /* fabric still configured */

    vTaskDelay(pdMS_TO_TICKS(100));
    gw5a_enable_spi();
    vTaskDelay(pdMS_TO_TICKS(100));
    return true;
}

/* Enter SPI-over-JTAG WITHOUT erasing SRAM. Used when the config flash
 * holds a corrupt image: erasing SRAM un-configures the device and re-arms
 * the boot engine's retry loop, which then owns the MSPI bus and defeats
 * every flash operation (live-debugged: block-erase status polls read
 * garbage and time out). With a JTAG-loaded SRAM config the boot engine is
 * satisfied and the bus is free; the running fabric does not use the MSPI
 * pins. The fabric keeps running during the whole flash write. */
bool fpga_jtag_flash_enter_keepsram(void)
{
    fpga_jtag_reset();
    jtag_idle_clocks(1000000);

    vTaskDelay(pdMS_TO_TICKS(100));
    gw5a_enable_spi();
    vTaskDelay(pdMS_TO_TICKS(100));
    return true;
}

/* Leave SPI mode and reconfigure from external flash. */
void fpga_jtag_reload(void)
{
    if (s_spi_mode)
        gw5a_disable_spi();
    fpga_jtag_reset();
    jtag_ir(GWIR_RELOAD);
    jtag_ir(GWIR_NOOP);
    fpga_jtag_reset();
}
