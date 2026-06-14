/*
 * UART1 interface for BL616 — USB↔UART passthrough.
 * Uses LHAL API for UART1 on GPIO11 (TX) / GPIO13 (RX).
 * Ring buffers for USB→UART and UART→USB data flow.
 * FTDI 2-byte status header (0x01 0x60) prepended on USB IN transfers.
 */

#include <string.h>
#include "board.h"
#include "bflb_gpio.h"
#include "bflb_uart.h"
#include "bflb_irq.h"
#include "bflb_mtimer.h"
#include "usbd_core.h"
#include "usbd_ftdi.h"
#include "uart_interface.h"
#include "cli.h"
#include "io_cfg.h"

#ifdef CONFIG_USB_HS
#define UART_EP_MPS 512
#else
#define UART_EP_MPS 64
#endif

/* Ring buffer sizes — power of 2 for efficient masking */
#define USB_RX_BUF_SIZE  8192
#define UART_RX_BUF_SIZE 8192
#define USB_RX_BUF_MASK  (USB_RX_BUF_SIZE - 1)
#define UART_RX_BUF_MASK (UART_RX_BUF_SIZE - 1)

/* USB OUT → UART TX ring buffer */
static uint8_t usb_rx_buf[USB_RX_BUF_SIZE];
static volatile uint32_t usb_rx_head = 0;
static volatile uint32_t usb_rx_tail = 0;

/* UART RX → USB IN ring buffer */
static uint8_t uart_rx_buf[UART_RX_BUF_SIZE];
static volatile uint32_t uart_rx_head = 0;
static volatile uint32_t uart_rx_tail = 0;

/* USB endpoint buffers */
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX static uint8_t uart_usb_out_buf[UART_EP_MPS];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX static uint8_t uart_usb_in_buf[UART_EP_MPS];

static volatile bool uart_tx_in_busy = false;
static volatile bool uart_paused = false;
static volatile uint32_t uart_out_nbytes = 0;  /* bytes received from last USB OUT */

static struct bflb_device_s *uart1_dev;
static struct bflb_device_s *gpio_dev;

/* Ring buffer helpers */
static inline uint32_t rb_used(volatile uint32_t *head, volatile uint32_t *tail, uint32_t mask)
{
    return (*head - *tail) & mask;
}

static inline uint32_t rb_free(volatile uint32_t *head, volatile uint32_t *tail, uint32_t mask)
{
    return mask - ((*head - *tail) & mask);
}

static void rb_write(uint8_t *buf, volatile uint32_t *head, uint32_t mask, const uint8_t *data, uint32_t len)
{
    for (uint32_t i = 0; i < len; i++) {
        buf[*head & mask] = data[i];
        (*head)++;
    }
}

static uint32_t rb_read(uint8_t *buf, volatile uint32_t *head, volatile uint32_t *tail, uint32_t mask,
                         uint8_t *out, uint32_t max_len)
{
    uint32_t avail = (*head - *tail) & mask;
    if (avail > max_len) avail = max_len;
    for (uint32_t i = 0; i < avail; i++) {
        out[i] = buf[*tail & mask];
        (*tail)++;
    }
    return avail;
}

/* UART1 RX interrupt handler — stores received bytes in ring buffer */
static void uart1_isr(int irq, void *arg)
{
    (void)irq;
    (void)arg;

    uint32_t int_status = bflb_uart_get_intstatus(uart1_dev);

    if (int_status & UART_INTSTS_RX_FIFO) {
        while (bflb_uart_rxavailable(uart1_dev)) {
            uint8_t ch = bflb_uart_getchar(uart1_dev);
            if (rb_free(&uart_rx_head, &uart_rx_tail, UART_RX_BUF_MASK) > 0) {
                uart_rx_buf[uart_rx_head & UART_RX_BUF_MASK] = ch;
                uart_rx_head++;
            }
        }
    }

    if (int_status & UART_INTSTS_RTO) {
        while (bflb_uart_rxavailable(uart1_dev)) {
            uint8_t ch = bflb_uart_getchar(uart1_dev);
            if (rb_free(&uart_rx_head, &uart_rx_tail, UART_RX_BUF_MASK) > 0) {
                uart_rx_buf[uart_rx_head & UART_RX_BUF_MASK] = ch;
                uart_rx_head++;
            }
        }
        bflb_uart_int_clear(uart1_dev, UART_INTCLR_RTO);
    }
}

void uart_init(void)
{
    gpio_dev = bflb_device_get_by_name("gpio");
    bflb_gpio_uart_init(gpio_dev, 11, GPIO_UART_FUNC_UART1_TX);
    bflb_gpio_uart_init(gpio_dev, 13, GPIO_UART_FUNC_UART1_RX);

    struct bflb_uart_config_s cfg = {
        .baudrate = 2000000,
        .direction = UART_DIRECTION_TXRX,
        .data_bits = UART_DATA_BITS_8,
        .stop_bits = UART_STOP_BITS_1,
        .parity = UART_PARITY_NONE,
        .bit_order = UART_LSB_FIRST,
        .flow_ctrl = 0,
        .tx_fifo_threshold = 7,
        .rx_fifo_threshold = 7,
    };

    uart1_dev = bflb_device_get_by_name("uart1");
    bflb_uart_init(uart1_dev, &cfg);

    /* Enable RX interrupts */
    bflb_uart_rxint_mask(uart1_dev, false);
    bflb_irq_attach(uart1_dev->irq_num, uart1_isr, NULL);
    bflb_irq_enable(uart1_dev->irq_num);

    /* Reset ring buffers */
    usb_rx_head = usb_rx_tail = 0;
    uart_rx_head = uart_rx_tail = 0;
    uart_paused = false;
}

void uart_start(void)
{
    /* Arm OUT endpoint with real buffer */
    usbd_ep_start_read(CDC_OUT_EP, uart_usb_out_buf, UART_EP_MPS);
    /* Send initial status-only packet on IN endpoint */
    uart_usb_in_buf[0] = FTDI_MODEM_STATUS_0;
    uart_usb_in_buf[1] = FTDI_MODEM_STATUS_1;
    uart_tx_in_busy = true;
    usbd_ep_start_write(CDC_IN_EP, uart_usb_in_buf, 2);
}

void uart_config(uint32_t baudrate, uint8_t databits, uint8_t parity, uint8_t stopbits)
{
    bflb_uart_disable(uart1_dev);

    struct bflb_uart_config_s cfg = {
        .baudrate = baudrate,
        .direction = UART_DIRECTION_TXRX,
        .data_bits = (databits <= 5) ? UART_DATA_BITS_5 :
                     (databits == 6) ? UART_DATA_BITS_6 :
                     (databits == 7) ? UART_DATA_BITS_7 : UART_DATA_BITS_8,
        .stop_bits = (stopbits == 2) ? UART_STOP_BITS_2 : UART_STOP_BITS_1,
        .parity = (parity == 1) ? UART_PARITY_ODD :
                  (parity == 2) ? UART_PARITY_EVEN : UART_PARITY_NONE,
        .bit_order = UART_LSB_FIRST,
        .flow_ctrl = 0,
        .tx_fifo_threshold = 7,
        .rx_fifo_threshold = 7,
    };

    bflb_uart_init(uart1_dev, &cfg);
    bflb_uart_rxint_mask(uart1_dev, false);
}

/* USB OUT callback — data from host going to UART */
void uart_bulk_out_cb(uint8_t ep, uint32_t nbytes)
{
    uart_out_nbytes = nbytes;

    /* Feed bytes to CLI break-in detector */
    if (!cli_is_active()) {
        for (uint32_t i = 0; i < nbytes; i++)
            cli_feed(uart_usb_out_buf[i]);
    }

    if (nbytes > 0 && !uart_paused) {
        /* Store in USB→UART ring buffer */
        uint32_t space = rb_free(&usb_rx_head, &usb_rx_tail, USB_RX_BUF_MASK);
        uint32_t to_write = (nbytes < space) ? nbytes : space;
        rb_write(usb_rx_buf, &usb_rx_head, USB_RX_BUF_MASK, uart_usb_out_buf, to_write);
    }
    /* Re-arm OUT endpoint */
    usbd_ep_start_read(CDC_OUT_EP, uart_usb_out_buf, UART_EP_MPS);
}

/* USB IN callback — done sending data to host */
void uart_bulk_in_cb(uint8_t ep, uint32_t nbytes)
{
    uart_tx_in_busy = false;
    cli_notify_in_complete();
}

uint32_t uart_get_usb_out_data(uint8_t *buf, uint32_t max_len)
{
    uint32_t nb = uart_out_nbytes;
    uart_out_nbytes = 0;  /* consume — prevent re-processing same bytes */
    if (nb > max_len) nb = max_len;
    if (nb > 0)
        memcpy(buf, uart_usb_out_buf, nb);
    return nb;
}

void uart_pause(void)
{
    uart_paused = true;
}

void uart_resume(void)
{
    uart_paused = false;
    /* Drain any stale data in the USB→UART buffer */
    usb_rx_head = usb_rx_tail = 0;
}

void uart_process(void)
{
    /* USB OUT → UART TX: drain ring buffer to UART */
    while (rb_used(&usb_rx_head, &usb_rx_tail, USB_RX_BUF_MASK) > 0) {
        uint8_t ch = usb_rx_buf[usb_rx_tail & USB_RX_BUF_MASK];
        usb_rx_tail++;
        bflb_uart_putchar(uart1_dev, ch);
    }

    /* UART RX → USB IN: send ring buffer data to host with FTDI header */
    if (!uart_tx_in_busy) {
        uint32_t avail = rb_used(&uart_rx_head, &uart_rx_tail, UART_RX_BUF_MASK);

        if (avail > 0) {
            /* Prepend FTDI 2-byte status header */
            uart_usb_in_buf[0] = FTDI_MODEM_STATUS_0;
            uart_usb_in_buf[1] = FTDI_MODEM_STATUS_1;

            uint32_t max_data = UART_EP_MPS - 2;
            uint32_t to_send = (avail < max_data) ? avail : max_data;

            rb_read(uart_rx_buf, &uart_rx_head, &uart_rx_tail, UART_RX_BUF_MASK,
                    &uart_usb_in_buf[2], to_send);

            uart_tx_in_busy = true;
            usbd_ep_start_write(CDC_IN_EP, uart_usb_in_buf, to_send + 2);
        } else {
            /* Latency timer: send status-only packet periodically */
            static uint64_t last_status_us = 0;
            uint64_t now = bflb_mtimer_get_time_us();
            uint32_t latency_ms = usbd_ftdi_get_latency_timer2();
            if ((now - last_status_us) >= (uint64_t)latency_ms * 1000) {
                uart_usb_in_buf[0] = FTDI_MODEM_STATUS_0;
                uart_usb_in_buf[1] = FTDI_MODEM_STATUS_1;
                uart_tx_in_busy = true;
                usbd_ep_start_write(CDC_IN_EP, uart_usb_in_buf, 2);
                last_status_us = now;
            }
        }
    }
}
