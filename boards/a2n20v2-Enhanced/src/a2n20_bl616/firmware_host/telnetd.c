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
                "keys: c=console m=menu q=quit\r\n"
                "menu: up/down move, right/enter=ok, left/esc/b=back,\r\n"
                "      y=view, s=select, [ ]=+/-16\r\n\r\n");

    bool menu_mode = false;
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

        if (menu_mode) {
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
