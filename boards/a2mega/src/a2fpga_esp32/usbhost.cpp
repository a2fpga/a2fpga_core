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
#include "hid_map.h"

#if A2MEGA_HAS_OSPI_LINK

#include "driver/usb_serial_jtag.h"
#include "esp_private/usb_phy.h"
#include "usb/usb_host.h"
#include "usb/usb_types_ch11.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "usbstorage.h"
#include "usbeth.h"
#include "usbhub_retry.h"
#include "idf_log_tee.h"
#include "settings.h"

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
/* kind: 0 = new device at addr, 1 = device gone, 2 = hub port failed to
 * enumerate (addr = hub, port = 1-based downstream port; from the log hook) */
struct work_item { uint8_t kind; uint8_t addr; uint8_t port; usb_device_handle_t dev; };
enum { WORK_NEW = 0, WORK_GONE = 1, WORK_HUB_PORT_FAILED = 2 };
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
/* Usage -> button tables and the consumer-page layout parser live in
 * hid_map.c (shared with the BLE HID host since 2026-11-19). */
typedef hid_consumer_layout_t consumer_layout;

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

/* Where the last SCSI command failed (msc_rw turns it into a console line;
 * `usb probe` reads it too). Set by scsi_cmd, read right after it fails. */
enum scsi_stage { SC_OK = 0, SC_CBW, SC_DATA, SC_CSW_XFER, SC_CSW_BAD, SC_CSW_STATUS };
static struct { uint8_t stage; uint8_t csw_status; uint32_t data_done; } s_scsi_err;
static const char *scsi_stage_str(uint8_t st)
{
    switch (st) {
    case SC_CBW:        return "CBW (COMMAND NOT ACCEPTED)";
    case SC_DATA:       return "DATA PHASE (TIMEOUT/STALL)";
    case SC_CSW_XFER:   return "CSW NEVER CAME";
    case SC_CSW_BAD:    return "CSW MALFORMED";
    case SC_CSW_STATUS: return "CSW STATUS (CHECK CONDITION)";
    default:            return "OK";
    }
}

/* one SCSI command: CBW, optional data phase, CSW. Returns true on a good CSW. */
static bool scsi_cmd(hdev *d, const uint8_t *cb, uint8_t cblen, uint8_t *data, uint32_t dlen, bool data_in)
{
    uint8_t cbw[31]; memset(cbw, 0, sizeof(cbw));
    uint32_t tag = ++d->msc_tag;
    cbw[0]='U'; cbw[1]='S'; cbw[2]='B'; cbw[3]='C';
    memcpy(&cbw[4], &tag, 4); memcpy(&cbw[8], &dlen, 4);
    cbw[12] = data_in ? 0x80 : 0x00; cbw[13] = 0; cbw[14] = cblen; memcpy(&cbw[15], cb, cblen);
    s_scsi_err.stage = SC_OK; s_scsi_err.csw_status = 0; s_scsi_err.data_done = 0;
    if (!bulk_xfer(d, d->bulk_out, cbw, 31, NULL, 1000)) { s_scsi_err.stage = SC_CBW; return false; }
    if (dlen) {
        /* data phase in chunks the host library accepts */
        uint32_t off = 0;
        while (off < dlen) {
            uint32_t n = dlen - off; if (n > 4096) n = 4096;
            size_t got = 0;
            if (!bulk_xfer(d, data_in ? d->bulk_in : d->bulk_out, data + off, n, &got, 3000)) {
                s_scsi_err.stage = SC_DATA; s_scsi_err.data_done = off; return false;
            }
            off += data_in ? (got ? got : n) : n;
            if (data_in && got < n) break;               /* short read: device sent less */
        }
        s_scsi_err.data_done = off;
    }
    uint8_t csw[13]; size_t got = 0;
    if (!bulk_xfer(d, d->bulk_in, csw, 13, &got, 1000)) {
        if (!bulk_xfer(d, d->bulk_in, csw, 13, &got, 1000)) { s_scsi_err.stage = SC_CSW_XFER; return false; }   /* one retry after a STALL clear */
    }
    if (!(got == 13 && csw[0]=='U' && csw[1]=='S' && csw[2]=='B' && csw[3]=='S')) { s_scsi_err.stage = SC_CSW_BAD; return false; }
    if (csw[12] != 0) { s_scsi_err.stage = SC_CSW_STATUS; s_scsi_err.csw_status = csw[12]; return false; }
    return true;
}

/* REQUEST SENSE after a CHECK CONDITION: key/ASC/ASCQ, or false. */
static bool scsi_request_sense(hdev *d, uint8_t *key, uint8_t *asc, uint8_t *ascq)
{
    uint8_t cb[16]; memset(cb, 0, 16); cb[0] = 0x03; cb[4] = 18;
    uint8_t sense[18]; memset(sense, 0, sizeof(sense));
    if (!scsi_cmd(d, cb, 6, sense, 18, true)) return false;
    *key = sense[2] & 0x0F; *asc = sense[12]; *ascq = sense[13];
    return true;
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
/* Failed READ(10)/WRITE(10) go to the console: the first 5, then every
 * 50th (a dying stick must not flood the OSD). `usb` prints the totals. */
static uint32_t s_msc_fail_rd, s_msc_fail_wr;
static char     s_msc_last_fail[80];
static void msc_log_failure(hdev *d, bool write, uint32_t lba, uint32_t n)
{
    uint8_t stage = s_scsi_err.stage, csw = s_scsi_err.csw_status; uint32_t done = s_scsi_err.data_done;
    uint32_t cnt = write ? ++s_msc_fail_wr : ++s_msc_fail_rd;
    uint8_t key = 0, asc = 0, ascq = 0; bool have_sense = false;
    if (stage == SC_CSW_STATUS) have_sense = scsi_request_sense(d, &key, &asc, &ascq);
    snprintf(s_msc_last_fail, sizeof(s_msc_last_fail), "%s lba %lu x%lu: %s csw=%02X data=%lu sense=%X/%02X/%02X",
             write ? "WRITE" : "READ", (unsigned long)lba, (unsigned long)n, scsi_stage_str(stage), csw,
             (unsigned long)done, have_sense ? key : 0xF, asc, ascq);
    if (cnt <= 5 || cnt % 50 == 0) {
        osd_log("USB HOST: %s LBA %lu X%lu FAILED", write ? "WRITE" : "READ", (unsigned long)lba, (unsigned long)n);
        osd_log("  %s", scsi_stage_str(stage));
        if (stage == SC_CSW_STATUS)
            osd_log("  CSW %02X SENSE KEY %X ASC %02X/%02X%s", csw, key, asc, ascq, have_sense ? "" : " (NO SENSE)");
        else if (stage == SC_DATA)
            osd_log("  %lu OF %lu BYTES MOVED", (unsigned long)done, (unsigned long)n * 512);
        if (cnt == 5) osd_log("  (FURTHER FAILURES: EVERY 50TH)");
    }
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
        if (!ok && s_msc == d) msc_log_failure(d, write, lba, n);
        buf += n * 512; lba += n; count -= n;
    }
    xSemaphoreGive(s_msc_lock);
    return ok;
}

/* `usb probe <lba> [read]`: one-sector read at lba, and unless read-only
 * and only if the sector is all zeros (free space, nothing to lose), a
 * WRITE(10) of the same zeros followed by a read-back. Reports each step
 * with its time; the MSC lock serialises it against FatFS. For bisecting a
 * stick that fails above some address (the 64 GB PNY, 2026-11-20). */
void usbhost_msc_probe(uint32_t lba, bool allow_write, void (*out)(void *ctx, const char *line), void *ctx)
{
    char b[120];
    uint32_t blocks = 0, bsize = 0;
    if (!usbhost_msc_capacity(&blocks, &bsize)) { out(ctx, "probe: no storage device"); return; }
    snprintf(b, sizeof(b), "probe: device has %lu blocks of %lu (%lu MB), lba %lu = %lu MB in",
             (unsigned long)blocks, (unsigned long)bsize, (unsigned long)((uint64_t)blocks * bsize >> 20),
             (unsigned long)lba, (unsigned long)((uint64_t)lba * bsize >> 20));
    out(ctx, b);
    if (lba >= blocks) { out(ctx, "probe: lba beyond the device"); return; }
    static uint8_t sec[512];
    uint32_t t0 = millis();
    bool ok = usbhost_msc_read(lba, 1, sec);
    uint32_t t1 = millis();
    if (!ok) { snprintf(b, sizeof(b), "probe: READ FAILED after %lu ms: %s", (unsigned long)(t1 - t0), s_msc_last_fail); out(ctx, b); return; }
    bool zero = true; for (int i = 0; i < 512; i++) if (sec[i]) { zero = false; break; }
    snprintf(b, sizeof(b), "probe: read ok in %lu ms, sector is %s", (unsigned long)(t1 - t0), zero ? "all zeros" : "NOT zero (in use?)");
    out(ctx, b);
    if (!allow_write) return;
    if (!zero) { out(ctx, "probe: refusing to write a non-zero sector; pick another lba or add 'read'"); return; }
    t0 = millis();
    ok = usbhost_msc_write(lba, 1, sec);
    t1 = millis();
    if (!ok) { snprintf(b, sizeof(b), "probe: WRITE FAILED after %lu ms: %s", (unsigned long)(t1 - t0), s_msc_last_fail); out(ctx, b); return; }
    snprintf(b, sizeof(b), "probe: write (same zeros) ok in %lu ms", (unsigned long)(t1 - t0)); out(ctx, b);
    memset(sec, 0xA5, sizeof(sec));
    t0 = millis();
    ok = usbhost_msc_read(lba, 1, sec);
    t1 = millis();
    if (!ok) { snprintf(b, sizeof(b), "probe: READ-BACK FAILED after %lu ms: %s", (unsigned long)(t1 - t0), s_msc_last_fail); out(ctx, b); return; }
    zero = true; for (int i = 0; i < 512; i++) if (sec[i]) { zero = false; break; }
    snprintf(b, sizeof(b), "probe: read-back ok in %lu ms, %s", (unsigned long)(t1 - t0), zero ? "still all zeros: PASS" : "NOT zeros: FAIL (data changed!)");
    out(ctx, b);
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
        case DK_KBD:                 /* boot report: [mods, reserved, key1..key6] */
            f->buttons = hid_decode_boot_kbd(buf, n);
            break;
        case DK_CONSUMER:
            if (f->con.rid && (n < 1 || buf[0] != f->con.rid)) break;   /* another report ID: keep state */
            f->buttons = hid_decode_consumer(&f->con, buf, n);
            break;
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

/* ---- hub-port enumeration retry (usbhub_retry.h) ------------------------------
 * Enumeration of a device behind a hub runs entirely inside the IDF hub
 * driver (ext_hub/ext_port + enum, prebuilt): our client only hears of a
 * device once it HAS enumerated, so nothing we do on NEW_DEV -- a delay, an
 * extra reset -- can change a port that fails before that. The one lever
 * left is the hub itself: the IDF driver opens hubs through usbh_devs_open
 * (no client; checked in libusb.a's ext_hub.c.obj), so a client may open a
 * hub too (usbhost_list already does) and talk to it over EP0. When the
 * driver logs "EXT_PORT: [hub:port] Port disabled" we power-cycle that one
 * port (ClearPortFeature / SetPortFeature PORT_POWER); the hub reports a
 * fresh connection and the driver debounces, resets and enumerates again.
 * The ladder (how many times, which delays, when it is a new plug) is the
 * pure usbhub_retry module; this is the plumbing. It never touches a port
 * whose device enumerated (PORT_ENABLE set), never a hub that switches all
 * ports together, adds no channels and holds the hub open only during a
 * cycle. The hook runs in the IDF daemon task: it only posts to the queue. */
static usbhub_retry_t s_hubr;

static void hub_retry_hook(const char *tag_msg)
{
    uint8_t hub, port;
    if (!s_work || !usbhub_retry_parse_disabled(tag_msg, &hub, &port)) return;
    work_item w = {}; w.kind = WORK_HUB_PORT_FAILED; w.addr = hub; w.port = port;
    xQueueSend(s_work, &w, 0);
}

enum hubcyc_result { HC_OK, HC_NO_HUB, HC_NOT_HUB, HC_PORT_EMPTY, HC_PORT_ENABLED, HC_GANGED, HC_NO_SWITCH, HC_XFER };

static bool hub_open(uint8_t addr, usb_device_handle_t *h)
{
    /* usbhost_list() opens and closes devices on this same client from the
     * menu/console tasks and the library refuses a second open by the same
     * client, so a collision makes one open fail: try a few times */
    for (int i = 0; i < 5; i++) {
        if (usb_host_device_open(s_client, addr, h) == ESP_OK) return true;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    *h = NULL;
    return false;
}

static bool hub_port_status(hdev *d, uint8_t port, usb_port_status_t *st)
{
    memset(st, 0, sizeof(*st));
    return ctrl_xfer(d, USB_BM_REQUEST_TYPE_DIR_IN | USB_BM_REQUEST_TYPE_PORT, USB_B_REQUEST_HUB_GET_PORT_STATUS,
                     0, port, USB_PORT_STATUS_SIZE, (uint8_t *)st) == ESP_OK;
}

/* One power cycle of hub:port (off for off_ms). Blocking; worker task only.
 * A hub with ganged power switching drops every port on the request; that
 * is refused only when settings()->usb_hub_retry_perport is set (*ganged = true
 * when it was done). */
static hubcyc_result hub_port_cycle(uint8_t hub, uint8_t port, uint16_t off_ms, bool *ganged)
{
    *ganged = false;
    hdev d; memset(&d, 0, sizeof(d)); d.addr = hub;
    if (!hub_open(hub, &d.dev)) return HC_NO_HUB;
    hubcyc_result r = HC_XFER;
    const usb_device_desc_t *dd = NULL;
    usb_hub_descriptor_t hd; usb_port_status_t st;
    if (usb_host_get_device_descriptor(d.dev, &dd) != ESP_OK || !dd || dd->bDeviceClass != 0x09) { r = HC_NOT_HUB; goto out; }
    if (ctrl_xfer(&d, USB_BM_REQUEST_TYPE_DIR_IN | USB_BM_REQUEST_TYPE_HUB, USB_B_REQUEST_HUB_GET_DESCRIPTOR,
                  (uint16_t)(USB_CLASS_DESCRIPTOR_TYPE_HUB << 8), 0, USB_HUB_DESCRIPTOR_SIZE, (uint8_t *)&hd) != ESP_OK) goto out;
    if (port < 1 || port > hd.bNbrPorts) { r = HC_NOT_HUB; goto out; }
    /* ganged switching cuts the HID dongle / Ethernet adapter too (they
     * re-enumerate in under a second); refused when SETTINGS USB HUB PORT
     * RETRY = PER-PORT */
    if (hd.wHubCharacteristics.power_switching == USB_W_HUB_CHARS_PORT_PWR_CTRL_ALL) {
        if (settings()->usb_hub_retry_perport) { r = HC_GANGED; goto out; }
        *ganged = true;
    }
    if (!hub_port_status(&d, port, &st)) goto out;
    if (!st.wPortStatus.PORT_CONNECTION) { r = HC_PORT_EMPTY; goto out; }     /* unplugged meanwhile */
    if (st.wPortStatus.PORT_ENABLE)      { r = HC_PORT_ENABLED; goto out; }   /* it enumerated after all: hands off */
    if (ctrl_xfer(&d, USB_BM_REQUEST_TYPE_PORT, USB_B_REQUEST_HUB_CLEAR_FEATURE, USB_FEATURE_PORT_POWER, port, 0, NULL) != ESP_OK) goto out;
    vTaskDelay(pdMS_TO_TICKS(50));
    /* a hub without power switching may answer the request and change
     * nothing; then the cycle is a no-op and we say so instead of looping */
    {
        bool changed = hub_port_status(&d, port, &st) && (!st.wPortStatus.PORT_POWER || !st.wPortStatus.PORT_CONNECTION);
        if (off_ms > 50) vTaskDelay(pdMS_TO_TICKS(off_ms - 50));
        if (ctrl_xfer(&d, USB_BM_REQUEST_TYPE_PORT, USB_B_REQUEST_HUB_SET_PORT_FEATURE, USB_FEATURE_PORT_POWER, port, 0, NULL) != ESP_OK) goto out;
        r = changed ? HC_OK : HC_NO_SWITCH;
    }
out:
    usb_host_device_close(s_client, d.dev);
    return r;
}

static void hub_port_failed(uint8_t hub, uint8_t port)
{
    usbhub_retry_plan_t plan = {};
    usbhub_retry_action_t act = usbhub_retry_on_failure(&s_hubr, hub, port, millis(), &plan);
    if (act == USBHUB_RETRY_IGNORE) return;
    if (act == USBHUB_RETRY_GIVE_UP) {
        osd_log("USB HOST: HUB %u PORT %u FAILED TO", hub, port);
        osd_log("  ENUMERATE, PLUG THE STICK DIRECTLY");
        ESP_LOGW(TAG, "hub %u port %u: gave up after %u port power cycles", hub, port, USBHUB_RETRY_MAX);
        return;
    }
    osd_log("USB HOST: HUB %u PORT %u ENUM FAILED,", hub, port);
    osd_log("  POWER CYCLING PORT (TRY %u/%u)", plan.attempt, USBHUB_RETRY_MAX);
    vTaskDelay(pdMS_TO_TICKS(plan.settle_ms));          /* let the driver finish recycling the port */
    bool ganged = false;
    hubcyc_result r = hub_port_cycle(hub, port, plan.off_ms, &ganged);
    switch (r) {
    case HC_OK:
        usbhub_retry_cycled(&s_hubr, hub, port, millis());
        if (ganged) osd_log("  GANGED HUB: ALL ITS PORTS WERE CYCLED");
        ESP_LOGI(TAG, "hub %u port %u: power cycled (%u ms off%s), waiting for the driver", hub, port, plan.off_ms, ganged ? ", all ports" : "");
        return;
    case HC_PORT_EMPTY:
        usbhub_retry_resolved(&s_hubr, hub, port);
        osd_log("USB HOST: HUB %u PORT %u IS EMPTY NOW", hub, port);
        return;
    case HC_PORT_ENABLED:
        usbhub_retry_resolved(&s_hubr, hub, port);
        ESP_LOGI(TAG, "hub %u port %u: enabled meanwhile, not touched", hub, port);
        return;
    case HC_NO_HUB:    osd_log("USB HOST: CANNOT OPEN HUB %u FROM OUR", hub); osd_log("  CLIENT, NO PORT RETRY:"); break;
    case HC_NOT_HUB:   osd_log("USB HOST: ADDR %u IS NOT A HUB WITH", hub);   osd_log("  PORT %u, NO PORT RETRY:", port); break;
    case HC_GANGED:    osd_log("USB HOST: HUB %u SWITCHES PORT POWER", hub); osd_log("  GANGED (ALL PORTS), NO PORT RETRY:");
                       osd_log("  (SETTINGS: USB HUB PORT RETRY=ALL PORTS)"); break;
    case HC_NO_SWITCH: osd_log("USB HOST: HUB %u IGNORED PORT POWER OFF,", hub); osd_log("  NO PORT RETRY:"); break;
    default:           osd_log("USB HOST: HUB %u CONTROL TRANSFER FAILED,", hub); osd_log("  NO PORT RETRY:"); break;
    }
    osd_log("  PLUG THE STICK DIRECTLY");
    usbhub_retry_abort(&s_hubr, hub, port, millis());
}

/* NEW_DEV while a cycle of ours awaits its verdict: is this the device on
 * that hub port? Device handles are the library's device objects, so the
 * hub opened by address compares equal to the new device's parent handle. */
static void hub_retry_check_recovered(hdev *d)
{
    if (!usbhub_retry_pending(&s_hubr)) return;
    usb_device_info_t info;
    if (usb_host_device_info(d->dev, &info) != ESP_OK || !info.parent.dev_hdl) return;
    for (int i = 0; i < USBHUB_RETRY_SLOTS; i++) {
        const usbhub_retry_slot_t *s = &s_hubr.slot[i];
        if (s->state != USBHUB_SLOT_WAITING || s->port != info.parent.port_num) continue;
        uint8_t hub = s->hub, port = s->port;
        usb_device_handle_t hh = NULL;
        if (usb_host_device_open(s_client, hub, &hh) != ESP_OK) continue;
        bool match = (hh == info.parent.dev_hdl);
        usb_host_device_close(s_client, hh);
        if (!match) continue;
        int n = usbhub_retry_resolved(&s_hubr, hub, port);
        osd_log("USB HOST: HUB %u PORT %u RECOVERED AFTER", hub, port);
        osd_log("  %d PORT POWER CYCLE%s", n, n == 1 ? "" : "S");
        return;
    }
}

/* ---- device attach --------------------------------------------------------- */
static void attach_device(uint8_t addr)
{
    hdev *d = dev_alloc();
    if (!d) return;
    if (usb_host_device_open(s_client, addr, &d->dev) != ESP_OK) { d->dev = NULL; return; }
    d->addr = addr;
    hub_retry_check_recovered(d);
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
                hid_parse_consumer_layout(rdesc, rlen, &f->con);
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
    if (d->nin == 0 && dd && dd->bNumConfigurations > 1) {
        /* Nothing we drive in the active configuration: a dual-configuration
         * Ethernet adapter (Realtek) keeps its CDC-ECM function in another one */
        hintf *f = &d->in[0]; memset(f, 0, sizeof(*f)); f->dev = d; f->intf = 0;
        if (usbeth_attach_alt(s_client, d->dev, (const uint8_t *)cfg, cfg->wTotalLength,
                              dd->bNumConfigurations, dd->idVendor, dd->idProduct)) {
            f->kind = DK_ETH; d->eth = true; d->nin = 1;
        }
    }
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
    if (m->event == USB_HOST_CLIENT_EVENT_NEW_DEV) { w.kind = WORK_NEW; w.addr = m->new_dev.address; }
    else if (m->event == USB_HOST_CLIENT_EVENT_DEV_GONE) { w.kind = WORK_GONE; w.dev = m->dev_gone.dev_hdl; }
    else return;
    if (s_work) xQueueSend(s_work, &w, 0);
}

static void worker_task(void *arg)
{
    (void)arg;
    work_item w;
    for (;;) {
        if (xQueueReceive(s_work, &w, portMAX_DELAY) != pdTRUE) continue;
        switch (w.kind) {
        case WORK_GONE:            detach_device(w.dev); break;
        case WORK_HUB_PORT_FAILED: hub_port_failed(w.addr, w.port); break;
        default:                   attach_device(w.addr); break;
        }
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
    usbhub_retry_init(&s_hubr);
    idf_log_tee_set_hook(hub_retry_hook);              /* "EXT_PORT: [h:p] Port disabled" -> port power cycle */
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

/* SETTINGS / console: allow (true, default) or refuse (false) cycling a ganged hub */
bool usbhost_set_hub_retry(bool all_ports)
{
    settings()->usb_hub_retry_perport = all_ports ? 0 : 1;
    return settings_save();
}

/* ---- device listing (USB DEVICES screen, `usb` console) ------------------- */
static void str16_to_ascii(const usb_str_desc_t *sd, char *out, int cap)
{
    int n = 0;
    if (sd && sd->bLength >= 2) {
        int chars = (sd->bLength - 2) / 2;
        for (int i = 0; i < chars && n < cap - 1; i++) {
            uint16_t c = sd->wData[i];
            char ch = (c >= 32 && c < 127) ? (char)c : '?';
            if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 32);
            out[n++] = ch;
        }
    }
    out[n] = 0;
}

static const char *intf_kind(uint8_t cls, uint8_t sub, uint8_t proto)
{
    switch (cls) {
    case 0x09: return "HUB";
    case 0x08: return (sub == 0x06 && proto == 0x50) ? "STORAGE" : "STORAGE?";
    case 0x03: return (sub == 0x01 && proto == 0x01) ? "KEYBOARD" :
                      (sub == 0x01 && proto == 0x02) ? "MOUSE" : "HID";
    case 0x02: return sub == 0x06 ? "ETHERNET ECM" : sub == 0x0D ? "ETHERNET NCM" :
                      sub == 0x02 ? "CDC SERIAL" : "CDC";
    case 0x0A: return NULL;                              /* CDC data: look at the control intf */
    case 0x01: return "AUDIO";
    case 0x0E: return "VIDEO";
    case 0xE0: return "WIRELESS";
    case 0xFF: return (sub == 0x5D && proto == 0x01) ? "XINPUT PAD" : "VENDOR";
    default:   return NULL;
    }
}

int usbhost_list(usbhost_devinfo_t *out, int max)
{
    if (!s_active || !s_client || max <= 0) return 0;
    uint8_t addrs[8]; int num = 0;
    if (usb_host_device_addr_list_fill(8, addrs, &num) != ESP_OK) return 0;
    int n = 0;
    for (int i = 0; i < num && n < max; i++) {
        /* A device our worker already serves is open on s_client, and the
         * host library refuses a second open by the same client: reuse the
         * worker's handle for those and only open (and later close) the rest. */
        usb_device_handle_t h = NULL;
        bool ours = false;
        for (auto &d : s_devs) if (d.dev && d.addr == addrs[i]) { h = d.dev; ours = true; break; }
        if (!ours && usb_host_device_open(s_client, addrs[i], &h) != ESP_OK) continue;
        usbhost_devinfo_t *o = &out[n];
        memset(o, 0, sizeof(*o));
        o->addr = addrs[i];
        const usb_device_desc_t *dd = NULL;
        if (usb_host_get_device_descriptor(h, &dd) == ESP_OK && dd) {
            o->vid = dd->idVendor; o->pid = dd->idProduct;
            if (dd->bDeviceClass == 0x09) strcpy(o->kind, "HUB");
        }
        /* A dual-configuration Ethernet adapter (Realtek) switched to its CDC
         * configuration after usbeth.c claimed it; the config walk below sees
         * neither, so name it from the driver's own flag. */
        if (!o->kind[0]) for (auto &d : s_devs) if (d.dev && d.addr == o->addr && d.eth) { strcpy(o->kind, "ETHERNET"); break; }
        usb_device_info_t info;
        if (usb_host_device_info(h, &info) == ESP_OK) {
            str16_to_ascii(info.str_desc_product, o->product, sizeof(o->product));
            o->speed = (uint8_t)info.speed;
        }
        const usb_config_desc_t *cfg = NULL;
        if (!o->kind[0] && usb_host_get_active_config_descriptor(h, &cfg) == ESP_OK && cfg) {
            /* Composite devices (the remote dongle is audio + HID): name the
             * device after the interface we would serve, not the first one. */
            char classes[14] = "";
            int best = 0;
            for (uint8_t k = 0; k < cfg->bNumInterfaces; k++) {
                int off = 0;
                const usb_intf_desc_t *id = usb_parse_interface_descriptor(cfg, k, 0, &off);
                if (!id) continue;
                const char *kd = intf_kind(id->bInterfaceClass, id->bInterfaceSubClass, id->bInterfaceProtocol);
                if (!kd) { if (!classes[0]) snprintf(classes, sizeof(classes), "CLASS %02X", id->bInterfaceClass); continue; }
                int rank = 1;
                switch (id->bInterfaceClass) {
                case 0x08: rank = 5; break;                          /* storage */
                case 0x03: rank = 4; break;                          /* HID */
                case 0xFF: rank = (id->bInterfaceSubClass == 0x5D) ? 4 : 1; break; /* XInput */
                case 0x02: rank = 3; break;                          /* CDC / Ethernet */
                default:   rank = 2; break;
                }
                if (rank > best) { best = rank; snprintf(o->kind, sizeof(o->kind), "%s", kd); }
            }
            if (!o->kind[0]) snprintf(o->kind, sizeof(o->kind), "%s", classes[0] ? classes : "NO INTERFACE");
        }
        if (!o->kind[0]) strcpy(o->kind, "UNKNOWN");
        for (auto &d : s_devs) if (d.dev && d.addr == o->addr && d.nin) o->served = true;
        if (!ours) usb_host_device_close(s_client, h);
        n++;
    }
    return n;
}

void usbhost_console(void (*out)(void *ctx, const char *line), void *ctx)
{
    char b[112];
    snprintf(b, sizeof(b), "usb: %s%s", s_status, s_active ? "" : " (device mode: no host enumeration)");
    out(ctx, b);
    snprintf(b, sizeof(b), "  hub port retry: %s (usb retry on|off; SETTINGS -> USB HUB PORT RETRY)",
             settings()->usb_hub_retry_perport ? "PER-PORT ONLY (ganged hubs refused)" : "ALL PORTS (ganged hubs cycled too, default)");
    out(ctx, b);
    if (s_msc_fail_rd || s_msc_fail_wr) {
        snprintf(b, sizeof(b), "  storage failures: %lu read, %lu write; last:",
                 (unsigned long)s_msc_fail_rd, (unsigned long)s_msc_fail_wr);
        out(ctx, b);
        out(ctx, s_msc_last_fail);
    }
    if (!s_active) return;
    usbhost_devinfo_t devs[8];
    int n = usbhost_list(devs, 8);
    if (!n) { out(ctx, "  (no devices enumerated)"); return; }
    static const char *const spd[] = { "LS", "FS", "HS" };
    for (int i = 0; i < n; i++) {
        snprintf(b, sizeof(b), "  addr %u  %04X:%04X  %-13s %s  %s%s", devs[i].addr, devs[i].vid, devs[i].pid,
                 devs[i].kind, devs[i].speed < 3 ? spd[devs[i].speed] : "??",
                 devs[i].product[0] ? devs[i].product : "-", devs[i].served ? "  [in use]" : "");
        out(ctx, b);
    }
}

#else  /* !A2MEGA_HAS_OSPI_LINK: dp_test builds keep the port in device mode */

void     usbhost_start(void)       {}
bool     usbhost_active(void)      { return false; }
bool     usbhost_pad_present(void) { return false; }
bool     usbhost_hid_present(void) { return false; }
uint16_t usbhost_buttons(void)     { return 0; }
const char *usbhost_status_str(void) { return "DEVICE MODE"; }
int      usbhost_list(usbhost_devinfo_t *o, int m) { (void)o; (void)m; return 0; }
void     usbhost_console(void (*out)(void *ctx, const char *line), void *ctx) { out(ctx, "usb: not built into this variant"); }
bool     usbhost_set_hub_retry(bool all_ports) { (void)all_ports; return false; }
bool     usbhost_msc_present(void) { return false; }
bool     usbhost_msc_capacity(uint32_t *b, uint32_t *s) { (void)b; (void)s; return false; }
bool     usbhost_msc_read(uint32_t l, uint32_t c, uint8_t *b) { (void)l; (void)c; (void)b; return false; }
void     usbhost_msc_probe(uint32_t l, bool w, void (*out)(void *ctx, const char *line), void *ctx) { (void)l; (void)w; out(ctx, "probe: not built into this variant"); }
bool     usbhost_msc_write(uint32_t l, uint32_t c, const uint8_t *b) { (void)l; (void)c; (void)b; return false; }

#endif
