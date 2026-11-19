# a2mega ESP32 Co-Processor — Enhanced Feature-Set Port

> Status (2026-10-25): the port is live on both ESP32 boards (a2mega 1.0a3, a2p25 displayport1; verified on the IIgs); the firmware is `boards/a2mega/src/a2fpga_esp32/`. The register table in this document predates the 2026-10-22 merge, which remapped the DOC telemetry to window registers 40–45 and moved CORE_BUILD from 0x3F to 0x7E; `a2fpga_regs.h` in the firmware tree is the authoritative map until this table is re-synced. The hardware-differences table was updated for board 1.0a3 on 2026-10-25.

Port of the a2n20v2-Enhanced BL616 feature set (on-screen menu, disk-image
serving, slot reconfiguration, Apple II reset hold, Uthernet II networking,
FPGA self-update) to the a2mega's ESP32-S3, continuing the `a2mega-usb-host`
branch work (FPGA-fabric `usb_hid_host` core).

## Hardware differences vs a2n20v2-Enhanced

| Function          | Enhanced (BL616)                   | a2mega (ESP32-S3-MINI-1-N8)                     |
|-------------------|------------------------------------|--------------------------------------------------|
| MCU↔FPGA link     | 4-wire SPI Mode 1, ~20 MHz         | Octal SPI (8-bit parallel), sync-pattern framing |
| Gamepad / HID     | BL616 USB host (XInput)            | **ESP32-S3 USB host** on the board's USB-C port (feature port item P2; the ESP32 writes the pad/key regs 0x16–0x1B) |
| Storage           | USB MSC stick (SD fallback tunnel) | **LittleFS on the ESP32 flash** (images by FTP) and USB mass storage on the ESP32's USB port; no SD card on this board |
| Networking        | USB Ethernet (CDC-ECM/RTL8152)     | **WiFi STA** (raw-frame bridge with MAC NAT) **or a CDC-ECM/NCM USB-Ethernet adapter on USB1** (`usbeth.c`, 2026-11-17; the wire wins when it has carrier) |
| Track/block buffers | SDRAM windows (0x200000/0x204000) | **BSRAM** buffers inside the OSPI connector spaces |
| Menu/console text | SDRAM OSD text page (0x020800)     | **Text VRAM BSRAM (SPACE 1)** + pixel-domain OSD overlay renderer |
| FPGA self-update  | Bit-banged JTAG→W25Q64, GW2AR      | ESP32 JTAG pins (IO40/41/42/45) → GW5AT SPI flash (chip specifics TBV on hardware) |
| MCU self-update   | Staged flash install               | Arduino OTA partition or UF2/USB-CDC reflash (ESP32 is reflashable over its own USB-C) |

The Apple II-facing HDL (DiskII, HDD, Uthernet2, slotmaker) is shared and
unchanged; only the co-processor connector and buffer backing differ.

## Register map — esp32_ospi_connector additions

Existing a2mega layout is kept (device ID 0x00-0x07, video 0x10-0x15, slots
0x30-0x33, volumes 0x40-0x5F, GPU 0x60-0x6F). New registers:

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| 0x07 | STATUS | R | [0]=ready(1) [1]=DDR3 calib done [2]=A2 RESET_N [3]=vol rd/wr pending [4]=HDD rd/wr pending [5]=W5100 doorbell pending [6]=pad report seen. First STATUS read latches `mcu_ready` (used by reset-hold policy). |
| 0x08-0x0B | SYSTIME | R | Free-running 32-bit cycle counter, LE |
| 0x0C-0x0F | SCRATCH1-4 | R/W | With SCRATCH0 (0x06): 40-bit scratch for DebugOverlay use |
| 0x16 | PAD_STATUS | R | [1:0]=last HID type (0 none/1 kbd/2 mouse/3 pad) [2]=connerr [7:4]=report counter |
| 0x17 | PAD_BTNS0 | R | [0]=U [1]=D [2]=L [3]=R [4]=A [5]=B [6]=X [7]=Y |
| 0x18 | PAD_BTNS1 | R | [0]=SELECT [1]=START [7:4]=extra[3:0] |
| 0x19 | KEY_MOD | R | HID keyboard modifiers |
| 0x1A | KEY_0 | R | First HID keycode |
| 0x1B | KEY_1 | R | Second HID keycode |
| 0x26 | HDD0 REQ / CTL | R/W | Read: {wr,rd} pending. Write: [2]=readonly [1]=mounted [0]=ready |
| 0x27 | HDD0 LBA_L / SIZE_L | R/W | Read: requested block LBA[7:0]. Write: volume size[7:0] (blocks) |
| 0x28 | HDD0 LBA_H / SIZE_H | R/W | Read: LBA[15:8]. Write: size[15:8] |
| 0x29 | HDD0 ACK | W | Write-any strobe: request served |
| 0x2A-0x2D | HDD1 * | R/W | Same layout as unit 0 |
| 0x2E | A2_RST_RELEASE | R/W | Write 1: release Apple II from power-on reset hold |
| 0x3C | DBG_DP_RATE | R | Raw DPCD 0x001 MAX_LINK_RATE from the sink's caps read (0x06=RBR 0x0A=HBR 0x14=HBR2 0x1E=HBR3; 0x00 = no DPCD read this HPD session). Adapter-census second gate (telnet 'd'). |
| 0x3D | DBG_DP_LANES | R | Raw DPCD 0x002: [3:0]=MAX_LANE_COUNT, [7]=enhanced framing. Clears with 0x3C on HPD-presence loss. |
| 0x3E | DBG_DP_STATUS | R | [0]=link_established [1]=video_live [2]=wedge_suspect |
| 0x3F | DBG_DP_SERDES | R | SERDES bring-up status {fifo_afull, fifo_full, pll_lock, lane_ready[1:0], ~pcs_tx_rst, tx_running[1:0]} |
| 0x7A | U2_CMD_DOORBELL | R/W | W5100 per-socket Sn_CR pending; write-1-to-clear |

Same addresses as the Enhanced BL616 map for the HDD compact bank (0x26-0x2D),
reset release (0x2E) and doorbell (0x7A), so the firmware port keeps those
constants.

Behavioral fix: VOL0/1 ACK (0x4E/0x5E) becomes a **write-strobe** (one-cycle
pulse), matching `drive_ii`'s ack handshake, instead of the previous level
register.

## Memory spaces (XFER reg 0x7F)

| Space | Contents | Size | Backing |
|-------|----------|------|---------|
| 0 | Test memory | 64B | FFs (kept off BSRAM — the device is near its BSRAM limit) |
| 1 | OSD text page — 40×24 Apple II screen codes, linear `y*40+x` | 2KB | BSRAM, write-only from the ESP32; port B feeds `osd_text_overlay` |
| 2 | Unimplemented (reads return 0xFF) | — | — |
| 3 | W5100 address space (0x0000-0x7FFF) | 32KB | Uthernet2 card port B |
| 4 | Disk II track buffers; addr[13]=drive, 8KB window each (track = 0x1A00 bytes used) | 16KB | 4 byte-lane BSRAMs: byte port (ESP32) + 32-bit byte-enable port (DiskII) |
| 5 | HDD block buffers; addr[9]=unit, 512B each. ESP32 writes must be sequential + 4-byte aligned (word-packing accumulator) | 1KB | one 32-bit BSRAM (the HDD card port is pure 32-bit) |

Track/HDD serving protocol is identical to Enhanced (poll VOL/HDD request
regs → XFER the data → ACK strobe), only the space/window differs (SPACE 4/5
at offset 0 instead of SDRAM SPACE 1 absolute addresses).

## OSD menu rendering

Enhanced writes the Apple II shadowed text page in SDRAM and flips the video
path with VIDEO_ENABLE. On a2mega the shadow lives in DDR3 behind the port
arbiter, so instead the menu uses a dedicated **pixel-domain overlay**:

- ESP32 writes 40×24 Apple II screen codes into SPACE 1 (linear addressing).
- `osd_text_overlay.sv` (clk_pixel, modeled on DebugOverlay) renders the grid
  over the framebuffer output using the shared Apple video ROM (`video.hex`),
  2× scaling → 560×384 centered in 720×480.
- Reg 0x10 VIDEO_ENABLE gates the overlay (0 = Apple passthrough, 1 = menu).
  Inverse/flash screen codes behave as on a real Apple II.

This keeps the menu visible even when the Apple II or DDR3 path is
misbehaving, and needs no DDR3 arbiter changes.

## Reset hold

`a2bus_control_if.reset_hold` policy ported verbatim from
`bl616_spi_connector` (release on reg 0x2E write, ~3 s no-MCU fallback, 15 s
backstop). Top-level drives `a2_res_out_n = reset_hold` — the board routes
FPGA_RES_OUT through an inverting open-drain gate (74LVC2G06, sch p.2), so
logic 1 pulls the Apple II RESET line low.

## Gamepad path

`usb_hid_host` outputs (clk_usb, 60 MHz) are latched on `full_report` and
double-flop synchronized into clk_logic, exposed at regs 0x16-0x1B. The ESP32
polls PAD_STATUS ~50 Hz for menu navigation (SELECT toggles Apple⇄menu, same
button semantics as the Enhanced menu). Keyboard keycodes are exposed for
future use (e.g. Bluetooth keyboards can come in via the ESP32 side later).

## Networking

The FPGA side ports the Enhanced `Uthernet2` (W5100 MACRAW, card ID 5)
unchanged; SPACE 3 + doorbell 0x7A are the same contract. The ESP32 firmware
bridges MACRAW frames to WiFi STA using raw L2 TX
(`esp_wifi_internal_tx`) + promiscuous/std RX callback with **MAC NAT**:
egress frames are rewritten to the ESP32's MAC (ARP sender-MAC and DHCP
chaddr/broadcast-flag fixups included), ingress unicast is rewritten back to
the Apple II's SHAR. This is required because 802.11 STA links only pass the
station's own MAC.

### USB-Ethernet uplink (2026-11-17; RTL8152B running on the a2p25 2026-11-18)

Hardware result 2026-11-18 (a2p25, fw 0c0bf6fb, dock with stick, no HID
dongle): `USB ETH: 0BDA:8152 ECM CFG 2 F4:4D:AD:07:36:0A`, `LINK UP
(ASSUMED)`, `UTHERNET UPLINK: USB ETHERNET`, `USB ETH: IP 192.168.232.176`;
from the LAN the wired address answers ping (1.9 ms), telnet, FTP (full
stick listing) and port 2323 while the WiFi address stays up too. Apple II
side (IP65 over the wire) still to be run.

A USB-Ethernet adapter on USB1 (through the same hub/dock as the gamepad and
stick) is a second uplink. `usbeth.c` is a generic **CDC-ECM / CDC-NCM host
driver** on ESP-IDF `usb_host` (claim control + data interface,
SET_INTERFACE to the data alt setting, SET_ETHERNET_PACKET_FILTER, bulk
IN/OUT, NETWORK_CONNECTION notifications; NCM adds NTB16 framing in
`usbeth_proto.c`, unit-tested in `tests/host/`). It feeds two consumers:

- the Apple II, through the same MAC-NAT scheme as WiFi (adapter MAC as the
  outer MAC), so no promiscuous mode or vendor "set MAC" register is needed
  and any adapter works the same way;
- the ESP32's own lwIP, through an `esp_netif` attached to the driver
  (route priority 120, above WiFi STA's 100), so telnet/FTP/port 2323 are
  reachable over the wire with or without WiFi configured.

`net_uplink.c` owns the `w5100_bridge_*` hooks and routes them: USB when the
adapter reports carrier, WiFi otherwise; only the active uplink delivers
frames to the Apple II. The CLI's `net` shows the active uplink and the
adapter's state; the OSD **NETWORK** page (also over the telnet menu mirror)
shows `UTHERNET UPLINK`, the adapter's MAC/link/IP and the Apple II frame
counters per uplink (`USB A2 FRAMES RX/TX`, `WIFI A2 FRAMES RX/TX`) with a
REFRESH item, so "did that go over the wire?" is answerable on screen. The
console logs `UTHERNET UPLINK: ...` whenever the choice changes. Caveat: on
adapters without a usable notification pipe (Realtek, see below) a pulled
cable is not detected, so the Apple II stays on the wire instead of falling
back to WiFi; re-plugging the adapter does switch.

Limits and the two 2026-11-18 hardware findings:

- **Eight host channels.** The ESP32-S3 OTG core has 8 host channels and
  the IDF host library pins one to every pipe for the life of the device:
  each device's EP0, each claimed endpoint, each hub's EP0 + status
  interrupt. On the a2p25 dock that is hub 2 + USB stick 3 + the 4842
  keyboard/remote dongle 3 = 8, so a USB-Ethernet adapter could not even get
  its EP0 pipe: enumeration failed inside the library with no event to the
  firmware (`HCD DWC: No more HCD channels available`). An adapter needs
  EP0 + bulk IN + bulk OUT = 3, so **stick + Ethernet + a HID dongle do not
  fit together**; the driver claims the data interface first and takes the
  notification pipe only if a channel is left (otherwise the link is
  assumed up after 3 s). IDF error lines are now mirrored into the OSD /
  telnet console by `idf_log_tee.c` (the serial console is USB1, i.e. the
  host port, so it is unreadable exactly when a dock is attached).
- **Dual-configuration Realtek parts.** RTL8152B 0BDA:8152 (measured): cfg 1
  = vendor FF/FF with bulk 0x81/0x02 + interrupt 0x83; cfg 2 = CDC-ECM on
  the same bulk pair, iMACAddress 3. The library enumerates configuration 1
  only (its enumeration filter is compiled out of the Arduino libs, and the
  internal `usbh_dev_set_config_desc()` only works in the addressed state).
  `usbeth_attach_alt()` reads the other configurations itself, sends
  SET_CONFIGURATION, then overwrites the library's cached copy of the
  active configuration (the buffer `usb_host_get_active_config_descriptor()`
  returns, parsed on every claim/release) with a 32-byte stand-in that lists
  only the ECM data interface and its two bulk endpoints
  (`cdc_build_min_config()`), and claims that: exactly two pipes, no
  endpoint-coincidence requirement, no notification pipe. Host-tested with
  the captured RTL8152 descriptors.

The ESP32-S3 OTG is **Full Speed** (adapters run at 12 Mbit/s with 64-byte
bulk packets — fine for the Apple II). The wired netif always uses DHCP (the
static-IP setting applies to WiFi). Why generic class drivers rather than the BL616's vendor drivers:
the Enhanced's CDC-ECM failure was a CherryUSB host-side bulk-IN problem,
not an ECM one, and the IDF bulk-IN path is proven by mass storage.

## Firmware (boards/a2mega/src/a2fpga_esp32, Arduino CLI build)

Continues the existing sketch + `a2fpga_ospi_link` transport. New modules
ported from `a2n20_bl616/firmware_host`:

- `fpga_link.*` — register/XFER helpers over `a2spi` (mutex-guarded)
- `fpga_screen.*` — 40×24 screen-code text writer (SPACE 1 linear)
- `menu.*`, `osd_console.*` — ported UI, gamepad polled from FPGA regs
- `settings.*` — same blob layout, stored in NVS (Preferences)
- `disk.*`, `gcr_dsk.*` — image mount/track-serve, FatFS→VFS (`SD_MMC`)
- `w5100.*`, `wifi_bridge.*`, `usbeth.*`, `net_uplink.*` — W5100 poll loop; WiFi raw-frame MAC-NAT bridge; CDC-ECM/NCM USB-Ethernet uplink; uplink selection.
  Configured by `wifi.txt` in the SD card root (line 1 SSID, line 2
  password; optional lines 3-5 = static IP/netmask/gateway, else DHCP)
- `fpgaupdate.*` — GW5AT JTAG flash writer (reuses `a2fpga_jtag` bit-bang;
  GW5A IDCODE/opcodes to verify at bring-up)

## Out of scope for the first pass

- CardROM/INH bootstrap and the bus-event FIFO (Enhanced debug machinery)
- Paddle/joystick emulation from gamepad (not in Enhanced either)
- Bluetooth HID (future; lands as additional writers of the same pad regs)
- MCU firmware self-update from SD (ESP32 reflashes over its own USB-C;
  OTA-from-SD can come later)
