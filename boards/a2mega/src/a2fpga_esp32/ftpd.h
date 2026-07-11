/* ftpd.h — passive-mode FTP server for the SD card (port of the BL616 ftpd) */
#ifndef FTPD_H
#define FTPD_H

#ifdef __cplusplus
extern "C" {
#endif

/* Start the FTP listener task (waits internally for WiFi to be up). */
void ftpd_init(void);

#ifdef __cplusplus
}
#endif

#endif /* FTPD_H */
