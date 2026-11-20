/*
 * Host tests for the hub-port enumeration retry ladder (usbhub_retry.c):
 * the log-line parser and the bounded cycle / give-up / replug logic.
 */
#include <stdio.h>
#include <string.h>
#include "usbhub_retry.h"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static void test_parse(void)
{
    uint8_t h = 0, p = 0;
    CHECK(usbhub_retry_parse_disabled("EXT_PORT: [1:3] Port disabled, reset attempts=1", &h, &p));
    CHECK(h == 1 && p == 3);
    CHECK(usbhub_retry_parse_disabled("EXT_PORT: [12:4] Port disabled, reset attempts=2", &h, &p));
    CHECK(h == 12 && p == 4);
    CHECK(usbhub_retry_parse_disabled("EXT_PORT: [1:3] Port disabled, reset attempts=1", NULL, NULL));
    /* other EXT_PORT errors are not a disabled port */
    CHECK(!usbhub_retry_parse_disabled("EXT_PORT: [1:3] Enabled, but doesn't have a device", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("EXT_PORT: [1:3] Failed to issue downstream port reset", &h, &p));
    /* other tags, malformed brackets, missing numbers */
    CHECK(!usbhub_retry_parse_disabled("ENUM: Bad transfer status 1: CHECK_SHORT_DEV_DESC", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("HUB: Port disabled", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("EXT_PORT: [1-3] Port disabled", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("EXT_PORT: [:3] Port disabled", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("EXT_PORT: [1:999] Port disabled", &h, &p));
    CHECK(!usbhub_retry_parse_disabled("", &h, &p));
    CHECK(!usbhub_retry_parse_disabled(NULL, &h, &p));
}

/* one plug that never enumerates: 3 cycles, then one give-up, then silence */
static void test_ladder_gives_up(void)
{
    usbhub_retry_t t; usbhub_retry_init(&t);
    usbhub_retry_plan_t plan;
    uint32_t now = 1000;
    for (int k = 1; k <= USBHUB_RETRY_MAX; k++) {
        CHECK(usbhub_retry_on_failure(&t, 1, 3, now, &plan) == USBHUB_RETRY_CYCLE);
        CHECK(plan.attempt == k);
        CHECK(plan.settle_ms == (500u << (k - 1)));
        CHECK(plan.off_ms == 200u * k);
        /* a second line while the cycle runs is an echo */
        CHECK(usbhub_retry_on_failure(&t, 1, 3, now + 10, &plan) == USBHUB_RETRY_IGNORE);
        CHECK(usbhub_retry_pending(&t));
        now += plan.settle_ms + plan.off_ms;
        usbhub_retry_cycled(&t, 1, 3, now);
        now += 1500;                                      /* the driver fails again inside the window */
    }
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now, &plan) == USBHUB_RETRY_GIVE_UP);
    CHECK(!usbhub_retry_pending(&t));
    /* echoes right after the give-up do not restart the ladder */
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now + 100, &plan) == USBHUB_RETRY_IGNORE);
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now + USBHUB_RETRY_QUIET_MS - 1, &plan) == USBHUB_RETRY_IGNORE);
    /* a human replug after the quiet period starts a fresh ladder of 3 */
    now += USBHUB_RETRY_QUIET_MS + 5000;
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 1);
}

/* the second cycle works: NEW_DEV on that port resolves the slot */
static void test_recovers(void)
{
    usbhub_retry_t t; usbhub_retry_init(&t);
    usbhub_retry_plan_t plan;
    uint32_t now = 50000;
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now, &plan) == USBHUB_RETRY_CYCLE);
    usbhub_retry_cycled(&t, 1, 3, now + 700);
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now + 2000, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 2);
    usbhub_retry_cycled(&t, 1, 3, now + 3400);
    CHECK(usbhub_retry_pending(&t));
    CHECK(usbhub_retry_resolved(&t, 1, 3) == 2);
    CHECK(!usbhub_retry_pending(&t));
    CHECK(usbhub_retry_slot(&t, 1, 3) == NULL);
    /* a port we never touched resolves to 0 */
    CHECK(usbhub_retry_resolved(&t, 1, 2) == 0);
    /* the next failure on that port, much later, is a new plug */
    CHECK(usbhub_retry_on_failure(&t, 1, 3, now + 60000, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 1);
}

/* a failure line long after our window is a replug, not our verdict */
static void test_stale_window_restarts(void)
{
    usbhub_retry_t t; usbhub_retry_init(&t);
    usbhub_retry_plan_t plan;
    uint32_t now = 0xFFFFF000u;                           /* straddles the 32-bit wrap */
    CHECK(usbhub_retry_on_failure(&t, 2, 1, now, &plan) == USBHUB_RETRY_CYCLE);
    usbhub_retry_cycled(&t, 2, 1, now + 700);
    CHECK(usbhub_retry_on_failure(&t, 2, 1, now + 700 + 1000, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 2);
    usbhub_retry_cycled(&t, 2, 1, now + 2500);
    now += 2500 + USBHUB_RETRY_WINDOW_MS + 20000;         /* silence: it enumerated, nobody told us; then a replug fails */
    CHECK(usbhub_retry_on_failure(&t, 2, 1, now, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 1);
}

/* abort = give-up with a quiet period, then a replug tries again */
static void test_abort(void)
{
    usbhub_retry_t t; usbhub_retry_init(&t);
    usbhub_retry_plan_t plan;
    CHECK(usbhub_retry_on_failure(&t, 1, 4, 100, &plan) == USBHUB_RETRY_CYCLE);
    usbhub_retry_abort(&t, 1, 4, 700);
    CHECK(!usbhub_retry_pending(&t));
    CHECK(usbhub_retry_on_failure(&t, 1, 4, 800, &plan) == USBHUB_RETRY_IGNORE);
    CHECK(usbhub_retry_on_failure(&t, 1, 4, 700 + USBHUB_RETRY_QUIET_MS, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(plan.attempt == 1);
}

/* more ports than slots: the one longest past its deadline is evicted, a
 * slot whose cycle is running never is */
static void test_slots(void)
{
    usbhub_retry_t t; usbhub_retry_init(&t);
    usbhub_retry_plan_t plan;
    for (int i = 0; i < USBHUB_RETRY_SLOTS; i++) {
        CHECK(usbhub_retry_on_failure(&t, 1, (uint8_t)(i + 1), 1000 + i, &plan) == USBHUB_RETRY_CYCLE);
        if (i) usbhub_retry_cycled(&t, 1, (uint8_t)(i + 1), 2000 + i * 100);   /* port 1 stays CYCLING */
    }
    CHECK(usbhub_retry_on_failure(&t, 1, 9, 50000, &plan) == USBHUB_RETRY_CYCLE);   /* evicts port 2 */
    CHECK(usbhub_retry_slot(&t, 1, 1) != NULL);
    CHECK(usbhub_retry_slot(&t, 1, 2) == NULL);
    CHECK(usbhub_retry_slot(&t, 1, 9) != NULL);
    /* every slot CYCLING: nothing can be evicted, the newcomer is ignored */
    usbhub_retry_init(&t);
    for (int i = 0; i < USBHUB_RETRY_SLOTS; i++) CHECK(usbhub_retry_on_failure(&t, 3, (uint8_t)(i + 1), 10, &plan) == USBHUB_RETRY_CYCLE);
    CHECK(usbhub_retry_on_failure(&t, 3, 7, 20, &plan) == USBHUB_RETRY_IGNORE);
}

int main(void)
{
    test_parse();
    test_ladder_gives_up();
    test_recovers();
    test_stale_window_restarts();
    test_abort();
    test_slots();
    if (fails) { printf("%d FAILED\n", fails); return 1; }
    printf("test_usbhub_retry: all passed\n");
    return 0;
}
