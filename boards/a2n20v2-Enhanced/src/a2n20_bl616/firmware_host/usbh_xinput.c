/*
 * usbh_xinput — CherryUSB host class driver for XInput gamepads.
 * Modeled on the stock usbh_hid.c, minus the HID-specific control transfers
 * (SET_IDLE / GET_REPORT_DESCRIPTOR) which an XInput device would STALL.
 */
#include "usbh_core.h"
#include "usbh_xinput.h"

#define DEV_FORMAT "/dev/xinput%d"

static uint32_t g_devinuse = 0;

static int usbh_xinput_devno_alloc(struct usbh_xinput *xinput_class)
{
    for (int devno = 0; devno < 32; devno++) {
        uint32_t bitno = 1 << devno;
        if ((g_devinuse & bitno) == 0) {
            g_devinuse |= bitno;
            xinput_class->minor = devno;
            return 0;
        }
    }
    return -EMFILE;
}

static void usbh_xinput_devno_free(struct usbh_xinput *xinput_class)
{
    int devno = xinput_class->minor;
    if (devno >= 0 && devno < 32) {
        g_devinuse &= ~(1 << devno);
    }
}

bool usbh_xinput_parse(const uint8_t *buf, int len, struct xinput_state *st)
{
    /* XInput input report: [0]=type(0x00) [1]=len(0x14) [2]=btnLo [3]=btnHi
     * [4]=LT [5]=RT [6..7]=LX [8..9]=LY [10..11]=RX [12..13]=RY */
    if (len < 14 || buf[0] != 0x00 || buf[1] != 0x14) {
        return false;
    }
    st->buttons    = (uint16_t)buf[2] | ((uint16_t)buf[3] << 8);
    st->trig_left  = buf[4];
    st->trig_right = buf[5];
    st->thumb_lx   = (int16_t)((uint16_t)buf[6]  | ((uint16_t)buf[7]  << 8));
    st->thumb_ly   = (int16_t)((uint16_t)buf[8]  | ((uint16_t)buf[9]  << 8));
    st->thumb_rx   = (int16_t)((uint16_t)buf[10] | ((uint16_t)buf[11] << 8));
    st->thumb_ry   = (int16_t)((uint16_t)buf[12] | ((uint16_t)buf[13] << 8));
    return true;
}

static int usbh_xinput_connect(struct usbh_hubport *hport, uint8_t intf)
{
    struct usb_endpoint_descriptor *ep_desc;

    struct usbh_xinput *xinput_class = usb_malloc(sizeof(struct usbh_xinput));
    if (xinput_class == NULL) {
        USB_LOG_ERR("Fail to alloc xinput_class\r\n");
        return -ENOMEM;
    }

    memset(xinput_class, 0, sizeof(struct usbh_xinput));
    usbh_xinput_devno_alloc(xinput_class);
    xinput_class->hport = hport;
    xinput_class->intf = intf;

    hport->config.intf[intf].priv = xinput_class;

    /* Activate the interrupt endpoints on interface 0 (intin = input reports,
     * intout = rumble/LED). No HID control transfers — XInput would STALL. */
    for (uint8_t i = 0; i < hport->config.intf[intf].altsetting[0].intf_desc.bNumEndpoints; i++) {
        ep_desc = &hport->config.intf[intf].altsetting[0].ep[i].ep_desc;
        if (ep_desc->bEndpointAddress & 0x80) {
            usbh_hport_activate_epx(&xinput_class->intin, hport, ep_desc);
        } else {
            usbh_hport_activate_epx(&xinput_class->intout, hport, ep_desc);
        }
    }

    snprintf(hport->config.intf[intf].devname, CONFIG_USBHOST_DEV_NAMELEN, DEV_FORMAT, xinput_class->minor);

    USB_LOG_INFO("Register XInput Class:%s\r\n", hport->config.intf[intf].devname);

    usbh_xinput_run(xinput_class);
    return 0;
}

static int usbh_xinput_disconnect(struct usbh_hubport *hport, uint8_t intf)
{
    struct usbh_xinput *xinput_class = (struct usbh_xinput *)hport->config.intf[intf].priv;

    if (xinput_class) {
        usbh_xinput_devno_free(xinput_class);

        if (xinput_class->intin) {
            usbh_pipe_free(xinput_class->intin);
        }
        if (xinput_class->intout) {
            usbh_pipe_free(xinput_class->intout);
        }

        usbh_xinput_stop(xinput_class);
        memset(xinput_class, 0, sizeof(struct usbh_xinput));
        usb_free(xinput_class);

        if (hport->config.intf[intf].devname[0] != '\0')
            USB_LOG_INFO("Unregister XInput Class:%s\r\n", hport->config.intf[intf].devname);
    }

    return 0;
}

__WEAK void usbh_xinput_run(struct usbh_xinput *xinput_class)
{
    (void)xinput_class;
}

__WEAK void usbh_xinput_stop(struct usbh_xinput *xinput_class)
{
    (void)xinput_class;
}

static const struct usbh_class_driver xinput_class_driver = {
    .driver_name = "xinput",
    .connect = usbh_xinput_connect,
    .disconnect = usbh_xinput_disconnect,
};

CLASS_INFO_DEFINE const struct usbh_class_info xinput_class_info = {
    .match_flags = USB_CLASS_MATCH_INTF_CLASS | USB_CLASS_MATCH_INTF_SUBCLASS | USB_CLASS_MATCH_INTF_PROTOCOL,
    .class = 0xFF,
    .subclass = 0x5D,
    .protocol = 0x01,
    .vid = 0x00,
    .pid = 0x00,
    .class_driver = &xinput_class_driver,
};
