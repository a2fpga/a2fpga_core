// a2fpga_spi_service.c
#include "a2fpga_spi_service.h"
#include <string.h>

static spi_link_t s_link;
static bool s_inited = false;

esp_err_t a2spi_init_once(spi_host_device_t host, int sclk, int mosi, int miso, int clock_hz)
{
    if (s_inited && s_link.dev) return ESP_OK;
    memset(&s_link, 0, sizeof(s_link));
    esp_err_t err = spi_link_init(&s_link, host, sclk, mosi, miso, clock_hz);
    if (err == ESP_OK) {
        s_link.use_sync = true; // include A5 5A on every header
        s_inited = true;
    }
    return err;
}

esp_err_t a2spi_deinit(void)
{
    if (!s_inited) return ESP_OK;
    esp_err_t err = spi_link_cleanup(&s_link);
    s_inited = false;
    return err;
}

bool a2spi_is_ready(void)
{
    return s_inited && s_link.dev != NULL;
}

spi_device_handle_t a2spi_device(void)
{
    return s_link.dev;
}

esp_err_t a2spi_reg_write(uint8_t reg, uint8_t val)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_reg_write(&s_link, reg, val);
}

esp_err_t a2spi_reg_read(uint8_t reg, uint8_t *val)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_reg_read(&s_link, reg, val);
}

esp_err_t a2spi_reg_read_status(uint8_t reg, uint8_t *val, uint8_t *status)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_reg_read_status(&s_link, reg, val, status);
}

esp_err_t a2spi_xfer_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len, bool inc_addr)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_xfer_write(&s_link, space, addr, data, len, inc_addr);
}

esp_err_t a2spi_xfer_read(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len, bool inc_addr)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_xfer_read(&s_link, space, addr, out, len, inc_addr);
}

esp_err_t a2spi_xfer_read_status(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len, bool inc_addr, uint8_t *status)
{
    if (!a2spi_is_ready()) return ESP_ERR_INVALID_STATE;
    return spi_xfer_read_status(&s_link, space, addr, out, len, inc_addr, status);
}

