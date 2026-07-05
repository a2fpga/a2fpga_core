/*
 * telnetd — remote console/menu mirror on TCP port 23 (see telnetd.c).
 */
#ifndef _TELNETD_H
#define _TELNETD_H

/* Spawn the server task. Call after tcpip_init(); binding does not require
 * the interface to be up yet. */
void telnetd_init(void);

/* Tee one console line to a connected client (called by osd_log from any
 * thread; never blocks on the network — ring buffered). */
void telnetd_console_tee(const char *line);

#endif
