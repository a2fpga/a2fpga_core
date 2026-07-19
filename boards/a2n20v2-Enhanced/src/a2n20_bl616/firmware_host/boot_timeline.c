/* boot_timeline.c -- see boot_timeline.h. */
#include "boot_timeline.h"
#include "fpga_spi.h"
#include "bflb_mtimer.h"
#include <stdio.h>

/* FPGA sys_time_r ticks at CLOCK_SPEED_HZ (bl616_spi_connector.sv param).
 * a2n20v2-Enhanced logic clock = 54 MHz. Counter is 32-bit -> wraps at
 * ~79.5 s; the whole boot window is < 15 s (reset backstop), so no wrap. */
#define FPGA_CLOCK_HZ   54000000u
#define FPGA_TICKS_PER_MS (FPGA_CLOCK_HZ / 1000u)

/* sys_time export registers (bl616_spi_connector.sv:831-834). */
#define REG_SYS_TIME0   0x08   /* LSB */
#define REG_SYS_TIME1   0x09
#define REG_SYS_TIME2   0x0A
#define REG_SYS_TIME3   0x0B   /* MSB */

typedef struct {
    uint8_t  valid;
    uint32_t fpga_ticks;
    uint32_t mcu_us;
} bt_entry_t;

static bt_entry_t g_bt[BT_COUNT];

static const char *bt_name(bt_stage_t s)
{
    switch (s) {
    case BT_FPGA_READY:   return "FPGA_READY(cfg+sdram)";
    case BT_A2BUS_READY:  return "A2BUS_READY";
    case BT_MOUNT_FOUND:  return "MOUNT_FOUND";
    case BT_RST_WRITE:    return "RST_0x2E_WRITE";
    case BT_RST_RELEASED: return "RST_RELEASED";
    default:              return "?";
    }
}

/* Read the 32-bit free-running counter. The four bytes are not latched
 * together, so a carry can propagate between byte reads. Re-read the LSB: if
 * it did not wrap during the read, no carry propagated and the sample is
 * consistent. Retry a couple of times, then accept the last read. */
static uint32_t bt_read_fpga_ticks(void)
{
    for (int i = 0; i < 3; i++) {
        uint8_t b0 = fpga_spi_reg_read(REG_SYS_TIME0);
        uint8_t b1 = fpga_spi_reg_read(REG_SYS_TIME1);
        uint8_t b2 = fpga_spi_reg_read(REG_SYS_TIME2);
        uint8_t b3 = fpga_spi_reg_read(REG_SYS_TIME3);
        uint8_t b0b = fpga_spi_reg_read(REG_SYS_TIME0);
        if (b0b >= b0)   /* LSB did not wrap -> no carry into b1..b3 */
            return (uint32_t)b0 | ((uint32_t)b1 << 8) |
                   ((uint32_t)b2 << 16) | ((uint32_t)b3 << 24);
    }
    /* Fallback: accept a fresh (possibly 1-tick-skewed) read. */
    return (uint32_t)fpga_spi_reg_read(REG_SYS_TIME0) |
           ((uint32_t)fpga_spi_reg_read(REG_SYS_TIME1) << 8) |
           ((uint32_t)fpga_spi_reg_read(REG_SYS_TIME2) << 16) |
           ((uint32_t)fpga_spi_reg_read(REG_SYS_TIME3) << 24);
}

void bt_mark(bt_stage_t stage)
{
    if (stage >= BT_COUNT) return;
    if (g_bt[stage].valid) return;              /* first write wins */
    g_bt[stage].fpga_ticks = bt_read_fpga_ticks();
    g_bt[stage].mcu_us     = (uint32_t)bflb_mtimer_get_time_us();
    g_bt[stage].valid      = 1;
}

int bt_reset_released(void)
{
    return g_bt[BT_RST_RELEASED].valid;
}

int bt_format(char *buf, int buflen)
{
    int n = 0;
    n += snprintf(buf + n, buflen - n,
        "\r\n-- BOOT TIMELINE (FPGA clk %u Hz; ms = elapsed since config-done) --\r\n"
        "  stage                    fpga_ms   delta    mcu_ms\r\n",
        FPGA_CLOCK_HZ);

    uint32_t prev_ms = 0;
    int have_prev = 0;
    for (int s = 0; s < BT_COUNT && n < buflen; s++) {
        if (!g_bt[s].valid) {
            n += snprintf(buf + n, buflen - n,
                          "  %-22s      ---     ---       ---   (not reached)\r\n",
                          bt_name((bt_stage_t)s));
            continue;
        }
        uint32_t fpga_ms = g_bt[s].fpga_ticks / FPGA_TICKS_PER_MS;
        uint32_t mcu_ms  = g_bt[s].mcu_us / 1000u;
        /* Plausibility guard: the whole boot window is far under 60 s, so a
         * near-full-scale fpga_ms (e.g. 79536 = counter max / early-boot SPI
         * read glitch returning 0xFF bytes) is bogus. Flag it, keep mcu_ms
         * (authoritative), and exclude it from the delta chain. */
        if (fpga_ms > 60000u) {
            n += snprintf(buf + n, buflen - n,
                          "  %-22s (wrap?%6u)   --- %9u   (fpga read glitch; use mcu_ms)\r\n",
                          bt_name((bt_stage_t)s), fpga_ms, mcu_ms);
            continue;
        }
        if (have_prev) {
            n += snprintf(buf + n, buflen - n,
                          "  %-22s %7u  %+6d %9u\r\n",
                          bt_name((bt_stage_t)s), fpga_ms,
                          (int)fpga_ms - (int)prev_ms, mcu_ms);
        } else {
            n += snprintf(buf + n, buflen - n,
                          "  %-22s %7u    base %9u\r\n",
                          bt_name((bt_stage_t)s), fpga_ms, mcu_ms);
        }
        prev_ms = fpga_ms;
        have_prev = 1;
    }
    if (n < buflen)
        n += snprintf(buf + n, buflen - n,
            "  (mcu_ms = BL616 mtimer, independent origin; fpga_ms is the truth)\r\n");
    return n;
}
