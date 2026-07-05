/*
 * menu.c — see menu.h for the model. 40x24 Apple II text overlay renderer,
 * gamepad navigation, screens for status / disk images / slots / network /
 * firmware / settings, and a generic file picker (no text input anywhere).
 *
 * a2mega ESP32 port of the a2n20v2-Enhanced firmware_host/menu.c:
 *   - input comes from the FPGA pad readback regs (fpga_pad_poll) instead of
 *     the BL616's XInput host driver; button word is the A2PAD_* bitmask
 *   - no shoulder buttons in the readback regs, so the LB/RB +/-16 bigstep
 *     is dropped (hold-to-repeat covers the octet editor)
 *   - view switching is A2REG_VIDEO_ENABLE only (no TEXT_MODE register)
 *   - slots apply via the SELECT/CARD/RECONFIG register triplet (0x30-0x33)
 *   - storage is SD-only (no USB stick / boot-pref choice)
 *   - network is WiFi STA (read-only status via net_status.h); DHCP toggle
 *     and static IP editing kept from settings
 *   - MCU firmware update items removed (the ESP32 reflashes over its own
 *     USB-C); the Firmware screen keeps the FPGA core update flow
 */
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_system.h"

#include "fpga_link.h"
#include "fpga_screen.h"
#include "osd_console.h"
#include "settings.h"
#include "disk.h"
#include "fpgaupdate.h"
#include "net_status.h"
#include "menu.h"

static const char *TAG = "menu";

/* Button mapping by FUNCTION (A2PAD_* bits from the FPGA pad readback).
 * The FPGA-fabric usb_hid_host already normalizes the pad, so no
 * label-vs-position swap is needed here (the BL616 mapped by printed label
 * because 8BitDo pads report SNES positions over XInput). */
#define BTN_OK    A2PAD_A       /* activate / enter                */
#define BTN_BACK  A2PAD_B       /* back / leave submenu            */
#define BTN_VIEW  A2PAD_Y       /* menu <-> console                */
#define BTN_APPLE A2PAD_SELECT  /* Apple II <-> MCU view toggle    */

/* Gateware build stamp, indexed reg (write index, read ASCII digit). Not in
 * a2fpga_regs.h because older a2mega cores may not implement it — the reader
 * degrades to "(NO VERSION REG)" when the digits don't come back. */
#define A2REG_CORE_BUILD  0x3Fu

/* ---- display modes ------------------------------------------------------ */
typedef enum { VIEW_APPLE, VIEW_CONSOLE, VIEW_MENU } view_t;

static view_t s_view       = VIEW_APPLE;
static view_t s_mcu_view   = VIEW_MENU;    /* which MCU view SELECT returns to */

/* ---- item model ---------------------------------------------------------- */
typedef enum {
    MI_INFO,      /* label + value, not activatable                       */
    MI_SUBMENU,   /* A enters (action() pushes the screen)                */
    MI_ACTION,    /* A runs action()                                      */
    MI_CHOICE,    /* LEFT/RIGHT/A cycle: on_change(id, dir)               */
    MI_TOGGLE,    /* LEFT/RIGHT/A flip: on_change(id, dir)                */
} mi_type_t;

#define MENU_MAX_ITEMS 64
#define MENU_LABEL_LEN 38          /* full row when the value is empty */
#define MENU_VALUE_COL 26          /* label clip when a value is shown */
#define MENU_VALUE_LEN 12

typedef struct menu_item {
    mi_type_t type;
    char label[MENU_LABEL_LEN + 1];
    char value[MENU_VALUE_LEN + 1];
    void (*action)(int id);            /* SUBMENU / ACTION                */
    void (*on_change)(int id, int dir);/* CHOICE / TOGGLE                 */
    int  id;
} menu_item_t;

typedef struct menu_screen {
    const char *title;
    void (*build)(void);               /* regenerate items on entry/refresh */
} menu_screen_t;

static menu_item_t s_items[MENU_MAX_ITEMS];
static int         s_nitems;

/* navigation stack */
#define MENU_MAX_DEPTH 6
static const menu_screen_t *s_stack[MENU_MAX_DEPTH];
static int s_cursor[MENU_MAX_DEPTH];
static int s_scroll[MENU_MAX_DEPTH];
static int s_depth;

static char s_status[41];              /* one-line status (SAVED, etc.) */
static bool s_wait_remount;            /* auto-refresh when remount finishes */

/* item builder helpers */
static menu_item_t *mi_add(mi_type_t t, const char *label, const char *value)
{
    if (s_nitems >= MENU_MAX_ITEMS)
        return &s_items[MENU_MAX_ITEMS - 1];
    menu_item_t *m = &s_items[s_nitems++];
    memset(m, 0, sizeof(*m));
    m->type = t;
    snprintf(m->label, sizeof(m->label), "%s", label ? label : "");
    snprintf(m->value, sizeof(m->value), "%s", value ? value : "");
    return m;
}

static void set_status(const char *msg)
{
    snprintf(s_status, sizeof(s_status), "%s", msg ? msg : "");
}

/* ---- rendering ----------------------------------------------------------- */
/* Layout: row 0 title bar (inverse), rows 2..20 items (19 visible),
 * row 21 status, row 23 key hints (inverse). */
#define ROW_ITEMS_TOP   2
#define ROWS_ITEMS      19

static void put_row(int row, const char *text, bool inverse)
{
    char line[FPGA_SCREEN_W + 1];
    snprintf(line, sizeof(line), "%-40.40s", text ? text : "");
    fpga_screen_set_inverse(inverse);
    fpga_screen_goto(0, row);
    fpga_screen_puts(line);
    fpga_screen_set_inverse(false);
}

static void selectable_hint(const menu_item_t *m, char *out, int cap)
{
    switch (m->type) {
    case MI_SUBMENU: snprintf(out, cap, ">");  break;
    case MI_CHOICE:
    case MI_TOGGLE:  snprintf(out, cap, "%s", m->value); break;
    case MI_ACTION:  snprintf(out, cap, "*");  break;
    default:         snprintf(out, cap, "%s", m->value); break;
    }
}

static void paint(void)
{
    if (s_view != VIEW_MENU)
        return;

    const menu_screen_t *scr = s_stack[s_depth];
    int cur = s_cursor[s_depth];
    int top = s_scroll[s_depth];

    fpga_link_lock();                  /* keep the frame update atomic */
    fpga_screen_clear();

    char bar[41];
    snprintf(bar, sizeof(bar), " A2FPGA  %-31.31s", scr->title);
    put_row(0, bar, true);

    for (int i = 0; i < ROWS_ITEMS; i++) {
        int idx = top + i;
        if (idx >= s_nitems)
            break;
        const menu_item_t *m = &s_items[idx];
        char val[MENU_VALUE_LEN + 2];
        selectable_hint(m, val, sizeof(val));
        char line[41];
        if (val[0])
            snprintf(line, sizeof(line), " %-*.*s%*.*s ",
                     MENU_VALUE_COL, MENU_VALUE_COL, m->label,
                     40 - 2 - MENU_VALUE_COL, MENU_VALUE_LEN, val);
        else
            snprintf(line, sizeof(line), " %-38.38s ", m->label);
        put_row(ROW_ITEMS_TOP + i, line, idx == cur);
    }

    if (s_nitems > ROWS_ITEMS) {
        char pos[41];
        snprintf(pos, sizeof(pos), "%38s%s", "",
                 (top + ROWS_ITEMS < s_nitems) ? "+" : " ");
        put_row(21, s_status[0] ? s_status : pos, false);
    } else {
        put_row(21, s_status, false);
    }

    put_row(23, " A:OK B:BACK Y:CONSOLE SELECT:APPLE II ", true);

    fpga_reg_write(A2REG_VIDEO_ENABLE, 1);
    fpga_link_unlock();
}

/* ---- navigation ---------------------------------------------------------- */
static void screen_push(const menu_screen_t *scr)
{
    if (s_depth + 1 >= MENU_MAX_DEPTH)
        return;
    s_depth++;
    s_stack[s_depth]  = scr;
    s_cursor[s_depth] = 0;
    s_scroll[s_depth] = 0;
    set_status("");
    s_nitems = 0;
    scr->build();
}

static void screen_pop(void)
{
    if (s_depth == 0)
        return;
    s_depth--;
    set_status("");
    s_nitems = 0;
    s_stack[s_depth]->build();
}

static void screen_refresh(void)
{
    s_nitems = 0;
    s_stack[s_depth]->build();
    if (s_cursor[s_depth] >= s_nitems)
        s_cursor[s_depth] = s_nitems ? s_nitems - 1 : 0;
}

static bool item_selectable(const menu_item_t *m)
{
    return m->type != MI_INFO;
}

static void move_cursor(int dir)
{
    if (!s_nitems)
        return;
    int cur = s_cursor[s_depth];
    for (int step = 0; step < s_nitems; step++) {
        cur += dir;
        if (cur < 0) cur = s_nitems - 1;
        if (cur >= s_nitems) cur = 0;
        if (item_selectable(&s_items[cur]))
            break;
    }
    s_cursor[s_depth] = cur;
    /* keep in view */
    if (cur < s_scroll[s_depth])
        s_scroll[s_depth] = cur;
    if (cur >= s_scroll[s_depth] + ROWS_ITEMS)
        s_scroll[s_depth] = cur - ROWS_ITEMS + 1;
}

/* ---- settings save helper ------------------------------------------------ */
static void save_settings_status(void)
{
    set_status(settings_save() ? " SETTINGS SAVED" : " SAVE FAILED (RAM ONLY)");
}

/* ---- gateware build stamp ------------------------------------------------ */
/* Read the gateware build stamp via indexed reg 0x3F (write index, read
 * ASCII digit). Cores predating the register return zeros -> unknown. */
static bool fpga_core_version(char *out, size_t cap)
{
    char v[15];
    fpga_link_lock();
    for (int i = 0; i < 14; i++) {
        fpga_reg_write(A2REG_CORE_BUILD, (uint8_t)i);
        v[i] = (char)fpga_reg_read(A2REG_CORE_BUILD);
        if (v[i] < '0' || v[i] > '9') {
            fpga_link_unlock();
            return false;
        }
    }
    fpga_link_unlock();
    v[14] = 0;
    /* Same shape as the MCU's __DATE__ __TIME__ ("Jul  4 2026 17:59:43"). */
    static const char mon[12][4] = { "Jan", "Feb", "Mar", "Apr", "May",
                                     "Jun", "Jul", "Aug", "Sep", "Oct",
                                     "Nov", "Dec" };
    int m = (v[4] - '0') * 10 + (v[5] - '0');
    if (m < 1 || m > 12)
        return false;
    int d = (v[6] - '0') * 10 + (v[7] - '0');
    snprintf(out, cap, "%s %2d %.4s %.2s:%.2s:%.2s",
             mon[m - 1], d, v, v + 8, v + 10, v + 12);
    return true;
}

/* ======================= SCREEN: SLOTS ==================================== */
static const char *card_name(uint8_t id)
{
    switch (id) {
    case A2CARD_NONE:         return "EMPTY";
    case A2CARD_SUPERSPRITE:  return "SUPERSPRITE";
    case A2CARD_MOCKINGBOARD: return "MOCKINGBOARD";
    case A2CARD_SUPERSERIAL:  return "SUPER SERIAL";
    case A2CARD_DISK_II:      return "DISK II";
    case A2CARD_UTHERNET2:    return "UTHERNET II";
    case A2CARD_HDD:          return "PRODOS HDD";
    case 0xFF:                return "DEFAULT";
    default:                  return "?";
    }
}

/* cycle order for the per-slot choice */
static const uint8_t k_slot_choices[] = { 0xFF, 0, 1, 2, 3, 4, 5, 6 };
#define N_SLOT_CHOICES ((int)sizeof(k_slot_choices))

/* Effective card for a slot (DEFAULT resolves to the hardware map). */
static uint8_t slot_effective(int i)
{
    uint8_t c = settings()->slot_cards[i];
    return (c == 0xFF) ? settings_slot_hw_defaults[i] : c;
}

/* Live card in a slot, via the SELECT/STATUS register pair. */
static uint8_t slot_live_card(int i)
{
    fpga_link_lock();
    fpga_reg_write(A2REG_SLOT_SELECT, (uint8_t)i);
    uint8_t c = fpga_reg_read(A2REG_SLOT_STATUS);
    fpga_link_unlock();
    return c;
}

static void slots_change(int id, int dir)
{
    uint8_t *sc = &settings()->slot_cards[id];
    int idx = 0;
    for (int i = 0; i < N_SLOT_CHOICES; i++)
        if (k_slot_choices[i] == *sc)
            idx = i;
    idx = (idx + dir + N_SLOT_CHOICES) % N_SLOT_CHOICES;
    *sc = k_slot_choices[idx];

    /* A card id may only answer in ONE slot (the slotmaker decode cannot
     * duplicate it). If this slot now holds a real card that another slot
     * also resolves to, empty the other slot explicitly. */
    uint8_t eff = slot_effective(id);
    int moved_from = -1;
    if (eff != 0) {
        for (int i = 0; i < 8; i++) {
            if (i != id && slot_effective(i) == eff) {
                settings()->slot_cards[i] = 0;   /* explicit EMPTY */
                moved_from = i;
            }
        }
    }

    save_settings_status();
    if (moved_from >= 0) {
        char msg[41];
        snprintf(msg, sizeof(msg), " %s MOVED - SLOT %d NOW EMPTY",
                 card_name(eff), moved_from);
        set_status(msg);
    }
    screen_refresh();
}

static void slots_apply_now(int id)
{
    (void)id;
    fpga_link_lock();
    for (int i = 0; i < 8; i++) {
        uint8_t c = settings()->slot_cards[i];
        if (c == 0xFF)
            c = settings_slot_hw_defaults[i];
        fpga_reg_write(A2REG_SLOT_SELECT, (uint8_t)i);
        fpga_reg_write(A2REG_SLOT_CARD, c);
    }
    fpga_reg_write(A2REG_SLOT_RECONFIG, 1);
    fpga_link_unlock();
    ESP_LOGI(TAG, "slot map applied (reconfig strobe)");
    set_status(" APPLIED - REBOOT APPLE II");
    screen_refresh();
}

static void slots_restore_defaults(int id)
{
    (void)id;
    memset(settings()->slot_cards, 0xFF, sizeof(settings()->slot_cards));
    save_settings_status();
    slots_apply_now(0);   /* re-seed the hardware map + reconfig */
}

static void slots_build(void)
{
    for (int i = 0; i < 8; i++) {
        char label[MENU_LABEL_LEN + 1];
        uint8_t live = slot_live_card(i);
        uint8_t cfg  = settings()->slot_cards[i];
        snprintf(label, sizeof(label), "SLOT %d  (NOW:%s)", i, card_name(live));
        menu_item_t *m = mi_add(MI_CHOICE, label, card_name(cfg));
        m->on_change = slots_change;
        m->id = i;
    }
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "APPLY NOW (RECONFIG)", "");
    m->action = slots_apply_now;
    m = mi_add(MI_ACTION, "RESTORE HW DEFAULTS", "");
    m->action = slots_restore_defaults;
    mi_add(MI_INFO, "SAVED MAP APPLIES AT BOOT", "");
}

static const menu_screen_t SCR_SLOTS = { "SLOT ASSIGNMENTS", slots_build };

/* ======================= SCREEN: FILE PICKER ============================== */
/* Generic list-of-files picker: fills a target settings name field. */
static disk_list_ent_t s_pick_ents[DISK_LIST_MAX];
static int   s_pick_count;
static bool  s_pick_fpga;                      /* FPGA bitstream picker mode */
static char  s_pick_path[SETTINGS_NAME_LEN];   /* current subdir ("" = root) */
static char *s_pick_target;            /* settings field to write */
static const char *const *s_pick_exts; /* NULL-terminated extension list */
static uint8_t s_pick_eject_bit;       /* eject_mask bit for this volume */

/* Load (or reload) the current picker directory via the disk task. */
static void picker_load(void)
{
    s_pick_count = 0;
    disk_list_begin(s_pick_path, s_pick_exts);
    for (int waited = 0; waited < 2000; waited += 20) {
        int n = disk_list_poll(s_pick_ents, DISK_LIST_MAX);
        if (n >= 0) {
            s_pick_count = n;
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

static void picker_choose(int id)
{
    if (id == -3) {                            /* UP: parent directory */
        char *slash = strrchr(s_pick_path, '/');
        if (slash)
            *slash = '\0';
        else
            s_pick_path[0] = '\0';
        picker_load();
        s_cursor[s_depth] = 0;
        s_scroll[s_depth] = 0;
        screen_refresh();
        return;
    }
    if (id >= 0 && s_pick_ents[id].is_dir) {   /* descend into subdirectory */
        size_t plen = strlen(s_pick_path);
        size_t nlen = strlen(s_pick_ents[id].name);
        if (plen + (plen ? 1 : 0) + nlen >= sizeof(s_pick_path)) {
            set_status(" PATH TOO LONG");
            return;
        }
        if (plen)
            s_pick_path[plen++] = '/';
        memcpy(s_pick_path + plen, s_pick_ents[id].name, nlen + 1);
        picker_load();
        s_cursor[s_depth] = 0;
        s_scroll[s_depth] = 0;
        screen_refresh();
        return;
    }

    if (s_pick_fpga) {                         /* update file selected */
        char full[SETTINGS_NAME_LEN];
        int n;
        if (s_pick_path[0])
            n = snprintf(full, sizeof(full), "%s/%s",
                         s_pick_path, s_pick_ents[id].name);
        else
            n = snprintf(full, sizeof(full), "%s", s_pick_ents[id].name);
        if (n >= (int)sizeof(full)) {
            set_status(" PATH TOO LONG");
            return;
        }
        fpgaupdate_request(full);
        screen_pop();                          /* back to the update screen */
        return;
    }

    if (id == -2) {                            /* EJECT: leave unmounted */
        settings()->eject_mask |= s_pick_eject_bit;
    } else if (id == -1) {                     /* AUTO: built-in names */
        s_pick_target[0] = '\0';
        settings()->eject_mask &= (uint8_t)~s_pick_eject_bit;
    } else {
        /* full path: subdir/name (must fit the settings field) */
        int n;
        if (s_pick_path[0])
            n = snprintf(s_pick_target, SETTINGS_NAME_LEN, "%s/%s",
                         s_pick_path, s_pick_ents[id].name);
        else
            n = snprintf(s_pick_target, SETTINGS_NAME_LEN, "%s",
                         s_pick_ents[id].name);
        if (n >= SETTINGS_NAME_LEN) {
            s_pick_target[0] = '\0';
            set_status(" PATH TOO LONG");
            return;
        }
        settings()->eject_mask &= (uint8_t)~s_pick_eject_bit;
    }
    save_settings_status();
    disk_request_remount();
    s_wait_remount = true;                     /* refresh when it lands */
    screen_pop();
}

static void picker_build(void)
{
    menu_item_t *m;
    if (s_pick_path[0]) {
        char cur[MENU_LABEL_LEN + 1];
        snprintf(cur, sizeof(cur), "DIR: /%s", s_pick_path);
        mi_add(MI_INFO, cur, "");
        m = mi_add(MI_ACTION, "(UP ONE DIRECTORY)", "");
        m->action = picker_choose;
        m->id = -3;
    } else if (!s_pick_fpga) {
        m = mi_add(MI_ACTION, "(AUTO - BUILT-IN NAMES)", "");
        m->action = picker_choose;
        m->id = -1;
        m = mi_add(MI_ACTION, "(EJECT - NO IMAGE)", "");
        m->action = picker_choose;
        m->id = -2;
    }
    for (int i = 0; i < s_pick_count; i++) {
        if (s_pick_ents[i].is_dir) {
            char label[MENU_LABEL_LEN + 1];
            snprintf(label, sizeof(label), "%s/", s_pick_ents[i].name);
            m = mi_add(MI_SUBMENU, label, "");
        } else {
            m = mi_add(MI_ACTION, s_pick_ents[i].name, "");
        }
        m->action = picker_choose;
        m->id = i;
    }
    if (!s_pick_count)
        mi_add(MI_INFO, "NO MATCHING IMAGES OR FOLDERS", "");
}

static const menu_screen_t SCR_PICKER = { "CHOOSE IMAGE", picker_build };

static void picker_open(char *target, const char *const *exts,
                        uint8_t eject_bit)
{
    s_pick_fpga      = false;
    s_pick_target    = target;
    s_pick_exts      = exts;
    s_pick_eject_bit = eject_bit;
    s_pick_path[0]   = '\0';   /* start at the volume root */
    /* The filesystem scan runs in the disk task (the pad is idle for the
     * few ms we block here). */
    picker_load();
    screen_push(&SCR_PICKER);
}

/* ======================= SCREEN: DISK IMAGES ============================== */
static const char *const k_floppy_exts[] = { "dsk", "do", "po", "2mg", "nib", NULL };
static const char *const k_hdd_exts[]    = { "hdv", "po", "2mg", NULL };

static void disks_pick(int id)
{
    if (id < 2)
        picker_open(settings()->disk_img[id], k_floppy_exts,
                    (uint8_t)(1u << id));
    else
        picker_open(settings()->hdd_img[id - 2], k_hdd_exts,
                    (uint8_t)(1u << (4 + id - 2)));
}

static void disks_rescan(int id)
{
    (void)id;
    disk_request_remount();
    s_wait_remount = true;
    set_status(" RESCANNING...");
}

static void disks_build(void)
{
    disk_info_t di;
    for (int v = 0; v < 2; v++) {
        disk_get_floppy_info(v, &di);
        char label[MENU_LABEL_LEN + 1];
        snprintf(label, sizeof(label), "D%d %s", v + 1,
                 di.mounted ? di.name :
                 (settings()->eject_mask & (1u << v)) ? "(EJECTED)"
                                                      : "(NO IMAGE FOUND)");
        menu_item_t *m = mi_add(MI_SUBMENU, label, di.mounted ? di.detail : "");
        m->action = disks_pick;
        m->id = v;
    }
    for (int u = 0; u < 2; u++) {
        disk_get_hdd_info(u, &di);
        char label[MENU_LABEL_LEN + 1];
        snprintf(label, sizeof(label), "HD%d %s", u + 1,
                 di.mounted ? di.name :
                 (settings()->eject_mask & (1u << (4 + u))) ? "(EJECTED)"
                                                            : "(NO IMAGE FOUND)");
        menu_item_t *m = mi_add(MI_SUBMENU, label, di.mounted ? di.detail : "");
        m->action = disks_pick;
        m->id = 2 + u;
    }
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "RESCAN / REMOUNT ALL", "");
    m->action = disks_rescan;
    mi_add(MI_INFO, "SELECT A DRIVE TO CHANGE ITS IMAGE", "");
}

static const menu_screen_t SCR_DISKS = { "DISK IMAGES", disks_build };

/* ======================= SCREEN: IP OCTET EDITOR ========================== */
/* Edits one 4-octet address in the settings with LEFT/RIGHT (+/-1, hold to
 * repeat). No text input needed. (The BL616's LB/RB +/-16 bigstep is gone:
 * the pad readback regs carry no shoulder buttons.) */
static uint8_t    *s_octets;           /* points at settings field [4] */
static const char *s_octets_name;

static void octet_change(int id, int dir)
{
    s_octets[id] = (uint8_t)(s_octets[id] + dir);
    save_settings_status();
    screen_refresh();
}

static void octets_build(void)
{
    for (int i = 0; i < 4; i++) {
        char label[MENU_LABEL_LEN + 1], val[8];
        snprintf(label, sizeof(label), "%s OCTET %d", s_octets_name, i + 1);
        snprintf(val, sizeof(val), "%d", s_octets[i]);
        menu_item_t *m = mi_add(MI_CHOICE, label, val);
        m->on_change = octet_change;
        m->id = i;
    }
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "LEFT/RIGHT: +/-1 (HOLD TO REPEAT)", "");
}

static const menu_screen_t SCR_OCTETS = { "EDIT ADDRESS", octets_build };

static void octets_open(uint8_t *field, const char *name)
{
    s_octets      = field;
    s_octets_name = name;
    screen_push(&SCR_OCTETS);
}

/* ======================= SCREEN: NETWORK ================================== */
static void net_change(int id, int dir)
{
    (void)id; (void)dir;
    settings()->dhcp_enable = !settings()->dhcp_enable;
    save_settings_status();
    screen_refresh();
}

static void net_edit(int id)
{
    switch (id) {
    case 0: octets_open(settings()->static_ip,   "IP");      break;
    case 1: octets_open(settings()->static_mask, "NETMASK"); break;
    case 2: octets_open(settings()->static_gw,   "GATEWAY"); break;
    }
}

static void net_apply(int id)
{
    (void)id;
    menu_hook_net_apply();
    set_status(" APPLIED TO WIFI INTERFACE");
    screen_refresh();
}

static void fmt_ip(char *out, int cap, const uint8_t ip[4])
{
    snprintf(out, cap, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}

static void net_build(void)
{
    a2_settings_t *st = settings();

    /* WiFi STA status (read-only; SSID/password come from wifi.txt / CLI) */
    mi_add(MI_INFO, "WIFI", net_connected() ? "CONNECTED" : "OFFLINE");
    {
        const char *ssid = net_ssid();
        char l[MENU_LABEL_LEN + 1];
        snprintf(l, sizeof(l), "SSID: %s",
                 (ssid && ssid[0]) ? ssid : "(NOT SET)");
        mi_add(MI_INFO, l, "");
    }
    {
        uint32_t ip = net_ip();
        char v[MENU_VALUE_LEN + 4];
        snprintf(v, sizeof(v), "%u.%u.%u.%u",
                 (unsigned)(ip & 0xFF), (unsigned)((ip >> 8) & 0xFF),
                 (unsigned)((ip >> 16) & 0xFF), (unsigned)((ip >> 24) & 0xFF));
        mi_add(MI_INFO, "IP ADDRESS", (net_connected() && ip) ? v : "-");
    }
    mi_add(MI_INFO, "", "");

    menu_item_t *m = mi_add(MI_TOGGLE, "DHCP", st->dhcp_enable ? "ON" : "OFF");
    m->on_change = net_change;

    if (!st->dhcp_enable) {
        char v[16];
        fmt_ip(v, sizeof(v), st->static_ip);
        m = mi_add(MI_SUBMENU, "STATIC IP", v);
        m->action = net_edit; m->id = 0;
        fmt_ip(v, sizeof(v), st->static_mask);
        m = mi_add(MI_SUBMENU, "NETMASK", v);
        m->action = net_edit; m->id = 1;
        fmt_ip(v, sizeof(v), st->static_gw);
        m = mi_add(MI_SUBMENU, "GATEWAY", v);
        m->action = net_edit; m->id = 2;
    }
    m = mi_add(MI_ACTION, "APPLY NOW", "");
    m->action = net_apply;
    mi_add(MI_INFO, "(ALSO APPLIES AT NEXT BOOT)", "");
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "SET SSID/PASSWORD VIA THE FILE", "");
    mi_add(MI_INFO, "/SDCARD/A2FPGA/WIFI.TXT OR THE", "");
    mi_add(MI_INFO, "SERIAL CLI ON THE USB-C PORT.", "");
}

static const menu_screen_t SCR_NETWORK = { "NETWORK", net_build };

/* ======================= SCREEN: SYSTEM STATUS ============================ */
static void status_refresh(int id)
{
    (void)id;
    screen_refresh();
}

static void status_build(void)
{
    uint8_t st = fpga_reg_read(A2REG_STATUS);
    mi_add(MI_INFO, "FPGA LINK", fpga_link_ok() ? "OK" : "DOWN");
    mi_add(MI_INFO, "FPGA READY", (st & A2STAT_READY) ? "YES" : "NO");
    mi_add(MI_INFO, "DDR3 CALIBRATED", (st & A2STAT_DDR3_READY) ? "YES" : "NO");
    mi_add(MI_INFO, "APPLE II",
           (st & A2STAT_A2_RESET_N) ? "RUNNING" : "IN RESET");
    {
        fpga_pad_state_t pad;
        fpga_pad_poll(&pad);
        mi_add(MI_INFO, "GAMEPAD",
               !pad.present ? "NONE" : pad.is_pad ? "PRESENT" : "OTHER HID");
    }
    mi_add(MI_INFO, "WIFI", net_connected() ? "CONNECTED" : "OFFLINE");
    mi_add(MI_INFO, "", "");

    disk_info_t di;
    static const char *const drv_names[4] = { "D1", "D2", "HD1", "HD2" };
    for (int i = 0; i < 4; i++) {
        if (i < 2) disk_get_floppy_info(i, &di);
        else       disk_get_hdd_info(i - 2, &di);
        char label[MENU_LABEL_LEN + 1];
        snprintf(label, sizeof(label), "%-3s %s", drv_names[i],
                 di.mounted ? di.name : "(NOT MOUNTED)");
        mi_add(MI_INFO, label, di.mounted ? di.detail : "");
    }
    mi_add(MI_INFO, "", "");

    {
        char b[MENU_LABEL_LEN + 1];
        snprintf(b, sizeof(b), "MCU  %s %s", __DATE__, __TIME__);
        mi_add(MI_INFO, b, "");
        char ver[24];
        if (fpga_core_version(ver, sizeof(ver)))
            snprintf(b, sizeof(b), "CORE %s", ver);
        else
            snprintf(b, sizeof(b), "CORE (NO VERSION REG)");
        mi_add(MI_INFO, b, "");
    }
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "REFRESH", "");
    m->action = status_refresh;
}

static const menu_screen_t SCR_STATUS = { "SYSTEM STATUS", status_build };

/* ======================= SCREEN: FIRMWARE ================================= */
/* FPGA core update (fpgaupdate state machine). MCU update items from the
 * BL616 menu are gone: the ESP32 reflashes over its own USB-C port. */
/* .bin only: the build's .fs is the 20MB ASCII bitstream (rejected by the
 * updater's size cap anyway); impl/pnr/a2mega.bin is the flashable binary. */
static const char *const k_fpga_exts[] = { "bin", NULL };

static void fpga_pick(int id)
{
    (void)id;
    s_pick_fpga      = true;
    s_pick_target    = NULL;
    s_pick_exts      = k_fpga_exts;
    s_pick_eject_bit = 0;
    s_pick_path[0]   = '\0';
    picker_load();
    screen_push(&SCR_PICKER);
}

static bool s_fw_installing;   /* freeze the UI: the install page owns it */

static void fpga_install(int id)
{
    (void)id;
    /* Paint a dedicated page and freeze the UI on it: the SCREEN ITSELF dies
     * during the install (the running bitstream is erased before the config
     * flash becomes writable), so this page is the last thing visible. */
    s_fw_installing = true;
    ESP_LOGW(TAG, "FPGA core install committed");
    fpga_link_lock();
    fpga_screen_clear();
    put_row(0,  "           UPDATING FPGA CORE           ", true);
    put_row(4,  "  THE SCREEN WILL GO COMPLETELY DARK    ", false);
    put_row(5,  "  FOR ONE TO TWO MINUTES WHILE THE      ", false);
    put_row(6,  "  NEW CORE IS WRITTEN. THIS IS NORMAL.  ", false);
    put_row(9,  "  THE BOARD THEN RESTARTS BY ITSELF     ", false);
    put_row(10, "  INTO THE NEW CORE.                    ", false);
    put_row(13, "  IF NOTHING APPEARS AFTER THREE        ", false);
    put_row(14, "  MINUTES, POWER OFF AND ON. IF STILL   ", false);
    put_row(15, "  DARK, RE-FLASH THE FPGA FROM A PC     ", false);
    put_row(16, "  (SEE THE BOARD README).               ", false);
    put_row(23, "            DO NOT POWER OFF            ", true);
    fpga_reg_write(A2REG_VIDEO_ENABLE, 1);
    fpga_link_unlock();
    fpgaupdate_commit();   /* the disk task takes it from here */
}

static void fpga_cancel(int id)
{
    (void)id;
    fpgaupdate_cancel();
    screen_refresh();
}

static void firmware_build(void)
{
    menu_item_t *m;
    {
        char b[MENU_LABEL_LEN + 1];
        snprintf(b, sizeof(b), "MCU: %s %s", __DATE__, __TIME__);
        mi_add(MI_INFO, b, "");
        char ver[24];
        if (fpga_core_version(ver, sizeof(ver)))
            snprintf(b, sizeof(b), "CORE: %s", ver);
        else
            snprintf(b, sizeof(b), "CORE: (NO VERSION REG)");
        mi_add(MI_INFO, b, "");
    }
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "MCU UPDATES: REFLASH THE ESP32 OVER", "");
    mi_add(MI_INFO, "ITS OWN USB-C PORT (NO SD UPDATE).", "");
    mi_add(MI_INFO, "", "");

    switch (fpgaupdate_state()) {
    case FPU_IDLE:
        m = mi_add(MI_ACTION, "UPDATE FPGA (.FS/.BIN)", "");
        m->action = fpga_pick;
        break;
    case FPU_CHECKING:
        mi_add(MI_INFO, fpgaupdate_message(), "");
        break;
    case FPU_READY:
        mi_add(MI_INFO, fpgaupdate_message(), "");
        mi_add(MI_INFO, "", "");
        m = mi_add(MI_ACTION, "INSTALL NOW", "");
        m->action = fpga_install;
        m = mi_add(MI_ACTION, "CANCEL", "");
        m->action = fpga_cancel;
        break;
    case FPU_ERROR:
        mi_add(MI_INFO, fpgaupdate_message(), "");
        m = mi_add(MI_ACTION, "UPDATE FPGA (.FS/.BIN)", "");
        m->action = fpga_pick;
        break;
    default:
        mi_add(MI_INFO, "INSTALLING...", "");
        break;
    }
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "PICK A CORE FILE ON THE SD CARD.", "");
    mi_add(MI_INFO, "THE FILE IS VERIFIED BEFORE ANYTHING", "");
    mi_add(MI_INFO, "IS ERASED. INSTALL BLANKS THE SCREEN", "");
    mi_add(MI_INFO, "FOR 1-2 MINUTES - DO NOT POWER OFF.", "");
}

static const menu_screen_t SCR_FIRMWARE = { "FIRMWARE", firmware_build };

/* ======================= SCREEN: SETTINGS ================================= */
static void settings_do_reset(int id)
{
    (void)id;
    settings_reset_defaults();
    save_settings_status();
    screen_refresh();
}

static void settings_build(void)
{
    mi_add(MI_INFO, "STORAGE", "SD CARD");
    mi_add(MI_INFO, "IMAGES LIVE ON THE MICRO-SD CARD", "");
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "RESCAN / REMOUNT ALL", "");
    m->action = disks_rescan;
    m = mi_add(MI_ACTION, "RESET SETTINGS TO DEFAULTS", "");
    m->action = settings_do_reset;
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "SETTINGS SOURCE",
           settings_loaded_from_flash() ? "SAVED" : "DEFAULTS");
    {
        char dbg[41];
        settings_debug_line(dbg, sizeof(dbg));
        mi_add(MI_INFO, dbg, "");
    }
}

static const menu_screen_t SCR_SETTINGS = { "SETTINGS", settings_build };

/* ======================= SCREEN: ROOT ===================================== */
static void root_enter(int id)
{
    switch (id) {
    case 0: screen_push(&SCR_STATUS);   break;
    case 1: screen_push(&SCR_DISKS);    break;
    case 2: screen_push(&SCR_SLOTS);    break;
    case 3: screen_push(&SCR_NETWORK);  break;
    case 4: screen_push(&SCR_FIRMWARE); break;
    case 5: screen_push(&SCR_SETTINGS); break;
    }
}

static void root_restart_mcu(int id)
{
    (void)id;
    ESP_LOGW(TAG, "user-requested ESP32 restart");
    fpga_link_lock();
    fpga_screen_clear();
    put_row(0,  "             RESTART ESP32              ", true);
    put_row(8,  "            RESTARTING...               ", false);
    fpga_reg_write(A2REG_VIDEO_ENABLE, 1);
    fpga_link_unlock();
    vTaskDelay(pdMS_TO_TICKS(100));   /* let the frame land */
    esp_restart();
}

static void root_build(void)
{
    static const char *const entries[] = {
        "SYSTEM STATUS", "DISK IMAGES", "SLOT ASSIGNMENTS", "NETWORK",
        "FIRMWARE", "SETTINGS"
    };
    for (int i = 0; i < 6; i++) {
        menu_item_t *m = mi_add(MI_SUBMENU, entries[i], "");
        m->action = root_enter;
        m->id = i;
    }
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "RESTART ESP32", "");
    m->action = root_restart_mcu;
    mi_add(MI_INFO, "", "");
    {
        char b[MENU_LABEL_LEN + 1];
        snprintf(b, sizeof(b), "MCU  %s %s", __DATE__, __TIME__);
        mi_add(MI_INFO, b, "");
        char ver[24];
        if (fpga_core_version(ver, sizeof(ver)))
            snprintf(b, sizeof(b), "CORE %s", ver);
        else
            snprintf(b, sizeof(b), "CORE (NO VERSION REG)");
        mi_add(MI_INFO, b, "");
    }
}

static const menu_screen_t SCR_ROOT = { "MAIN MENU", root_build };

/* ---- view switching ------------------------------------------------------ */
static void enter_view(view_t v)
{
    s_view = v;
    switch (v) {
    case VIEW_APPLE:
        osd_console_set_lockout(false);
        osd_console_hide();               /* writes VIDEO_ENABLE = 0 */
        break;
    case VIEW_CONSOLE:
        s_mcu_view = VIEW_CONSOLE;
        osd_console_set_lockout(false);
        osd_console_show();               /* writes VIDEO_ENABLE = 1 */
        break;
    case VIEW_MENU:
        s_mcu_view = VIEW_MENU;
        /* buffer logs while the menu owns the screen */
        osd_console_set_lockout(true);
        screen_refresh();
        paint();                          /* writes VIDEO_ENABLE = 1 */
        break;
    }
}

bool menu_mcu_view_active(void)
{
    return s_view != VIEW_APPLE;
}

/* ---- input: edges + hold repeat ------------------------------------------ */
#define REPEAT_DELAY_US  400000
#define REPEAT_RATE_US   120000

static uint16_t s_prev_buttons;
static uint16_t s_held_dir;            /* dpad button currently repeating */
static int64_t  s_next_repeat_us;

static void handle_button(uint16_t btn)
{
    /* global: SELECT toggles Apple II <-> MCU */
    if (btn == BTN_APPLE) {
        if (s_view == VIEW_APPLE)
            enter_view(s_mcu_view);
        else
            enter_view(VIEW_APPLE);
        return;
    }
    if (s_view == VIEW_APPLE)
        return;                        /* pad belongs to the Apple II side */

    /* MCU view: Y switches console <-> menu */
    if (btn == BTN_VIEW) {
        enter_view(s_view == VIEW_MENU ? VIEW_CONSOLE : VIEW_MENU);
        return;
    }
    if (s_view != VIEW_MENU)
        return;                        /* console view: only Y/SELECT act */

    menu_item_t *m = s_nitems ? &s_items[s_cursor[s_depth]] : NULL;
    bool chg = m && (m->type == MI_CHOICE || m->type == MI_TOGGLE) &&
               m->on_change;

    switch (btn) {
    case A2PAD_U:  move_cursor(-1); break;
    case A2PAD_D:  move_cursor(1);  break;
    case A2PAD_L:  if (chg) m->on_change(m->id, -1);  break;
    case A2PAD_R:  if (chg) m->on_change(m->id, 1);   break;
    case BTN_OK:
        if (!m)
            break;
        if (chg)
            m->on_change(m->id, 1);
        else if ((m->type == MI_ACTION || m->type == MI_SUBMENU) && m->action)
            m->action(m->id);
        break;
    case BTN_BACK:
        if (s_stack[s_depth] == &SCR_PICKER && s_pick_path[0]) {
            picker_choose(-3);         /* in a subdirectory: go up first */
        } else if (s_depth > 0) {
            screen_pop();
        } else {
            enter_view(VIEW_APPLE);
        }
        break;
    default:
        return;                        /* nothing menu-relevant changed */
    }
    paint();
}

void menu_input(uint16_t buttons)
{
    if (s_fw_installing)
        return;   /* install page owns the screen until the core reloads */

    uint16_t pressed = buttons & (uint16_t)~s_prev_buttons;
    s_prev_buttons = buttons;

    /* one event per rising edge, in a stable priority order */
    static const uint16_t order[] = {
        BTN_APPLE, BTN_VIEW, BTN_BACK, BTN_OK,
        A2PAD_U, A2PAD_D, A2PAD_L, A2PAD_R,
    };
    for (unsigned i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
        if (pressed & order[i]) {
            handle_button(order[i]);
            if (order[i] & (A2PAD_U | A2PAD_D | A2PAD_L | A2PAD_R)) {
                s_held_dir = order[i];
                s_next_repeat_us = esp_timer_get_time() + REPEAT_DELAY_US;
            }
        }
    }

    /* FPGA update progress: keep the update screen live */
    if (s_view == VIEW_MENU && s_stack[s_depth] == &SCR_FIRMWARE &&
        fpgaupdate_dirty() && !s_fw_installing) {
        screen_refresh();
        paint();
    }

    /* a requested rescan finished: refresh the visible screen */
    if (s_wait_remount && !disk_remount_pending()) {
        s_wait_remount = false;
        if (s_view == VIEW_MENU) {
            set_status(" REMOUNT COMPLETE");
            screen_refresh();
            paint();
        }
    }

    /* hold-repeat for the d-pad while in the menu view */
    if (s_view == VIEW_MENU && s_held_dir && (buttons & s_held_dir)) {
        int64_t now = esp_timer_get_time();
        if (now - s_next_repeat_us >= 0) {
            handle_button(s_held_dir);
            s_next_repeat_us = now + REPEAT_RATE_US;
        }
    } else if (!(buttons & s_held_dir)) {
        s_held_dir = 0;
    }
}

void menu_tick(void)
{
    fpga_pad_state_t pad;
    fpga_pad_poll(&pad);
    /* Feed 0 when no gamepad is attached so releases are seen and held
     * state clears; edge detection makes an unchanged word a no-op. */
    menu_input((pad.present && pad.is_pad) ? pad.buttons : 0);
}

void menu_init(void)
{
    s_depth = 0;
    s_stack[0]  = &SCR_ROOT;
    s_cursor[0] = 0;
    s_scroll[0] = 0;
    s_nitems = 0;
    SCR_ROOT.build();
    ESP_LOGI(TAG, "menu initialized (root screen built)");
}
