/*
 * A2FPGA ESP32-S3 Firmware (Simplified)
 *
 * Minimal firmware for ESP32-S3 to FPGA communication via Octal SPI.
 * This version excludes LCD_CAM, radio, tone generator, and ES5503 emulation.
 *
 * Features:
 *   - Octal SPI (8-bit parallel) communication with FPGA
 *   - USB JTAG bridge for FPGA programming
 *   - Serial forwarding to FPGA
 *   - CLI mode for diagnostics (enter with "+++")
 *
 * Board: ESP32-S3 (Adafruit QT Py ESP32-S3 or similar)
 *
 * Arduino IDE Settings:
 *   - Board: ESP32S3 Dev Module or Adafruit QT Py ESP32-S3
 *   - USB Mode: Hardware CDC and JTAG
 *   - USB CDC On Boot: Enabled
 *   - CPU Frequency: 240MHz
 */

#include <Arduino.h>
#include "driver/gpio.h"
#include "soc/usb_serial_jtag_reg.h"
#include "a2fpga_jtag.h"
#include "a2fpga_spi_service.h"
#include "esp_err.h"
#include <ctype.h>
#include <stdlib.h>

// ============================================================================
// Pin Assignments (DUMMY - Replace with actual hardware pins)
// ============================================================================

// LEDs
#define PIN_LED0 1
#define PIN_LED1 2

#define LED_ON  HIGH
#define LED_OFF LOW

// Serial interface to the FPGA
#define PIN_RXD  44
#define PIN_TXD  43
#define BAUD 115200

// Configuration done signal from the FPGA
#define PIN_FPGA_DONE  48

// JTAG interface to the FPGA
const int PIN_TCK  = 40;
const int PIN_TMS  = 41;
const int PIN_TDI  = 42;
const int PIN_TDO  = 45;
const int PIN_SRST = 3;  // unused and unconnected, but required by the JTAG bridge

// Octal SPI interface to the FPGA
static const ospi_pins_t OSPI_PINS = {
    .sclk = 47,      // SPI Clock
    .d0   = 1,     // Data bit 0 (MOSI in standard SPI mode)
    .d1   = 2,     // Data bit 1 (MISO in standard SPI mode)
    .d2   = 4,     // Data bit 2
    .d3   = 5,     // Data bit 3
    .d4   = 6,     // Data bit 4
    .d5   = 7,     // Data bit 5
    .d6   = 8,     // Data bit 6
    .d7   = 9,     // Data bit 7
    .cs   = -1,     // Chip select (-1 if directly controlled)
};

static const int SPI_HZ = 20 * 1000 * 1000;  // 20 MHz SPI clock

// ============================================================================
// Global State
// ============================================================================

bool usb_was_connected = false;

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
        Serial.printf("  LED0: %d\n", PIN_LED0);

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
// Arduino Setup and Loop
// ============================================================================

void setup() {
    Serial.begin(115200);
    Serial1.begin(BAUD, SERIAL_8N1, PIN_RXD, PIN_TXD);
    delay(300);

    Serial.printf("A2FPGA ESP32-S3 Firmware (%s %s)\n", __DATE__, __TIME__);
    Serial.println("Simplified version with Octal SPI support");
    Serial.println("Serial forwarding mode active. Use '+++' to enter CLI mode.");

    cli_mode = false;

    pinMode(PIN_FPGA_DONE, INPUT_PULLUP);
    pinMode(PIN_LED0, OUTPUT);
}

void loop() {
    digitalWrite(PIN_LED0, digitalRead(PIN_FPGA_DONE));

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
            cmd_process(s);
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
