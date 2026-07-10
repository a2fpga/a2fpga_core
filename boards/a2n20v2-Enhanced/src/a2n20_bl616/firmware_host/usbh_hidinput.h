/*
 * usbh_hidinput — generic USB HID keyboard / consumer-control (remote) input
 * for the MCU menu. Class-level matching only, no VID/PID: any USB keyboard
 * or media remote works. Implements the stock CherryUSB usbh_hid_run/stop
 * hooks; see usbh_hidinput.c for the design notes.
 *
 * Key mapping (menu vocabulary, same as telnetd):
 *   arrows            -> d-pad          Enter / OK button -> OK (XINPUT_B)
 *   Esc / Backspace / AC Back -> back   Tab / Menu-key / AC Home -> Apple<->MCU
 *   Y -> menu<->console view            Vol+/Vol- ([/]) -> big +/- steps
 */
#ifndef USBH_HIDINPUT_H
#define USBH_HIDINPUT_H

#include <stdint.h>

/* Current button state from all connected HID keyboards/remotes, in the
 * XINPUT_* bit vocabulary. OR into menu_input() every tick (main.c does);
 * level-based, so the menu's own edge detection and hold-repeat apply. */
uint16_t usbh_hidinput_buttons(void);

#endif /* USBH_HIDINPUT_H */
