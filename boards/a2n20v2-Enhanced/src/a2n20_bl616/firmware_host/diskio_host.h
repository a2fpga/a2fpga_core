/*
 * diskio_host.h — host-build FatFS disk router (SD card or USB Mass Storage).
 *
 * The host build serves the Disk II images from a single FatFS volume whose
 * physical backend is chosen at mount time: a USB Mass Storage stick if one is
 * connected to the BL616 USB host, otherwise the SD card (over the FPGA SPI
 * tunnel). diskio_host.c provides the FatFS disk_* entry points and dispatches
 * to mmc_disk_* (SD, from sdmm.c) or usbh_msc_scsi_* (USB).
 */

#ifndef _DISKIO_HOST_H
#define _DISKIO_HOST_H

#include <stdbool.h>

struct usbh_msc;

/* Active USB Mass Storage class, or NULL when no stick is attached. Set by the
 * usbh_msc_run()/usbh_msc_stop() connect hooks (main.c). */
extern volatile struct usbh_msc *g_msc_class;

/* Select which medium backs the FatFS volume: true = USB stick, false = SD. */
void disk_io_set_backend_usb(bool usb);

/* USB stick geometry (0 if no stick) — for mount-failure diagnostics. */
unsigned long disk_usb_block_count(void);
unsigned      disk_usb_block_size(void);

#endif
