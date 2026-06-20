/*
 * CherryUSB config for the a2n20v2-Enhanced BL616 FT2232 device-mode firmware.
 *
 * Based on the CherryUSB v1.5.3 (SDK v2.3.27) cherryusb_config_template.h, with
 * board-specific overrides marked "A2FPGA". The host-side defines are kept
 * because the BL616 USB port driver pulls in usbh_core.h even in device-only
 * mode. Do NOT define CHERRYUSB_VERSION here — common/usb_version.h owns it.
 */
#ifndef CHERRYUSB_CONFIG_H
#define CHERRYUSB_CONFIG_H

/* ================ USB common Configuration ================ */

#define CONFIG_USB_PRINTF(...) printf(__VA_ARGS__)

/* A2FPGA: the SDK no longer provides usb_malloc/usb_free defaults. */
#define usb_malloc(size) malloc(size)
#define usb_free(ptr)    free(ptr)

#ifndef CONFIG_USB_DBG_LEVEL
#define CONFIG_USB_DBG_LEVEL USB_DBG_INFO
#endif

#define CONFIG_USB_PRINTF_COLOR_ENABLE

#ifndef CONFIG_USB_ALIGN_SIZE
#define CONFIG_USB_ALIGN_SIZE 4
#endif

#define USB_NOCACHE_RAM_SECTION __attribute__((section(".noncacheable")))

/* ================= USB Device Stack Configuration ================ */

#ifndef CONFIG_USBDEV_REQUEST_BUFFER_LEN
#define CONFIG_USBDEV_REQUEST_BUFFER_LEN 512
#endif

/* NOTE: do NOT enable CONFIG_USBDEV_ADVANCE_DESC here — this firmware registers
 * a flat descriptor array via usbd_desc_register(), and ADVANCE_DESC would
 * require switching to the struct usb_descriptor API. */

#ifndef CONFIG_USBDEV_EP0_PRIO
#define CONFIG_USBDEV_EP0_PRIO 4
#endif
#ifndef CONFIG_USBDEV_EP0_STACKSIZE
#define CONFIG_USBDEV_EP0_STACKSIZE 2048
#endif

#ifndef CONFIG_USBDEV_MSC_MAX_LUN
#define CONFIG_USBDEV_MSC_MAX_LUN 1
#endif
#ifndef CONFIG_USBDEV_MSC_MAX_BUFSIZE
#define CONFIG_USBDEV_MSC_MAX_BUFSIZE 512
#endif
#ifndef CONFIG_USBDEV_MSC_MANUFACTURER_STRING
#define CONFIG_USBDEV_MSC_MANUFACTURER_STRING ""
#endif
#ifndef CONFIG_USBDEV_MSC_PRODUCT_STRING
#define CONFIG_USBDEV_MSC_PRODUCT_STRING ""
#endif
#ifndef CONFIG_USBDEV_MSC_VERSION_STRING
#define CONFIG_USBDEV_MSC_VERSION_STRING "0.01"
#endif

#ifndef CONFIG_USBDEV_RNDIS_RESP_BUFFER_SIZE
#define CONFIG_USBDEV_RNDIS_RESP_BUFFER_SIZE 156
#endif
#ifndef CONFIG_USBDEV_RNDIS_ETH_MAX_FRAME_SIZE
#define CONFIG_USBDEV_RNDIS_ETH_MAX_FRAME_SIZE 1580
#endif
#ifndef CONFIG_USBDEV_RNDIS_VENDOR_ID
#define CONFIG_USBDEV_RNDIS_VENDOR_ID 0x0000ffff
#endif
#ifndef CONFIG_USBDEV_RNDIS_VENDOR_DESC
#define CONFIG_USBDEV_RNDIS_VENDOR_DESC "CherryUSB"
#endif

/* ================ USB Host Stack Configuration ================== */
/* Required by the SDK even in device-only mode (the BL616 port includes
 * usbh_core.h). */

#define CONFIG_USBHOST_MAX_RHPORTS          1
#define CONFIG_USBHOST_MAX_EXTHUBS          0
#define CONFIG_USBHOST_MAX_EHPORTS          4
#define CONFIG_USBHOST_MAX_INTERFACES       8
#define CONFIG_USBHOST_MAX_INTF_ALTSETTINGS 8
#define CONFIG_USBHOST_MAX_ENDPOINTS        4

#define CONFIG_USBHOST_MAX_CDC_ACM_CLASS 1
#define CONFIG_USBHOST_MAX_HID_CLASS     1
#define CONFIG_USBHOST_MAX_MSC_CLASS     1
#define CONFIG_USBHOST_MAX_AUDIO_CLASS   1
#define CONFIG_USBHOST_MAX_VIDEO_CLASS   1

#define CONFIG_USBHOST_DEV_NAMELEN 16

#ifndef CONFIG_USBHOST_PSC_PRIO
#define CONFIG_USBHOST_PSC_PRIO 28
#endif
#ifndef CONFIG_USBHOST_PSC_STACKSIZE
#define CONFIG_USBHOST_PSC_STACKSIZE 2048
#endif

#ifndef CONFIG_USBHOST_MSOS_VENDOR_CODE
#define CONFIG_USBHOST_MSOS_VENDOR_CODE 0x00
#endif

#ifndef CONFIG_USBHOST_REQUEST_BUFFER_LEN
#define CONFIG_USBHOST_REQUEST_BUFFER_LEN 512
#endif

#ifndef CONFIG_USBHOST_CONTROL_TRANSFER_TIMEOUT
#define CONFIG_USBHOST_CONTROL_TRANSFER_TIMEOUT 1000
#endif

#ifndef CONFIG_USBHOST_MSC_TIMEOUT
#define CONFIG_USBHOST_MSC_TIMEOUT 5000
#endif

/* ================ USB Device Port Configuration ================*/

#ifndef CONFIG_USBDEV_MAX_BUS
#define CONFIG_USBDEV_MAX_BUS 1
#endif

#define CONFIG_USB_MUSB_EP_NUM 8

/* ================ USB Host Port Configuration ==================*/

#ifndef CONFIG_USBHOST_MAX_BUS
#define CONFIG_USBHOST_MAX_BUS 1
#endif

/* ---------------- EHCI Configuration ---------------- */
/* A2FPGA: BL616 USB EHCI register bases. */
#define CONFIG_USB_EHCI_HCCR_BASE       (0x20072000)
#define CONFIG_USB_EHCI_HCOR_BASE       (0x20072000 + 0x10)
#define CONFIG_USB_EHCI_HCCR_OFFSET     (0x0)
#define CONFIG_USB_EHCI_FRAME_LIST_SIZE 1024
#define CONFIG_USB_EHCI_QH_NUM          10
#define CONFIG_USB_EHCI_QTD_NUM         (CONFIG_USB_EHCI_QH_NUM * 3)
#define CONFIG_USB_EHCI_ITD_NUM         10
#define CONFIG_USB_EHCI_HCOR_RESERVED_DISABLE

/* ---------------- OHCI Configuration ---------------- */
#define CONFIG_USB_OHCI_HCOR_OFFSET (0x0)
#define CONFIG_USB_OHCI_ED_NUM 10
#define CONFIG_USB_OHCI_TD_NUM 3

/* ---------------- XHCI Configuration ---------------- */
#define CONFIG_USB_XHCI_HCCR_OFFSET (0x0)

/* ---------------- MUSB Configuration ---------------- */
#define CONFIG_USB_MUSB_PIPE_NUM 8

#ifndef usb_phyaddr2ramaddr
#define usb_phyaddr2ramaddr(addr) (addr)
#endif
#ifndef usb_ramaddr2phyaddr
#define usb_ramaddr2phyaddr(addr) (addr)
#endif

#endif
