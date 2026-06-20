/*
 * JTAG MPSSE state machine — bitbang via BL616 GPIO registers.
 */

#ifndef _JTAG_PROCESS_H
#define _JTAG_PROCESS_H

#include <stdint.h>

void jtag_gpio_init(void);
void jtag_init(void);
void jtag_process(void);
void jtag_idle(void);
void jtag_purge(void);

/* Call after USB configured to arm endpoints and send initial status */
void jtag_start(void);

/* USB endpoint callbacks for JTAG interface */
void jtag_bulk_out_cb(uint8_t busid, uint8_t ep, uint32_t nbytes);
void jtag_bulk_in_cb(uint8_t busid, uint8_t ep, uint32_t nbytes);

#endif
