// fpga_link.c
// Thread-safe FPGA link layer over the a2spi Octal SPI service.

#include "fpga_link.h"
#include "a2fpga_spi_service.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_log.h"

static const char *TAG = "fpga_link";

static SemaphoreHandle_t s_lock;
static bool s_ok;

void fpga_link_lock(void)   { if (s_lock) xSemaphoreTakeRecursive(s_lock, portMAX_DELAY); }
void fpga_link_unlock(void) { if (s_lock) xSemaphoreGiveRecursive(s_lock); }

bool fpga_link_init(void)
{
    if (!s_lock)
        s_lock = xSemaphoreCreateRecursiveMutex();

    uint8_t id[4] = {0};
    fpga_link_lock();
    for (int i = 0; i < 4; i++)
        a2spi_reg_read(A2REG_DEVICE_ID0 + i, &id[i]);
    // First STATUS read latches "MCU alive" in the FPGA (reset-hold policy)
    uint8_t status = 0;
    a2spi_reg_read(A2REG_STATUS, &status);
    fpga_link_unlock();

    s_ok = (id[0] == 'A' && id[1] == '2' && id[2] == 'F' && id[3] == 'P');
    ESP_LOGI(TAG, "FPGA id %c%c%c%c status %02x -> %s",
             id[0], id[1], id[2], id[3], status, s_ok ? "OK" : "NOT FOUND");
    return s_ok;
}

bool fpga_link_ok(void) { return s_ok; }

uint8_t fpga_reg_read(uint8_t reg)
{
    uint8_t v = 0;
    fpga_link_lock();
    a2spi_reg_read(reg, &v);
    fpga_link_unlock();
    return v;
}

void fpga_reg_write(uint8_t reg, uint8_t val)
{
    fpga_link_lock();
    a2spi_reg_write(reg, val);
    fpga_link_unlock();
}

uint32_t fpga_reg_read32(uint8_t reg_base)
{
    uint32_t v = 0;
    fpga_link_lock();
    for (int i = 0; i < 4; i++) {
        uint8_t b = 0;
        a2spi_reg_read(reg_base + i, &b);
        v |= ((uint32_t)b) << (8 * i);
    }
    fpga_link_unlock();
    return v;
}

void fpga_reg_write16(uint8_t reg_base, uint16_t val)
{
    fpga_link_lock();
    a2spi_reg_write(reg_base, val & 0xFF);
    a2spi_reg_write(reg_base + 1, (val >> 8) & 0xFF);
    fpga_link_unlock();
}

void fpga_reg_write32(uint8_t reg_base, uint32_t val)
{
    fpga_link_lock();
    for (int i = 0; i < 4; i++)
        a2spi_reg_write(reg_base + i, (val >> (8 * i)) & 0xFF);
    fpga_link_unlock();
}

bool fpga_mem_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len)
{
    fpga_link_lock();
    esp_err_t err = a2spi_xfer_write(space, addr, data, len, true);
    fpga_link_unlock();
    return err == ESP_OK;
}

bool fpga_mem_read(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len)
{
    fpga_link_lock();
    esp_err_t err = a2spi_xfer_read(space, addr, out, len, true);
    fpga_link_unlock();
    return err == ESP_OK;
}

void fpga_pad_poll(fpga_pad_state_t *out)
{
    fpga_link_lock();
    uint8_t st = 0, b0 = 0, b1 = 0;
    a2spi_reg_read(A2REG_PAD_STATUS, &st);
    a2spi_reg_read(A2REG_PAD_BTNS0, &b0);
    a2spi_reg_read(A2REG_PAD_BTNS1, &b1);
    fpga_link_unlock();

    out->present    = (st & 0x03) != A2PAD_TYPE_NONE;
    out->is_pad     = (st & 0x03) == A2PAD_TYPE_PAD;
    out->report_cnt = (st >> 4) & 0x0F;
    out->buttons    = (uint16_t)b0 | ((uint16_t)(b1 & 0x03) << 8);
}
