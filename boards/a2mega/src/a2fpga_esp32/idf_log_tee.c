/*
 * idf_log_tee.c -- see idf_log_tee.h
 */
#include "idf_log_tee.h"
#include "osd_console.h"

#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include "esp_log.h"

static vprintf_like_t s_prev;
static volatile bool  s_busy;          /* osd_log() itself logs at INFO; guard anyway */

static int tee_vprintf(const char *fmt, va_list ap)
{
    char buf[160];
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap2);
    va_end(ap2);

    int r = s_prev ? s_prev(fmt, ap) : vprintf(fmt, ap);

    if (n > 3 && buf[0] == 'E' && buf[1] == ' ' && buf[2] == '(' && !s_busy) {
        s_busy = true;
        /* "E (12345) TAG: message\n" -> "TAG: message" */
        char *p = strchr(buf, ')');
        p = p ? p + 1 : buf;
        while (*p == ' ') p++;
        size_t len = strlen(p);
        while (len && (p[len - 1] == '\n' || p[len - 1] == '\r' || p[len - 1] == ' ')) p[--len] = '\0';
        /* 40-column console: first piece verbatim, the rest indented */
        if (len <= 40) {
            osd_log("%s", p);
        } else {
            char piece[41];
            memcpy(piece, p, 40); piece[40] = '\0';
            osd_log("%s", piece);
            p += 40; len -= 40;
            for (int k = 0; k < 2 && len; k++) {           /* at most 3 lines per message */
                size_t take = len > 38 ? 38 : len;
                memcpy(piece + 2, p, take); piece[0] = piece[1] = ' '; piece[2 + take] = '\0';
                osd_log("%s", piece);
                p += take; len -= take;
            }
        }
        s_busy = false;
    }
    return r;
}

void idf_log_tee_init(void)
{
    if (s_prev) return;
    s_prev = esp_log_set_vprintf(tee_vprintf);
    if (!s_prev) s_prev = vprintf;
}
