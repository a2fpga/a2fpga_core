/*
 * menu — gamepad-driven MCU menu system for the a2n20v2-Enhanced host build.
 *
 * Display model (who owns the HDMI output):
 *   APPLE   — the Apple II drives the video (FPGA passthrough)
 *   MCU     — the BL616 owns the OSD text page, in one of two views:
 *               CONSOLE  the boot/status log (osd_console)
 *               MENU     this menu system
 *
 * Controls (XInput pad; no keyboard required):
 *   SELECT (Back)  toggle APPLE <-> MCU (returns to the last MCU view)
 *   Y              in MCU: switch MENU <-> CONSOLE view
 *   D-PAD UP/DOWN  move the selection (hold to repeat)
 *   D-PAD L/R      change the highlighted choice/toggle value
 *   A              activate: enter submenu / run action / cycle choice
 *   B              back: leave submenu; at the root menu, back to APPLE
 *
 * The menu runs entirely in the xinput poll thread: main.c feeds the current
 * button state into menu_input() every poll tick (~20 ms), and the menu does
 * its own edge detection, hold-repeat, and screen painting (all SPI access is
 * mutex-protected by fpga_spi). Settings changes are applied to the live
 * a2_settings_t and persisted to flash immediately.
 *
 * Future growth is anticipated in the framework, not bolted on: screens are
 * builder functions that regenerate their item lists on entry (so dynamic
 * content — mounted volumes, USB device tree, directory listings — is
 * first-class), and the item model (INFO/SUBMENU/ACTION/CHOICE/TOGGLE)
 * covers list-driven pickers without text input. A keyboard event source can
 * later feed menu_input() alongside the pad.
 */
#ifndef _MENU_H
#define _MENU_H

#include <stdbool.h>
#include <stdint.h>

/* Call once at startup (after settings_init). */
void menu_init(void);

/* Feed the current XInput button bitmap every poll tick (edge detection and
 * hold-repeat are handled inside). Safe to call with an unchanged state. */
void menu_input(uint16_t buttons);

/* True when the MCU owns the display (menu or console view). */
bool menu_mcu_view_active(void);

/* ---- hooks implemented in main.c (network glue for the menu) ---- */
/* Fill up to `max` 40-char lines with network status; returns lines used. */
int menu_hook_net_lines(char lines[][41], int max);

/* Apply the current network settings (DHCP on/off, static address) to the
 * active default interface. Also applied automatically at each bring-up. */
void menu_hook_net_apply(void);

#endif
