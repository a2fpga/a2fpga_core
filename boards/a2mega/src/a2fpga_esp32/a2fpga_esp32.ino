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
 * Board: a2mega (ESP32-S3-MINI-1-N8, 8 MB flash, no PSRAM)
 *
 * Arduino IDE Settings:
 *   - Board: ESP32S3 Dev Module
 *   - USB Mode: Hardware CDC and JTAG
 *   - USB CDC On Boot: Enabled
 *   - CPU Frequency: 240MHz
 */

#include <Arduino.h>
#include <SD_MMC.h>
#include "driver/gpio.h"
#include "soc/usb_serial_jtag_reg.h"
#include "a2fpga_jtag.h"
#include "a2fpga_spi_service.h"
#include "a2fpga_regs.h"
#include "fpga_link.h"
#include "fpga_screen.h"
#include "osd_console.h"
#include "settings.h"
#include "disk.h"
#include "menu.h"
#include "w5100.h"
#include "wifi_bridge.h"
#include "fpgaupdate.h"
#include "esp_err.h"
#include <ctype.h>
#include <stdlib.h>

// ============================================================================
// Pin Assignments (a2-mega schematic p.3, "ESP32 & I/O")
// ============================================================================

// Serial interface to the FPGA
#define PIN_RXD  44
#define PIN_TXD  43
#define BAUD 115200

// Configuration done signal from the FPGA
#define PIN_FPGA_DONE  48

// JTAG interface to the FPGA (shared: USB bridge and fpga_jtag.c self-update)
const int PIN_TCK  = 40;
const int PIN_TMS  = 41;
const int PIN_TDI  = 42;
const int PIN_TDO  = 45;
const int PIN_SRST = 3;  // unused and unconnected, but required by the JTAG bridge

// Micro-SD slot (4-bit SDMMC)
#define PIN_SD_CLK  37
#define PIN_SD_CMD  36
#define PIN_SD_D0   38
#define PIN_SD_D1   39
#define PIN_SD_D2   35   // verify at bring-up (schematic pin 31 net inferred)
#define PIN_SD_D3   34
#define PIN_SD_DET  46   // low when a card is inserted

// Octal SPI interface to the FPGA
static const ospi_pins_t OSPI_PINS = {
    .sclk = 47,     // ESP32_OPI_CLK
    .d0   = 1,      // ESP32_OPI_D0
    .d1   = 2,
    .d2   = 4,
    .d3   = 5,
    .d4   = 6,
    .d5   = 7,
    .d6   = 8,
    .d7   = 9,
    .cs   = -1,     // no CS — the protocol uses sync-pattern framing
};

static const int SPI_HZ = 4 * 1000 * 1000;  // reg path is clean at 8 MHz but
                                             // XFER payload reads outrun the
                                             // proto's 1-byte read pipeline
                                             // above ~4 MHz (FF fill) — add a
                                             // fabric-side prefetch to go higher  // 10 MHz for bring-up: the FPGA read
                                             // pipeline (2 cycles @ 54 MHz) is marginal
                                             // against back-to-back 20 MHz RX byte slots

// ============================================================================
// Global State
// ============================================================================

bool usb_was_connected = false;
static bool sd_mounted = false;
static bool subsystems_up = false;

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

    } else if (cmd == "spiinit") {
        Serial.println("[SPI] Initializing Octal SPI...");
        esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
        if (err == ESP_OK) {
            Serial.printf("[SPI] Initialized: %s mode @ %d Hz\n",
                         a2spi_is_octal() ? "OCTAL" : "STANDARD", SPI_HZ);
        } else {
            Serial.printf("[SPI] Init failed: %s\n", esp_err_to_name(err));
        }

    } else if (cmd == "spitest") {
        Serial.println("[SPI] Running SPI test...");

        if (!a2spi_is_ready()) {
            esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
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
                esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
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
            esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
            if (err != ESP_OK) {
                Serial.printf("viddbg: init error: %s\n", esp_err_to_name(err));
                return;
            }
        }
        uint8_t v[8];
        for (int i = 0; i < 8; i++) {
            uint8_t st = 0;
            esp_err_t err = a2spi_reg_read_status((uint8_t)(0x70 + i), &v[i], &st);
            if (err != ESP_OK) {
                Serial.printf("viddbg: read 0x%02X error: %s\n", 0x70 + i, esp_err_to_name(err));
                return;
            }
        }
        Serial.printf("mode 0x%02X: use_vgc=%d SHRG=%d LINEAR=%d STORE80=%d PAGE2=%d MIXED=%d HIRES=%d TEXT=%d\n",
                      v[0], !!(v[0] & 0x80), !!(v[0] & 0x40), !!(v[0] & 0x20), !!(v[0] & 0x10),
                      !!(v[0] & 0x08), !!(v[0] & 0x04), !!(v[0] & 0x02), !!(v[0] & 0x01));
        Serial.printf("C029 writes=%u last=0x%02X\n", v[1], v[2]);
        Serial.printf("vgc missed hsync/frame=%u  shadow-write drops=%u (sticky)\n", v[3], v[4]);
        Serial.printf("fb flags=0x%02X  ddr3 resp-fifo overflow=0x%02X (bit=port, sticky)\n", v[5], v[6]);
        Serial.printf("shadow rd fsm=0x%02X: pending=%d is_vgc=%d cache_valid=%d state=%d\n",
                      v[7], !!(v[7] & 0x80), !!(v[7] & 0x40), !!(v[7] & 0x20), v[7] & 0x07);

    } else if (cmd.startsWith("spir ")) {
        String toks[16];
        int nt = split_ws(cmd, toks, 16);
        if (nt < 4) {
            Serial.println("Usage: spir <space> <addr> <len> [inc=1]");
        } else {
            if (!a2spi_is_ready()) {
                esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
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
                esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
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
        Serial.println("Serial:");
        Serial.printf("  RXD:  %d\n", PIN_RXD);
        Serial.printf("  TXD:  %d\n", PIN_TXD);
        Serial.println("Other:");
        Serial.printf("  FPGA_DONE: %d\n", PIN_FPGA_DONE);
        Serial.printf("  SD:   CLK=%d CMD=%d D0=%d D1=%d D2=%d D3=%d DET=%d\n",
                      PIN_SD_CLK, PIN_SD_CMD, PIN_SD_D0, PIN_SD_D1, PIN_SD_D2, PIN_SD_D3, PIN_SD_DET);

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
            for (int i = 0; i < escape_buffer.length(); i++) {
                Serial1.write(escape_buffer.charAt(i));
            }
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
        disk_poll();
        fpgaupdate_poll();
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

static void start_subsystems() {
    if (subsystems_up)
        return;

    esp_err_t err = a2spi_init_once(SPI2_HOST, &OSPI_PINS, SPI_HZ);
    if (err != ESP_OK) {
        Serial.printf("[SPI] init failed: %s\n", esp_err_to_name(err));
        return;
    }
    if (!fpga_link_init()) {
        Serial.println("[fpga] no A2FP device on the OSPI link; retrying later");
        return;
    }

    settings_init();
    sd_mounted = mount_sd();

    osd_console_show();
    osd_log("A2MEGA ESP32 %s %s", __DATE__, __TIME__);
    osd_log(sd_mounted ? "SD CARD MOUNTED" : "NO SD CARD");

    disk_init();
    menu_init();
    w5100_init();

    if (sd_mounted)
        load_wifi_credentials();
    a2_settings_t *s = settings();
    if (s->wifi_ssid[0]) {
        wifi_bridge_config_ip(s->dhcp_enable != 0, s->static_ip,
                              s->static_mask, s->static_gw);
        if (wifi_bridge_init(s->wifi_ssid, s->wifi_psk))
            osd_log("WIFI: JOINING %s (%s)", s->wifi_ssid,
                    s->dhcp_enable ? "DHCP" : "STATIC IP");
        else
            osd_log("WIFI: INIT FAILED");
    } else {
        osd_log("WIFI: NOT CONFIGURED (WIFI.TXT)");
    }

    xTaskCreatePinnedToCore(disk_task, "disk", 8192, NULL, 5, NULL, 1);
    xTaskCreatePinnedToCore(menu_task, "menu", 8192, NULL, 4, NULL, 1);

    subsystems_up = true;
    Serial.println("[a2fpga] subsystems up");
}

// ============================================================================
// Arduino Setup and Loop
// ============================================================================

void setup() {
    Serial.begin(115200);
    Serial1.begin(BAUD, SERIAL_8N1, PIN_RXD, PIN_TXD);
    delay(300);

    Serial.printf("A2FPGA ESP32-S3 Firmware (%s %s)\n", __DATE__, __TIME__);
    Serial.println("a2mega co-processor: menu, SD disk serving, WiFi bridge");
    Serial.println("Serial forwarding mode active. Use '+++' to enter CLI mode.");

    cli_mode = false;

    pinMode(PIN_FPGA_DONE, INPUT_PULLUP);

    start_subsystems();
}

void loop() {
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

    // Handle USB JTAG connection changes
    bool usb_is_connected = usb_serial_jtag_is_connected();
    if (usb_was_connected == false && usb_is_connected == true)
        route_usb_jtag_to_gpio();
    if (usb_was_connected == true && usb_is_connected == false)
        unroute_usb_jtag_to_gpio();
    usb_was_connected = usb_is_connected;

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
            if (to_forward.length() > 0) {
                for (int i = 0; i < to_forward.length(); i++) {
                    Serial1.write(to_forward.charAt(i));
                }
            }
        }

        if (Serial1.available()) {
            Serial.write(Serial1.read());
        }
    }

    vTaskDelay(1);
}
