// esp32_s3_spi_link.h
#pragma once
#include "driver/spi_master.h"
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    spi_device_handle_t dev;
    spi_host_device_t host;
    bool use_sync;   // send A5 5A
    bool bus_owner;  // true if we initialized the bus
} spi_link_t;

esp_err_t spi_link_init(spi_link_t *link,
                        spi_host_device_t host, // SPI2_HOST is fine on S3
                        int sclk_io, int mosi_io, int miso_io,
                        int clock_hz);          // e.g., 20*1000*1000

esp_err_t spi_link_cleanup(spi_link_t *link);


// --- register access (1 byte registers 0..126) ---
esp_err_t spi_reg_write(spi_link_t *l, uint8_t reg, uint8_t val);
esp_err_t spi_reg_read (spi_link_t *l, uint8_t reg, uint8_t *val);

// Same as spi_reg_read but also returns the STATUS byte observed during header
esp_err_t spi_reg_read_status(spi_link_t *l, uint8_t reg, uint8_t *val, uint8_t *status);

// --- variable-length XFER via reg 127 ---
esp_err_t spi_xfer_write(spi_link_t *l,
                         uint8_t space, uint32_t addr,
                         const uint8_t *data, uint16_t len, bool inc_addr);

esp_err_t spi_xfer_read (spi_link_t *l,
                         uint8_t space, uint32_t addr,
                         uint8_t *out, uint16_t len, bool inc_addr);

// XFER read variant exposing STATUS returned during header
esp_err_t spi_xfer_read_status (spi_link_t *l,
                         uint8_t space, uint32_t addr,
                         uint8_t *out, uint16_t len, bool inc_addr,
                         uint8_t *status);

#ifdef __cplusplus
}
#endif
