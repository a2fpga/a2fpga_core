/*
 * sscbridge — Super Serial Card to TCP, Hayes-modem style.
 *
 * The FPGA's SSC (a real 6551 core in slot 2) drives its serial wire out
 * of the FPGA into BL616 UART1 (GPIO11 TX / GPIO13 RX, wired since the
 * device-mode firmware era). This bridge gives that wire somewhere to go:
 * a Hayes AT command emulation that opens TCP connections, so period
 * Apple II comm software (ProTERM, Z-Link, ADTPro's modem mode...) can
 * "dial" Internet hosts:
 *
 *     ATDT bbs.example.com:23      (port defaults to 23)
 *     ...online...
 *     +++                          (1 s guard both sides)
 *     ATH                          (hang up)
 *
 * Commands: AT ATZ ATE0 ATE1 ATH ATO ATI ATDT/ATD. Responses are verbose
 * (OK/ERROR/CONNECT/NO CARRIER). When the peer port is 23, minimal telnet
 * handling is enabled: incoming IAC negotiations are refused, IAC IAC
 * unescapes, and outgoing 0xFF bytes are doubled.
 *
 * Baud tracking: the 6551's control register (baud select in [3:0]) is
 * exported by the gateware at SPI reg 0x2F; the bridge polls it and
 * reprograms UART1 whenever Apple II software changes the rate. Cores
 * without the register read 0x00, which maps to the 6551's 115200 code —
 * also the bridge default.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

#include "bflb_gpio.h"
#include "bflb_uart.h"
#include "bflb_irq.h"

#include "lwip/sockets.h"
#include "lwip/netdb.h"
#include "lwip/netif.h"
#include "usb_osal.h"
#include "usb_config.h"

#include "fpga_spi.h"
#include "osd_console.h"
#include "sscbridge.h"

#define REG_SSC_CTL   0x2Fu

/* ---- UART1 (SSC wire) ---------------------------------------------------- */
static struct bflb_device_s *s_uart;

#define RXBUF_SZ 1024
static volatile uint8_t  s_rx[RXBUF_SZ];
static volatile uint32_t s_rx_wr, s_rx_rd;

static void uart_isr(int irq, void *arg)
{
    (void)irq; (void)arg;
    uint32_t st = bflb_uart_get_intstatus(s_uart);
    if (st & (UART_INTSTS_RX_FIFO | UART_INTSTS_RTO)) {
        while (bflb_uart_rxavailable(s_uart)) {
            uint8_t c = (uint8_t)bflb_uart_getchar(s_uart);
            if (s_rx_wr - s_rx_rd < RXBUF_SZ)
                s_rx[s_rx_wr++ % RXBUF_SZ] = c;
        }
        if (st & UART_INTSTS_RTO)
            bflb_uart_int_clear(s_uart, UART_INTCLR_RTO);
    }
}

static int uart_getc(void)
{
    if (s_rx_rd == s_rx_wr)
        return -1;
    return s_rx[s_rx_rd++ % RXBUF_SZ];
}

static void uart_put(const uint8_t *p, int n)
{
    for (int i = 0; i < n; i++)
        bflb_uart_putchar(s_uart, p[i]);
}

static void uart_puts(const char *s)
{
    uart_put((const uint8_t *)s, (int)strlen(s));
}

/* 6551 CTL[3:0] -> baud (uart_6551.v table) */
static const uint32_t k_baud[16] = {
    115200, 50, 75, 110, 134, 150, 300, 600,
    1200, 1800, 2400, 3600, 4800, 7200, 9600, 19200
};

static void uart_setup(uint32_t baud)
{
    struct bflb_device_s *gpio = bflb_device_get_by_name("gpio");
    bflb_gpio_uart_init(gpio, 11, GPIO_UART_FUNC_UART1_TX);
    bflb_gpio_uart_init(gpio, 13, GPIO_UART_FUNC_UART1_RX);

    struct bflb_uart_config_s cfg = {
        .baudrate = baud,
        .direction = UART_DIRECTION_TXRX,
        .data_bits = UART_DATA_BITS_8,
        .stop_bits = UART_STOP_BITS_1,
        .parity = UART_PARITY_NONE,
        .bit_order = UART_LSB_FIRST,
        .flow_ctrl = 0,
        .tx_fifo_threshold = 7,
        .rx_fifo_threshold = 7,
    };
    s_uart = bflb_device_get_by_name("uart1");
    bflb_uart_init(s_uart, &cfg);
    bflb_uart_rxint_mask(s_uart, false);
    bflb_irq_attach(s_uart->irq_num, uart_isr, NULL);
    bflb_irq_enable(s_uart->irq_num);
}

/* ---- modem state ---------------------------------------------------------- */
static int  s_sock = -1;
static bool s_echo = true;
static bool s_telnet;                 /* peer is port 23: IAC handling on */
static char s_line[96];
static int  s_linelen;

static void resp(const char *r)
{
    uart_puts("\r\n");
    uart_puts(r);
    uart_puts("\r\n");
}

static void hangup(void)
{
    if (s_sock >= 0) {
        lwip_close(s_sock);
        s_sock = -1;
    }
}

/* ATDT target: host[:port], port defaults 23 */
static void dial(const char *target)
{
    char host[80];
    int port = 23;
    const char *colon = strrchr(target, ':');
    if (colon) {
        snprintf(host, sizeof(host), "%.*s", (int)(colon - target), target);
        port = atoi(colon + 1);
    } else {
        snprintf(host, sizeof(host), "%s", target);
    }
    if (!host[0] || port <= 0 || port > 65535) {
        resp("ERROR");
        return;
    }

    struct addrinfo hints, *ai = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[8];
    snprintf(portstr, sizeof(portstr), "%d", port);
    if (lwip_getaddrinfo(host, portstr, &hints, &ai) != 0 || !ai) {
        resp("NO CARRIER");
        return;
    }

    int fd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        lwip_freeaddrinfo(ai);
        resp("NO CARRIER");
        return;
    }
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    lwip_setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (lwip_connect(fd, ai->ai_addr, ai->ai_addrlen) != 0) {
        lwip_close(fd);
        lwip_freeaddrinfo(ai);
        resp("NO CARRIER");
        return;
    }
    lwip_freeaddrinfo(ai);
    struct timeval tv2 = { .tv_sec = 0, .tv_usec = 10 * 1000 };
    lwip_setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv2, sizeof(tv2));
    s_sock = fd;
    s_telnet = (port == 23);
    osd_log("SSC: CONNECTED %s:%d", host, port);
    resp("CONNECT");
}

/* Returns true when the session should go online (successful dial/ATO). */
static bool do_command(char *cmd)
{
    /* uppercase, strip leading AT */
    for (char *p = cmd; *p; p++)
        *p = (char)toupper((unsigned char)*p);
    if (strncmp(cmd, "AT", 2) != 0) {
        resp("ERROR");
        return false;
    }
    char *c = cmd + 2;

    if (!*c) {                        /* bare AT */
        resp("OK");
    } else if (!strcmp(c, "Z")) {
        hangup();
        s_echo = true;
        resp("OK");
    } else if (!strcmp(c, "E0")) {
        s_echo = false;
        resp("OK");
    } else if (!strcmp(c, "E1")) {
        s_echo = true;
        resp("OK");
    } else if (!strcmp(c, "H") || !strcmp(c, "H0")) {
        hangup();
        resp("OK");
    } else if (!strcmp(c, "O") || !strcmp(c, "O0")) {
        if (s_sock >= 0) {
            resp("CONNECT");
            return true;
        }
        resp("NO CARRIER");
    } else if (!strcmp(c, "I")) {
        char info[64];
        struct netif *nif = netif_default;
        uint32_t ip = nif ? netif_ip4_addr(nif)->addr : 0;
        const uint8_t *o = (const uint8_t *)&ip;
        snprintf(info, sizeof(info),
                 "\r\nA2FPGA SSC BRIDGE\r\nIP %u.%u.%u.%u",
                 o[0], o[1], o[2], o[3]);
        uart_puts(info);
        resp("OK");
    } else if (c[0] == 'D') {
        const char *t = c + 1;
        if (*t == 'T' || *t == 'P')   /* ATDT / ATDP */
            t++;
        while (*t == ' ')
            t++;
        if (*t) {
            dial(t);
            return s_sock >= 0;
        }
        resp("ERROR");
    } else {
        resp("OK");                   /* be permissive like real modems */
    }
    return false;
}

void sscbridge_thread(void *arg)
{
    (void)arg;
    uart_setup(115200);
    osd_log("SSC: BRIDGE READY (AT COMMANDS)");

    bool online = false;              /* transparent data mode */
    int  plus_run = 0;
    uint32_t last_rx_ms = 0, ctl_poll = 0, now_ms = 0;
    uint8_t last_ctl = 0;
    int iac_st = 0;

    for (;;) {
        usb_osal_msleep(10);
        now_ms += 10;

        /* Track the 6551's programmed baud (SPI reg 0x2F, new cores). */
        if (++ctl_poll >= 25) {
            ctl_poll = 0;
            uint8_t ctl = fpga_spi_reg_read(REG_SSC_CTL);
            if (ctl != last_ctl) {
                last_ctl = ctl;
                bflb_uart_deinit(s_uart);
                uart_setup(k_baud[ctl & 0x0F]);
                osd_log("SSC: BAUD %lu", (unsigned long)k_baud[ctl & 0x0F]);
            }
        }

        /* ---- Apple II -> bridge ---- */
        int ch;
        while ((ch = uart_getc()) >= 0) {
            uint8_t c = (uint8_t)ch;
            if (online) {
                /* +++ escape: 3 plusses framed by ~1 s guards */
                if (c == '+' && (plus_run > 0 || now_ms - last_rx_ms > 1000))
                    plus_run++;
                else
                    plus_run = 0;
                last_rx_ms = now_ms;
                if (plus_run == 3) {
                    plus_run = 0;
                    online = false;
                    resp("OK");
                    continue;
                }
                if (s_sock >= 0) {
                    if (s_telnet && c == 0xFF) {
                        uint8_t esc[2] = { 0xFF, 0xFF };
                        lwip_send(s_sock, esc, 2, 0);
                    } else {
                        lwip_send(s_sock, &c, 1, 0);
                    }
                }
            } else {
                /* command mode line editing */
                if (s_echo)
                    uart_put(&c, 1);
                if (c == '\r' || c == '\n') {
                    s_line[s_linelen] = 0;
                    s_linelen = 0;
                    if (s_line[0]) {
                        if (do_command(s_line)) {
                            online = true;
                            last_rx_ms = now_ms;
                            plus_run = 0;
                        }
                    }
                } else if (c == 0x08 || c == 0x7F) {
                    if (s_linelen)
                        s_linelen--;
                } else if (s_linelen < (int)sizeof(s_line) - 1 && c >= 32) {
                    s_line[s_linelen++] = (char)c;
                }
            }
        }

        /* ---- network -> Apple II ---- */
        if (s_sock >= 0) {
            uint8_t buf[256];
            int r = lwip_recv(s_sock, buf, sizeof(buf), MSG_DONTWAIT);
            if (r == 0 || (r < 0 && errno != EWOULDBLOCK && errno != EAGAIN)) {
                hangup();
                online = false;
                resp("NO CARRIER");
                osd_log("SSC: DISCONNECTED");
            } else if (r > 0 && online) {
                if (!s_telnet) {
                    uart_put(buf, r);
                } else {
                    /* minimal telnet: refuse negotiations, unescape IAC */
                    for (int i = 0; i < r; i++) {
                        uint8_t c = buf[i];
                        if (iac_st == 0) {
                            if (c == 0xFF)
                                iac_st = 1;
                            else
                                uart_put(&c, 1);
                        } else if (iac_st == 1) {
                            if (c == 0xFF) {
                                uart_put(&c, 1);      /* escaped 0xFF */
                                iac_st = 0;
                            } else if (c >= 251 && c <= 254) {
                                iac_st = (int)c;      /* verb, await opt */
                            } else {
                                iac_st = 0;           /* other cmd: drop */
                            }
                        } else {
                            /* refuse: DO->WONT, WILL->DONT */
                            uint8_t verb = (iac_st == 253) ? 252 :
                                           (iac_st == 251) ? 254 : 0;
                            if (verb && s_sock >= 0) {
                                uint8_t rsp[3] = { 0xFF, verb, c };
                                lwip_send(s_sock, rsp, 3, 0);
                            }
                            iac_st = 0;
                        }
                    }
                }
            }
        }
    }
}

void sscbridge_init(void)
{
    usb_osal_thread_create("sscbridge", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                           sscbridge_thread, NULL);
}
