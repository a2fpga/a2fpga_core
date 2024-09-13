#include "a2mem.h"

#define a2_mem_bytes ((volatile uint8_t*)0x04000000)
#define a2_mem_words ((volatile uint32_t*)0x04000000)

#define mmio8(x) (*(volatile uint8_t*)(x))
#define mmio32(x) (*(volatile uint32_t*)(x))

uint32_t peek32(uint32_t addr) {
    return mmio32(0x04000000 + addr);
}

uint8_t peek8(uint32_t addr) {
    return mmio8(0x04000000 + addr);
}

void poke32(uint32_t addr, uint32_t val) {
    mmio32(0x04000000 + addr) = val;
}

void poke8(uint32_t addr, uint8_t val) {
    mmio8(0x04000000 + addr) = val;
}

void shadow_ram_init()
{
    // clear text page 0
    for (int i = 0; i < 2048; i += 4) {
        mmio32(0x04020800 + i) = 0x00000000;
    }
}

int h = 0;
int v = 0;

void screen_home()
{
    h = 0;
    v = 0;
}

void screen_clear()
{
    for (int i = 0; i < 2048; i += 4) {
        mmio32(0x04020800 + i) = 0xA0A0A0A0;
    }
    h = 0;
    v = 0;
}

uint32_t screen_addr(int x, int y)
{
    return 0x04020800 + (0x50 * (y >> 3)) + ((y & 0x07) << 8) + (x << 1);
}

void screen_scroll()
{
    uint32_t dst_addr = 0;
    uint32_t src_addr = 0;
    for (int y = 1; y < 24; y++) {
        dst_addr = screen_addr(0, y - 1);
        src_addr = screen_addr(0, y);
        for (int x = 0; x < 80; x += 4) {
            mmio32(dst_addr + x) = mmio32(src_addr + x);
        }
    }
    dst_addr = screen_addr(0, 23);
    for (int x = 0; x < 80; x += 4) {
        mmio32(dst_addr + x) = 0xA0A0A0A0;
    }
    h = 0;
    v = 23;
}

void newline()
{
    h = 0;
    v++;
    if (v > 23) {
        v = 0;
        screen_scroll();
    }
}

void screen_putchar(uint8_t c)
{
    if (c == '\n') {
        newline();
        return;
    }
    if (c < 32) return;

    mmio8(screen_addr(h, v)) = c + 128;

    h++;
    if (h > 39) {
        newline();
    }
}

