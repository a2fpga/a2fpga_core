// esp32_s3_spi_link.c
#include "a2fpga_spi_link.h"
#include "esp_log.h"
#include "esp_check.h"

static const char* TAG = "spi_link";

static inline uint8_t sub0_byte(bool dir_read, uint8_t space, bool inc, bool with_crc) {
    // SUB0: [0]DIR [3:1]SPACE [4]INC [5]CRC [6]RES [7]BUS(0)
    return (dir_read ? 1 : 0)
         | ((space & 0x7) << 1)
         | (inc ? (1<<4) : 0)
         | (with_crc ? (1<<5) : 0);
}

esp_err_t spi_link_init(spi_link_t *l, spi_host_device_t host,
                        int sclk_io, int mosi_io, int miso_io, int clock_hz)
{
    memset(l, 0, sizeof(*l));
    l->use_sync = true;
    l->host = host;

    spi_bus_config_t bus = {
        .mosi_io_num = mosi_io,
        .miso_io_num = miso_io,
        .sclk_io_num = sclk_io,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4096,
    };
    esp_err_t err = spi_bus_initialize(host, &bus, SPI_DMA_CH_AUTO);
    if (err == ESP_ERR_INVALID_STATE) {
        // Bus already initialized; continue
        l->bus_owner = false;
        ESP_LOGW(TAG, "bus already initialized; reusing");
    } else {
        ESP_RETURN_ON_ERROR(err, TAG, "bus init");
        l->bus_owner = true;
    }

    spi_device_interface_config_t dev = {
        .clock_speed_hz = clock_hz,
        .mode = 0,
        .spics_io_num = -1,           // <-- no CS
        .queue_size = 4,
        .flags = 0 /* explicit MSB-first */,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(host, &dev, &l->dev), TAG, "add dev");
    return ESP_OK;
}

esp_err_t spi_link_cleanup(spi_link_t *l) {
    esp_err_t err = ESP_OK;
    if (l->dev) {
        err = spi_bus_remove_device(l->dev);
        l->dev = NULL;
    }
    if (l->bus_owner) {
        esp_err_t bus_err = spi_bus_free(l->host);
        if (err == ESP_OK) err = bus_err;
        l->bus_owner = false;
    }
    return err;
}

// Send a small buffer and optionally receive same length into rx (can be NULL).
static esp_err_t xfer(spi_device_handle_t dev, const void *tx, void *rx, size_t n) {
    spi_transaction_t t = {0};
    t.length    = n * 8;
    t.tx_buffer = tx;
    t.rx_buffer = rx;
    return spi_device_transmit(dev, &t);
}


esp_err_t spi_reg_write(spi_link_t *l, uint8_t reg, uint8_t val) {
    if (reg >= 127) return ESP_ERR_INVALID_ARG;
    uint8_t buf[1 + 1 + 1]; // [sync?] opcode + payload
    size_t o = 0;
    if (l->use_sync) { buf[o++] = 0xA5; buf[o++] = 0x5A; }
    uint8_t opcode = (0 << 7) | (reg & 0x7F);
    buf[o++] = opcode;
    // header phase
    ESP_RETURN_ON_ERROR(xfer(l->dev, buf, NULL, o), TAG, "hdr");
    // payload
    return xfer(l->dev, &val, NULL, 1);
}

esp_err_t spi_reg_read(spi_link_t *l, uint8_t reg, uint8_t *val) {
    if (!val || reg >= 127) return ESP_ERR_INVALID_ARG;
    uint8_t tx[1 + 1 + 1 + 1]; // [sync?] opcode + 1 dummy
    uint8_t rx[sizeof(tx)] = {0};
    size_t o = 0;
    if (l->use_sync) { tx[o++] = 0xA5; tx[o++] = 0x5A; }
    tx[o++] = (uint8_t)((1 << 7) | (reg & 0x7F));
    tx[o++] = 0x00; // dummy to clock out data in same transaction

    // Best-effort resync before header
    ESP_RETURN_ON_ERROR(xfer(l->dev, tx, rx, o), TAG, "hdr+val");
    // Check status (if sync used)
    if (l->use_sync) {
        uint8_t st = rx[o-2];
        uint8_t ok = (st & 0x01);
        uint8_t ver = (st >> 4) & 0x0F;
        if (!ok || ver != 0x1) {
            // Retry once after a tiny delay
            vTaskDelay(1);
            memset(rx, 0, sizeof(rx));
            ESP_RETURN_ON_ERROR(xfer(l->dev, tx, rx, o), TAG, "retry hdr+val");
        }
    }
    *val = rx[o-1];
    return ESP_OK;
}

esp_err_t spi_reg_read_status(spi_link_t *l, uint8_t reg, uint8_t *val, uint8_t *status_out) {
    if (!val || reg >= 127) return ESP_ERR_INVALID_ARG;
    uint8_t tx[1 + 1 + 1 + 1];
    uint8_t rx[sizeof(tx)] = {0};
    size_t o = 0;
    if (l->use_sync) { tx[o++] = 0xA5; tx[o++] = 0x5A; }
    tx[o++] = (uint8_t)((1 << 7) | (reg & 0x7F));
    tx[o++] = 0x00;

    ESP_RETURN_ON_ERROR(xfer(l->dev, tx, rx, o), TAG, "hdr+val");
    if (status_out) *status_out = rx[o-2];
    *val = rx[o-1];
    return ESP_OK;
}

esp_err_t spi_xfer_write(spi_link_t *l,
                         uint8_t space, uint32_t addr,
                         const uint8_t *data, uint16_t len, bool inc_addr)
{
    if ((len == 0) || !data) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[2 + 1 + 1 + 3 + 2]; // sync + opcode + sub0 + addr24 + len16
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;                                 // reg 127 (opcode R/W bit ignored by core)
    hdr[o++] = sub0_byte(false, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    // header
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, NULL, o), TAG, "xfer-w hdr");
    // payload (write)
    return xfer(l->dev, data, NULL, len);
}

esp_err_t spi_xfer_read(spi_link_t *l,
                        uint8_t space, uint32_t addr,
                        uint8_t *out, uint16_t len, bool inc_addr)
{
    if ((len == 0) || !out) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[2 + 1 + 1 + 3 + 2];
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;
    hdr[o++] = sub0_byte(true, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    // send header and capture status
    uint8_t status_hdr[sizeof(hdr)] = {0};
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, status_hdr, o), TAG, "xfer-r hdr");
    if (l->use_sync) {
        uint8_t st = status_hdr[o-1];
        uint8_t ok = (st & 0x01);
        uint8_t ver = (st >> 4) & 0x0F;
        if (!ok || ver != 0x1) {
            // Retry header once
            vTaskDelay(1);
            memset(status_hdr, 0, sizeof(status_hdr));
            ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, status_hdr, o), TAG, "retry xfer-r hdr");
        }
    }

    // one dummy byte before first data
    uint8_t d = 0, toss = 0;
    ESP_RETURN_ON_ERROR(xfer(l->dev, &d, &toss, 1), TAG, "xfer-r dummy");

    // now clock out 'len' data bytes (TX dummies, RX data)
    // to avoid allocating a dummy array, do it in chunks
    const int CHUNK = 1024;
    uint8_t tx_dummy[16] = {0}; // reused; device will repeat this block
    size_t remaining = len;
    uint8_t *p = out;
    while (remaining) {
        size_t blk = remaining < sizeof(tx_dummy) ? remaining : sizeof(tx_dummy);
        spi_transaction_t t = {0};
        t.length    = blk * 8;
        t.tx_buffer = tx_dummy;
        t.rx_buffer = p;
        ESP_RETURN_ON_ERROR(spi_device_transmit(l->dev, &t), TAG, "data");
        p += blk;
        remaining -= blk;
    }
    return ESP_OK;
}

esp_err_t spi_xfer_read_status (spi_link_t *l,
                        uint8_t space, uint32_t addr,
                        uint8_t *out, uint16_t len, bool inc_addr,
                        uint8_t *status_out)
{
    if ((len == 0) || !out) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[2 + 1 + 1 + 3 + 2];
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;
    hdr[o++] = sub0_byte(true, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    uint8_t status[9] = {0};
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, status, o), TAG, "xfer-r hdr");
    if (status_out) *status_out = status[o-1];
    if (l->use_sync) {
        uint8_t ok = (status[o-1] & 0x01);
        uint8_t ver = (status[o-1] >> 4) & 0x0F;
        if (!ok || ver != 0x1) {
            // Retry header once
            vTaskDelay(1);
            memset(status, 0, sizeof(status));
            ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, status, o), TAG, "retry xfer-r hdr");
            if (status_out) *status_out = status[o-1];
        }
    }

    // one dummy byte before first data
    uint8_t d = 0, toss = 0;
    ESP_RETURN_ON_ERROR(xfer(l->dev, &d, &toss, 1), TAG, "xfer-r dummy");

    uint8_t tx_dummy[16] = {0};
    size_t remaining = len; uint8_t *p = out;
    while (remaining) {
        size_t blk = remaining < sizeof(tx_dummy) ? remaining : sizeof(tx_dummy);
        spi_transaction_t t = {0};
        t.length    = blk * 8;
        t.tx_buffer = tx_dummy;
        t.rx_buffer = p;
        ESP_RETURN_ON_ERROR(spi_device_transmit(l->dev, &t), TAG, "data");
        p += blk; remaining -= blk;
    }
    return ESP_OK;
}
