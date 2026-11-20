/*
 * usbhub_retry -- bounded recovery ladder for USB devices that fail
 * enumeration behind a hub. Pure logic (no ESP-IDF), host-testable.
 *
 * The ESP-IDF hub driver prebuilt into the Arduino core gives a downstream
 * hub port ONE reset attempt and then disables it:
 *
 *     E (ts) EXT_PORT: [<hub addr>:<port>] Port disabled, reset attempts=1
 *
 * and nothing re-enumerates that port until its connection changes (a
 * replug). The a2p25 bench of 2026-11-19 saw the PNY 13FE:6700 and a
 * Verbatim stick die that way on every plug behind the 05E3:0610 hub while
 * the same PNY enumerates at once on USB1 directly. The 30 ms recovery
 * delay and the single attempt are sdkconfig constants of the prebuilt
 * library and cannot be changed from this tree.
 *
 * usbhost.cpp catches that line through idf_log_tee's hook and manufactures
 * the connection change itself: it opens the hub from our own usb_host
 * client and power-cycles the port over the hub's control pipe
 * (ClearPortFeature / SetPortFeature PORT_POWER), which the hub reports as
 * a fresh connection, so the IDF driver debounces, resets and enumerates
 * again. This module decides WHEN, so the plumbing stays dumb:
 *
 *   - at most USBHUB_RETRY_MAX power cycles per physical plug, with growing
 *     settle and power-off times (usbhub_retry_plan_t);
 *   - a failure line that arrives while a cycle of ours is being executed
 *     is a duplicate and ignored;
 *   - a failure line inside the expectation window after our power-on is
 *     the result of that cycle (next rung, or give up and say so once);
 *   - a failure line outside any window is a NEW plug and restarts the
 *     ladder, except inside a short quiet period after a give-up, so a
 *     driver that prints the line twice cannot restart us;
 *   - a device enumerating on the port, or the port reading empty, resolves
 *     the slot.
 *
 * So the ladder runs again only when a human replugs. Hub-port addressing
 * follows the driver's log: hub = parent device address, port = 1-based
 * downstream port number.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define USBHUB_RETRY_MAX        3       /* power cycles per plug */
#define USBHUB_RETRY_SLOTS      4       /* hub:port pairs tracked at once */
#define USBHUB_RETRY_WINDOW_MS  8000    /* IDF debounce+reset+enum verdict after our power-on */
#define USBHUB_RETRY_QUIET_MS   3000    /* after a give-up: failure lines are echoes, not a replug */

typedef enum {
    USBHUB_RETRY_CYCLE,     /* run plan: wait settle_ms, power the port off for off_ms, back on */
    USBHUB_RETRY_GIVE_UP,   /* ladder exhausted for this plug: log once, do nothing */
    USBHUB_RETRY_IGNORE,    /* duplicate / echo: nothing to do */
} usbhub_retry_action_t;

typedef struct {
    uint8_t  attempt;       /* 1..USBHUB_RETRY_MAX */
    uint16_t settle_ms;     /* let the driver finish recycling the port before we touch it */
    uint16_t off_ms;        /* port power-off time */
} usbhub_retry_plan_t;

enum usbhub_retry_state { USBHUB_SLOT_FREE = 0, USBHUB_SLOT_IDLE, USBHUB_SLOT_CYCLING, USBHUB_SLOT_WAITING };

typedef struct {
    uint8_t  state;         /* enum usbhub_retry_state */
    uint8_t  hub, port;
    uint8_t  attempts;      /* power cycles decided for the current plug */
    uint8_t  gave_up;
    uint32_t until_ms;      /* WAITING: expectation window end; IDLE+gave_up: quiet period end */
} usbhub_retry_slot_t;

typedef struct {
    usbhub_retry_slot_t slot[USBHUB_RETRY_SLOTS];
} usbhub_retry_t;

/* "EXT_PORT: [1:3] Port disabled, reset attempts=1" (the log tee's stripped
 * "TAG: msg" form) -> hub 1, port 3. Anything else -> false. */
bool usbhub_retry_parse_disabled(const char *tag_msg, uint8_t *hub, uint8_t *port);

void usbhub_retry_init(usbhub_retry_t *t);

/* A "Port disabled" line for hub:port arrived at now_ms. On CYCLE, *plan
 * says how; the caller then calls usbhub_retry_cycled() when the port is
 * powered back on, or usbhub_retry_abort() if it could not do it. */
usbhub_retry_action_t usbhub_retry_on_failure(usbhub_retry_t *t, uint8_t hub, uint8_t port,
                                              uint32_t now_ms, usbhub_retry_plan_t *plan);

/* Our power cycle completed (port back on) at now_ms: opens the window in
 * which the next failure line counts as this cycle's result. */
void usbhub_retry_cycled(usbhub_retry_t *t, uint8_t hub, uint8_t port, uint32_t now_ms);

/* The cycle could not be carried out (hub not openable, ganged power, ...):
 * treat like a give-up (caller logs why), quiet period starts at now_ms. */
void usbhub_retry_abort(usbhub_retry_t *t, uint8_t hub, uint8_t port, uint32_t now_ms);

/* A device enumerated on hub:port (or the port read empty): forget it.
 * Returns how many cycles we had run for it (0 = we never touched it). */
int  usbhub_retry_resolved(usbhub_retry_t *t, uint8_t hub, uint8_t port);

/* true while some port awaits the verdict of a cycle of ours -- the only
 * time a NEW_DEV event needs its parent looked up. */
bool usbhub_retry_pending(const usbhub_retry_t *t);

/* The slot of hub:port, or NULL (tests / status). */
const usbhub_retry_slot_t *usbhub_retry_slot(const usbhub_retry_t *t, uint8_t hub, uint8_t port);

#ifdef __cplusplus
}
#endif
