/*
 * ble_hid.c — see ble_hid.h. HID-over-GATT central on raw esp-nimble.
 *
 * Threads: every ble_gap and ble_gattc callback runs in the NimBLE host
 * task (core 0, 5 KB stack per sdkconfig): keep them short, no OSD painting.
 * The menu task reads state through the accessors below; the candidate list
 * and strings are guarded by a spinlock, everything else is a single word.
 * The NimBLE API itself is safe to call from any task.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "board_pins.h"
#include "a2fpga_regs.h"
#include "hid_map.h"
#include "ble_hid.h"

#if A2MEGA_HAS_OSPI_LINK

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "nvs.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_store.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

#include "osd_console.h"

/* store/config/ble_store_config.h is not on the Arduino include path; the
 * symbol is in libbt.a (CONFIG_BT_NIMBLE_NVS_PERSIST=y). */
void ble_store_config_init(void);

static const char *TAG = "blehid";

/* ---- tunables ---------------------------------------------------------------- */
#define PAIR_SCAN_MS        60000     /* pairing window                         */
#define PAIR_AUTO_S         15        /* auto-connect to the strongest after    */
#define CONNECT_TIMEOUT_MS  10000
#define RECONNECT_SCAN_ITVL 0x0640    /* 1 s                                     */
#define RECONNECT_SCAN_WIN  0x0050    /* 50 ms -> 5 % duty beside WiFi           */
#define MAX_CAND            8
#define NAME_LEN            24
#define MAX_CHRS            24        /* every characteristic of the HID service */
#define SETUP_FAIL_MAX      3         /* consecutive setup failures before we stop */
#define RMAP_MAX            512

#define UUID_HID_SVC        0x1812
#define UUID_REPORT_MAP     0x2A4B
#define UUID_REPORT         0x2A4D
#define UUID_BOOT_KBD_IN    0x2A22
#define UUID_DEVICE_NAME    0x2A00
#define UUID_CCCD           0x2902
#define UUID_REPORT_REF     0x2908

#define NVS_NS              "blehid"
#define NVS_KEY_PEER        "peer"
#define PEER_MAGIC          0xB1

/* ---- state ------------------------------------------------------------------ */
typedef struct {
    uint8_t  magic;
    uint8_t  addr_type;
    uint8_t  addr[6];
    char     name[NAME_LEN];
    uint16_t appearance;
} peer_rec_t;

typedef struct {
    ble_addr_t addr;
    int8_t     rssi;
    char       name[NAME_LEN];
    int64_t    first_seen_us;
    int64_t    last_seen_us;
    bool       connectable;
} cand_t;

typedef struct {
    uint16_t uuid16;
    uint16_t val_handle;
    uint16_t cccd_handle;
    uint16_t rref_handle;
    uint8_t  rid, rtype;     /* from Report Reference: type 1 in, 2 out, 3 feat */
    uint16_t bits;           /* last decoded buttons of this report           */
} chr_t;

static portMUX_TYPE          s_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile ble_hid_state_t s_state = BLEH_OFF;
static volatile bool         s_ready;                /* host synced */
static volatile bool         s_dirty;
static volatile uint16_t     s_buttons;
static uint8_t               s_own_addr_type;
static char                  s_msg[41];

static peer_rec_t            s_peer;                 /* magic == PEER_MAGIC when known */
static uint16_t              s_conn = BLE_HS_CONN_HANDLE_NONE;   /* the active peer link */
static bool                  s_conn_is_pair_target;  /* link under pairing, not yet the peer */
static bool                  s_retried_security;
static int                   s_setup_fail;        /* consecutive discovery/security failures */

/* pairing */
static volatile bool         s_pairing;
static volatile bool         s_pair_pending;      /* scan starts once the connect cancel lands */
static volatile int          s_pair_result;
static cand_t                s_cand[MAX_CAND];
static int                   s_ncand;
static int64_t               s_pair_t0_us;
static cand_t                s_target;

/* discovery */
static chr_t                 s_chr[MAX_CHRS];
static int                   s_nchr;
static uint16_t              s_svc_start, s_svc_end;
static int                   s_ds;                   /* discovery step */
static int                   s_ds_idx;
static uint8_t               s_rmap[RMAP_MAX];
static uint16_t              s_rmap_len;
static hid_report_map_t      s_map;
static char                  s_live_name[NAME_LEN];  /* GAP device name read on the link */

/* ---- helpers ---------------------------------------------------------------- */
static void set_msg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_msg(const char *fmt, ...)
{
    char b[41];
    va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap);
    portENTER_CRITICAL(&s_mux);
    strncpy(s_msg, b, sizeof(s_msg) - 1); s_msg[sizeof(s_msg) - 1] = 0;
    portEXIT_CRITICAL(&s_mux);
    s_dirty = true;
    ESP_LOGI(TAG, "%s", b);
}

static void set_state(ble_hid_state_t st)
{
    if (s_state != st) { s_state = st; s_dirty = true; }
}

static void addr_str(const uint8_t *a, char *out, int cap)
{
    snprintf(out, cap, "%02X:%02X:%02X:%02X:%02X:%02X", a[5], a[4], a[3], a[2], a[1], a[0]);
}

static void upcase_copy(char *dst, int cap, const uint8_t *src, int n)
{
    int i = 0;
    for (; i < n && i < cap - 1; i++) {
        char c = (char)src[i];
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c < 32 || c > 126) c = '?';
        dst[i] = c;
    }
    dst[i] = 0;
}

static bool peer_known(void) { return s_peer.magic == PEER_MAGIC; }

static bool peer_matches(const ble_addr_t *a)
{
    return peer_known() && a->type == s_peer.addr_type && memcmp(a->val, s_peer.addr, 6) == 0;
}

static void peer_load(void)
{
    nvs_handle_t h;
    memset(&s_peer, 0, sizeof(s_peer));
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    size_t n = sizeof(s_peer);
    if (nvs_get_blob(h, NVS_KEY_PEER, &s_peer, &n) != ESP_OK || n != sizeof(s_peer) || s_peer.magic != PEER_MAGIC)
        memset(&s_peer, 0, sizeof(s_peer));
    nvs_close(h);
}

static bool peer_save(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return false;
    esp_err_t e = peer_known() ? nvs_set_blob(h, NVS_KEY_PEER, &s_peer, sizeof(s_peer))
                               : nvs_erase_key(h, NVS_KEY_PEER);
    if (e == ESP_OK || e == ESP_ERR_NVS_NOT_FOUND) e = nvs_commit(h);
    nvs_close(h);
    return e == ESP_OK;
}

static void buttons_recompute(void)
{
    uint16_t b = 0;
    for (int i = 0; i < s_nchr; i++) b |= s_chr[i].bits;
    s_buttons = b;
}

/* ---- GAP: scanning / connecting ------------------------------------------------ */
static int gap_event(struct ble_gap_event *ev, void *arg);

static const struct ble_gap_conn_params k_conn_params = {
    .scan_itvl = RECONNECT_SCAN_ITVL, .scan_window = RECONNECT_SCAN_WIN,
    .itvl_min = 6, .itvl_max = 24,          /* 7.5 .. 30 ms; the device may renegotiate */
    .latency = 0, .supervision_timeout = 400, /* 4 s */
    .min_ce_len = 0, .max_ce_len = 0,
};

/* Initiate to the bonded peer: the controller scans at a low duty and
 * connects when (and only when) that address advertises. Runs forever. */
static void start_reconnect(void)
{
    if (!s_ready || !peer_known()) { set_state(BLEH_IDLE); return; }
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        /* the peer link is still up (a replacement pairing was cancelled or
         * failed): nothing to initiate, just show the link state again */
        set_state(s_nchr ? BLEH_CONNECTED : BLEH_DISCOVERING);
        return;
    }
    if (s_setup_fail >= SETUP_FAIL_MAX) {
        set_state(BLEH_ERROR);
        set_msg("GIVING UP ON %s - PAIR AGAIN", s_peer.name[0] ? s_peer.name : "DEVICE");
        return;
    }
    ble_addr_t a = { .type = s_peer.addr_type };
    memcpy(a.val, s_peer.addr, 6);
    int rc = ble_gap_connect(s_own_addr_type, &a, BLE_HS_FOREVER, &k_conn_params, gap_event, NULL);
    if (rc == 0 || rc == BLE_HS_EALREADY) {
        set_state(BLEH_RECONNECT);
    } else {
        ESP_LOGW(TAG, "reconnect initiate rc=%d", rc);
        set_state(BLEH_ERROR);
        set_msg("RECONNECT FAILED (%d)", rc);
    }
}

/* ble_gap_disc_cancel() is synchronous (scan off, master state reset);
 * ble_gap_conn_cancel() is NOT: the controller reports the cancelled
 * initiation as a CONNECT event with status BLE_HS_EAPP, and until then
 * every other GAP master operation is refused with EBUSY. Whatever must
 * follow a cancel therefore starts from that event (resume_after_cancel). */
static void start_pair_scan(void);

static void resume_after_cancel(void)
{
    if (s_pair_pending) {
        s_pair_pending = false;
        start_pair_scan();
    } else if (!s_pairing) {
        start_reconnect();
    }
}

static void connect_to(const cand_t *c)
{
    struct ble_gap_conn_params p = k_conn_params;
    p.scan_itvl = 0x0030; p.scan_window = 0x0030;   /* continuous while pairing */
    s_conn_is_pair_target = true;
    s_retried_security = false;
    s_setup_fail = 0;
    set_state(BLEH_CONNECTING);
    set_msg("CONNECTING TO %s", c->name[0] ? c->name : "DEVICE");
    int rc = ble_gap_connect(s_own_addr_type, &c->addr, CONNECT_TIMEOUT_MS, &p, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "connect rc=%d", rc);
        s_conn_is_pair_target = false;
        s_pairing = false; s_pair_result = -1;
        set_state(BLEH_ERROR);
        set_msg("CONNECT FAILED (%d)", rc);
        start_reconnect();
    }
}

/* candidate list (host task writes, menu task reads) */
static cand_t *cand_find(const ble_addr_t *a)
{
    for (int i = 0; i < s_ncand; i++)
        if (s_cand[i].addr.type == a->type && memcmp(s_cand[i].addr.val, a->val, 6) == 0) return &s_cand[i];
    return NULL;
}

static bool adv_is_hid(const struct ble_hs_adv_fields *f)
{
    for (int i = 0; i < f->num_uuids16; i++)
        if (ble_uuid_u16(&f->uuids16[i].u) == UUID_HID_SVC) return true;
    if (f->appearance_is_present) {
        uint16_t cat = f->appearance >> 6;            /* 0x00F = HID */
        if (cat == 0x00F) return true;
    }
    return false;
}

static void on_disc(const struct ble_gap_disc_desc *d)
{
    if (!s_pairing) return;
    struct ble_hs_adv_fields f;
    if (ble_hs_adv_parse_fields(&f, d->data, d->length_data) != 0) return;
    bool connectable = d->event_type == BLE_HCI_ADV_RPT_EVTYPE_ADV_IND ||
                       d->event_type == BLE_HCI_ADV_RPT_EVTYPE_DIR_IND;
    bool is_rsp = d->event_type == BLE_HCI_ADV_RPT_EVTYPE_SCAN_RSP;
    int64_t now = esp_timer_get_time();

    portENTER_CRITICAL(&s_mux);
    cand_t *c = cand_find(&d->addr);
    if (!c) {
        if (!adv_is_hid(&f) || !connectable || s_ncand >= MAX_CAND) { portEXIT_CRITICAL(&s_mux); return; }
        c = &s_cand[s_ncand++];
        memset(c, 0, sizeof(*c));
        c->addr = d->addr; c->rssi = d->rssi; c->first_seen_us = now; c->connectable = true;
        s_dirty = true;
    } else {
        c->rssi = (int8_t)((c->rssi * 3 + d->rssi) / 4);     /* smooth */
        if (connectable) c->connectable = true;
    }
    c->last_seen_us = now;
    if (f.name && f.name_len && (!c->name[0] || f.name_is_complete || is_rsp)) {
        char nm[NAME_LEN];
        upcase_copy(nm, sizeof(nm), f.name, f.name_len);
        if (strcmp(nm, c->name)) { strcpy(c->name, nm); s_dirty = true; }
    }
    portEXIT_CRITICAL(&s_mux);
}

static void start_pair_scan(void)
{
    struct ble_gap_disc_params p;
    memset(&p, 0, sizeof(p));
    p.itvl = 0x0050; p.window = 0x0030;     /* 50 ms / 30 ms: 60 % duty, WiFi still breathes */
    p.passive = 0;                          /* active: ask for scan responses (names) */
    p.filter_duplicates = 0;                /* keep RSSI fresh */
    int rc = ble_gap_disc(s_own_addr_type, PAIR_SCAN_MS, &p, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_gap_disc rc=%d", rc);
        s_pairing = false; s_pair_result = -1;
        set_state(BLEH_ERROR);
        set_msg("SCAN FAILED (%d)", rc);
        start_reconnect();
        return;
    }
    set_state(BLEH_PAIR_SCAN);
    set_msg("SCANNING - PUT DEVICE IN PAIRING MODE");
}

/* ---- GATT discovery --------------------------------------------------------------- */
enum { DS_NONE, DS_NAME, DS_SVC, DS_CHRS, DS_DSCS, DS_RREF, DS_MAP, DS_CCCD, DS_DONE };

static void disc_advance(void);

static void disc_fail(const char *why)
{
    s_setup_fail++;
    set_msg("SETUP FAILED: %s", why);
    set_state(BLEH_ERROR);
    if (s_conn != BLE_HS_CONN_HANDLE_NONE)
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
}

static int cb_name(uint16_t conn, const struct ble_gatt_error *err, struct ble_gatt_attr *attr, void *arg)
{
    (void)arg;
    if (err->status == 0 && attr && conn == s_conn) {
        uint8_t b[NAME_LEN]; uint16_t n = OS_MBUF_PKTLEN(attr->om);
        if (n > sizeof(b)) n = sizeof(b);
        os_mbuf_copydata(attr->om, 0, n, b);
        portENTER_CRITICAL(&s_mux);
        upcase_copy(s_live_name, sizeof(s_live_name), b, n);
        portEXIT_CRITICAL(&s_mux);
        return 0;
    }
    /* EDONE / error / not found: move on either way */
    s_ds = DS_SVC; disc_advance();
    return 0;
}

static int cb_svc(uint16_t conn, const struct ble_gatt_error *err, const struct ble_gatt_svc *svc, void *arg)
{
    (void)arg;
    if (conn != s_conn) return 0;
    if (err->status == 0 && svc) {
        s_svc_start = svc->start_handle; s_svc_end = svc->end_handle;
        return 0;
    }
    if (err->status == BLE_HS_EDONE && s_svc_end) { s_ds = DS_CHRS; disc_advance(); }
    else disc_fail("NO HID SERVICE");
    return 0;
}

static int cb_chr(uint16_t conn, const struct ble_gatt_error *err, const struct ble_gatt_chr *chr, void *arg)
{
    (void)arg;
    if (conn != s_conn) return 0;
    if (err->status == 0 && chr) {
        /* record every characteristic (128-bit ones as uuid16 = 0) so that
         * cb_dsc can attribute each descriptor to its owner by handle order;
         * only Report / Report Map / Boot Keyboard Input are acted on */
        if (s_nchr < MAX_CHRS) {
            chr_t *c = &s_chr[s_nchr++];
            memset(c, 0, sizeof(*c));
            c->uuid16 = chr->uuid.u.type == BLE_UUID_TYPE_16 ? ble_uuid_u16(&chr->uuid.u) : 0;
            c->val_handle = chr->val_handle;
        }
        return 0;
    }
    if (err->status == BLE_HS_EDONE && s_nchr) { s_ds = DS_DSCS; disc_advance(); }
    else disc_fail("NO REPORTS");
    return 0;
}

static int cb_dsc(uint16_t conn, const struct ble_gatt_error *err, uint16_t chr_val_handle,
                  const struct ble_gatt_dsc *dsc, void *arg)
{
    (void)arg; (void)chr_val_handle;
    if (conn != s_conn) return 0;
    if (err->status == 0 && dsc) {
        if (dsc->uuid.u.type != BLE_UUID_TYPE_16) return 0;
        uint16_t u = ble_uuid_u16(&dsc->uuid.u);
        if (u != UUID_CCCD && u != UUID_REPORT_REF) return 0;
        /* belongs to the characteristic with the greatest value handle below it */
        chr_t *best = NULL;
        for (int i = 0; i < s_nchr; i++)
            if (s_chr[i].val_handle < dsc->handle && (!best || s_chr[i].val_handle > best->val_handle))
                best = &s_chr[i];
        if (best) {
            if (u == UUID_CCCD) best->cccd_handle = dsc->handle;
            else                best->rref_handle = dsc->handle;
        }
        return 0;
    }
    s_ds = DS_RREF; s_ds_idx = 0; disc_advance();
    return 0;
}

static int cb_rref(uint16_t conn, const struct ble_gatt_error *err, struct ble_gatt_attr *attr, void *arg)
{
    chr_t *c = (chr_t *)arg;
    if (conn != s_conn) return 0;
    if (err->status == 0 && attr && OS_MBUF_PKTLEN(attr->om) >= 2) {
        uint8_t b[2]; os_mbuf_copydata(attr->om, 0, 2, b);
        c->rid = b[0]; c->rtype = b[1];
    }
    s_ds_idx++; disc_advance();
    return 0;
}

static int cb_map(uint16_t conn, const struct ble_gatt_error *err, struct ble_gatt_attr *attr, void *arg)
{
    (void)arg;
    if (conn != s_conn) return 0;
    if (err->status == 0 && attr) {
        uint16_t n = OS_MBUF_PKTLEN(attr->om);
        uint16_t off = attr->offset;
        if (off == s_rmap_len && off + n <= RMAP_MAX) {
            os_mbuf_copydata(attr->om, 0, n, s_rmap + off);
            s_rmap_len = (uint16_t)(off + n);
        }
        return 0;
    }
    /* EDONE (or a read error: whatever we have) */
    bool ok = s_rmap_len && hid_parse_report_map(s_rmap, s_rmap_len, &s_map);
    ESP_LOGI(TAG, "report map %u bytes -> %u fields (kbd %d con %d pad %d, %u buttons)%s",
             s_rmap_len, s_map.nf, s_map.has_kbd, s_map.has_consumer, s_map.has_pad, s_map.nbuttons,
             ok ? "" : " (none usable)");
    s_ds = DS_CCCD; s_ds_idx = 0; disc_advance();
    return 0;
}

static int cb_cccd(uint16_t conn, const struct ble_gatt_error *err, struct ble_gatt_attr *attr, void *arg)
{
    (void)attr; (void)arg;
    if (conn != s_conn) return 0;
    if (err->status) ESP_LOGW(TAG, "CCCD write status %d", err->status);
    s_ds_idx++; disc_advance();
    return 0;
}

static bool chr_wants_notify(const chr_t *c)
{
    if (!c->cccd_handle) return false;
    if (c->uuid16 == UUID_REPORT) return c->rtype == 1 || c->rtype == 0;   /* input (0: no rref seen, try) */
    if (c->uuid16 == UUID_BOOT_KBD_IN) return s_map.nf == 0;              /* boot fallback only */
    return false;
}

static void disc_advance(void)
{
    uint16_t conn = s_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE) return;
    int rc = 0;
    switch (s_ds) {
    case DS_NAME: {
        if (s_live_name[0]) { s_ds = DS_SVC; disc_advance(); return; }
        ble_uuid16_t u = BLE_UUID16_INIT(UUID_DEVICE_NAME);
        rc = ble_gattc_read_by_uuid(conn, 1, 0xFFFF, &u.u, cb_name, NULL);
        break;
    }
    case DS_SVC: {
        ble_uuid16_t u = BLE_UUID16_INIT(UUID_HID_SVC);
        s_svc_start = s_svc_end = 0; s_nchr = 0; s_rmap_len = 0; memset(&s_map, 0, sizeof(s_map));
        rc = ble_gattc_disc_svc_by_uuid(conn, &u.u, cb_svc, NULL);
        break;
    }
    case DS_CHRS:
        rc = ble_gattc_disc_all_chrs(conn, s_svc_start, s_svc_end, cb_chr, NULL);
        break;
    case DS_DSCS:
        /* Find Information over the whole service: descriptors are assigned
         * to characteristics by handle order in cb_dsc */
        rc = ble_gattc_disc_all_dscs(conn, s_svc_start, s_svc_end, cb_dsc, NULL);
        break;
    case DS_RREF:
        while (s_ds_idx < s_nchr && !(s_chr[s_ds_idx].uuid16 == UUID_REPORT && s_chr[s_ds_idx].rref_handle))
            s_ds_idx++;
        if (s_ds_idx >= s_nchr) { s_ds = DS_MAP; disc_advance(); return; }
        rc = ble_gattc_read(conn, s_chr[s_ds_idx].rref_handle, cb_rref, &s_chr[s_ds_idx]);
        break;
    case DS_MAP: {
        int i;
        for (i = 0; i < s_nchr && s_chr[i].uuid16 != UUID_REPORT_MAP; i++) ;
        if (i >= s_nchr) { s_ds = DS_CCCD; s_ds_idx = 0; disc_advance(); return; }
        rc = ble_gattc_read_long(conn, s_chr[i].val_handle, 0, cb_map, NULL);
        break;
    }
    case DS_CCCD: {
        while (s_ds_idx < s_nchr && !chr_wants_notify(&s_chr[s_ds_idx])) s_ds_idx++;
        if (s_ds_idx >= s_nchr) { s_ds = DS_DONE; disc_advance(); return; }
        uint8_t v[2] = { 1, 0 };
        rc = ble_gattc_write_flat(conn, s_chr[s_ds_idx].cccd_handle, v, 2, cb_cccd, NULL);
        break;
    }
    case DS_DONE: {
        int nsub = 0;
        for (int i = 0; i < s_nchr; i++) if (chr_wants_notify(&s_chr[i])) nsub++;
        if (!nsub) { disc_fail("NO INPUT REPORTS"); return; }
        /* the live GAP name beats the advertised one */
        if (s_live_name[0] && strcmp(s_live_name, s_peer.name)) {
            portENTER_CRITICAL(&s_mux);
            strncpy(s_peer.name, s_live_name, sizeof(s_peer.name) - 1);
            portEXIT_CRITICAL(&s_mux);
            peer_save();
        }
        s_setup_fail = 0;
        set_state(BLEH_CONNECTED);
        set_msg("CONNECTED: %s", s_peer.name[0] ? s_peer.name : "DEVICE");
        osd_log("BLE: %s CONNECTED (%d INPUT REPORTS)", s_peer.name[0] ? s_peer.name : "DEVICE", nsub);
        return;
    }
    default: return;
    }
    if (rc != 0) {
        ESP_LOGW(TAG, "discovery step %d rc=%d", s_ds, rc);
        disc_fail("GATT ERROR");
    }
}

static void start_discovery(void)
{
    s_ds = DS_NAME; s_ds_idx = 0;
    set_state(BLEH_DISCOVERING);
    disc_advance();
}

/* ---- pairing resolution ------------------------------------------------------------ */
static void became_peer(const struct ble_gap_conn_desc *desc)
{
    /* drop the previous peer (bond + record) if it is a different device */
    if (peer_known() && !peer_matches(&desc->peer_id_addr)) {
        ble_addr_t old = { .type = s_peer.addr_type };
        memcpy(old.val, s_peer.addr, 6);
        ble_store_util_delete_peer(&old);
    }
    portENTER_CRITICAL(&s_mux);
    s_peer.magic = PEER_MAGIC;
    s_peer.addr_type = desc->peer_id_addr.type;
    memcpy(s_peer.addr, desc->peer_id_addr.val, 6);
    strncpy(s_peer.name, s_target.name, sizeof(s_peer.name) - 1);
    s_peer.name[sizeof(s_peer.name) - 1] = 0;
    portEXIT_CRITICAL(&s_mux);
    peer_save();
    s_conn_is_pair_target = false;
    s_pairing = false; s_pair_result = 1;
    set_msg("PAIRED: %s", s_peer.name[0] ? s_peer.name : "DEVICE");
    osd_log("BLE: PAIRED %s", s_peer.name[0] ? s_peer.name : "DEVICE");
}

static void pair_failed(const char *why, int code)
{
    if (code) set_msg("%s (%d)", why, code); else set_msg("%s", why);
    s_conn_is_pair_target = false;
    s_pairing = false; s_pair_result = -1;
    set_state(BLEH_ERROR);
}

/* ---- GAP event dispatcher ---------------------------------------------------------- */
static int gap_event(struct ble_gap_event *ev, void *arg)
{
    (void)arg;
    switch (ev->type) {
    case BLE_GAP_EVENT_DISC:
        on_disc(&ev->disc);
        return 0;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        if (s_pairing && s_state == BLEH_PAIR_SCAN) {
            /* 60 s window closed with nothing chosen */
            pair_failed(s_ncand ? "PAIRING TIMED OUT" : "NO DEVICE FOUND", 0);
            start_reconnect();
        }
        return 0;

    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status != 0) {
            ESP_LOGW(TAG, "connect failed status=%d", ev->connect.status);
            if (ev->connect.status == BLE_HS_EAPP) {          /* our own ble_gap_conn_cancel() */
                s_conn_is_pair_target = false;
                resume_after_cancel();
            } else if (s_conn_is_pair_target) {
                pair_failed("CONNECT FAILED", ev->connect.status);
                start_reconnect();
            } else {
                start_reconnect();                            /* initiation timed out/failed: retry */
            }
            return 0;
        }
        {
            struct ble_gap_conn_desc desc;
            if (ble_gap_conn_find(ev->connect.conn_handle, &desc) != 0) return 0;
            if (s_conn != BLE_HS_CONN_HANDLE_NONE && s_conn != ev->connect.conn_handle) {
                /* a pairing target connected while the old peer is still up:
                 * the old link goes away (single-peer policy) */
                ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
            }
            s_conn = ev->connect.conn_handle;
            s_buttons = 0; s_nchr = 0; s_live_name[0] = 0;
            set_state(BLEH_SECURING);
            if (s_conn_is_pair_target) set_msg("PAIRING...");
            int rc = ble_gap_security_initiate(s_conn);
            if (rc != 0 && rc != BLE_HS_EALREADY) {
                ESP_LOGW(TAG, "security_initiate rc=%d", rc);
                ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
            }
        }
        return 0;

    case BLE_GAP_EVENT_ENC_CHANGE:
        if (ev->enc_change.conn_handle != s_conn) return 0;
        if (ev->enc_change.status == 0) {
            struct ble_gap_conn_desc desc;
            if (ble_gap_conn_find(s_conn, &desc) != 0) return 0;
            if (s_conn_is_pair_target) became_peer(&desc);
            start_discovery();
            return 0;
        }
        ESP_LOGW(TAG, "encryption failed status=0x%x", ev->enc_change.status);
        /* The remote side lost its copy of the bond (device was reset or
         * paired elsewhere): forget ours and pair afresh on this same link,
         * once. Works when the device accepts pairing from any central. */
        if (!s_retried_security) {
            struct ble_gap_conn_desc desc;
            s_retried_security = true;
            if (ble_gap_conn_find(s_conn, &desc) == 0) ble_store_util_delete_peer(&desc.peer_id_addr);
            set_msg("RE-PAIRING...");
            if (ble_gap_security_initiate(s_conn) == 0) return 0;
        }
        if (s_conn_is_pair_target) pair_failed("PAIRING FAILED", ev->enc_change.status);
        else { s_setup_fail++; set_msg("ENCRYPTION FAILED (0x%X)", ev->enc_change.status); }
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        if (ev->disconnect.conn.conn_handle == s_conn) {
            ESP_LOGI(TAG, "disconnected reason=0x%x", ev->disconnect.reason);
            s_conn = BLE_HS_CONN_HANDLE_NONE;
            s_buttons = 0; s_nchr = 0;
            if (s_conn_is_pair_target) pair_failed("DEVICE DISCONNECTED", ev->disconnect.reason);
            else if (s_state == BLEH_CONNECTED || s_state == BLEH_DISCOVERING || s_state == BLEH_SECURING)
                set_msg("DISCONNECTED (0x%X)", ev->disconnect.reason);
            start_reconnect();
        }
        return 0;

    case BLE_GAP_EVENT_NOTIFY_RX: {
        if (ev->notify_rx.conn_handle != s_conn) return 0;
        chr_t *c = NULL;
        for (int i = 0; i < s_nchr; i++)
            if (s_chr[i].val_handle == ev->notify_rx.attr_handle) { c = &s_chr[i]; break; }
        if (!c) return 0;
        uint8_t d[32]; uint16_t n = OS_MBUF_PKTLEN(ev->notify_rx.om);
        if (n > sizeof(d)) n = sizeof(d);
        os_mbuf_copydata(ev->notify_rx.om, 0, n, d);
        if (c->uuid16 == UUID_BOOT_KBD_IN || s_map.nf == 0) {
            /* boot keyboard layout, or no usable map: best effort */
            c->bits = (n >= 8) ? hid_decode_boot_kbd(d, n)
                    : (n >= 2) ? hid_map_consumer_usage((uint16_t)d[0] | ((uint16_t)d[1] << 8)) : 0;
        } else {
            c->bits = hid_decode_report(&s_map, c->rid, d, n);
        }
        buttons_recompute();
        return 0;
    }

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        /* peer wants to pair again though we hold a bond: let it */
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(ev->repeat_pairing.conn_handle, &desc) == 0)
            ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    case BLE_GAP_EVENT_PASSKEY_ACTION:
        /* NO_INPUT_OUTPUT: only numeric comparison can be asked for; accept */
        if (ev->passkey.params.action == BLE_SM_IOACT_NUMCMP) {
            struct ble_sm_io io = { .action = BLE_SM_IOACT_NUMCMP, .numcmp_accept = 1 };
            ble_sm_inject_io(ev->passkey.conn_handle, &io);
        }
        return 0;

    case BLE_GAP_EVENT_CONN_UPDATE_REQ:
        return 0;                      /* accept the peer's parameters */

    default:
        return 0;
    }
}

/* ---- host task + start ---------------------------------------------------------------- */
static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset, reason=%d", reason);
    s_ready = false;
    s_conn = BLE_HS_CONN_HANDLE_NONE; s_buttons = 0;
    set_state(BLEH_ERROR);
    set_msg("BLE HOST RESET (%d)", reason);
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc) ESP_LOGW(TAG, "ensure_addr rc=%d", rc);
    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc) { ESP_LOGW(TAG, "infer_auto rc=%d", rc); s_own_addr_type = BLE_OWN_ADDR_PUBLIC; }
    s_ready = true;
    peer_load();
    if (peer_known()) {
        char a[18]; addr_str(s_peer.addr, a, sizeof(a));
        osd_log("BLE: PAIRED DEVICE %s (%s)", s_peer.name[0] ? s_peer.name : "?", a);
        start_reconnect();
    } else {
        set_state(BLEH_IDLE);
        osd_log("BLE: READY, NO DEVICE PAIRED");
    }
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();                 /* returns on nimble_port_stop() */
    nimble_port_freertos_deinit();
}

void ble_hid_start(void)
{
    static bool started;
    if (started) return;
    started = true;

    size_t heap0 = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    int rc = nimble_port_init();
    if (rc != 0) {
        ESP_LOGE(TAG, "nimble_port_init rc=%d", rc);
        osd_log("BLE: INIT FAILED (%d)", rc);
        set_msg("BLE INIT FAILED (%d)", rc);
        return;
    }
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;   /* evict the oldest bond when full */
    /* Just Works, bonded, Secure Connections when the device has it */
    ble_hs_cfg.sm_io_cap  = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm    = 0;
    ble_hs_cfg.sm_sc      = 1;
    ble_hs_cfg.sm_our_key_dist   = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_device_name_set("A2FPGA");
    ble_store_config_init();
    nimble_port_freertos_init(host_task);

    vTaskDelay(pdMS_TO_TICKS(50));     /* let the controller settle for the heap figure */
    size_t heap1 = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    osd_log("BLE: HOST UP, INTERNAL HEAP %u -> %u", (unsigned)heap0, (unsigned)heap1);
    ESP_LOGI(TAG, "nimble up; internal heap %u -> %u (-%u)", (unsigned)heap0, (unsigned)heap1,
             (unsigned)(heap0 - heap1));
}

/* ---- menu-side API ------------------------------------------------------------------- */
void ble_hid_poll(void)
{
    if (!s_pairing || s_state != BLEH_PAIR_SCAN) return;
    /* auto-connect to the strongest candidate PAIR_AUTO_S after the first one showed up */
    int64_t now = esp_timer_get_time();
    int64_t first = 0; int best = -1; int best_rssi = -128;
    portENTER_CRITICAL(&s_mux);
    for (int i = 0; i < s_ncand; i++) {
        if (!first || s_cand[i].first_seen_us < first) first = s_cand[i].first_seen_us;
        if (s_cand[i].connectable && s_cand[i].rssi > best_rssi) { best_rssi = s_cand[i].rssi; best = i; }
    }
    portEXIT_CRITICAL(&s_mux);
    if (best >= 0 && now - first >= (int64_t)PAIR_AUTO_S * 1000000)
        ble_hid_pair_select(best);
}

bool            ble_hid_available(void) { return s_ready; }
ble_hid_state_t ble_hid_state(void)     { return s_state; }
bool            ble_hid_connected(void) { return s_state == BLEH_CONNECTED; }
uint16_t        ble_hid_buttons(void)   { return s_state == BLEH_CONNECTED ? s_buttons : 0; }
bool            ble_hid_pairing(void)   { return s_pairing; }
int             ble_hid_pair_result(void) { return s_pair_result; }
bool            ble_hid_peer_known(void) { return peer_known(); }
const char     *ble_hid_peer_name(void) { return peer_known() ? s_peer.name : ""; }

const char *ble_hid_state_str(void)
{
    switch (s_state) {
    case BLEH_OFF:         return "OFF";
    case BLEH_IDLE:        return "NO DEVICE";
    case BLEH_RECONNECT:   return "SEARCHING";
    case BLEH_PAIR_SCAN:   return "SCANNING";
    case BLEH_CONNECTING:  return "CONNECTING";
    case BLEH_SECURING:    return "PAIRING";
    case BLEH_DISCOVERING: return "SETTING UP";
    case BLEH_CONNECTED:   return "CONNECTED";
    case BLEH_ERROR:       return "ERROR";
    }
    return "?";
}

const char *ble_hid_message(void) { return s_msg; }

bool ble_hid_take_dirty(void)
{
    bool d = s_dirty;
    s_dirty = false;
    return d;
}

void ble_hid_peer_addr_str(char *out, int cap)
{
    if (!peer_known()) { snprintf(out, cap, "-"); return; }
    addr_str(s_peer.addr, out, cap);
}

void ble_hid_pair_begin(void)
{
    if (!s_ready) { set_msg("BLUETOOTH NOT READY"); return; }
    if (s_pairing) return;
    portENTER_CRITICAL(&s_mux);
    s_ncand = 0;
    portEXIT_CRITICAL(&s_mux);
    s_pair_t0_us = esp_timer_get_time();
    s_pair_result = 0;
    s_pairing = true;
    ble_gap_disc_cancel();            /* no-op unless a scan is running */
    if (ble_gap_conn_active()) {
        /* leave the RECONNECT initiation; the scan starts from its EAPP event */
        s_pair_pending = true;
        set_state(BLEH_PAIR_SCAN);
        set_msg("SCANNING - PUT DEVICE IN PAIRING MODE");
        ble_gap_conn_cancel();
        return;
    }
    start_pair_scan();
}

void ble_hid_pair_cancel(void)
{
    if (!s_pairing) return;
    s_pairing = false; s_pair_result = -1;
    set_msg("PAIRING CANCELLED");
    if (s_pair_pending) {
        s_pair_pending = false;           /* the pending cancel's EAPP resumes RECONNECT */
        return;
    }
    if (ble_gap_disc_active()) {
        ble_gap_disc_cancel();            /* synchronous */
        start_reconnect();
        return;
    }
    if (ble_gap_conn_active()) {
        ble_gap_conn_cancel();            /* EAPP -> resume_after_cancel -> RECONNECT */
        return;
    }
    if (s_conn_is_pair_target && s_conn != BLE_HS_CONN_HANDLE_NONE) {
        s_conn_is_pair_target = false;
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);   /* DISCONNECT -> reconnect */
        return;
    }
    s_conn_is_pair_target = false;
    start_reconnect();
}

int ble_hid_pair_auto_seconds(void)
{
    if (!s_pairing || s_state != BLEH_PAIR_SCAN) return -1;
    int64_t first = 0;
    portENTER_CRITICAL(&s_mux);
    for (int i = 0; i < s_ncand; i++)
        if (!first || s_cand[i].first_seen_us < first) first = s_cand[i].first_seen_us;
    portEXIT_CRITICAL(&s_mux);
    if (!first) return -1;
    int64_t left = (int64_t)PAIR_AUTO_S * 1000000 - (esp_timer_get_time() - first);
    return left > 0 ? (int)((left + 999999) / 1000000) : 0;
}

int ble_hid_candidates(void) { return s_ncand; }

bool ble_hid_candidate(int i, char *name, int ncap, char *addr, int acap, int *rssi)
{
    bool ok = false;
    portENTER_CRITICAL(&s_mux);
    if (i >= 0 && i < s_ncand) {
        const cand_t *c = &s_cand[i];
        if (name && ncap) snprintf(name, ncap, "%s", c->name[0] ? c->name : "(UNNAMED HID DEVICE)");
        if (addr && acap) addr_str(c->addr.val, addr, acap);
        if (rssi) *rssi = c->rssi;
        ok = true;
    }
    portEXIT_CRITICAL(&s_mux);
    return ok;
}

void ble_hid_pair_select(int i)
{
    if (!s_pairing || s_state != BLEH_PAIR_SCAN) return;
    cand_t c; bool ok = false;
    portENTER_CRITICAL(&s_mux);
    if (i < 0) {                       /* strongest */
        int best = -1, br = -128;
        for (int k = 0; k < s_ncand; k++)
            if (s_cand[k].connectable && s_cand[k].rssi > br) { br = s_cand[k].rssi; best = k; }
        i = best;
    }
    if (i >= 0 && i < s_ncand) { c = s_cand[i]; ok = true; }
    portEXIT_CRITICAL(&s_mux);
    if (!ok) return;
    ble_gap_disc_cancel();
    s_target = c;
    connect_to(&s_target);
}

void ble_hid_forget(void)
{
    if (!peer_known() && s_conn == BLE_HS_CONN_HANDLE_NONE) return;
    s_pairing = false; s_pair_pending = false; s_setup_fail = 0;
    if (ble_gap_disc_active()) ble_gap_disc_cancel();
    bool cancelling = ble_gap_conn_active();
    if (cancelling) ble_gap_conn_cancel();        /* EAPP -> resume_after_cancel -> IDLE */
    if (s_conn != BLE_HS_CONN_HANDLE_NONE)
        ble_gap_terminate(s_conn, BLE_ERR_REM_USER_CONN_TERM);   /* DISCONNECT -> IDLE */
    if (peer_known()) {
        ble_addr_t a = { .type = s_peer.addr_type };
        memcpy(a.val, s_peer.addr, 6);
        ble_store_util_delete_peer(&a);
    }
    portENTER_CRITICAL(&s_mux);
    memset(&s_peer, 0, sizeof(s_peer));
    portEXIT_CRITICAL(&s_mux);
    peer_save();
    (void)cancelling;
    set_state(s_ready ? BLEH_IDLE : BLEH_OFF);
    set_msg("DEVICE FORGOTTEN");
    osd_log("BLE: DEVICE FORGOTTEN");
}

/* ---- console ------------------------------------------------------------------------- */
void ble_hid_console(int argc, const char *const *argv, void (*out)(void *ctx, const char *line), void *ctx)
{
    char b[96];
    const char *sub = argc >= 2 ? argv[1] : "status";
    if (!strcmp(sub, "status")) {
        char a[18]; ble_hid_peer_addr_str(a, sizeof(a));
        snprintf(b, sizeof(b), "ble: %s%s  peer: %s %s", ble_hid_state_str(), s_ready ? "" : " (host not synced)",
                 peer_known() ? (s_peer.name[0] ? s_peer.name : "(unnamed)") : "none", a);
        out(ctx, b);
        snprintf(b, sizeof(b), "ble: buttons 0x%03X  last: %s", s_buttons, s_msg[0] ? s_msg : "-");
        out(ctx, b);
        if (s_state == BLEH_CONNECTED) {
            snprintf(b, sizeof(b), "ble: report map %u B, %u fields, %d input chrs, %u buttons",
                     s_rmap_len, s_map.nf, s_nchr, s_map.nbuttons);
            out(ctx, b);
        }
        return;
    }
    if (!strcmp(sub, "pair"))   { ble_hid_pair_begin();  out(ctx, s_msg); return; }
    if (!strcmp(sub, "cancel")) { ble_hid_pair_cancel(); out(ctx, s_msg); return; }
    if (!strcmp(sub, "forget")) { ble_hid_forget();      out(ctx, s_msg); return; }
    if (!strcmp(sub, "list")) {
        int n = ble_hid_candidates();
        if (!n) { out(ctx, s_pairing ? "ble: no HID advertisers seen yet" : "ble: not scanning (ble pair)"); return; }
        for (int i = 0; i < n; i++) {
            char nm[NAME_LEN], a[18]; int r;
            if (ble_hid_candidate(i, nm, sizeof(nm), a, sizeof(a), &r)) {
                snprintf(b, sizeof(b), "  %d: %-24s %s %4d dBm", i, nm, a, r);
                out(ctx, b);
            }
        }
        int s = ble_hid_pair_auto_seconds();
        if (s >= 0) { snprintf(b, sizeof(b), "ble: auto-connect to the strongest in %d s", s); out(ctx, b); }
        return;
    }
    if (!strcmp(sub, "connect")) {
        int i = argc >= 3 ? atoi(argv[2]) : -1;
        if (!s_pairing) { out(ctx, "ble: start with 'ble pair' first"); return; }
        ble_hid_pair_select(i);
        out(ctx, s_msg);
        return;
    }
    out(ctx, "ble [status|pair|cancel|list|connect <n>|forget]");
}

#else  /* !A2MEGA_HAS_OSPI_LINK: dp_test builds carry no menu/pad path */

void            ble_hid_start(void) {}
void            ble_hid_poll(void) {}
bool            ble_hid_available(void) { return false; }
ble_hid_state_t ble_hid_state(void) { return BLEH_OFF; }
const char     *ble_hid_state_str(void) { return "OFF"; }
const char     *ble_hid_message(void) { return ""; }
bool            ble_hid_take_dirty(void) { return false; }
bool            ble_hid_connected(void) { return false; }
uint16_t        ble_hid_buttons(void) { return 0; }
bool            ble_hid_peer_known(void) { return false; }
const char     *ble_hid_peer_name(void) { return ""; }
void            ble_hid_peer_addr_str(char *out, int cap) { if (cap) snprintf(out, cap, "-"); }
void            ble_hid_forget(void) {}
bool            ble_hid_pairing(void) { return false; }
int             ble_hid_pair_result(void) { return 0; }
void            ble_hid_pair_begin(void) {}
void            ble_hid_pair_cancel(void) {}
int             ble_hid_pair_auto_seconds(void) { return -1; }
int             ble_hid_candidates(void) { return 0; }
bool            ble_hid_candidate(int i, char *n, int nc, char *a, int ac, int *r)
{ (void)i; (void)n; (void)nc; (void)a; (void)ac; (void)r; return false; }
void            ble_hid_pair_select(int i) { (void)i; }
void            ble_hid_console(int argc, const char *const *argv, void (*out)(void *ctx, const char *line), void *ctx)
{ (void)argc; (void)argv; out(ctx, "ble: not built into this variant"); }

#endif
