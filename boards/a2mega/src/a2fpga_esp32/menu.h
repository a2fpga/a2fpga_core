/*
 * menu — gamepad-driven menu system for the a2mega ESP32 firmware.
 *
 * Port of the a2n20v2-Enhanced firmware_host menu. Display model (who owns
 * the HDMI output):
 *   APPLE   — the Apple II drives the video (OSD overlay off)
 *   MCU     — the ESP32 owns the OSD text overlay, in one of two views:
 *               CONSOLE  the boot/status log (osd_console)
 *               MENU     this menu system
 *
 * Controls (gamepad on the FPGA's USB-A port, read back via the pad regs;
 * no keyboard required):
 *   SELECT         toggle APPLE <-> MCU (returns to the last MCU view)
 *   Y              in MCU: switch MENU <-> CONSOLE view
 *   D-PAD UP/DOWN  move the selection (hold to repeat)
 *   D-PAD L/R      change the highlighted choice/toggle value (hold repeats)
 *   A              activate: enter submenu / run action / cycle choice
 *   B              back: leave submenu; at the root menu, back to APPLE
 *
 * The menu runs in the main loop task: call menu_tick() every ~20 ms. It
 * polls the FPGA pad readback registers (fpga_pad_poll) and does its own
 * edge detection, hold-repeat, and screen painting (all link access is
 * mutex-protected by fpga_link). Settings changes are applied to the live
 * a2_settings_t and persisted immediately (settings_save()).
 *
 * Screens are builder functions that regenerate their item lists on entry,
 * and the item model (INFO/SUBMENU/ACTION/CHOICE/TOGGLE) covers list-driven
 * pickers without text input. A keyboard event source can later feed
 * menu_input() alongside the pad.
 */
#ifndef _MENU_H
#define _MENU_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call once at startup (after settings_init and fpga_link_init). */
void menu_init(void);

/* Call every ~20 ms from the main loop task: polls the pad and drives the
 * menu (edge detection and hold-repeat are handled inside). */
void menu_tick(void);

/* Feed a button bitmap (A2PAD_* bits from a2fpga_regs.h) directly. Normally
 * called by menu_tick(); exposed so other input sources (e.g. a keyboard)
 * can drive the menu. Safe to call with an unchanged state. */
void menu_input(uint16_t buttons);

/* True when the MCU owns the display (menu or console view). */
bool menu_mcu_view_active(void);

/* ---- hook implemented by the integrator (network glue for the menu) ---- */
/* Apply the current network settings (DHCP on/off, static address) to the
 * WiFi STA interface. Also applied automatically at each bring-up. */
void menu_hook_net_apply(void);

#ifdef __cplusplus
}
#endif

#endif
