/*
 * fwupdate — MCU firmware self-update from the storage volume.
 *
 * The firmware executes in place from flash (XIP) at 0x40000, so it cannot
 * simply overwrite itself. Update is two-phase:
 *
 *   STAGE   (safe, incremental, runs in the disk thread): the selected .bin
 *           is copied from the FatFS volume into an unused flash region at
 *           FWU_STAGE_ADDR, one 4 KB chunk per disk_poll() so disk serving
 *           keeps running; the image header is sanity-checked (Bouffalo
 *           "BFNP" bootheader, same magic as the installed app) and the
 *           staged copy is CRC-verified against the file. A power loss here
 *           is harmless — the running app is untouched.
 *
 *   COMMIT  (the point of no return, ~10 s): a TCM-resident loop with
 *           interrupts disabled copies the staged image over the app region
 *           (flash-read -> erase -> write per 4 KB; nothing executes from
 *           XIP), verifies by CRC with one full retry, and jumps to the new
 *           image only if the CRC passed; otherwise it halts with an error
 *           marker on the DebugOverlay rather than boot a corrupt image.
 *           Progress and any trap during the window are painted on the
 *           overlay scratch regs (encoding documented in fwupdate.c). If
 *           power is lost in this window the app region is corrupt, but
 *           Sipeed's Stage-1 bootloader at 0x0 is untouched: the board still
 *           enumerates for PC recovery and the UPDATE-button boot mode
 *           always works.
 *
 * Driven by the menu (FIRMWARE UPDATE screen); fwupdate_poll() must be
 * called from the disk thread (FatFS owner).
 */
#ifndef _FWUPDATE_H
#define _FWUPDATE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    FWU_IDLE = 0,
    FWU_STAGING,     /* copying file -> staging flash        */
    FWU_VERIFYING,   /* CRC read-back of the staged image    */
    FWU_STAGED,      /* verified, ready to install           */
    FWU_COMMIT_REQ,  /* install requested; disk thread runs it */
    FWU_ERROR,
} fwu_state_t;

/* Begin staging a firmware file (path relative to the volume root, no
 * "0:/" prefix). Returns false if an update is already in progress. */
bool fwupdate_request(const char *path);

/* Install the staged image and reboot. Only valid in FWU_STAGED. */
void fwupdate_commit(void);

/* Abandon a staged/errored update. */
void fwupdate_cancel(void);

fwu_state_t fwupdate_state(void);
int         fwupdate_progress(void);            /* percent, current phase */
const char *fwupdate_message(void);             /* one-line status/error  */

/* True once per state/progress change (menu auto-refresh edge). */
bool fwupdate_dirty(void);

/* Service the state machine. Call from the disk thread only. */
void fwupdate_poll(void);

/* Flash base the RUNNING image boots from (0x0 standalone, 0x40000
 * chain-loaded), derived from the XIP image offset Stage 1 programmed.
 * The self-update installs to this address. */
uint32_t fwupdate_app_base(void);

/* Request a firmware restart (jump to app entry). Executed by the disk
 * thread on its next poll — menu actions run in the USB poll context and
 * must not tear down the USB stack from a thread it owns. */
void fwupdate_request_restart(void);

/* Restart the firmware WITHOUT a chip reset (no reset source fires on the
 * fused boards — see the README): invalidate the caches and jump to the app
 * entry point at the XIP base. Stage-1's XIP mapping (and the fused-board
 * decrypt configuration) is already set up and remains valid, so the app in
 * flash — including one just written by the updater — boots as if freshly
 * chain-loaded and re-initializes all peripherals. Callers should quiesce
 * DMA masters first (usbh_deinitialize). Never returns. TCM-resident. */
void fwupdate_restart_app(void);

#endif
