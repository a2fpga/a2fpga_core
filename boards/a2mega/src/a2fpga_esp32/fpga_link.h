// fpga_link.h
// Thread-safe FPGA link layer: wraps the a2spi Octal SPI service with a
// recursive mutex and adds the small helpers the ported a2n20v2-Enhanced
// firmware modules (menu, disk, w5100 bridge) code against.
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "a2fpga_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

// Initialize (after a2spi_init_once). Creates the lock, probes the device ID,
// reads STATUS once (which latches "MCU alive" in the FPGA). Returns true if
// the FPGA responded with the "A2FP" ID.
bool fpga_link_init(void);
bool fpga_link_ok(void);

// Locked register access (returns 0 / 0xFF-safe defaults on link errors)
uint8_t fpga_reg_read(uint8_t reg);
void    fpga_reg_write(uint8_t reg, uint8_t val);
uint32_t fpga_reg_read32(uint8_t reg_base);   // 4 consecutive regs, LE
void    fpga_reg_write16(uint8_t reg_base, uint16_t val);
void    fpga_reg_write32(uint8_t reg_base, uint32_t val);

// Locked XFER access (auto-increment)
bool fpga_mem_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len);
bool fpga_mem_read(uint8_t space, uint32_t addr, uint8_t *out, uint16_t len);

// Hold the lock across a compound sequence (recursive)
void fpga_link_lock(void);
void fpga_link_unlock(void);

// ---------------------------------------------------------------------------
// Gamepad state (polled from the FPGA usb_hid_host readback regs)
// ---------------------------------------------------------------------------
typedef struct {
    bool     present;      // a HID device is attached
    bool     is_pad;       // last report came from a gamepad
    uint16_t buttons;      // A2PAD_* bitmask
    uint8_t  report_cnt;   // 4-bit counter, increments per report
} fpga_pad_state_t;

void fpga_pad_poll(fpga_pad_state_t *out);

#ifdef __cplusplus
}
#endif
