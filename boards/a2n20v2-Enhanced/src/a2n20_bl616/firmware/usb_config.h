#ifndef CHERRYUSB_CONFIG_H
#define CHERRYUSB_CONFIG_H

/* ================ USB common Configuration ================ */

#define CONFIG_USB_PRINTF(...) printf(__VA_ARGS__)

#define usb_malloc(size) malloc(size)
#define usb_free(ptr)    free(ptr)

#ifndef CONFIG_USB_DBG_LEVEL
#define CONFIG_USB_DBG_LEVEL USB_DBG_INFO
#endif

#define CONFIG_USB_PRINTF_COLOR_ENABLE

#ifndef CONFIG_USB_ALIGN_SIZE
#define CONFIG_USB_ALIGN_SIZE 4
#endif

/* BL616 noncacheable RAM section */
#define USB_NOCACHE_RAM_SECTION __attribute__((section(".noncacheable")))

/* ================= USB Device Stack Configuration ================ */

#define CONFIG_USBDEV_REQUEST_BUFFER_LEN 256

/* ================ USB Host Stack Configuration ================== */
/* Required by SDK even in device-only mode (bflb_usb_v2.c includes usbh_core.h) */

#define CONFIG_USBHOST_MAX_RHPORTS          1
#define CONFIG_USBHOST_MAX_EXTHUBS          0
#define CONFIG_USBHOST_MAX_EHPORTS          4
#define CONFIG_USBHOST_MAX_INTERFACES       4
#define CONFIG_USBHOST_MAX_INTF_ALTSETTINGS 8
#define CONFIG_USBHOST_MAX_ENDPOINTS        4

#define CONFIG_USBHOST_MAX_CDC_ACM_CLASS 1
#define CONFIG_USBHOST_MAX_HID_CLASS     1
#define CONFIG_USBHOST_MAX_MSC_CLASS     1
#define CONFIG_USBHOST_MAX_AUDIO_CLASS   1
#define CONFIG_USBHOST_MAX_VIDEO_CLASS   1
#define CONFIG_USBHOST_MAX_RNDIS_CLASS   1

#define CONFIG_USBHOST_DEV_NAMELEN 16

#ifndef CONFIG_USBHOST_PSC_PRIO
#define CONFIG_USBHOST_PSC_PRIO 28
#endif
#ifndef CONFIG_USBHOST_PSC_STACKSIZE
#define CONFIG_USBHOST_PSC_STACKSIZE 2048
#endif

#define CONFIG_USBHOST_REQUEST_BUFFER_LEN 512

#ifndef CONFIG_USBHOST_CONTROL_TRANSFER_TIMEOUT
#define CONFIG_USBHOST_CONTROL_TRANSFER_TIMEOUT 1000
#endif

#ifndef CONFIG_USBHOST_MSC_TIMEOUT
#define CONFIG_USBHOST_MSC_TIMEOUT 5000
#endif

#define CONFIG_USBHOST_PIPE_NUM 10

/* ================ USB Device Port Configuration ================*/

/* BL616 USB EHCI */
#define CONFIG_USB_EHCI_HCCR_BASE       (0x20072000)
#define CONFIG_USB_EHCI_HCOR_BASE       (0x20072000 + 0x10)
#define CONFIG_USB_EHCI_FRAME_LIST_SIZE 1024
#define CONFIG_USB_EHCI_HCOR_RESERVED_DISABLE

#endif
