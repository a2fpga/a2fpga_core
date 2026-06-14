/*
 * FT2232-compatible USB descriptors for A2N20 BL616 firmware.
 * VID 0x0403 / PID 0x6010 — matches real FT2232D.
 * Interface 0: JTAG (vendor class 0xFF, EP 0x81/0x02)
 * Interface 1: UART (vendor class 0xFF, EP 0x83/0x04)
 */

#include "usbd_core.h"
#include "usbd_ftdi.h"

#ifdef CONFIG_USB_HS
#define EP_MPS 512
#else
#define EP_MPS 64
#endif

const uint8_t ftdi_descriptor[] = {
    /* Device descriptor */
    0x12,                           /* bLength */
    USB_DESCRIPTOR_TYPE_DEVICE,     /* bDescriptorType */
    0x00, 0x02,                     /* bcdUSB: 2.0 */
    0x00,                           /* bDeviceClass: per-interface */
    0x00,                           /* bDeviceSubClass */
    0x00,                           /* bDeviceProtocol */
    0x40,                           /* bMaxPacketSize0: 64 */
    0x03, 0x04,                     /* idVendor: 0x0403 (FTDI) */
    0x10, 0x60,                     /* idProduct: 0x6010 (FT2232) */
    0x00, 0x05,                     /* bcdDevice: 5.00 */
    0x01,                           /* iManufacturer */
    0x02,                           /* iProduct */
    0x03,                           /* iSerialNumber */
    0x01,                           /* bNumConfigurations */

    /* Configuration descriptor */
    0x09,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_CONFIGURATION,      /* bDescriptorType */
    0x37, 0x00,                             /* wTotalLength: 55 */
    0x02,                                   /* bNumInterfaces */
    0x01,                                   /* bConfigurationValue */
    0x00,                                   /* iConfiguration */
    0xA0,                                   /* bmAttributes: remote wakeup */
    0x2D,                                   /* bMaxPower: 90mA */

    /* Interface 0: JTAG (vendor class) */
    0x09,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_INTERFACE,          /* bDescriptorType */
    0x00,                                   /* bInterfaceNumber: 0 */
    0x00,                                   /* bAlternateSetting */
    0x02,                                   /* bNumEndpoints */
    0xFF,                                   /* bInterfaceClass: vendor */
    0xFF,                                   /* bInterfaceSubClass */
    0xFF,                                   /* bInterfaceProtocol */
    0x02,                                   /* iInterface */

    /* EP 0x81 IN (JTAG) */
    0x07,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_ENDPOINT,           /* bDescriptorType */
    JTAG_IN_EP,                             /* bEndpointAddress: 0x81 */
    0x02,                                   /* bmAttributes: bulk */
    (EP_MPS & 0xFF), (EP_MPS >> 8),         /* wMaxPacketSize */
    0x01,                                   /* bInterval */

    /* EP 0x02 OUT (JTAG) */
    0x07,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_ENDPOINT,           /* bDescriptorType */
    JTAG_OUT_EP,                            /* bEndpointAddress: 0x02 */
    0x02,                                   /* bmAttributes: bulk */
    (EP_MPS & 0xFF), (EP_MPS >> 8),         /* wMaxPacketSize */
    0x01,                                   /* bInterval */

    /* Interface 1: UART (vendor class) */
    0x09,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_INTERFACE,          /* bDescriptorType */
    0x01,                                   /* bInterfaceNumber: 1 */
    0x00,                                   /* bAlternateSetting */
    0x02,                                   /* bNumEndpoints */
    0xFF,                                   /* bInterfaceClass: vendor */
    0xFF,                                   /* bInterfaceSubClass */
    0xFF,                                   /* bInterfaceProtocol */
    0x00,                                   /* iInterface */

    /* EP 0x83 IN (UART) */
    0x07,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_ENDPOINT,           /* bDescriptorType */
    CDC_IN_EP,                              /* bEndpointAddress: 0x83 */
    0x02,                                   /* bmAttributes: bulk */
    (EP_MPS & 0xFF), (EP_MPS >> 8),         /* wMaxPacketSize */
    0x01,                                   /* bInterval */

    /* EP 0x04 OUT (UART) */
    0x07,                                   /* bLength */
    USB_DESCRIPTOR_TYPE_ENDPOINT,           /* bDescriptorType */
    CDC_OUT_EP,                             /* bEndpointAddress: 0x04 */
    0x02,                                   /* bmAttributes: bulk */
    (EP_MPS & 0xFF), (EP_MPS >> 8),         /* wMaxPacketSize */
    0x01,                                   /* bInterval */

    /* String descriptor 0: Language ID */
    0x04,
    USB_DESCRIPTOR_TYPE_STRING,
    0x09, 0x04,                             /* English (US) */

    /* String descriptor 1: Manufacturer — "SIPEED" */
    0x0E,
    USB_DESCRIPTOR_TYPE_STRING,
    'S', 0x00,
    'I', 0x00,
    'P', 0x00,
    'E', 0x00,
    'E', 0x00,
    'D', 0x00,

    /* String descriptor 2: Product — "JTAG Debugger" */
    0x1C,
    USB_DESCRIPTOR_TYPE_STRING,
    'J', 0x00,
    'T', 0x00,
    'A', 0x00,
    'G', 0x00,
    ' ', 0x00,
    'D', 0x00,
    'e', 0x00,
    'b', 0x00,
    'u', 0x00,
    'g', 0x00,
    'g', 0x00,
    'e', 0x00,
    'r', 0x00,

    /* String descriptor 3: Serial — "A2N20" */
    0x0C,
    USB_DESCRIPTOR_TYPE_STRING,
    'A', 0x00,
    '2', 0x00,
    'N', 0x00,
    '2', 0x00,
    '0', 0x00,

    /* Device qualifier descriptor */
    0x0A,
    USB_DESCRIPTOR_TYPE_DEVICE_QUALIFIER,
    0x00, 0x02,                             /* bcdUSB: 2.0 */
    0x00,                                   /* bDeviceClass */
    0x00,                                   /* bDeviceSubClass */
    0x00,                                   /* bDeviceProtocol */
    0x40,                                   /* bMaxPacketSize0 */
    0x01,                                   /* bNumConfigurations */
    0x00,                                   /* Reserved */

    /* Terminator */
    0x00
};
