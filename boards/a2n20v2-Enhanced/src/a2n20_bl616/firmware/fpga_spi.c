/*
 * FPGA SPI — SPI0 master with GPIO-driven CS# for BL616→FPGA communication.
 *
 * Pin mapping:
 *   GPIO0 = CS#  (GPIO output, manually asserted/deasserted)
 *   GPIO1 = SCLK (SPI0_CLK)
 *   GPIO2 = MISO (SPI0_MISO, FPGA→MCU)
 *   GPIO3 = MOSI (SPI0_MOSI, MCU→FPGA)
 *
 * CS# is driven via GPIO (not the SPI peripheral) so that multi-byte
 * transactions stay framed while each byte is a separate SPI frame.
 * This matches FPGA Companion's approach (mcu_hw.c).
 */

#include <string.h>
#include <stdio.h>
#include "bflb_gpio.h"
#include "bflb_spi.h"
#include "bflb_mtimer.h"
#include "fpga_spi.h"
#include "fpga_screen.h"

/* Bus mutex (host build only): the SPI link + the shared scratch buffers are
 * touched by several threads (overlay/status writers, XInput, and the W5100
 * bridge task). Without serialization a W5100 transfer can interleave with an
 * overlay write and corrupt network data. Each public primitive takes this for
 * its whole transaction. Created in fpga_spi_init() (pre-scheduler); calls made
 * before the scheduler runs simply skip the lock.
 *
 * The device-mode build (firmware/) is single-threaded and does not link
 * FreeRTOS, so the lock compiles out to no-ops unless FPGA_SPI_THREADSAFE is
 * defined (firmware_host/CMakeLists.txt). */
#ifdef FPGA_SPI_THREADSAFE
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
static SemaphoreHandle_t spi_lock;
static inline void spi_lock_take(void)
{
    if (spi_lock && xTaskGetSchedulerState() == taskSCHEDULER_RUNNING)
        xSemaphoreTake(spi_lock, portMAX_DELAY);
}
static inline void spi_lock_give(void)
{
    if (spi_lock && xTaskGetSchedulerState() == taskSCHEDULER_RUNNING)
        xSemaphoreGive(spi_lock);
}
#define SPI_LOCK_INIT() do { spi_lock = xSemaphoreCreateMutex(); } while (0)
#else
static inline void spi_lock_take(void) {}
static inline void spi_lock_give(void) {}
#define SPI_LOCK_INIT() do {} while (0)
#endif

#define SPI_CS_PIN   GPIO_PIN_0
#define SPI_CLK_PIN  GPIO_PIN_1
#define SPI_MISO_PIN GPIO_PIN_2
#define SPI_MOSI_PIN GPIO_PIN_3

/* Max payload per XFER chunk. Sized for one FAT sector (512B) plus the 8-byte
 * header+dummy prefix used by reads. Each chunk is one poll_exchange call. */
#define XFER_CHUNK_MAX 512
#define XFER_HDR_LEN   7   /* opcode + sub0 + addr[3] + len[2] */
#define XFER_DUMMY_LEN 1

static struct bflb_device_s *spi0;
static struct bflb_device_s *gpio_dev;

/* TX scratch holds [header || (data | dummy+filler)] for one chunk. */
static uint8_t spi_tx_scratch[XFER_HDR_LEN + XFER_DUMMY_LEN + XFER_CHUNK_MAX];
/* RX scratch is only used for reads; the header bytes return status, the
 * dummy byte is discarded, then chunk_len data bytes follow. */
static uint8_t spi_rx_scratch[XFER_HDR_LEN + XFER_DUMMY_LEN + XFER_CHUNK_MAX];

static inline void cs_assert(void)   { bflb_gpio_reset(gpio_dev, SPI_CS_PIN); }
static inline void cs_deassert(void)  { bflb_gpio_set(gpio_dev, SPI_CS_PIN); }

/* Send one byte via SPI, return the received byte */
static inline uint8_t spi_xchg_byte(uint8_t tx)
{
    uint8_t rx;
    bflb_spi_poll_exchange(spi0, &tx, &rx, 1);
    return rx;
}

void fpga_spi_init(void)
{
    gpio_dev = bflb_device_get_by_name("gpio");

    /* CS# as GPIO output, default HIGH (deasserted) */
    bflb_gpio_init(gpio_dev, SPI_CS_PIN, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_3);
    bflb_gpio_set(gpio_dev, SPI_CS_PIN);

    /* SPI data/clock pins as SPI0 alternate function */
    bflb_gpio_init(gpio_dev, SPI_CLK_PIN,  GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_3);
    bflb_gpio_init(gpio_dev, SPI_MISO_PIN, GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_3);
    bflb_gpio_init(gpio_dev, SPI_MOSI_PIN, GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_3);

    spi0 = bflb_device_get_by_name("spi0");

    struct bflb_spi_config_s spi_cfg = {
        .freq = 20 * 1000 * 1000,
        .role = SPI_ROLE_MASTER,
        .mode = SPI_MODE1,              /* CPOL=0 CPHA=1 — matches FPGA Companion */
        .data_width = SPI_DATA_WIDTH_8BIT,
        .bit_order = SPI_BIT_MSB,
        .byte_order = SPI_BYTE_LSB,
        .tx_fifo_threshold = 0,
        .rx_fifo_threshold = 0,
    };
    bflb_spi_init(spi0, &spi_cfg);

    SPI_LOCK_INIT();
}

uint8_t fpga_spi_reg_read(uint8_t reg)
{
    spi_lock_take();
    cs_assert();
    spi_xchg_byte(0x80 | (reg & 0x7F));
    uint8_t val = spi_xchg_byte(0xFF);
    cs_deassert();
    spi_lock_give();
    return val;
}

void fpga_spi_reg_write(uint8_t reg, uint8_t val)
{
    spi_lock_take();
    cs_assert();
    spi_xchg_byte(reg & 0x7F);
    spi_xchg_byte(val);
    cs_deassert();
    spi_lock_give();
}

/* Build the 7-byte XFER header at the start of spi_tx_scratch.
 * SUB0 format: { 0, RES=0, CRC_EN=0, INC=1, SPACE[2:0], DIR } */
static inline void build_xfer_header(uint8_t space, uint32_t addr, uint16_t chunk, uint8_t dir)
{
    spi_tx_scratch[0] = 0x7F;                                          /* XFER opcode */
    spi_tx_scratch[1] = (1 << 4) | ((space & 0x07) << 1) | (dir & 1); /* SUB0: INC=1 */
    spi_tx_scratch[2] = (uint8_t)(addr & 0xFF);
    spi_tx_scratch[3] = (uint8_t)((addr >> 8) & 0xFF);
    spi_tx_scratch[4] = (uint8_t)((addr >> 16) & 0xFF);
    spi_tx_scratch[5] = (uint8_t)(chunk & 0xFF);
    spi_tx_scratch[6] = (uint8_t)((chunk >> 8) & 0xFF);
}

void fpga_spi_xfer_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len)
{
    uint16_t remaining = len;
    uint32_t cur_addr = addr;
    const uint8_t *src = data;

    spi_lock_take();
    while (remaining > 0) {
        uint16_t chunk = (remaining > XFER_CHUNK_MAX) ? XFER_CHUNK_MAX : remaining;
        build_xfer_header(space, cur_addr, chunk, 0);  /* DIR=0 (write) */
        memcpy(&spi_tx_scratch[XFER_HDR_LEN], src, chunk);
        cs_assert();
        for (uint16_t i = 0; i < XFER_HDR_LEN + chunk; i++)
            spi_xchg_byte(spi_tx_scratch[i]);
        cs_deassert();
        cur_addr += chunk;
        src      += chunk;
        remaining -= chunk;
    }
    spi_lock_give();
}

void fpga_spi_xfer_read(uint8_t space, uint32_t addr, uint8_t *data, uint16_t len)
{
    uint16_t remaining = len;
    uint32_t cur_addr = addr;
    uint8_t *dst = data;

    spi_lock_take();
    while (remaining > 0) {
        uint16_t chunk = (remaining > XFER_CHUNK_MAX) ? XFER_CHUNK_MAX : remaining;
        build_xfer_header(space, cur_addr, chunk, 1);  /* DIR=1 (read) */
        cs_assert();
        /* Send header */
        for (uint16_t i = 0; i < XFER_HDR_LEN; i++)
            spi_xchg_byte(spi_tx_scratch[i]);
        /* Dummy byte */
        spi_xchg_byte(0xFF);
        /* Read payload */
        for (uint16_t i = 0; i < chunk; i++)
            dst[i] = spi_xchg_byte(0xFF);
        cs_deassert();
        cur_addr += chunk;
        dst      += chunk;
        remaining -= chunk;
    }
    spi_lock_give();
}

void fpga_spi_xfer_fill(uint8_t space, uint32_t addr, uint8_t val, uint16_t len)
{
    uint16_t remaining = len;
    uint32_t cur_addr = addr;

    spi_lock_take();   /* MUST hold the lock: shares the SPI bus, CS, and the
                        * spi_tx_scratch buffer with every other SPI op. Missing
                        * this caused intermittent bus wedges (e.g. fpga_screen
                        * clear racing the W5100 bridge from another thread). */
    while (remaining > 0) {
        uint16_t chunk = (remaining > XFER_CHUNK_MAX) ? XFER_CHUNK_MAX : remaining;
        build_xfer_header(space, cur_addr, chunk, 0);  /* DIR=0 (write) */
        cs_assert();
        for (uint16_t i = 0; i < XFER_HDR_LEN; i++)
            spi_xchg_byte(spi_tx_scratch[i]);
        for (uint16_t i = 0; i < chunk; i++)
            spi_xchg_byte(val);
        cs_deassert();
        cur_addr  += chunk;
        remaining -= chunk;
    }
    spi_lock_give();
}

uint8_t fpga_spi_read_status(void)
{
    return fpga_spi_reg_read(0x06);
}

bool fpga_spi_wait_ready(uint32_t timeout_ms)
{
    uint64_t deadline = bflb_mtimer_get_time_ms() + timeout_ms;

    while (bflb_mtimer_get_time_ms() < deadline) {
        uint8_t status = fpga_spi_read_status();
        if ((status & FPGA_STATUS_FPGA_CONFIGURED) &&
            (status & FPGA_STATUS_SDRAM_READY)) {
            return true;
        }
        bflb_mtimer_delay_ms(10);
    }
    return false;
}

void fpga_spi_read_device_id(uint8_t *buf)
{
    for (int i = 0; i < 4; i++) {
        buf[i] = fpga_spi_reg_read(i);
    }
}

void fpga_service_init(void)
{
    printf("FPGA SPI: waiting for FPGA ready...\r\n");

    if (!fpga_spi_wait_ready(5000)) {
        printf("FPGA SPI: timeout waiting for FPGA\r\n");
        return;
    }

    /* Read and verify device ID */
    uint8_t id[4];
    fpga_spi_read_device_id(id);
    printf("FPGA SPI: Device ID = %c%c%c%c\r\n", id[0], id[1], id[2], id[3]);

    uint8_t status = fpga_spi_read_status();
    printf("FPGA SPI: STATUS = 0x%02X\r\n", status);

    /* Enable video, text mode, bus ready */
    fpga_spi_reg_write(0x10, 1);  /* VIDEO_ENABLE */
    fpga_spi_reg_write(0x11, 1);  /* TEXT_MODE */
    fpga_spi_reg_write(0x30, 1);  /* A2BUS_READY */

    /* Show hello message on Apple II display */
    fpga_screen_clear();
    fpga_screen_puts("Hello from the MCU!");

    /* Hold message for 3 seconds */
    bflb_mtimer_delay_ms(3000);

    /* Disable video overlay, release card ROM */
    fpga_spi_reg_write(0x10, 0);  /* VIDEO_ENABLE=0 */
    fpga_spi_reg_write(0x31, 1);  /* CARDROM_RELEASE */

    printf("FPGA SPI: init complete\r\n");
}
