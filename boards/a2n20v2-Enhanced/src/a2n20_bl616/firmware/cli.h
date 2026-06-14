/*
 * CLI — break-in via Ctrl-X Ctrl-C Enter on UART USB interface.
 * When active, UART passthrough stops and a local command shell runs.
 */

#ifndef _CLI_H
#define _CLI_H

#include <stdbool.h>
#include <stdint.h>

/* Call on each byte flowing through USB→UART to detect break-in sequence */
void cli_feed(uint8_t byte);

/* Returns true when CLI mode is active */
bool cli_is_active(void);

/* Process CLI I/O — call from main loop when cli_is_active() is true */
void cli_process(void);

/* Called from USB IN callback to signal TX completion */
void cli_notify_in_complete(void);

/* Write a string to the CLI terminal (FTDI-framed USB output).
 * Can be called from other modules (e.g., FPGA commands) while CLI is active. */
void cli_write(const char *str);

#endif
