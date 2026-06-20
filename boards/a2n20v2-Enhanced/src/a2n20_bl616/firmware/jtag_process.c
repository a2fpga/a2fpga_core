/*
 * JTAG MPSSE state machine for BL616 → FPGA GW2AR-18.
 * Bitbang via direct GPIO register access for speed.
 *
 * Architecture: MPSSE data is ALWAYS processed inline in the USB OUT
 * callback and the endpoint is ALWAYS re-armed immediately.  The OUT
 * endpoint is never left unarmed due to IN endpoint state (tx_busy).
 *
 * For write-only MPSSE commands (0x19 etc. — 99% of FPGA programming),
 * no TDO data is generated, so no IN flush is needed.  For read-write
 * commands, TDO data accumulates in jtag_tx_buffer and is flushed when
 * the IN endpoint becomes free.  Periodic FTDI status packets are
 * suppressed during active MPSSE traffic to avoid blocking the data path.
 *
 * Pin mapping:
 *   TMS=GPIO16 → FPGA pin 5
 *   TCK=GPIO10 → FPGA pin 6
 *   TDI=GPIO12 → FPGA pin 7
 *   TDO=GPIO14 → FPGA pin 8
 */

#include <string.h>
#include "usbd_core.h"
#include "usbd_ftdi.h"
#include "jtag_process.h"
#include "bflb_gpio.h"
#include "bflb_mtimer.h"
#include "io_cfg.h"

/* BL616 GPIO register addresses (GLB base 0x20000000):
 *   GPIO_CFG128 (0xAC4) = input read (pins 0-31)
 *   GPIO_CFG136 (0xAE4) = output value read/write (pins 0-31)
 *   GPIO_CFG138 (0xAEC) = output SET (write 1 = set high)
 *   GPIO_CFG140 (0xAF4) = output CLEAR (write 1 = set low)
 * Use SET/CLEAR registers for atomic GPIO manipulation (no read-modify-write).
 * RMW on GPIO_CFG136 (0xAE4) causes USB communication failures on BL616. */
#define JTAG_GPIO_SET    (*(volatile uint32_t *)0x20000AEC)
#define JTAG_GPIO_CLR    (*(volatile uint32_t *)0x20000AF4)
#define JTAG_GPIO_IN     (*(volatile uint32_t *)0x20000AC4)

/* Bit positions in GPIO register */
#define TMS_BIT  (1 << 16)
#define TCK_BIT  (1 << 10)
#define TDI_BIT  (1 << 12)
#define TDO_BIT  (1 << 14)

/* MPSSE state machine states */
#define MPSSE_IDLE              0
#define MPSSE_RCV_LENGTH_L      1
#define MPSSE_RCV_LENGTH_H      2
#define MPSSE_TRANSMIT_BYTE     3
#define MPSSE_RCV_LENGTH        4
#define MPSSE_TRANSMIT_BIT      5
#define MPSSE_ERROR             6
#define MPSSE_TRANSMIT_BIT_MSB  7
#define MPSSE_TMS_OUT           8
#define MPSSE_NO_OP_1           9
#define MPSSE_NO_OP_2           10
#define MPSSE_TRANSMIT_BYTE_MSB 11

/* TX buffer: bytes [0..1] reserved for FTDI status header, data starts at [2] */
#define JTAG_TX_BUFFER_SIZE 1024
#define JTAG_TX_DATA_OFFSET 2
#define JTAG_RX_BUFFER_SIZE 512

#ifdef CONFIG_USB_HS
#define JTAG_EP_MPS 512
#else
#define JTAG_EP_MPS 64
#endif

USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX static uint8_t jtag_rx_buffer[JTAG_RX_BUFFER_SIZE];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX static uint8_t jtag_tx_buffer[JTAG_TX_BUFFER_SIZE];

static volatile uint32_t jtag_rx_len = 0;
static volatile uint32_t jtag_rx_pos = 0;
static volatile bool jtag_tx_busy = false;
static volatile bool jtag_flush_pending = false;
static volatile uint64_t jtag_last_out_us = 0;

/* jtag_tx_pos points into the data area (offset from [2]) */
static uint32_t jtag_tx_pos = 0;

static uint32_t mpsse_longlen = 0;
static uint32_t mpsse_shortlen = 0;
static uint32_t mpsse_status = MPSSE_IDLE;
static uint32_t jtag_cmd = 0;

void jtag_gpio_init(void)
{
    struct bflb_device_s *gpio = bflb_device_get_by_name("gpio");

    bflb_gpio_init(gpio, 16, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0);  /* TMS */
    bflb_gpio_init(gpio, 10, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0);  /* TCK */
    bflb_gpio_init(gpio, 12, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0);  /* TDI */
    bflb_gpio_init(gpio, 14, GPIO_INPUT | GPIO_PULLUP | GPIO_SMT_EN);                /* TDO */

    JTAG_GPIO_CLR = TMS_BIT | TCK_BIT | TDI_BIT;
}

void jtag_init(void)
{
    jtag_tx_pos = 0;
    jtag_rx_len = 0;
    jtag_rx_pos = 0;
    jtag_tx_busy = false;
    jtag_flush_pending = false;
    jtag_last_out_us = 0;
    mpsse_status = MPSSE_IDLE;
}

static void jtag_tx_write(uint8_t byte)
{
    if ((jtag_tx_pos + JTAG_TX_DATA_OFFSET) < JTAG_TX_BUFFER_SIZE)
        jtag_tx_buffer[JTAG_TX_DATA_OFFSET + jtag_tx_pos++] = byte;
}

/* Send JTAG TX buffer to USB IN endpoint with FTDI 2-byte status header */
static void jtag_tx_flush(void)
{
    if (jtag_tx_busy)
        return;

    /* Always prepend FTDI status header */
    jtag_tx_buffer[0] = FTDI_MODEM_STATUS_0;
    jtag_tx_buffer[1] = FTDI_MODEM_STATUS_1;
    jtag_tx_busy = true;
    usbd_ep_start_write(0, JTAG_IN_EP, jtag_tx_buffer, JTAG_TX_DATA_OFFSET + jtag_tx_pos);
    jtag_tx_pos = 0;
}

void jtag_start(void)
{
    /* Arm OUT endpoint with real buffer */
    usbd_ep_start_read(0, JTAG_OUT_EP, jtag_rx_buffer, JTAG_EP_MPS);
    /* Send initial status-only packet on IN endpoint */
    jtag_tx_pos = 0;
    jtag_tx_flush();
}

/* Core MPSSE processing — called from both callback (fast path) and main loop (deferred) */
static void jtag_process_packet(void)
{
    uint32_t usb_tx_data;
    uint32_t data;

    while (jtag_rx_pos < jtag_rx_len) {
        switch (mpsse_status) {
        case MPSSE_IDLE:
            jtag_cmd = jtag_rx_buffer[jtag_rx_pos];

            switch (jtag_cmd) {
            case 0x80:
            case 0x82: /* Set data bits low/high byte — fake bitbang */
                mpsse_status = MPSSE_NO_OP_1;
                jtag_rx_pos++;
                break;

            case 0x81:
            case 0x83: /* Read data bits — fake status */
                usb_tx_data = jtag_rx_buffer[jtag_rx_pos] - 0x80;
                jtag_tx_write(usb_tx_data);
                jtag_rx_pos++;
                break;

            case 0x84:
            case 0x85: /* Loopback enable/disable */
                jtag_rx_pos++;
                break;

            case 0x86: /* Set TCK divisor — skip 2 data bytes */
                mpsse_status = MPSSE_NO_OP_1;
                jtag_rx_pos++;
                break;

            case 0x87: /* Flush buffer immediately */
                jtag_rx_pos++;
                break;

            /* Byte transfer commands (LSB/MSB, read/write/readwrite) */
            case 0x19: case 0x1d: case 0x39: case 0x3d:
            case 0x11: case 0x15: case 0x31: case 0x35:
                mpsse_status = MPSSE_RCV_LENGTH_L;
                jtag_rx_pos++;
                break;

            /* Bit transfer commands */
            case 0x6b: case 0x6f: case 0x4b: case 0x4f:
            case 0x3b: case 0x3f: case 0x1b: case 0x1f:
            case 0x13: case 0x17:
                mpsse_status = MPSSE_RCV_LENGTH;
                jtag_rx_pos++;
                break;

            default:
                jtag_tx_write(0xFA); /* Bad command marker */
                mpsse_status = MPSSE_ERROR;
                break;
            }
            break;

        case MPSSE_RCV_LENGTH_L:
            mpsse_longlen = jtag_rx_buffer[jtag_rx_pos];
            mpsse_status = MPSSE_RCV_LENGTH_H;
            jtag_rx_pos++;
            break;

        case MPSSE_RCV_LENGTH_H:
            mpsse_longlen |= (jtag_rx_buffer[jtag_rx_pos] << 8) & 0xFF00;
            jtag_rx_pos++;

            if (jtag_cmd == 0x11 || jtag_cmd == 0x31 || jtag_cmd == 0x15 || jtag_cmd == 0x35)
                mpsse_status = MPSSE_TRANSMIT_BYTE_MSB;
            else
                mpsse_status = MPSSE_TRANSMIT_BYTE;
            break;

        case MPSSE_TRANSMIT_BYTE: /* LSB-first byte transfer */
            data = jtag_rx_buffer[jtag_rx_pos];

            if (jtag_cmd == 0x19 || jtag_cmd == 0x1d) {
                /* Write-only fast path — skip TDO read */
                for (uint32_t i = 8; i; i--) {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                }
            } else {
                /* Read-write: capture TDO */
                usb_tx_data = 0;
                for (uint32_t i = 8; i; i--) {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data >>= 1;
                    usb_tx_data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                    if (JTAG_GPIO_IN & TDO_BIT)
                        usb_tx_data |= 0x80;
                }
                jtag_tx_write(usb_tx_data);
            }
            JTAG_GPIO_CLR = TCK_BIT;

            if (mpsse_longlen == 0)
                mpsse_status = MPSSE_IDLE;

            mpsse_longlen--;
            jtag_rx_pos++;
            break;

        case MPSSE_TRANSMIT_BYTE_MSB: /* MSB-first byte transfer */
            data = jtag_rx_buffer[jtag_rx_pos];

            if (jtag_cmd == 0x11 || jtag_cmd == 0x15) {
                /* Write-only fast path — skip TDO read */
                for (uint32_t i = 8; i; i--) {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x80)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data <<= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                }
            } else {
                /* Read-write: capture TDO */
                usb_tx_data = 0;
                for (uint32_t i = 8; i; i--) {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x80)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data <<= 1;
                    usb_tx_data <<= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                    if (JTAG_GPIO_IN & TDO_BIT)
                        usb_tx_data |= 0x01;
                }
                jtag_tx_write(usb_tx_data);
            }
            JTAG_GPIO_CLR = TCK_BIT;

            if (mpsse_longlen == 0)
                mpsse_status = MPSSE_IDLE;

            jtag_rx_pos++;
            mpsse_longlen--;
            break;

        case MPSSE_RCV_LENGTH:
            mpsse_shortlen = jtag_rx_buffer[jtag_rx_pos];

            if (jtag_cmd == 0x6b || jtag_cmd == 0x4b || jtag_cmd == 0x6f || jtag_cmd == 0x4f)
                mpsse_status = MPSSE_TMS_OUT;
            else if (jtag_cmd == 0x13 || jtag_cmd == 0x17)
                mpsse_status = MPSSE_TRANSMIT_BIT_MSB;
            else
                mpsse_status = MPSSE_TRANSMIT_BIT;

            jtag_rx_pos++;
            break;

        case MPSSE_TRANSMIT_BIT: /* LSB-first bit transfer */
            data = jtag_rx_buffer[jtag_rx_pos];

            if (jtag_cmd == 0x1b || jtag_cmd == 0x1f) {
                /* Write-only fast path */
                do {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                } while ((mpsse_shortlen--) > 0);
            } else {
                /* Read-write: capture TDO */
                usb_tx_data = 0;
                do {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TDI_BIT;
                    else
                        JTAG_GPIO_CLR = TDI_BIT;
                    data >>= 1;
                    usb_tx_data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                    if (JTAG_GPIO_IN & TDO_BIT)
                        usb_tx_data |= 0x80;
                } while ((mpsse_shortlen--) > 0);
                jtag_tx_write(usb_tx_data);
            }

            JTAG_GPIO_CLR = TCK_BIT;
            mpsse_status = MPSSE_IDLE;
            jtag_rx_pos++;
            break;

        case MPSSE_TRANSMIT_BIT_MSB: /* MSB-first bit transfer */
            data = jtag_rx_buffer[jtag_rx_pos];

            do {
                JTAG_GPIO_CLR = TCK_BIT;

                if (data & 0x80)
                    JTAG_GPIO_SET = TDI_BIT;
                else
                    JTAG_GPIO_CLR = TDI_BIT;

                data <<= 1;

                JTAG_GPIO_SET = TCK_BIT;
            } while ((mpsse_shortlen--) > 0);

            JTAG_GPIO_CLR = TCK_BIT;

            mpsse_status = MPSSE_IDLE;
            jtag_rx_pos++;
            break;

        case MPSSE_ERROR:
            usb_tx_data = jtag_rx_buffer[jtag_rx_pos];
            jtag_tx_write(usb_tx_data);
            mpsse_status = MPSSE_IDLE;
            jtag_rx_pos++;
            break;

        case MPSSE_TMS_OUT:
            data = jtag_rx_buffer[jtag_rx_pos];

            if (data & 0x80)
                JTAG_GPIO_SET = TDI_BIT;
            else
                JTAG_GPIO_CLR = TDI_BIT;

            if (jtag_cmd == 0x4b || jtag_cmd == 0x4f) {
                /* Write-only TMS fast path */
                do {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TMS_BIT;
                    else
                        JTAG_GPIO_CLR = TMS_BIT;
                    data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                } while ((mpsse_shortlen--) > 0);
            } else {
                /* Read-write TMS: capture TDO */
                usb_tx_data = 0;
                do {
                    JTAG_GPIO_CLR = TCK_BIT;
                    if (data & 0x01)
                        JTAG_GPIO_SET = TMS_BIT;
                    else
                        JTAG_GPIO_CLR = TMS_BIT;
                    data >>= 1;
                    usb_tx_data >>= 1;
                    JTAG_GPIO_SET = TCK_BIT;
                    if (JTAG_GPIO_IN & TDO_BIT)
                        usb_tx_data |= 0x80;
                } while ((mpsse_shortlen--) > 0);
                jtag_tx_write(usb_tx_data);
            }

            JTAG_GPIO_CLR = TCK_BIT;
            mpsse_status = MPSSE_IDLE;
            jtag_rx_pos++;
            break;

        case MPSSE_NO_OP_1:
            jtag_rx_pos++;
            mpsse_status = MPSSE_NO_OP_2;
            break;

        case MPSSE_NO_OP_2:
            mpsse_status = MPSSE_IDLE;
            jtag_rx_pos++;
            break;

        default:
            mpsse_status = MPSSE_IDLE;
            break;
        }
    }
}

/* USB OUT callback — ALWAYS process MPSSE data inline, ALWAYS re-arm.
 *
 * Previous architecture checked jtag_tx_busy before processing and deferred
 * the entire packet if IN was busy (e.g. from a periodic status packet sent
 * by jtag_idle).  This caused the OUT endpoint to go unarmed for up to 50ms
 * every time the latency timer fired — devastating throughput.
 *
 * New approach: process immediately regardless of tx_busy.  For write-only
 * MPSSE commands (0x19 etc.), jtag_tx_pos stays 0 so no flush is needed.
 * For read-write commands, TDO data accumulates in jtag_tx_buffer and is
 * flushed as soon as the IN endpoint is free (either here or in the IN
 * callback / main loop). */
void jtag_bulk_out_cb(uint8_t busid, uint8_t ep, uint32_t nbytes)
{
    (void)busid;
    if (nbytes == 0) {
        usbd_ep_start_read(0, JTAG_OUT_EP, jtag_rx_buffer, JTAG_EP_MPS);
        return;
    }

    jtag_last_out_us = bflb_mtimer_get_time_us();
    jtag_rx_len = nbytes;
    jtag_rx_pos = 0;

    /* Always process MPSSE data immediately */
    jtag_process_packet();

    /* Flush TDO data if any accumulated */
    if (jtag_tx_pos > 0) {
        if (!jtag_tx_busy) {
            jtag_tx_flush();
        } else {
            /* IN endpoint busy — mark flush pending, will be handled
             * in jtag_bulk_in_cb or jtag_process */
            jtag_flush_pending = true;
        }
    }

    /* Always re-arm OUT endpoint — never leave it unarmed */
    usbd_ep_start_read(0, JTAG_OUT_EP, jtag_rx_buffer, JTAG_EP_MPS);
}

void jtag_bulk_in_cb(uint8_t busid, uint8_t ep, uint32_t nbytes)
{
    (void)busid;
    jtag_tx_busy = false;

    /* If TDO data accumulated while IN was busy, flush it now */
    if (jtag_flush_pending && jtag_tx_pos > 0) {
        jtag_tx_flush();
        jtag_flush_pending = false;
    }
}

/* Main-loop handler — flush pending TDO data if IN callback didn't catch it */
void jtag_process(void)
{
    if (jtag_flush_pending && !jtag_tx_busy && jtag_tx_pos > 0) {
        jtag_tx_flush();
        jtag_flush_pending = false;
    }
}

/* Reset JTAG endpoint state — called when host purges buffers (SIO_RESET) */
void jtag_purge(void)
{
    jtag_tx_busy = false;
    jtag_tx_pos = 0;
    jtag_flush_pending = false;
    mpsse_status = MPSSE_IDLE;
}

/* Send periodic FTDI status packets when JTAG IN endpoint is idle.
 * Suppressed during active MPSSE traffic to avoid setting jtag_tx_busy
 * and interfering with the data path.  Only sends when the endpoint has
 * been quiet for at least 5ms.
 * Also recovers from stuck tx_busy (e.g. if host reclaimed interface). */
void jtag_idle(void)
{
    static uint64_t tx_busy_since = 0;

    if (jtag_tx_busy) {
        uint64_t now = bflb_mtimer_get_time_us();
        if (tx_busy_since == 0)
            tx_busy_since = now;
        else if ((now - tx_busy_since) > 50000)  /* 50ms timeout */
            jtag_tx_busy = false;
        return;
    }
    tx_busy_since = 0;

    if (jtag_flush_pending)
        return;

    /* Don't send status packets during active MPSSE traffic */
    uint64_t now = bflb_mtimer_get_time_us();
    if (jtag_last_out_us != 0 && (now - jtag_last_out_us) < 5000)
        return;

    static uint64_t last_status_us = 0;
    uint32_t latency_ms = usbd_ftdi_get_latency_timer1();
    if ((now - last_status_us) >= (uint64_t)latency_ms * 1000) {
        jtag_tx_pos = 0;
        jtag_tx_flush();
        last_status_us = now;
    }
}
