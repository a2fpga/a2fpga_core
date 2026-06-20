# BL616 USB — host-mode support, lessons, and roadmap

How the BL616 does USB on the a2n20v2-Enhanced board, what we learned building
the first USB-host feature (an XInput gamepad that toggles the display), and a
grounded assessment of which other USB device classes are feasible.

## TL;DR

- The BL616 is a **USB 2.0 High-Speed OTG** controller with a **single port**,
  driven by **CherryUSB** in the **EHCI** host model. There is **no OHCI/UHCI
  companion** controller.
- The single port is **host *or* device per firmware build** — not both. The
  default firmware is the **FT2232 device** (JTAG+UART programming bridge); the
  **`firmware_host/`** build is a **USB host**. They are separate images.
- **Working today:** USB-host **XInput gamepad** → pressing **Select** toggles
  the HDMI display between the Apple II output and an MCU-drawn menu.
- The BL616 has **native WiFi 6 + BLE** radios, **but on the Tang Nano 20K there
  is no antenna wired to them — so wireless (native *or* USB dongle) is not an
  option.** Card↔PC communication therefore goes over **wired USB-Ethernet**
  (a host-mode RTL8152 dongle + lwIP) — see §7.

## 1. The hardware

| Property | Value |
|---|---|
| USB controller | USB 2.0 High-Speed OTG (480 Mbps), single port |
| Host model | EHCI, via CherryUSB `port/ehci` |
| Companion controller | **None** (no OHCI/UHCI) |
| Physical connector | the USB-C **Debug** port |
| VBUS | tied to the card's +5V plane through a 6 V / 2 A fuse (bidirectional — so VBUS reads "present" whether or not a PC is attached; it is **not** a reliable "PC connected?" signal) |
| Native radios | WiFi 6 + BLE 5 (on-chip; SDK `components/wireless/{wifi6,bluetooth}`) — **but no antenna is wired on the Tang Nano 20K, so they're unusable here** |
| TCP/IP | lwIP (`components/net/lwip`) |

## 2. Architecture & hard constraints

- **USB role is build-time, mutually exclusive.** CherryUSB selects host
  (`CONFIG_CHERRYUSB_HOST`) or device (`CONFIG_CHERRYUSB_DEVICE`) at compile time;
  this SDK has no runtime dual-role switch on the single port.
  - **Device build** (`firmware/`): FT2232-compatible JTAG + UART + CLI. This is
    how you program the FPGA and use the CLI.
  - **Host build** (`firmware_host/`): USB host. **No FT2232 bridge** (those are
    device endpoints). Flash it via ROM boot mode; run it standalone.
  - *Future:* pick the role at boot by watching for USB **enumeration activity**
    (bus reset / SOF) — a PC enumerates immediately, a bare device doesn't. This
    is essentially how the BL616 ROM two-stage bootloader already decides whether
    a PC is present. (VBUS level can't be used — see the fuse note above.)
- **Host stack needs an RTOS.** The host build pulls in **FreeRTOS** (CherryUSB's
  host OSAL); the FT2232 device build is a bare `while(1)`.
- **The SPI link to the FPGA is independent of USB role** — it works in host or
  device mode. That's what makes the next point possible.
- **No USB serial console in host mode.** Debug via the **DebugOverlay** (the MCU
  writes status to FPGA scratch registers over SPI; the overlay renders them on
  HDMI). See [docs/video-pipeline.md](../../../../../docs/video-pipeline.md#debug-overlay-on-screen-status--diagnostics)
  and the scratch registers in [BL616_SPI_PROTOCOL.md](BL616_SPI_PROTOCOL.md).
  This was the instrument that made the gamepad bring-up debuggable.

## 3. What we built: the XInput gamepad host

In `firmware_host/`:
- A custom CherryUSB host class driver (`usbh_xinput.c`) that matches the XInput
  vendor interface (`bInterfaceClass/SubClass/Protocol = 0xFF/0x5D/0x01`) and
  exposes the controller as `/dev/xinputN`.
- `main.c`: brings up the host stack, runs the device init sequence, async-reads
  the 20-byte input report, and on a **Select** edge toggles `video_control` over
  SPI (Apple II ↔ menu). Live status is surfaced on the DebugOverlay.

Everything in §4 was learned getting this to work.

## 4. Lessons learned (read this before adding USB code)

### 4.1 Host vs device is one-or-the-other
You cannot have the FT2232 programmer **and** a USB host on the one port at the
same time. Program with a PC attached (device build), then run the host build
standalone. Multiple simultaneous USB devices require a **hub**.

### 4.2 Full-speed devices on a high-speed host — init, not transport
Most input devices (gamepads, mice, keyboards) are **full-speed (12 Mbps)**; the
host is **high-speed (480 Mbps)**. We initially *misdiagnosed* direct-connection
failures as "an HS-only EHCI host can't do periodic transfers to a directly
attached full-speed device without a hub's Transaction Translator." **That was
wrong.** The real cause was an **incomplete device init sequence** (see §4.4).
With the correct init, **full-speed devices work connected directly**. A powered
hub is still useful for (a) **power** to bus-powered devices and (b) connecting
**several** devices at once — but it is *not* required for full-speed transport.

### 4.3 Interrupt-IN endpoints must be read asynchronously
A **synchronous** interrupt-IN read (`usbh_int_urb_fill(..., timeout>0,
complete=NULL)` then `usbh_submit_urb`) **always times out** here
(`-ETIMEDOUT`; note newlib `ETIMEDOUT == 116 == 0x74`, not 110). Use the
**async** pattern: `timeout=0` + a completion callback that parses the report and
**re-submits** the URB. (Synchronous **control** and **interrupt-OUT** transfers
work fine — only interrupt-IN needs the callback.)

### 4.4 Vendor devices need a device-specific init sequence
A connected, enumerated controller can sit **silent** (no input reports) until it
gets the init its firmware expects. For **XInput** (ported from the reference
projects in §7), on connect and **before arming the IN read**:
1. `GET_STRING_DESCRIPTOR`, string index 2, lang `0x0409`, len 2, then len 32 —
   *the 8BitDo SN30 Pro specifically needs this; without it the pad never streams.*
2. vendor control `{bmRequestType 0xC1, bRequest 0x01, wValue 0x0100, wIndex 0, len 20}`
3. vendor control `{0xC1, 0x01, 0x0000, 0, len 8}` (skip the `0xC0`/len-4 variant —
   it hangs some 8BitDo adapters)
4. four interrupt-OUT (EP2) packets: `{01 03 02} {02 08 03} {01 03 02} {01 03 06}`

Standard classes (HID, MSC, CDC-ACM) generally need **no** special init.

### 4.5 Hot-plug detection
Detect a newly-plugged device via the **connect callback** (set a flag the poll
loop checks) — **not** by comparing the class-instance pointer. A freed class
struct's address gets reused, so a new device can look like the "same" one by
pointer and skip its init (symptom: hot-swap needs a power cycle). Also scan a
few device slots (`/dev/xinput0..3`) — the slot isn't always `0` right after a
disconnect.
**Known limitation:** hot-swapping a device **behind an external hub** is *not*
detected (re-plug the hub) — CherryUSB's hub driver doesn't propagate the live
downstream port change in this setup. Direct hot-swap works.

### 4.6 VBUS / adapters
The port may not reliably power a bus-powered device through a **passive** USB-C
OTG adapter. Use a **power-passing** adapter or a **self-powered hub** if a device
fails to power up (symptom: never reaches "connected").

### 4.7 Flashing the host build
No FT2232 in host mode, so flash via ROM **boot mode** with
`tools/a2n20-mcu-program` (or the `/flash-mcu` skill). Use **`--baudrate 500000`**
(the 2 Mbaud default is flaky) and `--verify-flash`. See the
[README](../README.md#flash-recommended--a2n20-mcu-program-wrapper).

## 5. Adding a new USB device class

1. **Pick/port the class driver.** The bundled CherryUSB host classes are
   **HID, MSC, CDC-ACM, Hub, Audio, Video**. Others (CDC-ECM, RNDIS, vendor
   net/serial, Bluetooth-HCI) exist **upstream** in CherryUSB and would need to
   be pulled in.
2. **Register it.** For a custom/vendor class, use `CLASS_INFO_DEFINE` to match by
   interface class/subclass/protocol (or VID/PID) — see `usbh_xinput.c`. Confirm
   the entry links into the `usbh_class_info` section.
3. **Read it.** Find the instance (`usbh_find_class_instance("/dev/...")`),
   async-read the interrupt/bulk endpoint (§4.3), parse.
4. **Bridge to the Apple II.** This is the *other half* and is often as much work
   as the USB side: decide how the device's data reaches the Apple II — a control
   register, the keyboard register, an SDRAM region (disk images), a slot card's
   I/O, etc. (see [BL616_SPI_PROTOCOL.md](BL616_SPI_PROTOCOL.md)).

## 6. Roadmap — feasibility per device class

Grounded in the actual SDK (bundled CherryUSB host classes + lwIP + native
WiFi/BLE). "Bridge" = the Apple-II-side integration work, separate from USB.

| Device | USB class | In bundled SDK? | Feasibility | Notes |
|---|---|---|---|---|
| **Mass storage** | MSC (bulk) | ✅ `usbh_msc` + FatFS | **High** | Same FatFS layer we already use for SD; serve disk images from a USB stick. HS bulk, no special init. |
| **Mouse / keyboard** | HID | ✅ `usbh_hid` | **High** | Same machinery as the gamepad; add HID **report-descriptor parsing** (the reference projects include a `hidparser`). Bridge to an Apple II mouse card / keyboard reg. |
| **Serial** | CDC-ACM | ✅ `usbh_cdc_acm` | **Medium** | Works for true CDC-ACM. FTDI/CH340/CP210x/PL2303 use **vendor** drivers (upstream CherryUSB, not bundled — port them). Bridge to a Super Serial Card. |
| **Wired ethernet** | RTL8152 / CDC-ECM / RNDIS / AX88179 | ✅ **working (HW verified: DHCP IP + ping)** | **Medium** | The **primary card↔PC channel** for host mode — see §7. We drive an **RTL8152 via the stock `usbh_rtl8152` vendor driver** + lwIP (CDC-ECM/RTL8153 was tried first but the RTL8153 isn't supported by the vendor driver's chip-version table). |
| **WiFi** | (USB dongle / native) | ❌ | **Not available** | The Tang Nano 20K has **no antenna wired to the BL616**, so the native WiFi 6 radio is unusable. USB WiFi dongles need proprietary vendor drivers + firmware blobs — impractical. So WiFi is off the table; use wired Ethernet (§7). |
| **Bluetooth** | (USB dongle / native) | ❌ | **Not available** | Same antenna problem rules out native BLE. A USB Bluetooth (HCI-over-USB) dongle is theoretically possible but needs a full host BT stack (L2CAP + RFCOMM/GATT) — impractical. |

### Cross-cutting caveats
- **One port, one role.** Host mode gives up the FT2232 programmer. Multiple
  simultaneous USB devices need a hub.
- **Native WiFi/BLE alongside USB host** is theoretically possible (separate
  hardware blocks) but costs significant RAM/CPU and integration effort.
- **The Apple-II bridge is the long pole.** Reading a USB device is usually the
  easy half; getting its data to the Apple II in a form a program can use (slot
  card emulation, registers, SDRAM) is the bulk of each feature.

## 7. Card ↔ PC communication

The card's only physical link to a PC is the BL616's USB. The right approach
depends on whether the BL616 is a USB **device** or **host**:

- **BL616 as a USB *device* (gadget) → PC.** The PC enumerates the BL616 directly
  as a COM port (CDC-ACM) or a USB-Ethernet gadget (RNDIS/ECM). Simplest, no extra
  hardware — and the existing FT2232 device firmware already gives a serial-to-PC
  channel. **But it needs *device* mode**, which is mutually exclusive with USB
  *host* on the single port — so it only fits when the card isn't also hosting
  peripherals.
- **BL616 as a USB *host* + a network *adapter* → network → PC.** When the card
  must stay in **host mode** (peripherals on a hub; no clean runtime
  host↔device switch, and re-cabling a hub of devices is impractical), it reaches
  a PC by hosting a **USB-Ethernet adapter** as one more device on the hub,
  running an IP stack, and talking to the PC **over the network**.

**This project targets the host-mode case, so the host + Ethernet-adapter path is
the one.** (A high-speed USB-Ethernet dongle does *not* hit the full-speed
transport caveats from §4.2 — it's a bulk, HS device.)

### Chosen approach: STOCK `usbh_rtl8152` vendor driver + lwIP — WORKING (HW verified: DHCP IP + ping + hot-plug)
Use an **RTL8152** adapter (`0x0BDA` / `0x8152`) with the **stock CherryUSB
`usbh_rtl8152` vendor driver** — **no SDK edits, no custom driver**. The driver's
`usbh_rtl8152_connect()` does the full chip bring-up (version detect, MAC RX/TX
enable, RX filter, autoneg) and runs its own `usbh_rtl8152_rx_thread`.
- **Enable:** `set(CONFIG_CHERRYUSB_HOST_RTL8152 1)` + `set(CONFIG_LWIP 1)` in
  proj.conf.
- **Two non-obvious build settings — both REQUIRED:**
  - `usb_config.h`: `CONFIG_USBHOST_RTL8152_ETH_MAX_RX_SIZE = 16*1024`. The chip
    reports `rx_buf_sz = 16K`; anything smaller makes `usbh_rtl8152_connect()`
    return `-USB_ERR_NOMEM` and the adapter never comes up.
  - `CMakeLists.txt`: **`-DPBUF_POOL_SIZE=16 -DPBUF_POOL_BUFSIZE=1600`**. ⚠️ The
    SDK's `lwipopts.h` defaults `PBUF_POOL_SIZE` to **0** unless
    `CFG_ETHERNET_ENABLE` is defined → `pbuf_alloc()` fails for *every* received
    frame → RX is silently dropped (no DHCP), even though the chip, USB stack,
    and driver are all healthy. This one line is what makes RX work.
- **IP glue (main.c):** override the driver's weak hooks —
  `usbh_rtl8152_eth_input()` (RX → lwIP), `rtl_linkoutput()` via
  `usbh_rtl8152_get_eth_txbuf()`/`usbh_rtl8152_eth_output()` (TX), and
  `usbh_rtl8152_run/stop` (netif add/remove + DHCP on the tcpip thread; spawn the
  driver's rx_thread). `usbh_get_hport_active_config_index()` returns 0 (the
  RTL8152 uses its default vendor config). `stop` must `netif_remove` (via
  `tcpip_callback`), else a re-plug `netif_add`s an already-added netif and
  hot-plug fails. lwIP needs `bl_rand()` — a small xorshift PRNG in main.c.
- **MVP proof:** the DHCP-leased IP is shown on the HDMI overlay; verified by
  pinging it from a PC, and the adapter hot-swaps with the gamepad under a hub.

**Why not CDC-ECM / RTL8153.** We first tried an **RTL8153** (`0x8153`,
dual-config) via the stock `usbh_cdc_ecm` driver — forcing its config-2 CDC-ECM
with the `usbh_get_hport_active_config_index` hook. It enumerated and TX worked,
but **RX never delivered frames**, which sent us down a long EHCI/data-toggle
rabbit hole. The real blocker turned out to be the `PBUF_POOL_SIZE=0` lwIP
default above — it dropped RX on *every* path, CDC-ECM and vendor alike.
Separately, the stock `usbh_rtl8152` driver's `rtl_ops_init` does **not**
implement the RTL8153's chip version (RTL_VER_09), so the 8153 can't use the
vendor driver. Net: use an **RTL8152** on the native vendor driver + the
pbuf-pool fix. (`usbh_asix`, `usbh_cdc_ncm`, `usbh_rndis` ship too and could be
wired the same way for other adapters.)

### Networking roadmap (smallest → largest)
| Tier | What | Apple II sees | Effort |
|---|---|---|---|
| **1 — MVP** | **MCU on the net**: DHCP + ping / tiny HTTP server. Then config + SD-over-network (HTTP → FatFS / A2FPGA registers). | nothing (MCU-only) | RTL8152 vendor driver + lwIP (**DONE — HW verified: DHCP IP + ping**) |
| **2** | **Virtual modem**: a Hayes-AT parser on the BL616 bridges the FPGA serial ↔ TCP sockets (the Fujinet / "WiFi modem" model). | its existing serial card + a "modem"; works with stock comms software | medium, mostly MCU-side |
| **3** | **Uthernet emulation**: a real IP stack on the Apple II via an emulated network card (IP65 / Contiki). | a network card | large, FPGA + bridge |

**Start with Tier 1** — the immediate goal is just proving Ethernet comms from the
MCU to the network (no Apple II changes). Note that Apple-II **serial-over-Ethernet
is Tier 2 (the virtual-modem pattern) handled on the *MCU*, not the PC**; Tier 3
(Uthernet) is only needed if the Apple II should run its own IP stack.

## 8. References

- This firmware: [`firmware_host/`](../firmware_host/) — `usbh_xinput.c`, `main.c`.
- **nand2mario/firmware-bl616** — `usb/usb_gamepad.cpp`: XInput + HID gamepad host
  on the BL616; the source of the working XInput init sequence.
- **MiSTle-Dev/FPGA-Companion** — `src/bl616/`: gamepad/keyboard/mouse USB host on
  the BL616 (the basis for the above).
- **CherryUSB** — `components/usb/cherryusb/` in the Bouffalo SDK (the host stack;
  class drivers under `class/`).
- [BL616_SPI_PROTOCOL.md](BL616_SPI_PROTOCOL.md) — MCU↔FPGA register/XFER protocol
  (how USB data reaches the Apple II).
- [bl616_ecosystem.md](bl616_ecosystem.md) — board variants, eFuse, boot stages.
- BL616 datasheet / reference manual: <https://github.com/bouffalolab/bl_docs>.
