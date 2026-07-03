/*
 * osd_console — shared boot/status console for the BL616 host build.
 *
 * Every subsystem (USB host, USB-Ethernet, Disk II, menu) appends one line per
 * STATE CHANGE via osd_log() instead of owning the screen and continuously
 * repainting. Backed by the FPGA OSD text page (fpga_screen) + the
 * video_control_if takeover (reg 0x10 VIDEO_ENABLE, 0x11 TEXT_MODE).
 *
 * Visibility model:
 *   - osd_console_show(): take over the Apple II display, repaint the log.
 *   - osd_console_hide(): hand the display back to the live Apple II.
 *   - While shown, osd_log() repaints; while hidden, osd_log() only buffers the
 *     line (so a later show() reveals the full history) and does NOT steal the
 *     screen back from the Apple II.
 */
#ifndef _OSD_CONSOLE_H
#define _OSD_CONSOLE_H

#include <stdbool.h>

void osd_log(const char *fmt, ...);   /* append one status line (thread-safe) */
void osd_console_show(void);          /* take over the screen, show the log */
void osd_console_hide(void);          /* return the screen to the Apple II */

/* While locked out (the menu owns the screen), show() requests from other
 * threads are ignored and osd_log() only buffers — the menu is never stomped. */
void osd_console_set_lockout(bool lockout);

#endif
