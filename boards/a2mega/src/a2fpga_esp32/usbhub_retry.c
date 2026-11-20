/*
 * usbhub_retry.c -- see usbhub_retry.h
 */
#include "usbhub_retry.h"

#include <string.h>

static bool time_reached(uint32_t now, uint32_t deadline) { return (int32_t)(now - deadline) >= 0; }

static bool parse_u8(const char **pp, uint8_t *out)
{
    const char *p = *pp;
    unsigned v = 0; int n = 0;
    while (*p >= '0' && *p <= '9' && n < 4) { v = v * 10 + (unsigned)(*p - '0'); p++; n++; }
    if (!n || v > 255) return false;
    *out = (uint8_t)v; *pp = p;
    return true;
}

bool usbhub_retry_parse_disabled(const char *tag_msg, uint8_t *hub, uint8_t *port)
{
    static const char tag[] = "EXT_PORT:";
    if (!tag_msg || strncmp(tag_msg, tag, sizeof(tag) - 1) != 0) return false;
    const char *p = tag_msg + sizeof(tag) - 1;
    while (*p == ' ') p++;
    if (*p++ != '[') return false;
    uint8_t h, n;
    if (!parse_u8(&p, &h) || *p++ != ':' || !parse_u8(&p, &n) || *p++ != ']') return false;
    while (*p == ' ') p++;
    if (strncmp(p, "Port disabled", 13) != 0) return false;
    if (hub)  *hub  = h;
    if (port) *port = n;
    return true;
}

void usbhub_retry_init(usbhub_retry_t *t) { memset(t, 0, sizeof(*t)); }

static usbhub_retry_slot_t *find(usbhub_retry_t *t, uint8_t hub, uint8_t port)
{
    for (int i = 0; i < USBHUB_RETRY_SLOTS; i++) {
        usbhub_retry_slot_t *s = &t->slot[i];
        if (s->state != USBHUB_SLOT_FREE && s->hub == hub && s->port == port) return s;
    }
    return NULL;
}

static usbhub_retry_slot_t *alloc(usbhub_retry_t *t, uint8_t hub, uint8_t port, uint32_t now)
{
    usbhub_retry_slot_t *s = NULL;
    for (int i = 0; i < USBHUB_RETRY_SLOTS && !s; i++) if (t->slot[i].state == USBHUB_SLOT_FREE) s = &t->slot[i];
    if (!s) {
        /* all busy: evict the slot whose deadline passed longest ago, never
         * one whose cycle is being executed right now */
        int32_t best = 0;
        for (int i = 0; i < USBHUB_RETRY_SLOTS; i++) {
            usbhub_retry_slot_t *c = &t->slot[i];
            if (c->state == USBHUB_SLOT_CYCLING) continue;
            int32_t age = (int32_t)(now - c->until_ms);
            if (!s || age > best) { s = c; best = age; }
        }
        if (!s) return NULL;
    }
    memset(s, 0, sizeof(*s));
    s->state = USBHUB_SLOT_IDLE; s->hub = hub; s->port = port;
    return s;
}

static void make_plan(uint8_t attempt, usbhub_retry_plan_t *plan)
{
    plan->attempt   = attempt;
    plan->settle_ms = (uint16_t)(500u << (attempt - 1));   /* 500, 1000, 2000 */
    plan->off_ms    = (uint16_t)(200u * attempt);          /* 200, 400, 600  */
}

usbhub_retry_action_t usbhub_retry_on_failure(usbhub_retry_t *t, uint8_t hub, uint8_t port,
                                              uint32_t now, usbhub_retry_plan_t *plan)
{
    usbhub_retry_slot_t *s = find(t, hub, port);
    if (!s) s = alloc(t, hub, port, now);
    if (!s) return USBHUB_RETRY_IGNORE;

    switch (s->state) {
    case USBHUB_SLOT_CYCLING:
        return USBHUB_RETRY_IGNORE;                        /* echo while our cycle runs */
    case USBHUB_SLOT_WAITING:
        if (time_reached(now, s->until_ms)) { s->attempts = 0; s->gave_up = 0; }   /* stale: a new plug */
        break;
    case USBHUB_SLOT_IDLE:
    default:
        if (s->gave_up) {
            if (!time_reached(now, s->until_ms)) return USBHUB_RETRY_IGNORE;      /* echo after give-up */
            s->attempts = 0; s->gave_up = 0;                                      /* a new plug */
        }
        break;
    }
    if (s->attempts >= USBHUB_RETRY_MAX) {
        s->state = USBHUB_SLOT_IDLE; s->gave_up = 1; s->until_ms = now + USBHUB_RETRY_QUIET_MS;
        return USBHUB_RETRY_GIVE_UP;
    }
    s->attempts++;
    s->state = USBHUB_SLOT_CYCLING;
    if (plan) make_plan(s->attempts, plan);
    return USBHUB_RETRY_CYCLE;
}

void usbhub_retry_cycled(usbhub_retry_t *t, uint8_t hub, uint8_t port, uint32_t now)
{
    usbhub_retry_slot_t *s = find(t, hub, port);
    if (!s) return;
    s->state = USBHUB_SLOT_WAITING; s->until_ms = now + USBHUB_RETRY_WINDOW_MS;
}

void usbhub_retry_abort(usbhub_retry_t *t, uint8_t hub, uint8_t port, uint32_t now)
{
    usbhub_retry_slot_t *s = find(t, hub, port);
    if (!s) return;
    s->state = USBHUB_SLOT_IDLE; s->gave_up = 1; s->until_ms = now + USBHUB_RETRY_QUIET_MS;
}

int usbhub_retry_resolved(usbhub_retry_t *t, uint8_t hub, uint8_t port)
{
    usbhub_retry_slot_t *s = find(t, hub, port);
    if (!s) return 0;
    int n = s->attempts;
    memset(s, 0, sizeof(*s));
    return n;
}

bool usbhub_retry_pending(const usbhub_retry_t *t)
{
    for (int i = 0; i < USBHUB_RETRY_SLOTS; i++)
        if (t->slot[i].state == USBHUB_SLOT_WAITING || t->slot[i].state == USBHUB_SLOT_CYCLING) return true;
    return false;
}

const usbhub_retry_slot_t *usbhub_retry_slot(const usbhub_retry_t *t, uint8_t hub, uint8_t port)
{
    return find((usbhub_retry_t *)t, hub, port);
}
