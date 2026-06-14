# ESP32 Octal SPI Connector Design

This document describes the extended ESP32 Octal SPI connector for the A2Mega board,
providing control interfaces similar to the PicoSoC module.

## Overview

The ESP32 communicates with the FPGA via an 8-bit parallel (Octal) SPI interface.
The connector provides:

1. **Register Access** - 127 registers (0x00-0x7E) for configuration and status
2. **Memory Spaces** - Up to 8 address spaces (SPACE 0-7) for bulk data transfer
3. **Text VRAM** - Block RAM for text mode display

## Protocol

The protocol is identical to the standard SPI version but transfers 8 bits per SCLK cycle:

### Sync Pattern
- Byte 0: 0xA5
- Byte 1: 0x5A

### Register Access (reg 0-126)
- **Write**: `[SYNC] [0:reg] [data]`
- **Read**: `[SYNC] [1:reg] [dummy]` -> returns `[status] [data]`

### Extended Transfer (reg 127)
- `[SYNC] [0x7F] [SUB0] [ADDR0] [ADDR1] [ADDR2] [LEN0] [LEN1] [payload...]`
- SUB0: `[7:6]=reserved [5]=CRC [4]=INC [3:1]=SPACE [0]=DIR(1=read)`

---

## Register Map

### SPACE 0: System Registers (0x00-0x0F)

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| 0x00 | DEVICE_ID0 | R | 'A' (0x41) |
| 0x01 | DEVICE_ID1 | R | '2' (0x32) |
| 0x02 | DEVICE_ID2 | R | 'F' (0x46) |
| 0x03 | DEVICE_ID3 | R | 'P' (0x50) |
| 0x04 | PROTO_VER | R | Protocol version (0x01) |
| 0x05 | CAPABILITIES | R | [0]=SYNC [1]=CRC |
| 0x06 | SCRATCH | R/W | Test register |
| 0x07 | STATUS | R | System status |

### SPACE 1: Video Control (0x10-0x2F)

| Addr | Name | R/W | Bits | Description |
|------|------|-----|------|-------------|
| 0x10 | VIDEO_ENABLE | R/W | [0] | Enable video control override |
| 0x11 | VIDEO_MODE | R/W | [7:0] | Mode flags (see below) |
| 0x12 | TEXT_COLOR | R/W | [3:0] | Text foreground color |
| 0x13 | BG_COLOR | R/W | [3:0] | Background color |
| 0x14 | BORDER_COLOR | R/W | [3:0] | Border color |
| 0x15 | VIDEO_FLAGS | R/W | [7:0] | Additional flags |

**VIDEO_MODE bits:**
- [0] TEXT_MODE
- [1] MIXED_MODE
- [2] PAGE2
- [3] HIRES_MODE
- [4] AN3
- [5] STORE80
- [6] COL80
- [7] ALTCHAR

**VIDEO_FLAGS bits:**
- [0] MONOCHROME_MODE
- [1] MONOCHROME_DHIRES_MODE
- [2] SHRG_MODE

### SPACE 2: Slot Configuration (0x30-0x3F)

| Addr | Name | R/W | Bits | Description |
|------|------|-----|------|-------------|
| 0x30 | SLOT_SELECT | R/W | [2:0] | Slot number (1-7) |
| 0x31 | SLOT_CARD | R/W | [7:0] | Card type to configure |
| 0x32 | SLOT_STATUS | R | [7:0] | Current card in slot |
| 0x33 | SLOT_RECONFIG | W | [0] | Trigger reconfiguration |

### SPACE 3: Drive Volumes (0x40-0x5F)

For each drive (0x40-0x4F = Drive 0, 0x50-0x5F = Drive 1):

| Offset | Name | R/W | Bits | Description |
|--------|------|-----|------|-------------|
| +0x00 | VOL_READY | R/W | [0] | Volume ready |
| +0x01 | VOL_ACTIVE | R | [0] | Drive active |
| +0x02 | VOL_MOUNTED | R/W | [0] | Volume mounted |
| +0x03 | VOL_READONLY | R/W | [0] | Read-only flag |
| +0x04 | VOL_SIZE_L | R/W | [7:0] | Size bits [7:0] |
| +0x05 | VOL_SIZE_M | R/W | [7:0] | Size bits [15:8] |
| +0x06 | VOL_SIZE_H | R/W | [7:0] | Size bits [23:16] |
| +0x07 | VOL_SIZE_X | R/W | [7:0] | Size bits [31:24] |
| +0x08 | VOL_LBA_0 | R | [7:0] | LBA bits [7:0] |
| +0x09 | VOL_LBA_1 | R | [7:0] | LBA bits [15:8] |
| +0x0A | VOL_LBA_2 | R | [7:0] | LBA bits [23:16] |
| +0x0B | VOL_LBA_3 | R | [7:0] | LBA bits [31:24] |
| +0x0C | VOL_BLK_CNT | R | [5:0] | Block count |
| +0x0D | VOL_CMD | R | [1:0] | [0]=RD [1]=WR |
| +0x0E | VOL_ACK | R/W | [0] | Acknowledge |

### SPACE 4: F18A GPU Interface (0x60-0x7E)

| Addr | Name | R/W | Bits | Description |
|------|------|-----|------|-------------|
| 0x60 | GPU_CONTROL | R/W | [7:0] | [0]=trigger [1]=pause |
| 0x61 | GPU_STATUS | R | [7:0] | [0]=running [1]=pause_ack |
| 0x62 | GPU_PC_L | R/W | [7:0] | Load PC low byte |
| 0x63 | GPU_PC_H | R/W | [7:0] | Load PC high byte |
| 0x64 | GPU_VADDR_L | R/W | [7:0] | VRAM address low |
| 0x65 | GPU_VADDR_H | R/W | [5:0] | VRAM address high |
| 0x66 | GPU_VDATA | R/W | [7:0] | VRAM data (auto-inc on read/write) |
| 0x67 | GPU_PADDR | R/W | [5:0] | Palette address |
| 0x68 | GPU_PDATA_L | R/W | [7:0] | Palette data low [7:0] |
| 0x69 | GPU_PDATA_H | R/W | [3:0] | Palette data high [11:8] |
| 0x6A | GPU_RADDR_L | R/W | [7:0] | Register address low |
| 0x6B | GPU_RADDR_H | R/W | [5:0] | Register address high |
| 0x6C | GPU_RDATA | R/W | [7:0] | Register data |
| 0x6D | GPU_SCANLINE | R | [7:0] | Current scanline |
| 0x6E | GPU_BLANK | R | [0] | Blanking active |
| 0x6F | GPU_GSTATUS | R | [6:0] | GPU status output |

---

## Memory Spaces (XFER via reg 127)

| Space | Description | Size | Usage |
|-------|-------------|------|-------|
| 0 | Internal test memory | 256B | Testing/scratch |
| 1 | Text VRAM Bank 0 | 2KB | 40x24 or 80x24 text |
| 2 | Text VRAM Bank 1 | 2KB | Auxiliary text bank |
| 3 | F18A VRAM | 16KB | VDP video memory |
| 4 | F18A Palette | 64x12b | VDP palette |
| 5 | Reserved | - | Future use |
| 6 | Reserved | - | Future use |
| 7 | Reserved | - | Future use |

---

## Text VRAM Memory Map

### Space 1: Text VRAM Bank 0 (2KB)
- 0x000-0x3FF: Primary text page ($0400-$07FF equivalent)
- 0x400-0x7FF: Secondary text page ($0800-$0BFF equivalent)

### Space 2: Text VRAM Bank 1 (2KB)
- 0x000-0x3FF: Auxiliary text page 1
- 0x400-0x7FF: Auxiliary text page 2

---

## Status Byte Format

Returned during reads after sync pattern:

| Bit | Name | Description |
|-----|------|-------------|
| 7:4 | VERSION | Protocol version (0x1) |
| 3 | ALIGN | Sync pattern detected |
| 2 | CRCERR | CRC error (if enabled) |
| 1 | BUSY | Processing previous command |
| 0 | OK | Ready/valid |

---

## Example Transactions

### Read Device ID
```
TX: A5 5A 80 00  (sync + read reg 0 + dummy)
RX: -- -- 11 41  (status + 'A')
```

### Write Video Mode
```
TX: A5 5A 11 07  (sync + write reg 0x11 + data)
```

### Read Text VRAM (256 bytes from address 0)
```
TX: A5 5A 7F 01 00 00 00 00 01 [256 dummy bytes]
                ^space=1, dir=read, inc=1
RX: [9 status bytes] [1 dummy] [256 data bytes]
```

### Write Text VRAM (256 bytes to address 0)
```
TX: A5 5A 7F 11 00 00 00 00 01 [256 data bytes]
                ^space=1, dir=write, inc=1
```

---

## Implementation Notes

1. **Clock Domain Crossing**: SCLK is synchronized to the logic clock via `cdc_denoise`

2. **Bidirectional Data**: The 8 data lines switch direction based on transaction phase:
   - Input during command/address/write-data phases
   - Output during status/read-data phases

3. **Interface Priorities**: Register writes take effect immediately. Memory writes
   are processed as they arrive.

4. **Text VRAM**: Directly mapped to block RAM. The video controller reads from
   this RAM for OSD/text overlay rendering.

5. **F18A Integration**: The GPU interface signals are directly exposed. The ESP32
   can read/write VRAM, palette, and registers, and control GPU execution.

6. **No Chip Select**: The protocol uses sync patterns (0xA5 0x5A) for framing instead
   of a CS line. This frees up the CS pin for other uses. Idle timeout (~100ms) handles
   automatic reframing if communication is lost.

---

## Future Enhancements

### Interrupt Line (FPGA → ESP32)

Since the CS pin is not used for SPI framing, it can be repurposed as an interrupt
output from the FPGA to the ESP32. This would allow the FPGA to signal events without
the ESP32 needing to poll registers.

**Proposed interrupt sources:**
- Drive volume read/write request pending (`volumes[x].rd` or `.wr` asserted)
- VDP vertical blank interrupt
- Apple II bus activity (specific address access)
- Any other condition requiring ESP32 attention

**Implementation:**
- Add `esp_irq_n` output to `esp32_ospi_connector.sv`
- Active-low, directly usable as GPIO interrupt on ESP32
- Add interrupt status/mask registers (e.g., 0x08-0x09) to identify source
- ESP32 configures GPIO for falling-edge interrupt, reads status register to determine cause

**Proposed registers:**
| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| 0x08 | IRQ_STATUS | R | Pending interrupt flags (read clears) |
| 0x09 | IRQ_MASK | R/W | Interrupt enable mask |

**IRQ_STATUS / IRQ_MASK bits:**
- [0] VOL0_CMD - Drive 0 has pending read/write
- [1] VOL1_CMD - Drive 1 has pending read/write
- [2] VDP_VBLANK - VDP vertical blank
- [3] VDP_SPRITE - VDP sprite collision
- [4-7] Reserved
