/*
 * ftpd.c — small passive-mode FTP server for the SD card (/sdcard).
 *
 * Port of the a2n20v2-Enhanced BL616 ftpd (LAN threat model: USER/PASS
 * accepted as-is). LIST/NLST, RETR/STOR, DELE, MKD/RMD, RNFR/RNTO, SIZE,
 * CWD/CDUP/PWD. Three-session pool because Cyberduck-class clients open a
 * separate control connection per transfer.
 *
 * Differences from the BL616 original: ESP-IDF's VFS/FatFS is reentrant, so
 * file operations are plain POSIX on /sdcard (the BL616 funneled every op
 * through the disk task's FSOP queue); threads are FreeRTOS tasks; the
 * mounted-image guard compares against the disk module's mount snapshots.
 * lwIP sockets are identical, including netif_default for the PASV reply.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "lwip/sockets.h"
#include "lwip/netif.h"

#include "disk.h"
#include "osd_console.h"
#include "ftpd.h"

#define FTP_PORT    21
#define CWD_MAX     192
#define XFER_CHUNK  1460
#define ROOT        "/sdcard"

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
static SemaphoreHandle_t s_fslock;

static void reply(ftps_t *fs, const char *s)
{
    lwip_send(fs->ctl, s, (int)strlen(s), 0);
    lwip_send(fs->ctl, "\r\n", 2, 0);
}

static void replyf(ftps_t *fs, const char *fmt, ...)
{
    char b[224];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    reply(fs, b);
}

/* Full VFS path from a volume-root-relative path */
static void fullpath(const char *rel, char *out, size_t cap)
{
    if (rel[0])
        snprintf(out, cap, ROOT "/%s", rel);
    else
        snprintf(out, cap, ROOT);
}

/* Guard: is this volume-root-relative path one of the mounted images?
 * disk_info_t.name is the image filename without the /sdcard prefix. */
static bool path_mounted(const char *rel)
{
    disk_info_t di;
    for (int v = 0; v < 2; v++) {
        disk_get_floppy_info(v, &di);
        if (di.mounted && di.name[0] && !strcasecmp(di.name, rel))
            return true;
    }
    for (int u = 0; u < 2; u++) {
        disk_get_hdd_info(u, &di);
        if (di.mounted && di.name[0] && !strcasecmp(di.name, rel))
            return true;
    }
    return false;
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
    int dfd = lwip_accept(fs->pasv, NULL, NULL);
    pasv_close(fs);
    return dfd;
}

/* ---- directory listing ---------------------------------------------------- */
static const char *k_mon[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

static void send_list(int dfd, const char *rel, bool names_only)
{
    char full[CWD_MAX + 16];
    fullpath(rel, full, sizeof(full));

    xSemaphoreTake(s_fslock, portMAX_DELAY);
    DIR *d = opendir(full);
    if (!d) {
        xSemaphoreGive(s_fslock);
        return;
    }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        char line[192];
        int n;
        if (names_only) {
            n = snprintf(line, sizeof(line), "%s\r\n", de->d_name);
        } else {
            char fp[CWD_MAX + 288];
            snprintf(fp, sizeof(fp), "%s/%s", full, de->d_name);
            struct stat st;
            if (stat(fp, &st) != 0)
                memset(&st, 0, sizeof(st));
            struct tm tmv;
            time_t t = st.st_mtime;
            localtime_r(&t, &tmv);
            int mo = (tmv.tm_mon >= 0 && tmv.tm_mon < 12) ? tmv.tm_mon : 0;
            n = snprintf(line, sizeof(line),
                         "%crw-r--r--   1 a2fpga a2fpga %10lu %s %2d  %4d %s\r\n",
                         S_ISDIR(st.st_mode) ? 'd' : '-',
                         (unsigned long)st.st_size, k_mon[mo],
                         (tmv.tm_mday >= 1 && tmv.tm_mday <= 31) ? tmv.tm_mday : 1,
                         tmv.tm_year + 1900, de->d_name);
        }
        lwip_send(dfd, line, n, 0);
    }
    closedir(d);
    xSemaphoreGive(s_fslock);
}

/* ---- transfers ------------------------------------------------------------ */
static void do_retr(ftps_t *fs, const char *rel)
{
    char full[CWD_MAX + 16];
    fullpath(rel, full, sizeof(full));

    xSemaphoreTake(s_fslock, portMAX_DELAY);
    FILE *f = fopen(full, "rb");
    xSemaphoreGive(s_fslock);
    if (!f) {
        reply(fs, "550 Not found.");
        return;
    }
    reply(fs, "150 Opening data connection.");
    int dfd = data_accept(fs);
    if (dfd < 0) {
        fclose(f);
        reply(fs, "425 No data connection.");
        return;
    }
    bool ok = true;
    for (;;) {
        xSemaphoreTake(s_fslock, portMAX_DELAY);
        size_t r = fread(fs->xbuf, 1, XFER_CHUNK, f);
        xSemaphoreGive(s_fslock);
        if (r == 0)
            break;
        if (lwip_send(dfd, fs->xbuf, (int)r, 0) < 0) {
            ok = false;
            break;
        }
        if (r < XFER_CHUNK)
            break;
    }
    fclose(f);
    lwip_close(dfd);
    reply(fs, ok ? "226 Transfer complete." : "426 Transfer aborted.");
}

static void do_stor(ftps_t *fs, const char *rel)
{
    if (path_mounted(rel)) {
        reply(fs, "550 File is a mounted disk image; eject it first.");
        return;
    }
    char full[CWD_MAX + 16];
    fullpath(rel, full, sizeof(full));

    xSemaphoreTake(s_fslock, portMAX_DELAY);
    FILE *f = fopen(full, "wb");
    xSemaphoreGive(s_fslock);
    if (!f) {
        reply(fs, "550 Cannot create file.");
        return;
    }
    reply(fs, "150 Opening data connection.");
    int dfd = data_accept(fs);
    if (dfd < 0) {
        fclose(f);
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
        xSemaphoreTake(s_fslock, portMAX_DELAY);
        size_t w = fwrite(fs->xbuf, 1, (size_t)r, f);
        xSemaphoreGive(s_fslock);
        if (w != (size_t)r) {
            ok = false;               /* volume full? */
            break;
        }
    }
    fclose(f);
    lwip_close(dfd);
    reply(fs, ok ? "226 Transfer complete." : "426 Transfer aborted.");
    if (ok)
        osd_log("FTP: STORED %s", rel);
}

/* ---- command loop ---------------------------------------------------------- */
static void session(ftps_t *fs)
{
    char line[256];
    int  len = 0;
    fs->cwd[0] = 0;
    fs->rnfr[0] = 0;

    reply(fs, "220 A2FPGA a2mega FTP ready.");

    for (;;) {
        char c;
        int r = lwip_recv(fs->ctl, &c, 1, 0);
        if (r <= 0)
            return;
        if (c == '\n') {
            line[len] = 0;
            len = 0;
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
            char full[CWD_MAX + 16];
            struct stat st;
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
                    fullpath(path, full, sizeof(full));
                    if (stat(full, &st) == 0 && S_ISDIR(st.st_mode)) {
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
                    fullpath(path, full, sizeof(full));
                    if (stat(full, &st) == 0 && !S_ISDIR(st.st_mode)) {
                        replyf(fs, "213 %lu", (unsigned long)st.st_size);
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
                if (resolve(fs, arg, path, sizeof(path)) && !path_mounted(path)) {
                    fullpath(path, full, sizeof(full));
                    if (unlink(full) == 0) {
                        reply(fs, "250 Deleted.");
                        continue;
                    }
                }
                reply(fs, "550 Delete failed (mounted image?).");
            } else if (!strcmp(line, "MKD") || !strcmp(line, "XMKD")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fullpath(path, full, sizeof(full));
                    if (mkdir(full, 0775) == 0) {
                        replyf(fs, "257 \"/%s\" created.", path);
                        continue;
                    }
                }
                reply(fs, "550 Mkdir failed.");
            } else if (!strcmp(line, "RMD") || !strcmp(line, "XRMD")) {
                if (resolve(fs, arg, path, sizeof(path))) {
                    fullpath(path, full, sizeof(full));
                    if (rmdir(full) == 0) {
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
                    !path_mounted(fs->rnfr) && !path_mounted(path)) {
                    char full2[CWD_MAX + 16];
                    fullpath(fs->rnfr, full, sizeof(full));
                    fullpath(path, full2, sizeof(full2));
                    if (rename(full, full2) == 0) {
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
    vTaskDelete(NULL);
}

static void ftpd_thread(void *arg)
{
    (void)arg;

    /* Wait for the WiFi netif to be up with an address */
    while (netif_default == NULL ||
           netif_ip4_addr(netif_default)->addr == 0)
        vTaskDelay(pdMS_TO_TICKS(500));

    int lfd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = lwip_htons(FTP_PORT);
    sa.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    int one = 1;
    lwip_setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lwip_bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
        lwip_listen(lfd, 2) < 0) {
        osd_log("FTP: BIND FAILED");
        vTaskDelete(NULL);
        return;
    }
    osd_log("FTP: READY ON PORT 21");

    for (;;) {
        int fd = lwip_accept(lfd, NULL, NULL);
        if (fd < 0) {
            vTaskDelay(pdMS_TO_TICKS(500));
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
        xTaskCreatePinnedToCore(session_thread, "ftps", 4096, fs, 2, NULL, 1);
    }
}

void ftpd_init(void)
{
    s_fslock = xSemaphoreCreateMutex();
    xTaskCreatePinnedToCore(ftpd_thread, "ftpd", 4096, NULL, 2, NULL, 1);
}
