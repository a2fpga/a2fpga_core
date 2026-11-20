/*
 * idf_log_tee -- mirror ESP-IDF error-level log lines ("E (ts) TAG: msg")
 * into the OSD / telnet console.
 *
 * Why: the Arduino-built IDF libraries keep only ESP_LOGE (LOG_MAXIMUM_LEVEL
 * 1) and print it to UART0 / the USB-Serial-JTAG console. On the a2p25 and
 * a2mega that port is USB1, which is the USB HOST port whenever a dock is
 * attached, so the one place the usb_host library reports an enumeration
 * failure ("ENUM: Stage GET_SHORT_DEV_DESC FAILED", "HUB: Device has
 * overcurrent!", ...) is unreadable exactly when it matters. This hook
 * copies those lines, split into 40-column pieces, into osd_log(), which the
 * telnet console (port 23) tees to every connected client.
 *
 * Only lines starting with "E (" are mirrored; everything is still passed on
 * to the previous vprintf, so the serial log is unchanged.
 *
 * Hook: the stripped "TAG: msg" of every mirrored line is also handed to
 * one optional callback, so a module can react to a library error it has
 * no API for (usbhost.cpp: "EXT_PORT: [h:p] Port disabled ..." starts the
 * hub-port power-cycle retry). The callback runs in the logging task's
 * context (for usb_host that is its daemon task): post to a queue, do not
 * block, do not log.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void idf_log_tee_init(void);

typedef void (*idf_log_tee_hook_t)(const char *tag_msg);
/* Install (or clear with NULL) the single error-line hook. */
void idf_log_tee_set_hook(idf_log_tee_hook_t hook);

#ifdef __cplusplus
}
#endif
