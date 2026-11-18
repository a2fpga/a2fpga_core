/*
 * usbhost.cpp — ESP32-S3 USB host for gamepads, HID input, mass storage and
 * (via usbeth.c) CDC-ECM/NCM Ethernet adapters (see usbhost.h).
 *
 * Ported from the a2n20v2-Enhanced BL616 firmware (CherryUSB):
 *   firmware_host/usbh_xinput.c   — XInput class match (FF/5D/01), report layout
 *   firmware_host/main.c          — the init sequence every pad needs (4 control
 *                                   transfers + 4 EP2 packets), ISR-safe report
 *                                   stashing, thread does the slow work
 *   firmware_host/usbh_hidinput.c — boot-protocol keyboard, consumer-page remotes
 *                                   (usage array or bitmap), the usage->button map
 * on top of ESP-IDF's usb_host library (the esp32-arduino-libs ship usb_host
 * and usb_phy for the S3).
 *
 * Threads: the usb_host daemon task (library events), the client task
 * (device events + transfer completions run in its context, so no mutex
 * problems — the BL616 had to split ISR/thread), and usbhost_start()'s
 * role-decision task which becomes the client task.
 */
#include <Arduino.h>
#include <string.h>

#include "board_pins.h"
#include "usbhost.h"
#include "a2fpga_regs.h"

#if A2MEGA_HAS_OSPI_LINK

#include "driver/usb_serial_jtag.h"
#include "esp_private/usb_phy.h"
#include "usb/usb_host.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "usbstorage.h"
#include "usbeth.h"

#include "osd_console.h"   /* osd_log (C linkage) */

static const char *TAG = "usbhost";

/* ---- state ------------------------------------------------------------- */
static volatile bool     s_active      = false;   /* PHY in OTG host mode */
static volatile bool     s_pad_present = false;
static volatile bool     s_hid_present = false;
static volatile uint16_t s_pad_buttons = 0;       /* A2PAD layout */
static volatile uint16_t s_kbd_buttons = 0;
static volatile uint16_t s_con_buttons = 0;
static char              s_status[40]  = "DEVICE MODE";

static usb_phy_handle_t          s_phy    = NULL;
static usb_host_client_handle_t  s_client = NULL;
/* Attach/detach work runs in a worker task: the client task must keep
 * pumping usb_host_client_handle_events() or no transfer completion (incl.
 * the control transfers of the XInput init) is ever delivered — doing the
 * work inside the client callback deadlocked and watchdog-reset the chip
 * (a2p25 10-12: Apple reset loop on gamepad attach). */
struct work_item { uint8_t is_gone; uint8_t addr; usb_device_handle_t dev; };
static QueueHandle_t s_work = NULL;

/* ---- XInput ---------------------------------------------------------------
 * Input report: [0]=type(0x00) [1]=len(0x14) [2]=btnLo [3]=btnHi [4]=LT [5]=RT
 * [6..7]=LX [8..9]=LY [10..11]=RX [12..13]=RY  (usbh_xinput_parse) */
#define XINPUT_DPAD_UP    0x0001
#define XINPUT_DPAD_DOWN  0x0002
#define XINPUT_DPAD_LEFT  0x0004
#define XINPUT_DPAD_RIGHT 0x0008
#define XINPUT_START      0x0010
#define XINPUT_BACK       0x0020
#define XINPUT_LB         0x0100
#define XINPUT_RB         0x0200
#define XINPUT_A          0x1000
#define XINPUT_B          0x2000
#define XINPUT_X          0x4000
#define XINPUT_Y          0x8000

/* raw XInput buttons -> the menu's A2PAD layout (a2fpga_regs.h) */
static uint16_t xinput_to_a2pad(uint16_t x)
{
    uint16_t b = 0;
    if (x & XINPUT_DPAD_UP)    b |= A2PAD_U;
    if (x & XINPUT_DPAD_DOWN)  b |= A2PAD_D;
    if (x & XINPUT_DPAD_LEFT)  b |= A2PAD_L;
    if (x & XINPUT_DPAD_RIGHT) b |= A2PAD_R;
    if (x & XINPUT_A)          b |= A2PAD_A;
    if (x & XINPUT_B)          b |= A2PAD_B;
    if (x & XINPUT_X)          b |= A2PAD_X;
    if (x & XINPUT_Y)          b |= A2PAD_Y;
    if (x & XINPUT_BACK)       b |= A2PAD_SELECT;
    if (x & XINPUT_START)      b |= A2PAD_START;
    return b;
}

/* The init every pad needs before it streams reports (BL616 main.c):
 * four control transfers (string reads + vendor requests; some STALL,
 * ignore) then four interrupt-OUT LED/rumble packets on the OUT endpoint. */
struct ctrl_req { uint8_t bmRequestType, bRequest; uint16_t wValue, wIndex, wLength; };
static const ctrl_req k_xbox_init_ctrl[4] = {
    {0x80, 0x06, 0x0302, 0x0409, 2},   /* GET_STRING_DESCRIPTOR (SN30 Pro needs this) */
    {0x80, 0x06, 0x0302, 0x0409, 32},  /* GET_STRING_DESCRIPTOR */
    {0xC1, 0x01, 0x0100, 0x0000, 20},  /* vendor control 1 (many pads need this) */
    {0xC1, 0x01, 0x0000, 0x0000, 8},   /* vendor control 2 */
};
static const uint8_t k_xbox_ep2[4][3] = {
    {0x01, 0x03, 0x02}, {0x02, 0x08, 0x03}, {0x01, 0x03, 0x02}, {0x01, 0x03, 0x06},
};

/* ---- HID keyboard / consumer (usbh_hidinput.c) ---------------------------- */
/* Keyboard usages -> menu buttons. The ESP32 menu's OK is A and back is B
 * (BTN_OK / BTN_BACK in menu.c); SELECT = Apple II <-> MCU; Y = menu <->
 * console. Arrows/OK/Menu arrive as keyboard usages on the known remotes. */
static uint16_t map_kbd_usage(uint8_t u)
{
    switch (u) {
    case 0x52: return A2PAD_U;        /* Up arrow */
    case 0x51: return A2PAD_D;        /* Down arrow */
    case 0x50: return A2PAD_L;        /* Left arrow */
    case 0x4F: return A2PAD_R;        /* Right arrow */
    case 0x28:                        /* Enter (remote OK button) */
    case 0x58: return A2PAD_A;        /* Keypad Enter        -> OK */
    case 0x29:                        /* Esc */
    case 0x2A: return A2PAD_B;        /* Backspace           -> back */
    case 0x65:                        /* Application ("menu" key) */
    case 0x2B: return A2PAD_SELECT;   /* Tab      -> Apple II <-> MCU */
    case 0x1C: return A2PAD_Y;        /* Y        -> menu <-> console */
    default:   return 0;
    }
}
static uint16_t map_consumer_usage(uint16_t u)
{
    switch (u) {
    case 0x223:                       /* AC Home (remote Home button) */
    case 0x040: return A2PAD_SELECT;  /* Menu     -> Apple II <-> MCU */
    case 0x224: return A2PAD_B;       /* AC Back             -> back */
    case 0x041: return A2PAD_A;       /* Menu Pick           -> OK */
    case 0x042: return A2PAD_U;       /* Menu Up */
    case 0x043: return A2PAD_D;       /* Menu Down */
    case 0x044: return A2PAD_L;       /* Menu Left */
    case 0x045: return A2PAD_R;       /* Menu Right */
    default:    return 0;             /* volume keys: no menu meaning here */
    }
}

/* consumer-page input report layout, from the report descriptor */
struct consumer_layout {
    bool     valid;
    bool     is_array;     /* array of usage codes vs 1-bit-per-usage bitmap */
    uint8_t  rid;          /* report ID (0 = none) */
    uint8_t  field_bits;   /* array: bits per entry (8/16); bitmap: 1 */
    uint8_t  field_count;  /* array: entries; bitmap: bits */
    uint16_t usages[16];   /* bitmap only: usage per bit position */
    uint8_t  nusages;
};

/* Minimal HID report-descriptor parse: for each Input item on the Consumer
 * page record the report ID, entry size/count and (for bitmaps) the per-bit
 * usage list. Prefers a usage-code ARRAY over a bitmap (usbh_hidinput.c). */
static void parse_consumer_layout(const uint8_t *d, uint32_t len, consumer_layout *out)
{
    uint16_t usage_page = 0, rcount = 0, rsize = 0, usage_min = 0;
    uint8_t  rid = 0;
    uint16_t usages[16]; uint8_t nus = 0; bool have_min = false;
    memset(out, 0, sizeof(*out));
    uint32_t i = 0;
    while (i < len) {
        uint8_t  b   = d[i++];
        uint8_t  sz  = b & 3; if (sz == 3) sz = 4;
        uint8_t  typ = (b >> 2) & 3, tag = b >> 4;
        uint32_t val = 0;
        for (uint8_t k = 0; k < sz && i < len; k++) val |= (uint32_t)d[i++] << (8 * k);
        if (typ == 1) {              /* global */
            switch (tag) {
            case 0: usage_page = (uint16_t)val; break;
            case 7: rsize = (uint16_t)val; break;
            case 9: rcount = (uint16_t)val; break;
            case 8: rid = (uint8_t)val; break;
            }
        } else if (typ == 2) {       /* local */
            switch (tag) {
            case 0: if (nus < 16) usages[nus++] = (uint16_t)val; break;
            case 1: usage_min = (uint16_t)val; have_min = true; break;
            case 2:                  /* usage max: bitmap declared as a range */
                if (have_min) { for (uint16_t u = 0; u < 16 && usage_min + u <= val; u++) if (nus < 16) usages[nus++] = usage_min + u; }
                break;
            }
        } else if (typ == 0) {       /* main */
            if (tag == 8 && usage_page == 0x0C && !out->valid) {   /* Input, Consumer page */
                bool is_array = (val & 0x02) == 0;                   /* bit1: 0 = array, 1 = variable */
                if (is_array && (rsize == 8 || rsize == 16)) {
                    out->valid = true; out->is_array = true; out->rid = rid;
                    out->field_bits = (uint8_t)rsize; out->field_count = (uint8_t)rcount;
                } else if (!is_array && rsize == 1 && nus > 0) {
                    out->valid = true; out->is_array = false; out->rid = rid;
                    out->field_bits = 1; out->field_count = (uint8_t)rcount;
                    out->nusages = nus; memcpy(out->usages, usages, sizeof(usages));
                }
            }
            if (tag == 8 || tag == 9 || tag == 11) { nus = 0; have_min = false; }   /* Input/Output/Feature clear locals */
        }
    }
}

/* ---- per-device bookkeeping ------------------------------------------------ */
enum devkind { DK_NONE, DK_XINPUT, DK_KBD, DK_CONSUMER, DK_MSC, DK_ETH };
/* one serviced interface of a device (composite remotes carry a keyboard
 * interface AND a consumer-page interface; both must be read) */
struct hintf {
    devkind  kind;
    uint8_t  intf;
    uint8_t  ep_in, ep_out;
    uint16_t mps_in, mps_out;
    usb_transfer_t *xin;
    consumer_layout con;
    bool     claimed;
    uint16_t buttons;                /* last decoded buttons of this interface */
    struct hdev *dev;
};
#define MAX_INTF 4
struct hdev {
    usb_device_handle_t dev;
    uint8_t  addr;
    hintf    in[MAX_INTF];
    uint8_t  nin;
    /* MSC (bulk-only transport) */
    hintf   *msc;
    uint8_t  bulk_in, bulk_out;
    uint16_t mps_bulk;
    uint32_t msc_blocks, msc_bsize;
    uint32_t msc_tag;
    /* CDC-ECM/NCM Ethernet adapter owned by usbeth.c */
    bool     eth;
};
#define MAX_DEV 4
static hdev s_devs[MAX_DEV];

static hdev *dev_find(usb_device_handle_t h) { for (auto &d : s_devs) if (d.dev == h) return &d; return NULL; }
static hdev *dev_alloc(void) { for (auto &d : s_devs) if (!d.dev) { memset(&d, 0, sizeof(d)); return &d; } return NULL; }

static hdev *s_msc = NULL;                     /* the mounted mass-storage device */
static SemaphoreHandle_t s_msc_lock = NULL;

static void recompute_presence(void)
{
    bool pad = false, hid = false, msc = false, eth = false;
    for (auto &d : s_devs) {
        if (!d.dev) continue;
        if (d.msc) msc = true;
        if (d.eth) eth = true;
        for (uint8_t i = 0; i < d.nin; i++) {
            if (d.in[i].kind == DK_XINPUT) pad = true;
            if (d.in[i].kind == DK_KBD || d.in[i].kind == DK_CONSUMER) hid = true;
        }
    }
    s_pad_present = pad; s_hid_present = hid;
    if (!pad) s_pad_buttons = 0;
    if (!hid) { s_kbd_buttons = 0; s_con_buttons = 0; }
    snprintf(s_status, sizeof(s_status), "HOST%s%s%s%s", pad ? " PAD" : "", hid ? " HID" : "", msc ? " STICK" : "", eth ? " ETH" : "");
}

/* buttons = OR over every serviced interface of every device */
static void recompute_buttons(void)
{
    uint16_t pad = 0, kbd = 0, con = 0;
    for (auto &d : s_devs) {
        if (!d.dev) continue;
        for (uint8_t i = 0; i < d.nin; i++) {
            if (d.in[i].kind == DK_XINPUT)   pad |= d.in[i].buttons;
            if (d.in[i].kind == DK_KBD)      kbd |= d.in[i].buttons;
            if (d.in[i].kind == DK_CONSUMER) con |= d.in[i].buttons;
        }
    }
    s_pad_buttons = pad; s_kbd_buttons = kbd; s_con_buttons = con;
}

static esp_err_t ctrl_xfer(hdev *d, uint8_t bmRT, uint8_t bReq, uint16_t wVal, uint16_t wIdx, uint16_t wLen, uint8_t *data_out);

/* ---- MSC bulk-only transport (SCSI transparent) ------------------------------
 * Blocking helpers usable from any task except the client task: completions
 * are delivered by the client task's event pump and wake the caller. */
static void blk_done_cb(usb_transfer_t *t) { xTaskNotifyGive((TaskHandle_t)t->context); }
static bool bulk_xfer(hdev *d, uint8_t ep, uint8_t *buf, size_t len, size_t *done, uint32_t timeout_ms)
{
    usb_transfer_t *t = NULL;
    /* IN transfers must be a whole multiple of the endpoint's max packet
     * size (usb_host rejects the submit otherwise); round up and copy the
     * actual length back. OUT transfers go as-is. */
    size_t req = len;
    if ((ep & 0x80) && d->mps_bulk) req = ((len + d->mps_bulk - 1) / d->mps_bulk) * d->mps_bulk;
    size_t alloc = req ? req : 1;
    if (usb_host_transfer_alloc(alloc, 0, &t) != ESP_OK) return false;
    if (!(ep & 0x80) && len) memcpy(t->data_buffer, buf, len);
    t->num_bytes = req; t->device_handle = d->dev; t->bEndpointAddress = ep;
    t->callback = blk_done_cb; t->context = (void *)xTaskGetCurrentTaskHandle(); t->timeout_ms = timeout_ms;
    ulTaskNotifyTake(pdTRUE, 0);                         /* clear stale notifications */
    if (usb_host_transfer_submit(t) != ESP_OK) { usb_host_transfer_free(t); return false; }
    if (!ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(timeout_ms + 500))) { usb_host_transfer_free(t); return false; }
    bool ok = (t->status == USB_TRANSFER_STATUS_COMPLETED);
    if (ok && (ep & 0x80) && len) memcpy(buf, t->data_buffer, t->actual_num_bytes > len ? len : t->actual_num_bytes);
    if (done) *done = t->actual_num_bytes;
    if (t->status == USB_TRANSFER_STATUS_STALL) {      /* clear halt, as the BOT spec asks */
        ctrl_xfer(d, 0x02, 0x01, 0x0000, ep, 0, NULL);
    }
    usb_host_transfer_free(t);
    return ok;
}

/* one SCSI command: CBW, optional data phase, CSW. Returns true on a good CSW. */
static bool scsi_cmd(hdev *d, const uint8_t *cb, uint8_t cblen, uint8_t *data, uint32_t dlen, bool data_in)
{
    uint8_t cbw[31]; memset(cbw, 0, sizeof(cbw));
    uint32_t tag = ++d->msc_tag;
    cbw[0]='U'; cbw[1]='S'; cbw[2]='B'; cbw[3]='C';
    memcpy(&cbw[4], &tag, 4); memcpy(&cbw[8], &dlen, 4);
    cbw[12] = data_in ? 0x80 : 0x00; cbw[13] = 0; cbw[14] = cblen; memcpy(&cbw[15], cb, cblen);
    if (!bulk_xfer(d, d->bulk_out, cbw, 31, NULL, 1000)) return false;
    if (dlen) {
        /* data phase in chunks the host library accepts */
        uint32_t off = 0;
        while (off < dlen) {
            uint32_t n = dlen - off; if (n > 4096) n = 4096;
            size_t got = 0;
            if (!bulk_xfer(d, data_in ? d->bulk_in : d->bulk_out, data + off, n, &got, 3000)) return false;
            off += data_in ? (got ? got : n) : n;
            if (data_in && got < n) break;               /* short read: device sent less */
        }
    }
    uint8_t csw[13]; size_t got = 0;
    if (!bulk_xfer(d, d->bulk_in, csw, 13, &got, 1000)) {
        if (!bulk_xfer(d, d->bulk_in, csw, 13, &got, 1000)) return false;   /* one retry after a STALL clear */
    }
    return got == 13 && csw[0]=='U' && csw[1]=='S' && csw[2]=='B' && csw[3]=='S' && csw[12] == 0;
}

static bool msc_init(hdev *d)
{
    uint8_t inq[36]; uint8_t cb[16];
    memset(cb, 0, 16); cb[0] = 0x12; cb[4] = 36;                      /* INQUIRY */
    scsi_cmd(d, cb, 6, inq, 36, true);
    bool ready = false;
    for (int i = 0; i < 20 && !ready; i++) {                           /* TEST UNIT READY, spin-up */
        memset(cb, 0, 16);
        ready = scsi_cmd(d, cb, 6, NULL, 0, true);
        if (!ready) { memset(cb, 0, 16); cb[0] = 0x03; cb[4] = 18; uint8_t sense[18]; scsi_cmd(d, cb, 6, sense, 18, true); vTaskDelay(pdMS_TO_TICKS(100)); }
    }
    if (!ready) { osd_log("USB HOST: STORAGE NOT READY (TUR)"); return false; }
    uint8_t cap[8]; memset(cb, 0, 16); cb[0] = 0x25;                  /* READ CAPACITY(10) */
    if (!scsi_cmd(d, cb, 10, cap, 8, true)) { osd_log("USB HOST: STORAGE READ CAPACITY FAILED"); return false; }
    uint32_t last = ((uint32_t)cap[0] << 24) | ((uint32_t)cap[1] << 16) | ((uint32_t)cap[2] << 8) | cap[3];
    uint32_t bs   = ((uint32_t)cap[4] << 24) | ((uint32_t)cap[5] << 16) | ((uint32_t)cap[6] << 8) | cap[7];
    if (bs != 512) { ESP_LOGW(TAG, "MSC block size %u unsupported", (unsigned)bs); return false; }
    d->msc_blocks = last + 1; d->msc_bsize = bs;
    ESP_LOGI(TAG, "MSC: %.8s %.16s, %u blocks", (const char *)&inq[8], (const char *)&inq[16], (unsigned)d->msc_blocks);
    return true;
}

bool usbhost_msc_present(void) { return s_msc != NULL; }
bool usbhost_msc_capacity(uint32_t *blocks, uint32_t *bsize)
{
    if (!s_msc) return false;
    if (blocks) *blocks = s_msc->msc_blocks;
    if (bsize)  *bsize  = s_msc->msc_bsize;
    return true;
}
static bool msc_rw(uint32_t lba, uint32_t count, uint8_t *buf, bool write)
{
    hdev *d = s_msc;
    if (!d || !s_msc_lock) return false;
    xSemaphoreTake(s_msc_lock, portMAX_DELAY);
    bool ok = true;
    while (count && ok && s_msc == d) {
        uint32_t n = count > 8 ? 8 : count;                            /* 4 KB per command */
        uint8_t cb[16]; memset(cb, 0, 16);
        cb[0] = write ? 0x2A : 0x28;                                   /* WRITE(10) / READ(10) */
        cb[2] = lba >> 24; cb[3] = lba >> 16; cb[4] = lba >> 8; cb[5] = lba;
        cb[7] = n >> 8; cb[8] = n;
        ok = scsi_cmd(d, cb, 10, buf, n * 512, !write);
        buf += n * 512; lba += n; count -= n;
    }
    xSemaphoreGive(s_msc_lock);
    return ok;
}
bool usbhost_msc_read(uint32_t lba, uint32_t count, uint8_t *buf)        { return msc_rw(lba, count, buf, false); }
bool usbhost_msc_write(uint32_t lba, uint32_t count, const uint8_t *buf) { return msc_rw(lba, count, (uint8_t *)buf, true); }

/* ---- transfers ------------------------------------------------------------ */
static void in_xfer_cb(usb_transfer_t *t)
{
    hintf *f = (hintf *)t->context;
    if (!f || !f->dev || !f->dev->dev) return;
    if (t->status == USB_TRANSFER_STATUS_COMPLETED && t->actual_num_bytes > 0) {
        const uint8_t *buf = t->data_buffer; int n = t->actual_num_bytes;
        switch (f->kind) {
        case DK_XINPUT:
            if (n >= 14 && buf[0] == 0x00 && buf[1] == 0x14)
                f->buttons = xinput_to_a2pad((uint16_t)buf[2] | ((uint16_t)buf[3] << 8));
            break;
        case DK_KBD: {               /* boot report: [mods, reserved, key1..key6] */
            uint16_t bits = 0;
            for (int k = 2; k < 8 && k < n; k++) if (buf[k] > 0x01) bits |= map_kbd_usage(buf[k]);
            f->buttons = bits;
            break;
        }
        case DK_CONSUMER: {
            const consumer_layout *c = &f->con; uint16_t bits = 0; int off = 0;
            if (c->rid) { if (n < 1 || buf[0] != c->rid) break; off = 1; }
            if (c->is_array) {
                int bytes = c->field_bits / 8;
                for (int f = 0; f < c->field_count && off + bytes <= n; f++, off += bytes) {
                    uint16_t u = buf[off] | (bytes == 2 ? (uint16_t)buf[off + 1] << 8 : 0);
                    if (u) bits |= map_consumer_usage(u);
                }
            } else {
                for (int f = 0; f < c->field_count && f < c->nusages; f++) {
                    int byte = off + f / 8, bit = f % 8;
                    if (byte < n && (buf[byte] >> bit) & 1) bits |= map_consumer_usage(c->usages[f]);
                }
            }
            f->buttons = bits;
            break;
        }
        default: break;
        }
        recompute_buttons();
    } else if (t->status != USB_TRANSFER_STATUS_COMPLETED &&
               t->status != USB_TRANSFER_STATUS_TIMED_OUT) {
        return;                      /* device gone / stalled: stop re-arming */
    }
    t->num_bytes = f->mps_in;
    usb_host_transfer_submit(t);     /* re-arm (the report pattern) */
}

/* synchronous control transfer on EP0 (results ignored by callers that
 * expect STALLs, like the XInput init) */
static void ctrl_done_cb(usb_transfer_t *t) { xTaskNotifyGive((TaskHandle_t)t->context); }
static esp_err_t ctrl_xfer(hdev *d, uint8_t bmRT, uint8_t bReq, uint16_t wVal, uint16_t wIdx, uint16_t wLen, uint8_t *data_out)
{
    usb_transfer_t *t = NULL;
    if (usb_host_transfer_alloc(sizeof(usb_setup_packet_t) + wLen, 0, &t) != ESP_OK) return ESP_ERR_NO_MEM;
    usb_setup_packet_t *sp = (usb_setup_packet_t *)t->data_buffer;
    sp->bmRequestType = bmRT; sp->bRequest = bReq; sp->wValue = wVal; sp->wIndex = wIdx; sp->wLength = wLen;
    if (data_out && !(bmRT & 0x80)) memcpy(t->data_buffer + sizeof(*sp), data_out, wLen);
    t->num_bytes = sizeof(*sp) + wLen; t->device_handle = d->dev; t->bEndpointAddress = 0;
    t->callback = ctrl_done_cb; t->context = (void *)xTaskGetCurrentTaskHandle(); t->timeout_ms = 500;
    esp_err_t r = usb_host_transfer_submit_control(s_client, t);
    if (r == ESP_OK) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000));
        r = (t->status == USB_TRANSFER_STATUS_COMPLETED) ? ESP_OK : ESP_FAIL;
        if (data_out && (bmRT & 0x80) && t->status == USB_TRANSFER_STATUS_COMPLETED)
            memcpy(data_out, t->data_buffer + sizeof(*sp), t->actual_num_bytes > wLen ? wLen : t->actual_num_bytes);
    }
    usb_host_transfer_free(t);
    return r;
}

static void out_done_cb(usb_transfer_t *t) { usb_host_transfer_free(t); }
static void int_out(hintf *f, const uint8_t *data, int n)
{
    usb_transfer_t *t = NULL;
    if (!f->ep_out || usb_host_transfer_alloc(n, 0, &t) != ESP_OK) return;
    memcpy(t->data_buffer, data, n);
    t->num_bytes = n; t->device_handle = f->dev->dev; t->bEndpointAddress = f->ep_out;
    t->callback = out_done_cb; t->context = f; t->timeout_ms = 500;
    if (usb_host_transfer_submit(t) != ESP_OK) usb_host_transfer_free(t);
}

static void arm_in(hintf *f)
{
    if (!f->ep_in) return;
    if (usb_host_transfer_alloc(f->mps_in, 0, &f->xin) != ESP_OK) return;
    f->xin->device_handle = f->dev->dev; f->xin->bEndpointAddress = f->ep_in;
    f->xin->num_bytes = f->mps_in; f->xin->callback = in_xfer_cb; f->xin->context = f; f->xin->timeout_ms = 0;
    usb_host_transfer_submit(f->xin);
}

/* ---- device attach --------------------------------------------------------- */
static void attach_device(uint8_t addr)
{
    hdev *d = dev_alloc();
    if (!d) return;
    if (usb_host_device_open(s_client, addr, &d->dev) != ESP_OK) { d->dev = NULL; return; }
    d->addr = addr;
    const usb_device_desc_t *dd = NULL;
    const usb_config_desc_t *cfg = NULL;
    char ifs[96] = ""; int ifl = 0;   /* composite devices list several interfaces */
    usb_host_get_device_descriptor(d->dev, &dd);
    if (usb_host_get_active_config_descriptor(d->dev, &cfg) != ESP_OK) goto drop;
    for (uint8_t i = 0; i < cfg->bNumInterfaces; i++) {
        int off = 0;
        const usb_intf_desc_t *id = usb_parse_interface_descriptor(cfg, i, 0, &off);
        if (!id) continue;
        if (ifl < (int)sizeof(ifs) - 8)
            ifl += snprintf(ifs + ifl, sizeof(ifs) - ifl, "%s%02X/%02X/%02X", i ? " " : "", id->bInterfaceClass, id->bInterfaceSubClass, id->bInterfaceProtocol);
        devkind k = DK_NONE;
        if (id->bInterfaceClass == 0xFF && id->bInterfaceSubClass == 0x5D && id->bInterfaceProtocol == 0x01) k = DK_XINPUT;
        else if (id->bInterfaceClass == 0x03 && id->bInterfaceSubClass == 0x01 && id->bInterfaceProtocol == 0x01) k = DK_KBD;
        else if (id->bInterfaceClass == 0x03) k = DK_CONSUMER;
        else if (id->bInterfaceClass == 0x08 && id->bInterfaceSubClass == 0x06 && id->bInterfaceProtocol == 0x50 && !s_msc && !d->msc) k = DK_MSC;
        /* CDC Ethernet (ECM 02/06 or NCM 02/0D) control interface: the
         * adapter's data interface (class 0x0A) is claimed by usbeth.c */
        else if (id->bInterfaceClass == 0x02 && (id->bInterfaceSubClass == 0x06 || id->bInterfaceSubClass == 0x0D) && !d->eth) k = DK_ETH;
        if (k == DK_NONE || d->nin >= MAX_INTF) continue;
        hintf *f = &d->in[d->nin]; memset(f, 0, sizeof(*f)); f->dev = d; f->intf = i;
        if (k == DK_ETH) {
            if (usbeth_attach(s_client, d->dev, (const uint8_t *)cfg, cfg->wTotalLength, i,
                              dd ? dd->idVendor : 0, dd ? dd->idProduct : 0)) {
                f->kind = k; d->eth = true; d->nin++;      /* interfaces released by usbeth_detach */
            }
            continue;
        }
        if (k == DK_MSC) {
            for (uint8_t e = 0; e < id->bNumEndpoints; e++) {
                int eoff = off;
                const usb_ep_desc_t *ep = usb_parse_endpoint_descriptor_by_index(id, e, cfg->wTotalLength, &eoff);
                if (!ep || (ep->bmAttributes & 0x03) != USB_BM_ATTRIBUTES_XFER_BULK) continue;
                if (ep->bEndpointAddress & 0x80) d->bulk_in = ep->bEndpointAddress; else d->bulk_out = ep->bEndpointAddress;
                d->mps_bulk = ep->wMaxPacketSize;
            }
            if (!d->bulk_in || !d->bulk_out) continue;
            if (usb_host_interface_claim(s_client, d->dev, i, 0) != ESP_OK) continue;
            f->claimed = true; f->kind = k; d->msc = f; d->nin++;
            continue;
        }
        for (uint8_t e = 0; e < id->bNumEndpoints; e++) {
            int eoff = off;
            const usb_ep_desc_t *ep = usb_parse_endpoint_descriptor_by_index(id, e, cfg->wTotalLength, &eoff);
            if (!ep || (ep->bmAttributes & 0x03) != USB_BM_ATTRIBUTES_XFER_INT) continue;
            if (ep->bEndpointAddress & 0x80) { f->ep_in = ep->bEndpointAddress; f->mps_in = ep->wMaxPacketSize; }
            else                             { f->ep_out = ep->bEndpointAddress; f->mps_out = ep->wMaxPacketSize; }
        }
        if (!f->ep_in) continue;
        if (usb_host_interface_claim(s_client, d->dev, i, 0) != ESP_OK) continue;
        f->claimed = true;
        if (k == DK_CONSUMER) {
            /* report descriptor: the HID descriptor (0x21) carries its length */
            uint16_t rlen = 0; int hoff = off;
            const usb_standard_desc_t *hd = usb_parse_next_descriptor_of_type((const usb_standard_desc_t *)id, cfg->wTotalLength, 0x21, &hoff);
            if (hd && hd->bLength >= 9) { const uint8_t *hb = (const uint8_t *)hd; rlen = hb[7] | ((uint16_t)hb[8] << 8); }
            static uint8_t rdesc[512];
            if (rlen && rlen <= 512 && ctrl_xfer(d, 0x81, 0x06, 0x2200, i, rlen, rdesc) == ESP_OK)
                parse_consumer_layout(rdesc, rlen, &f->con);
            if (!f->con.valid) {
                /* not a consumer-page report: a non-boot keyboard or something
                 * else on this interface — leave it claimed but unread */
                usb_host_interface_release(s_client, d->dev, i); f->claimed = false;
                continue;
            }
        }
        f->kind = k; d->nin++;
    }
    osd_log("USB HOST: %04X:%04X [%s]", dd ? dd->idVendor : 0, dd ? dd->idProduct : 0, ifs);
    if (d->nin == 0) goto drop;
    for (uint8_t n = 0; n < d->nin; n++) {
        hintf *f = &d->in[n];
        if (f->kind == DK_ETH) continue;                  /* running already (usbeth_attach) */
        if (f->kind == DK_MSC) {
            if (!msc_init(d)) {
                osd_log("USB HOST: STORAGE DEVICE NOT READY");
                usb_host_interface_release(s_client, d->dev, f->intf); f->claimed = false; f->kind = DK_NONE; d->msc = NULL;
                continue;
            }
            s_msc = d;
            osd_log("USB HOST: STORAGE %u MB", (unsigned)((uint64_t)d->msc_blocks * d->msc_bsize / (1024 * 1024)));
            usbstorage_on_msc(true);
            continue;
        }
        if (f->kind == DK_KBD) {
            ctrl_xfer(d, 0x21, 0x0B, 0, f->intf, 0, NULL);          /* SET_PROTOCOL boot */
            ctrl_xfer(d, 0x21, 0x0A, 0, f->intf, 0, NULL);          /* SET_IDLE 0 */
        } else if (f->kind == DK_XINPUT) {
            uint8_t tmp[32];
            for (int i = 0; i < 4; i++)
                ctrl_xfer(d, k_xbox_init_ctrl[i].bmRequestType, k_xbox_init_ctrl[i].bRequest,
                          k_xbox_init_ctrl[i].wValue, k_xbox_init_ctrl[i].wIndex, k_xbox_init_ctrl[i].wLength, tmp);
            for (int i = 0; i < 4; i++) int_out(f, k_xbox_ep2[i], 3);
        }
        arm_in(f);
        osd_log("USB HOST: %s CONNECTED", f->kind == DK_XINPUT ? "XINPUT CONTROLLER" : f->kind == DK_KBD ? "KEYBOARD" : "HID REMOTE");
    }
    recompute_presence();
    ESP_LOGI(TAG, "attached addr %u, %u interfaces", addr, d->nin);
    return;
drop:
    ESP_LOGI(TAG, "addr %u: no supported interface", addr);
    usb_host_device_close(s_client, d->dev);
    d->dev = NULL;
}

static void detach_device(usb_device_handle_t h)
{
    hdev *d = dev_find(h);
    if (!d) return;
    if (d == s_msc) {
        s_msc = NULL;                                     /* readers see "gone" first */
        usbstorage_on_msc(false);
        if (s_msc_lock) { xSemaphoreTake(s_msc_lock, portMAX_DELAY); xSemaphoreGive(s_msc_lock); }
    }
    if (d->eth) { usbeth_detach(d->dev); d->eth = false; }
    for (uint8_t n = 0; n < d->nin; n++) {
        hintf *f = &d->in[n];
        if (f->xin) { usb_host_transfer_free(f->xin); f->xin = NULL; }
        if (f->claimed) usb_host_interface_release(s_client, d->dev, f->intf);
    }
    usb_host_device_close(s_client, d->dev);
    osd_log("USB HOST: DEVICE REMOVED");
    memset(d, 0, sizeof(*d));
    recompute_presence();
    recompute_buttons();
}

static void client_cb(const usb_host_client_event_msg_t *m, void *arg)
{
    (void)arg;
    work_item w = {};
    if (m->event == USB_HOST_CLIENT_EVENT_NEW_DEV) { w.is_gone = 0; w.addr = m->new_dev.address; }
    else if (m->event == USB_HOST_CLIENT_EVENT_DEV_GONE) { w.is_gone = 1; w.dev = m->dev_gone.dev_hdl; }
    else return;
    if (s_work) xQueueSend(s_work, &w, 0);
}

static void worker_task(void *arg)
{
    (void)arg;
    work_item w;
    for (;;) {
        if (xQueueReceive(s_work, &w, portMAX_DELAY) != pdTRUE) continue;
        if (w.is_gone) detach_device(w.dev);
        else           attach_device(w.addr);
    }
}

/* ---- tasks ------------------------------------------------------------------ */
static void daemon_task(void *arg)
{
    (void)arg;
    for (;;) {
        uint32_t flags = 0;
        usb_host_lib_handle_events(portMAX_DELAY, &flags);
        if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) usb_host_device_free_all();
    }
}

static bool engage_host_mode(void)
{
    /* route the internal PHY from USB-Serial-JTAG to the OTG controller */
    usb_phy_config_t pc = {};
    pc.controller = USB_PHY_CTRL_OTG;
    pc.target     = USB_PHY_TARGET_INT;
    pc.otg_mode   = USB_OTG_MODE_HOST;
    pc.otg_speed  = USB_PHY_SPEED_FULL;
    if (usb_new_phy(&pc, &s_phy) != ESP_OK) { ESP_LOGE(TAG, "usb_new_phy failed"); return false; }
    usb_host_config_t hc = {};
    hc.skip_phy_setup = true;
    hc.intr_flags     = ESP_INTR_FLAG_LEVEL1;
    if (usb_host_install(&hc) != ESP_OK) { ESP_LOGE(TAG, "usb_host_install failed"); return false; }
    xTaskCreatePinnedToCore(daemon_task, "usbh_lib", 4096, NULL, 6, NULL, 0);
    usb_host_client_config_t cc = {};
    cc.is_synchronous    = false;
    cc.max_num_event_msg = 8;
    cc.async.client_event_callback = client_cb;
    cc.async.callback_arg          = NULL;
    if (usb_host_client_register(&cc, &s_client) != ESP_OK) { ESP_LOGE(TAG, "client register failed"); return false; }
    s_work = xQueueCreate(8, sizeof(work_item));
    s_msc_lock = xSemaphoreCreateMutex();
    xTaskCreatePinnedToCore(worker_task, "usbh_work", 6144, NULL, 5, NULL, 0);
    s_active = true;
    snprintf(s_status, sizeof(s_status), "HOST");
    return true;
}

static void role_task(void *arg)
{
    (void)arg;
    /* Device-first: a Mac on USB1 enumerates us within a few seconds.
     * If nobody does, the port is ours to host. BOOT (S2) held at boot
     * forces device mode deterministically (programming/console), as does
     * any PC enumeration inside the window. */
#if defined(PIN_BOOT_BTN) && PIN_BOOT_BTN >= 0
    pinMode(PIN_BOOT_BTN, INPUT_PULLUP);   /* S2 to GND; strapping pin, read only */
#endif
    const uint32_t t0 = millis();
    while (millis() - t0 < 5000) {
#if defined(PIN_BOOT_BTN) && PIN_BOOT_BTN >= 0
        if (digitalRead(PIN_BOOT_BTN) == LOW) {
            snprintf(s_status, sizeof(s_status), "DEVICE MODE (BOOT HELD)");
            osd_log("USB PORT: DEVICE MODE (BOOT HELD)");
            vTaskDelete(NULL);
            return;
        }
#endif
        if (usb_serial_jtag_is_connected()) {
            snprintf(s_status, sizeof(s_status), "DEVICE MODE (PC ATTACHED)");
            ESP_LOGI(TAG, "USB host attached on USB1: staying in device mode");
            osd_log("USB PORT: DEVICE MODE (PC ATTACHED)");
            vTaskDelete(NULL);
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    Serial.println("[usbhost] no PC on USB1: switching the port to USB HOST mode (CDC console off; telnet stays)");
    Serial.flush();
    vTaskDelay(pdMS_TO_TICKS(20));
    if (!engage_host_mode()) { snprintf(s_status, sizeof(s_status), "HOST INIT FAILED"); vTaskDelete(NULL); return; }
    osd_log("USB HOST MODE ON USB1");
    for (;;) usb_host_client_handle_events(s_client, portMAX_DELAY);
}

void usbhost_start(void)
{
    static bool started = false;
    if (started) return;
    started = true;
    xTaskCreatePinnedToCore(role_task, "usbh_cli", 6144, NULL, 5, NULL, 0);
}

bool     usbhost_active(void)      { return s_active; }
bool     usbhost_pad_present(void) { return s_pad_present; }
bool     usbhost_hid_present(void) { return s_hid_present; }
uint16_t usbhost_buttons(void)     { return (uint16_t)(s_pad_buttons | s_kbd_buttons | s_con_buttons); }
const char *usbhost_status_str(void) { return s_status; }

#else  /* !A2MEGA_HAS_OSPI_LINK: dp_test builds keep the port in device mode */

void     usbhost_start(void)       {}
bool     usbhost_active(void)      { return false; }
bool     usbhost_pad_present(void) { return false; }
bool     usbhost_hid_present(void) { return false; }
uint16_t usbhost_buttons(void)     { return 0; }
const char *usbhost_status_str(void) { return "DEVICE MODE"; }
bool     usbhost_msc_present(void) { return false; }
bool     usbhost_msc_capacity(uint32_t *b, uint32_t *s) { (void)b; (void)s; return false; }
bool     usbhost_msc_read(uint32_t l, uint32_t c, uint8_t *b) { (void)l; (void)c; (void)b; return false; }
bool     usbhost_msc_write(uint32_t l, uint32_t c, const uint8_t *b) { (void)l; (void)c; (void)b; return false; }

#endif
