/*
 * disk.h — Apple II Disk II image serving (track-on-demand) for the host build.
 *
 * The FPGA Disk II controller (hdl/disk/drive_ii.sv) keeps only the track the
 * head is currently over resident in a small SDRAM window. On a seek it raises
 * a per-drive read request over the drive_volume_if block protocol (exposed by
 * bl616_spi_connector as SPI volume registers 0x40-0x5F). This module mounts the
 * SD card, opens .nib disk images, and services those requests: it reads the
 * requested track from the file and DMAs it into the FPGA SDRAM track window via
 * XFER SPACE 1, then acknowledges.
 *
 * Supports read (track load) and write (dirty-track flush) when the image opens
 * read-write; falls back to read-only for write-protected images.
 */

#ifndef _DISK_H
#define _DISK_H

/* Mount the SD card and open the disk images. Call once before disk_poll(). */
void disk_init(void);

/* Service any pending track requests for both drives. Call repeatedly. */
void disk_poll(void);

/* Request a re-mount on the next poll (e.g. after a USB stick is attached or
 * removed). Safe to call from the USB host thread. */
void disk_request_remount(void);

/* ---- menu accessors ------------------------------------------------------ */
#include <stdbool.h>

typedef struct {
    bool mounted;
    bool writable;
    char name[32];     /* image filename (no volume prefix), or "" */
    char detail[16];   /* short format/size tag, e.g. "DSK RW", "65535 BLK" */
} disk_info_t;

/* Snapshot mount state for floppy drive v (0/1) or HDD unit u (0/1). */
void disk_get_floppy_info(int v, disk_info_t *out);
void disk_get_hdd_info(int u, disk_info_t *out);

/* True when the current FatFS backend is the USB stick (vs SD card). */
bool disk_backend_is_usb(void);

/* True while a requested remount has not finished yet. */
bool disk_remount_pending(void);

/* Async directory listing (FatFS is NOT re-entrant — FF_FS_REENTRANT=0 — so
 * all filesystem access must run in the disk thread). Begin posts a request
 * for one directory (path relative to the volume root, "" = root); poll
 * returns -1 while pending, else the number of entries filled. Directories
 * are always included (is_dir set); files are filtered by exts, a
 * NULL-terminated list of extensions (no dot, case-insensitive).
 * Directories sort before files. */
#define DISK_LIST_MAX 24
typedef struct {
    char name[40];   /* entry name within the directory */
    bool is_dir;
} disk_list_ent_t;
void disk_list_begin(const char *path, const char *const *exts);
int  disk_list_poll(disk_list_ent_t *ents, int max);

#endif
