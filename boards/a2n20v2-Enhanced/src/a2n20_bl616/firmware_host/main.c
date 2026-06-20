/*
 * A2N20 BL616 Firmware — USB-HOST build (standalone joystick mode)
 *
 * This is a SEPARATE build from the default FT2232 device-mode firmware in
 * ../firmware. In host mode the BL616 OTG port becomes a USB host: it powers
 * and enumerates a USB XInput gamepad (optionally behind a hub) and drives the
 * FPGA over SPI. The FT2232 JTAG/UART bridge and CLI are NOT present in this
 * build (those are USB-device endpoints, mutually exclusive with host mode).
 *
 * Phase 1/2/3 behavior:
 *   - bring up the CherryUSB host stack (EHCI on the BL616 OTG controller)
 *   - register the XInput vendor-class driver (usbh_xinput.c)
 *   - on connect, show a status line on the Apple II screen via fpga_screen
 *   - poll the controller; on a Select (Back) button press, toggle the display
 *     between the live Apple II output and an MCU-drawn menu (text screen) by
 *     overriding video_control via the SPI register interface.
 */

#include <FreeRTOS.h>
#include "task.h"
#include "usbh_core.h"
#include "usbh_xinput.h"
#include "board.h"
#include "bflb_mtimer.h"

#include "fpga_spi.h"
#include "fpga_screen.h"

#include "lwip/tcpip.h"   /* lwIP for the USB-Ethernet (CDC-ECM) net path */
#include "lwip/netif.h"
#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "usbh_cdc_ecm.h"
#include <string.h>

/* lwIP's LWIP_RAND() calls bl_rand() (normally from the SDK wifi/RF component,
 * which we don't pull in). It's used for DHCP xids / initial sequence numbers /
 * local-port randomization — not crypto — so an xorshift PRNG is fine. */
int bl_rand(void)
{
    static uint32_t s = 0;
    if (s == 0) {
        s = (uint32_t)bflb_mtimer_get_time_us() | 1u;
    }
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return (int)(s & 0x7fffffff);
}

/* video_control register map (see BL616_SPI_PROTOCOL.md / bl616_spi_connector.sv) */
#define REG_VIDEO_ENABLE 0x10
#define REG_TEXT_MODE    0x11
#define REG_A2BUS_READY  0x30
#define REG_CARDROM_REL  0x31

/* --- DebugOverlay status channel ---------------------------------------
 * These MCU scratch regs are wired into the HDMI DebugOverlay in top.sv:
 *   hex[0]=stage  hex[1]=btn-lo  hex[2]=btn-hi  hex[3]=counter  hex[4]=flags
 *   bit-row0 = {flags[5:0], standalone, mcu_ready}   bit-row1 = btn-lo
 * So everything below shows up on screen over the Apple II output, in any
 * USB role, with no serial console needed. */
#define DBG_STAGE   0x07  /* scratch0 */
#define DBG_BTN_LO  0x0C  /* scratch1 */
#define DBG_BTN_HI  0x0D  /* scratch2 */
#define DBG_COUNTER 0x0E  /* scratch3 (heartbeat) */
#define DBG_FLAGS   0x0F  /* scratch4 */

/* DBG_FLAGS bits */
#define F_SPI_INIT   (1u << 0)
#define F_FPGA_READY (1u << 1)
#define F_USBH_INIT  (1u << 2)
#define F_THREAD_UP  (1u << 3)
#define F_CONNECTED  (1u << 4)
#define F_HEARTBEAT  (1u << 5)

/* Stage codes (DBG_STAGE) */
#define STG_SPI_INIT   0x10
#define STG_FPGA_READY 0x20
#define STG_PRE_USB    0x30
#define STG_USBH_INIT  0x40
#define STG_SCHED      0x50
#define STG_SEARCH     0xA0
#define STG_CONNECTED  0xC0
#define STG_REPORT     0xD0

/* EHCI host-controller registers (CherryUSB maps HCOR here for bl616).
 * PORTSC[0] tells us if the controller electrically sees a device on the port:
 *   bit0 CCS (connect status), bit1 CSC, bit2 PE, bits10-11 line status,
 *   bit12 PP (port power). USBSTS bit2 = port-change-detect. */
#ifndef CONFIG_USB_EHCI_HCOR_BASE
#define CONFIG_USB_EHCI_HCOR_BASE (0x20072000 + 0x10)
#endif
#define EHCI_USBSTS  (*(volatile uint32_t *)(CONFIG_USB_EHCI_HCOR_BASE + 0x04))
#define EHCI_PORTSC0 (*(volatile uint32_t *)(CONFIG_USB_EHCI_HCOR_BASE + 0x44))

static volatile uint8_t g_flags = 0;
static volatile uint8_t g_counter = 0;
/* Set by the connect callback for EVERY new controller; the poll thread (re)runs
 * the init when it sees this. A flag (not pointer identity) because a freed class
 * struct's address gets reused — so a new pad can look "same" by pointer. */
static volatile bool g_need_init = false;
/* True while a USB-Ethernet (CDC-ECM) device owns the DebugOverlay (it reports
 * the DHCP IP on the same scratch regs). When set, the xinput poll thread stops
 * writing its "searching" status so the two don't fight over the overlay. */
static volatile bool g_net_active = false;

static inline void dbg_stage(uint8_t s) { fpga_spi_reg_write(DBG_STAGE, s); }
static inline void dbg_set(uint8_t f)   { g_flags |= f;  fpga_spi_reg_write(DBG_FLAGS, g_flags); }
static inline void dbg_clr(uint8_t f)   { g_flags &= ~f; fpga_spi_reg_write(DBG_FLAGS, g_flags); }
/* Heartbeat: bump the counter + toggle the heartbeat bit so a live loop is
 * visibly distinguishable from a hung one on screen. */
static inline void dbg_tick(void)
{
    fpga_spi_reg_write(DBG_COUNTER, ++g_counter);
    g_flags ^= F_HEARTBEAT;
    fpga_spi_reg_write(DBG_FLAGS, g_flags);
}

USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_xinput_buf[64];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_xinput_out[8];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_xinput_ctrl[64];

/* Full XInput start sequence, ported from the proven BL616 implementation in
 * nand2mario/firmware-bl616 + MiSTle-Dev/FPGA-Companion (usb_gamepad.cpp).
 * The two GET_STRING_DESCRIPTOR reads are the piece we were missing — the comment
 * there literally says "SN30pro needs this". Order: 4 control transfers, then 4
 * interrupt-OUT packets, THEN the IN loop is armed (control xfers must not race a
 * pending IN URB). Returns the result of the first vendor control transfer. */
static const struct {
    uint8_t bmRequestType, bRequest;
    uint16_t wValue, wIndex, wLength;
} k_xbox_init_ctrl[4] = {
    {0x80, 0x06, 0x0302, 0x0409, 2},   /* GET_STRING_DESCRIPTOR (SN30 Pro needs this) */
    {0x80, 0x06, 0x0302, 0x0409, 32},  /* GET_STRING_DESCRIPTOR */
    {0xC1, 0x01, 0x0100, 0x0000, 20},  /* vendor control 1 (many pads need this) */
    {0xC1, 0x01, 0x0000, 0x0000, 8},   /* vendor control 2 */
};
static const uint8_t k_xbox_ep2[4][3] = {
    {0x01, 0x03, 0x02}, {0x02, 0x08, 0x03}, {0x01, 0x03, 0x02}, {0x01, 0x03, 0x06},
};

static int xinput_send_init(struct usbh_xinput *xc)
{
    struct usb_setup_packet *setup = xc->hport->setup;
    int ret = 0;

    /* 1) four control transfers on EP0 (string reads + vendor) */
    for (int i = 0; i < 4; i++) {
        setup->bmRequestType = k_xbox_init_ctrl[i].bmRequestType;
        setup->bRequest      = k_xbox_init_ctrl[i].bRequest;
        setup->wValue        = k_xbox_init_ctrl[i].wValue;
        setup->wIndex        = k_xbox_init_ctrl[i].wIndex;
        setup->wLength       = k_xbox_init_ctrl[i].wLength;
        ret = usbh_control_transfer(xc->hport->ep0, setup, g_xinput_ctrl);
    }

    /* 2) four interrupt-OUT packets (LED/rumble) on EP2 */
    if (xc->intout) {
        struct usbh_urb urb;
        for (int i = 0; i < 4; i++) {
            memcpy(g_xinput_out, k_xbox_ep2[i], 3);
            usbh_int_urb_fill(&urb, xc->intout, g_xinput_out, 3, 500, NULL, NULL);
            usbh_submit_urb(&urb);
        }
    }
    return ret;
}

static volatile bool g_menu_active = false;

/* Draw the placeholder menu into the Apple II text screen. */
static void menu_show(void)
{
    fpga_screen_clear();
    fpga_screen_home();
    fpga_screen_puts("  A2FPGA MENU  ");
    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1); /* override: force our text screen */
}

/* Hand the display back to the live Apple II soft-switches. */
static void menu_hide(void)
{
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 0); /* enable=0 -> Apple II drives video */
}

static void menu_toggle(void)
{
    g_menu_active = !g_menu_active;
    if (g_menu_active) {
        menu_show();
    } else {
        menu_hide();
    }
}

/* Called by usbh_xinput.c when a controller enumerates. */
void usbh_xinput_run(struct usbh_xinput *xinput_class)
{
    (void)xinput_class;
    dbg_stage(STG_CONNECTED);
    dbg_set(F_CONNECTED);
    g_need_init = true;   /* tell the poll thread to (re)init this controller */
    fpga_screen_clear();
    fpga_screen_home();
    fpga_screen_puts("XInput controller connected");
}

void usbh_xinput_stop(struct usbh_xinput *xinput_class)
{
    (void)xinput_class;
    dbg_clr(F_CONNECTED);
}

/* Async interrupt-IN read. Interrupt endpoints NAK until data is ready, and the
 * SDK only ever reads them via this callback pattern (sync reads just time out).
 * Counter ticks per report now, so: MOVING = reports flowing, FROZEN = silent. */
static struct usbh_urb     g_in_urb;
static struct usbh_xinput *g_dev = NULL;
static uint16_t            g_prev_buttons = 0;

static void xinput_in_cb(void *arg, int nbytes)
{
    (void)arg;
    if (nbytes > 0) {
        struct xinput_state st;
        if (usbh_xinput_parse(g_xinput_buf, nbytes, &st)) {
            dbg_stage(STG_REPORT);
            fpga_spi_reg_write(DBG_BTN_LO, (uint8_t)(st.buttons & 0xFF));
            fpga_spi_reg_write(DBG_BTN_HI, (uint8_t)(st.buttons >> 8));
            uint16_t pressed = st.buttons & ~g_prev_buttons; /* rising edges */
            if (pressed & XINPUT_BACK) {                     /* Select pressed */
                menu_toggle();
            }
            g_prev_buttons = st.buttons;
        }
        dbg_tick();
        usbh_submit_urb(&g_in_urb);  /* re-arm for the next report */
    } else {
        fpga_spi_reg_write(DBG_BTN_HI, (uint8_t)(-nbytes)); /* error code */
        g_dev = NULL;                /* force re-arm on next thread loop */
    }
}

/* Find the first connected XInput controller. The device slot ("/dev/xinputN")
 * isn't always N=0 across hot-plugs (the old slot may not be freed before the
 * new pad enumerates), so scan a few. */
static struct usbh_xinput *xinput_find(void)
{
    for (int m = 0; m < 4; m++) {
        char name[16];
        snprintf(name, sizeof(name), "/dev/xinput%d", m);
        struct usbh_xinput *xc = (struct usbh_xinput *)usbh_find_class_instance(name);
        if (xc) {
            return xc;
        }
    }
    return NULL;
}

static void xinput_thread(void *arg)
{
    (void)arg;

    while (1) {
        struct usbh_xinput *xinput_class = xinput_find();
        if (xinput_class == NULL) {
            /* Not connected. Show EHCI port status: hex[1]=PORTSC low (bit0 CCS),
             * hex[2]=PORTSC high. Only the thread does SPI here. BUT if a CDC-ECM
             * device is active it owns the overlay (DHCP IP), so stay quiet. */
            if (!g_net_active) {
                uint32_t portsc = EHCI_PORTSC0;
                dbg_stage(STG_SEARCH);
                fpga_spi_reg_write(DBG_BTN_LO, (uint8_t)(portsc & 0xFF));
                fpga_spi_reg_write(DBG_BTN_HI, (uint8_t)((portsc >> 8) & 0xFF));
                dbg_tick();              /* heartbeat while searching */
            }
            g_dev = NULL;
            g_prev_buttons = 0;
            usb_osal_msleep(500);
            continue;
        }

        /* (Re)initialize on a fresh connection. Triggered by g_need_init (set by
         * the connect callback for EVERY new pad) OR a changed instance pointer —
         * either alone is unreliable for hot-plug, together they're robust. */
        if (g_need_init || xinput_class != g_dev) {
            g_need_init = false;
            g_dev = xinput_class;
            g_prev_buttons = 0;
            /* Full XInput init (control transfers + EP2 packets) FIRST, then arm
             * the async IN read (control transfers must not race a pending IN). */
            int ir = xinput_send_init(xinput_class);
            fpga_spi_reg_write(DBG_BTN_HI, (uint8_t)(-ir)); /* hex[2] = init result */
            usbh_int_urb_fill(&g_in_urb, xinput_class->intin, g_xinput_buf,
                              sizeof(g_xinput_buf), 0, xinput_in_cb, xinput_class);
            usbh_submit_urb(&g_in_urb);
        }

        /* Connected: the callback owns the overlay/SPI now; thread just polls. */
        usb_osal_msleep(500);
    }
}

/* ===================== USB-Ethernet (CDC-ECM) glue =======================
 * usbh_cdc_ecm.c (in usb_net/) handles the USB side: it matches the RTL8153
 * by VID/PID, switches it to its config-2 CDC-ECM, and brings up the bulk
 * data path. The hooks below provide (a) breadcrumb tracing onto the HDMI
 * DebugOverlay during connect, and (b) the lwIP netif + DHCP bring-up. Once
 * DHCP binds, the leased IP's four octets are written to the overlay hex regs
 * (stage 0xEA) — that on-screen IP is the MVP proof of MCU-on-network. */

static struct netif g_ecm_netif;

/* Breadcrumb overrides (weak in usbh_cdc_ecm.c). Stage 0xE0..0xEF tracks how
 * far connect() got; bytes 0..2 carry parsed intf numbers / MAC bytes. */
void ecm_dbg_stage(uint8_t code) { fpga_spi_reg_write(DBG_STAGE, code); }
void ecm_dbg_byte(uint8_t idx, uint8_t val)
{
    switch (idx) {
        case 0: fpga_spi_reg_write(DBG_BTN_LO, val);  break;
        case 1: fpga_spi_reg_write(DBG_BTN_HI, val);  break;
        case 2: fpga_spi_reg_write(DBG_COUNTER, val); break;
        default: break;
    }
}

static err_t ecm_netif_init(struct netif *netif)
{
    struct usbh_cdc_ecm *ecm = usbh_cdc_ecm_get_class();
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;
    netif->linkoutput = usbh_cdc_ecm_linkoutput;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP;
    netif->hwaddr_len = 6;
    if (ecm) {
        memcpy(netif->hwaddr, ecm->mac, 6);
    }
    return ERR_OK;
}

/* Runs on the lwIP tcpip thread (via tcpip_callback) — lwIP core calls must
 * not be made from the USB enumeration thread directly. */
static void ecm_netif_setup_cb(void *ctx)
{
    (void)ctx;
    ip4_addr_t any;
    ip4_addr_set_zero(&any);
    netif_add(&g_ecm_netif, &any, &any, &any, NULL, ecm_netif_init, tcpip_input);
    netif_set_default(&g_ecm_netif);
    netif_set_up(&g_ecm_netif);
    netif_set_link_up(&g_ecm_netif);
    dhcp_start(&g_ecm_netif);
}

/* Poll the netif and surface the DHCP-leased IP on the overlay hex regs. */
static void ecm_ip_report_thread(void *arg)
{
    struct netif *netif = (struct netif *)arg;
    uint32_t last = 0;
    while (1) {
        uint32_t ip = netif_ip4_addr(netif)->addr; /* network byte order */
        if (ip != last) {
            last = ip;
            if (ip != 0) {
                const uint8_t *o = (const uint8_t *)&ip;
                fpga_spi_reg_write(DBG_STAGE, 0xEA); /* 0xEA = DHCP bound */
                fpga_spi_reg_write(DBG_BTN_LO, o[0]);
                fpga_spi_reg_write(DBG_BTN_HI, o[1]);
                fpga_spi_reg_write(DBG_COUNTER, o[2]);
                fpga_spi_reg_write(DBG_FLAGS, o[3]);
            }
        }
        usb_osal_msleep(500);
    }
}

void usbh_cdc_ecm_run(struct usbh_cdc_ecm *ecm)
{
    g_net_active = true;                          /* take over the overlay */
    ecm->netif = &g_ecm_netif;
    tcpip_callback(ecm_netif_setup_cb, NULL);     /* netif+dhcp on tcpip thread */
    usbh_cdc_ecm_lwip_thread_init(&g_ecm_netif);  /* bulk-IN rx thread */
    usb_osal_thread_create("ecm_ip", 1024, CONFIG_USBHOST_PSC_PRIO + 1,
                           ecm_ip_report_thread, &g_ecm_netif);
}

void usbh_cdc_ecm_stop(struct usbh_cdc_ecm *ecm)
{
    (void)ecm;
    g_net_active = false;
    netif_set_down(&g_ecm_netif);
    dhcp_stop(&g_ecm_netif);
}

int main(void)
{
    board_init();

    /* SPI link to the FPGA works regardless of USB role. */
    fpga_spi_init();
    dbg_stage(STG_SPI_INIT);
    dbg_set(F_SPI_INIT);

    bool ready = fpga_spi_wait_ready(2000);
    dbg_stage(STG_FPGA_READY);
    if (ready) dbg_set(F_FPGA_READY);

    fpga_screen_clear();
    fpga_screen_home();
    fpga_screen_puts("USB host mode: waiting for joystick...");
    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
    dbg_stage(STG_PRE_USB);

    printf("A2N20 BL616 USB-host (XInput) build started\r\n");

    tcpip_init(NULL, NULL);   /* bring up the lwIP TCP/IP thread before USB host */

    usbh_initialize();
    dbg_stage(STG_USBH_INIT);
    dbg_set(F_USBH_INIT);

    usb_osal_thread_create("xinput", 2048, CONFIG_USBHOST_PSC_PRIO + 1, xinput_thread, NULL);
    dbg_stage(STG_SCHED);
    dbg_set(F_THREAD_UP);

    vTaskStartScheduler();

    while (1) {
    }
}
