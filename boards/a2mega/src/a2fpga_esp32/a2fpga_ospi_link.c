// a2fpga_ospi_link.c
// Octal SPI (8-bit parallel) link implementation for ESP32-S3
//
// Note: ESP32-S3 supports Octal SPI via the SPI_LL layer. This implementation
// uses the standard SPI master driver with octal mode configuration.
// For full hardware octal SPI, the ESP-IDF must be configured appropriately.

#include "a2fpga_ospi_link.h"
#include "esp_log.h"
#include "esp_check.h"
#include "driver/gpio.h"

static const char* TAG = "ospi_link";

// Build SUB0 byte for XFER protocol
static inline uint8_t sub0_byte(bool dir_read, uint8_t space, bool inc, bool with_crc) {
    // SUB0: [0]DIR [3:1]SPACE [4]INC [5]CRC [6]RES [7]BUS(0)
    return (dir_read ? 1 : 0)
         | ((space & 0x7) << 1)
         | (inc ? (1<<4) : 0)
         | (with_crc ? (1<<5) : 0);
}

esp_err_t ospi_link_init(ospi_link_t *l, spi_host_device_t host,
                         const ospi_pins_t *pins, int clock_hz)
{
    memset(l, 0, sizeof(*l));
    l->use_sync = true;
    l->host = host;
    l->pins = *pins;

    // Configure SPI bus
    // For octal SPI, we configure with all 8 data lines
    // ESP32-S3 SPI master can support octal mode via the flags
    spi_bus_config_t bus = {
        .mosi_io_num = pins->d0,        // D0 acts as MOSI in standard mode
        .miso_io_num = pins->d1,        // D1 acts as MISO in standard mode
        .sclk_io_num = pins->sclk,
        .quadwp_io_num = pins->d2,      // D2 (WP in quad mode)
        .quadhd_io_num = pins->d3,      // D3 (HD in quad mode)
        .data4_io_num = pins->d4,       // D4 for octal
        .data5_io_num = pins->d5,       // D5 for octal
        .data6_io_num = pins->d6,       // D6 for octal
        .data7_io_num = pins->d7,       // D7 for octal
        .max_transfer_sz = 4096,
        .flags = SPICOMMON_BUSFLAG_OCTAL,
    };

    esp_err_t err = spi_bus_initialize(host, &bus, SPI_DMA_CH_AUTO);
    if (err == ESP_ERR_INVALID_STATE) {
        // Bus already initialized; continue
        l->bus_owner = false;
        ESP_LOGW(TAG, "bus already initialized; reusing");
    } else if (err == ESP_ERR_NOT_SUPPORTED) {
        // Octal mode not supported, fall back to standard SPI
        ESP_LOGW(TAG, "Octal SPI not supported, falling back to standard SPI");
        l->octal_mode = false;

        // Reconfigure for standard SPI
        spi_bus_config_t std_bus = {
            .mosi_io_num = pins->d0,
            .miso_io_num = pins->d1,
            .sclk_io_num = pins->sclk,
            .quadwp_io_num = -1,
            .quadhd_io_num = -1,
            .max_transfer_sz = 4096,
        };
        err = spi_bus_initialize(host, &std_bus, SPI_DMA_CH_AUTO);
        if (err == ESP_ERR_INVALID_STATE) {
            l->bus_owner = false;
        } else {
            ESP_RETURN_ON_ERROR(err, TAG, "std bus init");
            l->bus_owner = true;
        }
    } else {
        ESP_RETURN_ON_ERROR(err, TAG, "bus init");
        l->bus_owner = true;
        l->octal_mode = true;
    }

    // Configure device
    spi_device_interface_config_t dev = {
        .clock_speed_hz = clock_hz,
        .mode = 0,
        .spics_io_num = pins->cs,
        .queue_size = 4,
        .flags = l->octal_mode ? SPI_DEVICE_HALFDUPLEX : 0,
    };

    ESP_RETURN_ON_ERROR(spi_bus_add_device(host, &dev, &l->dev), TAG, "add dev");

    ESP_LOGI(TAG, "OSPI link initialized: %s mode, %d Hz",
             l->octal_mode ? "octal" : "standard", clock_hz);

    return ESP_OK;
}

esp_err_t ospi_link_cleanup(ospi_link_t *l) {
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

// Send a small buffer and optionally receive same length into rx (can be NULL)
static esp_err_t xfer(spi_device_handle_t dev, const void *tx, void *rx, size_t n, bool octal) {
    spi_transaction_t t = {0};
    t.length = n * 8;
    t.tx_buffer = tx;
    t.rx_buffer = rx;

    if (octal) {
        // For octal mode, use extended transaction with proper flags
        spi_transaction_ext_t ext = {0};
        ext.base = t;
        ext.base.flags = SPI_TRANS_MODE_OCT;
        return spi_device_transmit(dev, (spi_transaction_t*)&ext);
    }

    return spi_device_transmit(dev, &t);
}

// RX-only phase (bus turnaround): clock n bytes with the data lines released
// so the FPGA can drive its response. Octal mode is half-duplex — reads MUST
// be split into a TX header phase and an RX phase; a combined TX+RX
// transaction is rejected by the IDF driver AND would fight the FPGA's
// output drivers on the shared bus.
static esp_err_t xfer_rx(spi_device_handle_t dev, void *rx, size_t n, bool octal) {
    spi_transaction_ext_t ext = {0};
    ext.base.length = 0;
    ext.base.rxlength = n * 8;
    ext.base.rx_buffer = rx;
    if (octal)
        ext.base.flags = SPI_TRANS_MODE_OCT;
    return spi_device_transmit(dev, (spi_transaction_t*)&ext);
}

esp_err_t ospi_reg_write(ospi_link_t *l, uint8_t reg, uint8_t val) {
    if (reg >= 127) return ESP_ERR_INVALID_ARG;

    uint8_t buf[4]; // [sync?] opcode + payload
    size_t o = 0;
    if (l->use_sync) { buf[o++] = 0xA5; buf[o++] = 0x5A; }
    uint8_t opcode = (0 << 7) | (reg & 0x7F);
    buf[o++] = opcode;

    // Header phase
    ESP_RETURN_ON_ERROR(xfer(l->dev, buf, NULL, o, l->octal_mode), TAG, "hdr");
    // Payload
    return xfer(l->dev, &val, NULL, 1, l->octal_mode);
}

// Register read: TX [sync][read-opcode], turnaround, RX [data][status].
// The FPGA drives exactly those two response slots and releases the bus.
static esp_err_t reg_read_once(ospi_link_t *l, uint8_t reg,
                               uint8_t *val, uint8_t *status_out) {
    uint8_t tx[3];
    size_t o = 0;
    if (l->use_sync) { tx[o++] = 0xA5; tx[o++] = 0x5A; }
    tx[o++] = (uint8_t)((1 << 7) | (reg & 0x7F));

    if (l->octal_mode) {
        uint8_t rx[2] = {0};
        ESP_RETURN_ON_ERROR(xfer(l->dev, tx, NULL, o, true), TAG, "rd hdr");
        ESP_RETURN_ON_ERROR(xfer_rx(l->dev, rx, 2, true), TAG, "rd resp");
        *val = rx[0];
        if (status_out) *status_out = rx[1];
    } else {
        // Standard SPI fallback: separate MOSI/MISO lines, full duplex is fine
        uint8_t txf[5], rxf[5] = {0};
        memcpy(txf, tx, o);
        txf[o] = 0x00;
        txf[o+1] = 0x00;
        ESP_RETURN_ON_ERROR(xfer(l->dev, txf, rxf, o + 2, false), TAG, "rd fd");
        *val = rxf[o];
        if (status_out) *status_out = rxf[o+1];
    }
    return ESP_OK;
}

esp_err_t ospi_reg_read(ospi_link_t *l, uint8_t reg, uint8_t *val) {
    if (!val || reg >= 127) return ESP_ERR_INVALID_ARG;

    uint8_t st = 0;
    ESP_RETURN_ON_ERROR(reg_read_once(l, reg, val, &st), TAG, "rd");
    if (l->use_sync) {
        uint8_t ok = (st & 0x01);
        uint8_t ver = (st >> 4) & 0x0F;
        if (!ok || ver != 0x1) {
            // Retry once after a tiny delay (reframing)
            vTaskDelay(1);
            ESP_RETURN_ON_ERROR(reg_read_once(l, reg, val, &st), TAG, "rd retry");
        }
    }
    return ESP_OK;
}

esp_err_t ospi_reg_read_status(ospi_link_t *l, uint8_t reg, uint8_t *val, uint8_t *status_out) {
    if (!val || reg >= 127) return ESP_ERR_INVALID_ARG;
    return reg_read_once(l, reg, val, status_out);
}

esp_err_t ospi_xfer_write(ospi_link_t *l,
                          uint8_t space, uint32_t addr,
                          const uint8_t *data, uint16_t len, bool inc_addr)
{
    if ((len == 0) || !data) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[11]; // sync + opcode + sub0 + addr24 + len16
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;                                 // reg 127
    hdr[o++] = sub0_byte(false, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    // Header
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, NULL, o, l->octal_mode), TAG, "xfer-w hdr");
    // Payload (write)
    return xfer(l->dev, data, NULL, len, l->octal_mode);
}

esp_err_t ospi_xfer_read(ospi_link_t *l,
                         uint8_t space, uint32_t addr,
                         uint8_t *out, uint16_t len, bool inc_addr)
{
    if ((len == 0) || !out) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[11];
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;
    hdr[o++] = sub0_byte(true, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    // TX header, then bus turnaround: the dummy slot carries the status
    // byte, followed by the payload — all driven by the FPGA.
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, NULL, o, l->octal_mode), TAG, "xfer-r hdr");

    uint8_t st = 0;
    ESP_RETURN_ON_ERROR(xfer_rx(l->dev, &st, 1, l->octal_mode), TAG, "xfer-r status");
    if (l->use_sync) {
        uint8_t ok = (st & 0x01);
        uint8_t ver = (st >> 4) & 0x0F;
        if (!ok || ver != 0x1)
            return ESP_ERR_INVALID_RESPONSE;   // caller retries the whole op
    }

    return xfer_rx(l->dev, out, len, l->octal_mode);
}

esp_err_t ospi_xfer_read_status(ospi_link_t *l,
                                uint8_t space, uint32_t addr,
                                uint8_t *out, uint16_t len, bool inc_addr,
                                uint8_t *status_out)
{
    if ((len == 0) || !out) return ESP_ERR_INVALID_ARG;

    uint8_t hdr[11];
    size_t o = 0;
    if (l->use_sync) { hdr[o++] = 0xA5; hdr[o++] = 0x5A; }
    hdr[o++] = 0x7F;
    hdr[o++] = sub0_byte(true, space, inc_addr, false);
    hdr[o++] = (uint8_t)(addr & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 8) & 0xFF);
    hdr[o++] = (uint8_t)((addr >> 16) & 0xFF);
    hdr[o++] = (uint8_t)(len & 0xFF);
    hdr[o++] = (uint8_t)((len >> 8) & 0xFF);

    // TX header, turnaround, status (dummy slot), payload
    ESP_RETURN_ON_ERROR(xfer(l->dev, hdr, NULL, o, l->octal_mode), TAG, "xfer-r hdr");

    uint8_t st = 0;
    ESP_RETURN_ON_ERROR(xfer_rx(l->dev, &st, 1, l->octal_mode), TAG, "xfer-r status");
    if (status_out) *status_out = st;

    return xfer_rx(l->dev, out, len, l->octal_mode);
}
