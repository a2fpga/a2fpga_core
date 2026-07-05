/*
 * fpgaupdate — FPGA bitstream self-update from the storage volume.
 * See fpgaupdate.c for the design and safety notes.
 */
#ifndef _FPGAUPDATE_H
#define _FPGAUPDATE_H

#include <stdbool.h>

typedef enum {
    FPU_IDLE = 0,
    FPU_CHECKING,     /* validating the picked .bin (disk thread) */
    FPU_READY,        /* verified, ready to install               */
    FPU_INSTALL_REQ,  /* install requested; disk thread runs it   */
    FPU_ERROR,
} fpu_state_t;

/* Begin validating a bitstream file (path relative to the volume root). */
bool fpgaupdate_request(const char *path);

/* Erase + program + verify + reload + MCU restart. Only valid in READY.
 * The screen goes dark for the duration (~1-2 min). */
void fpgaupdate_commit(void);

void fpgaupdate_cancel(void);

fpu_state_t fpgaupdate_state(void);
const char *fpgaupdate_message(void);
bool        fpgaupdate_dirty(void);   /* true once per change (menu edge) */

/* Service the state machine. Call from the disk thread only. */
void fpgaupdate_poll(void);

#endif
