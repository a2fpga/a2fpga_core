/*
 * ftpd — minimal FTP server for the storage volume (see ftpd.c).
 */
#ifndef _FTPD_H
#define _FTPD_H

/* Spawn the server task. Call after tcpip_init(). */
void ftpd_init(void);

#endif
