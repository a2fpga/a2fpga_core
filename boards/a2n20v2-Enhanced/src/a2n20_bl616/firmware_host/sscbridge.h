/*
 * sscbridge — Super Serial Card to TCP (Hayes AT modem emulation).
 * See sscbridge.c.
 */
#ifndef _SSCBRIDGE_H
#define _SSCBRIDGE_H

/* Spawn the bridge task (UART1 <-> AT command engine / TCP). */
void sscbridge_init(void);

#endif
