/*
 * telnetd — remote console/menu mirror on TCP port 23.
 *
 * a2mega ESP32 port of the a2n20v2-Enhanced firmware_host/telnetd.c
 * (usb_osal -> FreeRTOS, fpga_spi -> fpga_link/a2spi, XINPUT_* -> A2PAD_*).
 * The Enhanced-only diagnostics (bus-event FIFO snapshot/scope/trigger,
 * boot timeline) are not ported — that capture fabric does not exist in the
 * a2mega gateware.
 *
 * One client at a time. Two views, toggled by single keys:
 *
 *   'c'  CONSOLE (default): dumps the osd_console backlog, then streams
 *        every new osd_log() line live (the tee is a lock-protected line
 *        ring so logging threads never block on the network).
 *   'm'  MENU: mirrors the FPGA's 40x24 OSD text page (menu, install pages,
 *        whatever is painted) as ANSI, repainted on change, and maps keys
 *        to pad buttons so the whole menu is drivable remotely:
 *          up/down    = D-pad          Enter/a = A (OK)
 *          left/right = D-pad L/R      Backspace/b = B (back)
 *          y = Y (menu<->console view) s/Tab = SELECT (Apple II <-> MCU)
 *   'q'  disconnect.
 *
 * On 1.0a3 this is the PRIMARY console: the USB-C port faces the DP
 *  monitor, so there is no PC serial link while the board is in service.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "lwip/sockets.h"
#include "lwip/netif.h"

#include "fpga_screen.h"
#include "fpga_link.h"
#include "gs_socket.h"
#include "fpga_jtag.h"
#include "osd_console.h"
#include "menu.h"
#include "board_pins.h"
#include "disk.h"
#if A2MEGA_HAS_USBC_PD
#include "usbc_glue.h"
#endif
#if A2MEGA_HAS_DP130
#include "sn75dp130.h"
#endif
#include "a2fpga_regs.h"
#include "telnetd.h"
#include "wedge_watch.h"

extern volatile bool viddbg_request;   /* serviced by loop() in a2fpga_esp32.ino */

#define TELNET_PORT     23
#define TEE_LINES       32
#define TEE_COLS        40

/* ---- console tee ring (written by osd_log from any thread) -------------- */
static char     s_tee[TEE_LINES][TEE_COLS + 1];
static volatile uint32_t s_tee_wr;        /* total lines ever written  */
static uint32_t s_tee_rd;                 /* telnet thread's position  */
static SemaphoreHandle_t s_tee_lock;
static volatile bool s_client_up;

void telnetd_console_tee(const char *line)
{
    if (!s_client_up || !s_tee_lock)
        return;
    xSemaphoreTake(s_tee_lock, portMAX_DELAY);
    snprintf(s_tee[s_tee_wr % TEE_LINES], sizeof(s_tee[0]), "%s", line);
    s_tee_wr++;
    xSemaphoreGive(s_tee_lock);
}

/* ---- helpers ------------------------------------------------------------- */
/* Set when a send errors or times out (SO_SNDTIMEO): the peer vanished
 * without closing (crashed client, port scanner) and its window filled.
 * tn_send goes no-op and session() bails, so the next client can connect. */
static bool s_peer_dead;

static int tn_send(int fd, const void *buf, int len)
{
    const char *p = buf;
    while (len > 0 && !s_peer_dead) {
        int n = lwip_send(fd, p, len, 0);
        if (n <= 0) {
            s_peer_dead = true;
            return -1;
        }
        p += n;
        len -= n;
    }
    return s_peer_dead ? -1 : 0;
}

static void tn_puts(int fd, const char *s)
{
    tn_send(fd, s, (int)strlen(s));
}

static void tn_printf(int fd, const char *fmt, ...)
{
    char buf[200];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0)
        tn_send(fd, buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
}

/* ---- line mode (':' key): CLI-style register commands over telnet ---------
 * The USB CLI lives in the sketch and prints to Serial; this is the subset
 * the bench needs when the USB-C port is busy being the DP output:
 *   spireg <reg> [val]      raw FPGA register read/write (dec or 0x..)
 *   gs                      decoded GS-socket window (regs 0x5F/0x4F)
 *   gs set <idx> <val>      write one window register
 *   gs arm|listen|off|clear|freeze|run
 *   gs trace                the 64-cycle bus trace (freezes it first)
 *   gs mode <0-3> | gs hold <ms>   bring-up mode / timed hold (gs_socket.h)
 *   gs events | gs evclear  the FPGA bring-up event log (window regs 32-39)
 * Empty line or ESC leaves line mode. */
#define GS_REG_SEL   0x5F
#define GS_REG_DATA  0x4F

static uint8_t gs_rd(uint8_t idx)
{
    uint8_t v;
    fpga_link_lock();
    fpga_reg_write(GS_REG_SEL, idx);
    v = fpga_reg_read(GS_REG_DATA);
    fpga_link_unlock();
    return v;
}

static void gs_wr(uint8_t idx, uint8_t val)
{
    fpga_link_lock();
    fpga_reg_write(GS_REG_SEL, idx);
    fpga_reg_write(GS_REG_DATA, val);
    fpga_link_unlock();
}

static const char *gs_mode_name(unsigned m);

static void gs_dump(int fd)
{
    uint8_t r[32];
    fpga_link_lock();
    for (int i = 0; i < 32; i++) {
        fpga_reg_write(GS_REG_SEL, (uint8_t)i);
        r[i] = fpga_reg_read(GS_REG_DATA);
    }
    fpga_link_unlock();
    #define U16(lo) ((unsigned)r[lo] | ((unsigned)r[(lo) + 1] << 8))
    uint32_t cyc = (uint32_t)r[4] | ((uint32_t)r[5] << 8) | ((uint32_t)r[6] << 16) | ((uint32_t)r[7] << 24);
    unsigned per = U16(16), hi = U16(18);
    tn_printf(fd, "CTRL=0x%02X STATUS=0x%02X ph2_alive=%u running=%u enabled=%u be_ok=%u res_n=%u rdy=%u slot_dma_n=%u slot_rdy_n=%u\r\n",
              r[0], r[1], (r[1] >> 7) & 1, (r[1] >> 6) & 1, (r[1] >> 5) & 1, (r[1] >> 4) & 1,
              (r[1] >> 3) & 1, (r[1] >> 2) & 1, (r[1] >> 1) & 1, r[1] & 1);
    if (per) {
        /* sequencer clock 110 MHz: 9.091 ns per clk; counters are per 256 cycles */
        unsigned per_ns10 = (unsigned)((uint64_t)per * 9091 / 256 / 100);   /* 0.1 ns units */
        unsigned hi_ns10  = (unsigned)((uint64_t)hi  * 9091 / 256 / 100);
        unsigned khz = (unsigned)(256000000ULL * 1000 / ((uint64_t)per * 9091));
        tn_printf(fd, "PHI2: %u.%u ns/cycle (%u.%03u MHz), high %u.%u ns (%u%%)\r\n",
                  per_ns10 / 10, per_ns10 % 10, khz / 1000, khz % 1000,
                  hi_ns10 / 10, hi_ns10 % 10, per ? hi * 100 / per : 0);
    }
    tn_printf(fd, "cycles=%lu stalls=%u be_low_clks=%u hold_mismatch=%u hold_samples=%u out_extra=%u hold_tap=%u\r\n",
              (unsigned long)cyc, U16(8), U16(10), U16(12), U16(14), r[2], r[3]);
    tn_printf(fd, "last_addr=%02X:%02X%02X trace: %s%s wptr=%u trig_en=%u\r\n",
              r[22], r[21], r[20], (r[23] & 0x80) ? "FROZEN" : "running",
              (r[23] & 0x40) ? " TRIGGERED" : "", r[23] & 0x3F, (r[0] >> 4) & 1);
    {
        uint8_t st07 = fpga_reg_read(0x07), rst = fpga_reg_read(0x2E);
        tn_printf(fd, "%s | a2: clock %s, reset_n=%u | 0x2E=%02X hold=%u por_done=%u (release=%u assert=%u probe=%u autoarm=%u early=%u) | mode %u %s, timed hold %u ms\r\n",
                  gs_socket_state_str(), (st07 & 0x80) ? "RUNNING" : "STOPPED", (st07 >> 2) & 1, rst,
                  (rst >> 4) & 1, (rst >> 5) & 1, rst & 1, (rst >> 1) & 1, (rst >> 2) & 1, (rst >> 3) & 1, (rst >> 6) & 1,
                  gs_socket_get_mode(), gs_mode_name(gs_socket_get_mode()), gs_socket_get_hold_ms());
        if (gs_socket_get_autotrig()) tn_puts(fd, "autotrig ON\r\n");
        if (gs_socket_get_late_ms()) tn_printf(fd, "mode 2 late arm = %u ms\r\n", gs_socket_get_late_ms());
    }
    #undef U16
}

static void gs_trace(int fd)
{
    uint8_t ctrl = gs_rd(0);
    if (!(ctrl & 0x08)) {
        gs_wr(0, ctrl | 0x08);             /* freeze: the ring stops moving */
        tn_puts(fd, "trace frozen (gs run to release)\r\n");
    }
    uint8_t st = gs_rd(23);
    unsigned wptr = st & 0x3F;
    tn_printf(fd, "%-3s %-9s %-4s %s   (oldest first; wptr=%u%s; OP=opcode fetch dat=data opr=operand int=internal)\r\n",
              "#", "bank:addr", "data", "flags", wptr, (st & 0x40) ? "; TRIGGERED" : "");
    fpga_link_lock();
    for (unsigned n = 0; n < 64; n++) {
        unsigned idx = (wptr + n) & 0x3F;  /* wptr = next write = oldest entry */
        fpga_reg_write(GS_REG_SEL, 23);
        fpga_reg_write(GS_REG_DATA, (uint8_t)idx);
        uint8_t b[5];
        for (int k = 0; k < 5; k++) {
            fpga_reg_write(GS_REG_SEL, (uint8_t)(24 + k));
            b[k] = fpga_reg_read(GS_REG_DATA);
        }
        fpga_link_unlock();
        /* flags: bit0 R/W, bit1 RDY at the fall, bit2 BE ok, bit3 VPA, bit4 VDA */
        const char *kind = (b[4] & 0x18) == 0x18 ? "OP " : (b[4] & 0x10) ? "dat" : (b[4] & 0x08) ? "opr" : "int";
        tn_printf(fd, "%02u  %02X:%02X%02X   %02X   %c %s%s%s\r\n", n, b[2], b[1], b[0], b[3],
                  (b[4] & 1) ? 'R' : 'W', kind, (b[4] & 2) ? "" : " STALL", (b[4] & 4) ? "" : " BE0");
        fpga_link_lock();
    }
    fpga_link_unlock();
}

static const char *gs_mode_name(unsigned m)
{
    static const char *n[] = { "NATURAL (FPGA arms at the machine's release)", "EARLY (armed under our hold, TWGS model)",
                               "TIMED (release socket-off, arm on rise)", "TIMED+ (armed under hold, timed release)",
                               "AUTO (release socket-off, arm late; clock already up at start -> at once, clock later -> after a 300 ms hold)" };
    return m < 5 ? n[m] : "?";
}

/* FPGA bring-up event log (window regs 32-39, hdl/esp32/a2_event_log.sv) */
static void gs_events(int fd)
{
    static const char *name[] = {
        "?", "SLOT /RESET fall", "SLOT /RESET rise", "SOCKET /RES fall", "SOCKET /RES rise",
        "our hold ON", "our hold OFF", "0x2E write", "CTRL write", "POR DONE (machine let go)",
        "clock alive", "clock lost", "release (storage/backstop)", "MCU ready", "core RUNNING",
        "core in reset", "trace trigger", "socket pins OURS", "socket pins released", "probe start", "hardware arm" };
    uint8_t st = gs_rd(32);
    unsigned n = (st & 0x80) ? 128 : (st & 0x7F);
    tn_printf(fd, "%u events%s; t = ms from the first; ctx letters: H our hold, R released, P por_done, A clock alive, L listen, M arm, O pins ours, X core running\r\n",
              n, (st & 0x80) ? " (LOG FULL - gs evclear)" : "");
    uint32_t t0 = 0, tp = 0;
    for (unsigned i = 0; i < n; i++) {
        uint8_t b[6];
        fpga_link_lock();
        fpga_reg_write(GS_REG_SEL, 33);
        fpga_reg_write(GS_REG_DATA, (uint8_t)i);
        for (int k = 0; k < 6; k++) {
            fpga_reg_write(GS_REG_SEL, (uint8_t)(34 + k));
            b[k] = fpga_reg_read(GS_REG_DATA);
        }
        fpga_link_unlock();
        uint32_t t = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
        if (i == 0) { t0 = t; tp = t; }
        uint32_t dt = t - t0, dp = t - tp;            /* wrap-safe (32-bit ticks at 54 MHz, 79 s) */
        tp = t;
        unsigned code = b[4], d = b[5];
        uint32_t us = dt / 54, dus = dp / 54;
        char ctx[10];
        snprintf(ctx, sizeof(ctx), "%c%c%c%c%c%c%c%c", (d & 0x80) ? 'H' : '.', (d & 0x40) ? 'R' : '.', (d & 0x20) ? 'P' : '.',
                 (d & 0x10) ? 'A' : '.', (d & 0x08) ? 'L' : '.', (d & 0x04) ? 'M' : '.', (d & 0x02) ? 'O' : '.', (d & 0x01) ? 'X' : '.');
        if (code == 7 || code == 8)
            tn_printf(fd, "%3u %9lu.%03lu ms (+%lu.%03lu) %-28s value 0x%02X\r\n", i, (unsigned long)(us / 1000), (unsigned long)(us % 1000),
                      (unsigned long)(dus / 1000), (unsigned long)(dus % 1000), code < 21 ? name[code] : "?", d);
        else
            tn_printf(fd, "%3u %9lu.%03lu ms (+%lu.%03lu) %-28s %s\r\n", i, (unsigned long)(us / 1000), (unsigned long)(us % 1000),
                      (unsigned long)(dus / 1000), (unsigned long)(dus % 1000), code < 21 ? name[code] : "?", ctx);
    }
}

static bool parse_num(const char *t, unsigned *out)
{
    if (!t || !*t) return false;
    char *end;
    unsigned long v = strtoul(t, &end, 0);
    if (*end) return false;
    *out = (unsigned)v;
    return true;
}

static void tn_exec_line(int fd, char *line)
{
    char *tok[6];
    int nt = 0;
    for (char *p = strtok(line, " \t"); p && nt < 6; p = strtok(NULL, " \t"))
        tok[nt++] = p;
    if (nt == 0)
        return;
    if (!strcmp(tok[0], "help") || !strcmp(tok[0], "?")) {
        tn_puts(fd, "spireg <reg> [val] | gs | gs set <idx> <val> | gs arm|listen|off|auto|mode <0-3>|hold <ms>|autotrig on|off|clear|freeze|run|trig|untrig | gs trace | gs events|evclear\r\n");
        return;
    }
    if (!fpga_link_ok()) {
        tn_puts(fd, "fpga link not up\r\n");
        return;
    }
    if (!strcmp(tok[0], "spireg")) {
        unsigned reg, val;
        if (nt < 2 || !parse_num(tok[1], &reg) || reg > 126) {
            tn_puts(fd, "usage: spireg <reg 0..126> [val]\r\n");
        } else if (nt == 2) {
            tn_printf(fd, "reg[0x%02X] -> 0x%02X\r\n", reg, fpga_reg_read((uint8_t)reg));
        } else if (!parse_num(tok[2], &val) || val > 255) {
            tn_puts(fd, "spireg: invalid value\r\n");
        } else {
            fpga_reg_write((uint8_t)reg, (uint8_t)val);
            tn_printf(fd, "reg[0x%02X] <= 0x%02X\r\n", reg, val);
        }
        return;
    }
    if (!strcmp(tok[0], "gs")) {
        unsigned idx, val;
        if (nt == 1) {
            gs_dump(fd);
        } else if (!strcmp(tok[1], "set") && nt == 4 && parse_num(tok[2], &idx) && idx < 64 && parse_num(tok[3], &val) && val < 256) {
            if (idx == 0) gs_socket_manual();
            gs_wr((uint8_t)idx, (uint8_t)val);
            tn_printf(fd, "gs[%u] <= 0x%02X\r\n", idx, val);
        } else if (!strcmp(tok[1], "arm")) {
            gs_socket_manual();
            gs_wr(0, 0x05); tn_puts(fd, "CTRL=0x05 (arm+listen)\r\n");
        } else if (!strcmp(tok[1], "listen")) {
            gs_socket_manual();
            gs_wr(0, 0x04); tn_puts(fd, "CTRL=0x04 (listen)\r\n");
        } else if (!strcmp(tok[1], "off")) {
            gs_socket_manual();
            gs_wr(0, 0x00); tn_puts(fd, "CTRL=0x00\r\n");
        } else if (!strcmp(tok[1], "clear")) {
            uint8_t c = gs_rd(0); gs_wr(0, c | 0x80); gs_wr(0, c & 0x7F); tn_puts(fd, "counters cleared\r\n");
        } else if (!strcmp(tok[1], "freeze")) {
            gs_wr(0, gs_rd(0) | 0x08); tn_puts(fd, "trace frozen\r\n");
        } else if (!strcmp(tok[1], "run")) {
            gs_wr(0, gs_rd(0) & ~0x08); tn_puts(fd, "trace running\r\n");
        } else if (!strcmp(tok[1], "trig")) {
            /* arm the runaway trigger: clear pulse with trig_en set, freeze off */
            uint8_t c = (gs_rd(0) & ~0x08) | 0x10;
            gs_wr(0, c | 0x80); gs_wr(0, c);
            tn_puts(fd, "trigger armed (opcode fetch from bank 0 < $0800; +32 cycles then freeze)\r\n");
        } else if (!strcmp(tok[1], "untrig")) {
            gs_wr(0, gs_rd(0) & ~0x10); tn_puts(fd, "trigger off\r\n");
        } else if (!strcmp(tok[1], "hold") && nt == 3 && parse_num(tok[2], &val)) {
            gs_socket_set_hold_ms(val); tn_printf(fd, "timed hold = %u ms (modes 2/3)\r\n", val);
        } else if (!strcmp(tok[1], "mode") && nt == 3 && parse_num(tok[2], &val) && val < 5) {
            gs_socket_set_mode(val); tn_printf(fd, "bring-up mode = %u (%s); takes effect at the next machine-off -> clock-up\r\n", val, gs_mode_name(val));
        } else if (!strcmp(tok[1], "late") && nt == 3 && parse_num(tok[2], &val)) {
            gs_socket_set_late_ms(val); tn_printf(fd, "mode 2: arm %u ms after the slot reset reads high\r\n", val);
        } else if (!strcmp(tok[1], "autotrig") && nt == 3) {
            bool on = !strcmp(tok[2], "on") || !strcmp(tok[2], "1");
            gs_socket_set_autotrig(on); tn_printf(fd, "autotrig %s: the /RES-fall trace trigger is armed 20 ms after the socket inputs come on\r\n", on ? "ON" : "OFF");
        } else if (!strcmp(tok[1], "events")) {
            gs_events(fd);
        } else if (!strcmp(tok[1], "evclear")) {
            gs_wr(32, 0x80); tn_puts(fd, "event log cleared\r\n");
        } else if (!strcmp(tok[1], "auto")) {
            gs_socket_resume(); tn_puts(fd, "auto-arm resumed\r\n");
        } else if (!strcmp(tok[1], "trace")) {
            gs_trace(fd);
        } else {
            tn_puts(fd, "usage: gs | gs set <idx> <val> | gs arm|listen|off|auto|mode <0-3>|hold <ms>|clear|freeze|run|trig|untrig | gs trace | gs events|evclear\r\n");
        }
        return;
    }
    tn_printf(fd, "unknown: %s (help)\r\n", tok[0]);
}

/* Render one 40-char row of Apple II screen codes as ANSI. Inverse video
 * is codes $00-$3F ($00-$1F = '@'+c, $20-$3F = c); normal is ASCII+0x80. */
static void render_row(int fd, const uint8_t *row)
{
    char out[40 * 4 + 16];
    int n = 0;
    bool inv = false;
    for (int x = 0; x < 40; x++) {
        uint8_t c = row[x];
        bool want_inv = c < 0x40;
        char ch;
        if (want_inv)
            ch = (c < 0x20) ? (char)('@' + c) : (char)c;
        else
            ch = (char)(c & 0x7F);
        if (ch < 0x20 || ch > 0x7E)
            ch = ' ';
        if (want_inv != inv) {
            n += snprintf(out + n, sizeof(out) - n, want_inv ? "\x1b[7m" : "\x1b[0m");
            inv = want_inv;
        }
        if (n < (int)sizeof(out) - 8)
            out[n++] = ch;
    }
    if (inv)
        n += snprintf(out + n, sizeof(out) - n, "\x1b[0m");
    n += snprintf(out + n, sizeof(out) - n, "\r\n");
    tn_send(fd, out, n);
}

static void render_screen(int fd)
{
    tn_puts(fd, "\x1b[H");                 /* home, no clear: less flicker */
    for (int y = 0; y < FPGA_SCREEN_H; y++)
        render_row(fd, fpga_screen_shadow_row(y));
}

/* Map a received key to a one-tick pad pulse (A2PAD_* bits). Returns 0 if
 * unmapped. st tracks a tiny ESC [ sequence parser for arrows across calls. */
static uint16_t key_to_buttons(uint8_t ch, int *st)
{
    if (*st == 1) {                        /* got ESC */
        *st = (ch == '[') ? 2 : 0;
        return 0;
    }
    if (*st == 2) {                        /* got ESC [ */
        *st = 0;
        switch (ch) {
        case 'A': return A2PAD_U;
        case 'B': return A2PAD_D;
        case 'C': return A2PAD_R;          /* choice next / value +   */
        case 'D': return A2PAD_L;          /* choice prev / value -   */
        }
        return 0;
    }
    switch (ch) {
    case 0x1b: *st = 1; return 0;
    case '\r': case '\n': case 'a': return A2PAD_A;      /* OK    */
    case 0x7f: case 0x08: case 'b': return A2PAD_B;      /* back  */
    case 'y':                       return A2PAD_Y;      /* view  */
    case 's': case '\t':            return A2PAD_SELECT; /* select*/
    }
    return 0;
}

/* ---- session ------------------------------------------------------------- */
static void session(int fd)
{
    s_peer_dead = false;
    /* char-at-a-time: WILL ECHO, WILL SGA, DO SGA */
    static const uint8_t nego[] = { 255, 251, 1, 255, 251, 3, 255, 253, 3 };
    tn_send(fd, nego, sizeof(nego));
    tn_puts(fd, "\r\nA2FPGA " A2_BOARD_NAME " remote console\r\n"
                "keys: c=console m=menu p=pd d=census x=regs z=viddbg e=eq +/-=eqstep l=lanes v=replug f=flip r=retrain g=fpgareload u=fusb t=trace i=i2cscan"
#if A2MEGA_HAS_DP130
                " n=dp130"
#endif
                " :=cmdline q=quit\r\n"
                "menu: up/down move, left/right change, enter/a=ok,\r\n"
                "      esc/backspace/b=back, y=view, s/tab=select\r\n\r\n");

    bool menu_mode = false;
    int esc_st = 0, iac_st = 0;
    bool line_mode = false;                /* ':' command line (tn_exec_line) */
    char line[96];
    int line_len = 0;
    uint32_t last_paint = 0;

    /* start in console mode: replay the on-screen backlog */
    {
        char snap[23][40];
        int n = osd_console_snapshot(snap, 23);
        for (int i = 0; i < n; i++) {
            tn_puts(fd, snap[i]);
            tn_puts(fd, "\r\n");
        }
        xSemaphoreTake(s_tee_lock, portMAX_DELAY);
        s_tee_rd = s_tee_wr;               /* live from here on */
        xSemaphoreGive(s_tee_lock);
    }

    for (;;) {
        if (s_peer_dead)
            return;                        /* send timed out/failed */
        /* input (non-blocking-ish: 50 ms poll via SO_RCVTIMEO) */
        uint8_t ch;
        int r = lwip_recv(fd, &ch, 1, 0);
        if (r == 0)
            return;                        /* closed */
        if (r < 0 && errno != EWOULDBLOCK && errno != EAGAIN)
            return;                        /* reset/keepalive-reaped, not the 50 ms poll */
        if (r != 1 && esc_st == 1) {
            /* lone ESC (no sequence followed within the 50 ms poll): back */
            esc_st = 0;
            if (menu_mode)
                menu_inject(A2PAD_B);
        }
        if (r == 1) {
            if (iac_st == 1) {             /* IAC verb  */
                iac_st = (ch >= 251 && ch <= 254) ? 2 : 0;
                continue;
            }
            if (iac_st == 2) {             /* IAC verb option */
                iac_st = 0;
                continue;
            }
            if (ch == 255) {
                iac_st = 1;
                continue;
            }
            if (line_mode) {
                if (ch == 0x1b) {              /* ESC: leave line mode */
                    line_mode = false;
                    tn_puts(fd, "\r\n");
                } else if (ch == '\r' || ch == '\n') {
                    if (ch == '\n' && line_len == 0 && !line_mode)
                        continue;
                    tn_puts(fd, "\r\n");
                    line[line_len] = 0;
                    if (line_len == 0) {
                        line_mode = false;     /* empty line: back to keys */
                    } else {
                        tn_exec_line(fd, line);
                        line_len = 0;
                        tn_puts(fd, ": ");
                    }
                } else if (ch == 0x7f || ch == 0x08) {
                    if (line_len > 0) { line_len--; tn_puts(fd, "\b \b"); }
                } else if (ch >= 0x20 && ch < 0x7f && line_len < (int)sizeof(line) - 1) {
                    line[line_len++] = (char)ch;
                    tn_send(fd, &ch, 1);
                } else if (ch == 0) {
                    /* telnet CR NUL */
                }
                continue;
            }
            if (esc_st == 0 && ch == ':' && !menu_mode) {
                line_mode = true;
                line_len = 0;
                tn_puts(fd, "\r\n: ");
                continue;
            }
            if (esc_st == 0 && ch == 'q')
                return;
            if (esc_st == 0 && ch == 'c' && menu_mode) {
                menu_mode = false;
                tn_puts(fd, "\x1b[0m\x1b[2J\x1b[H-- console --\r\n");
                xSemaphoreTake(s_tee_lock, portMAX_DELAY);
                s_tee_rd = s_tee_wr;
                xSemaphoreGive(s_tee_lock);
                continue;
            }
            if (esc_st == 0 && ch == 'p' && !menu_mode) {
                /* PD status into the console tee: works with the monitor
                 * on the port, when telnet is the only console. */
#if A2MEGA_HAS_USBC_PD
                usbc_pd_status_log();
#else
                tn_puts(fd, "pd: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'f' && !menu_mode) {
                /* Flip the mux FLIPSEL convention live: tests whether the
                 * CC-orientation mapping is inverted (AUX crossed + lanes
                 * on unwatched pins) without any reflash. */
#if A2MEGA_HAS_USBC_PD
                usbc_mux_flip_toggle();
#else
                tn_puts(fd, "flip: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'r' && !menu_mode) {
                /* Restart the FPGA's blind training ladder via HPD pulse. */
#if A2MEGA_HAS_USBC_PD
                usbc_hpd_retrain();
#else
                tn_puts(fd, "retrain: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 't' && !menu_mode) {
                /* PD event trace: did we stop transmitting, or did the
                 * partner never answer? (PD-silent adapter dig.) */
#if A2MEGA_HAS_USBC_PD
                usbc_trace_dump_log();
#else
                tn_puts(fd, "trace: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'u' && !menu_mode) {
                /* Raw FUSB302B status snapshot (in-slot attach debug). */
#if A2MEGA_HAS_USBC_PD
                usbc_fusb_dump_log();
#else
                tn_puts(fd, "fusb: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'd' && !menu_mode) {
                /* Adapter lane census: pin-assignment decode of the last
                 * Discover Modes ACK (a2p25 RBR x4 hub qualification). */
#if A2MEGA_HAS_USBC_PD
                usbc_modes_census_log();
#else
                tn_puts(fd, "census: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'e' && !menu_mode) {
                /* Cycle DP receiver EQ presets on the mux, live. */
#if A2MEGA_HAS_USBC_PD
                usbc_mux_eq_cycle();
#else
                tn_puts(fd, "eq: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'v' && !menu_mode) {
                /* V2.1: virtual replug (CC-open detach + reattach). */
#if A2MEGA_HAS_USBC_PD
                usbc_virtual_replug();
#else
                tn_puts(fd, "replug: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'w' && !menu_mode) {
                /* auto-recovery watch: toggle + status (wedge_watch.c) */
                wedge_watch_toggle_cmd();
                continue;
            }
            if (esc_st == 0 && ch == 'l' && !menu_mode) {
                /* M1: toggle unused mux DP2/DP3 inputs (thermal A/B). */
#if A2MEGA_HAS_USBC_PD
                usbc_mux_lanes23_toggle();
#else
                tn_puts(fd, "lanes: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && (ch == '+' || ch == '-') && !menu_mode) {
                /* Fine EQ step: all 16 mux settings (1.0..14.4 dB). */
#if A2MEGA_HAS_USBC_PD
                usbc_mux_eq_step(ch == '+' ? 1 : -1);
#else
                tn_puts(fd, "eq: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'g' && !menu_mode) {
                /* Reconfigure the FPGA from flash (bench boot-draw
                 * re-roll / recovery; ~2-3 s dark). NEVER a consumer
                 * feature — bench tooling only (decision of record). */
                tn_puts(fd, "fpga: reloading from flash\r\n");
                disk_quiesce();          /* no serving off a dead fabric */
                fpga_jtag_init_pins();
                fpga_jtag_reload();
                fpga_jtag_release_pins();
                disk_request_remount();  /* re-register the disks in the new fabric */
                continue;
            }
            if (esc_st == 0 && ch == 'z' && !menu_mode) {
                /* Video/DOC debug block (FPGA regs 0x70-0x78, the CLI's
                 * viddbg) into the console tee — the WiFi-only bench must
                 * not depend on the USB CDC console for these counters.
                 * The OSPI register reads belong to the main task: raise a
                 * flag that loop() services (reading from this task rebooted
                 * the ESP32 and reset the Apple II, 2026-10-14). */
                viddbg_request = true;
                continue;
            }
            if (esc_st == 0 && ch == 'x' && !menu_mode) {
                /* TUSB1046A register dump — the AUX snooper is the only
                 * on-the-wire view of the FPGA's AUX transmissions. */
#if A2MEGA_HAS_USBC_PD
                usbc_mux_dump_log();
#else
                tn_puts(fd, "mux: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'i' && !menu_mode) {
                /* List responders on the DP I2C bus (mux/PD PHY/DP130). */
#if A2MEGA_HAS_USBC_PD
                usbc_i2c_scan_log();
#else
                tn_puts(fd, "i2c: not built for this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'n' && !menu_mode) {
                /* SN75DP130 raw register dump (auto mode is never touched
                 * from telnet; overrides go through the serial CLI). */
#if A2MEGA_HAS_DP130
                dp130_dump_log(0x00, 0x40);
#else
                tn_puts(fd, "dp130: not on this board rev\r\n");
#endif
                continue;
            }
            if (esc_st == 0 && ch == 'm' && !menu_mode) {
                menu_mode = true;
                last_paint = 0;            /* force full repaint */
                tn_puts(fd, "\x1b[2J");
                /* Force the MENU view specifically: a bare SELECT lands in
                 * whichever MCU view was last active (possibly the console,
                 * where arrows are ignored). */
                menu_request_menu_view();
                continue;
            }
            if (menu_mode) {
                uint16_t b = key_to_buttons(ch, &esc_st);
                if (b)
                    menu_inject(b);
            }
        }

        if (menu_mode) {
            if (!menu_mcu_view_active()) {
                /* B at the root menu (or SELECT) handed the display back
                 * to the Apple II — mirror that instead of showing a
                 * stale frame. */
                menu_mode = false;
                tn_puts(fd, "\x1b[0m\x1b[2J\x1b[H"
                            "-- board returned to Apple II view; "
                            "m to re-enter menu --\r\n");
                xSemaphoreTake(s_tee_lock, portMAX_DELAY);
                s_tee_rd = s_tee_wr;
                xSemaphoreGive(s_tee_lock);
                continue;
            }
            uint32_t gen = fpga_screen_shadow_gen();
            if (gen != last_paint) {
                last_paint = gen;
                render_screen(fd);
            }
        } else {
            /* drain the console tee */
            for (;;) {
                char line[TEE_COLS + 1];
                xSemaphoreTake(s_tee_lock, portMAX_DELAY);
                bool have = s_tee_rd < s_tee_wr;
                if (have) {
                    if (s_tee_wr - s_tee_rd > TEE_LINES)
                        s_tee_rd = s_tee_wr - TEE_LINES;   /* dropped */
                    strcpy(line, s_tee[s_tee_rd % TEE_LINES]);
                    s_tee_rd++;
                }
                xSemaphoreGive(s_tee_lock);
                if (!have)
                    break;
                tn_puts(fd, line);
                tn_puts(fd, "\r\n");
            }
        }
    }
}

static void telnetd_task(void *arg)
{
    (void)arg;
    /* Bind only after lwIP core init has certainly finished (same guard as
     * the BL616 original and ftpd.c: netif_default appearing means the
     * tcpip thread is long past lwip_init). */
    while (netif_default == NULL)
        vTaskDelay(pdMS_TO_TICKS(200));

    int lfd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0)
        vTaskDelete(NULL);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = PP_HTONS(TELNET_PORT);
    sa.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    int one = 1;
    lwip_setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lwip_bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
        lwip_listen(lfd, 1) < 0) {
        lwip_close(lfd);
        vTaskDelete(NULL);
    }
    osd_log("TELNET: LISTENING ON PORT 23");

    for (;;) {
        int fd = lwip_accept(lfd, NULL, NULL);
        if (fd < 0) {
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }
        struct timeval tv = { .tv_sec = 0, .tv_usec = 50 * 1000 };
        lwip_setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        /* A peer that vanishes without closing (port scan, killed nc) stops
         * ACKing; once its window fills an untimed send blocks this thread
         * forever and the single-session server is wedged until reboot. */
        struct timeval stv = { .tv_sec = 3, .tv_usec = 0 };
        lwip_setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof(stv));
        /* Keepalive reaps half-open sessions that go idle (console mode
         * with no log traffic never sends, so SO_SNDTIMEO alone can't). */
        int idle = 10, intvl = 5, cnt = 3;
        lwip_setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        lwip_setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
        lwip_setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
        lwip_setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
        s_client_up = true;
        osd_log("TELNET: CLIENT CONNECTED");
        session(fd);
        s_client_up = false;
        lwip_close(fd);
        osd_log("TELNET: CLIENT DISCONNECTED");
    }
}

void telnetd_init(void)
{
    if (s_tee_lock)
        return;                            /* already running */
    s_tee_lock = xSemaphoreCreateMutex();
    /* Same core/priority band as ftpd: below the lwIP tcpip thread. */
    xTaskCreatePinnedToCore(telnetd_task, "telnetd", 4096, NULL, 4, NULL, 1);
}
