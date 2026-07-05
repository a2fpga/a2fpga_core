/*
 * osd_console — see osd_console.h. A small line ring-buffer rendered to the
 * FPGA OSD text page. Repaints only on state changes (when shown), so there is
 * no continuous-refresh flicker and no task permanently owning the screen.
 *
 * a2mega ESP32 port of the a2n20v2-Enhanced firmware_host/osd_console.c:
 *   - usb_osal mutex -> FreeRTOS mutex
 *   - video takeover is A2REG_VIDEO_ENABLE only (no TEXT_MODE register)
 *   - every logged line is mirrored to the serial log (ESP_LOGI, tag
 *     "console") so the boot history is visible on USB-C too
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_log.h"

#include "fpga_link.h"
#include "fpga_screen.h"
#include "osd_console.h"

static const char *TAG = "console";

#define CON_ROWS 23           /* fits the 24-row text page with headroom */
#define CON_COLS 39           /* 40-col screen, leave 1 to avoid auto-wrap */

static char  s_lines[CON_ROWS][CON_COLS + 1];
static int   s_count;
static bool  s_visible;
static bool  s_lockout;   /* menu owns the screen; buffer only */
static SemaphoreHandle_t s_lock;

/* The very first osd_log()/show() runs single-threaded at boot (the startup
 * banner), so creating the mutex lazily here is race-free in practice. */
static void ensure_lock(void)
{
    if (!s_lock)
        s_lock = xSemaphoreCreateMutex();
}

/* Repaint the whole buffer to the OSD text page. Caller holds s_lock. */
static void repaint(void)
{
    fpga_link_lock();                 /* keep the frame update atomic */
    fpga_screen_clear();
    fpga_screen_home();
    for (int i = 0; i < s_count; i++) {
        fpga_screen_puts(s_lines[i]);
        fpga_screen_puts("\n");
    }
    fpga_link_unlock();
}

void osd_log(const char *fmt, ...)
{
    ensure_lock();
    xSemaphoreTake(s_lock, portMAX_DELAY);

    char line[CON_COLS + 1];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    ESP_LOGI(TAG, "%s", line);

    /* Uppercase so it renders in the Apple II primary character set. */
    for (char *p = line; *p; p++)
        if (*p >= 'a' && *p <= 'z')
            *p = (char)(*p - 32);

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
        fpga_reg_write(A2REG_VIDEO_ENABLE, 1);
    }

    xSemaphoreGive(s_lock);
}

void osd_console_show(void)
{
    ensure_lock();
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_lockout) {                 /* menu owns the screen: buffer only */
        xSemaphoreGive(s_lock);
        return;
    }
    s_visible = true;
    repaint();
    fpga_reg_write(A2REG_VIDEO_ENABLE, 1);
    xSemaphoreGive(s_lock);
}

void osd_console_set_lockout(bool lockout)
{
    ensure_lock();
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_lockout = lockout;
    if (lockout)
        s_visible = false;           /* menu will paint; logs buffer */
    xSemaphoreGive(s_lock);
}

void osd_console_hide(void)
{
    ensure_lock();
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_visible = false;
    /* While the menu owns the screen (lockout), do NOT touch the video
     * takeover — a background hide (e.g. disk remount's scheduled hide)
     * would otherwise yank the display back to the Apple II mid-menu. */
    if (!s_lockout)
        fpga_reg_write(A2REG_VIDEO_ENABLE, 0);
    xSemaphoreGive(s_lock);
}
