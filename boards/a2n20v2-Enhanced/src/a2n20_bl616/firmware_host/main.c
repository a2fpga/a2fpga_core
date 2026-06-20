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
#include "usbh_rtl8152.h"   /* stock vendor driver for the RTL8152 adapter */
#include "usbh_asix.h"      /* stock vendor driver for ASIX AX88772x adapters */
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
        ret = usbh_control_transfer(xc->hport, setup, g_xinput_ctrl);
    }

    /* 2) four interrupt-OUT packets (LED/rumble) on EP2 */
    if (xc->intout) {
        for (int i = 0; i < 4; i++) {
            memcpy(g_xinput_out, k_xbox_ep2[i], 3);
            usbh_int_urb_fill(&xc->intout_urb, xc->hport, xc->intout, g_xinput_out, 3, 500, NULL, NULL);
            usbh_submit_urb(&xc->intout_urb);
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
static struct usbh_xinput *g_dev = NULL;
static uint16_t            g_prev_buttons = 0;

static void xinput_in_cb(void *arg, int nbytes)
{
    struct usbh_xinput *xc = (struct usbh_xinput *)arg;
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
        if (xc) {
            usbh_submit_urb(&xc->intin_urb);  /* re-arm for the next report */
        }
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
            usbh_int_urb_fill(&xinput_class->intin_urb, xinput_class->hport, xinput_class->intin,
                              g_xinput_buf, sizeof(g_xinput_buf), 0, xinput_in_cb, xinput_class);
            usbh_submit_urb(&xinput_class->intin_urb);
        }

        /* Connected: the callback owns the overlay/SPI now; thread just polls. */
        usb_osal_msleep(500);
    }
}

/* ===================== USB-Ethernet (CDC-ECM) glue =======================
 * On CherryUSB v1.5.3 we use the STOCK usbh_cdc_ecm.c driver. Our RTL8153 is
 * dual-config (config 1 = Realtek vendor, config 2 = CDC-ECM); v1.5.3 added the
 * weak hook usbh_get_hport_active_config_index(), so we override it to make the
 * core enumerate config 2 for that adapter — then the stock CDC-ECM class
 * matches with no SDK edits and no custom driver. The glue below is just the
 * lwIP netif + DHCP bring-up plus the RX/TX bridge to the stock driver. Once
 * DHCP binds, the leased IP's four octets are written to the overlay hex regs
 * (stage 0xEA) — that on-screen IP is the MVP proof of MCU-on-network. */

#define RTL8153_VID 0x0BDA
#define RTL8153_PID 0x8153

static struct netif g_ecm_netif;

/* Route EVERY device to its DEFAULT config (index 0). For the dual-config
 * RTL8153 that is config 1 = the Realtek VENDOR interface, so the stock
 * usbh_rtl8152 vendor driver claims it (it handles RTL_VER_09) and runs the
 * vendor RX-engine init (rtl_ops.enable) that the generic CDC-ECM path skips.
 * (Previously we forced config 2 = CDC-ECM here; that path never received. We
 * keep the CDC-ECM driver compiled but no longer steer the 8153 to it.) */
uint8_t usbh_get_hport_active_config_index(struct usbh_hubport *hport)
{
    (void)hport;
    return 0;
}

/* ---- EXPERIMENT: async interrupt-IN (notification) + async bulk-IN ----------
 * Neither prior attempt ran this config. The STOCK rx thread blocks forever on a
 * sync interrupt-IN status read (get_connect_status, WAITING_FOREVER) and gates
 * bulk-IN behind it. Our earlier CUSTOM rx omitted the interrupt endpoint
 * entirely. Linux's usbnet keeps a status URB continuously outstanding (async,
 * non-gating) AND submits bulk-IN independently. This mirrors that: arm an async
 * intin read that just re-arms forever, plus an async bulk-IN, neither gating the
 * other. Hypothesis: the RTL8153 ECM won't forward RX until intin is serviced. */
static volatile bool     g_netif_ready = false;
static struct usbh_cdc_ecm *g_ecm = NULL;
static volatile uint32_t g_eth_tx = 0;   /* linkoutput calls */
static volatile uint32_t g_eth_bn = 0;   /* bulk-IN callback fires (any nbytes) */
static volatile uint32_t g_eth_rx = 0;   /* bulk-IN frames with data -> lwIP */
static volatile uint32_t g_eth_nh = 0;   /* interrupt-IN (notification) fires */
static volatile int      g_eth_last = 0; /* last bulk-IN nbytes/err */
static volatile uint8_t  g_nt_code = 0xee; /* last notification bNotificationCode */
static volatile uint16_t g_nt_val  = 0;    /* last notification wValue (link state) */
static volatile int      g_eth_armret = -1; /* return of the bulk-IN submit */
static volatile uint8_t  g_bi_addr = 0, g_bo_addr = 0, g_ii_addr = 0; /* bound EP addrs */
static volatile uint16_t g_bi_mps = 0;     /* bulk-IN max packet size */
static volatile uint8_t  g_data_an = 0;    /* data interface altsetting_num */
static volatile int      g_si_ret = -1;    /* our SET_INTERFACE(data) return */

/* Carrier-gated RX re-arm (Linux usbnet parity). Linux only submits RX URBs
 * AFTER netif_carrier_on(), which fires when the interrupt-IN status reports
 * NETWORK_CONNECTION=connected. CherryUSB arms RX at connect() time, before the
 * notification, and never re-arms. We replicate Linux: defer the first bulk-IN
 * submit until carrier-up, then re-assert SET_INTERFACE(alt) + packet filter and
 * only then queue the read. See agent line-by-line analysis (2026-06-18). */
static volatile bool g_carrier_up   = false; /* set by intin_cb on link-up */
static volatile bool g_rearm_done   = false; /* re-arm performed once */
/* Host bulk-IN data toggle. CherryUSB v1.5.3 stores the toggle per-URB and only
 * advances it on a COMPLETED transfer; SET_INTERFACE resets the DEVICE toggle
 * but not the host's. If they disagree, EHCI silently drops every IN packet and
 * the qTD stays Active forever (bn=0, no error). We own g_eth_bulkin_urb, and
 * usbh_bulk_urb_fill does not clear data_toggle, so we drive it directly and
 * sweep 0<->1 until the first frame lands; after that the HC carries it forward. */
static volatile uint8_t  g_force_toggle = 0; /* host bulk-IN toggle to try next */
static volatile uint32_t g_tog_sweeps   = 0; /* toggle flips attempted */

USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_eth_inbuf[1600];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_eth_ntbuf[16];
static struct usbh_urb g_eth_bulkin_urb;
static struct usbh_urb g_eth_intin_urb;

/* One-line status on the Apple II text screen (persists; not overwritten by the
 * xinput search loop, which only touches the overlay). */
static void eth_status(const char *msg)
{
    fpga_screen_clear();
    fpga_screen_home();
    fpga_screen_puts(msg);
    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
}

/* netif->linkoutput: stock TX (works). */
static err_t ecm_linkoutput(struct netif *netif, struct pbuf *p)
{
    (void)netif;
    uint8_t *txbuf = usbh_cdc_ecm_get_eth_txbuf();
    if (txbuf == NULL || p->tot_len > 1514) {
        return ERR_BUF;
    }
    uint8_t *q = txbuf;
    for (struct pbuf *it = p; it != NULL; it = it->next) {
        memcpy(q, it->payload, it->len);
        q += it->len;
    }
    g_eth_tx++;
    return (usbh_cdc_ecm_eth_output(p->tot_len) < 0) ? ERR_IF : ERR_OK;
}

/* Deliver a received frame to lwIP (guarded against pre-netif_add). */
void usbh_cdc_ecm_eth_input(uint8_t *buf, uint32_t buflen)
{
    if (buflen == 0 || !g_netif_ready || g_ecm_netif.input == NULL) {
        return;
    }
    struct pbuf *p = pbuf_alloc(PBUF_RAW, buflen, PBUF_POOL);
    if (p == NULL) {
        return;
    }
    memcpy(p->payload, buf, buflen);
    if (g_ecm_netif.input(p, &g_ecm_netif) != ERR_OK) {
        pbuf_free(p);
    }
}

/* async bulk-IN completion → deliver + re-arm */
static void eth_bulkin_cb(void *arg, int nbytes)
{
    (void)arg;
    g_eth_bn++;
    g_eth_last = nbytes;
    if (nbytes > 0) {
        g_eth_rx++;
        usbh_cdc_ecm_eth_input(g_eth_inbuf, (uint32_t)nbytes);
    }
    if (g_ecm && g_ecm->bulkin) {
        usbh_submit_urb(&g_eth_bulkin_urb);  /* re-arm */
    }
}

/* async interrupt-IN (CDC notification) completion → just count + re-arm, so a
 * status URB stays continuously outstanding like Linux usbnet (non-gating). */
static void eth_intin_cb(void *arg, int nbytes)
{
    (void)arg;
    g_eth_nh++;
    if (nbytes >= 4) {
        /* CDC notification: [1]=bNotificationCode, [2..3]=wValue.
         * NETWORK_CONNECTION(0x00): wValue 1=connected,0=disconnected.
         * CONNECTION_SPEED_CHANGE(0x2A). */
        g_nt_code = g_eth_ntbuf[1];
        g_nt_val  = (uint16_t)g_eth_ntbuf[2] | ((uint16_t)g_eth_ntbuf[3] << 8);
        /* Carrier-up edge: NETWORK_CONNECTION=connected, or a speed-change
         * report (the device only emits 0x2A once the link is live). The report
         * thread does the actual re-arm (control transfers need thread context,
         * not this completion callback). */
        if ((g_nt_code == CDC_ECM_NOTIFY_CODE_NETWORK_CONNECTION && g_nt_val != 0) ||
            g_nt_code == CDC_ECM_NOTIFY_CODE_CONNECTION_SPEED_CHANGE) {
            g_carrier_up = true;
        }
    }
    if (g_ecm && g_ecm->intin) {
        usbh_submit_urb(&g_eth_intin_urb);   /* keep it outstanding */
    }
}

/* Carrier-gated RX arm — the PURE Linux-parity test. Linux usbnet does NOT
 * re-send any control transfers after carrier; cdc_ether sends SET_INTERFACE +
 * SET_ETHERNET_PACKET_FILTER once at bind (we already did, at connect), and the
 * ONLY thing usbnet defers to post-carrier is the RX URB submission. So here we
 * just submit the bulk-IN, nothing else.
 *
 * (Earlier this also re-sent SET_INTERFACE/CLEAR_FEATURE/SET_ETHERNET_PACKET_
 * FILTER after carrier; the device STALLed the filter and clear-halt — f8/h8 —
 * even though the identical filter succeeded at enumeration. Re-issuing those
 * post-carrier corrupts the control endpoint, so they are removed. This isolates
 * the real question: does deferring only the bulk-IN submit to post-carrier make
 * the RTL8153 stream RX?) */
static void eth_rearm_rx_path(void)
{
    struct usbh_cdc_ecm *ecm = g_ecm;
    if (!ecm || !ecm->hport || !ecm->bulkin) {
        return;
    }
    usbh_bulk_urb_fill(&g_eth_bulkin_urb, ecm->hport, ecm->bulkin, g_eth_inbuf,
                       1536, 0 /*async*/, eth_bulkin_cb, NULL);
    g_eth_bulkin_urb.data_toggle = g_force_toggle; /* we own the host toggle */
    g_eth_armret = usbh_submit_urb(&g_eth_bulkin_urb);
    g_rearm_done = true;
}

/* Recover a host/device bulk-IN data-toggle mismatch: kill the stuck (forever-
 * Active) URB, flip the host toggle, and resubmit. Called from the report
 * thread while bn==0; once the first frame lands the HC carries the correct
 * toggle forward via eth_bulkin_cb's re-arm, so we stop sweeping. */
static void eth_toggle_sweep(void)
{
    struct usbh_cdc_ecm *ecm = g_ecm;
    /* Gate on real frames (g_eth_rx), NOT g_eth_bn: usbh_kill_urb itself fires
     * the completion callback with a cancel status, which bumps g_eth_bn — so a
     * bn-based gate would stop the sweep after its own first kill. */
    if (!ecm || !ecm->bulkin || g_eth_rx != 0) return; /* don't disturb a live pipe */
    usbh_kill_urb(&g_eth_bulkin_urb);
    g_force_toggle ^= 1;
    g_tog_sweeps++;
    usbh_bulk_urb_fill(&g_eth_bulkin_urb, ecm->hport, ecm->bulkin, g_eth_inbuf,
                       1536, 0 /*async*/, eth_bulkin_cb, NULL);
    g_eth_bulkin_urb.data_toggle = g_force_toggle;
    g_eth_armret = usbh_submit_urb(&g_eth_bulkin_urb);
}

static err_t ecm_netif_init(struct netif *netif)
{
    struct usbh_cdc_ecm *ecm = (struct usbh_cdc_ecm *)usbh_find_class_instance("/dev/cdc_ether");
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;
    netif->linkoutput = ecm_linkoutput;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP;
    netif->hwaddr_len = 6;
    if (ecm) {
        memcpy(netif->hwaddr, ecm->mac, 6);
    }
    return ERR_OK;
}

static void ecm_netif_setup_cb(void *ctx)
{
    (void)ctx;
    ip4_addr_t any;
    ip4_addr_set_zero(&any);
    netif_add(&g_ecm_netif, &any, &any, &any, NULL, ecm_netif_init, tcpip_input);
    netif_set_default(&g_ecm_netif);
    netif_set_up(&g_ecm_netif);
    netif_set_link_up(&g_ecm_netif);
    g_netif_ready = true;
    dhcp_start(&g_ecm_netif);
}

/* Surface the DHCP IP once bound; until then show the live traffic counters so we
 * can see whether servicing intin makes bulk-IN start completing. */
static void ecm_ip_report_thread(void *arg)
{
    struct netif *netif = (struct netif *)arg;
    uint32_t last = 0, iter = 0, sweep_div = 0;
    while (1) {
        /* Carrier-gated RX arming (Linux parity): once the link-up notification
         * has arrived, queue the first bulk-IN. */
        if (g_carrier_up && !g_rearm_done) {
            eth_rearm_rx_path();
        } else if (g_rearm_done && g_eth_rx == 0 && g_tog_sweeps < 1) {
            /* Disambiguate toggle-mismatch from a dead bulk-IN WITHOUT the
             * repeated-kill confound (this EHCI's async kill/re-arm path is
             * fragile). Leave toggle 0 armed and UNTOUCHED for ~5s; if still no
             * real frame, do EXACTLY ONE flip to toggle 1 and then leave that
             * armed indefinitely (g_tog_sweeps<1 gate => no further kills). So:
             * toggle0 for 5s, then toggle1 forever. If neither delivers real
             * data (l stays <=0), it is NOT a toggle issue. */
            if (++sweep_div >= 10) { sweep_div = 0; eth_toggle_sweep(); }
        }
        uint32_t ip = netif_ip4_addr(netif)->addr;
        if (ip != 0) {
            if (ip != last) {
                last = ip;
                const uint8_t *o = (const uint8_t *)&ip;
                char line[24];
                snprintf(line, sizeof(line), "ETH IP %u.%u.%u.%u", o[0], o[1], o[2], o[3]);
                eth_status(line);
            }
        } else {
            char line[40];
            /* tg=host bulk-IN toggle  sw=toggle flips  bn=completions (incl.
             * kill-cancels)  rx=real frames  l=last nbytes (<0 err/cancel, 0 ZLP,
             * >0 data) */
            snprintf(line, sizeof(line), "tg%d sw%lu bn%lu rx%lu l%d",
                     g_force_toggle, (unsigned long)g_tog_sweeps,
                     (unsigned long)g_eth_bn, (unsigned long)g_eth_rx, g_eth_last);
            eth_status(line);
            fpga_spi_reg_write(DBG_COUNTER, (uint8_t)(++iter)); /* heartbeat */
        }
        usb_osal_msleep(500);
    }
}

void usbh_cdc_ecm_run(struct usbh_cdc_ecm *ecm)
{
    g_ecm = ecm;
    g_eth_tx = g_eth_bn = g_eth_rx = g_eth_nh = 0;
    if (ecm) {
        ecm->connect_status = true;   /* unblock stock TX; do NOT gate RX on it */
        if (ecm->bulkin)  { g_bi_addr = ecm->bulkin->bEndpointAddress;  g_bi_mps = ecm->bulkin->wMaxPacketSize; }
        if (ecm->bulkout) { g_bo_addr = ecm->bulkout->bEndpointAddress; }
        if (ecm->intin)   { g_ii_addr = ecm->intin->bEndpointAddress; }

        /* THE FIX: explicitly SET_INTERFACE the data interface to arm the RX
         * datapath. Stock connect() skips SET_INTERFACE when the data interface
         * has a single altsetting; Linux's usbnet issues it unconditionally
         * ("traffic can't flow until an altsetting is enabled"). Do an
         * alt0->alt_enabled cycle (degenerates to SET_INTERFACE(0) for a single
         * altsetting), BEFORE arming the bulk-IN so the toggle is fresh. */
        g_data_an = ecm->hport->config.intf[ecm->data_intf].altsetting_num;
        uint8_t data_alt = (g_data_an > 1) ? (g_data_an - 1) : 0;
        if (g_data_an > 1) {
            usbh_set_interface(ecm->hport, ecm->data_intf, 0);
        }
        g_si_ret = usbh_set_interface(ecm->hport, ecm->data_intf, data_alt);
    }
    g_net_active = true;
    tcpip_callback(ecm_netif_setup_cb, NULL);

    /* Arm ONLY the interrupt-IN status read now. The bulk-IN read is deferred to
     * eth_rearm_rx_path(), triggered from the report thread once intin reports
     * carrier-up — this is the whole point of the experiment (Linux submits RX
     * only post-carrier). Reset the carrier/re-arm latches for this device. */
    g_carrier_up = false;
    g_rearm_done = false;
    g_eth_armret = -1;
    if (ecm && ecm->intin) {
        usbh_int_urb_fill(&g_eth_intin_urb, ecm->hport, ecm->intin, g_eth_ntbuf,
                          16, 0 /*async*/, eth_intin_cb, NULL);
        usbh_submit_urb(&g_eth_intin_urb);
    }

    usb_osal_thread_create("ecm_ip", 1024, CONFIG_USBHOST_PSC_PRIO + 1,
                           ecm_ip_report_thread, &g_ecm_netif);
}

void usbh_cdc_ecm_stop(struct usbh_cdc_ecm *ecm)
{
    (void)ecm;
    g_net_active = false;
    g_netif_ready = false;
    g_ecm = NULL;   /* stop callbacks from re-arming */
    netif_set_down(&g_ecm_netif);
    dhcp_stop(&g_ecm_netif);
}

/* ===================== USB-Ethernet (RTL8152) glue ========================
 * The stock CherryUSB usbh_rtl8152.c vendor driver owns enumeration, the vendor
 * RX-engine init (rtl_ops.enable), RX-mode/speed, and its OWN rx_thread that
 * reads bulk-IN, strips the rx_desc headers, and calls usbh_rtl8152_eth_input()
 * per frame. So our glue is only: lwIP netif + DHCP, the eth_input->lwIP bridge,
 * TX via the driver's tx buffer, and spawning the driver's rx_thread. This is
 * the SUPPORTED path (contrast the hand-rolled CDC-ECM RX above). */
static struct netif      g_rtl_netif;
static struct usbh_rtl8152 *g_rtl = NULL;
static volatile uint32_t g_rtl_rx = 0;   /* frames delivered to lwIP */
static volatile uint32_t g_rtl_tx = 0;   /* frames sent via linkoutput */

/* RX: the driver's rx_thread calls this once per received Ethernet frame.
 * NOTE: this needs a non-zero lwIP pbuf pool — see CMakeLists.txt
 * (PBUF_POOL_SIZE defaults to 0 in the SDK lwipopts, which silently drops
 * every RX frame here). */
void usbh_rtl8152_eth_input(uint8_t *buf, uint32_t buflen)
{
    if (buflen == 0 || !g_netif_ready || g_rtl_netif.input == NULL) {
        return;
    }
    struct pbuf *p = pbuf_alloc(PBUF_RAW, buflen, PBUF_POOL);
    if (p == NULL) {
        return;
    }
    pbuf_take(p, buf, buflen);
    g_rtl_rx++;
    if (g_rtl_netif.input(p, &g_rtl_netif) != ERR_OK) {
        pbuf_free(p);
    }
}

/* TX: copy the pbuf into the driver's tx buffer (after its tx_desc) and send. */
static err_t rtl_linkoutput(struct netif *netif, struct pbuf *p)
{
    (void)netif;
    uint8_t *txbuf = usbh_rtl8152_get_eth_txbuf();
    if (txbuf == NULL) {
        return ERR_IF;
    }
    pbuf_copy_partial(p, txbuf, p->tot_len, 0);
    g_rtl_tx++;
    return (usbh_rtl8152_eth_output(p->tot_len) < 0) ? ERR_IF : ERR_OK;
}

static err_t rtl_netif_init(struct netif *netif)
{
    struct usbh_rtl8152 *r = (struct usbh_rtl8152 *)usbh_find_class_instance("/dev/rtl8152");
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;
    netif->linkoutput = rtl_linkoutput;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP;
    netif->hwaddr_len = 6;
    if (r) {
        memcpy(netif->hwaddr, r->mac, 6);
    }
    return ERR_OK;
}

static void rtl_netif_setup_cb(void *ctx)
{
    (void)ctx;
    ip4_addr_t any;
    ip4_addr_set_zero(&any);
    netif_add(&g_rtl_netif, &any, &any, &any, NULL, rtl_netif_init, tcpip_input);
    netif_set_default(&g_rtl_netif);
    netif_set_up(&g_rtl_netif);
    netif_set_link_up(&g_rtl_netif);
    g_netif_ready = true;
    dhcp_start(&g_rtl_netif);
}

/* Shared USB-Ethernet status overlay (used by every adapter's glue). Spawned by
 * a driver's run(); renders a clean status (link / rx / tx / IP) and exits +
 * self-deletes on disconnect (g_net_active) so a re-plug spawns exactly one
 * fresh reporter instead of accumulating threads that fight over the screen. */
typedef bool (*eth_link_fn)(void);
static void eth_report_thread(struct netif *netif, const char *chip,
                              const volatile uint32_t *rxp,
                              const volatile uint32_t *txp,
                              eth_link_fn link_up)
{
    uint32_t iter = 0;
    /* static: keep these buffers OFF the small thread stack. */
    static char s[1024];
    static char line[48];
    /* Clear ONCE, then overwrite in place with fixed-width lines (per-frame
     * clear caused visible flicker). */
    fpga_screen_clear();
    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
#define EMIT(...) do { \
        if (n >= 0 && (size_t)n + 42 < sizeof(s)) { \
            snprintf(line, sizeof(line), __VA_ARGS__); \
            int _w = snprintf(s + n, sizeof(s) - n, "%-39.39s\n", line); \
            if (_w > 0) n += _w; \
        } \
    } while (0)
    while (g_net_active) {
        uint32_t ip = netif_ip4_addr(netif)->addr;
        const uint8_t *o = (const uint8_t *)&ip;
        int n = 0;
        EMIT("A2N20 USB-Ethernet (%s)  #%lu", chip, (unsigned long)(++iter));
        EMIT("link:%s", link_up() ? "up" : "down");
        EMIT("rx:%lu  tx:%lu", (unsigned long)*rxp, (unsigned long)*txp);
        if (ip != 0) {
            EMIT("IP: %u.%u.%u.%u", o[0], o[1], o[2], o[3]);
        } else {
            EMIT("IP: (requesting via DHCP...)");
        }
        (void)n;
        fpga_screen_home();
        fpga_screen_puts(s);
        fpga_spi_reg_write(DBG_COUNTER, (uint8_t)iter); /* heartbeat */
        usb_osal_msleep(500);
    }
#undef EMIT
    usb_osal_thread_delete(NULL);
}

static bool rtl_link_up(void) { return g_rtl && g_rtl->connect_status; }
static void rtl_ip_report_thread(void *arg)
{
    eth_report_thread((struct netif *)arg, "RTL8152", &g_rtl_rx, &g_rtl_tx, rtl_link_up);
}

void usbh_rtl8152_run(struct usbh_rtl8152 *class)
{
    g_rtl = class;
    g_rtl_rx = 0;
    g_net_active = true;
    tcpip_callback(rtl_netif_setup_cb, NULL);
    /* The driver's rx_thread does connect-wait, rtl_ops.enable, and the bulk-IN
     * RX loop; spawn it once here (it self-deletes on disconnect). */
    usb_osal_thread_create("rtl_rx", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                           usbh_rtl8152_rx_thread, NULL);
    usb_osal_thread_create("rtl_ip", 2048, CONFIG_USBHOST_PSC_PRIO + 1,
                           rtl_ip_report_thread, &g_rtl_netif);
}

/* netif teardown must run on the tcpip thread (lwIP isn't reentrant). netif_remove
 * is essential: without it, a re-plug calls netif_add on an already-added netif
 * (lwIP list corruption) -> hot-plug back to the adapter fails. */
static void rtl_netif_teardown_cb(void *ctx)
{
    (void)ctx;
    dhcp_stop(&g_rtl_netif);
    netif_remove(&g_rtl_netif);
}

void usbh_rtl8152_stop(struct usbh_rtl8152 *class)
{
    (void)class;
    g_net_active = false;   /* report thread sees this and self-deletes */
    g_netif_ready = false;  /* eth_input drops any in-flight frames */
    g_rtl = NULL;
    tcpip_callback(rtl_netif_teardown_cb, NULL);
}

/* ===================== USB-Ethernet (ASIX AX88772x) glue ====================
 * Same pattern as the RTL8152 glue above, against the stock CherryUSB usbh_asix
 * vendor driver (AX88772 / 772A / 772B). Both drivers are enabled and coexist —
 * whichever adapter is plugged in, only its own run()/stop() fires (one Ethernet
 * adapter at a time; g_net_active / g_netif_ready are shared). Uses the same
 * pbuf pool (CMakeLists -DPBUF_POOL_SIZE) — that fix applies to all adapters. */
static struct netif      g_asix_netif;
static struct usbh_asix  *g_asix = NULL;
static volatile uint32_t g_asix_rx = 0;   /* frames delivered to lwIP */
static volatile uint32_t g_asix_tx = 0;   /* frames sent via linkoutput */

void usbh_asix_eth_input(uint8_t *buf, uint32_t buflen)
{
    if (buflen == 0 || !g_netif_ready || g_asix_netif.input == NULL) {
        return;
    }
    struct pbuf *p = pbuf_alloc(PBUF_RAW, buflen, PBUF_POOL);
    if (p == NULL) {
        return;
    }
    pbuf_take(p, buf, buflen);
    g_asix_rx++;
    if (g_asix_netif.input(p, &g_asix_netif) != ERR_OK) {
        pbuf_free(p);
    }
}

static err_t asix_linkoutput(struct netif *netif, struct pbuf *p)
{
    (void)netif;
    uint8_t *txbuf = usbh_asix_get_eth_txbuf();
    if (txbuf == NULL) {
        return ERR_IF;
    }
    pbuf_copy_partial(p, txbuf, p->tot_len, 0);
    g_asix_tx++;
    return (usbh_asix_eth_output(p->tot_len) < 0) ? ERR_IF : ERR_OK;
}

static err_t asix_netif_init(struct netif *netif)
{
    struct usbh_asix *a = (struct usbh_asix *)usbh_find_class_instance("/dev/asix");
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;
    netif->linkoutput = asix_linkoutput;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP;
    netif->hwaddr_len = 6;
    if (a) {
        memcpy(netif->hwaddr, a->mac, 6);
    }
    return ERR_OK;
}

static void asix_netif_setup_cb(void *ctx)
{
    (void)ctx;
    ip4_addr_t any;
    ip4_addr_set_zero(&any);
    netif_add(&g_asix_netif, &any, &any, &any, NULL, asix_netif_init, tcpip_input);
    netif_set_default(&g_asix_netif);
    netif_set_up(&g_asix_netif);
    netif_set_link_up(&g_asix_netif);
    g_netif_ready = true;
    dhcp_start(&g_asix_netif);
}

static void asix_netif_teardown_cb(void *ctx)
{
    (void)ctx;
    dhcp_stop(&g_asix_netif);
    netif_remove(&g_asix_netif);
}

static bool asix_link_up(void) { return g_asix && g_asix->connect_status; }
static void asix_ip_report_thread(void *arg)
{
    eth_report_thread((struct netif *)arg, "ASIX", &g_asix_rx, &g_asix_tx, asix_link_up);
}

void usbh_asix_run(struct usbh_asix *class)
{
    g_asix = class;
    g_asix_rx = 0;
    g_net_active = true;
    tcpip_callback(asix_netif_setup_cb, NULL);
    usb_osal_thread_create("asix_rx", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                           usbh_asix_rx_thread, NULL);
    usb_osal_thread_create("asix_ip", 2048, CONFIG_USBHOST_PSC_PRIO + 1,
                           asix_ip_report_thread, &g_asix_netif);
}

void usbh_asix_stop(struct usbh_asix *class)
{
    (void)class;
    g_net_active = false;
    g_netif_ready = false;
    g_asix = NULL;
    tcpip_callback(asix_netif_teardown_cb, NULL);
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

    usbh_initialize(0, CONFIG_USB_EHCI_HCCR_BASE); /* busid 0, BL616 OTG EHCI base */
    dbg_stage(STG_USBH_INIT);
    dbg_set(F_USBH_INIT);

    usb_osal_thread_create("xinput", 2048, CONFIG_USBHOST_PSC_PRIO + 1, xinput_thread, NULL);
    dbg_stage(STG_SCHED);
    dbg_set(F_THREAD_UP);

    vTaskStartScheduler();

    while (1) {
    }
}
