/*
 * ftpd — minimal FTP server for the storage volume (port 21, one client).
 *
 * Purpose: copy disk images on/off the USB stick over the LAN with a
 * mature client (Cyberduck, FileZilla, lftp) instead of shuttling the
 * stick between machines. Plaintext, LAN-threat-model; any USER/PASS is
 * accepted. Passive mode only (every modern client defaults to PASV;
 * PORT gets 502).
 *
 * Implemented: USER PASS SYST FEAT PWD CWD CDUP TYPE PASV LIST NLST RETR
 * STOR DELE MKD RMD RNFR RNTO SIZE NOOP QUIT. Transfers stream through
 * the disk thread's FS proxy (disk_fs_request) in 4 KB steps, so Disk II
 * track serving never misses its cadence, and the currently MOUNTED
 * image files are protected from STOR/DELE/RNTO (550).
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>

#include "lwip/sockets.h"
#include "lwip/netif.h"
#include "usb_osal.h"
#include "usb_config.h"

#include "disk.h"
#include "osd_console.h"
#include "ftpd.h"

#define FTP_PORT     21
#define XFER_CHUNK   4096
#define CWD_MAX      128

/* Cyberduck (and friends) open a SEPARATE control connection per transfer,
 * so a single-client server times out their uploads. Small session pool;
 * the FS proxy has exactly one FIL/DIR, so open->close operation groups
 * are serialized with s_fslock. */
#define MAX_SESSIONS 3

typedef struct {
    int     ctl;                      /* control connection        */
    int     pasv;                     /* passive listener          */
    char    cwd[CWD_MAX];             /* "" = volume root          */
    char    rnfr[CWD_MAX];            /* pending RNFR source       */
    uint8_t xbuf[XFER_CHUNK];
    volatile bool in_use;
} ftps_t;

static ftps_t s_sess[MAX_SESSIONS];
static usb_osal_mutex_t s_fslock;

static void reply(ftps_t *fs, const char *s)
{
    lwip_send(fs->ctl, s, (int)strlen(s), 0);
    lwip_send(fs->ctl, "\r\n", 2, 0);
}

static void replyf(ftps_t *fs, const char *fmt, ...)
{
    char b[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    reply(fs, b);
}

/* Resolve an FTP path argument against the cwd into out (volume-root
 * relative, no leading slash). Handles absolute paths, "." and "..".
 * Returns false on overflow or attempts to escape the root. */
static bool resolve(ftps_t *fs, const char *arg, char *out, size_t cap)
{
    char tmp[CWD_MAX * 2];
    if (arg[0] == '/')
        snprintf(tmp, sizeof(tmp), "%s", arg + 1);
    else if (fs->cwd[0])
        snprintf(tmp, sizeof(tmp), "%s/%s", fs->cwd, arg);
    else
        snprintf(tmp, sizeof(tmp), "%s", arg);

    /* normalize component by component */
    char comp[CWD_MAX];
    size_t olen = 0;
    out[0] = 0;
    const char *p = tmp;
    while (*p) {
        const char *slash = strchr(p, '/');
        size_t n = slash ? (size_t)(slash - p) : strlen(p);
        if (n >= sizeof(comp))
            return false;
        memcpy(comp, p, n);
        comp[n] = 0;
        p += n + (slash ? 1 : 0);
        if (!n || !strcmp(comp, "."))
            continue;
        if (!strcmp(comp, "..")) {
            char *ls = strrchr(out, '/');
            if (ls)
                *ls = 0;
            else
                out[0] = 0;
            olen = strlen(out);
            continue;
        }
        if (olen + n + 2 > cap)
            return false;
        if (olen)
            out[olen++] = '/';
        memcpy(out + olen, comp, n + 1);
        olen += n;
    }
    return true;
}

/* ---- passive data connections -------------------------------------------- */
static void pasv_close(ftps_t *fs)
{
    if (fs->pasv >= 0) {
        lwip_close(fs->pasv);
        fs->pasv = -1;
    }
}

static void cmd_pasv(ftps_t *fs)
{
    pasv_close(fs);
    fs->pasv = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (fs->pasv < 0) {
        reply(fs, "425 Can't open data connection.");
        return;
    }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = 0;                  /* ephemeral */
    sa.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    if (lwip_bind(fs->pasv, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
        lwip_listen(fs->pasv, 1) < 0) {
        pasv_close(fs);
        reply(fs, "425 Can't open data connection.");
        return;
    }
    socklen_t sl = sizeof(sa);
    lwip_getsockname(fs->pasv, (struct sockaddr *)&sa, &sl);
    uint16_t port = lwip_ntohs(sa.sin_port);
    uint32_t ip = netif_default ? netif_ip4_addr(netif_default)->addr : 0;
    const uint8_t *o = (const uint8_t *)&ip;
    replyf(fs, "227 Entering Passive Mode (%u,%u,%u,%u,%u,%u)",
           o[0], o[1], o[2], o[3], port >> 8, port & 0xFF);
}

/* Accept the queued data connection (client connects after the 227). */
static int data_accept(ftps_t *fs)
{
    if (fs->pasv < 0)
        return -1;
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    lwip_setsockopt(fs->pasv, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int fd = lwip_accept(fs->pasv, NULL, NULL);
    pasv_close(fs);                   /* one transfer per PASV */
    return fd;
}

/* ---- directory listing ---------------------------------------------------- */
static const char *k_mon[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

static void send_list(int dfd, const char *path, bool names_only)
{
    usb_osal_mutex_take(s_fslock);
    fs_req_t r = { .op = FSOP_LIST_OPEN, .path = path };
    if (disk_fs_request(&r) != 0) {
        usb_osal_mutex_give(s_fslock);
        return;
    }
    for (;;) {
        fs_req_t e = { .op = FSOP_LIST_NEXT };
        if (disk_fs_request(&e) != 0 || !e.name[0])
            break;
        char line[128];
        int n;
        if (names_only) {
            n = snprintf(line, sizeof(line), "%s\r\n", e.name);
        } else {
            int yr = 1980 + ((e.fdate >> 9) & 0x7F);
            int mo = (e.fdate >> 5) & 0x0F;
            int dy = e.fdate & 0x1F;
            if (mo < 1 || mo > 12)
                mo = 1;
            n = snprintf(line, sizeof(line),
                         "%crw-r--r--   1 a2fpga a2fpga %10lu %s %2d  %4d %s\r\n",
                         (e.attr & 0x10) ? 'd' : '-',   /* AM_DIR */
                         (unsigned long)e.size, k_mon[mo - 1], dy, yr, e.name);
        }
        lwip_send(dfd, line, n, 0);
    }
    fs_req_t c = { .op = FSOP_LIST_CLOSE };
    disk_fs_request(&c);
    usb_osal_mutex_give(s_fslock);
}

/* ---- transfers ------------------------------------------------------------ */
static void do_retr(ftps_t *fs, const char *path)
{
    usb_osal_mutex_take(s_fslock);
    fs_req_t o = { .op = FSOP_OPEN_R, .path = path };
    if (disk_fs_request(&o) != 0) {
        usb_osal_mutex_give(s_fslock);
        reply(fs, "550 Not found.");
        return;
    }
    reply(fs, "150 Opening data connection.");
    int dfd = data_accept(fs);
    if (dfd < 0) {
        fs_req_t c = { .op = FSOP_CLOSE };
        disk_fs_request(&c);
        usb_osal_mutex_give(s_fslock);
        reply(fs, "425 No data connection.");
        return;
    }
    bool ok = true;
    for (;;) {
        fs_req_t rd = { .op = FSOP_READ, .buf = fs->xbuf, .len = XFER_CHUNK };
        if (disk_fs_request(&rd) != 0) {
            ok = false;
            break;
        }
        if (rd.out == 0)
            break;
        if (lwip_send(dfd, fs->xbuf, (int)rd.out, 0) < 0) {
            ok = false;
            break;
        }
        if (rd.out < XFER_CHUNK)
            break;
    }
    fs_req_t c = { .op = FSOP_CLOSE };
    disk_fs_request(&c);
    usb_osal_mutex_give(s_fslock);
    lwip_close(dfd);
    reply(fs, ok ? "226 Transfer complete." : "426 Transfer aborted.");
}

static void do_stor(ftps_t *fs, const char *path)
{
    if (disk_path_mounted(path)) {
        reply(fs, "550 File is a mounted disk image; eject it first.");
        return;
    }
    usb_osal_mutex_take(s_fslock);
    fs_req_t o = { .op = FSOP_OPEN_W, .path = path };
    if (disk_fs_request(&o) != 0) {
        usb_osal_mutex_give(s_fslock);
        reply(fs, "550 Cannot create file.");
        return;
    }
    reply(fs, "150 Opening data connection.");
    int dfd = data_accept(fs);
    if (dfd < 0) {
        fs_req_t c = { .op = FSOP_CLOSE };
        disk_fs_request(&c);
        usb_osal_mutex_give(s_fslock);
        reply(fs, "425 No data connection.");
        return;
    }
    bool ok = true;
    for (;;) {
        int r = lwip_recv(dfd, fs->xbuf, XFER_CHUNK, 0);
        if (r == 0)
            break;
        if (r < 0) {
            ok = false;
            break;
        }
        fs_req_t wr = { .op = FSOP_WRITE, .buf = fs->xbuf, .len = (uint32_t)r };
        if (disk_fs_request(&wr) != 0 || wr.out != (uint32_t)r) {
            ok = false;               /* volume full? */
            break;
        }
    }
    fs_req_t c = { .op = FSOP_CLOSE };
    disk_fs_request(&c);
    usb_osal_mutex_give(s_fslock);
    lwip_close(dfd);
    reply(fs, ok ? "226 Transfer complete." : "426 Transfer aborted.");
    if (ok)
        osd_log("FTP: STORED %s", path);
}

/* ---- command loop ---------------------------------------------------------- */
static void session(ftps_t *fs)
{
    char line[256];
    int  len = 0;
    fs->cwd[0] = 0;
    fs->rnfr[0] = 0;

    reply(fs, "220 A2FPGA a2n20v2-Enhanced FTP ready.");

    for (;;) {
        char c;
        int r = lwip_recv(fs->ctl, &c, 1, 0);
        if (r <= 0)
            return;
        if (c == '\n') {
            line[len] = 0;
            len = 0;
            /* strip CR */
            char *cr = strchr(line, '\r');
            if (cr)
                *cr = 0;
            if (!line[0])
                continue;

            char *arg = strchr(line, ' ');
            if (arg)
                *arg++ = 0;
            else
                arg = line + strlen(line);
            for (char *p = line; *p; p++)
                *p = (char)toupper((unsigned char)*p);

            char path[CWD_MAX];
            if (!strcmp(line, "USER")) {
                reply(fs, "331 Any password will do.");
            } else if (!strcmp(line, "PASS")) {
                reply(fs, "230 Logged in.");
            } else if (!strcmp(line, "SYST")) {
                reply(fs, "215 UNIX Type: L8");
            } else if (!strcmp(line, "FEAT")) {
                reply(fs, "211-Features:");
                reply(fs, " SIZE");
                reply(fs, " PASV");
                reply(fs, "211 End");
            } else if (!strcmp(line, "TYPE")) {
                reply(fs, "200 Type set.");
            } else if (!strcmp(line, "NOOP")) {
                reply(fs, "200 NOOP.");
            } else if (!strcmp(line, "PWD") || !strcmp(line, "XPWD")) {
                replyf(fs, "257 \"/%s\"", fs->cwd);
            } else if (!strcmp(line, "CWD")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fs_req_t st = { .op = FSOP_STAT, .path = path };
                    if (disk_fs_request(&st) == 0 && (st.attr & 0x10)) {
                        snprintf(fs->cwd, sizeof(fs->cwd), "%s", path);
                        replyf(fs, "250 \"/%s\"", fs->cwd);
                    } else {
                        reply(fs, "550 No such directory.");
                    }
                } else {
                    reply(fs, "550 Bad path.");
                }
            } else if (!strcmp(line, "CDUP")) {
                char *ls = strrchr(fs->cwd, '/');
                if (ls)
                    *ls = 0;
                else
                    fs->cwd[0] = 0;
                replyf(fs, "250 \"/%s\"", fs->cwd);
            } else if (!strcmp(line, "PASV")) {
                cmd_pasv(fs);
            } else if (!strcmp(line, "PORT")) {
                reply(fs, "502 Use passive mode.");
            } else if (!strcmp(line, "LIST") || !strcmp(line, "NLST")) {
                bool nl = !strcmp(line, "NLST");
                /* ignore -a style flags; optional path argument */
                const char *a = (arg[0] && arg[0] != '-') ? arg : "";
                if (!resolve(fs, a, path, sizeof(path))) {
                    reply(fs, "550 Bad path.");
                    continue;
                }
                reply(fs, "150 Here comes the directory listing.");
                int dfd = data_accept(fs);
                if (dfd < 0) {
                    reply(fs, "425 No data connection.");
                    continue;
                }
                send_list(dfd, path, nl);
                lwip_close(dfd);
                reply(fs, "226 Directory send OK.");
            } else if (!strcmp(line, "SIZE")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fs_req_t st = { .op = FSOP_STAT, .path = path };
                    if (disk_fs_request(&st) == 0 && !(st.attr & 0x10)) {
                        replyf(fs, "213 %lu", (unsigned long)st.size);
                        continue;
                    }
                }
                reply(fs, "550 Not found.");
            } else if (!strcmp(line, "RETR")) {
                if (resolve(fs, arg, path, sizeof(path)))
                    do_retr(fs, path);
                else
                    reply(fs, "550 Bad path.");
            } else if (!strcmp(line, "STOR")) {
                if (resolve(fs, arg, path, sizeof(path)))
                    do_stor(fs, path);
                else
                    reply(fs, "550 Bad path.");
            } else if (!strcmp(line, "DELE")) {
                if (resolve(fs, arg, path, sizeof(path)) &&
                    !disk_path_mounted(path)) {
                    fs_req_t d = { .op = FSOP_DELETE, .path = path };
                    if (disk_fs_request(&d) == 0) {
                        reply(fs, "250 Deleted.");
                        continue;
                    }
                }
                reply(fs, "550 Delete failed (mounted image?).");
            } else if (!strcmp(line, "MKD") || !strcmp(line, "XMKD")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fs_req_t d = { .op = FSOP_MKDIR, .path = path };
                    if (disk_fs_request(&d) == 0) {
                        replyf(fs, "257 \"/%s\" created.", path);
                        continue;
                    }
                }
                reply(fs, "550 Mkdir failed.");
            } else if (!strcmp(line, "RMD") || !strcmp(line, "XRMD")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fs_req_t d = { .op = FSOP_RMDIR, .path = path };
                    if (disk_fs_request(&d) == 0) {
                        reply(fs, "250 Removed.");
                        continue;
                    }
                }
                reply(fs, "550 Rmdir failed (not empty?).");
            } else if (!strcmp(line, "RNFR")) {
                if (resolve(fs, arg, fs->rnfr, sizeof(fs->rnfr)))
                    reply(fs, "350 Ready for RNTO.");
                else
                    reply(fs, "550 Bad path.");
            } else if (!strcmp(line, "RNTO")) {
                if (fs->rnfr[0] && resolve(fs, arg, path, sizeof(path)) &&
                    !disk_path_mounted(fs->rnfr) && !disk_path_mounted(path)) {
                    fs_req_t d = { .op = FSOP_RENAME,
                                   .path = fs->rnfr, .path2 = path };
                    if (disk_fs_request(&d) == 0) {
                        reply(fs, "250 Renamed.");
                        fs->rnfr[0] = 0;
                        continue;
                    }
                }
                reply(fs, "550 Rename failed.");
                fs->rnfr[0] = 0;
            } else if (!strcmp(line, "QUIT")) {
                reply(fs, "221 Goodbye.");
                return;
            } else {
                reply(fs, "502 Not implemented.");
            }
        } else if (len < (int)sizeof(line) - 1) {
            line[len++] = c;
        }
    }
}

static void session_thread(void *arg)
{
    ftps_t *fs = (ftps_t *)arg;
    session(fs);
    pasv_close(fs);
    lwip_close(fs->ctl);
    fs->ctl = -1;
    fs->in_use = false;
    osd_log("FTP: CLIENT DISCONNECTED");
    usb_osal_thread_delete(NULL);
}

static void ftpd_thread(void *arg)
{
    (void)arg;
    while (netif_default == NULL)     /* lwIP core init + link (see telnetd) */
        usb_osal_msleep(200);

    int lfd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0)
        return;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = PP_HTONS(FTP_PORT);
    sa.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    int one = 1;
    lwip_setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lwip_bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
        return;
    lwip_listen(lfd, MAX_SESSIONS);
    osd_log("FTP: LISTENING ON PORT 21");

    for (;;) {
        int fd = lwip_accept(lfd, NULL, NULL);
        if (fd < 0) {
            usb_osal_msleep(500);
            continue;
        }
        ftps_t *fs = NULL;
        for (int i = 0; i < MAX_SESSIONS; i++) {
            if (!s_sess[i].in_use) {
                fs = &s_sess[i];
                break;
            }
        }
        if (!fs) {
            const char *busy = "421 Too many connections.\r\n";
            lwip_send(fd, busy, (int)strlen(busy), 0);
            lwip_close(fd);
            continue;
        }
        fs->in_use = true;
        fs->ctl = fd;
        fs->pasv = -1;
        osd_log("FTP: CLIENT CONNECTED");
        usb_osal_thread_create("ftps", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                               session_thread, fs);
    }
}

void ftpd_init(void)
{
    s_fslock = usb_osal_mutex_create();
    usb_osal_thread_create("ftpd", 3072, CONFIG_USBHOST_PSC_PRIO + 1,
                           ftpd_thread, NULL);
}
