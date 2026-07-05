# A2N20v2-Enhanced — A2FPGA for Tang Nano 20K + BL616 (Beta)

This is the **Enhanced** build of the A2FPGA Apple II card for the
[Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html).
It pairs the Tang Nano 20K's Gowin GW2AR-18 FPGA (8 MB SDRAM) with the
on-board **BL616 MCU** acting as a coprocessor: the MCU is a USB host (game
controller, mass storage, Ethernet), serves Apple II disk images from a USB
stick or SD card, drives an on-screen menu system, and bridges networking —
no PC required once the board is flashed.

The A2N20v2 card supports Apple II, //e, and IIgs models (the "a2bridge"
CPLD captures all bus signals including M2SEL/M2B0 for the IIgs).

> **Status: beta.** This document is the end-to-end guide for beta testers:
> what you need, how to flash both the FPGA and the MCU, how to prepare a
> USB stick, and what to expect when it boots.

## What the card provides

Virtual peripheral cards (default slot assignments; changeable in the menu):

| Slot | Card | Notes |
|------|------|-------|
| 2 | Super Serial Card | |
| 3 | Uthernet II (WIZnet W5100) | Ethernet, bridged through a USB-Ethernet adapter on the MCU — works with IP65, ADTPro, Contiki |
| 4 | Mockingboard | |
| 5 | Disk II controller | Two floppy drives served from disk images |
| 6 | ProDOS hard disk | Two block-device units served from disk images; bootable |
| 7 | SuperSprite (TMS9918A/F18A) | |

Plus: HDMI video output for all Apple II/e/gs graphics modes, Ensoniq DOC
5503 sound (IIgs audio, 32 oscillators), Apple II speaker over HDMI, and a
gamepad-driven on-screen menu for configuration.

### Disk image support

Floppy drives (Disk II, slot 5) serve these image formats, read **and**
write:

| Format | Contents | Notes |
|--------|----------|-------|
| `.dsk` / `.do` | 143,360-byte sector image | Sector order is auto-detected from content (DOS 3.3 vs ProDOS-order images both work) |
| `.po` | 143,360-byte sector image | ProDOS sector order |
| `.2mg` | 2IMG container | Floppy-size payloads serve as floppies |
| `.nib` | 232,960-byte nibble image | Served as-is |

Hard disk units (slot 6) serve ProDOS block volumes, read and write:

| Format | Notes |
|--------|-------|
| `.hdv` | Raw ProDOS blocks, up to 32 MB (65,535 blocks) |
| `.po`  | Any size — raw blocks |
| `.2mg` | ProDOS-order payloads |

Tracks/blocks are served on demand by the MCU — images stay on the USB
stick / SD card and are not size-limited by FPGA memory.

## What you need

- A2N20v2 card with Tang Nano 20K (Enhanced build targets the **fused**
  BL616 boards Sipeed currently ships)
- **USB-C cable** to the Tang Nano 20K's **Debug** port (the USB-C port on
  the BL616 side) for flashing
- A small **[USB-C to USB-A hub](https://www.amazon.com/dp/B07PY87TBD)** (the BL616 has one USB host port; you'll want at
  least a gamepad + storage on it)
- **XInput game controller** — 8BitDo SN30 Pro or similar (the menu's only
  input device; no Apple II keyboard needed)
- **USB flash drive**, FAT32-formatted (MBR partition scheme) — or a FAT32
  SD card in the Tang Nano 20K's SD slot
- Optional: **[USB 2.0 10/100 Mbps Ethernet adapter](https://www.amazon.com/dp/B00ET4KHJ2)** (Realtek RTL8152) for the Uthernet II bridge
- A Mac or PC with:
  - [openFPGALoader](https://github.com/trabucayre/openFPGALoader) — on a
    Mac: `brew install openfpgaloader`
  - Python 3 with `pip install bflb-iot-tool` (for MCU flashing)

## Updating your board

There are **two things to flash**, and they are flashed differently:

1. the **FPGA bitstream** (`.fs` file — the Apple II hardware itself)
2. the **BL616 MCU firmware** (`.bin` file — USB host, disks, menu)

Flash the FPGA first, then the MCU. Both are done over the same Debug
USB-C port.

### 1. Flash the FPGA bitstream

Connect the Debug port to your computer and power the board normally (no
buttons). The BL616's stock bootloader detects the attached computer and
exposes a JTAG programmer (the host firmware stays dormant while a computer
is attached, so this works even with our MCU firmware installed).

```
openFPGALoader -b tangnano20k -f boards/a2n20v2-Enhanced/impl/pnr/a2n20v2_enhanced.fs
```

or, from the repository root:

```
tools/flash.sh a2n20v2-Enhanced
```

This writes the bitstream to the FPGA's SPI flash (`-f`), so it persists
across power cycles. The MCU firmware is untouched.

### 2. Flash the BL616 MCU firmware

> ⚠️ **Never use `make flash`, `BLFlashCommand`, or any tool that writes to
> flash address `0x0`.** Sipeed's boards chain-boot from an encrypted
> first-stage bootloader at `0x0`; overwriting it disables the board's USB
> JTAG/serial functions until the stock firmware is restored. Our firmware
> lives at `0x40000` (Stage 2) and is flashed **only** with the
> `a2n20-mcu-program` tool below, which enforces the correct address.

**Step 1 — put the board in ROM boot mode** (required; the running firmware
cannot reflash itself):

1. **Disconnect** the USB cable from the board
2. **Press and hold** the **UPDATE** button (recessed, behind the HDMI
   connector)
3. **Plug in** the USB-C cable (Debug port) *while still holding* UPDATE
4. **Release** UPDATE

The board enumerates as a Bouffalo serial device — on a Mac it appears as
`/dev/cu.usbmodemXXXX` (if you instead see two `usbserial-…` ports, the
board booted normally; redo the button sequence).

**Step 2 — flash** (from `boards/a2n20v2-Enhanced/src/a2n20_bl616/`):

```
./tools/a2n20-mcu-program --stage2 \
    --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
    --port /dev/cu.usbmodemXXXX --non-interactive --verify-flash
```

Wait for both `[OK] Stage 2 flashed successfully` and
`[OK] verified … bytes at 0x40000 match the image`. The `--verify-flash`
read-back is your proof it worked — the host firmware is invisible over USB
once running, so there's no other way to confirm from the PC side.

**Step 3 — run it:** disconnect the board from the computer entirely and
power it **in the Apple II with no PC attached**. The MCU firmware only
starts when no computer is enumerating the BL616 (that's what lets step 1
of the FPGA flash work).

### Updating the MCU from the USB stick (no PC)

Once your board runs a firmware with the on-screen menu, later MCU updates
don't need a PC at all:

1. Copy the new `a2n20_bl616_host_bl616.bin` anywhere on the USB stick
2. Menu → **FIRMWARE UPDATE** → **CHOOSE FIRMWARE FILE (.BIN)** and pick it
3. The update is staged and verified in the background (disks keep
   working); when it shows READY, choose **INSTALL NOW**
4. The screen freezes for about a minute while the update is written —
   **do not power off during this**
5. The board **restarts itself** when the install finishes and the new
   firmware boots (verify the build stamp on the FIRMWARE UPDATE screen).
   If it hasn't come back after two minutes, power-cycle the system.

The staging step is fully verified before anything is overwritten, so a
bad file or interrupted copy cannot hurt the installed firmware. Only the
short install window is critical; if power is lost there, recover with the
PC flashing procedure above (the UPDATE-button boot mode always works).

### Updating the FPGA core from the USB stick (no PC)

The FPGA core (gateware) can also be updated from the stick — the BL616
writes the bitstream into the FPGA's configuration flash over JTAG:

1. Copy the build's `impl/pnr/a2n20v2_enhanced.bin` anywhere on the stick
   (the raw `.bin`, not `.fs` or `.binx`)
2. Menu → **FPGA UPDATE** → **CHOOSE CORE FILE (.BIN)** and pick it
3. The file is verified first (Gowin bitstream for this exact FPGA; an MCU
   firmware `.bin` is rejected), then choose **INSTALL NOW**
4. The screen goes **completely dark for one to two minutes** while the
   core is written — this is normal; **do not power off**
5. The board restarts itself into the new core; the main menu shows the
   new core build stamp next to the MCU one

Unlike the MCU update there is no staged copy: the running core must be
stopped before its flash is reachable. If the write is interrupted, the
FPGA comes up unconfigured (dark screen) but the MCU stays fully alive —
recover by re-flashing the FPGA from a PC (`tools/flash.sh
a2n20v2-Enhanced` with the board attached to the computer).

### Recovery

Nothing here can permanently brick the board: the UPDATE-button boot mode
is in mask ROM. If the MCU firmware misbehaves, redo boot mode and reflash
(our firmware, or Sipeed's stock `bl616_fpga_partner` at its documented
address — see the [BL616 firmware README](src/a2n20_bl616/README.md)).

## Preparing the USB stick

Format: **FAT32, MBR partition scheme** (on a Mac: Disk Utility → Erase →
"MS-DOS (FAT)" + "Master Boot Record"). Then copy disk images to the root.

At startup the firmware mounts, per drive, the **first name that exists**:

| Drive | Names tried, in order |
|-------|------------------------|
| Floppy 1 | `disk1.dsk`, `disk1.do`, `disk1.po`, `disk1.2mg`, `disk1.nib` |
| Floppy 2 | `disk2.dsk`, `disk2.do`, `disk2.po`, `disk2.2mg`, `disk2.nib` |
| Hard disk 1 | `hdd1.hdv`, `hdd1.po`, `hdd1.2mg` |
| Hard disk 2 | `hdd2.hdv`, `hdd2.po`, `hdd2.2mg` |

Images with **any other name — including in subdirectories** — can be
selected from the on-screen menu (DISK IMAGES → pick a drive → browse
folders and choose); the choice is saved and survives power cycles. A USB stick takes priority over the SD card by
default (configurable in STORAGE).

A good starter set: a DOS 3.3 disk as `disk1.dsk`, a blank 143,360-byte
file as `disk2.dsk`, and a bootable ProDOS volume (e.g. Total Replay) as
`hdd1.hdv`.

## First boot — what to expect

1. **The Apple II stays quiet for a few seconds.** The FPGA holds the
   Apple II in RESET while the MCU brings up USB and mounts images, so the
   autoboot scan doesn't run before storage is ready. The HDMI output shows
   the MCU's boot console (USB devices found, images mounted, then
   `A2: RESET RELEASED`).
2. **The Apple II boots.** The slot scan finds the hard disk in slot 6
   first — if `hdd1.hdv` is mounted, it boots that. Otherwise the HDD ROM
   falls through to the Disk II in slot 5 and the floppy boots.
   - Hold **open-apple** (paddle button 0) during boot to skip the hard
     disk and boot the floppy instead.
   - No images at all: reset releases after ~7 s and the machine boots to
     BASIC as usual.
3. If the MCU firmware isn't running at all, the FPGA releases the Apple II
   after ~3 s and the card works as a plain video/sound card (no disks, no
   menu).

## The on-screen menu

Press **SELECT** on the gamepad at any time:

| Button | Action |
|--------|--------|
| SELECT | Toggle between the Apple II display and the MCU display |
| Y | In the MCU display: switch between the MENU and the CONSOLE log |
| D-pad up/down | Move selection (hold to repeat) |
| D-pad left/right | Change the highlighted value |
| LB / RB | Change numeric values by ±16 (IP address octets) |
| A | Activate: enter submenu / run action / cycle value |
| B | Back; at the main menu, back to the Apple II |

(Buttons are labeled per SNES-style pads like the 8BitDo SN30.)

Menu screens:

- **SLOT ASSIGNMENTS** — view the live slot map and reassign cards per
  slot. Saved changes apply at every boot (before the Apple II starts);
  "APPLY NOW" reconfigures immediately (then reboot the Apple II).
  A card can occupy only one slot — assigning it elsewhere empties the old
  slot automatically. "RESTORE HW DEFAULTS" returns to the table above.
- **DISK IMAGES** — per-drive mount status; select any image on the
  storage volume for any drive, or eject a drive. Changes remount
  immediately and persist.
- **STORAGE** — storage source: AUTO (USB if present, else SD), USB only,
  SD only; rescan/remount.
- **NETWORK** — DHCP on/off; with DHCP off, edit a static IP, netmask and
  gateway with the pad. Live link status, IP, and MAC.
- **USB DEVICES** — the USB device tree (hubs, VID:PID, driver, speed).
- **RESET SETTINGS TO DEFAULTS** — clears all saved preferences.

All settings persist in the BL616's flash (not on the stick). The main
menu's diagnostic line (`FLASH 4M @3FF000 LD:OK SV:OK`) shows the
settings-store state: `LD:` is the load result at boot (`OK`, or `MAG` on a
first boot with no saved settings), `SV:` the last save (`-` = none yet
this session).

## DIP switches

The A2N20v2 card's 4-position DIP switch:

1. Scanline effect on/off
2. Apple II speaker audio over HDMI on/off
3. Power-on-Reset hold (delay Apple II start-up until the FPGA is running)
4. Apple IIgs mode — set ON when installed in a IIgs

For ROM 00/01 IIgs models the card must be in **slot 3** (M2B0 is only
present there); ROM 03 models work in any slot.

## Troubleshooting

- **Board won't enter boot mode** (no `usbmodem` port): the UPDATE button
  must already be held *when power arrives*. Unplug fully, hold, plug,
  release.
- **`DISK II: WAITING FOR USB STORAGE (PREF)`** on the console: storage
  preference is USB-only and no stick is present — insert one or change
  STORAGE to AUTO.
- **A drive shows `(EJECTED)`**: you ejected it from the menu; pick an
  image or "(AUTO)" in DISK IMAGES to restore it.
- **A drive shows `(NO IMAGE FOUND)`**: none of the default names exist on
  the volume — add one or pick a file via the menu.
- **ProDOS/DOS disk boots in an emulator but not on the card**: make sure
  you're on the current firmware (early betas had a sector-interleave bug
  affecting externally-created `.dsk` images). Also note `.dsk` files
  *written by* pre-fix firmware (e.g. COPYA output) need to be recreated.
- **Settings don't survive power cycles**: check the `SV:` code on the
  main menu after changing something — anything other than `OK` is a flash
  write problem; report the code.
- **Uthernet II apps see no network**: check NETWORK for link/IP (the
  USB-Ethernet adapter bridges the Apple II; the Apple II gets its own IP
  via the W5100 emulation — see [docs/UTHERNET2.md](docs/UTHERNET2.md)).

## Building from source

- **FPGA bitstream**: open `a2n20v2_enhanced.gprj` in the Gowin IDE
  (educational or commercial), or build headless with the Gowin CLI — see
  the [project wiki](../../docs/README.md). (When using the Gowin IDE, do
  not add/remove files from the project or it will rewrite relative paths
  as absolute.)
- **BL616 firmware**: T-Head RISC-V toolchain + Bouffalo SDK — full
  instructions in the [BL616 firmware README](src/a2n20_bl616/README.md).
  The end-user build is `firmware_host` (USB host + disks + menu); the
  `firmware` build is the developer JTAG/UART bridge.

## Documentation

- [Project documentation wiki](../../docs/README.md) — Gowin CLI setup,
  architecture, conventions, gotchas
- [BL616 firmware, protocol & flashing internals](src/a2n20_bl616/README.md)
- [Uthernet II emulation](docs/UTHERNET2.md) ·
  [protocol](docs/UTHERNET2_PROTOCOL.md)
- [Disk image serving design](docs/disk_image_serving_design.md)
- [Board tasks & status](TODO.md)
- [Agent & contributor guide](../../AGENTS.md)
