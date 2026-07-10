/*
 * osd_console — see osd_console.h. A small line ring-buffer rendered to the
 * FPGA OSD text page. Repaints only on state changes (when shown), so there is
 * no continuous-refresh flicker and no thread permanently owning the screen.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "usb_osal.h"
#include "fpga_spi.h"
#include "fpga_screen.h"
#include "osd_console.h"
#include "telnetd.h"

#define REG_VIDEO_ENABLE  0x10u
#define REG_TEXT_MODE     0x11u

#define CON_ROWS 23           /* fits the 24-row text page with headroom */
#define CON_COLS 39           /* 40-col screen, leave 1 to avoid auto-wrap */

static char  s_lines[CON_ROWS][CON_COLS + 1];
static int   s_count;
static bool  s_visible;
static bool  s_lockout;   /* menu owns the screen; buffer only */
static usb_osal_mutex_t s_lock;

/* The very first osd_log()/show() runs single-threaded at boot (the startup
 * banner), so creating the mutex lazily here is race-free in practice. */
static void ensure_lock(void)
{
    if (!s_lock)
        s_lock = usb_osal_mutex_create();
}

/* Repaint the whole buffer to the OSD text page. Caller holds s_lock. */
static void repaint(void)
{
    fpga_screen_clear();
    fpga_screen_home();
    for (int i = 0; i < s_count; i++) {
        fpga_screen_puts(s_lines[i]);
        fpga_screen_puts("\n");
    }
}

void osd_log(const char *fmt, ...)
{
    ensure_lock();
    usb_osal_mutex_take(s_lock);

    char line[CON_COLS + 1];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    /* Uppercase so it renders in the Apple II primary character set. */
    for (char *p = line; *p; p++)
        if (*p >= 'a' && *p <= 'z')
            *p = (char)(*p - 32);

    telnetd_console_tee(line);
    if (s_count < CON_ROWS) {
        strcpy(s_lines[s_count++], line);
    } else {
        for (int i = 1; i < CON_ROWS; i++)
            strcpy(s_lines[i - 1], s_lines[i]);
        strcpy(s_lines[CON_ROWS - 1], line);
    }

    /* Only repaint / assert the takeover when the console is the active view.
     * When hidden, we just buffer the line — the Apple II keeps the screen. */
    if (s_visible) {
        repaint();
        fpga_spi_reg_write(REG_TEXT_MODE, 1);
        fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
    }

    usb_osal_mutex_give(s_lock);
}

void osd_console_show(void)
{
    ensure_lock();
    usb_osal_mutex_take(s_lock);
    if (s_lockout) {                 /* menu owns the screen: buffer only */
        usb_osal_mutex_give(s_lock);
        return;
    }
    s_visible = true;
    repaint();
    fpga_spi_reg_write(REG_TEXT_MODE, 1);
    fpga_spi_reg_write(REG_VIDEO_ENABLE, 1);
    usb_osal_mutex_give(s_lock);
}

void osd_console_set_lockout(bool lockout)
{
    ensure_lock();
    usb_osal_mutex_take(s_lock);
    s_lockout = lockout;
    if (lockout)
        s_visible = false;           /* menu will paint; logs buffer */
    usb_osal_mutex_give(s_lock);
}

void osd_console_hide(void)
{
    ensure_lock();
    usb_osal_mutex_take(s_lock);
    s_visible = false;
    /* While the menu owns the screen (lockout), do NOT touch the video
     * takeover — a background hide (e.g. disk_remount's scheduled hide)
     * would otherwise yank the display back to the Apple II mid-menu. */
    if (!s_lockout)
        fpga_spi_reg_write(REG_VIDEO_ENABLE, 0);
    usb_osal_mutex_give(s_lock);
}

/* Copy the current backlog for a newly connected remote console. Returns
 * the number of lines copied. */
int osd_console_snapshot(char dst[][41], int max)
{
    ensure_lock();
    usb_osal_mutex_take(s_lock);
    int n = s_count < max ? s_count : max;
    for (int i = 0; i < n; i++)
        snprintf(dst[i], 41, "%s", s_lines[i]);
    usb_osal_mutex_give(s_lock);
    return n;
}
