// a2fpga_spi_service.h
// High-level SPI service wrapper for FPGA communication
#pragma once

#include "a2fpga_ospi_link.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Octal SPI link once and keep it for the lifetime of the app.
// Returns ESP_OK if ready, or an ESP_ERR_* on failure.
esp_err_t a2spi_init_once(spi_host_device_t host, const ospi_pins_t *pins, int clock_hz);

// Optional: deinit at shutdown (not required for typical Arduino usage)
esp_err_t a2spi_deinit(void);

// Query readiness
bool a2spi_is_ready(void);

// Check if running in octal mode
bool a2spi_is_octal(void);

// Accessors
spi_device_handle_t a2spi_device(void);

// Basic register ops
esp_err_t a2spi_reg_write(uint8_t reg, uint8_t val);
esp_err_t a2spi_reg_read(uint8_t reg, uint8_t *val);
esp_err_t a2spi_reg_read_status(uint8_t reg, uint8_t *val, uint8_t *status);

// XFER ops (reg 127 portal)
esp_err_t a2spi_xfer_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len, bool inc_addr);
esp_err_t a2spi_xfer_read(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len, bool inc_addr);
esp_err_t a2spi_xfer_read_status(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len, bool inc_addr, uint8_t *status);

#ifdef __cplusplus
}
#endif
