# a2mega ESP32 Co-Processor — Enhanced Feature-Set Port

Port of the a2n20v2-Enhanced BL616 feature set (on-screen menu, disk-image
serving, slot reconfiguration, Apple II reset hold, Uthernet II networking,
FPGA self-update) to the a2mega's ESP32-S3, continuing the `a2mega-usb-host`
branch work (FPGA-fabric `usb_hid_host` core).

## Hardware differences vs a2n20v2-Enhanced

| Function          | Enhanced (BL616)                   | a2mega (ESP32-S3-MINI-1-N8)                     |
|-------------------|------------------------------------|--------------------------------------------------|
| MCU↔FPGA link     | 4-wire SPI Mode 1, ~20 MHz         | Octal SPI (8-bit parallel), sync-pattern framing |
| Gamepad / HID     | BL616 USB host (XInput)            | **FPGA-fabric `usb_hid_host`** on the USB-A port; ESP32 polls readback regs |
| Storage           | USB MSC stick (SD fallback tunnel) | **Micro-SD on ESP32** (native 4-bit SDMMC: CLK=IO36? CMD/D0-D3, DET — see sch p.3) |
| Networking        | USB Ethernet (CDC-ECM/RTL8152)     | **WiFi STA** (raw-frame bridge with MAC NAT)     |
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
| 0 | Test memory | 2KB | BSRAM (existing) |
| 1 | OSD text page — 40×24 Apple II screen codes, linear `y*40+x` | 2KB | BSRAM (existing text_vram0), read by `osd_text_overlay` |
| 2 | Text VRAM bank 1 (unused, reserved) | 2KB | BSRAM (existing) |
| 3 | W5100 address space (0x0000-0x7FFF) | 32KB | Uthernet2 card port B |
| 4 | Disk II track buffers; addr[13]=drive, 8KB window each (track = 0x1A00 bytes used) | 16KB | BSRAM, byte port (ESP32) + 32-bit port (DiskII) |
| 5 | HDD block buffers; addr[9]=unit, 512B each | 1KB | BSRAM, dual port as above |

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

## Firmware (boards/a2mega/src/a2fpga_esp32, Arduino CLI build)

Continues the existing sketch + `a2fpga_ospi_link` transport. New modules
ported from `a2n20_bl616/firmware_host`:

- `fpga_link.*` — register/XFER helpers over `a2spi` (mutex-guarded)
- `fpga_screen.*` — 40×24 screen-code text writer (SPACE 1 linear)
- `menu.*`, `osd_console.*` — ported UI, gamepad polled from FPGA regs
- `settings.*` — same blob layout, stored in NVS (Preferences)
- `disk.*`, `gcr_dsk.*` — image mount/track-serve, FatFS→VFS (`SD_MMC`)
- `w5100_bridge.*` — W5100 poll loop + WiFi raw-frame MAC-NAT bridge.
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
