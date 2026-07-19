/* boot_timeline.h -- boot-milestone timeline instrumentation.
 *
 * Records, for each boot milestone, the FPGA free-running counter (sys_time,
 * regs 0x08-0x0B, 32-bit LE, +1 per FPGA clk = 54 MHz, zeroed at FPGA
 * config-done) plus the BL616 mtimer. This turns the perceptual "firmware idle
 * for a while after config" into hard numbers: elapsed-since-config per stage.
 *
 * bt_mark() is first-write-wins per stage, so it is safe to call from a poll
 * loop. Printed over telnet with the 'b' command (telnetd.c). */
#ifndef BOOT_TIMELINE_H
#define BOOT_TIMELINE_H

#include <stdint.h>

typedef enum {
    BT_FPGA_READY = 0,   /* fpga_spi_wait_ready() returned (config + SDRAM ready) */
    BT_A2BUS_READY,      /* REG_A2BUS_READY (0x30) written -> FPGA grabs Apple /RES */
    BT_SLOTS_APPLIED,    /* slot map written + 0x6B strobed -> /RES may release    */
    BT_MOUNT_FOUND,      /* first storage volume mounted (any floppy/HDD)          */
    BT_RST_WRITE,        /* A2_RST_RELEASE (0x2E) write first issued               */
    BT_RST_RELEASED,     /* reg 0x06 bit5 (A2BUS_RESET_N) observed high = released */
    BT_COUNT
} bt_stage_t;

/* Capture FPGA sys_time + MCU mtimer for `stage` (first call per stage wins). */
void bt_mark(bt_stage_t stage);

/* True once BT_RST_RELEASED has been recorded (so the poll loop can stop
 * re-reading the status reg). */
int  bt_reset_released(void);

/* Format the timeline table into buf; returns bytes written (< buflen). */
int  bt_format(char *buf, int buflen);

#endif /* BOOT_TIMELINE_H */
