/*
 * telnetd — remote console/menu mirror on TCP port 23.
 *
 * One client at a time. Two views, toggled by single keys:
 *
 *   'c'  CONSOLE (default): dumps the osd_console backlog, then streams
 *        every new osd_log() line live (the tee is a lock-protected line
 *        ring so logging threads never block on the network).
 *   'm'  MENU: mirrors the FPGA's 40x24 text page (menu, install pages,
 *        whatever is painted) as ANSI, ~10 Hz on change, and maps keys to
 *        gamepad buttons so the whole menu is drivable remotely:
 *          arrows = D-pad   Enter/a = A (OK)      b/Backspace = B (back)
 *          y = Y (view)     s/Tab = SELECT        [ / ] = LB / RB
 *   'q'  disconnect.
 *
 * Purpose: field support. A beta tester types `telnet a2fpga.local` and we
 * read their console instead of photographs of CRTs.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "lwip/sockets.h"
#include "lwip/netif.h"
#include "usb_osal.h"
#include "usb_config.h"

#include "fpga_screen.h"
#include "osd_console.h"
#include "menu.h"
#include "usbh_xinput.h"
#include "telnetd.h"
#include "fpga_spi.h"
#include "boot_timeline.h"   /* 'b' = boot-milestone timeline */

#define TELNET_PORT     23
#define TEE_LINES       32
#define TEE_COLS        40

/* ---- console tee ring (written by osd_log from any thread) -------------- */
static char     s_tee[TEE_LINES][TEE_COLS + 1];
static volatile uint32_t s_tee_wr;        /* total lines ever written  */
static uint32_t s_tee_rd;                 /* telnet thread's position  */
static usb_osal_mutex_t s_tee_lock;
static volatile bool s_client_up;

void telnetd_console_tee(const char *line)
{
    if (!s_client_up || !s_tee_lock)
        return;
    usb_osal_mutex_take(s_tee_lock);
    snprintf(s_tee[s_tee_wr % TEE_LINES], sizeof(s_tee[0]), "%s", line);
    s_tee_wr++;
    usb_osal_mutex_give(s_tee_lock);
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

/* ---- bus-event FIFO snapshot (diagnostic; 'd' in the console) -------------
 * The gateware samples every Apple II bus cycle into a 512-deep event FIFO
 * (packet bytes = ctrl, data, addr_lo, addr_hi; ctrl = full control-line set
 * [7]rw_n [6]/INH [5]/RESET [4]/IRQ [3]/NMI [2]/DMA [1]/RDY [0]m2sel_n, so the
 * FIFO doubles as a logic analyzer -- no external scope needed). Capture
 * is gated by reg 0x79 (enable) / 0x78 (mode, 0 = everything); entries stream
 * out of XFER SPACE 2 (FPGA_SPACE_FIFO, 4 bytes/entry, auto-popped). We drain
 * any stale entries, arm a fresh window, freeze it, and print the recent fetch
 * addresses -- so we can see what the 6502 is actually doing when the machine
 * is hung: looping in $F8xx (autostart/monitor), parked at the reset vector,
 * or off in garbage. Snapshot on demand, not a continuous stream. */
static uint16_t fifo_count_rd(void)
{
    /* reg 0x70: [7]=empty [6]=full. When full the 9-bit count wraps to 0
     * (512 & 0x1FF), so read the full flag first (rolling buffer sits full). */
    uint8_t stat = fpga_spi_reg_read(0x70);
    if (stat & 0x40) return 512;                 /* full */
    return (uint16_t)fpga_spi_reg_read(0x71) |
           ((uint16_t)(fpga_spi_reg_read(0x72) & 1) << 8);
}

static void bus_snapshot(int fd)
{
    static uint8_t buf[512 * 4];   /* whole rolling window */
    char line[80];

    /* The FIFO captures continuously (rolling: keeps the last ~512 cycles).
     * Freeze it, read the frozen window = the run-up to *now* (or, if the CPU
     * has halted/hung, the run-up to the stall -- the jump target + halting
     * opcode), then re-arm. No fresh-window arming, so a hang is caught. */
    fpga_spi_reg_write(0x79, 0);                 /* freeze rolling capture */

    uint8_t  st  = fpga_spi_reg_read(0x06);      /* [6]=SDRAM_RDY [5]=RESET_N */
    uint16_t cnt = fifo_count_rd();
    snprintf(line, sizeof(line),
             "\r\n-- BUS SNAPSHOT (last %u cycles) --  RESET_N=%d  SDRAM_RDY=%d\r\n",
             cnt, (st >> 5) & 1, (st >> 6) & 1);
    tn_puts(fd, line);

    uint8_t trg = fpga_spi_reg_read(0x1A);       /* [0]=armed [1]=matched */
    if (trg & 0x01) {
        snprintf(line, sizeof(line), " trigger armed, %s\r\n",
                 (trg & 0x02) ? "FIRED (window ends at the trigger cycle)"
                              : "not yet fired (window = latest cycles)");
        tn_puts(fd, line);
    }

    if (cnt == 0) {
        tn_puts(fd, " (rolling buffer empty -- no bus cycles since last read)\r\n");
        fpga_spi_reg_write(0x79, 1);             /* re-arm */
        return;
    }
    /* Read the whole window (oldest..newest). The FIFO streams oldest-first,
     * so the LAST entries are the most recent = the run-up to the hang. */
    uint16_t n = cnt > 512 ? 512 : cnt;
    fpga_spi_xfer_read(FPGA_SPACE_FIFO, 0, buf, n * 4);

    /* stats over the whole window */
    uint16_t amin = 0xFFFF, amax = 0x0000;
    uint16_t rst_a = 0, inh_a = 0;
    for (uint16_t i = 0; i < n; i++) {
        uint8_t  f = buf[i * 4 + 0];
        uint16_t a = (uint16_t)buf[i * 4 + 2] |
                     ((uint16_t)buf[i * 4 + 3] << 8);
        if (a < amin) amin = a;
        if (a > amax) amax = a;
        if (!((f >> 6) & 1)) inh_a++;
        if (!((f >> 5) & 1)) rst_a++;
    }

    /* print the NEWEST up-to-40 in chronological order -- the last line is the
     * final bus cycle before the CPU stopped (jump target / halting opcode).
     * CTRL: [7]rw_n [6]/INH [5]/RESET [4]/IRQ [3]/NMI [2]/DMA [1]/RDY [0]m2sel_n
     * (active-low; decoded columns flag each ASSERTED line, else '-'). */
    uint16_t show  = n > 40 ? 40 : n;
    uint16_t start = n - show;
    tn_puts(fd, " addr rw dat ctl  INH RST IRQ NMI DMA RDY  (newest last)\r\n");
    for (uint16_t i = start; i < n; i++) {
        uint8_t  f = buf[i * 4 + 0];
        uint8_t  d = buf[i * 4 + 1];
        uint16_t a = (uint16_t)buf[i * 4 + 2] |
                     ((uint16_t)buf[i * 4 + 3] << 8);
        snprintf(line, sizeof(line),
                 " %04X %c  %02X %02X   %c   %c   %c   %c   %c   %c\r\n",
                 a, (f & 0x80) ? 'R' : 'W', d, f,
                 ((f >> 6) & 1) ? '-' : 'I',    /* /INH   */
                 ((f >> 5) & 1) ? '-' : 'R',    /* /RESET */
                 ((f >> 4) & 1) ? '-' : 'Q',    /* /IRQ   */
                 ((f >> 3) & 1) ? '-' : 'N',    /* /NMI   */
                 ((f >> 2) & 1) ? '-' : 'D',    /* /DMA   */
                 ((f >> 1) & 1) ? '-' : 'Y');   /* /RDY   */
        tn_puts(fd, line);
    }
    snprintf(line, sizeof(line),
             "-- range $%04X..$%04X, %u cyc; RESET asserted %u/%u, "
             "INH asserted %u/%u --\r\n",
             amin, amax, n, rst_a, n, inh_a, n);
    tn_puts(fd, line);
    fpga_spi_reg_write(0x79, 1);                 /* resume rolling capture */
}

/* Full-buffer variant ('D'): same freeze/read flow as bus_snapshot, but prints
 * ALL entries oldest-first -- boot forensics for the v3 oneshot capture, where
 * the buffer holds the FIRST 512 bus cycles from bridge-start/reset-release and
 * the interesting part is the beginning, not the newest 40. Output is paced in
 * 32-line chunks (tn_send already blocks on the TCP window; the sleep just lets
 * lwIP drain so one 31 KB burst doesn't stall the poll loop). */
static void bus_dump_full(int fd)
{
    static uint8_t buf[512 * 4];
    char line[80];

    fpga_spi_reg_write(0x79, 0);                 /* freeze capture */

    uint8_t  st  = fpga_spi_reg_read(0x06);
    uint16_t cnt = fifo_count_rd();
    snprintf(line, sizeof(line),
             "\r\n-- BUS DUMP (all %u cycles, oldest first) --  RESET_N=%d  SDRAM_RDY=%d\r\n",
             cnt, (st >> 5) & 1, (st >> 6) & 1);
    tn_puts(fd, line);

    uint8_t trg = fpga_spi_reg_read(0x1A);
    if (trg & 0x01) {
        snprintf(line, sizeof(line), " trigger armed, %s\r\n",
                 (trg & 0x02) ? "FIRED (window ends at the trigger cycle)"
                              : "not yet fired");
        tn_puts(fd, line);
    }
    if (fpga_spi_reg_read(0x1F) & 0x01)
        tn_puts(fd, " oneshot ON: window = first cycles after capture start\r\n");

    if (cnt == 0) {
        tn_puts(fd, " (buffer empty)\r\n");
        fpga_spi_reg_write(0x79, 1);
        return;
    }
    uint16_t n = cnt > 512 ? 512 : cnt;
    fpga_spi_xfer_read(FPGA_SPACE_FIFO, 0, buf, n * 4);

    uint16_t amin = 0xFFFF, amax = 0x0000;
    uint16_t rst_a = 0, inh_a = 0;
    tn_puts(fd, "  idx addr rw dat ctl  INH RST IRQ NMI DMA RDY\r\n");
    for (uint16_t i = 0; i < n; i++) {
        uint8_t  f = buf[i * 4 + 0];
        uint8_t  d = buf[i * 4 + 1];
        uint16_t a = (uint16_t)buf[i * 4 + 2] |
                     ((uint16_t)buf[i * 4 + 3] << 8);
        if (a < amin) amin = a;
        if (a > amax) amax = a;
        if (!((f >> 6) & 1)) inh_a++;
        if (!((f >> 5) & 1)) rst_a++;
        snprintf(line, sizeof(line),
                 " %4u %04X %c  %02X %02X   %c   %c   %c   %c   %c   %c\r\n",
                 i, a, (f & 0x80) ? 'R' : 'W', d, f,
                 ((f >> 6) & 1) ? '-' : 'I',    /* /INH   */
                 ((f >> 5) & 1) ? '-' : 'R',    /* /RESET */
                 ((f >> 4) & 1) ? '-' : 'Q',    /* /IRQ   */
                 ((f >> 3) & 1) ? '-' : 'N',    /* /NMI   */
                 ((f >> 2) & 1) ? '-' : 'D',    /* /DMA   */
                 ((f >> 1) & 1) ? '-' : 'Y');   /* /RDY   */
        tn_puts(fd, line);
        if ((i & 31) == 31)
            usb_osal_msleep(2);                  /* let lwIP drain the chunk */
    }
    snprintf(line, sizeof(line),
             "-- range $%04X..$%04X, %u cyc; RESET asserted %u/%u, "
             "INH asserted %u/%u --\r\n",
             amin, amax, n, rst_a, n, inh_a, n);
    tn_puts(fd, line);
    fpga_spi_reg_write(0x79, 1);                 /* resume capture */
}

/* ---- scope mode: continuous bus stream ('s' toggles) ---------------------
 * While active, capture stays armed and each poll iteration drains whatever
 * the FIFO holds and prints it live (addr rw data ctl-hex), so the console
 * acts as a rolling logic-analyzer trace. Sampled, not every-cycle: the FIFO
 * (512 deep) refills as we drain, so bursty CPUs may skip cycles between
 * dumps -- fine for watching where execution sits. */
static void scope_dump_batch(int fd)
{
    static uint8_t buf[64 * 4];
    char line[40];
    uint16_t cnt = fifo_count_rd();
    if (!cnt) return;
    uint16_t n = cnt > 64 ? 64 : cnt;
    fpga_spi_xfer_read(FPGA_SPACE_FIFO, 0, buf, n * 4);
    for (uint16_t i = 0; i < n; i++) {
        uint8_t  f = buf[i * 4 + 0];
        uint8_t  d = buf[i * 4 + 1];
        uint16_t a = (uint16_t)buf[i * 4 + 2] |
                     ((uint16_t)buf[i * 4 + 3] << 8);
        snprintf(line, sizeof(line), "%04X %c %02X %02X\r\n",
                 a, (f & 0x80) ? 'R' : 'W', d, f);
        tn_puts(fd, line);
    }
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
    for (int y = 0; y < 24; y++)
        render_row(fd, fpga_screen_shadow_row(y));
}

/* Map a received key to a one-tick gamepad pulse. Returns 0 if unmapped.
 * st tracks a tiny ESC [ sequence parser for arrows across calls. */
static uint16_t key_to_buttons(uint8_t ch, int *st)
{
    if (*st == 1) {                        /* got ESC */
        *st = (ch == '[') ? 2 : 0;
        return 0;
    }
    if (*st == 2) {                        /* got ESC [ */
        *st = 0;
        switch (ch) {
        case 'A': return XINPUT_DPAD_UP;
        case 'B': return XINPUT_DPAD_DOWN;
        case 'C': return XINPUT_B;         /* right arrow = forward/OK */
        case 'D': return XINPUT_A;         /* left arrow  = back      */
        }
        return 0;
    }
    switch (ch) {
    case 0x1b: *st = 1; return 0;
    case '\r': case '\n': case 'a': return XINPUT_B;   /* OK    */
    case 0x7f: case 0x08: case 'b': return XINPUT_A;   /* back  */
    case 'y':                       return XINPUT_X;   /* view  */
    case 's': case '\t':            return XINPUT_BACK;/* select*/
    case '[':                       return XINPUT_LB;
    case ']':                       return XINPUT_RB;
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
    tn_puts(fd, "\r\nA2FPGA a2n20v2-Enhanced remote console\r\n"
                "keys: c=console m=menu d=snapshot D=full dump s=scope t=trigger o=oneshot b=boot-timeline q=quit\r\n"
                "menu: up/down move, right/enter=ok, left/esc/b=back,\r\n"
                "      y=view, s=select, [ ]=+/-16\r\n\r\n");

    bool menu_mode = false;
    bool scope_mode = false;
    int  trig_sel = -1;        /* -1=off; cycles through trig_presets via 't' */
    int esc_st = 0, iac_st = 0;
    uint32_t last_paint = 0;

    /* start in console mode: replay the on-screen backlog */
    {
        char snap[23][41];
        int n = osd_console_snapshot(snap, 23);
        for (int i = 0; i < n; i++) {
            tn_puts(fd, snap[i]);
            tn_puts(fd, "\r\n");
        }
        usb_osal_mutex_take(s_tee_lock);
        s_tee_rd = s_tee_wr;               /* live from here on */
        usb_osal_mutex_give(s_tee_lock);
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
                menu_inject(XINPUT_A);
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
            if (esc_st == 0 && ch == 'q')
                return;
            if (esc_st == 0 && ch == 'd' && !menu_mode) {
                bus_snapshot(fd);          /* diagnostic bus-address snapshot */
                continue;
            }
            if (esc_st == 0 && ch == 'D' && !menu_mode) {
                bus_dump_full(fd);         /* whole buffer, oldest first */
                continue;
            }
            if (esc_st == 0 && ch == 'b' && !menu_mode) {
                char tl[640];
                bt_format(tl, sizeof(tl)); /* boot-milestone timeline */
                tn_puts(fd, tl);
                continue;
            }
            if (esc_st == 0 && ch == 's' && !menu_mode) {
                scope_mode = !scope_mode;  /* continuous bus stream */
                /* capture runs continuously (rolling); scope just toggles
                 * whether we stream it -- do not disable capture on exit. */
                if (scope_mode)
                    tn_puts(fd, "\r\n-- SCOPE on (s = stop) --\r\n"
                                " addr rw dat ctl  ctl=[7]rw[6]INH[5]RST"
                                "[4]IRQ[3]NMI[2]DMA[1]RDY[0]M2\r\n");
                else
                    tn_puts(fd, "-- SCOPE off --\r\n");
                continue;
            }
            if (esc_st == 0 && ch == 't' && !menu_mode) {
                /* cycle the FIFO freeze-trigger; freezes the rolling buffer on
                 * the first matching address so 'd' shows the run-up to it. */
                if (++trig_sel > 3) trig_sel = -1;
                fpga_spi_reg_write(0x1A, 0);   /* disarm -> clear frozen */
                uint16_t ta = 0, tm = 0;
                const char *nm = "off (rolling)";
                switch (trig_sel) {
                    case 0: ta = 0xC080; tm = 0xFFF0;
                            nm = "$C08x (LC soft-switch)"; break;
                    case 1: ta = 0xFFFE; tm = 0xFFFF;
                            nm = "$FFFE (BRK/IRQ vector fetch)"; break;
                    case 2: ta = 0x0000; tm = 0xFFFF;
                            nm = "$0000 (jump-to-zero / BRK)"; break;
                    case 3: ta = 0xFFFC; tm = 0xFFFF;
                            nm = "$FFFC (RESET vector fetch)"; break;
                    default: break;            /* -1: off */
                }
                if (trig_sel >= 0) {
                    fpga_spi_reg_write(0x1B, ta & 0xFF);
                    fpga_spi_reg_write(0x1C, ta >> 8);
                    fpga_spi_reg_write(0x1D, tm & 0xFF);
                    fpga_spi_reg_write(0x1E, tm >> 8);
                    fpga_spi_reg_write(0x1A, 1);   /* arm */
                }
                char tl[80];
                snprintf(tl, sizeof(tl), "\r\n-- TRIGGER %s%s --\r\n",
                         trig_sel < 0 ? "" : "armed: freeze on ", nm);
                tn_puts(fd, tl);
                continue;
            }
            if (esc_st == 0 && ch == 'o' && !menu_mode) {
                /* Toggle FIFO oneshot (reg 0x1F, v3 gateware). Oneshot=1
                 * (config default) freezes the buffer when full, keeping the
                 * FIRST 512 bus cycles after /RES release; 0 = rolling
                 * (keep the last 512). Note 'd' DRAINS the buffer, so the
                 * first-512 boot capture is readable once per power-cycle. */
                uint8_t os = fpga_spi_reg_read(0x1F) & 0x01;
                fpga_spi_reg_write(0x1F, os ? 0 : 1);
                tn_puts(fd, (os ? "\r\n-- ROLLING (last-512) --\r\n"
                                : "\r\n-- ONESHOT ON (first-512) --\r\n"));
                continue;
            }
            if (esc_st == 0 && ch == 'c' && menu_mode) {
                menu_mode = false;
                tn_puts(fd, "\x1b[0m\x1b[2J\x1b[H-- console --\r\n");
                usb_osal_mutex_take(s_tee_lock);
                s_tee_rd = s_tee_wr;
                usb_osal_mutex_give(s_tee_lock);
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

        if (scope_mode) {
            scope_dump_batch(fd);          /* continuous bus stream */
        } else if (menu_mode) {
            if (!menu_mcu_view_active()) {
                /* B at the root menu (or SELECT) handed the display back
                 * to the Apple II — mirror that instead of showing a
                 * stale frame. */
                menu_mode = false;
                tn_puts(fd, "\x1b[0m\x1b[2J\x1b[H"
                            "-- board returned to Apple II view; "
                            "m to re-enter menu --\r\n");
                usb_osal_mutex_take(s_tee_lock);
                s_tee_rd = s_tee_wr;
                usb_osal_mutex_give(s_tee_lock);
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
                usb_osal_mutex_take(s_tee_lock);
                bool have = s_tee_rd < s_tee_wr;
                if (have) {
                    if (s_tee_wr - s_tee_rd > TEE_LINES)
                        s_tee_rd = s_tee_wr - TEE_LINES;   /* dropped */
                    strcpy(line, s_tee[s_tee_rd % TEE_LINES]);
                    s_tee_rd++;
                }
                usb_osal_mutex_give(s_tee_lock);
                if (!have)
                    break;
                tn_puts(fd, line);
                tn_puts(fd, "\r\n");
            }
        }
    }
}

static void telnetd_thread(void *arg)
{
    (void)arg;
    /* tcpip_init() returns before the tcpip thread has run lwip_init();
     * touching the socket API before that wins a race into uninitialized
     * memp pools and corrupts the stack (manifested as boot hangs around
     * DHCP time). netif_default appearing means core init long finished. */
    while (netif_default == NULL)
        usb_osal_msleep(200);

    /* Arm the rolling bus-event capture up front so the FIFO always holds the
     * last ~512 Apple II cycles -- when the CPU hangs, 'd' then reads the
     * run-up to the stall even though the client connects afterwards. */
    fpga_spi_reg_write(0x78, 0);   /* capture mode = everything */
    fpga_spi_reg_write(0x79, 1);   /* capture enable */

    int lfd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0)
        return;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = PP_HTONS(TELNET_PORT);
    sa.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    int one = 1;
    lwip_setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lwip_bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
        return;
    lwip_listen(lfd, 1);
    osd_log("TELNET: LISTENING ON PORT 23");

    for (;;) {
        int fd = lwip_accept(lfd, NULL, NULL);
        if (fd < 0) {
            usb_osal_msleep(500);
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
    s_tee_lock = usb_osal_mutex_create();
    /* Same priority band as the other app threads — an over-high priority
     * here (above the tcpip thread) is part of how the init race bites. */
    usb_osal_thread_create("telnetd", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                           telnetd_thread, NULL);
}
