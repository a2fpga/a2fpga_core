/* usb_urbfix.c -- treat EHCI transaction errors that the controller already
 * recovered from as the successes they are.
 *
 * The bundled CherryUSB EHCI port (bouffalo_sdk v2.3.27, port/ehci/
 * usb_hc_ehci.c ehci_check_qh) fails a finished qTD whenever its XactErr or
 * DataBufErr status bit is set, even when Halted is clear. Per EHCI 1.0
 * 4.10.3/4.15.1 those bits only record that ONE attempt went wrong: the
 * controller retries while the error counter lasts, and a qTD that retired
 * without Halted completed normally (Linux ehci-q.c qtd_copy_status likewise
 * only reports errors for a halted qTD). A halted qTD is mapped to
 * -USB_ERR_STALL before XactErr/DBErr are looked at, so in this port
 * -USB_ERR_IO ALWAYS means "completed after a recovered retry" -- the data
 * and actual_length are good.
 *
 * Why it matters: the hub driver's status-change poll resubmits only after
 * data or a NAK. A false -USB_ERR_IO silently stops it for good, so devices
 * plugged into the hub are never enumerated -- the hub keeps reporting
 * C_CONNECTION on every port and nobody listens. After the OTA warm jump
 * the hub's change report hit this on every attempt in bench testing
 * (2026-11-27: errorcode -12, actual_length 1, data 0x1A = ports 1/3/4),
 * which is why USB never came back without a power-cycle.
 *
 * Fix without patching the SDK: the link wraps usbh_submit_urb
 * (-Wl,--wrap=usbh_submit_urb, see CMakeLists.txt). Synchronous transfers
 * get their return value / errorcode corrected; asynchronous ones get a
 * completion shim that corrects the code before calling the original
 * callback. */
#include <string.h>
#include "usbh_core.h"
#include "usb_urbfix.h"

int __real_usbh_submit_urb(struct usbh_urb *urb);

#define SHIM_SLOTS 24

struct shim_slot {
    struct usbh_urb          *urb;
    usbh_complete_callback_t  complete;
    void                     *arg;
};

static struct shim_slot  s_slot[SHIM_SLOTS];
static volatile uint32_t s_fixed;

uint32_t usb_urbfix_count(void)
{
    return s_fixed;
}

static void urbfix_complete(void *arg, int nbytes)
{
    struct usbh_urb *urb = (struct usbh_urb *)arg;
    usbh_complete_callback_t cb = NULL;
    void *cb_arg = NULL;

    size_t flags = usb_osal_enter_critical_section();
    for (int i = 0; i < SHIM_SLOTS; i++) {
        if (s_slot[i].urb == urb) {
            cb = s_slot[i].complete;
            cb_arg = s_slot[i].arg;
            break;
        }
    }
    usb_osal_leave_critical_section(flags);

    if (nbytes == -USB_ERR_IO) {
        urb->errorcode = 0;
        nbytes = (int)urb->actual_length;
        s_fixed++;
    }
    if (cb)
        cb(cb_arg, nbytes);
}

/* Remember (or refresh) the caller's callback for this URB and route the
 * completion through the shim. Returns false when the table is full, in
 * which case the URB is submitted untouched (old behaviour). */
static bool shim_install(struct usbh_urb *urb)
{
    if (urb->complete == urbfix_complete)
        return true;                /* resubmitted as-is: slot already holds it */

    bool ok = false;
    size_t flags = usb_osal_enter_critical_section();
    int free_i = -1;
    for (int i = 0; i < SHIM_SLOTS; i++) {
        if (s_slot[i].urb == urb) {
            free_i = i;
            break;
        }
        if (free_i < 0 && s_slot[i].urb == NULL)
            free_i = i;
    }
    if (free_i >= 0) {
        s_slot[free_i].urb = urb;
        s_slot[free_i].complete = urb->complete;
        s_slot[free_i].arg = urb->arg;
        urb->complete = urbfix_complete;
        urb->arg = urb;
        ok = true;
    }
    usb_osal_leave_critical_section(flags);
    return ok;
}

int __wrap_usbh_submit_urb(struct usbh_urb *urb)
{
    if (urb && urb->complete)
        shim_install(urb);

    int ret = __real_usbh_submit_urb(urb);

    /* Synchronous transfer (timeout > 0 on entry): the return value is the
     * completion code. */
    if (ret == -USB_ERR_IO) {
        urb->errorcode = 0;
        ret = 0;
        s_fixed++;
    }
    return ret;
}
