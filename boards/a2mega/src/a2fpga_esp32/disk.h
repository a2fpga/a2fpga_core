/*
 * disk.h — Apple II Disk II / ProDOS HDD image serving (track/block-on-demand)
 * for the a2mega ESP32 build.
 *
 * The FPGA Disk II controller (hdl/disk/drive_ii.sv) keeps only the track the
 * head is currently over resident in a BSRAM window inside the OSPI connector
 * (XFER SPACE 4). On a seek it raises a per-drive read request over the
 * drive_volume_if block protocol (exposed by esp32_ospi_connector as volume
 * registers 0x40-0x5F). This module opens disk images on the SD card
 * (mounted at /sdcard via VFS) and services those requests: it reads the
 * requested track from the file and streams it into the FPGA track window,
 * then acknowledges. ProDOS HDD units (hdl/disk/hdd.sv) are served the same
 * way, one 512-byte block at a time through XFER SPACE 5.
 *
 * Supports read (track load) and write (dirty-track flush) when the image
 * opens read-write; falls back to read-only for write-protected images.
 *
 * Public API is kept identical to the a2n20v2-Enhanced BL616 firmware_host
 * disk.h so the ported menu links unchanged.
 */

#ifndef _DISK_H
#define _DISK_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Prepare the module (settings_init() must have run; the SD card must already
 * be mounted at /sdcard). The first disk_poll() performs the initial mount. */
void disk_init(void);

/* Service any pending track/block requests for all drives/units. Call
 * repeatedly from a dedicated task (~2 ms cadence). Never blocks. */
void disk_poll(void);

/* Request a re-mount on the next poll (e.g. after the menu changes an image
 * selection or the SD card is re-inserted). Safe to call from other tasks. */
void disk_request_remount(void);

/* ---- menu accessors ------------------------------------------------------ */

typedef struct {
    bool mounted;
    bool writable;
    char name[32];     /* image filename (no /sdcard prefix), or "" */
    char detail[16];   /* short format/size tag, e.g. "DSK RW", "65535 BLK" */
} disk_info_t;

/* Snapshot mount state for floppy drive v (0/1) or HDD unit u (0/1). */
void disk_get_floppy_info(int v, disk_info_t *out);
void disk_get_hdd_info(int u, disk_info_t *out);

/* Storage backend query, kept for menu compatibility with the BL616 build.
 * The a2mega serves images from the SD card only, so this is always false. */
bool disk_backend_is_usb(void);

/* True while a requested remount has not finished yet. */
bool disk_remount_pending(void);

/* Async directory listing (all filesystem access runs in the disk task so
 * stdio/VFS state stays single-threaded). Begin posts a request for one
 * directory (path relative to the SD root, "" = root); poll returns -1 while
 * pending, else the number of entries filled. Directories are always included
 * (is_dir set); files are filtered by exts, a NULL-terminated list of
 * extensions (no dot, case-insensitive). Directories sort before files. */
#define DISK_LIST_MAX 24
typedef struct {
    char name[64];   /* entry name within the directory (LFN; longer skipped) */
    bool is_dir;
} disk_list_ent_t;
void disk_list_begin(const char *path, const char *const *exts);
int  disk_list_poll(disk_list_ent_t *ents, int max);

#ifdef __cplusplus
}
#endif

#endif
