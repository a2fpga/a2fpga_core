// a2fpga_ospi_link.h
// Octal SPI (8-bit parallel) link for ESP32-S3 to FPGA communication
#pragma once

#include "driver/spi_master.h"
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Octal SPI pin configuration
typedef struct {
    int sclk;       // Clock
    int d0;         // Data bit 0
    int d1;         // Data bit 1
    int d2;         // Data bit 2
    int d3;         // Data bit 3
    int d4;         // Data bit 4
    int d5;         // Data bit 5
    int d6;         // Data bit 6
    int d7;         // Data bit 7
    int cs;         // Chip select (-1 if not used)
} ospi_pins_t;

typedef struct {
    spi_device_handle_t dev;
    spi_host_device_t host;
    ospi_pins_t pins;
    bool use_sync;      // Send A5 5A sync pattern
    bool bus_owner;     // true if we initialized the bus
    bool octal_mode;    // true for 8-bit mode, false for standard SPI fallback
} ospi_link_t;

// Initialize Octal SPI link
esp_err_t ospi_link_init(ospi_link_t *link,
                         spi_host_device_t host,
                         const ospi_pins_t *pins,
                         int clock_hz);

// Cleanup and release resources
esp_err_t ospi_link_cleanup(ospi_link_t *link);

// --- Register access (1 byte registers 0..126) ---
esp_err_t ospi_reg_write(ospi_link_t *l, uint8_t reg, uint8_t val);
esp_err_t ospi_reg_read(ospi_link_t *l, uint8_t reg, uint8_t *val);

// Same as ospi_reg_read but also returns the STATUS byte observed during header
esp_err_t ospi_reg_read_status(ospi_link_t *l, uint8_t reg, uint8_t *val, uint8_t *status);

// --- Variable-length XFER via reg 127 ---
esp_err_t ospi_xfer_write(ospi_link_t *l,
                          uint8_t space, uint32_t addr,
                          const uint8_t *data, uint16_t len, bool inc_addr);

esp_err_t ospi_xfer_read(ospi_link_t *l,
                         uint8_t space, uint32_t addr,
                         uint8_t *out, uint16_t len, bool inc_addr);

// XFER read variant exposing STATUS returned during header
esp_err_t ospi_xfer_read_status(ospi_link_t *l,
                                uint8_t space, uint32_t addr,
                                uint8_t *out, uint16_t len, bool inc_addr,
                                uint8_t *status);

#ifdef __cplusplus
}
#endif
