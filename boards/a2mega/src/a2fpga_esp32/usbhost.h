/*
 * usbhost — ESP32-S3 USB host on the module's own USB-C port (USB1 on the
 * a2p25 / a2mega 1.0a3): the port the BL616 uses on the Tang Nano 20K,
 * wired the same way (D+/D- on the OTG pins, VBUS tied to the board's
 * +5 V through a PTC, Rd on CC). Gamepads, HID keyboards/remotes and
 * (later) mass storage plug in there with the usual C-to-A adapters.
 *
 * Role policy: USB1 is also the Mac CDC/JTAG port. The firmware boots in
 * device mode (hardware USB-Serial-JTAG); usbhost_start() waits a short
 * while for a host to enumerate us and, if none does, re-routes the PHY
 * to the OTG controller in host mode. From then on the CDC console is
 * gone (telnet remains) until the next reset with a Mac attached.
 *
 * Output: a button word in the menu's A2PAD_* layout (a2fpga_regs.h),
 * merged by menu_tick() with the FPGA pad readback.
 */
#ifndef USBHOST_H
#define USBHOST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Start the role-decision task (production builds only). Safe to call once. */
void     usbhost_start(void);
/* true once the PHY has been switched to OTG host mode */
bool     usbhost_active(void);
/* a gamepad (XInput) is attached and initialised */
bool     usbhost_pad_present(void);
/* any HID keyboard / consumer-control device is attached */
bool     usbhost_hid_present(void);
/* current buttons, A2PAD_* layout: gamepad | keyboard/remote mapping */
uint16_t usbhost_buttons(void);
/* one-line status for the OSD/telnet status screens */
const char *usbhost_status_str(void);

/* Everything the host has enumerated right now (hubs and unclaimed devices
 * included), for the USB DEVICES menu screen and the `usb` console command.
 * Walks the usb_host address list and reads descriptors; call from any
 * task. Returns the number of entries filled. */
typedef struct {
    uint8_t  addr;
    uint8_t  speed;          /* usb_speed_t: 0 low, 1 full, 2 high */
    uint16_t vid, pid;
    char     product[32];    /* product string, upper-cased ASCII, "" if none */
    char     kind[14];       /* HUB / STORAGE / KEYBOARD / HID / XINPUT PAD / ETHERNET ... */
    bool     served;         /* claimed by this firmware (stick, pad, remote) */
} usbhost_devinfo_t;
int      usbhost_list(usbhost_devinfo_t *out, int max);
/* console: status line + one line per device; out() gets lines without newline */
void     usbhost_console(void (*out)(void *ctx, const char *line), void *ctx);
/* USB HUB PORT RETRY setting: true = a hub with ganged power switching is
 * cycled too (every device on it re-enumerates), false = refused. Saves the
 * settings blob; returns the save result. */
bool     usbhost_set_hub_retry(bool all_ports);

/* USB mass storage (first MSC device, LUN 0, 512-byte blocks). The
 * read/write helpers block and may be called from any task except the
 * host client task; usbstorage.cpp wraps them for FatFS. */
bool     usbhost_msc_present(void);
bool     usbhost_msc_capacity(uint32_t *blocks, uint32_t *bsize);
bool     usbhost_msc_read(uint32_t lba, uint32_t count, uint8_t *buf);
bool     usbhost_msc_write(uint32_t lba, uint32_t count, const uint8_t *buf);

#ifdef __cplusplus
}
#endif
#endif
