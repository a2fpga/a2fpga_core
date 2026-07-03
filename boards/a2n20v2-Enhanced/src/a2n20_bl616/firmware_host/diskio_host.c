/*
 * diskio_host.c — FatFS disk_* entry points for the host build.
 *
 * One FatFS volume (FF_VOLUMES=1, pdrv 0), backed by either the SD card or a USB
 * Mass Storage stick depending on disk_io_set_backend_usb(). The SD path reuses
 * sdmm.c (exported as mmc_disk_*); the USB path calls the CherryUSB usbh_msc
 * SCSI helpers. Compiled only in the host build, which defines
 * FATFS_EXTERNAL_DISKIO so sdmm.c does not also define disk_*.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "ff.h"
#include "diskio.h"

#include "usbh_core.h"
#include "usbh_msc.h"

#include "diskio_host.h"

/* USB Mass Storage bulk DATA must land in a NON-CACHEABLE, aligned buffer: the
 * BL616 USB host DMAs sector data straight into the caller's buffer (only the
 * CBW/CSW go through CherryUSB's own nocache buffers). FatFS's window and the
 * track buffer are cacheable, so reading straight into them returns stale cache
 * (mount fails, FR_NO_FILESYSTEM). Bounce every USB sector through this. */
#define USB_BOUNCE_SECTORS 8
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX
uint8_t g_usb_disk_bounce[USB_BOUNCE_SECTORS * 512];

/* SD backend (sdmm.c). */
extern DSTATUS mmc_disk_status(BYTE drv);
extern DSTATUS mmc_disk_initialize(BYTE drv);
extern DRESULT mmc_disk_read(BYTE drv, BYTE *buff, LBA_t sector, UINT count);
extern DRESULT mmc_disk_write(BYTE drv, const BYTE *buff, LBA_t sector, UINT count);
extern DRESULT mmc_disk_ioctl(BYTE drv, BYTE ctrl, void *buff);

volatile struct usbh_msc *g_msc_class = NULL;
static volatile bool      g_backend_usb = false;

void disk_io_set_backend_usb(bool usb)
{
    g_backend_usb = usb;
}

unsigned long disk_usb_block_count(void)
{
    return g_msc_class ? (unsigned long)g_msc_class->blocknum : 0;
}

unsigned disk_usb_block_size(void)
{
    return g_msc_class ? (unsigned)g_msc_class->blocksize : 0;
}

DSTATUS disk_status(BYTE pdrv)
{
    (void)pdrv;
    if (g_backend_usb)
        return g_msc_class ? 0 : STA_NOINIT;
    return mmc_disk_status(0);
}

DSTATUS disk_initialize(BYTE pdrv)
{
    (void)pdrv;
    if (g_backend_usb)
        return g_msc_class ? 0 : STA_NOINIT;   /* SCSI init done on connect */
    return mmc_disk_initialize(0);
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    (void)pdrv;
    if (g_backend_usb) {
        struct usbh_msc *m = (struct usbh_msc *)g_msc_class;
        if (!m)
            return RES_NOTRDY;
        while (count) {
            UINT n = count > USB_BOUNCE_SECTORS ? USB_BOUNCE_SECTORS : count;
            if (usbh_msc_scsi_read10(m, (uint32_t)sector, g_usb_disk_bounce, n) < 0)
                return RES_ERROR;
            memcpy(buff, g_usb_disk_bounce, (size_t)n * 512u);
            buff += n * 512u;
            sector += n;
            count -= n;
        }
        return RES_OK;
    }
    return mmc_disk_read(0, buff, sector, count);
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    (void)pdrv;
    if (g_backend_usb) {
        struct usbh_msc *m = (struct usbh_msc *)g_msc_class;
        if (!m)
            return RES_NOTRDY;
        while (count) {
            UINT n = count > USB_BOUNCE_SECTORS ? USB_BOUNCE_SECTORS : count;
            memcpy(g_usb_disk_bounce, buff, (size_t)n * 512u);
            if (usbh_msc_scsi_write10(m, (uint32_t)sector, g_usb_disk_bounce, n) < 0)
                return RES_ERROR;
            buff += n * 512u;
            sector += n;
            count -= n;
        }
        return RES_OK;
    }
    return mmc_disk_write(0, buff, sector, count);
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    (void)pdrv;
    if (g_backend_usb) {
        struct usbh_msc *m = (struct usbh_msc *)g_msc_class;
        if (!m)
            return RES_NOTRDY;
        switch (cmd) {
        case CTRL_SYNC:
            return RES_OK;
        case GET_SECTOR_COUNT:
            *(LBA_t *)buff = m->blocknum;
            return RES_OK;
        case GET_SECTOR_SIZE:
            *(WORD *)buff = m->blocksize;
            return RES_OK;
        case GET_BLOCK_SIZE:
            *(DWORD *)buff = 1;
            return RES_OK;
        default:
            return RES_PARERR;
        }
    }
    return mmc_disk_ioctl(0, cmd, buff);
}
