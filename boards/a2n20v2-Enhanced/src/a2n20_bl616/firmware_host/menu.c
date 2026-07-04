/*
 * menu.c — see menu.h for the model. 40x24 Apple II text page renderer,
 * gamepad navigation, screens for slots / disk images / storage / network /
 * USB device tree, and a generic file picker (no text input anywhere).
 */
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "fpga_spi.h"
#include "fpga_screen.h"
#include "bflb_mtimer.h"
#include "usbh_core.h"

#include "usbh_xinput.h"
#include "osd_console.h"
#include "settings.h"
#include "disk.h"
#include "fwupdate.h"
#include "menu.h"

/* Button mapping by PAD LABEL: the 8BitDo SN30-style pads (our reference
 * controller) use SNES button positions, so the button PRINTED "A" reports as
 * XInput B, "B" as A, and "X"/"Y" likewise swapped. The on-screen hints show
 * printed labels, so map by label here. If an Xbox-layout pad shows reversed
 * buttons, this becomes a settings toggle (NINTENDO/XBOX labels). */
#define BTN_OK    XINPUT_B     /* labelled "A" */
#define BTN_BACK  XINPUT_A     /* labelled "B" */
#define BTN_VIEW  XINPUT_X     /* labelled "Y" */
#define BTN_BIGUP   XINPUT_RB  /* +16 on numeric choices */
#define BTN_BIGDOWN XINPUT_LB  /* -16 on numeric choices */

/* FPGA video takeover registers (same as osd_console) */
#define REG_VIDEO_ENABLE  0x10u
#define REG_TEXT_MODE     0x11u
/* Slot config registers */
#define REG_SLOT_BASE     0x60u
#define REG_SLOT_RECONFIG 0x6Bu

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

    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
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

/* ======================= SCREEN: SLOTS ==================================== */
static const char *card_name(uint8_t id)
{
    switch (id) {
    case 0:    return "EMPTY";
    case 1:    return "SUPERSPRITE";
    case 2:    return "MOCKINGBOARD";
    case 3:    return "SUPER SERIAL";
    case 4:    return "DISK II";
    case 5:    return "UTHERNET II";
    case 6:    return "PRODOS HDD";
    case 0xFF: return "DEFAULT";
    default:   return "?";
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
    for (int i = 0; i < 8; i++) {
        uint8_t c = settings()->slot_cards[i];
        if (c == 0xFF)
            c = settings_slot_hw_defaults[i];
        fpga_spi_reg_write((uint8_t)(REG_SLOT_BASE + i), c);
    }
    fpga_spi_reg_write(REG_SLOT_RECONFIG, 1);
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
        uint8_t live = fpga_spi_reg_read((uint8_t)(REG_SLOT_BASE + i));
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
static bool  s_pick_fw;                        /* firmware picker mode */
static char  s_pick_path[SETTINGS_NAME_LEN];   /* current subdir ("" = root) */
static char *s_pick_target;            /* settings field to write */
static const char *const *s_pick_exts; /* NULL-terminated extension list */
static uint8_t s_pick_eject_bit;       /* eject_mask bit for this volume */

/* Load (or reload) the current picker directory via the disk thread. */
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
        usb_osal_msleep(20);
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

    if (s_pick_fw) {                           /* firmware file selected */
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
        fwupdate_request(full);
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
    } else if (!s_pick_fw) {
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
    s_pick_fw        = false;
    s_pick_target    = target;
    s_pick_exts      = exts;
    s_pick_eject_bit = eject_bit;
    s_pick_path[0]   = '\0';   /* start at the volume root */
    /* FatFS is not re-entrant: the scan runs in the disk thread (the pad is
     * idle for the few ms we block here). */
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

/* ======================= SCREEN: STORAGE ================================== */
static void storage_change(int id, int dir)
{
    (void)id;
    int p = settings()->boot_pref + dir;
    if (p < 0) p = 2;
    if (p > 2) p = 0;
    settings()->boot_pref = (uint8_t)p;
    save_settings_status();
    screen_refresh();
}

static const char *boot_pref_name(uint8_t p)
{
    switch (p) {
    case BOOT_PREF_USB: return "USB ONLY";
    case BOOT_PREF_SD:  return "SD ONLY";
    default:            return "AUTO";
    }
}

static void storage_build(void)
{
    menu_item_t *m = mi_add(MI_CHOICE, "STORAGE SOURCE",
                            boot_pref_name(settings()->boot_pref));
    m->on_change = storage_change;
    mi_add(MI_INFO, "ACTIVE BACKEND",
           disk_backend_is_usb() ? "USB" : "SD CARD");
    mi_add(MI_INFO, "", "");
    m = mi_add(MI_ACTION, "RESCAN / REMOUNT ALL", "");
    m->action = disks_rescan;
    mi_add(MI_INFO, "AUTO = USB IF PRESENT, ELSE SD CARD", "");
    mi_add(MI_INFO, "CHANGES APPLY ON RESCAN OR NEXT BOOT", "");
}

static const menu_screen_t SCR_STORAGE = { "STORAGE", storage_build };

/* ======================= SCREEN: IP OCTET EDITOR ========================== */
/* Edits one 4-octet address in the settings with LEFT/RIGHT (+/-1, hold to
 * repeat) and LB/RB (+/-16). No text input needed. */
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
    mi_add(MI_INFO, "LEFT/RIGHT: +/-1   LB/RB: +/-16", "");
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
    set_status(" APPLIED TO ACTIVE INTERFACE");
    screen_refresh();
}

static void fmt_ip(char *out, int cap, const uint8_t ip[4])
{
    snprintf(out, cap, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}

static void net_build(void)
{
    a2_settings_t *st = settings();
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

    char lines[6][41];
    int n = menu_hook_net_lines(lines, 6);
    for (int i = 0; i < n; i++)
        mi_add(MI_INFO, lines[i], "");
}

static const menu_screen_t SCR_NETWORK = { "NETWORK", net_build };

/* ======================= SCREEN: USB DEVICES ============================== */
static void usb_tree_walk(struct usbh_hub *hub, int depth)
{
    if (!hub)
        return;
    for (int i = 0; i < CONFIG_USBHOST_MAX_EHPORTS; i++) {
        struct usbh_hubport *p = &hub->child[i];
        if (!p->connected)
            continue;
        char label[MENU_LABEL_LEN + 1];
        const char *drv = "?";
        if (p->config.intf[0].class_driver &&
            p->config.intf[0].class_driver->driver_name)
            drv = p->config.intf[0].class_driver->driver_name;
        snprintf(label, sizeof(label), "%*s%d-%d %04X:%04X %s",
                 depth * 2, "", hub->is_roothub ? 1 : hub->index,
                 p->port, p->device_desc.idVendor, p->device_desc.idProduct,
                 drv);
        char val[MENU_VALUE_LEN + 1];
        snprintf(val, sizeof(val), "%s",
                 p->speed == 2 ? "HS" : p->speed == 1 ? "FS" : "LS");
        mi_add(MI_INFO, label, val);
        if (p->iProduct && p->iProduct[0]) {
            char pl[MENU_LABEL_LEN + 1];
            snprintf(pl, sizeof(pl), "%*s%s", depth * 2 + 4, "", p->iProduct);
            mi_add(MI_INFO, pl, "");
        }
        if (p->self)
            usb_tree_walk(p->self, depth + 1);
    }
}

static void usb_refresh(int id)
{
    (void)id;
    screen_refresh();
}

static void usb_build(void)
{
    extern struct usbh_bus g_usbhost_bus[];
    mi_add(MI_INFO, "ROOT HUB (BL616 EHCI)", "");
    usb_tree_walk(&g_usbhost_bus[0].hcd.roothub, 1);
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "REFRESH", "");
    m->action = usb_refresh;
}

static const menu_screen_t SCR_USB = { "USB DEVICES", usb_build };

/* ======================= SCREEN: FIRMWARE UPDATE ========================== */
static const char *const k_fw_exts[] = { "bin", NULL };

static void fw_pick(int id)
{
    (void)id;
    s_pick_fw        = true;
    s_pick_target    = NULL;
    s_pick_exts      = k_fw_exts;
    s_pick_eject_bit = 0;
    s_pick_path[0]   = '\0';
    picker_load();
    screen_push(&SCR_PICKER);
}

static void fw_install(int id)
{
    (void)id;
    set_status(" INSTALLING - DO NOT POWER OFF!");
    fwupdate_commit();   /* the disk thread takes it from here */
}

static void fw_cancel(int id)
{
    (void)id;
    fwupdate_cancel();
    screen_refresh();
}

static void fw_build(void)
{
    menu_item_t *m;
    mi_add(MI_INFO, "INSTALLED BUILD", __DATE__);
    mi_add(MI_INFO, "", "");

    switch (fwupdate_state()) {
    case FWU_IDLE:
        m = mi_add(MI_ACTION, "CHOOSE FIRMWARE FILE (.BIN)", "");
        m->action = fw_pick;
        break;
    case FWU_STAGING:
    case FWU_VERIFYING:
        mi_add(MI_INFO, fwupdate_message(), "");
        mi_add(MI_INFO, "(DISKS KEEP SERVING MEANWHILE)", "");
        break;
    case FWU_STAGED:
        mi_add(MI_INFO, fwupdate_message(), "");
        mi_add(MI_INFO, "", "");
        m = mi_add(MI_ACTION, "INSTALL NOW AND REBOOT", "");
        m->action = fw_install;
        m = mi_add(MI_ACTION, "CANCEL", "");
        m->action = fw_cancel;
        break;
    case FWU_ERROR:
        mi_add(MI_INFO, fwupdate_message(), "");
        m = mi_add(MI_ACTION, "CHOOSE FIRMWARE FILE (.BIN)", "");
        m->action = fw_pick;
        break;
    default:
        mi_add(MI_INFO, "INSTALLING...", "");
        break;
    }
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "INSTALL TAKES ~10S. DO NOT POWER", "");
    mi_add(MI_INFO, "OFF - RECOVERY NEEDS A PC IF", "");
    mi_add(MI_INFO, "INTERRUPTED (UPDATE BUTTON MODE).", "");
}

static const menu_screen_t SCR_FWUPDATE = { "FIRMWARE UPDATE", fw_build };

/* ======================= SCREEN: ROOT ===================================== */
static void root_enter(int id)
{
    switch (id) {
    case 0: screen_push(&SCR_SLOTS);    break;
    case 1: screen_push(&SCR_DISKS);    break;
    case 2: screen_push(&SCR_STORAGE);  break;
    case 3: screen_push(&SCR_NETWORK);  break;
    case 4: screen_push(&SCR_USB);      break;
    case 5: screen_push(&SCR_FWUPDATE); break;
    }
}

static void root_reset_defaults(int id)
{
    (void)id;
    settings_reset_defaults();
    save_settings_status();
    screen_refresh();
}

static void root_build(void)
{
    static const char *const entries[] = {
        "SLOT ASSIGNMENTS", "DISK IMAGES", "STORAGE", "NETWORK",
        "USB DEVICES", "FIRMWARE UPDATE"
    };
    for (int i = 0; i < 6; i++) {
        menu_item_t *m = mi_add(MI_SUBMENU, entries[i], "");
        m->action = root_enter;
        m->id = i;
    }
    mi_add(MI_INFO, "", "");
    menu_item_t *m = mi_add(MI_ACTION, "RESET SETTINGS TO DEFAULTS", "");
    m->action = root_reset_defaults;
    mi_add(MI_INFO, "", "");
    mi_add(MI_INFO, "SETTINGS",
           settings_loaded_from_flash() ? "FLASH" : "DEFAULTS");
    {
        char dbg[41];
        settings_debug_line(dbg, sizeof(dbg));
        mi_add(MI_INFO, dbg, "");
    }
    mi_add(MI_INFO, "BUILD", __DATE__);
}

static const menu_screen_t SCR_ROOT = { "MAIN MENU", root_build };

/* ---- view switching ------------------------------------------------------ */
static void enter_view(view_t v)
{
    s_view = v;
    switch (v) {
    case VIEW_APPLE:
        osd_console_set_lockout(false);
        osd_console_hide();
        break;
    case VIEW_CONSOLE:
        s_mcu_view = VIEW_CONSOLE;
        osd_console_set_lockout(false);
        osd_console_show();
        break;
    case VIEW_MENU:
        s_mcu_view = VIEW_MENU;
        /* buffer logs while the menu owns the screen */
        osd_console_set_lockout(true);
        screen_refresh();
        paint();
        break;
    }
}

bool menu_mcu_view_active(void)
{
    return s_view != VIEW_APPLE;
}

/* ---- input: edges + hold repeat ------------------------------------------ */
#define REPEAT_DELAY_US  400000u
#define REPEAT_RATE_US   120000u

static uint16_t s_prev_buttons;
static uint16_t s_held_dir;            /* dpad button currently repeating */
static uint32_t s_next_repeat_us;

static void handle_button(uint16_t btn)
{
    /* global: SELECT toggles Apple II <-> MCU */
    if (btn == XINPUT_BACK) {
        if (s_view == VIEW_APPLE)
            enter_view(s_mcu_view);
        else
            enter_view(VIEW_APPLE);
        return;
    }
    if (s_view == VIEW_APPLE)
        return;                        /* pad belongs to the Apple II side */

    /* MCU view: "Y" (label) switches console <-> menu */
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
    case XINPUT_DPAD_UP:    move_cursor(-1); break;
    case XINPUT_DPAD_DOWN:  move_cursor(1);  break;
    case XINPUT_DPAD_LEFT:  if (chg) m->on_change(m->id, -1);  break;
    case XINPUT_DPAD_RIGHT: if (chg) m->on_change(m->id, 1);   break;
    case BTN_BIGDOWN:       if (chg) m->on_change(m->id, -16); break;
    case BTN_BIGUP:         if (chg) m->on_change(m->id, 16);  break;
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
    uint16_t pressed = buttons & (uint16_t)~s_prev_buttons;
    s_prev_buttons = buttons;

    /* one event per rising edge, in a stable priority order */
    static const uint16_t order[] = {
        XINPUT_BACK, BTN_VIEW, BTN_BACK, BTN_OK, BTN_BIGDOWN, BTN_BIGUP,
        XINPUT_DPAD_UP, XINPUT_DPAD_DOWN, XINPUT_DPAD_LEFT, XINPUT_DPAD_RIGHT,
    };
    for (unsigned i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
        if (pressed & order[i]) {
            handle_button(order[i]);
            if (order[i] & (XINPUT_DPAD_UP | XINPUT_DPAD_DOWN |
                            XINPUT_DPAD_LEFT | XINPUT_DPAD_RIGHT)) {
                s_held_dir = order[i];
                s_next_repeat_us =
                    (uint32_t)bflb_mtimer_get_time_us() + REPEAT_DELAY_US;
            }
        }
    }

    /* firmware update progress: keep the update screen live */
    if (s_view == VIEW_MENU && s_stack[s_depth] == &SCR_FWUPDATE &&
        fwupdate_dirty()) {
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
        uint32_t now = (uint32_t)bflb_mtimer_get_time_us();
        if ((int32_t)(now - s_next_repeat_us) >= 0) {
            handle_button(s_held_dir);
            s_next_repeat_us = now + REPEAT_RATE_US;
        }
    } else if (!(buttons & s_held_dir)) {
        s_held_dir = 0;
    }
}

void menu_init(void)
{
    s_depth = 0;
    s_stack[0]  = &SCR_ROOT;
    s_cursor[0] = 0;
    s_scroll[0] = 0;
    s_nitems = 0;
    SCR_ROOT.build();
}
