/*
 * A2FPGA ESP32-S3 Firmware — a2mega co-processor
 *
 * Port of the a2n20v2-Enhanced BL616 feature set to the a2mega's
 * ESP32-S3-MINI-1-N8 (see boards/a2mega/docs/ESP32_ENHANCED_PORT.md):
 *   - Octal SPI (8-bit parallel) communication with the FPGA
 *   - On-screen menu + console (gamepad-driven via the FPGA usb_hid_host)
 *   - Disk-image serving from the micro-SD card (Disk II + ProDOS HDD)
 *   - Uthernet II (W5100) MACRAW bridge to WiFi
 *   - FPGA core self-update from a file on the SD card
 *   - USB JTAG bridge for PC-driven FPGA programming (openFPGALoader)
 *   - Serial forwarding to FPGA; CLI mode for diagnostics ("+++")
 *
 * Board: a2mega, plus the a2p25 "displayport1" rev (BOARD_REV=225, see
 * boards/a2p25/docs/ESP32_FW_A2P25.md). The ESP32 module varies by board
 * revision (board_pins.h):
 *   1.0a3   ESP32-S3-MINI-1-N4R2 — 4 MB flash + 2 MB quad PSRAM (same
 *           module as the a2p25; PSRAM available for large buffers)
 *   1.0a2x  ESP32-S3-MINI-1-N8   — 8 MB flash, no PSRAM
 *   a2p25   ESP32-S3-MINI-1-N4R2 (as 1.0a3)
 *
 * Arduino IDE Settings (the Makefile encodes these per revision):
 *   - Board: ESP32S3 Dev Module
 *   - USB Mode: Hardware CDC and JTAG
 *   - USB CDC On Boot: Enabled
 *   - CPU Frequency: 240MHz
 *   - Flash/PSRAM/Partitions: per module above (1.0a3: 4M, PSRAM enabled,
 *     no_ota; 1.0a2x: 8M, PSRAM disabled, default_8MB)
 */

#include <Arduino.h>
#include "board_pins.h"
#if A2MEGA_HAS_SD
#include <SD_MMC.h>
#else
#include <LittleFS.h>
#endif
#include "driver/gpio.h"
#include "soc/usb_serial_jtag_reg.h"
#include "a2fpga_jtag.h"
#include "a2fpga_spi_service.h"
#include "a2fpga_regs.h"
#include "fpga_link.h"
#include "fpga_screen.h"
#include "osd_console.h"
#include "usbhost.h"
#include "usbstorage.h"
#include "fwupdate.h"
#include "settings.h"
#include "wedge_watch.h"
#include "disk.h"
#include "gs_socket.h"
#include "menu.h"
#include "w5100.h"
#include "wifi_bridge.h"
#include "fpga_jtag.h"
#include "fpgaupdate.h"
#include "fpgastream.h"
#include "ftpd.h"
#include "telnetd.h"
#include "usbc_glue.h"
#include "sn75dp130.h"
#include "esp_err.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include <ctype.h>
#include <stdlib.h>

// ============================================================================
// Pin Assignments — see board_pins.h (revision-selected: 1.0a2a vs 1.0a3)
// ============================================================================

#include "board_pins.h"

#define BAUD 115200

// Octal SPI interface to the FPGA
static const ospi_pins_t OSPI_PINS = {
    .sclk = PIN_OPI_CLK,
    .d0   = PIN_OPI_D0,
    .d1   = PIN_OPI_D1,
    .d2   = PIN_OPI_D2,
    .d3   = PIN_OPI_D3,
    .d4   = PIN_OPI_D4,
    .d5   = PIN_OPI_D5,
    .d6   = PIN_OPI_D6,
    .d7   = PIN_OPI_D7,
    .cs   = -1,     // no CS — the protocol uses sync-pattern framing
};

static const int SPI_HZ = 4 * 1000 * 1000;  // (reg path is clean at 8 MHz but
                                             // XFER payload reads outrun the
                                             // proto's 1-byte read pipeline
                                             // above ~4 MHz (FF fill) — add a
                                             // fabric-side prefetch to go higher  // 10 MHz for bring-up: the FPGA read
                                             // pipeline (2 cycles @ 54 MHz) is marginal
                                             // against back-to-back 20 MHz RX byte slots

// OSPI bring-up, gated per board: on the a2p25 dp_test build the link's
// D0 pad (IO11) carries the FPGA telemetry UART instead, and initializing
// SPI2 on it would steal the pad from UART1.
static esp_err_t ospi_init() {
#if A2MEGA_HAS_OSPI_LINK
    return a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
#else
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

#if PIN_A2_RESET_OUT >= 0
// Apple II /RES driver (a2p25: ESP32 IO33 -> open-drain inverter -> slot).
static void a2_reset_drive(bool assert_reset) {
    digitalWrite(PIN_A2_RESET_OUT,
                 (assert_reset == (A2_RESET_ASSERT_LEVEL != 0)) ? HIGH : LOW);
}
// Reset hold (the BL616/a2mega contract, here in firmware because the
// FPGA's reset-hold output has no pin on the a2p25): /RES stays asserted
// from power-on (R1 holds the driver input high before we run) until the
// disk task reports the mounts done — a2_reset_hold_release() from
// disk.c — or until a 15 s backstop in loop(). Only when the OSPI link
// exists (the dp_test bitstream has no Apple-bus logic: release at once).
static bool     s_a2_held = false;
static uint32_t s_a2_hold_deadline_ms = 0;
extern "C" void a2_reset_hold_release(const char *why) {
    if (!s_a2_held) return;
    s_a2_held = false;
    a2_reset_drive(false);
    Serial.printf("[a2] /RES released (%s)\n", why ? why : "");
    osd_log("A2: /RES RELEASED (%s)", why ? why : "");
}
#else
extern "C" void a2_reset_hold_release(const char *why) { (void)why; }
#endif

// ============================================================================
// Global State
// ============================================================================

bool usb_was_connected = false;
static bool sd_mounted = false;
static bool subsystems_up = false;
static bool network_up = false;
static TaskHandle_t disk_task_h = NULL;
static TaskHandle_t menu_task_h = NULL;
static bool wifitest_quiesced = false;

// CLI Escape Sequence
const char* CLI_ESCAPE_SEQUENCE = "+++";
const int ESCAPE_TIMEOUT_MS = 1000;
bool cli_mode = false;
String escape_buffer = "";
unsigned long last_char_time = 0;

// ============================================================================
// Helper Functions
// ============================================================================

static bool parse_u32(const String &s, uint32_t &out) {
    const char *c = s.c_str();
    char *endp = nullptr;
    unsigned long v = strtoul(c, &endp, 0);
    if (endp == c) return false;
    out = (uint32_t)v;
    return true;
}

static int split_ws(const String &line, String *toks, int max_toks) {
    int n = 0;
    int i = 0;
    while (i < (int)line.length() && n < max_toks) {
        while (i < (int)line.length() && isspace((int)line[i])) i++;
        if (i >= (int)line.length()) break;
        int j = i;
        while (j < (int)line.length() && !isspace((int)line[j])) j++;
        toks[n++] = line.substring(i, j);
        i = j;
    }
    return n;
}

static void print_status(uint8_t s) {
    uint8_t ver = (s >> 4) & 0xF;
    uint8_t align = (s >> 3) & 1;
    uint8_t crcerr = (s >> 2) & 1;
    uint8_t busy = (s >> 1) & 1;
    uint8_t ok = s & 1;
    Serial.printf("[SPI] status=0x%02X ver=%u align=%u crcerr=%u busy=%u ok=%u\n",
                  s, ver, align, crcerr, busy, ok);
}

// ============================================================================
// CLI Commands
// ============================================================================

static void cmd_process(String cmd) {
    cmd.trim();
    cmd.toLowerCase();

    if (cmd == "status") {
        Serial.println("=== A2FPGA Status ===");
        Serial.printf("FPGA DONE pin: %s\n", digitalRead(PIN_FPGA_DONE) ? "HIGH" : "LOW");
        Serial.printf("SPI initialized: %s\n", a2spi_is_ready() ? "YES" : "NO");
        if (a2spi_is_ready()) {
            Serial.printf("SPI mode: %s\n", a2spi_is_octal() ? "OCTAL" : "STANDARD");
        }
        Serial.printf("USB connected: %s\n", usb_was_connected ? "YES" : "NO");
        // Only report FPGA-side state over a verified link: with no SOM (or
        // an OSPI-less bring-up bitstream) reg reads "succeed" at the SPI
        // driver level but return floating-bus junk — live-observed as
        // "DDR3: CALIBRATED (retries=254 seq=0xFE)" on an EMPTY board.
        Serial.printf("FPGA link: %s\n",
                      fpga_link_ok() ? "UP (A2FP)" : "DOWN (no OSPI device)");
        if (fpga_link_ok()) {
            uint8_t fs = 0, retries = 0, seq = 0, st = 0;
            if (a2spi_reg_read_status(0x07, &fs, &st) == ESP_OK) {
                a2spi_reg_read_status(0x23, &retries, &st);
                a2spi_reg_read_status(0x24, &seq, &st);
                Serial.printf("DDR3: %s (retries=%u seq=0x%02X)\n",
                              (fs & 0x02) ? "CALIBRATED" : "NOT CALIBRATED",
                              retries, seq);
            }
        }

    } else if (cmd == "spiinit") {
        Serial.println("[SPI] Initializing Octal SPI...");
        esp_err_t err = ospi_init();
        if (err == ESP_OK) {
            Serial.printf("[SPI] Initialized: %s mode @ %d Hz\n",
                         a2spi_is_octal() ? "OCTAL" : "STANDARD", SPI_HZ);
        } else {
            Serial.printf("[SPI] Init failed: %s\n", esp_err_to_name(err));
        }

    } else if (cmd == "spitest") {
        Serial.println("[SPI] Running SPI test...");

        if (!a2spi_is_ready()) {
            esp_err_t err = ospi_init();
            if (err != ESP_OK) {
                Serial.printf("[SPI] Init failed: %s\n", esp_err_to_name(err));
                return;
            }
        }

        // Read protocol version register
        uint8_t proto = 0xFF, st = 0x00;
        esp_err_t err = a2spi_reg_read_status(0x04, &proto, &st);
        Serial.printf("[SPI] reg[0x04] (PROTO_VER) -> 0x%02X (%s)\n",
                     proto, (err == ESP_OK ? "OK" : esp_err_to_name(err)));
        print_status(st);

        // Write/read test register
        err = a2spi_reg_write(0x06, 0x55);
        Serial.printf("[SPI] reg[0x06] <= 0x55 -> %s\n", (err == ESP_OK ? "OK" : esp_err_to_name(err)));

        uint8_t echo = 0x00;
        err = a2spi_reg_read_status(0x06, &echo, &st);
        Serial.printf("[SPI] reg[0x06] readback -> 0x%02X (%s)\n",
                     echo, (err == ESP_OK ? "OK" : esp_err_to_name(err)));
        print_status(st);

        // XFER test to space 0
        uint8_t buf_w[4] = {1, 2, 3, 4};
        Serial.printf("[SPI] xfer-w space=0 addr=0x20 len=4 data=");
        for (int i = 0; i < 4; i++) Serial.printf("%s%02X", (i ? " " : ""), buf_w[i]);
        Serial.println();

        err = a2spi_xfer_write(0, 0x20, buf_w, 4, true);
        Serial.printf("[SPI] xfer-w -> %s\n", (err == ESP_OK ? "OK" : esp_err_to_name(err)));

        uint8_t buf_r[4] = {0};
        err = a2spi_xfer_read_status(0, 0x20, buf_r, 4, true, &st);
        Serial.printf("[SPI] xfer-r -> %s, data=", (err == ESP_OK ? "OK" : esp_err_to_name(err)));
        for (int i = 0; i < 4; i++) Serial.printf("%s%02X", (i ? " " : ""), buf_r[i]);
        Serial.println();
        print_status(st);

        bool match = (memcmp(buf_w, buf_r, 4) == 0);
        Serial.printf("[SPI] roundtrip %s\n", match ? "MATCH" : "MISMATCH");

    } else if (cmd.startsWith("spireg")) {
        String toks[16];
        int nt = split_ws(cmd, toks, 16);
        if (nt < 2) {
            Serial.println("Usage: spireg <reg> [value]");
        } else {
            if (!a2spi_is_ready()) {
                esp_err_t err = ospi_init();
                if (err != ESP_OK) {
                    Serial.printf("spireg: init error: %s\n", esp_err_to_name(err));
                    return;
                }
            }

            uint32_t reg;
            if (!parse_u32(toks[1], reg) || reg > 126) {
                Serial.println("spireg: invalid <reg> (0..126)");
            } else if (nt == 2) {
                uint8_t val = 0, st = 0;
                esp_err_t err = a2spi_reg_read_status((uint8_t)reg, &val, &st);
                if (err == ESP_OK) {
                    Serial.printf("reg[0x%02X] -> 0x%02X (status=0x%02X)\n", (unsigned)reg, val, st);
                } else {
                    Serial.printf("spireg: read error: %s\n", esp_err_to_name(err));
                }
            } else {
                uint32_t v;
                if (!parse_u32(toks[2], v) || v > 0xFF) {
                    Serial.println("spireg: invalid <value> (0..255)");
                } else {
                    esp_err_t err = a2spi_reg_write((uint8_t)reg, (uint8_t)v);
                    if (err == ESP_OK) {
                        Serial.printf("reg[0x%02X] <= 0x%02X\n", (unsigned)reg, (unsigned)v);
                    } else {
                        Serial.printf("spireg: write error: %s\n", esp_err_to_name(err));
                    }
                }
            }
        }

    } else if (cmd == "viddbg") {
        // Dump the video-pipeline debug registers (FPGA regs 0x70-0x77)
        if (!a2spi_is_ready()) {
            esp_err_t err = ospi_init();
            if (err != ESP_OK) {
                Serial.printf("viddbg: init error: %s\n", esp_err_to_name(err));
                return;
            }
        }
        uint8_t v[9];
        fpga_link_lock();   // shared OSPI link (see viddbg_log)
        for (int i = 0; i < 9; i++) {
            uint8_t st = 0;
            esp_err_t err = a2spi_reg_read_status((uint8_t)(0x70 + i), &v[i], &st);
            if (err != ESP_OK) {
                fpga_link_unlock();
                Serial.printf("viddbg: read 0x%02X error: %s\n", 0x70 + i, esp_err_to_name(err));
                return;
            }
        }
        fpga_link_unlock();
        Serial.printf("mode 0x%02X: use_vgc=%d SHRG=%d LINEAR=%d STORE80=%d PAGE2=%d MIXED=%d HIRES=%d TEXT=%d\n",
                      v[0], !!(v[0] & 0x80), !!(v[0] & 0x40), !!(v[0] & 0x20), !!(v[0] & 0x10),
                      !!(v[0] & 0x08), !!(v[0] & 0x04), !!(v[0] & 0x02), !!(v[0] & 0x01));
        Serial.printf("C029 writes=%u last=0x%02X\n", v[1], v[2]);
        Serial.printf("vgc missed hsync/frame=%u  shadow-write drops=%u (sticky)\n", v[3], v[4]);
        Serial.printf("fb flags=0x%02X  ddr3 resp-fifo overflow=0x%02X (bit=port, sticky)\n", v[5], v[6]);
        Serial.printf("shadow rd fsm=0x%02X: vid_req=%d is_vgc=%d cache_valid=%d vgc_req=%d state=%d\n",
                      v[7], !!(v[7] & 0x80), !!(v[7] & 0x40), !!(v[7] & 0x20), !!(v[7] & 0x10), v[7] & 0x07);
        Serial.printf("vgc stale-word swaps/frame=%u\n", v[8]);

    } else if (cmd.startsWith("wifitest")) {
        // A/B instrument for the latency investigation: suspend the board's
        // periodic workload (disk poll @2ms, menu @20ms — both OSPI traffic
        // adjacent to the antenna and core-1 load) to measure whether our
        // own activity causes the RTT spikes. "wifitest on" quiesces,
        // "wifitest off" resumes. Suspending disk serving pauses floppy/HDD
        // I/O — do not leave it on with the Apple II running from disk.
        if (cmd.endsWith("on") && !wifitest_quiesced) {
            if (disk_task_h) vTaskSuspend(disk_task_h);
            if (menu_task_h) vTaskSuspend(menu_task_h);
            wifitest_quiesced = true;
            Serial.println("wifitest: disk+menu tasks SUSPENDED (OSPI quiet)");
        } else if (cmd.endsWith("off") && wifitest_quiesced) {
            if (disk_task_h) vTaskResume(disk_task_h);
            if (menu_task_h) vTaskResume(menu_task_h);
            wifitest_quiesced = false;
            Serial.println("wifitest: tasks resumed");
        } else {
            Serial.printf("wifitest: %s (usage: wifitest on|off)\n",
                          wifitest_quiesced ? "QUIESCED" : "normal");
        }

    } else if (cmd.startsWith("wifiproto")) {
        // TX rate-pathology A/B: "wifiproto bg" drops all 802.11n/MCS rates,
        // "wifiproto bgn" restores. Small frames (ARP) always got through
        // while data frames (ICMP/TCP) died at good RSSI — if bg-only fixes
        // it, the n-rate path (rate control / AMPDU) is the culprit.
        esp_err_t perr;
        if (cmd.endsWith("bgn")) {
            perr = esp_wifi_set_protocol(WIFI_IF_STA,
                WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N);
            Serial.printf("wifiproto: bgn (%s)\n", esp_err_to_name(perr));
        } else if (cmd.endsWith("bg")) {
            perr = esp_wifi_set_protocol(WIFI_IF_STA,
                WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G);
            Serial.printf("wifiproto: bg-only (%s)\n", esp_err_to_name(perr));
        } else {
            uint8_t pr = 0;
            esp_wifi_get_protocol(WIFI_IF_STA, &pr);
            Serial.printf("wifiproto: current=0x%02X (b=1 g=2 n=4)\n", pr);
        }

    } else if (cmd == "wifi" || cmd.startsWith("wifi ")) {
        // Set/show WiFi credentials in NVS. Primary config path on 1.0a3
        // (no SD card, so no wifi.txt); also handy on older boards.
        String toks[3];
        int nt = split_ws(cmd, toks, 3);
        if (nt < 2) {
            a2_settings_t *s = settings();
            Serial.printf("wifi: ssid '%s' (%s)\n",
                          s->wifi_ssid[0] ? s->wifi_ssid : "(unset)",
                          net_connected() ? "connected" :
                          net_ssid()[0]   ? "joining"   : "not started");
            Serial.println("Usage: wifi <ssid> [psk]   (no spaces in ssid;"
                           " omit psk for open networks)");
        } else {
            a2_settings_t *s = settings();
            strlcpy(s->wifi_ssid, toks[1].c_str(), sizeof(s->wifi_ssid));
            strlcpy(s->wifi_psk, nt >= 3 ? toks[2].c_str() : "",
                    sizeof(s->wifi_psk));
            bool saved = settings_save();
            Serial.printf("wifi: ssid '%s' %s\n", s->wifi_ssid,
                          saved ? "saved" : "SAVE FAILED");
            if (!net_ssid()[0]) {
                // Bridge never started (booted unconfigured): start it now.
                if (wifi_bridge_init(s->wifi_ssid, s->wifi_psk)) {
                    osd_log("WIFI: JOINING %s (%s)", s->wifi_ssid,
                            s->dhcp_enable ? "DHCP" : "STATIC IP");
                    ftpd_init();
                    telnetd_init();
                    fpgastream_start();  /* see start_network() note */
                } else {
                    Serial.println("wifi: bridge init failed");
                }
            } else {
                Serial.println("wifi: saved; 'restart' to apply the new network");
            }
        }

    } else if (cmd == "net") {
        wifi_ap_record_t ap;
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK)
            Serial.printf("WiFi: associated to %s  RSSI %d\n", (const char*)ap.ssid, ap.rssi);
        else
            Serial.println("WiFi: NOT associated");
        esp_netif_t *nif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
        if (nif) {
            esp_netif_ip_info_t ii;
            if (esp_netif_get_ip_info(nif, &ii) == ESP_OK)
                Serial.printf("IP: " IPSTR "  GW: " IPSTR "  MASK: " IPSTR "\n",
                              IP2STR(&ii.ip), IP2STR(&ii.gw), IP2STR(&ii.netmask));
        } else {
            Serial.println("netif: WIFI_STA_DEF not found");
        }
        int8_t txp = 0;
        if (esp_wifi_get_max_tx_power(&txp) == ESP_OK)
            Serial.printf("max TX power: %.2f dBm (%d)\n", txp * 0.25, txp);
        wifi_ps_type_t ps;
        if (esp_wifi_get_ps(&ps) == ESP_OK)
            Serial.printf("power save: %s\n",
                          ps == WIFI_PS_NONE ? "NONE" :
                          ps == WIFI_PS_MIN_MODEM ? "MIN_MODEM" : "MAX_MODEM");
        extern volatile uint32_t wifi_dbg_rx_total, wifi_dbg_rx_ucast;
        extern volatile uint32_t wifi_dbg_disconnects, wifi_dbg_last_reason;
        Serial.printf("rx frames: total=%lu unicast-to-me=%lu\n",
                      (unsigned long)wifi_dbg_rx_total,
                      (unsigned long)wifi_dbg_rx_ucast);
        Serial.printf("disconnects: %lu (last reason %lu)\n",
                      (unsigned long)wifi_dbg_disconnects,
                      (unsigned long)wifi_dbg_last_reason);

    } else if (cmd == "fpgaerase") {
        // Erase the config-flash HEADER blocks (128KB) via the
        // SRAM-preserving SPI entry — the GW5A then boots like a
        // factory-blank board and the STANDARD openFPGALoader flash flow
        // works again. Delegates to fpgaupdate_erase_bitstream_region(),
        // which (unlike the original inline version) calls
        // fpga_jtag_init_pins() first: after any USB JTAG bridge session,
        // the disconnect handler leaves TCK/TMS/TDI as INPUTs, and
        // bit-banging floating pins produced "block 0x00000 TIMEOUT"
        // (live-hit on board #1, 2026-08-11).
        Serial.println("fpgaerase: erasing config-flash header "
                       "(keepsram; fabric stays live)...");
        bool eok = fpgaupdate_erase_bitstream_region();
        Serial.printf("fpgaerase: %s\n",
                      eok ? "OK — flash boots as blank; flash normally now"
                          : "FAILED (see log; is a fabric SRAM-loaded?)");

    } else if (cmd.startsWith("fpgaflash ")) {
        // Persistent FPGA flash via the on-board bit-bang updater (fpgaupdate/
        // fpga_jtag). Exists because openFPGALoader's flash flow loses the
        // SPI bus to the GW5A's config-retry loop whenever the flash already
        // holds a corrupt image (its own SRAM-erase step re-arms the retry
        // loop, then its hardcoded-10MHz flash-ID read fails). The bit-bang
        // path runs at the slow clocks that demonstrably win, with per-page
        // verify. We hold the recursive link mutex, so driving
        // fpgaupdate_poll() synchronously here is safe: menu/disk tasks stay
        // blocked (the FPGA is dark during the write anyway) and osd_log's
        // lock re-enters.
        String toks[4];
        int nt = split_ws(cmd, toks, 4);
        if (nt < 2) {
            Serial.println("Usage: fpgaflash <file.bin on SD>");
            return;
        }
        bool keepsram = (nt >= 3 && toks[2] == "keepsram");
        fpgaupdate_set_keepsram(keepsram);
        if (keepsram)
            Serial.println("fpgaflash: keepsram — fabric stays live; flash written under a quiet MSPI bus");
        if (!fpgaupdate_request(toks[1].c_str())) {
            Serial.println("fpgaflash: updater busy");
            return;
        }
        fpgaupdate_poll();   // CHECK phase, synchronous
        Serial.printf("fpgaflash: %s\n", fpgaupdate_message());
        if (fpgaupdate_state() != FPU_READY)
            return;
        Serial.println("fpgaflash: INSTALLING — FPGA goes dark; can take 10+ min; DO NOT power off");
        fpgaupdate_commit();
        fpgaupdate_poll();   // INSTALL phase, synchronous; esp_restart() on success
        Serial.printf("fpgaflash: %s\n", fpgaupdate_message());  // reached only on error

    } else if (cmd.startsWith("ddrd ")) {
        // Dump DDR3 words via the debug read window (regs 0x34-0x3B).
        // Usage: ddrd <word_addr> <word_count>   (addr in hex or dec)
        String toks[16];
        int nt = split_ws(cmd, toks, 16);
        if (nt < 3) {
            Serial.println("Usage: ddrd <word_addr> <words>");
            return;
        }
        if (!a2spi_is_ready()) {
            esp_err_t err = ospi_init();
            if (err != ESP_OK) {
                Serial.printf("ddrd: init error: %s\n", esp_err_to_name(err));
                return;
            }
        }
        uint32_t addr, count;
        if (!parse_u32(toks[1], addr) || addr > 0x1FFFFF ||
            !parse_u32(toks[2], count) || count == 0 || count > 65536) {
            Serial.println("ddrd: bad args (addr 0..0x1FFFFF, words 1..65536)");
            return;
        }
        a2spi_reg_write(0x34, addr & 0xFF);
        a2spi_reg_write(0x35, (addr >> 8) & 0xFF);
        a2spi_reg_write(0x36, (addr >> 16) & 0x1F);
        for (uint32_t w = 0; w < count; w++) {
            a2spi_reg_write(0x37, 1);                 // GO (addr auto-incs)
            uint8_t busy = 1, st;
            for (int t = 0; t < 100 && busy; t++)
                a2spi_reg_read_status(0x37, &busy, &st);
            if (busy) { Serial.printf("\nddrd: timeout at word %lu\n", (unsigned long)w); return; }
            uint8_t d0, d1, d2, d3;
            a2spi_reg_read_status(0x38, &d0, &st);
            a2spi_reg_read_status(0x39, &d1, &st);
            a2spi_reg_read_status(0x3A, &d2, &st);
            a2spi_reg_read_status(0x3B, &d3, &st);
            if ((w & 7) == 0) Serial.printf("\n%06lX:", (unsigned long)(addr + w));
            Serial.printf(" %02X%02X%02X%02X", d3, d2, d1, d0);
        }
        Serial.println("\nddrd: done");

    } else if (cmd.startsWith("spir ")) {
        String toks[16];
        int nt = split_ws(cmd, toks, 16);
        if (nt < 4) {
            Serial.println("Usage: spir <space> <addr> <len> [inc=1]");
        } else {
            if (!a2spi_is_ready()) {
                esp_err_t err = ospi_init();
                if (err != ESP_OK) {
                    Serial.printf("spir: init error: %s\n", esp_err_to_name(err));
                    return;
                }
            }

            uint32_t space, addr, len;
            uint32_t inc = 1;
            if (!parse_u32(toks[1], space) || space > 7) { Serial.println("spir: <space> 0..7"); return; }
            if (!parse_u32(toks[2], addr)) { Serial.println("spir: invalid <addr>"); return; }
            if (!parse_u32(toks[3], len) || len == 0 || len > 4096) { Serial.println("spir: <len> 1..4096"); return; }
            if (nt >= 5) { if (!parse_u32(toks[4], inc)) { Serial.println("spir: invalid [inc]"); return; } }

            uint8_t *buf = (uint8_t*)malloc(len);
            if (!buf) { Serial.println("spir: OOM"); return; }

            uint8_t st = 0;
            esp_err_t err = a2spi_xfer_read_status((uint8_t)space, addr, buf, (uint16_t)len, inc != 0, &st);
            if (err == ESP_OK) {
                Serial.printf("spir: space=%u addr=0x%06lX len=%lu inc=%u status=0x%02X\n",
                             (unsigned)space, (unsigned long)addr, (unsigned long)len, (unsigned)(inc != 0), st);
                for (uint32_t i = 0; i < len; i++) {
                    if ((i % 16) == 0) Serial.printf("%s%06lX:", (i ? "\n" : ""), (unsigned long)(addr + i));
                    Serial.printf(" %02X", buf[i]);
                }
                Serial.println();
            } else {
                Serial.printf("spir: read error: %s\n", esp_err_to_name(err));
            }
            free(buf);
        }

    } else if (cmd.startsWith("spiw ")) {
        String toks[64];
        int nt = split_ws(cmd, toks, 64);
        if (nt < 5) {
            Serial.println("Usage: spiw <space> <addr> <inc> <b0> [b1 ...]");
        } else {
            if (!a2spi_is_ready()) {
                esp_err_t err = ospi_init();
                if (err != ESP_OK) {
                    Serial.printf("spiw: init error: %s\n", esp_err_to_name(err));
                    return;
                }
            }

            uint32_t space, addr, third;
            if (!parse_u32(toks[1], space) || space > 7) { Serial.println("spiw: <space> 0..7"); return; }
            if (!parse_u32(toks[2], addr)) { Serial.println("spiw: invalid <addr>"); return; }
            if (!parse_u32(toks[3], third)) { Serial.println("spiw: invalid <inc>/<len>"); return; }

            bool inc = true;
            uint32_t len = 0;
            int data_start_idx = 4;

            if (third <= 1) { inc = (third != 0); len = nt - data_start_idx; }
            else { len = third; inc = true; }

            if (len == 0 || len > 4096) { Serial.println("spiw: <len> 1..4096"); return; }
            if ((uint32_t)(nt - data_start_idx) < len) { Serial.println("spiw: not enough data bytes"); return; }

            uint8_t *buf = (uint8_t*)malloc(len);
            if (!buf) { Serial.println("spiw: OOM"); return; }

            for (uint32_t i = 0; i < len; i++) {
                uint32_t v;
                if (!parse_u32(toks[data_start_idx + i], v) || v > 0xFF) {
                    Serial.printf("spiw: bad byte at %lu\n", (unsigned long)i);
                    free(buf);
                    return;
                }
                buf[i] = (uint8_t)v;
            }

            esp_err_t err = a2spi_xfer_write((uint8_t)space, addr, buf, (uint16_t)len, inc);
            if (err == ESP_OK) {
                Serial.printf("spiw: wrote %lu bytes to space=%u addr=0x%06lX inc=%u\n",
                             (unsigned long)len, (unsigned)space, (unsigned long)addr, (unsigned)inc);
            } else {
                Serial.printf("spiw: write error: %s\n", esp_err_to_name(err));
            }
            free(buf);
        }

    } else if (cmd == "meminfo") {
        size_t psram_total = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
        size_t psram_free = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
        size_t internal_total = heap_caps_get_total_size(MALLOC_CAP_INTERNAL);
        size_t internal_free = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);

        Serial.println("Memory Information:");
        if (psram_total > 0) {
            Serial.printf("  PSRAM:    %d / %d bytes free (%.1f%% used)\n",
                         (int)psram_free, (int)psram_total,
                         100.0 * (psram_total - psram_free) / psram_total);
        } else {
            Serial.println("  PSRAM:    Not available");
        }
        Serial.printf("  Internal: %d / %d bytes free (%.1f%% used)\n",
                     (int)internal_free, (int)internal_total,
                     100.0 * (internal_total - internal_free) / internal_total);

    } else if (cmd == "pins") {
        Serial.println("=== Pin Assignments ===");
        Serial.println("Octal SPI:");
        Serial.printf("  SCLK: %d\n", OSPI_PINS.sclk);
        Serial.printf("  D0:   %d\n", OSPI_PINS.d0);
        Serial.printf("  D1:   %d\n", OSPI_PINS.d1);
        Serial.printf("  D2:   %d\n", OSPI_PINS.d2);
        Serial.printf("  D3:   %d\n", OSPI_PINS.d3);
        Serial.printf("  D4:   %d\n", OSPI_PINS.d4);
        Serial.printf("  D5:   %d\n", OSPI_PINS.d5);
        Serial.printf("  D6:   %d\n", OSPI_PINS.d6);
        Serial.printf("  D7:   %d\n", OSPI_PINS.d7);
        Serial.printf("  CS:   %d\n", OSPI_PINS.cs);
        Serial.println("JTAG:");
        Serial.printf("  TCK:  %d\n", PIN_TCK);
        Serial.printf("  TMS:  %d\n", PIN_TMS);
        Serial.printf("  TDI:  %d\n", PIN_TDI);
        Serial.printf("  TDO:  %d\n", PIN_TDO);
#if A2MEGA_HAS_FPGA_UART
        Serial.println("Serial (FPGA telemetry):");
        Serial.printf("  RXD:  %d\n", PIN_RXD);
        Serial.printf("  TXD:  %d\n", PIN_TXD);
#endif
        Serial.println("Other:");
        Serial.printf("  FPGA_DONE: %d\n", PIN_FPGA_DONE);
        Serial.printf("  Board: %s rev %d\n", A2_BOARD_NAME, A2MEGA_BOARD_REV);
#if A2MEGA_BOARD_REV == 225
        Serial.printf("  dp_test mode: %s\n", A2P25_DP_TEST ? "ON (IO10=HPD out, IO11=UART RX, no OSPI)" : "off");
        Serial.printf("  RECONFIG_N=%d A2_RESET_OUT=%d (high=assert) LED0=%d LED1=%d BOOT=%d\n",
                      PIN_FPGA_RECONFIG_N, PIN_A2_RESET_OUT, PIN_LED0, PIN_LED1, PIN_BOOT_BTN);
#endif
#if A2MEGA_HAS_SD
        Serial.printf("  SD:   CLK=%d CMD=%d D0=%d D1=%d D2=%d D3=%d DET=%d\n",
                      PIN_SD_CLK, PIN_SD_CMD, PIN_SD_D0, PIN_SD_D1, PIN_SD_D2, PIN_SD_D3, PIN_SD_DET);
#endif
#if A2MEGA_HAS_USBC_PD
        Serial.printf("  I2C:  SCL=%d SDA=%d FUSB_INT=%d\n",
                      PIN_I2C_SCL, PIN_I2C_SDA, PIN_FUSB_INT);
        Serial.printf("  USB-C: VBUS_SRC_EN=%d HPD_OUT=%d\n",
                      PIN_VBUS_SRC_EN, PIN_DP_HPD_OUT);
#endif

#if A2MEGA_HAS_USBC_PD
    } else if (cmd == "pd") {
        usbc_pd_status();
#endif

#if A2MEGA_HAS_USBC_PD
    } else if (cmd == "muxdump") {
        usbc_mux_dump_serial();
    } else if (cmd == "muxflip") {
        // Live A/B of the CC -> FLIPSEL convention (same as telnet 'f').
        // Persists across attaches until toggled back or reboot.
        usbc_mux_flip_toggle();
        usbc_mux_dump_serial();
    } else if (cmd == "i2cscan") {
        usbc_i2c_scan_log();
#endif

#if A2MEGA_HAS_DP130
    } else if (cmd == "dp130" || cmd.startsWith("dp130 ")) {
        // SN75DP130 debug access. The part runs in its power-up AUTO mode;
        // nothing writes it unless an operator issues "dp130 w".
        //   dp130                    dump 0x00-0x3F
        //   dp130 r <reg> [count]    read
        //   dp130 w <reg> <val>      write (debug override)
        //   dp130 probe              re-probe 0x2C-0x2F
        String toks[4];
        int nt = split_ws(cmd, toks, 4);
        uint32_t reg = 0, arg = 0;
        if (nt >= 2 && toks[1] == "probe") {
            Serial.printf("dp130: %s at 0x%02X\n",
                          dp130_init() ? "found" : "NOT found", dp130_addr());
        } else if (nt >= 3 && toks[1] == "w") {
            if (nt < 4 || !parse_u32(toks[2], reg) || reg > 0xFF ||
                !parse_u32(toks[3], arg) || arg > 0xFF) {
                Serial.println("Usage: dp130 w <reg> <val>");
            } else {
                int rc = dp130_write((uint8_t)reg, (uint8_t)arg);
                uint8_t rb = 0;
                int rrc = dp130_read((uint8_t)reg, &rb);
                Serial.printf("dp130[0x%02X] <= 0x%02X %s; readback %s0x%02X\n",
                              (unsigned)reg, (unsigned)arg, rc ? "NAK" : "ok",
                              rrc ? "FAILED " : "", rb);
            }
        } else {
            uint32_t first = 0x00, count = 0x40;
            if (nt >= 3 && toks[1] == "r") {
                if (!parse_u32(toks[2], first) || first > 0xFF) {
                    Serial.println("Usage: dp130 r <reg> [count]");
                    return;
                }
                count = 1;
                if (nt >= 4 && (!parse_u32(toks[3], count) || count == 0))
                    count = 1;
                if (first + count > 0x100) count = 0x100 - first;
            }
            Serial.printf("dp130 @0x%02X%s:\n", dp130_addr(),
                          dp130_present() ? "" : " (not detected at boot)");
            for (uint32_t r = first; r < first + count; r++) {
                if (((r - first) % 16) == 0)
                    Serial.printf("%s%02X:", (r != first) ? "\n" : "", (unsigned)r);
                uint8_t v = 0;
                if (dp130_read((uint8_t)r, &v) == 0)
                    Serial.printf(" %02X", v);
                else
                    Serial.print(" --");
            }
            Serial.println();
        }
#endif

#if PIN_A2_RESET_OUT >= 0
    } else if (cmd == "a2reset") {
        Serial.println("a2reset: asserting Apple II /RES for 200 ms");
        a2_reset_drive(true);
        delay(200);
        a2_reset_drive(false);
        osd_log("APPLE II RESET PULSED");
#endif

#if A2MEGA_BOARD_REV == 225
    } else if (cmd.startsWith("fwupdate")) {
        // fwupdate <file>   check a .bin on the volume (relative to /sdcard)
        // fwupdate go       install the checked file and restart
        // fwupdate cancel
        String arg = cmd.length() > 9 ? cmd.substring(9) : String("");
        arg.trim();
        if (arg == "go") { fwupdate_commit(); Serial.println("fwupdate: installing"); }
        else if (arg == "cancel") { fwupdate_cancel(); Serial.println("fwupdate: cancelled"); }
        else if (arg.length()) { Serial.printf("fwupdate: %s\n", fwupdate_request(arg.c_str()) ? "checking" : "busy"); }
        else Serial.printf("fwupdate: state %d: %s (slot %s)\n", (int)fwupdate_state(), fwupdate_message(), fwupdate_running_slot());
    } else if (cmd == "reconfig") {
        // Pulse the FPGA's RECONFIG_N (open-drain style: drive low, then
        // release to the R32 pull-up) — reload the bitstream from flash.
        Serial.println("reconfig: pulsing RECONFIG_N low 1 ms");
        disk_quiesce();                   // no serving off a dead fabric
        pinMode(PIN_FPGA_RECONFIG_N, OUTPUT);
        digitalWrite(PIN_FPGA_RECONFIG_N, LOW);
        delay(1);
        pinMode(PIN_FPGA_RECONFIG_N, INPUT);
        uint32_t t0 = millis();
        while (!digitalRead(PIN_FPGA_DONE) && millis() - t0 < 5000) delay(10);
        Serial.printf("reconfig: DONE=%d after %lu ms\n", digitalRead(PIN_FPGA_DONE),
                      (unsigned long)(millis() - t0));
        disk_request_remount();           // re-register the disks in the new fabric
#endif

    } else if (cmd == "restart") {
        Serial.println("Restarting...");
        Serial.flush();
        disk_release_storage();           // close images, detach the stick's FAT
        delay(100);
        ESP.restart();

    } else if (cmd == "exit") {
        cli_mode = false;
        Serial.println("Exiting CLI mode. Returning to serial forwarding mode.");
        Serial.println("Use '+++' to enter CLI mode again.");

    } else if (cmd == "help") {
        Serial.println("=== A2FPGA ESP32 CLI Commands ===");
        Serial.println("  status    - Show system status");
        Serial.println("  spiinit   - Initialize Octal SPI");
        Serial.println("  spitest   - Run SPI loopback test");
        Serial.println("  spireg <reg> [val]  - Read/write SPI register (0..126)");
        Serial.println("  viddbg              - Dump video-pipeline debug regs (0x70-0x77)");
        Serial.println("  spir <space> <addr> <len> [inc=1]  - Read from FPGA");
        Serial.println("  spiw <space> <addr> <inc> <b0> [b1 ...]  - Write to FPGA");
        Serial.println("  meminfo   - Show memory usage");
        Serial.println("  pins      - Show pin assignments");
        Serial.println("  wifi [<ssid> [psk]] - Show/set WiFi credentials (NVS)");
        Serial.println("  net       - Show WiFi/IP status");
#if A2MEGA_HAS_USBC_PD
        Serial.println("  pd        - Show USB-C PD / DP Alt Mode status");
        Serial.println("  i2cscan   - List devices on the DP I2C bus");
#endif
#if A2MEGA_HAS_DP130
        Serial.println("  dp130 [r <reg> [n] | w <reg> <val> | probe] - SN75DP130 regs");
#endif
#if PIN_A2_RESET_OUT >= 0
        Serial.println("  a2reset   - Pulse the Apple II /RES line (200 ms)");
#endif
#if A2MEGA_BOARD_REV == 225
        Serial.println("  reconfig  - Pulse FPGA RECONFIG_N (reload from flash)");
        Serial.println("  fwupdate [<file>|go|cancel] - MCU self-update from a .bin on the volume");
#endif
        Serial.println("  restart   - Reboot the ESP32");
        Serial.println("  exit      - Return to serial forwarding mode");
        Serial.println("  help      - Show this help");

    } else if (cmd.length()) {
        Serial.printf("Unknown command: %s (type 'help' for available commands)\n", cmd.c_str());
    }
}

// ============================================================================
// Escape Sequence Detection
// ============================================================================

void check_escape_timeout() {
    if (escape_buffer.length() > 0 && (millis() - last_char_time) > ESCAPE_TIMEOUT_MS) {
        if (!cli_mode) {
#if A2MEGA_HAS_FPGA_UART
            for (int i = 0; i < escape_buffer.length(); i++) {
                Serial1.write(escape_buffer.charAt(i));
            }
#endif
        }
        escape_buffer = "";
    }
}

String check_escape_sequence(char c) {
    last_char_time = millis();
    escape_buffer += c;

    if (escape_buffer == CLI_ESCAPE_SEQUENCE) {
        escape_buffer = "";
        cli_mode = true;
        Serial.println("\nEntering CLI mode. Type 'help' for commands or 'exit' to return to forwarding.");
        Serial.printf("A2FPGA ESP32-S3 Firmware (%s %s)\n", __DATE__, __TIME__);
        return "";
    }

    if (String(CLI_ESCAPE_SEQUENCE).startsWith(escape_buffer)) {
        return "";
    }

    String to_forward = escape_buffer.substring(0, escape_buffer.length() - 1);
    escape_buffer = String(c);

    if (String(CLI_ESCAPE_SEQUENCE).startsWith(escape_buffer)) {
        return to_forward;
    } else {
        String result = to_forward + c;
        escape_buffer = "";
        return result;
    }
}

// ============================================================================
// Subsystem bring-up
// ============================================================================

// Apply DHCP/static-IP changes from the menu to the ESP32's WiFi netif.
// (The Apple II's own IP stack, over the W5100, configures itself.)
extern "C" void menu_hook_net_apply(void) {
    a2_settings_t *s = settings();
    wifi_bridge_config_ip(s->dhcp_enable != 0, s->static_ip, s->static_mask, s->static_gw);
    Serial.printf("[net] applied %s config\n", s->dhcp_enable ? "DHCP" : "static IP");
}

#if A2MEGA_HAS_SD
static bool mount_sd() {
    pinMode(PIN_SD_DET, INPUT_PULLUP);
    SD_MMC.setPins(PIN_SD_CLK, PIN_SD_CMD, PIN_SD_D0, PIN_SD_D1, PIN_SD_D2, PIN_SD_D3);
    if (!SD_MMC.begin("/sdcard", false)) {
        // Retry in 1-bit mode in case D1-D3 routing differs on this board spin
        if (!SD_MMC.begin("/sdcard", true)) {
            Serial.println("[sd] mount failed");
            return false;
        }
        Serial.println("[sd] mounted (1-bit mode)");
        return true;
    }
    Serial.println("[sd] mounted (4-bit mode)");
    return true;
}
#else
// 1.0a3 has no SD slot. Storage is a LittleFS on the 1.875 MB "spiffs"
// flash partition (no_ota scheme on the N4R2's 4 MB part), mounted at the
// same /sdcard VFS prefix so disk.c / ftpd.c / fpgaupdate.c (all plain
// POSIX on that prefix) work unchanged. Disk images arrive over FTP once
// WiFi is up. An uncompressed FPGA bitstream (~2.6 MB) does not fit —
// see the Makefile note.
static bool mount_sd() {
    if (!LittleFS.begin(true /* format on first use */, "/sdcard", 10,
                        "spiffs")) {
        Serial.println("[fs] LittleFS mount FAILED");
        return false;
    }
    Serial.printf("[fs] LittleFS at /sdcard: %u KB used of %u KB\n",
                  (unsigned)(LittleFS.usedBytes() / 1024),
                  (unsigned)(LittleFS.totalBytes() / 1024));
    return true;
}
#endif

// Storage backend swap at /sdcard (called by disk.c from the disk task,
// images closed): USB stick (FatFS over usbhost) or the local volume.
extern "C" void storage_activate(bool usb) {
#if A2MEGA_HAS_OSPI_LINK
    if (usb) {
#if !A2MEGA_HAS_SD
        LittleFS.end();
#else
        SD_MMC.end();
#endif
        if (!usbstorage_mount("/sdcard")) {
            osd_log("USB STICK: MOUNT FAILED (FAT?)");
            sd_mounted = mount_sd();          /* back to the local volume */
            return;
        }
        osd_log("USB STICK MOUNTED AT /SDCARD");
        sd_mounted = true;
    } else {
        usbstorage_unmount();
        sd_mounted = mount_sd();
        osd_log(sd_mounted ? "LOCAL VOLUME MOUNTED" : "LOCAL VOLUME FAILED");
    }
#else
    (void)usb;
#endif
}

// WiFi configuration file: wifi.txt on the SD card (root, with
// /sdcard/A2FPGA/wifi.txt as a fallback location).
//   line 1: SSID
//   line 2: password
//   lines 3-5 (optional): static IP address, netmask, gateway
// When lines 3-5 are absent (or unparsable), DHCP is assumed. The parsed
// configuration is persisted into settings so it survives without the card.
static bool parse_ip4(const char *str, uint8_t out[4]) {
    unsigned a, b, c, d;
    if (sscanf(str, "%u.%u.%u.%u", &a, &b, &c, &d) != 4)
        return false;
    if (a > 255 || b > 255 || c > 255 || d > 255)
        return false;
    out[0] = a; out[1] = b; out[2] = c; out[3] = d;
    return true;
}

static void load_wifi_credentials() {
    a2_settings_t *s = settings();
    FILE *f = fopen("/sdcard/wifi.txt", "r");
    if (!f)
        f = fopen("/sdcard/A2FPGA/wifi.txt", "r");
    if (!f)
        return;

    char line[5][96];
    int nlines = 0;
    while (nlines < 5 && fgets(line[nlines], sizeof(line[0]), f)) {
        line[nlines][strcspn(line[nlines], "\r\n")] = 0;
        nlines++;
    }
    fclose(f);

    if (nlines < 1 || !line[0][0])
        return;

    const char *ssid = line[0];
    const char *psk  = (nlines >= 2) ? line[1] : "";

    uint8_t ip[4] = {0}, mask[4] = {0}, gw[4] = {0};
    bool have_static = (nlines >= 5) &&
                       parse_ip4(line[2], ip) &&
                       parse_ip4(line[3], mask) &&
                       parse_ip4(line[4], gw);

    bool changed = strcmp(s->wifi_ssid, ssid) || strcmp(s->wifi_psk, psk) ||
                   (s->dhcp_enable != (have_static ? 0 : 1)) ||
                   (have_static && (memcmp(s->static_ip, ip, 4) ||
                                    memcmp(s->static_mask, mask, 4) ||
                                    memcmp(s->static_gw, gw, 4)));
    if (changed) {
        strlcpy(s->wifi_ssid, ssid, sizeof(s->wifi_ssid));
        strlcpy(s->wifi_psk, psk, sizeof(s->wifi_psk));
        s->dhcp_enable = have_static ? 0 : 1;
        if (have_static) {
            memcpy(s->static_ip, ip, 4);
            memcpy(s->static_mask, mask, 4);
            memcpy(s->static_gw, gw, 4);
        }
        settings_save();
        Serial.printf("[net] wifi.txt: ssid '%s', %s\n", ssid,
                      have_static ? "static IP" : "DHCP");
    }
}

// Disk service task: image serving + FPGA update state machine. All SD
// filesystem work (including the menu's directory listings) runs here.
static void disk_task(void *arg) {
    (void)arg;
    for (;;) {
        gs_socket_poll();      /* in-socket 65816 auto-arm (no-op without the ribbon) */
        disk_poll();
        fpgaupdate_poll();
        fwupdate_poll();
        vTaskDelay(pdMS_TO_TICKS(2));
    }
}

// Menu/UI task: gamepad polling + OSD rendering at ~50 Hz.
static void menu_task(void *arg) {
    (void)arg;
    for (;;) {
        menu_tick();
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

// Network + storage bring-up, deliberately INDEPENDENT of the FPGA link.
// On 1.0a3 the USB-C port is the monitor, so WiFi/telnet is the primary
// console and must come up even when the FPGA is absent (no SOM fitted),
// unconfigured, or running a bitstream without the OSPI service (the DP
// colorbars bring-up build has none). osd_log() lines emitted here are
// buffered in the console and replay to the OSD when the link appears.
static void start_network() {
    if (network_up)
        return;
    network_up = true;

    settings_init();
    wedge_watch_init();   /* auto-recovery policy (needs NVS up) */
    sd_mounted = mount_sd();

    osd_log("%s ESP32 %s %s", A2_BOARD_NAME, __DATE__, __TIME__);
#if A2MEGA_BOARD_REV == 225 && A2P25_DP_TEST
    osd_log("DP_TEST MODE: HPD->IO10, TELEM<-IO11");
#endif
#if A2MEGA_HAS_SD
    osd_log(sd_mounted ? "SD CARD MOUNTED" : "NO SD CARD");
#else
    osd_log(sd_mounted ? "FLASH FS MOUNTED" : "FLASH FS FAILED");
#endif

    if (sd_mounted)
        load_wifi_credentials();
    a2_settings_t *s = settings();
    if (s->wifi_ssid[0]) {
        wifi_bridge_config_ip(s->dhcp_enable != 0, s->static_ip,
                              s->static_mask, s->static_gw);
        if (wifi_bridge_init(s->wifi_ssid, s->wifi_psk)) {
            osd_log("WIFI: JOINING %s (%s)", s->wifi_ssid,
                    s->dhcp_enable ? "DHCP" : "STATIC IP");
            ftpd_init();     /* FTP file drop for /sdcard once WiFi is up */
            telnetd_init();  /* remote console/menu mirror on port 23 */
            /* Network bitstream flashing (port 2323, bench). Must NOT
             * be FPGA-link-gated (bring-up bitstreams have no OSPI
             * link) but MUST be behind wifi_bridge_init: calling
             * lwIP sockets before the stack exists asserts in
             * xQueueSemaphoreTake (fresh unprovisioned board, found
             * the hard way 08-18). */
            fpgastream_start();
        } else {
            osd_log("WIFI: INIT FAILED");
        }
    } else {
#if A2MEGA_HAS_SD
        osd_log("WIFI: NOT CONFIGURED (WIFI.TXT)");
#else
        osd_log("WIFI: NOT CONFIGURED (CLI: WIFI <SSID> <PSK>)");
#endif
    }
}

static void start_subsystems() {
    if (subsystems_up)
        return;
#if !A2MEGA_HAS_OSPI_LINK
    // dp_test build: no OSPI service in the bitstream and IO11 is the
    // telemetry UART — never touch SPI2. (Called every 500 ms by loop().)
    return;
#endif

    esp_err_t err = ospi_init();
    if (err != ESP_OK) {
        Serial.printf("[SPI] init failed: %s\n", esp_err_to_name(err));
        return;
    }
    if (!fpga_link_init()) {
        // Keep probing quietly: with the colorbars bring-up bitstream (no
        // OSPI service in fabric) this state is permanent and expected.
        static uint32_t misses = 0;
        if (misses++ % 60 == 0)
            Serial.println("[fpga] no A2FP device on the OSPI link; retrying "
                           "in the background (normal for bring-up bitstreams)");
        return;
    }

    osd_console_show();

    // USB host on the module's USB-C (gamepads, HID remotes): device-first
    // role decision, then the OTG host stack (usbhost.cpp)
    usbhost_start();

    disk_init();
    menu_init();
    w5100_init();

    // DDR3 calibration telemetry: status reg bit1 = init_calib_complete,
    // reg 0x23 = fabric watchdog retry count (nonzero = the reset sequencer
    // had to re-run calibration this boot — track to correlate failures
    // with e.g. gamepad rumble load). MUST run before the disk/menu tasks
    // exist AND under the link mutex: raw a2spi calls racing task traffic
    // panic the SPI driver (boot-loop, learned the hard way).
    if (a2spi_is_ready()) {
        uint8_t fpga_status = 0, ddr3_retries = 0, st = 0;
        fpga_link_lock();
        esp_err_t serr = a2spi_reg_read_status(0x07, &fpga_status, &st);
        esp_err_t rerr = a2spi_reg_read_status(0x23, &ddr3_retries, &st);
        fpga_link_unlock();
        if (serr == ESP_OK && !(fpga_status & 0x02)) {
            Serial.println("[a2fpga] WARNING: DDR3 NOT CALIBRATED");
            osd_log("WARNING: DDR3 NOT CALIBRATED");
        }
        if (serr == ESP_OK && rerr == ESP_OK && ddr3_retries != 0) {
            Serial.printf("[a2fpga] DDR3 calib retries this boot: %u\n", ddr3_retries);
            osd_log("DDR3 CALIB RETRIES: %u", ddr3_retries);
        }
    }

    xTaskCreatePinnedToCore(disk_task, "disk", 8192, NULL, 5, &disk_task_h, 1);
    xTaskCreatePinnedToCore(menu_task, "menu", 8192, NULL, 4, &menu_task_h, 1);

    subsystems_up = true;
    Serial.println("[a2fpga] subsystems up");
}

// ============================================================================
// Arduino Setup and Loop
// ============================================================================

// Video/DOC debug block (FPGA regs 0x70-0x78) into the OSD/telnet console
// log, so the counters are readable over WiFi (telnet key 'w'). Same
// registers as the CLI's "viddbg"; on the a2p25 the two $C029 slots carry
// the DOC fetch telemetry (timeouts, max latency in clk_logic cycles).
volatile bool viddbg_request = false;   // telnet 'z' -> serviced in loop()
extern "C" void viddbg_log(void)
{
    if (!a2spi_is_ready()) { osd_log("VIDDBG: SPI NOT READY"); return; }
    uint8_t v[9], pf[8], st2 = 0;   // pf: DOC REQ lo/hi, MEMRD lo/hi, LATE lo/hi, GLU drops, DOC fetch drops
    // The OSPI link is shared with the disk/menu tasks: take the link mutex
    // around the burst of register reads (an unlocked burst during disk
    // streaming collided on the SPI driver and panicked the ESP32 — which
    // holds the Apple II in reset while it reboots; 2026-10-14).
    fpga_link_lock();
    for (int i = 0; i < 9; i++) {
        uint8_t st = 0;
        if (a2spi_reg_read_status((uint8_t)(0x70 + i), &v[i], &st) != ESP_OK) {
            fpga_link_unlock();
            osd_log("VIDDBG: READ 0x%02X FAILED", 0x70 + i);
            return;
        }
    }
    /* DOC per-frame telemetry lives in the indexed debug window (select
     * 0x5F, data 0x4F; indices 40-45 = REQ lo/hi, MEMRD lo/hi, LATE lo/hi,
     * 46 = GLU write-queue drops, 47 = DOC fetch drops, both sticky;
     * 32-39 is the socket module's event log).
     * The plain registers it used until 2026-10-22 (0x3C-0x3F, 0x2F, 0x4F,
     * 0x5F) are the DP readback and the GS-socket window on the a2mega. */
    for (int i = 0; i < 8; i++) {
        fpga_reg_write(0x5F, (uint8_t)(40 + i));
        a2spi_reg_read_status(0x4F, &pf[i], &st2);
    }
    fpga_link_unlock();
    osd_log("VIDDBG MODE %02X FB %02X OVFL %02X RD %02X", v[0], v[5], v[6], v[7]);
#if A2MEGA_BOARD_REV == 225
    osd_log("DOC TIMEOUTS %u  LATMAX %u CLK (0x%02X)", v[1], v[2], v[2]);
    osd_log("DOC/FRAME REQ %u MEMRD %u LATE %u", (unsigned)pf[0] | ((unsigned)pf[1] << 8),
            (unsigned)pf[2] | ((unsigned)pf[3] << 8), (unsigned)pf[4] | ((unsigned)pf[5] << 8));
    osd_log("GLU WQ DROPS %u  DOC FETCH DROPS %u (STICKY)", pf[6], pf[7]);
#else
    osd_log("C029 WRITES %u LAST %02X", v[1], v[2]);
#endif
    osd_log("VGC HSYNC %u STALE %u  SHADOW DROPS %u", v[3], v[8], v[4]);
}

void setup() {
    // NOTE: do NOT route the USB JTAG bridge here. It was tried (early
    // rescue window for the MSPI-hang state, board #1 2026-08-11) and it
    // broke the bridge for the rest of the boot: Serial.begin()'s
    // hardware-CDC init reconfigures the same USB peripheral and leaves
    // an early-routed bridge half-configured — every JTAG chain scan
    // after the first returned "no device found" until power cycle
    // (observed 30/30 flash-attempt failures). loop()'s edge-triggered
    // routing after USB init is the correct path; the MSPI-hang rescue
    // works through the SRAM-load retry race regardless.
#if PIN_A2_RESET_OUT >= 0
    // a2p25: R1 pulls the reset driver's input high, i.e. the Apple II has
    // been held in /RES since power-on. Production (OSPI link): keep holding
    // until the mounts are done (disk.c) or the 15 s backstop — the Apple's
    // autoboot slot scan must not run before storage is up. dp_test: the
    // bring-up bitstream has no Apple-bus logic, the card is passive —
    // release at once.
    pinMode(PIN_A2_RESET_OUT, OUTPUT);     // output latch resets to 0 = released
#if A2MEGA_HAS_OSPI_LINK
    a2_reset_drive(true);
    s_a2_held = true;
    s_a2_hold_deadline_ms = millis() + 15000;
    Serial.println("[a2] /RES held until media mounted (15 s backstop)");
    osd_log("A2: /RES HELD UNTIL MEDIA MOUNTED");
#else
    a2_reset_drive(false);
#endif
#endif
#if PIN_LED0 >= 0
    pinMode(PIN_LED0, OUTPUT);
    digitalWrite(PIN_LED0, HIGH);
#endif
#if PIN_LED1 >= 0
    pinMode(PIN_LED1, OUTPUT);
    digitalWrite(PIN_LED1, LOW);
#endif
#if A2MEGA_BOARD_REV == 225
    pinMode(PIN_FPGA_RECONFIG_N, INPUT);   // R32 pull-up; never driven here
    // (IO10 is PIN_DP_HPD_OUT in both variants — set up as an output below)
#endif
    Serial.begin(115200);
#if A2MEGA_HAS_FPGA_UART
    // a2mega: UART pads 44/43. a2p25 dp_test: GPIO-matrix routed — RX on
    // IO11 (ESP32_OPI_D0 = FPGA ball C2, the bitstream's uart_tx), TX on
    // IO12 (ESP32_OPI_D1 = ball F2, the PSRAM test console's uart_rx).
    Serial1.begin(BAUD, SERIAL_8N1, PIN_RXD, PIN_TXD);
#endif
    delay(300);

    Serial.printf("A2FPGA ESP32-S3 Firmware (%s %s)\n", __DATE__, __TIME__);
    Serial.printf("%s co-processor (board rev %d)\n", A2_BOARD_NAME, A2MEGA_BOARD_REV);
    Serial.println("Serial forwarding mode active. Use '+++' to enter CLI mode.");

    cli_mode = false;

    pinMode(PIN_FPGA_DONE, INPUT_PULLUP);

#if A2MEGA_HAS_USBC_PD
    // Pin down the USB-C power-path controls before anything else runs.
    // VBUS_SRC_EN (strapping pin, external pull-down) must stay low unless
    // we deliberately source 5 V out the port; HPD to the FPGA idles low
    // until the PD stack reports a DisplayPort sink.
    pinMode(PIN_VBUS_SRC_EN, OUTPUT);
    digitalWrite(PIN_VBUS_SRC_EN, LOW);
#if PIN_DP_HPD_OUT >= 0
    pinMode(PIN_DP_HPD_OUT, OUTPUT);
    digitalWrite(PIN_DP_HPD_OUT, LOW);
#endif
    pinMode(PIN_FUSB_INT, INPUT);   // open-drain, external pull-up (R19 a2mega / R25 a2p25)

    // PD policy (FUSB302B + DP mux) is independent of the FPGA link and
    // time-bound once a partner attaches — start it before the subsystems.
    usbc_pd_init();
#endif
#if A2MEGA_HAS_DP130
    // Probe only: the DP130 stays in its power-up auto mode.
    dp130_init();
#endif

    start_network();      /* WiFi/telnet console first — never FPGA-gated */

    // Route the USB-JTAG bridge ONCE, after USB/CDC init, and never
    // unroute it. The old edge-triggered routing keyed on
    // usb_serial_jtag_is_connected() — an SOF-activity heuristic that
    // macOS USB autosuspend defeats whenever no host process holds a
    // port open: suspend -> "disconnected" -> unroute -> the next
    // openFPGALoader open races the polled re-route and loses. That one
    // heuristic caused two days of "JTAG wedge" rituals (works
    // first-op-after-replug, dies on op two, retry-races eventually
    // win). The bit-bang path (fpga_jtag) does its own pad handoff via
    // fpga_usb_jtag_bridge_release()/restore(), so permanent routing is
    // safe. (Routing EARLY in setup(), before Serial.begin, was tried
    // and broke the bridge differently — this placement is the one that
    // works.)
    route_usb_jtag_to_gpio();

    start_subsystems();
}

void loop() {
    if (viddbg_request) { viddbg_request = false; viddbg_log(); }
#if PIN_A2_RESET_OUT >= 0
    // reset-hold backstop: a machine with no media, or a link that never
    // came up, still boots
    if (s_a2_held && (int32_t)(millis() - s_a2_hold_deadline_ms) >= 0)
        a2_reset_hold_release("backstop");
#endif
    // One-shot debug-UART line diagnostic (2026-08-13: FPGA heartbeat up,
    // uart_tx placed on H13, yet zero bytes reach the telnet tee): raw-
    // sample the Serial1 RX pad for 400 ms ~8 s after boot. The GPIO in-
    // register still reflects the pad while the UART owns it. A healthy
    // line idles HIGH and shows a burst of edges every ~340 ms; stuck
    // LOW = pin conflict/no drive; HIGH with 0 edges = FPGA not sending.
#if A2MEGA_HAS_FPGA_UART
    static bool uart_diag_done = false;
    if (!uart_diag_done && millis() > 8000) {
        uart_diag_done = true;
        int last = gpio_get_level((gpio_num_t)PIN_RXD), edges = 0;
        uint32_t lows = 0, n = 0;
        uint32_t t0 = millis();
        while (millis() - t0 < 400) {
            int v = gpio_get_level((gpio_num_t)PIN_RXD);
            n++;
            if (v != last) { edges++; last = v; }
            if (!v) lows++;
        }
        char msg[64];
        snprintf(msg, sizeof msg, "UARTDIAG: RX%d EDGES=%d LOW=%lu/%lu",
                 PIN_RXD, edges, (unsigned long)lows, (unsigned long)n);
        osd_log(msg);
        Serial.printf("[diag] %s\n", msg);
    }
#endif

#if PIN_LED0 >= 0
    // LED0 heartbeat (1 Hz): the ESP32 firmware is alive.
    {
        static uint32_t last_hb = 0;
        static bool hb = true;
        if (millis() - last_hb >= 500) {
            last_hb = millis();
            hb = !hb;
            digitalWrite(PIN_LED0, hb ? HIGH : LOW);
        }
    }
#endif

    // Late bring-up: keep probing until the FPGA answers on the OSPI link
    // (it may still be configuring at ESP32 boot).
    if (!subsystems_up) {
        static uint32_t last_try = 0;
        if (millis() - last_try > 500) {
            last_try = millis();
            start_subsystems();
        }
    } else {
        // Network servicing (W5100 doorbells + WiFi uplink), same task.
        w5100_poll();
        wifi_bridge_poll();
    }

    // USB JTAG bridge: routed permanently in setup() (see note there).
    // Track connection state for the 'status' display only.
    usb_was_connected = usb_serial_jtag_is_connected();

    check_escape_timeout();

    if (cli_mode) {
        if (Serial.available()) {
            String s = Serial.readStringUntil('\n');
            // Hold the FPGA-link mutex across the whole command: the CLI's
            // a2spi_* calls otherwise race the disk/menu/w5100 tasks'
            // transactions on the same SPI device — live-observed as an IDF
            // spi_device_transmit assert (ret_trans == trans_desc) crash.
            fpga_link_lock();
            cmd_process(s);
            fpga_link_unlock();
        }
    } else {
        if (Serial.available()) {
            char c = Serial.read();
            String to_forward = check_escape_sequence(c);
#if A2MEGA_HAS_FPGA_UART
            if (to_forward.length() > 0) {
                for (int i = 0; i < to_forward.length(); i++) {
                    Serial1.write(to_forward.charAt(i));
                }
            }
#else
            (void)to_forward;
#endif
        }

#if A2MEGA_HAS_FPGA_UART
        if (Serial1.available()) {
            char c1 = (char)Serial1.read();
            Serial.write(c1);
            // Tee FPGA debug-UART lines into the telnet console: the only
            // FPGA-status channel that works while the monitor owns USB-C.
            static char fline[96];   // PSRAM test status lines are 63 chars
            static uint8_t flen = 0;
            if (c1 == '\n' || flen >= sizeof(fline) - 1) {
                if (flen > 0) {
                    fline[flen] = '\0';
                    telnetd_console_tee(fline);
                    wedge_watch_line(fline);
                    flen = 0;
                }
            } else if (c1 != '\r') {
                fline[flen++] = c1;
            }
        }
#endif
    }

    vTaskDelay(1);
}
