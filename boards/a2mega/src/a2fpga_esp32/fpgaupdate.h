// fpgaupdate.h
// FPGA bitstream self-update from the SD card (menu "FPGA UPDATE").
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    FPU_IDLE = 0,
    FPU_CHECKING,      // validating the picked file
    FPU_READY,         // file verified, waiting for user confirm
    FPU_INSTALL_REQ,   // user confirmed, install on next poll
    FPU_ERROR
} fpu_state_t;

// Start a check of /sdcard/<path>. Returns false if a check/install is
// already in flight.
bool fpgaupdate_request(const char *path);

// Confirm installation of the verified file (FPU_READY -> FPU_INSTALL_REQ).
void fpgaupdate_commit(void);

// Cancel from FPU_READY / FPU_ERROR back to idle.
void fpgaupdate_cancel(void);

fpu_state_t fpgaupdate_state(void);
const char *fpgaupdate_message(void);
bool fpgaupdate_dirty(void);

// Drive the state machine; call from the main loop task (NOT from the menu
// tick — the install blocks for minutes).
void fpgaupdate_poll(void);

#ifdef __cplusplus
}
#endif
