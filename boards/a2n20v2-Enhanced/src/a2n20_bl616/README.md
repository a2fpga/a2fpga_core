# A2N20 Tang Nano 20K BL616 Firmware

BL616 microcontroller firmware providing application-tier services to the a2fpga Apple II FPGA design on the Sipeed Tang Nano 20K. Replaces the PicoRV32 soft CPU + SD card SPI currently used in the FPGA with a dedicated MCU solution, freeing FPGA logic and providing significantly more RAM and processing power for filesystem access, USB peripherals, and future extensibility.

## Goals

1. BL616 firmware providing application-tier services to the a2fpga FPGA design
2. Primary service: FAT32 filesystem access for Apple II disk images (.dsk, .po, .nib, .woz)
3. Communication with FPGA via SPI (BL616 as master, GPIO0-3 → FPGA pins 86/13/75/76) with polling for status
4. USB provides FT2232-compatible JTAG + UART bridge (same user experience as Sipeed stock firmware)
5. JTAG (GPIO10/12/14/16 → FPGA dedicated JTAG pins 5-8) and SPI are independent — both operate simultaneously
6. Stage 2 firmware at 0x40000, chain-loaded by Sipeed's Stage 1
7. Extensible for future services: USB HID keyboard input, OSD control, additional peripherals

## Architecture

### Data Flow

```
Apple II Bus                      FPGA (GW2AR-18)                    BL616 MCU
──────────                        ───────────────                    ─────────
Disk II slot access  ◄─bus─►  apple_disk.sv
                                  drive_ii.sv
                                      │
                                      ▼
                              mcu_interface.sv  ◄──SPI master───►  main.c
                              (replaces picosoc)   (GPIO0-3)          │
                                                                      ▼
                              FPGA status regs  ◄──SPI polling──  FatFS + SD card
                              (sector requests,                   (FAT32 filesystem)
                               drive status)                          │
                                                                      ▼
                              FPGA JTAG pins    ◄──JTAG─────────  .dsk/.po/.nib/.woz
                              (5,6,7,8)           (GPIO10/12/      disk image files
                                                   14/16)

USB (Debug port)  ◄──FT2232-compatible JTAG + UART bridge────►  CherryUSB device
                    (same behavior as Sipeed stock firmware)
```

### What This Replaces

The current a2fpga design uses a PicoRV32 soft CPU inside the FPGA for SD card access:

| | PicoRV32 (current) | BL616 MCU (new) |
|-|-------------------|-----------------|
| CPU | 32-bit RISC-V soft core in FPGA | 320 MHz T-Head E907 hardware core |
| RAM | 14 KB BRAM (9 blocks) | 480 KB SRAM |
| Storage | SPI to SD card (FPGA GPIO) | SDH controller (hardware) |
| USB | None | USB 2.0 HS (CherryUSB) |
| FPGA cost | ~2000 LUTs + 9 BRAM blocks | 0 (external MCU) |
| Filesystem | Minimal FAT32 in 14 KB | Full FatFS with large buffers |

### Source Layout (as shipped)

Two builds share `firmware/` sources:

```
firmware/            # device-mode build (FT2232 emulation: PC JTAG/UART bridge)
│                    # + sources shared with the host build:
├── fpga_spi.c       #   SPI protocol to the FPGA (regs + XFER)
├── fpga_screen.c    #   40x24 text screen writer
├── gcr_dsk.c        #   .dsk/.do/.po <-> 6-and-2 GCR nibble codec
├── ff.c, sdmm.c     #   FatFS + SD backend
firmware_host/       # USB-host build (the one users run)
├── main.c           # FreeRTOS init, xinput/net/disk threads, overlay
├── disk.c           # disk-image serving, remount, USB supervisor
├── usbh_xinput.c    # gamepad host driver
├── usbh_hidinput.c  # USB keyboard / media-remote menu input (no VID/PID match)
├── w5100.c          # Uthernet II (W5100) MACRAW bridge
├── menu.c           # gamepad menu system (all screens)
├── settings.c       # persisted settings blob (last 4 KB of flash)
├── fwupdate.c       # MCU firmware self-update + warm restart
├── fpga_jtag.c      # bit-banged JTAG / SPI-over-JTAG to the W25Q64
├── fpgaupdate.c     # FPGA core self-update from the stick
└── osd_console.c    # boot/status console on the FPGA text screen
```

### Communication Protocol

SPI register-based protocol between BL616 (master) and FPGA (slave). MCU polls FPGA status registers since no dedicated interrupt line is available.

**SPI Configuration**:
- **BL616 side**: SPI master, GPIO0 (CS#), GPIO1 (SCLK), GPIO2 (MISO), GPIO3 (MOSI)
- **FPGA side**: SPI slave on pins 86 (CS#), 13 (SCLK), 75 (MISO), 76 (MOSI)
- **Clock**: ~20 MHz
- **Mode**: TBD during implementation

**FPGA Register Map** (accessible via SPI, details TBD):

| Register | R/W | Purpose |
|----------|-----|---------|
| STATUS | R | Pending request flags (sector read/write needed, drive status change) |
| COMMAND | R | Current request details (drive, LBA, operation) |
| DATA | R/W | Sector data buffer (256 bytes) |
| RESPONSE | W | MCU writes response status |
| CONFIG | W | Drive mount/unmount, image parameters |

MCU polls STATUS register periodically. When a flag is set, MCU reads COMMAND, services the request (e.g., reads sector from SD card), writes DATA + RESPONSE. Exact register layout depends on FPGA-side `mcu_interface` module design.

**UART** (GPIO11/GPIO13 → FPGA pins 70/69) is available as a secondary channel but primary communication uses SPI for higher throughput.

### FPGA Integration with a2fpga

- **FPGA side**: New `mcu_interface` module replaces PicoRV32+SD card chain
- **SPI slave**: FPGA exposes register interface on pins 86/13/75/76, MCU polls for requests
- **Volume interface**: Existing `drive_volume_if.sv` handshake protocol stays — MCU interface translates between SPI registers and volume registers
- **UART pins** (69/70): Currently used by Super Serial Card emulation in top.sv (lines 409-431). May remain available for SSC or be repurposed.
- **a2fpga_core location**: `/Users/edanuff/GitHub/a2fpga_core/boards/a2n20v2/`

## Tang Nano 20K BL616 Pin Map

### SPI (BL616 → FPGA, primary data channel)

| Signal | BL616 GPIO | FPGA Pin (QN88) | Notes |
|--------|-----------|-----------------|-------|
| CS# | GPIO0 | 86 | Active low |
| SCLK | GPIO1 | 13 | ~20 MHz |
| DIR/MISO | GPIO2 | 75 | FPGA → MCU |
| DAT/MOSI | GPIO3 | 76 | MCU → FPGA |

BL616 operates as SPI master. No dedicated interrupt line available — MCU polls FPGA status registers to detect pending requests (sector reads, drive status changes, etc.).

### JTAG (BL616 → Gowin GW2AR-18 dedicated JTAG pins)

| Signal | BL616 GPIO | GPIO Config Register | FPGA Pin (QN88) |
|--------|-----------|---------------------|-----------------|
| TMS | GPIO16 | 0x20000904 | 5 |
| TCK | GPIO10 | 0x200008EC | 6 |
| TDI | GPIO12 | 0x200008F4 | 7 |
| TDO | GPIO14 | 0x200008FC | 8 |

FPGA pins 5-8 are the GW2AR-18's **dedicated JTAG pins** — independent from the SPI general I/O pins. JTAG and SPI operate simultaneously without conflict.

### UART (BL616 → FPGA)

| Signal | BL616 GPIO | FPGA Pin | Notes |
|--------|-----------|----------|-------|
| TX (BL616→FPGA) | GPIO11 | 70 | UART1 |
| RX (FPGA→BL616) | GPIO13 | 69 | UART1 |

### USB

USB D+/D- are dedicated analog pins on the BL616 QFN40 package (not GPIOs). Hardwired to the Debug USB-C connector.

For USB **host** support (reading gamepads/storage/etc. instead of acting as the
FT2232 device), the architecture, hard-won lessons, and a per-device-class
feasibility roadmap are in **[docs/BL616_USB.md](docs/BL616_USB.md)**. The working
example is the USB-host XInput gamepad build in [`firmware_host/`](firmware_host/).

### GPIO Register Addresses (BL616)

BL616 GLB base: `0x20000000`.

```c
// BL616 GPIO registers (correct addresses — see io_cfg.h)
#define JTAG_GPIO_SET  (*(volatile uint32_t *)0x20000AEC)  // GPIO_CFG138: write 1 = set high
#define JTAG_GPIO_CLR  (*(volatile uint32_t *)0x20000AF4)  // GPIO_CFG140: write 1 = set low
#define JTAG_GPIO_IN   (*(volatile uint32_t *)0x20000AC4)  // GPIO_CFG128: input read

// IMPORTANT: Never use read-modify-write on GPIO_CFG136 (0x20000AE4) for bitbanging.
// RMW causes USB communication failures on BL616. Always use SET/CLEAR registers.

// JTAG pins (→ FPGA dedicated JTAG pins 5-8)
#define TMS_PIN  16  // → FPGA pin 5
#define TCK_PIN  10  // → FPGA pin 6
#define TDI_PIN  12  // → FPGA pin 7
#define TDO_PIN  14  // → FPGA pin 8
```

## Tang Nano 20K Board Variants & BL616 eFuse

All publicly shipped Tang Nano 20K boards are v3921 (the first public release). The only meaningful distinction is whether Sipeed burned eFuse keys during manufacturing:

| Board Type | BL616 eFuse | Notes |
|-----------|-------------|-------|
| v3921 unfused | No | eFuse keys not burned. Sipeed's encrypted `bl616_fpga_partner` won't validate. |
| v3921 fused | Yes | eFuse keys burned. Sipeed's encrypted `bl616_fpga_partner` validates and runs. |

Boards are physically identical — **indistinguishable by appearance**.

**How to tell fused from unfused**: Flash Sipeed's stock `bl616_fpga_partner_20kNano.bin` via boot mode. If the board boots normally showing FT2232 UART ports → fused. If it shows "Bouffalo CDC DEMO" → unfused.

### Two-Stage Boot Architecture (Stock Firmware)

Sipeed's current stock firmware uses a two-stage boot with specific flash addresses:
1. **Stage 1** at flash address `0x0` (`bl616_fpga_partner_20kNano.bin`): Encrypted bootloader providing FT2232D JTAG+UART. On fused boards, validates against eFuse keys. Requires firmware version `2025030317` or later for Stage 2 support.
2. **Stage 2** at flash address `0x40000` (optional): Stage 1 chain-loads a second firmware (e.g., FPGA-Companion, TangCore) if no JTAG programmer host is detected.

### Deployment Strategy

**Primary target: Stage 2 at 0x40000** — Sipeed's Stage 1 stays at 0x0 providing FT2232-compatible USB JTAG+UART bridge. When no JTAG host is connected, Stage 1 chain-loads our firmware. Our firmware provides its own JTAG (GPIO bitbang), SPI master for FPGA communication, and FT2232-compatible USB bridge.

**Fused boards**: Flash our firmware at 0x40000. Sipeed's encrypted Stage 1 at 0x0 validates against eFuse and chain-loads us.

**Unfused boards**: Flash unencrypted `friend_20k` (MiSTeryNano) at 0x0 as Stage 1, our firmware at 0x40000. Same two-stage behavior without eFuse dependency.

See `docs/bl616_ecosystem.md` for detailed field update procedures and board variant handling.

### Warm restart: no chip reset works on fused boards — jump to the app entry instead

No CHIP reset source revives the BL616 on the fused boards Sipeed ships:
the SDK's `GLB_SW_POR_Reset`, a direct `GLB_SWRST_CFG2` toggle, and a
`WDG_MODE_RESET` watchdog all leave the chip dark until a power cycle —
even with the UPDATE button held (which would force ROM download mode if
any reset actually fired). The encrypted Sipeed Stage-1 / fused boot
configuration evidently masks chip reset sources; FPGA-Companion's
identical watchdog recipe works only on unfused boards.

The working alternative (menu RESTART MCU and the tail of a firmware
self-update install) restarts the FIRMWARE without any chip reset —
`fwupdate_restart_app()` in `firmware_host/fwupdate.c`:

1. `usbh_deinitialize()`, then drop OTG VBUS (`USB_A_BUS_DROP_HOV`) and
   hold it low ≥1 s. This gives the bus-powered hub and devices a REAL
   power cycle. (The driver's own init only drops VBUS ~10 ms — a
   brownout that can zombie a hub's port controller: EP0 answers, all
   ports report unpowered, SET PORT_POWER is ignored.)
2. Reset the USB peripheral (`GLB_AHB_MCU_Software_Reset(
   GLB_AHB_MCU_SW_EXT_USB)`) and power the PHY off (`PDS_Turn_Off_USB()`)
   — `bflb_usb_phy_init` only ORs its power bits in, so it is a no-op
   unless the PHY starts from OFF.
3. From TCM with interrupts off: clean+invalidate D-cache, invalidate
   I-cache (stale lines of the OLD image!), jump to the app entry at
   0xA0000000. Stage-1's XIP mapping (including fused-board decrypt)
   remains programmed, so the app in flash boots as if chain-loaded.

Even then, CherryUSB's hub driver only enumerates devices that produce a
connect CHANGE event on the hub's interrupt endpoint — devices already
settled on powered ports are structurally invisible to it. The disk
thread runs a supervisor (`disk.c`): if the root port is connected but
zero non-hub devices exist for 8 s, it directly "adopts" occupied hub
ports (port reset + build child hubport + `usbh_enumerate`, mirroring the
driver's connect tail), then falls back to a VBUS cycle and a full stack
recycle. Any DMA buffer for such control transfers MUST be
`USB_NOCACHE_RAM_SECTION` (a cached buffer reads back stale zeros).

### FPGA self-flash over bit-banged JTAG (firmware_host/fpga_jtag.c)

The host firmware programs the FPGA's external W25Q64 config flash itself
— the JTAG pins are plain BL616 GPIOs (TMS=16, TCK=10, TDI=12, TDO=14),
usable while USB host runs. Sequence (mirrors openFPGALoader's GW2A path;
UG290E §7.2.4): erase the fabric SRAM (ConfigEnable 0x15 → ERASE_SRAM
0x05 → XFER_DONE 0x09 → ConfigDisable 0x3A, with status polls via IR
0x41), then each SPI transaction is IR 0x16 + one Shift-DR burst
(TCK=SCLK, TMS=CS, TDI=MOSI, TDO=MISO). Hard-won details:

- **GW2A(R)-18's IDCODE is `0x0000081B`** (part-number field is zero on
  this early Gowin part — not a readback bug).
- Every Gowin instruction needs **6 Run-Test/Idle clocks after Update-IR**
  (openFPGALoader's `send_command`); without them commands don't execute.
- The ConfigEnable+0x3D "flash access" prep is for NON-GW2A parts only —
  sending it on a GW2A blocks 0x16 mode (MISO reads all-FF).
- Shift **exactly 8·n clocks** per SPI transaction, TMS up on the last
  data bit; a stray extra clock breaks page programming. MISO is delayed
  one clock — reads shift one extra dummy byte and rebuild from samples
  8i+1..8i+8.
- SPI register **0x7F is the XFER opcode**, not a usable register — the
  core build stamp readback lives at reg 0x3F (write index, read digit).
- The Gowin `.bin` is the raw flash image, written verbatim at offset 0.

### Recovery Is Always Possible

Regardless of board variant, entering boot mode (UPDATE button) lets you reflash. No board variant is permanently brickable — the ROM bootloader is in mask ROM and cannot be overwritten.

### Known Hardware Issues

1. **MSPI/JTAG conflict**: FPGA flash shares JTAG pins. JTAG must work to program flash. If bitstream reconfigures JTAG pins as GPIO, board appears bricked.
2. **JTAGSEL_N recovery**: Pull FPGA JTAGSEL_N low before power-up to force JTAG active, overriding bitstream pin config.
3. **S2 button JTAG recovery**: If openFPGALoader reports "no device found" after flashing firmware, disconnect the board, hold S2, reconnect while holding, release, then retry. (Reported in FPGA-Companion issue #79.)

## Build Environment Setup (macOS)

> **Full step-by-step (Homebrew prerequisites + building the T-Head toolchain
> from source) lives in [docs/macos_build_setup.md](docs/macos_build_setup.md).**
> That doc is the single source of truth for the host setup; this section only
> covers the pieces specific to *this* firmware (the SDK version pin + the build
> commands). New machine? Start with that doc, then come back here.

### Toolchain (T-Head RISC-V GCC) — summary

The BL616's T-Head E907 needs vendor GCC extensions (`xtheade`, `zpsfoperand`)
that upstream/Homebrew RISC-V GCC lacks, and there are no prebuilt macOS
binaries — so it's a one-time **build from source** into
`/opt/riscv-toolchain/xuantie`, kept **first on `PATH`**. Full steps:
[docs/macos_build_setup.md](docs/macos_build_setup.md#t-head-risc-v-toolchain).
Verify: `/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc -dumpversion`
→ `10.4.0`.

### SDK Setup

> **Pin the SDK to a known-good tag.** This firmware is written against the
> CherryUSB version bundled in a specific bouffalo_sdk release. A bare
> `git clone` lands on `master`, whose CherryUSB API may differ and **will not
> build** without porting. Always check out the tested tag:
>
> **Required: `v2.3.27` (CherryUSB v1.5.3).**

```bash
git clone --branch v2.3.27 --depth 1 https://github.com/bouffalolab/bouffalo_sdk.git
# (or, on an existing clone:)
#   cd bouffalo_sdk && git fetch --tags && git checkout v2.3.27

# The build needs these two env vars every time. BL_SDK_BASE MUST be set
# explicitly — the Makefiles' default relative path does not resolve here.
export BL_SDK_BASE=/path/to/bouffalo_sdk
export PATH=/opt/riscv-toolchain/xuantie/bin:$PATH   # T-Head GCC must be first
```

To confirm an existing checkout is on the right version:

```bash
git -C "$BL_SDK_BASE" describe --tags                       # -> v2.3.27
grep CHERRYUSB_VERSION_STR "$BL_SDK_BASE"/components/usb/cherryusb/common/usb_version.h
# -> #define CHERRYUSB_VERSION_STR "v1.5.3"
```

Bumping to a newer SDK is a deliberate port (the CherryUSB host/device APIs
change across releases — e.g. the v0.10→v1.x rewrite threaded a `busid` arg
through the whole device API and replaced the `usbh_pipe_t` model). No macOS
patches to the SDK are needed at v2.3.27 — upstream handles Darwin directly.

### Why T-Head Toolchain

BL616 uses T-Head E907 core with arch flags not in upstream GCC:
- **MARCH**: `rv32imafcpzpsfoperand_xtheade`
- **MABI**: `ilp32f`
- **MCPU**: `e907`

## Build / Flash / Test Commands

### Build

There are **two** firmware builds in this tree, built the same way:

- `firmware/` — the default **FT2232 device** firmware (USB JTAG+UART bridge + CLI).
- `firmware_host/` — the **USB-host** firmware (XInput gamepad + USB-Ethernet).

```bash
# device firmware:
cd firmware
PATH=/opt/riscv-toolchain/xuantie/bin:$PATH BL_SDK_BASE=/path/to/bouffalo_sdk \
    make CHIP=bl616 BOARD=bl616dk
# -> build/build_out/a2n20_bl616_bl616.bin

# host firmware:
cd ../firmware_host
PATH=/opt/riscv-toolchain/xuantie/bin:$PATH BL_SDK_BASE=/path/to/bouffalo_sdk \
    make CHIP=bl616 BOARD=bl616dk
# -> build/build_out/a2n20_bl616_host_bl616.bin
```

Notes:
- **Always** pass `BL_SDK_BASE` explicitly and put the **T-Head** toolchain first
  on `PATH` (see [SDK Setup](#sdk-setup)).
- After a toolchain or SDK change, `rm -rf build` first — the cmake cache pins
  the old paths otherwise.
- A clean build ends with `Built target combine` and produces the `.bin` above.

### Enter Boot Mode

1. Press and hold the **UPDATE** button (top of board, behind HDMI connector)
2. Connect USB-C to the **Debug** port (or power-cycle while holding)
3. Release button — BL616 enumerates as CDC-ACM device
4. macOS: appears as `/dev/tty.usbmodemXXXX`

### Flash (Recommended — `a2n20-mcu-program` wrapper)

`tools/a2n20-mcu-program` wraps `bflb-iot-tool`, auto-detects the board state
(fused/unfused/bricked/boot mode) and picks the right flash strategy and
address. It flashes either firmware build:

- `firmware/build/build_out/a2n20_bl616_bl616.bin` — default **FT2232 device**
  firmware (JTAG+UART bridge, CLI).
- `firmware_host/build/build_out/a2n20_bl616_host_bl616.bin` — **USB-host**
  firmware (standalone XInput joystick mode). See
  [`firmware_host/`](firmware_host/).

```bash
# Interactive (guides you through boot mode), auto-detect strategy:
./tools/a2n20-mcu-program

# Flash the host build explicitly:
./tools/a2n20-mcu-program --stage2 \
    --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin
```

On a **fused** board (enumerates as "USB Debugger"), the signed Sipeed Stage 1
at `0x0` is kept and firmware is written as Stage 2 at `0x40000`; Stage 1
chain-loads it when no PC is attached.

> **First-time setup on a new board: flash BOTH stages.** Boards arrive with a
> factory Stage 1 that may **not** chain-load 0x40000 — fused boards can carry
> an old Sipeed image predating chain-load support. Flash only `--stage2` on
> such a board and the write verifies perfectly but the app never runs: the
> status LED goes **blue at power-on, then off** (the FPGA gives up waiting for
> the MCU and falls back to standalone mode). The recommended first-time
> command flashes a known-good Stage 1 too:
>
> ```bash
> ./tools/a2n20-mcu-program --stage1 --stage2 \
>     --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
>     --port /dev/cu.usbmodemXXXX --non-interactive
> ```
>
> Bare `--stage1` (no path) is safe on any board: it probes the eFuse state
> over the BootROM and auto-selects the correct image (signed Sipeed partner
> image for fused boards — which also upgrades old non-chaining Stage 1s —
> `friend_20k` for unfused). Note that bare `--stage2` defaults to the FT2232
> **device** build; always pass `--firmware` explicitly when you want the host
> build.

**Non-interactive / scripted / agent use.** Put the board in boot mode first
(hold UPDATE while connecting USB-C to the Debug port — it appears as
`/dev/cu.usbmodemXXXX`), then drive the flash without prompts:

```bash
./tools/a2n20-mcu-program --stage2 \
    --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
    --port /dev/cu.usbmodemXXXX --non-interactive
```

- `--non-interactive` (aka `--yes`/`-y`): never blocks on prompts, assumes the
  board is already in boot mode, and implies `--skip-verify` (verify needs a
  physical power-cycle). Exits **non-zero** if flashing fails — earlier versions
  printed "Programming complete!" even on a failed write.
- The flash **baud rate auto-falls-back** (default 500000 → 115200) on write
  failure; 2000000 is unreliable on some cables and is no longer the default.
- `--verify-flash` reads each written region back from the chip and
  byte-compares it to the image — confirms a correct flash **without** a
  power-cycle (useful since a running host-mode firmware is invisible from the
  PC). A real mismatch exits non-zero. Combine with a flash:
  ```bash
  ./tools/a2n20-mcu-program --stage2 \
      --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
      --port /dev/cu.usbmodemXXXX --non-interactive --verify-flash
  ```
  Or **verify-only** (no rewrite) — `--verify-flash` with no `--stage1`/`--stage2`,
  board in boot mode. Defaults to 0x40000; override with `--addr`:
  ```bash
  ./tools/a2n20-mcu-program --verify-flash \
      --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
      --port /dev/cu.usbmodemXXXX --non-interactive
  ```
- `--detect` reports board state (from USB descriptors) and exits without
  flashing.
- `--probe-cli` identifies the **running** firmware over serial: it opens the
  device's serial port(s), sends the `Ctrl-X Ctrl-C Enter` break-in + `help`,
  and reports who answers. Ours shows the `a2n20>` prompt and the A2N20 banner;
  the stock firmware shows `TangNano20K />` with `pll`/`chip_id`/`reboot`/etc.
  The JTAG/MPSSE channel is detected and skipped. No serial ports at all is
  itself a signal — the board is in boot mode or running the USB-host firmware
  (a USB host exposes no serial device).

Coding agents: the **`flash-mcu`** skill (`.claude/skills/flash-mcu/`) drives
this for you.

### ⚠️ Do NOT use `make flash` / raw `BLFlashCommand` / `bflb-iot-tool --addr 0x0`

> **These brick fused boards.** The SDK `make flash` target, raw
> `BLFlashCommand`, and `bflb-iot-tool ... --addr 0x0` default to writing the
> firmware at flash **0x0**. On a **fused** board that **erases the signed
> Sipeed Stage 1 and bricks it** — the ROM only boots a *signed* image at 0x0,
> and our firmware is unsigned (it belongs at Stage 2 **0x40000**). This has
> actually bricked a board.
>
> Guards in place so it can't happen by accident:
> - `make flash` is **overridden in the `Makefile`** to print an error and exit
>   non-zero.
> - `flash_prog_cfg.ini` is **pinned to `0x40000`** (was `0x0`) as a backstop.
> - A repo `PreToolUse` hook blocks these commands for coding agents.
>
> **Always flash via `tools/a2n20-mcu-program`** (the Recommended section above,
> or the `/flash-mcu` skill). It auto-detects fused/unfused/bricked and writes
> to the correct address. To **recover a bricked board**, run the tool's auto
> mode (it restores the signed Stage 1 from [`recovery/`](recovery/) at 0x0 and
> the firmware at 0x40000), or force it:
> ```bash
> ./tools/a2n20-mcu-program \
>     --stage1 recovery/bl616_fpga_partner_20kNano.bin \
>     --stage2 firmware_host/build/build_out/a2n20_bl616_host_bl616.bin
> ```

> **Baud rate:** use **500000**. `2000000` is unreliable on some USB-C cables
> (intermittent `BFLB FLASH WRITE FAIL`); the `a2n20-mcu-program` wrapper
> defaults to 500000 and auto-falls-back to 115200. Drop to 115200 if 500000
> still fails on your cable.

### Flash Config Files

- `flash_prog_cfg.ini` — pinned to Stage 2 **0x40000** (was 0x0; `make flash`
  that used it is disabled — see the warning above).
- `flash_stage2_cfg.ini` — Stage 2 at 0x40000.

### Restore Stock Firmware

**Fused boards** (stock encrypted firmware):
1. Download `bl616_fpga_partner_20kNano.bin` from Sipeed:
   - Direct: https://api.dl.sipeed.com/TANG/Debugger/onboard/BL616/2025030317/bl616_fpga_partner_20kNano.bin
   - Directory: https://api.dl.sipeed.com/shareURL/TANG/Debugger/onboard/BL616/2025030317
2. Enter boot mode (UPDATE button)
3. Flash using BouffaloLabDevCube v1.9.0: chip BL616/618, select the .bin, flash at address `0x0`
4. Power cycle — should enumerate as FT2232 with serial `2025030317` showing "USB Converter A" + "USB Converter B"
5. If only a single COM port appears instead of dual converters → board is unfused, use the unfused procedure below

**Unfused boards** (unencrypted recovery firmware):
1. Download `friend_20k` unencrypted firmware from MiSTle-Dev:
   - Direct: https://github.com/MiSTle-Dev/FPGA-Companion/raw/refs/heads/main/src/bl616/friend_20k/friend_20k_bl616.bin
   - Directory: https://github.com/MiSTle-Dev/FPGA-Companion/tree/main/src/bl616/friend_20k
2. Enter boot mode (UPDATE button)
3. Flash the unencrypted variant
4. Power cycle — should enumerate as FT2232

### Verify JTAG

```bash
# After flashing, reconnect USB normally (no UPDATE button)
openFPGALoader --detect
# Should show: GW2AR-18 (idcode 0x0000081b)
```

## Field Troubleshooting

Lessons from real user bring-ups (first external field debug: 2026-07-11).
Work top-to-bottom: LED first, then the DebugOverlay, then telnet.

### Status LED decoder (WS2812, driven by the FPGA)

The LED is an FPGA-side MCU liveness watchdog
(`boards/a2n20v2-Enhanced/hdl/bl616/mcu_status_led.sv`) — it works even when
the MCU is dead, and no firmware support is required.

| LED | Meaning |
|-----|---------|
| blue steady | power-on, MCU hasn't made an SPI transaction yet |
| cyan | firmware booting |
| yellow | USB searching (no usable device yet) |
| green | USB device connected, reports flowing — normal operation |
| magenta / white | firmware self-update copy/verify / verified |
| red steady | MCU-declared fatal (see fwupdate markers) |
| red blinking (~0.8 Hz) | MCU went silent > 10 s after having run (wedged update / crash) |
| off (after blue) | **standalone fallback engaged — the MCU never spoke** |

Field signatures observed in practice:

- **Blue → off, board otherwise works but no USB/disk/network:** the app at
  0x40000 never runs. Almost always a factory Stage 1 without chain-load
  support — reflash with `--stage1 --stage2` (see the first-time setup note in
  the Flash section). The DebugOverlay still works in this state (it's
  FPGA-rendered; its version datestamp is the *gateware* build, not proof the
  MCU is alive).
- **Green → yellow:** a USB device enumerated, then dropped off the bus. See
  the USB notes below.

### USB device invisible? Check the USB-C adapter FIRST

**Not all USB-A→C adapters pass data.** Many are charge-only, and some wire
the CC resistor for one plug orientation only. Signature: the device is
*electrically absent* — overlay shows `USB HOST: WAITING FOR DEVICE...`
forever, **no** `ENUM STALLED` supervisor messages (those require a physical
connect), stage byte stuck at `A0`. Confirmed in the field: two visually
identical adapters, one works, one doesn't. Try flipping the adapter 180°
(single-orientation CC wiring) and then a different adapter before suspecting
anything else. The same applies to detachable device cables (charge-only
cables are everywhere).

### USB hubs and plug order

- **Hub with other live devices on it (ethernet, storage): connect the
  controller BEFORE power-on.** Hot-plug behind an already-working hub is not
  detected (CherryUSB hub driver limitation), and re-plugging just the device
  won't recover it — re-plug the whole hub or power-cycle.
- **Empty or fully-stalled hub: hot-plug recovers by itself within ~30 s** —
  the enumeration supervisor escalates ADOPT → VBUS power-cycle → stack
  recycle (up to 5 attempts, visible on the overlay as
  `USB: ENUM STALLED - ...`).
- **Direct attach: hot-plug just works.**
- A **self-powered hub** helps when the Apple II slot 5 V is marginal, but is
  not required for a working setup.

### Remote support: telnet console (port 23)

With a USB-ethernet adapter attached, `telnet <board-ip>` gives field support
without photographs of CRTs: `c` streams the console log live (with backlog),
`m` mirrors the on-screen menu as ANSI and maps the keyboard to gamepad
buttons (arrows = D-pad, Enter = A, `s`/Tab = SELECT), `q` disconnects.

### `--verify-flash` says "read-back file not found"

Fixed 2026-07-11: `bflb-iot-tool --read` writes its dump into its own Python
package directory, and locating that dir used to fail for venv installs whose
CLI entry point has a `#!/bin/sh` wrapper shebang (pip/distlib does this on
some setups), silently skipping the byte-compare. The tool now derives
site-packages from the CLI executable path directly and, if the file still
can't be found, prints every location it checked.

### Known issue: 8BitDo SN30 Pro (Bluetooth model) over USB

The BT-capable model connects as XInput and then drops a few seconds later
(LED green → yellow) on current firmware — reproduced on two units, two
boards. The wired-only model is unaffected. Under investigation (suspected
regression from the SDK v2.3.27 / CherryUSB v1.5.3 migration; the BT model
needs the timing-sensitive extended init sequence). Wrong-mode pads are a
*different* failure: a pad not in X-input mode never goes green at all.

## BL616 Technical Reference

### Register Base Addresses

| Register Block | BL702 | BL616 |
|---------------|-------|-------|
| GLB base | 0x40000000 | 0x20000000 |
| GPIO output SET | 0x40000188 | 0x20000AEC |
| GPIO output CLR | — | 0x20000AF4 |
| GPIO input | 0x40000180 | 0x20000AC4 |
| DMA base | 0x4000C000 | 0x2000C000 |
| USB clock bit (CGEN1) | Bit 28 | Bit 13 |

### RISC-V Core

| | BL702 | BL616 |
|-|-------|-------|
| Core | T-Head E906 | T-Head E907 |
| Arch | rv32imafc | rv32imafcpzpsfoperand_xtheade |
| GPIO count | 38 (0-37) | 35 (0-34) |
| DMA channels | 8 | 4 |

### CherryUSB API (BL616 / bouffalo_sdk)

```c
usbd_desc_register(busid, &descriptor);
usbd_add_interface(busid, &intf);
usbd_add_endpoint(busid, &ep);
usbd_initialize(busid, reg_base, event_handler);
// Event-driven: use USBD_EVENT_CONFIGURED callback
```

### GPIO API (BL616 LHAL)

```c
struct bflb_device_s *gpio = bflb_device_get_by_name("gpio");
bflb_gpio_init(gpio, pin, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0);
bflb_gpio_set(gpio, pin);
bflb_gpio_reset(gpio, pin);
bool val = bflb_gpio_read(gpio, pin);
```

### UART API (BL616 LHAL)

```c
struct bflb_device_s *uart1 = bflb_device_get_by_name("uart1");
struct bflb_uart_config_s cfg = { .baudrate = 2000000, ... };
bflb_uart_init(uart1, &cfg);
bflb_uart_txint_mask(uart1, false);
```

### Build System

Standard bouffalo_sdk Makefile pattern:
```makefile
SDK_DEMO_PATH ?= $(abspath .)
BL_SDK_BASE ?= $(abspath ../../bouffalo_sdk)
export BL_SDK_BASE
CROSS_COMPILE ?= riscv64-unknown-elf-
include $(BL_SDK_BASE)/project.build
```

## Implementation Phases

### Phase 1: Build Environment + Minimal Firmware
- Set up bouffalo_sdk project skeleton with Makefile/CMakeLists.txt
- Create minimal FreeRTOS application that boots on BL616
- Blink LED and/or print to UART1 to confirm firmware runs
- Test both flash configurations: Stage 2 (0x40000) and standalone (0x0)
- Test on fused and unfused boards to determine eFuse impact
- **Success criteria**: LED blinks, UART output visible, boots correctly as Stage 2

### Phase 2: FatFS Integration
- Initialize SD card via Bouffalo SDH interface
- Mount FAT32 filesystem using FatFS
- List directory contents, read files
- Verify .dsk/.po file access and read performance
- **Success criteria**: Can read and list disk image files from SD card

### Phase 3: FPGA Communication Protocol
- Define command/response message format (adapted from TangCore protocol)
- Implement UART1 TX/RX with ring buffers and interrupt-driven receive
- Create FreeRTOS tasks: main task + UART RX task
- Implement FPGA-side `mcu_interface` module (in a2fpga_core project)
- Replace PicoRV32 + SD card with MCU interface in FPGA top-level
- **Success criteria**: MCU and FPGA exchange commands/responses over UART

### Phase 4: Disk Image Service
- Implement sector read/write handlers for disk images
- Support .dsk (140 KB, 35 tracks x 16 sectors x 256 bytes) and .po (ProDOS order) formats
- Wire to existing `drive_volume_if` handshake in FPGA disk controller
- Test with Apple II DOS 3.3 and ProDOS boot disks
- **Success criteria**: Apple II boots from disk image served by BL616 over UART

### Phase 5: Field Deployment
- Test on fused and unfused Tang Nano 20K boards
- Document field update procedure for A2N20 users
- Create recovery instructions for all board variants
- Package firmware binary and flashing tools
- **Success criteria**: A2N20 users can update BL616 firmware and boot disk images

## USB-Ethernet (RTL8152) host networking

The USB-host build (`firmware_host/`) can host a **USB-Ethernet adapter** so the
card joins the LAN: the BL616 runs the USB host, brings up the adapter, runs
lwIP + DHCP, and shows the leased IP on the HDMI overlay. Hardware-verified
(gets a DHCP lease, pings both ways, hot-pluggable with the gamepad).

**Adapter:** Realtek **RTL8152** (USB `0x0bda/0x8152`). Use the stock CherryUSB
`usbh_rtl8152` vendor driver — **no SDK patches needed**. (The **RTL8153**
`0x8153` is *not* supported by that driver's `rtl_ops_init` for its chip version,
so use an RTL8152-based adapter.)

**What enables it (all in `firmware_host/`, CherryUSB unmodified):**
- `proj.conf`: `set(CONFIG_CHERRYUSB_HOST_RTL8152 1)` + `CONFIG_LWIP 1`.
- `usb_config.h`: `CONFIG_USBHOST_RTL8152_ETH_MAX_RX_SIZE = 16*1024`. The chip
  reports `rx_buf_sz = 16K`; a smaller value makes `usbh_rtl8152_connect()`
  return `-USB_ERR_NOMEM` and the adapter never comes up.
- `CMakeLists.txt`: **`-DPBUF_POOL_SIZE=16 -DPBUF_POOL_BUFSIZE=1600`**.
  ⚠️ **Critical gotcha:** the SDK's `lwipopts.h` defaults `PBUF_POOL_SIZE` to **0**
  unless `CFG_ETHERNET_ENABLE` is defined — with a zero pool, `pbuf_alloc()`
  fails for *every* received frame and RX is silently dropped (no DHCP, no IP),
  even though the chip, USB stack, and driver are all working. This one line is
  what makes RX work.
- `main.c`: `usbh_get_hport_active_config_index()` returns 0 (RTL8152 uses its
  default vendor config); lwIP netif glue (`usbh_rtl8152_eth_input` → lwIP, TX via
  the driver's tx buffer); spawns the driver's `usbh_rtl8152_rx_thread` + a status
  reporter. On unplug, `usbh_rtl8152_stop` calls `netif_remove` (via
  `tcpip_callback`) so a re-plug can re-add the netif (hot-plug).

**Test:** flash the host build (`/flash-mcu`), then with **no PC on the BL616
USB port**, plug the RTL8152 adapter (Ethernet cabled to your LAN) into the host
port. The overlay shows `link: up` then `IP: x.x.x.x`; ping that IP from another
host.

## Key Design Decisions

1. **SPI as primary FPGA channel**: SPI (GPIO0-3 → FPGA pins 86/13/75/76) provides ~20 MHz throughput for register-based communication. JTAG (GPIO10/12/14/16 → FPGA dedicated pins 5-8) is fully independent — both operate simultaneously. No interrupt line available, so MCU polls FPGA status registers via SPI.

2. **FT2232-compatible USB bridge**: Our firmware provides the same USB JTAG + UART bridge behavior as Sipeed's stock firmware, so the user experience is unchanged. Additionally, we implement FPGA services (disk image access, etc.) that Sipeed's firmware doesn't provide.

3. **Stage 2 only**: All boards deploy as Stage 2 at 0x40000. Fused boards use Sipeed's encrypted Stage 1; unfused boards use `friend_20k` unencrypted Stage 1. No standalone 0x0 image needed.

4. **Don't fork TangCore/FPGA-Companion**: Use them as reference implementations but build purpose-specific firmware for a2fpga. Their protocols are designed for retro gaming cores (OSD-heavy, core switching). Our needs are more focused (disk image service + extensibility).

5. **FreeRTOS**: Follow TangCore's lead — FreeRTOS provides task scheduling, mutexes, and integrates with bouffalo_sdk and CherryUSB.

## Key References

### Repositories
- **TangCore/firmware-bl616** (reference implementation): https://github.com/nand2mario/firmware-bl616
- **TangCore** (FPGA cores): https://github.com/nand2mario/tangcore
- **FPGA-Companion** (SPI protocol reference): https://github.com/MiSTle-Dev/FPGA-Companion
- **RV-Debugger-BL702** (JTAG reference): https://github.com/sipeed/RV-Debugger-BL702
- **Bouffalo SDK**: https://github.com/bouffalolab/bouffalo_sdk
- **CherryUSB**: https://github.com/cherry-embedded/CherryUSB
- **T-Head RISC-V Toolchain**: https://github.com/XUANTIE-RV/xuantie-gnu-toolchain
- **macOS Toolchain Build Guide**: https://github.com/p4ddy1/pine_ox64/blob/main/build_toolchain_macos.md
- **a2fpga_core** (FPGA design): https://github.com/a2fpga/a2fpga_core

### Ecosystem Analysis
- **nand2mario blog**: https://nand2mario.github.io/posts/2025/mcu_for_better_fpga_gaming/
- **FPGA-Companion SPI protocol**: https://github.com/MiSTle-Dev/FPGA-Companion/blob/main/SPI.md
- **FPGA-Companion TN20K versions wiki**: https://github.com/MiSTle-Dev/.github/wiki/Versions_TangNano20k
- **Ecosystem reference doc**: [`docs/bl616_ecosystem.md`](docs/bl616_ecosystem.md)
- **USB host support, lessons & device roadmap**: [`docs/BL616_USB.md`](docs/BL616_USB.md)
- **nand2mario/firmware-bl616** (USB gamepad host reference): https://github.com/nand2mario/firmware-bl616
- **FPGA-Companion BL616 source** (USB host reference): https://github.com/MiSTle-Dev/FPGA-Companion/tree/main/src/bl616

### Board Variant & eFuse Research
- **FPGA-Companion issue #79** (board variant bricking, recovery procedures): https://github.com/MiSTle-Dev/FPGA-Companion/issues/79
- **Sipeed stock BL616 firmware (2025030317)**: https://api.dl.sipeed.com/shareURL/TANG/Debugger/onboard/BL616/2025030317
- **friend_20k unencrypted recovery firmware**: https://github.com/MiSTle-Dev/FPGA-Companion/tree/main/src/bl616/friend_20k
- **BouffaloLabDevCube v1.9.0**: https://dev.bouffalolab.com/download/

### Datasheets & Docs
- **BL616/BL618 Datasheet**: https://github.com/bouffalolab/bl_docs/tree/main/BL616_DS/en
- **BL616 Reference Manual**: https://github.com/bouffalolab/bl_docs/tree/main/BL616_RM/en
- **GW2AR Pinout (UG229)**: https://cdn.gowinsemi.com.cn/UG229E.pdf
- **Tang Nano 20K Wiki**: https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html
- **Update Debugger (boot mode)**: https://wiki.sipeed.com/hardware/en/tang/common-doc/update_debugger.html
- **openFPGALoader Gowin Notes**: https://trabucayre.github.io/openFPGALoader/vendors/gowin.html

## Code Style

- **Standard**: C99
- **Naming**: `snake_case` for functions and variables, `UPPER_CASE` for macros and constants
- **Prefixes**: `disk_` for disk service functions, `mcu_` for protocol/communication functions, `sd_` for SD card functions
- **Includes**: System headers first, then SDK headers, then project headers
- **Buffers**: Static allocation, no malloc. Ring buffers sized to powers of 2 for efficient masking.
- **Error handling**: Check return values at USB/UART boundaries. No exceptions. Silent on expected fast-path conditions.
- **Comments**: Explain hardware quirks and register magic. No boilerplate comments.
