/*
 * FPGA Screen — OSD text output via SDRAM XFER writes.
 *
 * SDRAM address mapping (from PicoSOC a2mem.c):
 *   PicoSOC 0x04020800 = SDRAM byte 0x020800 (OSD text page)
 *
 * Address encoding (Apple II interleaved text page):
 *   addr = 0x020800 + (0x50 * (y >> 3)) + ((y & 0x07) << 8) + (x << 1)
 *
 * Characters occupy even byte addresses (x<<1); odd bytes are padding.
 * Characters are stored as Apple II screen codes: ASCII + 128 for normal text.
 * v1 simplification: cursor wraps to top (no scroll).
 *
 * IMPORTANT: Characters must be written in batches (one contiguous XFER per
 * screen line) rather than individual single-byte XFERs. The FPGA's SDRAM
 * write accumulator collects bytes into 32-bit words before flushing; when a
 * new write targets a different word and the SDRAM port is busy, the old
 * word is silently dropped. Contiguous batch writes hit the auto-flush path
 * at every 4th byte, keeping the accumulator in sync.
 */

#include <string.h>
#include "fpga_screen.h"
#include "fpga_spi.h"

#define OSD_BASE  0x020800
#define OSD_SIZE  2048
#define SCREEN_W  40
#define SCREEN_H  24

static int cursor_h = 0;
static int cursor_v = 0;

static uint32_t screen_addr(int x, int y)
{
    return OSD_BASE + (0x50 * (y >> 3)) + ((y & 0x07) << 8) + (x << 1);
}

void fpga_screen_clear(void)
{
    fpga_spi_xfer_fill(FPGA_SPACE_SDRAM, OSD_BASE, 0xA0, OSD_SIZE);
    cursor_h = 0;
    cursor_v = 0;
}

static void newline(void)
{
    cursor_h = 0;
    cursor_v++;
    if (cursor_v >= SCREEN_H) {
        cursor_v = 0;  /* Wrap to top (no scroll in v1) */
    }
}

/* Flush a run of characters as one contiguous XFER write.
 * buf[] has characters at even offsets and 0xA0 padding at odd offsets.
 * This hits the SDRAM accumulator's auto-flush every 4 bytes, avoiding
 * the lost-word race when the port is busy. */
static void flush_line(int start_h, int start_v, const uint8_t *buf, int nbytes)
{
    if (nbytes > 0) {
        fpga_spi_xfer_write(FPGA_SPACE_SDRAM,
                            screen_addr(start_h, start_v),
                            buf, (uint16_t)nbytes);
    }
}

void fpga_screen_putchar(uint8_t c)
{
    if (c == '\n') {
        newline();
        return;
    }
    if (c < 32) return;

    /* Single char: write 2 bytes (char + padding) so the SDRAM accumulator
     * sees a complete even/odd pair, reducing flush race likelihood. */
    uint8_t pair[2] = { (uint8_t)(c + 128), 0xA0 };
    fpga_spi_xfer_write(FPGA_SPACE_SDRAM, screen_addr(cursor_h, cursor_v), pair, 2);

    cursor_h++;
    if (cursor_h >= SCREEN_W) {
        newline();
    }
}

void fpga_screen_puts(const char *str)
{
    /* Build contiguous buffer for each screen line: character at even byte,
     * 0xA0 padding at odd byte. Write entire line as one XFER. */
    uint8_t buf[SCREEN_W * 2];
    int count = 0;
    int start_h = cursor_h;
    int start_v = cursor_v;

    while (*str) {
        uint8_t c = (uint8_t)*str++;

        if (c == '\n' || c < 32) {
            flush_line(start_h, start_v, buf, count);
            count = 0;
            if (c == '\n') newline();
            start_h = cursor_h;
            start_v = cursor_v;
            continue;
        }

        buf[count++] = c + 128;   /* Apple II screen code */
        buf[count++] = 0xA0;      /* odd-byte padding */

        cursor_h++;
        if (cursor_h >= SCREEN_W) {
            flush_line(start_h, start_v, buf, count);
            count = 0;
            newline();
            start_h = cursor_h;
            start_v = cursor_v;
        }
    }

    flush_line(start_h, start_v, buf, count);
}

void fpga_screen_home(void)
{
    cursor_h = 0;
    cursor_v = 0;
}
