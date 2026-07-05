/*
 * disk.c — Apple II Disk II / ProDOS HDD image serving for the a2mega ESP32
 * build. See disk.h for the architecture.
 *
 * Port of the a2n20v2-Enhanced firmware_host/disk.c (NanoApple2 floppy_track
 * model): the FPGA requests one track at a time (lba = track*13, 13 * 512 =
 * 0x1A00 bytes), we read it from the image file on the SD card and stream it
 * into the FPGA track window (XFER SPACE 4), then pulse ack. HDD units serve
 * one 512-byte block per request through XFER SPACE 5.
 *
 * Differences from the BL616 original:
 *   - Storage is the SD card at /sdcard (POSIX stdio/dirent via VFS); there
 *     is no USB-stick backend, so boot_pref is ignored.
 *   - FPGA transport is fpga_link.h over the Octal SPI service; track/block
 *     data goes to the BSRAM-backed XFER spaces A2SPACE_DISK/A2SPACE_HDD at
 *     window offsets (not SDRAM absolute addresses).
 *   - Floppy rd/wr pending are bits of A2REG_VOL_CMD; ACK is at base+0xE.
 *   - The USB enumeration supervisor and fwupdate/fpgaupdate staging are not
 *     ported (the ESP32 reflashes over its own USB-C).
 *
 * IMPORTANT: disk_poll() must never block — a blocking delay here freezes
 * track serving and hangs any boot that seeks during it (seen on the BL616 as
 * a ~1.5 s poll gap). The console hide after a good mount is scheduled and
 * performed non-blockingly from the poll loop.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>       /* fsync */
#include <dirent.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_timer.h"    /* esp_timer_get_time — us since boot */

#include "a2fpga_regs.h"
#include "fpga_link.h"
#include "gcr_dsk.h"      /* on-the-fly .dsk/.do <-> 6-and-2 GCR nibble codec */
#include "settings.h"     /* persisted image overrides + slot map */
#include "disk.h"

static const char *TAG = "disk";

/* ---- OSD boot/status console hooks (ported menu module) -------------------
 * Weak no-op fallbacks so this file builds and links before/without the menu
 * port; the real osd_console.c (strong symbols, same BL616 prototypes)
 * overrides them at link time. */
void __attribute__((weak)) osd_log(const char *fmt, ...) { (void)fmt; }
void __attribute__((weak)) osd_console_show(void) {}
void __attribute__((weak)) osd_console_hide(void) {}

/* Log to both the serial console and the on-screen OSD console. */
/* printf, not ESP_LOGI: the Arduino core's precompiled IDF caps the log
 * level at ERROR, silently discarding INFO — bring-up taught us that the
 * hard way. printf reaches the USB-CDC console unconditionally. */
#define DLOGI(...) do { printf("[disk] " __VA_ARGS__); printf("\n"); osd_log(__VA_ARGS__); } while (0)
#define DLOGW(...) do { printf("[disk] " __VA_ARGS__); printf("\n"); osd_log(__VA_ARGS__); } while (0)

/* ---- SD card mount point --------------------------------------------------
 * The card is mounted by the integrator (esp_vfs_fat_sdmmc_mount) before
 * disk_poll() first runs; this module only does file I/O under it. */
#define SD_ROOT       "/sdcard"
#define SD_PREFIX_LEN (sizeof(SD_ROOT))   /* strlen("/sdcard/") == 8 */

#define SECTOR_BYTES    512u
#define MAX_TRACK_BYTES 0x1A00u   /* 6656 = 13 sectors = A2DISK_TRACK_BYTES */

#define NDRV 2   /* Disk II floppy drives */
#define NHDD 2   /* ProDOS HDD units      */

/* Per-drive image format:
 *   FMT_NIB — raw nibble track, streamed as-is
 *   FMT_DSK — sector image (16*256 B/track) that gcr_dsk nibblizes on load /
 *             de-nibblizes on flush; g_order[] gives the file's sector order
 *             (.dsk/.do = DOS 3.3, .po = ProDOS)
 * A .2mg is a 64-byte header wrapping one of the above; g_base[] carries the
 * payload's byte offset within the file (0 for bare images). */
typedef enum { FMT_NONE = 0, FMT_NIB, FMT_DSK } disk_fmt_t;

/* Candidate images per drive, tried in order (first that opens wins).
 * Sector formats take priority over .nib. Menu/config selection first. */
#define NCAND 5
static const char *const g_candidates[NDRV][NCAND] = {
    { SD_ROOT "/disk1.dsk", SD_ROOT "/disk1.do", SD_ROOT "/disk1.po",
      SD_ROOT "/disk1.2mg", SD_ROOT "/disk1.nib" },
    { SD_ROOT "/disk2.dsk", SD_ROOT "/disk2.do", SD_ROOT "/disk2.po",
      SD_ROOT "/disk2.2mg", SD_ROOT "/disk2.nib" },
};

#define PATH_MAX_LEN (SETTINGS_NAME_LEN + 16)   /* "/sdcard/" + override */

static FILE       *g_img[NDRV];
static bool        g_mounted[NDRV];
static bool        g_writable[NDRV];
static disk_fmt_t  g_fmt[NDRV];
static gcr_order_t g_order[NDRV];                /* sector order for FMT_DSK    */
static uint32_t    g_base[NDRV];                 /* payload offset (.2mg header)*/
static char        g_imgname[NDRV][PATH_MAX_LEN];/* resolved image path         */
static uint8_t     g_trackbuf[MAX_TRACK_BYTES];  /* nibble track (FPGA window)  */
static uint8_t     g_secbuf[DSK_TRACK_BYTES];    /* one sector track (16*256)   */

/* ProDOS HDD units: raw 512-byte block volumes (.hdv/.po/.2mg), served one
 * block at a time, LBA 1:1 into the image payload. */
static const char *const g_hdd_candidates[NHDD][3] = {
    { SD_ROOT "/hdd1.hdv", SD_ROOT "/hdd1.po", SD_ROOT "/hdd1.2mg" },
    { SD_ROOT "/hdd2.hdv", SD_ROOT "/hdd2.po", SD_ROOT "/hdd2.2mg" },
};
static FILE    *g_hdd_img[NHDD];
static bool     g_hdd_mounted[NHDD];
static bool     g_hdd_writable[NHDD];
static uint32_t g_hdd_base[NHDD];       /* payload offset (.2mg header)  */
static uint32_t g_hdd_blocks[NHDD];     /* size in 512-byte blocks       */
static char     g_hdd_name[NHDD][PATH_MAX_LEN];
static uint8_t  g_blockbuf[SECTOR_BYTES];

/* Menu directory-listing request (see disk_list_begin/poll in disk.h). */
static volatile bool          g_list_req;
static volatile bool          g_list_done;
static const char *const     *g_list_exts;
static char                   g_list_path[PATH_MAX_LEN];
static disk_list_ent_t        g_list_ents[DISK_LIST_MAX];
static int                    g_list_count;

/* Display form of a resolved path: strip the "/sdcard/" prefix. */
static const char *disp(const char *path)
{
    if (strncmp(path, SD_ROOT "/", SD_PREFIX_LEN) == 0)
        return path + SD_PREFIX_LEN;
    return path;
}

/* Case-insensitive extension test ("dsk", "do", ...). */
static bool has_ext(const char *name, const char *ext)
{
    size_t n = strlen(name), x = strlen(ext);
    if (n < x + 1 || name[n - x - 1] != '.')
        return false;
    for (size_t i = 0; i < x; i++)
        if ((name[n - x + i] | 0x20) != (ext[i] | 0x20))
            return false;
    return true;
}

/* Format + sector order from the filename extension. .2mg is resolved from its
 * header at mount time (see mount_drive). */
static disk_fmt_t detect_format(const char *name, gcr_order_t *order)
{
    *order = GCR_ORDER_DOS;
    if (has_ext(name, "nib"))
        return FMT_NIB;
    if (has_ext(name, "dsk") || has_ext(name, "do"))
        return FMT_DSK;
    if (has_ext(name, "po")) {
        *order = GCR_ORDER_PRODOS;
        return FMT_DSK;
    }
    return FMT_NONE;
}

/* Size in bytes of an open file (position preserved). */
static uint32_t file_size(FILE *f)
{
    long cur = ftell(f);
    if (fseek(f, 0, SEEK_END) != 0)
        return 0;
    long sz = ftell(f);
    fseek(f, cur < 0 ? 0 : cur, SEEK_SET);
    return sz < 0 ? 0 : (uint32_t)sz;
}

/* Sniff the sector order of a bare .dsk (the extension nominally means DOS
 * 3.3 order, but many ProDOS disks circulate as ProDOS-order images named
 * .dsk). Detection per the classic CiderPress/AppleWin heuristics:
 *   - a DOS 3.3 VTOC at track 17 sector 0 (DOS-order file offset 0x11000):
 *     35 tracks, 16 sectors, 256 bytes/sector markers
 *   - else a ProDOS volume directory at block 2 (ProDOS-order file offset
 *     0x400): storage type $F header, entry_length $27, entries/block $0D
 * A DOS-order image of a ProDOS *filesystem* still sniffs as DOS order
 * (ProDOS blocks are not contiguous in a DOS-order file), which is correct —
 * the order describes the file layout, not the filesystem. Defaults to DOS
 * order when neither signature is found. */
static gcr_order_t sniff_dsk_order(FILE *f)
{
    uint8_t buf[256];

    if (fseek(f, 0x11000, SEEK_SET) == 0 &&
        fread(buf, 1, sizeof(buf), f) == sizeof(buf)) {
        if (buf[0x34] == 35 && buf[0x35] == 16 &&
            buf[0x36] == 0x00 && buf[0x37] == 0x01)
            return GCR_ORDER_DOS;        /* DOS 3.3 VTOC found */
    }

    if (fseek(f, 0x400, SEEK_SET) == 0 &&
        fread(buf, 1, sizeof(buf), f) == sizeof(buf)) {
        if ((buf[0x04] >> 4) == 0xF && (buf[0x04] & 0x0F) >= 1 &&
            buf[0x23] == 0x27 && buf[0x24] == 0x0D)
            return GCR_ORDER_PRODOS;     /* ProDOS volume directory found */
    }

    return GCR_ORDER_DOS;
}

/* Parse a 2IMG (.2mg) header: 64-byte header, format word at 0x0C (0 = DOS
 * order, 1 = ProDOS order, 2 = NIB), payload offset at 0x18, length at 0x1C.
 * Only floppy-size payloads serve as Disk II volumes; block-device payloads
 * belong to the hard-disk path. Returns the format or FMT_NONE. */
static disk_fmt_t parse_2mg(FILE *f, gcr_order_t *order, uint32_t *base,
                            uint32_t *paylen)
{
    uint8_t h[64];
    if (fseek(f, 0, SEEK_SET) != 0 || fread(h, 1, sizeof h, f) != sizeof h)
        return FMT_NONE;
    if (memcmp(h, "2IMG", 4) != 0)
        return FMT_NONE;

    uint32_t fmt = (uint32_t)h[0x0C] | ((uint32_t)h[0x0D] << 8) |
                   ((uint32_t)h[0x0E] << 16) | ((uint32_t)h[0x0F] << 24);
    uint32_t off = (uint32_t)h[0x18] | ((uint32_t)h[0x19] << 8) |
                   ((uint32_t)h[0x1A] << 16) | ((uint32_t)h[0x1B] << 24);
    uint32_t len = (uint32_t)h[0x1C] | ((uint32_t)h[0x1D] << 8) |
                   ((uint32_t)h[0x1E] << 16) | ((uint32_t)h[0x1F] << 24);
    if (off == 0)
        off = 64;   /* some creators leave the offset field 0 */

    *base   = off;
    *paylen = len;
    *order  = (fmt == 1) ? GCR_ORDER_PRODOS : GCR_ORDER_DOS;
    if (fmt == 2)
        return FMT_NIB;
    if (fmt <= 1)
        return FMT_DSK;
    return FMT_NONE;
}

/* Open name read-write, falling back to read-only. NULL if neither works. */
static FILE *open_image(const char *name, bool *rw)
{
    FILE *f = fopen(name, "r+b");
    if (f) {
        *rw = true;
        return f;
    }
    f = fopen(name, "rb");
    if (f)
        *rw = false;
    return f;
}

/* Flush stdio buffers and push the data to the card. */
static void image_sync(FILE *f)
{
    fflush(f);
    fsync(fileno(f));
}

static void mount_drive(int v)
{
    g_mounted[v]  = false;
    g_writable[v] = false;
    g_fmt[v]      = FMT_NONE;
    g_order[v]    = GCR_ORDER_DOS;
    g_base[v]     = 0;
    fpga_reg_write(A2REG_VOL_READY(v), 0);
    fpga_reg_write(A2REG_VOL_MOUNTED(v), 0);

    /* Default display name (primary candidate) for the not-found log. */
    strncpy(g_imgname[v], g_candidates[v][0], sizeof(g_imgname[v]) - 1);
    g_imgname[v][sizeof(g_imgname[v]) - 1] = '\0';

    if (settings()->eject_mask & (1u << v))
        return;   /* ejected from the menu: leave unmounted */

    /* Candidate list: a persisted per-drive override (menu file picker) is
     * tried first, then the built-in names. First that opens AND resolves to
     * a servable format wins. Prefer read-write; fall back to read-only. */
    char ovr[PATH_MAX_LEN];
    const char *cands[NCAND + 1];
    int ncand = 0;
    if (settings()->disk_img[v][0]) {
        snprintf(ovr, sizeof(ovr), SD_ROOT "/%s", settings()->disk_img[v]);
        cands[ncand++] = ovr;
    }
    for (int c = 0; c < NCAND; c++)
        cands[ncand++] = g_candidates[v][c];

    int opened = 0;
    for (int c = 0; c < ncand && !opened; c++) {
        const char *name = cands[c];
        bool rw;
        FILE *f = open_image(name, &rw);
        if (!f)
            continue;

        disk_fmt_t  fmt;
        gcr_order_t order = GCR_ORDER_DOS;
        uint32_t    base  = 0;
        uint32_t    bytes = file_size(f);

        if (has_ext(name, "2mg")) {
            uint32_t paylen = 0;
            fmt = parse_2mg(f, &order, &base, &paylen);
            if (paylen)
                bytes = paylen;
            else if (bytes > base)
                bytes -= base;
            /* Only floppy-size payloads are Disk II volumes; larger 2mg images
             * are block devices and belong to the hard-disk path. */
            if (fmt == FMT_DSK && bytes != DSK_TRACK_BYTES * 35u) {
                DLOGI("DISK II: D%d %s not a 5.25 floppy (%lu B) - skip",
                      v + 1, disp(name), (unsigned long)bytes);
                fmt = FMT_NONE;
            }
        } else {
            fmt = detect_format(name, &order);
            /* Bare .dsk is ambiguous: sniff the actual sector order (.do and
             * .po stay explicit). */
            if (fmt == FMT_DSK && has_ext(name, "dsk"))
                order = sniff_dsk_order(f);
        }

        if (fmt == FMT_NONE) {
            fclose(f);
            continue;
        }

        g_img[v]      = f;
        g_writable[v] = rw;
        g_fmt[v]      = fmt;
        g_order[v]    = order;
        g_base[v]     = base;
        strncpy(g_imgname[v], name, sizeof(g_imgname[v]) - 1);
        g_imgname[v][sizeof(g_imgname[v]) - 1] = '\0';
        opened = 1;

        uint32_t blocks = bytes / SECTOR_BYTES;
        /* .dsk/.do/.po: 35 trk * 16 * 256 = 143360 B; .nib: 35 * 6656 =
         * 232960 B. VOL_SIZE is informational for a floppy. */
        DLOGI("DISK II: D%d %s = %lu B (%s%s)", v + 1, disp(g_imgname[v]),
              (unsigned long)bytes,
              fmt == FMT_NIB ? "nib" :
              (order == GCR_ORDER_PRODOS ? "po" : "dsk"),
              base ? " 2mg" : "");
        fpga_reg_write32(A2REG_VOL_SIZE0(v), blocks);
        fpga_reg_write(A2REG_VOL_READONLY(v), g_writable[v] ? 0 : 1);
        fpga_reg_write(A2REG_VOL_MOUNTED(v), 1);
        fpga_reg_write(A2REG_VOL_READY(v), 1);
        g_mounted[v] = true;
    }
}

/* ---- ProDOS HDD unit mount: raw 512-byte blocks, LBA 1:1 ----------------- */
static void mount_hdd(int u)
{
    g_hdd_mounted[u]  = false;
    g_hdd_writable[u] = false;
    g_hdd_base[u]     = 0;
    g_hdd_blocks[u]   = 0;
    fpga_reg_write(A2REG_HDD_CTL(u), 0);

    strncpy(g_hdd_name[u], g_hdd_candidates[u][0], sizeof(g_hdd_name[u]) - 1);
    g_hdd_name[u][sizeof(g_hdd_name[u]) - 1] = '\0';

    if (settings()->eject_mask & (1u << (4 + u)))
        return;   /* ejected from the menu: leave unmounted */

    char ovr[PATH_MAX_LEN];
    const char *cands[4];
    int ncand = 0;
    if (settings()->hdd_img[u][0]) {
        snprintf(ovr, sizeof(ovr), SD_ROOT "/%s", settings()->hdd_img[u]);
        cands[ncand++] = ovr;
    }
    for (int c = 0; c < 3; c++)
        cands[ncand++] = g_hdd_candidates[u][c];

    for (int c = 0; c < ncand; c++) {
        const char *name = cands[c];
        bool rw;
        FILE *f = open_image(name, &rw);
        if (!f)
            continue;

        uint32_t base  = 0;
        uint32_t bytes = file_size(f);

        if (has_ext(name, "2mg")) {
            /* Any ProDOS-order 2mg payload serves as a block device. */
            gcr_order_t order;
            uint32_t    paylen = 0;
            disk_fmt_t  fmt = parse_2mg(f, &order, &base, &paylen);
            if (fmt != FMT_DSK || order != GCR_ORDER_PRODOS) {
                /* DOS-order / NIB payloads are floppies, not block devices */
                if (fmt == FMT_NONE || bytes < base) {
                    fclose(f);
                    continue;
                }
            }
            if (paylen)
                bytes = paylen;
            else
                bytes -= base;
        }
        /* .hdv / .po: raw ProDOS blocks from byte 0 */

        uint32_t blocks = bytes / SECTOR_BYTES;
        if (blocks == 0) {
            fclose(f);
            continue;
        }
        if (blocks > 0xFFFFu)
            blocks = 0xFFFFu;   /* ProDOS volumes cap at 65535 blocks (32 MB) */

        g_hdd_img[u]      = f;
        g_hdd_writable[u] = rw;
        g_hdd_base[u]     = base;
        g_hdd_blocks[u]   = blocks;
        strncpy(g_hdd_name[u], name, sizeof(g_hdd_name[u]) - 1);
        g_hdd_name[u][sizeof(g_hdd_name[u]) - 1] = '\0';

        fpga_reg_write(A2REG_HDD_SIZE_L(u), (uint8_t)blocks);
        fpga_reg_write(A2REG_HDD_SIZE_H(u), (uint8_t)(blocks >> 8));
        fpga_reg_write(A2REG_HDD_CTL(u), A2HDD_CTL_READY | A2HDD_CTL_MOUNTED |
                                         (rw ? 0 : A2HDD_CTL_READONLY));
        g_hdd_mounted[u] = true;
        return;
    }
}

/* (Re)mount trigger. Set at startup (the first disk_poll performs the initial
 * mount) and whenever the menu changes an image selection. */
static volatile bool g_remount_req = true;
static volatile bool g_remounting  = false;   /* disk_remount() running */

/* Non-blocking console hide: disk_remount() schedules the "READY" screen to be
 * handed back to the Apple II after a readable delay, and disk_poll() performs
 * the hide when the time arrives. Doing this instead of a blocking delay keeps
 * the 2 ms disk task serving track loads throughout — a sleep here freezes
 * serving for the whole delay and hangs a boot that seeks into it.
 * 0 = nothing scheduled. */
static int64_t g_hide_console_at_us = 0;

void disk_request_remount(void)
{
    g_remount_req = true;
}

/* ---- Disk II (re)mount, logged to the shared OSD console -------------------
 * Mount status is appended to the boot console (osd_console). The console is
 * shown while we look for the image(s); on a successful mount we hide it so the
 * screen returns to the Apple II, and on failure we leave it up so the message
 * can be read. */
static void disk_remount(void)
{
    osd_console_show();
    DLOGI("DISK II: SEARCHING FOR STORAGE...");

    /* Tear down the previous mount. */
    for (int v = 0; v < NDRV; v++) {
        if (g_img[v]) {
            fclose(g_img[v]);
            g_img[v] = NULL;
        }
        g_mounted[v]  = false;
        g_writable[v] = false;
        fpga_reg_write(A2REG_VOL_READY(v), 0);
        fpga_reg_write(A2REG_VOL_MOUNTED(v), 0);
    }
    for (int u = 0; u < NHDD; u++) {
        if (g_hdd_img[u]) {
            fclose(g_hdd_img[u]);
            g_hdd_img[u] = NULL;
        }
        g_hdd_mounted[u] = false;
        fpga_reg_write(A2REG_HDD_CTL(u), 0);
    }

    /* SD card present? The VFS mount is owned by the integrator; probe it. */
    DIR *root = opendir(SD_ROOT);
    if (!root) {
        DLOGW("DISK II: NO SD CARD (%s NOT MOUNTED)", SD_ROOT);
        DLOGI("DISK II: INSERT SD CARD WITH DISK1.DSK/.NIB");
        return;   /* leave the console up so the message is visible */
    }
    closedir(root);
    DLOGI("DISK II: SD CARD");

    int n_mounted = 0;
    for (int v = 0; v < NDRV; v++) {
        mount_drive(v);
        if (g_mounted[v]) {
            DLOGI("DISK II: DRIVE %d %s MOUNTED (%s)", v + 1,
                  disp(g_imgname[v]), g_writable[v] ? "RW" : "RO");
            n_mounted++;
        } else {
            DLOGI("DISK II: DRIVE %d %s NOT FOUND", v + 1, disp(g_imgname[v]));
        }
    }
    for (int u = 0; u < NHDD; u++) {
        mount_hdd(u);
        if (g_hdd_mounted[u]) {
            DLOGI("HDD: UNIT %d %s MOUNTED (%lu BLK %s)", u + 1,
                  disp(g_hdd_name[u]), (unsigned long)g_hdd_blocks[u],
                  g_hdd_writable[u] ? "RW" : "RO");
            n_mounted++;
        }
    }

    if (n_mounted > 0) {
        DLOGI("DISK II: READY - STARTING APPLE II");
        /* Hand the screen back after a readable delay, WITHOUT blocking: a
         * sleep here would freeze the 2 ms disk task and hang a boot that
         * seeks during the delay (observed on the BL616 as a ~1.54 s gap). */
        g_hide_console_at_us = esp_timer_get_time() + 1500000;
    } else {
        DLOGI("DISK II: NO DISK IMAGES ON SD CARD");
        /* leave the console up so the message is visible */
    }
}

void disk_init(void)
{
    /* Nothing to bring up here: settings_init() and the SD/VFS mount are the
     * integrator's job; the first disk_poll() performs the initial mount. */
    g_remount_req = true;
}

static void serve_drive(int v)
{
    if (!g_mounted[v])
        return;

    uint8_t cmd = fpga_reg_read(A2REG_VOL_CMD(v));
    bool rd = (cmd & A2VOL_CMD_RD) != 0;
    bool wr = (cmd & A2VOL_CMD_WR) != 0;
    if (!rd && !wr)
        return;   /* nothing pending */

    uint32_t lba   = fpga_reg_read32(A2REG_VOL_LBA0(v));
    uint32_t nblk  = (uint32_t)fpga_reg_read(A2REG_VOL_BLK_CNT(v)) + 1u;
    uint32_t nbyte = nblk * SECTOR_BYTES;
    if (nbyte > MAX_TRACK_BYTES)
        nbyte = MAX_TRACK_BYTES;

    uint32_t addr = A2DISK_WINDOW(v);

    /* Log disk activity to the console BUFFER on track change (a boot re-polling
     * the same track must not spam). Does NOT force the console visible — the
     * Apple II keeps the screen so the booted disk is actually usable. */
    {
        static int s_last_trk[NDRV] = { -1, -1 };
        int trk = (int)(lba / 13u);
        /* BRING-UP: log every serve, including same-track reloads after a
         * warm reset (the dedup hid exactly the event under investigation).
         * TODO: restore the dedup once boot serving is verified. */
        (void)s_last_trk;
        DLOGI("DISK II: D%d %s TRK %d (LBA %lu N%lu)", v + 1,
              wr ? "WR" : "RD", trk, (unsigned long)lba,
              (unsigned long)nblk);
    }

    if (wr) {
        /* Flush a dirty track: FPGA track window -> image file. */
        if (g_writable[v]) {
            for (uint32_t off = 0; off < nbyte; off += SECTOR_BYTES) {
                uint32_t chunk = nbyte - off;
                if (chunk > SECTOR_BYTES)
                    chunk = SECTOR_BYTES;
                fpga_mem_read(A2SPACE_DISK, addr + off,
                              g_trackbuf + off, (uint16_t)chunk);
            }
            if (g_fmt[v] == FMT_DSK) {
                /* Decode the (possibly partly rewritten) nibble track back to
                 * file-order sectors. Preload the current on-file track so any
                 * sector that fails to decode keeps its existing bytes; gate the
                 * write on the found-mask so a bad decode never corrupts the
                 * image. */
                uint32_t track = lba / 13u;
                long     fpos  = (long)g_base[v] +
                                 (long)track * (long)DSK_TRACK_BYTES;
                size_t br = 0;
                if (fseek(g_img[v], fpos, SEEK_SET) == 0)
                    br = fread(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]);
                if (br < DSK_TRACK_BYTES)
                    memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
                uint16_t mask = gcr_decode_dos_track(g_trackbuf, MAX_TRACK_BYTES,
                                                     g_order[v], g_secbuf);
                if (mask != 0) {
                    if (fseek(g_img[v], fpos, SEEK_SET) == 0) {
                        fwrite(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]);
                        image_sync(g_img[v]);
                    }
                }
                if (mask != 0xFFFF)
                    DLOGW("DISK II: D%d TRK%lu wr partial mask=%04X",
                          v + 1, (unsigned long)track, (unsigned)mask);
            } else {
                if (fseek(g_img[v], (long)g_base[v] +
                                    (long)lba * (long)SECTOR_BYTES,
                          SEEK_SET) == 0) {
                    fwrite(g_trackbuf, 1, nbyte, g_img[v]);
                    image_sync(g_img[v]);
                }
            }
        }
    } else {
        /* Load the requested track: image file -> FPGA track window. */
        uint32_t track = lba / 13u;
        if (g_fmt[v] == FMT_DSK) {
            /* Read this track's 16*256 file-order sectors and nibblize them
             * into the 6-and-2 GCR stream the window expects. */
            size_t br = 0;
            if (fseek(g_img[v], (long)g_base[v] +
                                (long)track * (long)DSK_TRACK_BYTES,
                      SEEK_SET) == 0)
                br = fread(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]);
            if (br < DSK_TRACK_BYTES)
                memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
            gcr_encode_dos_track(g_secbuf, (uint8_t)track, DSK_DEFAULT_VOLUME,
                                 g_order[v], g_trackbuf, MAX_TRACK_BYTES);
        } else {
            /* .nib: raw nibble stream, streamed as-is. */
            size_t br = 0;
            if (fseek(g_img[v], (long)g_base[v] +
                                (long)lba * (long)SECTOR_BYTES,
                      SEEK_SET) == 0)
                br = fread(g_trackbuf, 1, nbyte, g_img[v]);
            if (br < nbyte) {
                /* EOF: a zero-filled track has no sync/prologue nibbles, so RWTS
                 * finds nothing and DOS I/O-errors at this same track every boot
                 * — pinpoints a truncated/short .nib. */
                osd_console_show();
                DLOGW("DISK II: TRK%lu SHORT br=%lu/%lu (EOF) -> zero-fill",
                      (unsigned long)track,
                      (unsigned long)br, (unsigned long)nbyte);
                memset(g_trackbuf + br, 0, nbyte - br);
            }
        }

        for (uint32_t off = 0; off < nbyte; off += SECTOR_BYTES) {
            uint32_t chunk = nbyte - off;
            if (chunk > SECTOR_BYTES)
                chunk = SECTOR_BYTES;
            fpga_mem_write(A2SPACE_DISK, addr + off,
                           g_trackbuf + off, (uint16_t)chunk);
        }
    }

    fpga_reg_write(A2REG_VOL_ACK(v), 1);   /* request serviced — release the head */
}

/* Serve one ProDOS HDD unit: raw 512-byte blocks, LBA 1:1 into the image
 * payload, one block per request through the unit's XFER SPACE 5 window. */
static void serve_hdd(int u)
{
    if (!g_hdd_mounted[u])
        return;

    uint8_t req = fpga_reg_read(A2REG_HDD_REQ(u)) &
                  (A2HDD_REQ_RD | A2HDD_REQ_WR);
    if (!req)
        return;   /* nothing pending */

    uint32_t lba = (uint32_t)fpga_reg_read(A2REG_HDD_LBA_L(u)) |
                   ((uint32_t)fpga_reg_read(A2REG_HDD_LBA_H(u)) << 8);
    uint32_t addr = A2HDD_WINDOW(u);
    long     fpos = (long)g_hdd_base[u] + (long)lba * (long)SECTOR_BYTES;

    if (req & A2HDD_REQ_WR) {
        /* write: block window -> image file */
        if (g_hdd_writable[u] && lba < g_hdd_blocks[u]) {
            fpga_mem_read(A2SPACE_HDD, addr, g_blockbuf, SECTOR_BYTES);
            if (fseek(g_hdd_img[u], fpos, SEEK_SET) == 0) {
                fwrite(g_blockbuf, 1, SECTOR_BYTES, g_hdd_img[u]);
                image_sync(g_hdd_img[u]);
            }
        }
    } else {
        /* read: image file -> block window */
        size_t br = 0;
        if (lba < g_hdd_blocks[u] &&
            fseek(g_hdd_img[u], fpos, SEEK_SET) == 0)
            br = fread(g_blockbuf, 1, SECTOR_BYTES, g_hdd_img[u]);
        if (br < SECTOR_BYTES)
            memset(g_blockbuf + br, 0, SECTOR_BYTES - br);
        fpga_mem_write(A2SPACE_HDD, addr, g_blockbuf, SECTOR_BYTES);
    }

    fpga_reg_write(A2REG_HDD_ACK(u), 1);   /* request serviced */
}

/* Program the persisted slot map into the slotmaker and strobe a reconfig.
 * On the a2mega this goes through the SLOT_SELECT/SLOT_CARD window pair
 * (esp32_ospi_connector regs 0x30-0x33); each select+write pair is done under
 * the link lock so another task cannot interleave a register access. */
static void apply_slot_map(void)
{
    for (int i = 0; i < 8; i++) {
        uint8_t c = settings()->slot_cards[i];
        if (c == 0xFF)
            c = settings_slot_hw_defaults[i];
        fpga_link_lock();
        fpga_reg_write(A2REG_SLOT_SELECT, (uint8_t)i);
        fpga_reg_write(A2REG_SLOT_CARD, c);
        fpga_link_unlock();
    }
    fpga_reg_write(A2REG_SLOT_RECONFIG, 1);   /* slotmaker reconfig strobe */

    uint8_t eff[8];
    for (int i = 0; i < 8; i++) {
        uint8_t c = settings()->slot_cards[i];
        eff[i] = (c == 0xFF) ? settings_slot_hw_defaults[i] : c;
    }
    DLOGI("SLOTS: %d %d %d %d %d %d %d %d",
          eff[0], eff[1], eff[2], eff[3], eff[4], eff[5], eff[6], eff[7]);
}

void disk_poll(void)
{
    if (g_remount_req) {
        g_remount_req = false;
        g_remounting  = true;
        disk_remount();
        g_remounting  = false;
    }

    /* Non-blocking console hide (scheduled by disk_remount on a good mount). */
    if (g_hide_console_at_us &&
        esp_timer_get_time() >= g_hide_console_at_us) {
        g_hide_console_at_us = 0;
        osd_console_hide();
    }

    /* Apple II reset release: the FPGA holds the Apple II in RESET from
     * power-on (reg 0x2E) so the autoboot slot scan does not run before
     * storage is up. Release as soon as a (re)mount has found at least one
     * volume, or after a deadline so a machine with no media still boots.
     * The FPGA has its own 15 s backstop should we never write. */
    {
        static bool s_released = false;
        if (!s_released) {
            bool any = false;
            for (int v = 0; v < NDRV; v++) any = any || g_mounted[v];
            for (int u = 0; u < NHDD; u++) any = any || g_hdd_mounted[u];
            if ((any && !g_remount_req) ||
                esp_timer_get_time() > 7000000) {
                /* Program the slot map JUST before the release — this late in
                 * boot the link is proven good (the mounts above ran over it),
                 * and the Apple II is still held in reset so the reconfig is
                 * race-free. */
                apply_slot_map();

                fpga_reg_write(A2REG_A2_RST_RELEASE, 1);
                s_released = true;
                DLOGI("A2: RESET RELEASED%s", any ? "" : " (NO MEDIA)");
            }
        }
    }

    /* Async directory listing for the menu (all filesystem access runs here,
     * in the task that owns the mounted images). Two passes so directories
     * sort before files. */
    if (g_list_req) {
        g_list_count = 0;
        for (int pass = 0; pass < 2; pass++) {
            DIR *dir = opendir(g_list_path);
            if (!dir)
                break;
            struct dirent *de;
            while (g_list_count < DISK_LIST_MAX &&
                   (de = readdir(dir)) != NULL) {
                if (de->d_name[0] == '.' || de->d_name[0] == '_')
                    continue;
                bool is_dir;
                if (de->d_type != DT_UNKNOWN) {
                    is_dir = (de->d_type == DT_DIR);
                } else {
                    char full[PATH_MAX_LEN + 72];
                    struct stat st;
                    snprintf(full, sizeof(full), "%s/%s",
                             g_list_path, de->d_name);
                    if (stat(full, &st) != 0)
                        continue;
                    is_dir = S_ISDIR(st.st_mode);
                }
                if ((pass == 0) != is_dir)
                    continue;
                if (!is_dir) {
                    bool match = false;
                    for (int e = 0; g_list_exts[e] && !match; e++)
                        match = has_ext(de->d_name, g_list_exts[e]);
                    if (!match)
                        continue;
                }
                if (strlen(de->d_name) >= sizeof(g_list_ents[0].name))
                    continue;   /* name too long to select later */
                disk_list_ent_t *e = &g_list_ents[g_list_count++];
                snprintf(e->name, sizeof(e->name), "%s", de->d_name);
                e->is_dir = is_dir;
            }
            closedir(dir);
        }
        g_list_req  = false;
        g_list_done = true;
    }

    for (int v = 0; v < NDRV; v++)
        serve_drive(v);
    for (int u = 0; u < NHDD; u++)
        serve_hdd(u);
}

/* ---- menu accessors (see disk.h) ----------------------------------------- */
void disk_get_floppy_info(int v, disk_info_t *out)
{
    memset(out, 0, sizeof(*out));
    if (v < 0 || v >= NDRV)
        return;
    out->mounted  = g_mounted[v];
    out->writable = g_writable[v];
    {   /* display the basename (paths can exceed the label width) */
        const char *n = g_imgname[v][0] ? disp(g_imgname[v]) : "";
        const char *slash = strrchr(n, '/');
        snprintf(out->name, sizeof(out->name), "%s", slash ? slash + 1 : n);
    }
    if (g_mounted[v])
        snprintf(out->detail, sizeof(out->detail), "%s %s",
                 g_fmt[v] == FMT_NIB ? "NIB" :
                 (g_order[v] == GCR_ORDER_PRODOS ? "PO" : "DSK"),
                 g_writable[v] ? "RW" : "RO");
}

void disk_get_hdd_info(int u, disk_info_t *out)
{
    memset(out, 0, sizeof(*out));
    if (u < 0 || u >= NHDD)
        return;
    out->mounted  = g_hdd_mounted[u];
    out->writable = g_hdd_writable[u];
    {
        const char *n = g_hdd_name[u][0] ? disp(g_hdd_name[u]) : "";
        const char *slash = strrchr(n, '/');
        snprintf(out->name, sizeof(out->name), "%s", slash ? slash + 1 : n);
    }
    if (g_hdd_mounted[u])
        snprintf(out->detail, sizeof(out->detail), "%luBLK %s",
                 (unsigned long)g_hdd_blocks[u],
                 g_hdd_writable[u] ? "RW" : "RO");
}

bool disk_backend_is_usb(void)
{
    return false;   /* SD card is the only storage backend on the a2mega */
}

bool disk_remount_pending(void)
{
    return g_remount_req || g_remounting;
}

void disk_list_begin(const char *path, const char *const *exts)
{
    g_list_done = false;
    g_list_exts = exts;
    snprintf(g_list_path, sizeof(g_list_path), SD_ROOT "/%s",
             path ? path : "");
    g_list_req  = true;           /* serviced by the next disk_poll */
}

int disk_list_poll(disk_list_ent_t *ents, int max)
{
    if (!g_list_done)
        return -1;
    int n = g_list_count < max ? g_list_count : max;
    memcpy(ents, g_list_ents, (size_t)n * sizeof(disk_list_ent_t));
    return n;
}
