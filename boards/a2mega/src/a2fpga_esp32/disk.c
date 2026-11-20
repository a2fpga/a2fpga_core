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
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"    /* esp_timer_get_time — us since boot */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h" /* quiesce handshake with the disk task */

#include "a2fpga_regs.h"
#include "fpga_link.h"
#include "gcr_dsk.h"      /* on-the-fly .dsk/.do <-> 6-and-2 GCR nibble codec */

/* .ino: releases the ESP32-driven Apple /RES (no-op where the FPGA owns it) */
void a2_reset_hold_release(const char *why);
#include "usbstorage.h"   /* USB stick as the image volume (backend switch) */
#include "settings.h"     /* persisted image overrides + slot map */
#include "audio_ctl.h"    /* Mockingboard level, applied with the slot map */
#include "disk.h"
#include "gs_socket.h"

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
static uint32_t    g_bytes[NDRV];                /* payload length at mount     */
static uint32_t    g_fsize[NDRV];                /* whole file size at mount    */
static uint32_t    g_wr_fail[NDRV];              /* write/sync failures so far  */
static char        g_imgname[NDRV][PATH_MAX_LEN];/* resolved image path         */
/* 6.5 KB nibble track + 4 KB sector track: filled by fread (the USB MSC path
 * copies out of its own transfer buffers) and the GCR code, written to the
 * FPGA in 512-byte SPI chunks (the SPI master bounces non-DMA sources through
 * a temporary internal buffer) -> PSRAM, allocated in disk_init (heap diet). */
static uint8_t    *g_trackbuf;                   /* nibble track (FPGA window)  */
static uint8_t    *g_secbuf;                     /* one sector track (16*256)   */

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
static uint32_t g_hdd_fsize[NHDD];      /* whole file size at mount      */
static uint32_t g_hdd_wr_fail[NHDD];    /* write/sync failures so far    */
static char     g_hdd_name[NHDD][PATH_MAX_LEN];
static uint8_t  g_blockbuf[SECTOR_BYTES];

/* Menu directory-listing request (see disk_list_begin/poll in disk.h). */
static volatile bool          g_list_req;
static volatile bool          g_list_done;
static const char *const     *g_list_exts;
static char                   g_list_path[PATH_MAX_LEN];
static disk_list_ent_t       *g_list_ents;     /* DISK_LIST_MAX entries, PSRAM (disk_init) */
static bool                   g_a2_released;

bool disk_a2_released(void) { return g_a2_released; }
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

/* Case-insensitive name compare for the directory listing sort. */
static int name_cmp(const char *a, const char *b)
{
    while (*a && *b) {
        int ca = *a | 0x20, cb = *b | 0x20;
        if (ca != cb)
            return ca - cb;
        a++; b++;
    }
    return (*a & 0xff) - (*b & 0xff);
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

/* ---- image size plausibility ----------------------------------------------
 * A directory entry's size field is the one number the firmware takes on
 * trust, and a failing stick can hand back a corrupt one (the 11-17 stick's
 * disk1.nib entry read 4 GB). Every seek is bounded by the mounted size, so
 * a corrupt size would let requests past the real data through: refuse to
 * mount an image whose size is not one a real image has.
 *   .nib            35 or 40 tracks x 6656 B
 *   .dsk/.do/.po    35 or 40 tracks x 4096 B (16 x 256)
 *   HDD .hdv/.po    a whole number of 512 B blocks, 1 block .. 32 MiB
 *                   (hdd.sv addresses 16-bit block numbers; ProDOS stops at
 *                   65535, so nothing beyond 32 MiB is reachable anyway)
 *   .2mg            header payload length must also fit inside the file */
#define NIB_TRACK_BYTES  MAX_TRACK_BYTES               /* 6656 */
#define HDD_MAX_BYTES    (32u * 1024u * 1024u)

static bool floppy_size_ok(disk_fmt_t fmt, uint32_t bytes)
{
    if (fmt == FMT_NIB)
        return bytes == 35u * NIB_TRACK_BYTES || bytes == 40u * NIB_TRACK_BYTES;
    if (fmt == FMT_DSK)
        return bytes == 35u * DSK_TRACK_BYTES || bytes == 40u * DSK_TRACK_BYTES;
    return false;
}

static bool hdd_size_ok(uint32_t bytes)
{
    return bytes >= SECTOR_BYTES && bytes <= HDD_MAX_BYTES &&
           (bytes % SECTOR_BYTES) == 0;
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

/* Flush stdio buffers and push the data to the volume. Returns false if
 * either step failed (stick gone, write error) so the caller can log it;
 * the volume protocol has no error channel back to the card, so the Apple
 * still sees the block as written — the log is the only evidence. */
static bool image_sync(FILE *f)
{
    bool ok = (fflush(f) == 0);
    if (fsync(fileno(f)) != 0)
        ok = false;
    return ok;
}

static void mount_drive(int v)
{
    g_mounted[v]  = false;
    g_writable[v] = false;
    g_fmt[v]      = FMT_NONE;
    g_order[v]    = GCR_ORDER_DOS;
    g_base[v]     = 0;
    g_bytes[v]    = 0;
    g_fsize[v]    = 0;
    g_wr_fail[v]  = 0;
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
        uint32_t    fsize = file_size(f);
        uint32_t    bytes = fsize;

        if (has_ext(name, "2mg")) {
            uint32_t paylen = 0;
            fmt = parse_2mg(f, &order, &base, &paylen);
            if (fmt != FMT_NONE && (base > fsize || paylen > fsize - base)) {
                DLOGW("DISK II: D%d %s 2MG HEADER EXCEEDS FILE (%lu+%lu > %lu) - skip",
                      v + 1, disp(name), (unsigned long)base,
                      (unsigned long)paylen, (unsigned long)fsize);
                fmt = FMT_NONE;
            }
            if (paylen)
                bytes = paylen;
            else if (bytes > base)
                bytes -= base;
            /* Only floppy-size payloads are Disk II volumes; larger 2mg images
             * are block devices and belong to the hard-disk path. */
            if (fmt == FMT_DSK && !floppy_size_ok(FMT_DSK, bytes)) {
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
        if (!floppy_size_ok(fmt, bytes)) {
            /* Not a size a real image has: a corrupt directory entry (a
             * failing stick) or a damaged file. Serving it would let requests
             * past the real data through. Refuse, loudly. */
            osd_console_show();
            DLOGW("DISK II: D%d %s SIZE %lu B IMPLAUSIBLE - NOT MOUNTED",
                  v + 1, disp(name), (unsigned long)bytes);
            fclose(f);
            continue;
        }

        g_img[v]      = f;
        g_writable[v] = rw;
        g_fmt[v]      = fmt;
        g_order[v]    = order;
        g_base[v]     = base;
        g_bytes[v]    = bytes;   /* every seek is bounded by this (see serve_drive) */
        g_fsize[v]    = fsize;   /* re-checked after any write failure (see check_image) */
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
    g_hdd_fsize[u]    = 0;
    g_hdd_wr_fail[u]  = 0;
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
        uint32_t fsize = file_size(f);
        uint32_t bytes = fsize;

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
            if (base > fsize || paylen > fsize - base) {
                DLOGW("HDD: UNIT %d %s 2MG HEADER EXCEEDS FILE - skip",
                      u + 1, disp(name));
                fclose(f);
                continue;
            }
            if (paylen)
                bytes = paylen;
            else
                bytes -= base;
        }
        /* .hdv / .po: raw ProDOS blocks from byte 0 */

        if (!hdd_size_ok(bytes)) {
            /* Not a whole number of blocks, or past what a 16-bit block
             * number can reach: a corrupt directory entry or a damaged file.
             * Refuse rather than serve a size we cannot trust. */
            osd_console_show();
            DLOGW("HDD: UNIT %d %s SIZE %lu B IMPLAUSIBLE - NOT MOUNTED",
                  u + 1, disp(name), (unsigned long)bytes);
            fclose(f);
            continue;
        }
        uint32_t blocks = bytes / SECTOR_BYTES;
        if (blocks > 0xFFFFu)
            blocks = 0xFFFFu;   /* ProDOS volumes cap at 65535 blocks (32 MB) */

        g_hdd_img[u]      = f;
        g_hdd_writable[u] = rw;
        g_hdd_base[u]     = base;
        g_hdd_blocks[u]   = blocks;
        g_hdd_fsize[u]    = fsize;
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

/* ---- quiesce: stop serving and close every image --------------------------
 * The FPGA is about to go away (JTAG flash entry, bitstream reload, RECONFIG)
 * or the ESP32 is about to restart. Either way no file may be open and no
 * request may be serviced until a remount is asked for: an unconfigured
 * FPGA answers register reads with bus junk, and on 2026-11-17 a junk "write
 * pending" with a junk lba made this task seek 4 GB past the end of a .nib
 * and FatFS extended the file into the stick's directory (see
 * boards/a2p25/docs/STICK_CORRUPTION_2026-11-17.md). The files belong to
 * the disk task, so another task asks and waits for the close to happen in
 * disk_poll(); the disk task itself (fpgaupdate/fwupdate run in it) closes
 * inline. */
static volatile bool g_quiesce_req = false;
static volatile bool g_quiesced    = false;
static TaskHandle_t  g_owner_task  = NULL;   /* the task that runs disk_poll */
static void disk_unmount_all(void);

static void do_quiesce(void)
{
    disk_unmount_all();
    g_hide_console_at_us = 0;
    g_quiesced = true;
}

void disk_quiesce(void)
{
    g_remount_req = false;              /* a pending remount must not reopen */
    if (g_quiesced)
        return;
    if (g_owner_task == NULL || xTaskGetCurrentTaskHandle() == g_owner_task) {
        do_quiesce();
        return;
    }
    g_quiesce_req = true;
    for (int i = 0; i < 250 && !g_quiesced; i++)   /* ~500 ms; a serve is ms */
        vTaskDelay(pdMS_TO_TICKS(2));
    if (!g_quiesced) {
        /* The disk task is not running (suspended, or wedged on the link):
         * close from here rather than restart with the files open. */
        DLOGW("DISK: QUIESCE TIMEOUT - CLOSING IMAGES FROM %s",
              pcTaskGetName(NULL));
        g_quiesce_req = false;
        do_quiesce();
    }
}

bool disk_quiesced(void)
{
    return g_quiesced;
}

void disk_release_storage(void)
{
    disk_quiesce();
    usbstorage_unmount();   /* no-op when the stick is not the volume */
    DLOGI("DISK: IMAGES CLOSED, STORAGE RELEASED");
}

/* ---- Disk II (re)mount, logged to the shared OSD console -------------------
 * Mount status is appended to the boot console (osd_console). The console is
 * shown while we look for the image(s); on a successful mount we hide it so the
 * screen returns to the Apple II, and on failure we leave it up so the message
 * can be read. */
/* Close every image and clear the FPGA mounted/ready flags (the disk task
 * owns these files; the storage backend may be swapped afterwards). */
static void disk_unmount_all(void)
{
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
}

static const char *storage_name(void) { return usbstorage_is_usb() ? "USB STICK" : "FLASH FS"; }

static void disk_remount(void)
{
    osd_console_show();
    DLOGI("DISK II: SEARCHING FOR STORAGE...");
    disk_unmount_all();
    /* Volume present? The VFS mount is owned by the integrator; probe it. */
    DIR *root = opendir(SD_ROOT);
    if (!root) {
        DLOGW("DISK II: NO SD CARD (%s NOT MOUNTED)", SD_ROOT);
        DLOGI("DISK II: INSERT SD CARD WITH DISK1.DSK/.NIB");
        return;   /* leave the console up so the message is visible */
    }
    closedir(root);
    DLOGI("DISK II: %s", storage_name());

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
        DLOGI("DISK II: NO DISK IMAGES ON %s", storage_name());
        /* leave the console up so the message is visible */
    }
}

void disk_init(void)
{
    /* 8 KB directory listing: pure-CPU data, so it lives in PSRAM and
     * leaves the internal heap to USB/WiFi/BLE (a2p25 heap diet 11-19) */
    if (!g_list_ents) {
        g_list_ents = (disk_list_ent_t *)heap_caps_calloc(DISK_LIST_MAX, sizeof(disk_list_ent_t), MALLOC_CAP_SPIRAM);
        if (!g_list_ents) g_list_ents = (disk_list_ent_t *)calloc(DISK_LIST_MAX, sizeof(disk_list_ent_t));
    }
    if (!g_trackbuf) {
        g_trackbuf = (uint8_t *)heap_caps_malloc(MAX_TRACK_BYTES, MALLOC_CAP_SPIRAM);
        if (!g_trackbuf) g_trackbuf = (uint8_t *)malloc(MAX_TRACK_BYTES);
    }
    if (!g_secbuf) {
        g_secbuf = (uint8_t *)heap_caps_malloc(DSK_TRACK_BYTES, MALLOC_CAP_SPIRAM);
        if (!g_secbuf) g_secbuf = (uint8_t *)malloc(DSK_TRACK_BYTES);
    }
    /* Nothing to bring up here: settings_init() and the SD/VFS mount are the
     * integrator's job; the first disk_poll() performs the initial mount. */
    g_remount_req = true;
}

/* ---- media errors -----------------------------------------------------------
 * The volume protocol has no error channel back to the Apple: a failed
 * fwrite/fflush/fsync used to be one DLOGW line and the block counted as
 * written. The 11-17 stick failed as hardware (reads fell to 100 KB/s, then
 * it would not reformat), so a write failure is now (1) counted per volume
 * and shown on the OSD console the first time and every WR_FAIL_EVERY
 * failures, and (2) followed by a re-check of the image: fstat() of the open
 * file (FatFS's in-memory size) and stat() of the path (the directory entry
 * re-read from the medium) against the size measured at mount. A size that
 * moved, or a medium that cannot be read, turns the volume read-only — the
 * FPGA is told (VOL_READONLY / HDD_CTL) so the Apple sees a write-protected
 * disk from then on — and the OSD says so. */
#define WR_FAIL_EVERY 10u

/* True when the file still has its mount-time size on the medium and in the
 * open handle; *why names the first discrepancy otherwise. */
static bool image_size_intact(FILE *f, const char *path, uint32_t fsize,
                              const char **why, uint32_t *seen)
{
    struct stat st;
    *seen = 0;
    if (fstat(fileno(f), &st) != 0) {
        *why = "FSTAT FAILED";
        return false;
    }
    if ((uint32_t)st.st_size != fsize) {
        *why = "OPEN FILE SIZE CHANGED";
        *seen = (uint32_t)st.st_size;
        return false;
    }
    if (stat(path, &st) != 0) {
        *why = "DIRECTORY ENTRY UNREADABLE";
        return false;
    }
    if ((uint32_t)st.st_size != fsize) {
        *why = "DIRECTORY SIZE CHANGED";
        *seen = (uint32_t)st.st_size;
        return false;
    }
    return true;
}

/* Disk II drive v: count a write/sync failure, report, re-check, demote. */
static void drive_write_failed(int v, uint32_t track, const char *what)
{
    int err = errno;
    uint32_t n = ++g_wr_fail[v];
    if (n == 1 || (n % WR_FAIL_EVERY) == 0) {
        osd_console_show();
        DLOGW("DISK II: D%d TRK%lu %s FAILED (errno %d) - %lu FAILURES",
              v + 1, (unsigned long)track, what, err, (unsigned long)n);
    }
    if (!g_writable[v])
        return;
    const char *why; uint32_t seen;
    if (!image_size_intact(g_img[v], g_imgname[v], g_fsize[v], &why, &seen)) {
        g_writable[v] = false;
        fpga_reg_write(A2REG_VOL_READONLY(v), 1);
        osd_console_show();
        DLOGW("DISK II: D%d %s (%lu -> %lu) - NOW READ-ONLY", v + 1, why,
              (unsigned long)g_fsize[v], (unsigned long)seen);
    }
}

/* HDD unit u: the same for a block write. */
static void hdd_write_failed(int u, uint32_t lba, const char *what)
{
    int err = errno;
    uint32_t n = ++g_hdd_wr_fail[u];
    if (n == 1 || (n % WR_FAIL_EVERY) == 0) {
        osd_console_show();
        DLOGW("HDD: UNIT %d BLK %lu %s FAILED (errno %d) - %lu FAILURES",
              u + 1, (unsigned long)lba, what, err, (unsigned long)n);
    }
    if (!g_hdd_writable[u])
        return;
    const char *why; uint32_t seen;
    if (!image_size_intact(g_hdd_img[u], g_hdd_name[u], g_hdd_fsize[u],
                           &why, &seen)) {
        g_hdd_writable[u] = false;
        fpga_reg_write(A2REG_HDD_CTL(u), A2HDD_CTL_READY | A2HDD_CTL_MOUNTED |
                                         A2HDD_CTL_READONLY);
        osd_console_show();
        DLOGW("HDD: UNIT %d %s (%lu -> %lu) - NOW READ-ONLY", u + 1, why,
              (unsigned long)g_hdd_fsize[u], (unsigned long)seen);
    }
}

/* ---- request validation ---------------------------------------------------
 * A request is served only when (a) every register of it came back in a
 * valid OSPI frame AND the FPGA still answers its device ID — an
 * unconfigured or reloading chip returns bus junk, which read as "write
 * pending, lba 0x7EFF0B" on 2026-11-17 — and (b) the file position it
 * implies lies inside the image as measured at mount. A request that fails
 * (a) is left pending (the fabric is gone; a remount follows the reload).
 * One that fails (b) is logged, never seeked, and acknowledged so the drive
 * is not stuck (the protocol has no error channel; a bad read returns a
 * zero track, like a short image). */
static bool s_link_down_noted;

static void note_link_down(const char *who)
{
    if (!s_link_down_noted) {
        s_link_down_noted = true;
        DLOGW("%s: FPGA LINK INVALID - REQUEST IGNORED", who);
    }
}

/* Read a pending request's registers with frame checks and a device-ID
 * probe. Returns false (and leaves the request pending) if the link is not
 * trustworthy. */
static bool read_request_ok(const char *who, uint8_t cmd_reg, uint8_t *cmd)
{
    if (!fpga_reg_read_checked(cmd_reg, cmd)) {
        note_link_down(who);
        return false;
    }
    if (*cmd == 0)
        return true;              /* nothing pending: no probe needed */
    if (!fpga_link_probe()) {    /* a real request comes from a live fabric */
        note_link_down(who);
        *cmd = 0;
        return false;
    }
    if (s_link_down_noted) {
        s_link_down_noted = false;
        DLOGI("%s: FPGA LINK BACK", who);
    }
    return true;
}

static void serve_drive(int v)
{
    if (!g_mounted[v])
        return;

    uint8_t cmd = 0;
    if (!read_request_ok("DISK II", A2REG_VOL_CMD(v), &cmd))
        return;
    bool rd = (cmd & A2VOL_CMD_RD) != 0;
    bool wr = (cmd & A2VOL_CMD_WR) != 0;
    if (!rd && !wr)
        return;   /* nothing pending */

    uint32_t lba = 0;
    uint8_t  blk = 0;
    if (!fpga_reg_read32_checked(A2REG_VOL_LBA0(v), &lba) ||
        !fpga_reg_read_checked(A2REG_VOL_BLK_CNT(v), &blk)) {
        note_link_down("DISK II");
        return;
    }
    /* The request is read as six separate OSPI transactions. On the FPGA the
     * lba is combinational from the track registers and only moves on our
     * ack — or on system_reset_n, which includes the Apple's /RES: a reset
     * between the CMD read and the lba read drops the request (save_req_r,
     * load_req_r, dirty_r clear; req_track_r = 0) and the lba we then read is
     * 0 for a write we still believe in, i.e. the old dirty track's nibbles
     * would land on track 0. Read the pair again and require agreement; a
     * request that moved is left for the next poll. */
    {
        uint8_t  cmd2 = 0;
        uint32_t lba2 = 0;
        if (!fpga_reg_read_checked(A2REG_VOL_CMD(v), &cmd2) ||
            !fpga_reg_read32_checked(A2REG_VOL_LBA0(v), &lba2)) {
            note_link_down("DISK II");
            return;
        }
        if (cmd2 != cmd || lba2 != lba) {
            DLOGW("DISK II: D%d REQUEST CHANGED UNDER US (%02X/%lu -> %02X/%lu) - RETRY",
                  v + 1, cmd, (unsigned long)lba, cmd2, (unsigned long)lba2);
            return;
        }
    }
    uint32_t nblk  = (uint32_t)blk + 1u;
    uint32_t nbyte = nblk * SECTOR_BYTES;
    if (nbyte > MAX_TRACK_BYTES)
        nbyte = MAX_TRACK_BYTES;

    uint32_t addr = A2DISK_WINDOW(v);

    /* Bounds against the image as mounted. The FPGA asks for whole tracks
     * (lba = track * 13, 13 blocks); the file position is computed in 64
     * bits so a junk lba cannot wrap. A read may start inside the image and
     * run short (a truncated .nib keeps its zero-fill behaviour); a write
     * must fit entirely, so the file is never extended. */
    const uint64_t img_end = (uint64_t)g_base[v] + g_bytes[v];
    uint64_t fpos;
    uint64_t flen;
    if (g_fmt[v] == FMT_DSK) {
        fpos = (uint64_t)g_base[v] + (uint64_t)(lba / 13u) * DSK_TRACK_BYTES;
        flen = DSK_TRACK_BYTES;
    } else {
        fpos = (uint64_t)g_base[v] + (uint64_t)lba * SECTOR_BYTES;
        flen = nbyte;
    }
    bool in_range = (lba % 13u == 0) &&
                    (wr ? (fpos + flen <= img_end) : (fpos < img_end));
    if (!in_range) {
        static uint32_t s_last_bad[NDRV] = { 0xFFFFFFFFu, 0xFFFFFFFFu };
        if (lba != s_last_bad[v]) {
            s_last_bad[v] = lba;
            DLOGW("DISK II: D%d %s LBA %lu OUT OF RANGE (IMG %lu B) - %s",
                  v + 1, wr ? "WR" : "RD", (unsigned long)lba,
                  (unsigned long)g_bytes[v],
                  wr ? "NOT WRITTEN" : "ZERO TRACK");
        }
        if (!wr) {
            memset(g_trackbuf, 0, nbyte);
            for (uint32_t off = 0; off < nbyte; off += SECTOR_BYTES) {
                uint32_t chunk = nbyte - off;
                if (chunk > SECTOR_BYTES)
                    chunk = SECTOR_BYTES;
                fpga_mem_write(A2SPACE_DISK, addr + off,
                               g_trackbuf + off, (uint16_t)chunk);
            }
        }
        fpga_reg_write(A2REG_VOL_ACK(v), 1);   /* release the head */
        return;
    }

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
                long     tpos  = (long)fpos;   /* in range: checked above */
                size_t br = 0;
                if (fseek(g_img[v], tpos, SEEK_SET) == 0)
                    br = fread(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]);
                bool preload_ok = (br == DSK_TRACK_BYTES);   /* in range, so short = medium */
                if (!preload_ok) {
                    memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
                    drive_write_failed(v, track, "PRELOAD READ");
                }
                uint16_t mask = gcr_decode_dos_track(g_trackbuf, MAX_TRACK_BYTES,
                                                     g_order[v], g_secbuf);
                /* A partial decode keeps the preloaded bytes for the missing
                 * sectors; without a good preload those bytes are zeros, so
                 * only an all-sectors decode may be written. */
                bool may_write = (mask == 0xFFFF) || (mask != 0 && preload_ok);
                if (may_write && g_writable[v]) {
                    const char *what = "WRITE";
                    bool ok = (fseek(g_img[v], tpos, SEEK_SET) == 0) &&
                              fwrite(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]) ==
                              DSK_TRACK_BYTES;
                    if (ok && !image_sync(g_img[v])) {
                        ok = false;
                        what = "SYNC";
                    }
                    if (!ok)
                        drive_write_failed(v, track, what);
                } else if (mask != 0 && !may_write) {
                    DLOGW("DISK II: D%d TRK%lu NOT WRITTEN (PRELOAD FAILED, mask=%04X)",
                          v + 1, (unsigned long)track, (unsigned)mask);
                }
                if (mask != 0xFFFF)
                    DLOGW("DISK II: D%d TRK%lu wr partial mask=%04X",
                          v + 1, (unsigned long)track, (unsigned)mask);
            } else {
                const char *what = "WRITE";
                bool ok = (fseek(g_img[v], (long)fpos, SEEK_SET) == 0) &&   /* in range: checked above */
                          fwrite(g_trackbuf, 1, nbyte, g_img[v]) == nbyte;
                if (ok && !image_sync(g_img[v])) {
                    ok = false;
                    what = "SYNC";
                }
                if (!ok)
                    drive_write_failed(v, lba / 13u, what);
            }
        }
    } else {
        /* Load the requested track: image file -> FPGA track window. */
        uint32_t track = lba / 13u;
        if (g_fmt[v] == FMT_DSK) {
            /* Read this track's 16*256 file-order sectors and nibblize them
             * into the 6-and-2 GCR stream the window expects. */
            size_t br = 0;
            if (fseek(g_img[v], (long)fpos, SEEK_SET) == 0)   /* in range: checked above */
                br = fread(g_secbuf, 1, DSK_TRACK_BYTES, g_img[v]);
            if (br < DSK_TRACK_BYTES)
                memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
            gcr_encode_dos_track(g_secbuf, (uint8_t)track, DSK_DEFAULT_VOLUME,
                                 g_order[v], g_trackbuf, MAX_TRACK_BYTES);
        } else {
            /* .nib: raw nibble stream, streamed as-is. */
            size_t br = 0;
            if (fseek(g_img[v], (long)fpos, SEEK_SET) == 0)   /* in range: checked above */
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

    uint8_t req = 0;
    if (!read_request_ok("HDD", A2REG_HDD_REQ(u), &req))
        return;
    req &= (A2HDD_REQ_RD | A2HDD_REQ_WR);
    if (!req)
        return;   /* nothing pending */

    uint8_t lba_l = 0, lba_h = 0;
    if (!fpga_reg_read_checked(A2REG_HDD_LBA_L(u), &lba_l) ||
        !fpga_reg_read_checked(A2REG_HDD_LBA_H(u), &lba_h)) {
        note_link_down("HDD");
        return;
    }
    uint32_t lba = (uint32_t)lba_l | ((uint32_t)lba_h << 8);
    {   /* same read-twice rule as serve_drive (hdd.sv resets on /RES too) */
        uint8_t req2 = 0, l2 = 0, h2 = 0;
        if (!fpga_reg_read_checked(A2REG_HDD_REQ(u), &req2) ||
            !fpga_reg_read_checked(A2REG_HDD_LBA_L(u), &l2) ||
            !fpga_reg_read_checked(A2REG_HDD_LBA_H(u), &h2)) {
            note_link_down("HDD");
            return;
        }
        req2 &= (A2HDD_REQ_RD | A2HDD_REQ_WR);
        if (req2 != req || l2 != lba_l || h2 != lba_h) {
            DLOGW("HDD: UNIT %d REQUEST CHANGED UNDER US - RETRY", u + 1);
            return;
        }
    }
    uint32_t addr = A2HDD_WINDOW(u);
    long     fpos = (long)g_hdd_base[u] + (long)lba * (long)SECTOR_BYTES;

    /* Bounds: g_hdd_blocks is the payload length at mount (<= 65535), so a
     * block inside it is inside the file; anything else is never seeked. */
    if (lba >= g_hdd_blocks[u]) {
        static uint32_t s_last_bad[NHDD] = { 0xFFFFFFFFu, 0xFFFFFFFFu };
        if (lba != s_last_bad[u]) {
            s_last_bad[u] = lba;
            DLOGW("HDD: UNIT %d %s BLK %lu OUT OF RANGE (%lu BLK) - %s", u + 1,
                  (req & A2HDD_REQ_WR) ? "WR" : "RD", (unsigned long)lba,
                  (unsigned long)g_hdd_blocks[u],
                  (req & A2HDD_REQ_WR) ? "NOT WRITTEN" : "ZERO BLOCK");
        }
    }

    if (req & A2HDD_REQ_WR) {
        /* write: block window -> image file */
        if (g_hdd_writable[u] && lba < g_hdd_blocks[u]) {
            if (!fpga_mem_read(A2SPACE_HDD, addr, g_blockbuf, SECTOR_BYTES)) {
                /* link, not medium: the block never left the FPGA window */
                DLOGW("HDD: UNIT %d BLK %lu WINDOW READ FAILED - NOT WRITTEN",
                      u + 1, (unsigned long)lba);
            } else {
                const char *what = "WRITE";
                bool ok = (fseek(g_hdd_img[u], fpos, SEEK_SET) == 0) &&
                          fwrite(g_blockbuf, 1, SECTOR_BYTES, g_hdd_img[u]) ==
                          SECTOR_BYTES;
                if (ok && !image_sync(g_hdd_img[u])) {
                    ok = false;
                    what = "SYNC";
                }
                if (!ok)
                    hdd_write_failed(u, lba, what);
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
    if (g_owner_task == NULL)
        g_owner_task = xTaskGetCurrentTaskHandle();

    /* Quiesce (see disk_quiesce): close everything and serve nothing until
     * a remount is requested. */
    if (g_quiesce_req) {
        g_quiesce_req = false;
        do_quiesce();
    }
    if (g_quiesced) {
        if (!g_remount_req)
            return;
        g_quiesced = false;
    }

    /* Storage backend change (USB stick attached/removed, reported by
     * usbhost): close the images first — they live on the volume about to
     * be swapped — then let the integrator swap /sdcard, then remount. */
    {
        bool usb = false;
        if (usbstorage_take_pending(&usb)) {
            disk_unmount_all();
            storage_activate(usb);
            DLOGI("STORAGE: %s", usb ? "USB STICK" : "FLASH FS");
            g_remount_req = true;
        }
    }
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
        if (!g_a2_released) {
            bool any = false;
            for (int v = 0; v < NDRV; v++) any = any || g_mounted[v];
            for (int u = 0; u < NHDD; u++) any = any || g_hdd_mounted[u];
            /* 10 s (was 7): the USB host role decision takes 5 s and a stick
             * needs a moment to enumerate and mount before the Apple scans.
             * gs_socket_ready(): the in-socket 65C816 auto-arm must have
             * settled before /RES rises (bench G30; PR #34). */
            if ((any && !g_remount_req && gs_socket_ready()) ||
                esp_timer_get_time() > 10000000) {
                /* Program the slot map JUST before the release — this late in
                 * boot the link is proven good (the mounts above ran over it),
                 * and the Apple II is still held in reset so the reconfig is
                 * race-free. */
                apply_slot_map();
                audio_ctl_apply();                   /* Mockingboard level (window index 55) */

                gs_socket_a2_release();              /* 0x2E.0, via the socket module (keeps its assert bit) */
                /* boards where the ESP32 owns the /RES pin (a2p25 IO33) */
                a2_reset_hold_release(any ? "media mounted" : "no media");
                g_a2_released = true;
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
        /* Alphabetize within each group (the two passes already put
         * directories first). FAT returns creation order, which makes big
         * image folders unnavigable and hides a file past the cap depending
         * on which directory slot its entry happened to land in. Insertion
         * sort: n <= DISK_LIST_MAX. */
        for (int i = 1; i < g_list_count; i++) {
            disk_list_ent_t tmp = g_list_ents[i];
            int j = i;
            while (j > 0 && g_list_ents[j - 1].is_dir == tmp.is_dir &&
                   name_cmp(g_list_ents[j - 1].name, tmp.name) > 0) {
                g_list_ents[j] = g_list_ents[j - 1];
                j--;
            }
            g_list_ents[j] = tmp;
        }
        if (g_list_count >= DISK_LIST_MAX)
            DLOGW("DISK: listing of %s cut at %d entries", g_list_path,
                  DISK_LIST_MAX);
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
    return usbstorage_is_usb();
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
