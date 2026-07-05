/*
 * FPGA Screen — OSD text output via XFER writes (a2mega ESP32 port).
 *
 * Port of a2n20v2-Enhanced firmware/fpga_screen.c with the a2mega OSD page
 * layout:
 *
 *   - The text page is LINEAR: 40x24 Apple II screen codes at offset
 *     y*40+x in XFER space A2SPACE_OSD (BSRAM text_vram0, read by
 *     osd_text_overlay.sv). No Apple II interleaved addressing, no even/odd
 *     byte packing, and no SDRAM write-accumulator flush constraints.
 *
 *   - The OSD space is write-only from the ESP32 side, so a local 960-byte
 *     shadow of the page is kept. The shadow also enables real scrolling:
 *     unlike the BL616 v1 (cursor wrapped to the top), a newline past the
 *     bottom row scrolls the page up one line.
 *
 * Characters are stored as Apple II screen codes: ASCII + 128 for normal
 * text, $00-$3F for inverse (uppercase + symbols only).
 */

#include <string.h>
#include "fpga_screen.h"
#include "fpga_link.h"

#define SCREEN_W  FPGA_SCREEN_W
#define SCREEN_H  FPGA_SCREEN_H
#define OSD_SIZE  (SCREEN_W * SCREEN_H)          /* 960 bytes */

static uint8_t s_shadow[OSD_SIZE];               /* local copy (space is WO) */
static int cursor_h = 0;
static int cursor_v = 0;
static bool inverse_mode = false;

/* ASCII -> Apple II screen code. Normal text = ASCII+128; inverse = codes
 * $00-$3F (uppercase + symbols only, so lowercase is folded to uppercase). */
static uint8_t screen_code(uint8_t c)
{
    if (c >= 'a' && c <= 'z')
        c -= 32;
    if (inverse_mode) {
        if (c >= 0x40 && c < 0x60)
            return (uint8_t)(c - 0x40);   /* @A-Z... -> $00-$1F */
        if (c >= 0x20 && c < 0x40)
            return c;                     /* space/digits/symbols -> $20-$3F */
        return 0x20;                      /* out of range: inverse space */
    }
    return (uint8_t)(c + 128);
}

static uint32_t screen_addr(int x, int y)
{
    return (uint32_t)(y * SCREEN_W + x);
}

void fpga_screen_clear(void)
{
    memset(s_shadow, 0xA0, OSD_SIZE);
    fpga_mem_write(A2SPACE_OSD, 0, s_shadow, OSD_SIZE);
    cursor_h = 0;
    cursor_v = 0;
}

/* Scroll the page up one line (shadow + full-page repaint). */
static void scroll_up(void)
{
    memmove(s_shadow, s_shadow + SCREEN_W, OSD_SIZE - SCREEN_W);
    memset(s_shadow + OSD_SIZE - SCREEN_W, 0xA0, SCREEN_W);
    fpga_mem_write(A2SPACE_OSD, 0, s_shadow, OSD_SIZE);
}

static void newline(void)
{
    cursor_h = 0;
    cursor_v++;
    if (cursor_v >= SCREEN_H) {
        cursor_v = SCREEN_H - 1;
        scroll_up();
    }
}

/* Flush a run of characters (already placed in the shadow) as one
 * contiguous XFER write. */
static void flush_line(int start_h, int start_v, int nchars)
{
    if (nchars > 0) {
        uint32_t addr = screen_addr(start_h, start_v);
        fpga_mem_write(A2SPACE_OSD, addr, &s_shadow[addr], (uint16_t)nchars);
    }
}

void fpga_screen_putchar(uint8_t c)
{
    if (c == '\n') {
        newline();
        return;
    }
    if (c < 32) return;

    uint32_t addr = screen_addr(cursor_h, cursor_v);
    s_shadow[addr] = screen_code(c);
    fpga_mem_write(A2SPACE_OSD, addr, &s_shadow[addr], 1);

    cursor_h++;
    if (cursor_h >= SCREEN_W) {
        newline();
    }
}

void fpga_screen_puts(const char *str)
{
    /* Place characters into the shadow, flushing one contiguous XFER write
     * per screen-line segment. */
    int count = 0;
    int start_h = cursor_h;
    int start_v = cursor_v;

    while (*str) {
        uint8_t c = (uint8_t)*str++;

        if (c == '\n' || c < 32) {
            flush_line(start_h, start_v, count);
            count = 0;
            if (c == '\n') newline();
            start_h = cursor_h;
            start_v = cursor_v;
            continue;
        }

        s_shadow[screen_addr(cursor_h, cursor_v)] = screen_code(c);
        count++;

        cursor_h++;
        if (cursor_h >= SCREEN_W) {
            flush_line(start_h, start_v, count);
            count = 0;
            newline();
            start_h = cursor_h;
            start_v = cursor_v;
        }
    }

    flush_line(start_h, start_v, count);
}

void fpga_screen_home(void)
{
    cursor_h = 0;
    cursor_v = 0;
}

void fpga_screen_goto(int x, int y)
{
    if (x < 0) x = 0;
    if (x >= SCREEN_W) x = SCREEN_W - 1;
    if (y < 0) y = 0;
    if (y >= SCREEN_H) y = SCREEN_H - 1;
    cursor_h = x;
    cursor_v = y;
}

void fpga_screen_set_inverse(bool inverse)
{
    inverse_mode = inverse;
}
