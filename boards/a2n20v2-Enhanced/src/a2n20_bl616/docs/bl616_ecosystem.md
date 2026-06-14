# BL616 Firmware Ecosystem for Tang Nano 20K

Reference document covering the existing BL616 firmware projects, Sipeed's two-stage boot architecture, board variant handling, and field deployment considerations relevant to the a2n20 project.

## Sipeed Two-Stage Boot Architecture

### Flash Layout

Sipeed's current stock firmware (version 2025030317+) implements a two-stage boot:

```
Flash Address   Content                          Purpose
──────────────  ───────────────────────────────  ────────────────────────────
0x00000         bl616_fpga_partner_20kNano.bin   Stage 1: JTAG/UART bridge
                (encrypted, Sipeed-signed)        + Stage 2 chain-loader

0x40000         Custom firmware (optional)        Stage 2: Application firmware
                (unsigned, open-source)           (TangCore, FPGA-Companion, etc.)
```

### Boot Sequence

1. BL616 powers on, ROM bootloader runs from mask ROM
2. ROM bootloader checks eFuse for secure boot keys (fused boards only)
3. Loads and executes Stage 1 at flash address `0x0`
4. Stage 1 checks for JTAG host connection (openFPGALoader, OpenOCD, Gowin Programmer)
   - **Host detected**: Stays in FT2232D JTAG/UART bridge mode (VID 0x0403, PID 0x6010)
   - **No host detected**: Chain-loads Stage 2 firmware at flash address `0x40000`
5. Stage 2 firmware takes over, initializing its own USB stack, peripherals, etc.

### Key Details

- Stage 1 firmware version must be `2025030317` or later for Stage 2 chain-loading support
- Host detection appears to check for USB enumeration/configuration within a timeout window
- Stage 2 firmware is unsigned — any valid BL616 binary at `0x40000` will be loaded
- Stage 1 preserves JTAG programming capability — users can always reprogram the FPGA via openFPGALoader when connected to a host PC

### Flash Configuration for Two-Stage

```ini
[cfg]
erase = 1
skip_mode = 0x0, 0x0
boot2_isp_mode = 0

[official]
filedir = bl616_fpga_partner_20kNano.bin
address = 0x0

[custom]
filedir = ./build/build_out/firmware_bl616.bin
address = 0x40000
```

## TangCore / firmware-bl616 (nand2mario)

**Repository**: https://github.com/nand2mario/firmware-bl616
**Related**: https://github.com/nand2mario/tangcore
**Blog post**: https://nand2mario.github.io/posts/2025/mcu_for_better_fpga_gaming/

### What It Provides

TangCore is Stage 2 firmware for BL616 on various Sipeed Tang boards (Console 60K/138K, Mega 60K/138K, Primer 25K, Tang Nano 20K). It provides:

1. **JTAG FPGA Programming**: Full Gowin JTAG TAP state machine with GPIO bit-bang at ~5 Mbps. Optimized bitstream upload (~2 seconds for GW5A-60 vs 13 seconds baseline) via direct GPIO register access.

2. **FAT32 Storage**: FatFS filesystem on SD card (via Bouffalo SDH) or USB mass storage (via CherryUSB MSC). Automatic fallback: tries SD first, then USB.

3. **USB Host**: CherryUSB host stack for gamepad/HID controller input. Supports USB OTG for USB drive access via OTG dongle.

4. **FPGA Communication**: UART1-based bidirectional protocol at 2 Mbps. Sends ROM data, joypad state, overlay text. Receives core ID, configuration, floppy sector requests.

5. **On-Screen Display (OSD)**: Menu system rendered by MCU, sent to FPGA for overlay on video output. Core selection, ROM browsing, options.

6. **Game Core Support**: NES, SNES, Game Boy, Genesis, Master System, PC/XT (DOS). Core-specific ROM loaders with progress display. Floppy sector I/O for DOS cores.

### Architecture

- **Build stack**: bouffalo_sdk + FreeRTOS v10.2.1 + CherryUSB v1.0.0 + FatFS R13
- **Language**: C++17
- **Tasks**: Main task (menu/UI, 2048 byte stack) + UART1 RX task (message parser, 512 byte stack)
- **Shared state**: Mutex-protected globals for joypad state, core ID
- **Board variants**: Compile-time `TANG_BOARD=nano20k` selection

### UART Protocol (MCU to FPGA)

```
Byte 0:     0xAA (sync byte)
Byte 1-2:   Length (16-bit big-endian, includes command byte)
Byte 3:     Command code
Bytes 4+:   Payload
```

**MCU → FPGA Commands**:

| Code | Name | Payload | Purpose |
|------|------|---------|---------|
| 0x01 | GET_CORE_ID | none | Query active core ID |
| 0x03 | SET_CONFIG | 4 bytes | Core configuration |
| 0x04 | CURSOR | col, row | Position OSD cursor |
| 0x05 | PRINT | ASCII string | Print to OSD |
| 0x06 | LOAD_STATE | 0/1 | Start/stop ROM loading |
| 0x07 | ROM_DATA | ROM bytes | Send ROM content (8 KB chunks) |
| 0x08 | OSD_TOGGLE | on/off | Show/hide overlay |
| 0x09 | HID_STATE | 4 bytes | Joypad state (joy1_H/L, joy2_H/L) |
| 0x0A | FLOPPY_READ_RESP | drive, sector, data[512] | Floppy read response |

**FPGA → MCU Responses** (same header format):

| Code | Name | Payload | Purpose |
|------|------|---------|---------|
| 0x01 | CORE_ID | 1 byte | Response to GET_CORE_ID |
| 0x03 | JOYPAD_STATE | 4 bytes | Periodic joypad update from FPGA-side controllers |
| 0x04 | FLOPPY_WRITE | drive, sector, data[512] | Floppy write request |
| 0x05 | FLOPPY_READ | drive, sector | Floppy read request |

### JTAG Performance Optimization

Direct GPIO register writes bypass LHAL for the JTAG hot path:

```c
volatile uint32_t *reg_gpio0_31 = (volatile uint32_t *)0x20000ae4;  // GPIO_CFG136

// Enter GPIO output mode: configure TMS/TCK/TDI for direct register control
*reg_gpio_tms = GPIO_INT_MASK | GPIO_FUNC_SWGPIO | GPIO_OUTPUT_EN | ...;
*reg_gpio_tck = GPIO_INT_MASK | GPIO_FUNC_SWGPIO | GPIO_OUTPUT_EN | ...;
*reg_gpio_tdi = GPIO_INT_MASK | GPIO_FUNC_SWGPIO | GPIO_OUTPUT_EN | ...;
```

Critical sections (`taskENTER_CRITICAL`) disable context switching during JTAG and UART bulk transfers.

### Relevance to a2n20

TangCore demonstrates the viable architecture for our project: Stage 2 firmware using FreeRTOS + CherryUSB + FatFS, communicating with the FPGA via UART at 2 Mbps. The UART protocol format (0xAA sync, length, command, payload) is a proven design we can adapt. The key difference is that TangCore serves retro gaming cores (ROM loading, joypad forwarding), while we need disk image sector service for Apple II emulation.


## FPGA-Companion (MiSTle-Dev)

**Repository**: https://github.com/MiSTle-Dev/FPGA-Companion
**SPI Protocol**: https://github.com/MiSTle-Dev/FPGA-Companion/blob/main/SPI.md
**TN20K Versions**: https://github.com/MiSTle-Dev/.github/wiki/Versions_TangNano20k

### What It Provides

FPGA-Companion is MCU-agnostic companion firmware for retro computing FPGA projects. It provides peripheral bridging services after the FPGA is already programmed:

1. **USB HID**: Keyboard matrix, mouse movement, joystick/gamepad input
2. **SD Card**: Sector read/write for disk image emulation, image insertion notifications
3. **On-Screen Display**: 128x64 monochrome tile-based OSD menu system
4. **System Control**: Status queries, LED control, button states, interrupt management
5. **Audio Output**: Reserved in protocol, not yet implemented

### Multi-MCU Architecture

FPGA-Companion abstracts the MCU layer with three implementations sharing an identical SPI protocol:

| MCU | Advantages | Limitations |
|-----|-----------|-------------|
| **BL616** | USB 2.0 HS, WiFi 6, BLE 5.2, integrated in Tang boards | Complex SDK |
| **RP2040** | Well-supported SDK, cheap, full-speed USB | No wireless |
| **ESP32-S2/S3** | WiFi, Bluetooth | Limited USB host (no hub) |

### SPI Protocol

Communication uses SPI at 20 MHz (MODE1) where the MCU is always master:

- **Signals**: CSN, SCK, MOSI, MISO, IRQN (interrupt, active low)
- **Target-based routing**: First byte selects subsystem (SYS=0, HID=1, OSD=2, SDC=3, AUDIO=4)
- **Interrupt-driven**: FPGA asserts IRQN when it needs service (sector requests, HID events)

**Pin Mapping (BL616 on Tang Nano 20K)**:

| Signal | BL616 GPIO | FPGA Pin |
|--------|-----------|----------|
| CSN | GPIO0 | 86 |
| SCK | GPIO1 | 13 |
| MISO | GPIO2 | 75 |
| MOSI | GPIO3 | 76 |
| IRQN | GPIO13 | 69 |

Note: SPI pins (GPIO0-3) connect to the same FPGA pins as JTAG (GPIO10/12/14/16) via separate board traces. SPI is usable only when JTAG is not active.

### Supported FPGA Projects

MiSTeryNano (Atari ST), NanoMig (Amiga), NanoMac (Mac Plus), C64Nano, VIC20Nano, A2600Nano, NanoApple2, C16Nano — all share the same FPGA-Companion firmware via the standardized SPI protocol.

### Key Difference from TangCore

- **TangCore**: Application-specific, includes JTAG programmer, tightly coupled to Tang Console/Mega boards, UART-based FPGA communication
- **FPGA-Companion**: Generic peripheral bridge, no JTAG, MCU-agnostic, SPI-based FPGA communication, runs only after FPGA is programmed

### Relevance to a2n20

FPGA-Companion demonstrates the SPI approach (~20 MHz, ~10x faster than UART) and provides a reference for SD card sector service. However, its SPI protocol requires FPGA-side SPI slave IP and shares pins with JTAG — meaning the SPI interface cannot be used simultaneously with JTAG programming. For our project, UART is the safer starting point since it uses dedicated pins (GPIO11/GPIO13) independent of JTAG.


## Tang Nano 20K Board Variants

### Three Board Classes

| Board Type | PCB Marking | BL616 eFuse | SPI Support | Notes |
|-----------|-------------|-------------|-------------|-------|
| Pre-3921 | Various | No | Blocked by C51 capacitor | Requires C51 desoldering for SPI |
| v3921 unfused | v3921 | No | Yes | Indistinguishable from fused by appearance |
| v3921 fused | v3921 | Yes | Yes | eFuse keys burned, accepts encrypted firmware |

### Detection Method

Flash Sipeed's stock `bl616_fpga_partner_20kNano.bin` via boot mode (UPDATE button):
- **FT2232 dual UART ports appear** (USB Converter A + B) → **Fused board**
- **"Bouffalo CDC DEMO" appears** (single COM port) → **Unfused board**

Sipeed's troubleshooting confirms: "abnormal efuse content on the BL616" indicates an unfused board.

### Impact on Deployment Strategy

**Stage 2 approach (flash at 0x40000)**:
- **Fused boards**: Stage 1 (`bl616_fpga_partner`) validates against eFuse, boots normally, chain-loads our Stage 2. Works.
- **Unfused boards**: Stage 1 fails eFuse validation, shows "Bouffalo CDC DEMO" instead of FT2232. Stage 2 is never reached. Does NOT work with Sipeed's encrypted Stage 1.
- **Unfused workaround**: Use unencrypted Stage 1 from `friend_20k` (MiSTeryNano). This provides JTAG/UART bridge without eFuse validation and can chain-load Stage 2.

**Standalone approach (flash at 0x0)**:
- **Fused boards**: Open question — eFuse secure boot may reject unsigned firmware at address 0x0. Needs testing.
- **Unfused boards**: Works — ROM bootloader loads any valid firmware from flash.
- **Trade-off**: Loses Sipeed JTAG unless we implement our own.

**Recommended approach**: Target Stage 2 (0x40000) as primary. Provide instructions for unfused boards to use unencrypted Stage 1. Also produce standalone (0x0) image as fallback.

### Recovery Procedures

**All board variants**: Enter boot mode (hold UPDATE button while connecting USB) to access ROM bootloader in ISP mode. ROM bootloader is in mask ROM, cannot be overwritten, accepts any firmware for flashing. No board is permanently brickable.

**Fused board recovery**:
1. Enter boot mode (UPDATE button)
2. Flash `bl616_fpga_partner_20kNano.bin` at address `0x0`
3. Source: https://api.dl.sipeed.com/TANG/Debugger/onboard/BL616/2025030317/bl616_fpga_partner_20kNano.bin
4. Power cycle — should show "USB Converter A" + "USB Converter B"

**Unfused board recovery**:
1. Enter boot mode (UPDATE button)
2. Flash `friend_20k_bl616.bin` at address `0x0`
3. Source: https://github.com/MiSTle-Dev/FPGA-Companion/raw/refs/heads/main/src/bl616/friend_20k/friend_20k_bl616.bin
4. Power cycle — should enumerate as FT2232

### Known Hardware Issues

1. **C51 capacitor (pre-3921 only)**: Blocks SPI signal integrity. Must desolder for SPI. Not an issue on v3921 boards.
2. **GPIO2 signal integrity**: Some revisions have issues with GPIO2 for fast SPI MISO. Workaround uses GPIO10.
3. **MSPI/JTAG conflict**: If FPGA bitstream reconfigures JTAG pins as GPIO, board appears bricked. Recovery: pull JTAGSEL_N low before power-up.
4. **S2 button recovery**: If openFPGALoader reports "no device found", disconnect, hold S2, reconnect while holding, release, retry.

### References

- FPGA-Companion issue #79 (board variant details): https://github.com/MiSTle-Dev/FPGA-Companion/issues/79
- FPGA-Companion TN20K versions wiki: https://github.com/MiSTle-Dev/.github/wiki/Versions_TangNano20k
- Sipeed stock firmware: https://api.dl.sipeed.com/shareURL/TANG/Debugger/onboard/BL616/2025030317
- Unencrypted recovery firmware: https://github.com/MiSTle-Dev/FPGA-Companion/tree/main/src/bl616/friend_20k
- BouffaloLabDevCube: https://dev.bouffalolab.com/download/


## Field Update Procedures

### For End Users with Fused Boards (Stage 2 Deployment)

Prerequisites: BouffaloLabDevCube v1.9.0 or BLFlashCommand CLI tool.

1. Verify Stage 1 firmware version is 2025030317 or later:
   - If unsure, download and flash `bl616_fpga_partner_20kNano.bin` at address `0x0` first
2. Enter boot mode: hold UPDATE button, connect USB to Debug port, release
3. Flash a2n20 firmware at address `0x40000`
4. Power cycle
5. Verify: connect to Debug USB normally (no UPDATE button) — should enumerate with a2n20 USB device when no JTAG host is active
6. JTAG still works: openFPGALoader/OpenOCD will use Stage 1 when connected

### For End Users with Unfused Boards

1. Enter boot mode (UPDATE button)
2. Flash `friend_20k` unencrypted Stage 1 at address `0x0`
3. Flash a2n20 firmware at address `0x40000`
4. Power cycle
5. Verify as above

### Rollback / Recovery

1. Enter boot mode (UPDATE button) — always works regardless of firmware state
2. Flash original stock firmware:
   - Fused boards: `bl616_fpga_partner_20kNano.bin` at `0x0`
   - Unfused boards: `friend_20k` firmware at `0x0`
3. Erase Stage 2: flash empty/zeros at `0x40000` (or just reflash Stage 1 which overwrites the chain-loader trigger)
4. Power cycle
