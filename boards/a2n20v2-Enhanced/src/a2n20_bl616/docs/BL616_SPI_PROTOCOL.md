# BL616 4-Wire SPI Link -- Protocol and Implementation Spec

This document specifies the SPI protocol between the BL616 MCU host and the
FPGA "connector + proto proc" logic, and the behavioral requirements for the
two RTL modules `bl616_spi_proto_proc.sv` and `bl616_spi_connector.sv`.

Adapted from the ESP32 3-wire SPI protocol with key improvements: CS# framing,
128-register address space, and SDRAM/bus-event memory spaces.

## Electrical & Timing

- Bus: 4-wire SPI (SCLK, MOSI, MISO, CS#), Mode 0 (CPOL=0, CPHA=0),
  full-duplex, MSB-first.
- CS# (active low) frames each transaction. Deasserting CS# immediately
  aborts any in-flight transaction and returns the state machine to IDLE.
- MISO update: Slave updates on SCLK falling edges; host samples on rising
  edges.
- No sync bytes or idle timeout required (CS# provides framing).

### Pin Assignment

| Signal | BL616 GPIO | FPGA Pin | Direction   |
|--------|------------|----------|-------------|
| CS#    | GPIO0      | 86       | MCU -> FPGA |
| SCLK   | GPIO1      | 13       | MCU -> FPGA |
| MISO   | GPIO2      | 75       | FPGA -> MCU |
| MOSI   | GPIO3      | 76       | MCU -> FPGA |

## Status Byte (transmitted during header bytes)

- Format: `{ ver[3:0], 1'b0, crcerr, busy, ok }` (MSB->LSB).
  - `ver`: `PROTO_VER[3:0]` (currently 0x1).
  - `crcerr`: reserved (0).
  - `busy`: 1 if connector is busy processing a previous SDRAM access.
  - `ok`: 1 for normal operation; cleared to 0 on protocol errors.
- During header reception (opcode/subheader), slave transmits STATUS bytes.

## Opcodes and Register Access

- 1-byte opcode: `op = { rw, reg[6:0] }`.
  - `rw=1`: register READ. `reg != 127` -> fixed-size 1-byte read.
  - `rw=0`: register WRITE. `reg != 127` -> fixed-size 1-byte write
    (payload follows).
- `reg==127` (0x7F) selects the XFER portal (variable-length transfer).
- Register reads return the byte immediately following the opcode (i.e., the
  next slave byte after the opcode is the register value).

## Register Map (128 registers, 0x00-0x7E)

### Page 0: System (0x00-0x0F)

| Reg  | Name          | R/W | Description                          |
|------|---------------|-----|--------------------------------------|
| 0x00 | DEVICE_ID0    | R   | 'A' (0x41)                           |
| 0x01 | DEVICE_ID1    | R   | '2' (0x32)                           |
| 0x02 | DEVICE_ID2    | R   | 'F' (0x46)                           |
| 0x03 | DEVICE_ID3    | R   | 'P' (0x50)                           |
| 0x04 | PROTO_VER     | R   | Protocol version (0x01)              |
| 0x05 | CAP0          | R   | Capabilities {6'b0, USE_CRC, 1'b1}  |
| 0x06 | STATUS        | R   | System status (see below)            |
| 0x07 | SCRATCH0      | R/W | General purpose scratch register     |
| 0x08 | SYS_TIME0     | R   | System timer [7:0] (54 MHz)          |
| 0x09 | SYS_TIME1     | R   | System timer [15:8]                  |
| 0x0A | SYS_TIME2     | R   | System timer [23:16]                 |
| 0x0B | SYS_TIME3     | R   | System timer [31:24]                 |
| 0x0C | SCRATCH1      | R/W | General purpose scratch register     |
| 0x0D | SCRATCH2      | R/W | General purpose scratch register     |
| 0x0E | SCRATCH3      | R/W | General purpose scratch register     |
| 0x0F | SCRATCH4      | R/W | General purpose scratch register     |

#### STATUS Register (0x06) Bit Fields

| Bit | Name           | Description                                             |
|-----|----------------|---------------------------------------------------------|
| 7   | FPGA_CONFIGURED | Hardwired to 1. An unconfigured FPGA drives all pins to Hi-Z (reads as 0xFF or 0x00 depending on pull), so this bit reliably distinguishes a configured FPGA from an unconfigured one. |
| 6   | SDRAM_READY    | 1 = SDRAM initialization complete. MCU should wait for this before issuing SDRAM accesses via XFER SPACE 1. |
| 5   | A2BUS_RESET_N  | Active-low Apple II bus reset, active-high here. 1 = bus not in reset. |
| 4:2 | Reserved       | Read as 0.                                              |
| 1   | WR_PENDING     | 1 = SDRAM write in progress.                            |
| 0   | RD_PENDING     | 1 = SDRAM read in progress.                             |

**MCU Ready Detection**: After power-on, the MCU should poll STATUS repeatedly. The FPGA is ready when `STATUS[7] == 1` (configured) AND `STATUS[6] == 1` (SDRAM initialized). A typical sequence:
1. Read STATUS — if 0xFF or 0x00, FPGA is not yet configured; wait and retry.
2. If bit 7 is set but bit 6 is clear, FPGA is configured but SDRAM is still initializing; wait and retry.
3. When `STATUS == 0xE0` or higher (bits 7+6+5 set), the system is fully ready.

**FPGA-side `mcu_ready_o`**: The connector outputs `mcu_ready_o` which latches high on the first successful read of the STATUS register (0x06). This lets the FPGA know the MCU is alive and can be used to gate MCU-dependent functionality (e.g., disk volume requests). The signal stays high until reset.

### Page 1: Video Control (0x10-0x1F)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x10 | VIDEO_ENABLE      | R/W | Master video control enable        |
| 0x11 | TEXT_MODE         | R/W | Text mode                          |
| 0x12 | MIXED_MODE        | R/W | Mixed mode                         |
| 0x13 | HIRES_MODE        | R/W | Hi-res mode                        |
| 0x14 | PAGE2             | R/W | Page 2 select                      |
| 0x15 | AN3               | R/W | Annunciator 3                      |
| 0x16 | STORE80           | R/W | 80-column store                    |
| 0x17 | COL80             | R/W | 80-column mode                     |
| 0x18 | ALTCHAR           | R/W | Alternate character set             |
| 0x19 | SHRG_MODE         | R/W | Super hi-res graphics mode         |
| 0x1A | reserved          |     |                                    |
| 0x1B | reserved          |     |                                    |
| 0x1C | reserved          |     |                                    |
| 0x1D | reserved          |     |                                    |
| 0x1E | reserved          |     |                                    |
| 0x1F | reserved          |     |                                    |

### Page 2: Video Colors & Keyboard (0x20-0x2F)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x20 | TEXT_COLOR        | R/W | Text foreground color [3:0]        |
| 0x21 | BG_COLOR          | R/W | Background color [3:0]             |
| 0x22 | BORDER_COLOR      | R/W | Border color [3:0]                 |
| 0x23 | MONO_MODE         | R/W | Monochrome mode                    |
| 0x24 | MONO_DHIRES       | R/W | Monochrome double hi-res mode      |
| 0x25 | KEYCODE           | R/W | Keyboard input byte                |
| 0x26 | HDD0_REQ/CTL      | R/W | R: {wr,rd} pending. W: CTL {readonly,mounted,ready} |
| 0x27 | HDD0_LBA_L/SIZE_L | R/W | R: LBA low (ProDOS block). W: size in blocks, low |
| 0x28 | HDD0_LBA_H/SIZE_H | R/W | R: LBA high. W: size in blocks, high |
| 0x29 | HDD0_ACK          | W   | Ack strobe (block served)          |
| 0x2A | HDD1_REQ/CTL      | R/W | as HDD0                            |
| 0x2B | HDD1_LBA_L/SIZE_L | R/W | as HDD0                            |
| 0x2C | HDD1_LBA_H/SIZE_H | R/W | as HDD0                            |
| 0x2D | HDD1_ACK          | W   | Ack strobe (block served)          |
| 0x2E | A2_RST_RELEASE    | R/W | 1 = release the Apple II from the power-on RESET hold |
| 0x2F | reserved          |     |                                    |

### Page 3: A2 Bus Control (0x30-0x3F)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x30 | A2BUS_READY       | R/W | A2 bus ready signal                |
| 0x31 | CARDROM_RELEASE   | W   | Release card ROM (write 1)         |
| 0x32 | CARDROM_ACTIVE    | R   | Card ROM active status             |
| 0x33 | A2_RESET          | R/W | A2 reset control                   |
| 0x34 | A2_CMD            | R/W | A2 command byte                    |
| 0x35 | A2_DATA0          | R/W | A2 data [7:0]                      |
| 0x36 | A2_DATA1          | R/W | A2 data [15:8]                     |
| 0x37 | A2_DATA2          | R/W | A2 data [23:16]                    |
| 0x38 | A2_DATA3          | R/W | A2 data [31:24]                    |
| 0x39 | A2BUS_INH_N       | R   | Bus inhibit status                 |
| 0x3A | A2BUS_IRQ_N       | R   | Bus IRQ status                     |
| 0x3B | A2BUS_RDY_N       | R   | Bus ready status                   |
| 0x3C | A2BUS_DMA_N       | R   | Bus DMA status                     |
| 0x3D | A2BUS_NMI_N       | R   | Bus NMI status                     |
| 0x3E | A2BUS_RESET_N     | R   | Bus reset status                   |
| 0x3F | COUNTDOWN_TRIG    | W   | Trigger countdown timer            |

### Page 4: Disk Volume 0 (0x40-0x4F)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x40 | VOL0_READY        | R/W | Volume 0 ready                     |
| 0x41 | VOL0_ACTIVE       | R   | Volume 0 active (from drive)       |
| 0x42 | VOL0_MOUNTED      | R/W | Volume 0 mounted                   |
| 0x43 | VOL0_READONLY     | R/W | Volume 0 read-only                 |
| 0x44 | VOL0_SIZE0        | R/W | Volume 0 size [7:0]                |
| 0x45 | VOL0_SIZE1        | R/W | Volume 0 size [15:8]               |
| 0x46 | VOL0_SIZE2        | R/W | Volume 0 size [23:16]              |
| 0x47 | VOL0_SIZE3        | R/W | Volume 0 size [31:24]              |
| 0x48 | VOL0_LBA0         | R   | Volume 0 LBA [7:0]                 |
| 0x49 | VOL0_LBA1         | R   | Volume 0 LBA [15:8]               |
| 0x4A | VOL0_LBA2         | R   | Volume 0 LBA [23:16]              |
| 0x4B | VOL0_LBA3         | R   | Volume 0 LBA [31:24]              |
| 0x4C | VOL0_BLK_CNT      | R   | Volume 0 block count [5:0]         |
| 0x4D | VOL0_RD           | R   | Volume 0 read pending              |
| 0x4E | VOL0_WR           | R   | Volume 0 write pending             |
| 0x4F | VOL0_ACK          | W   | Volume 0 acknowledge (write 1)     |

### Page 5: Disk Volume 1 (0x50-0x5F)

Same layout as Page 4, offset by 0x10.

### Page 6: Slot Config & GPIO (0x60-0x6F)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x60 | SLOT0_CARD        | R/W | Slot 0 card type                   |
| 0x61 | SLOT1_CARD        | R/W | Slot 1 card type                   |
| 0x62 | SLOT2_CARD        | R/W | Slot 2 card type                   |
| 0x63 | SLOT3_CARD        | R/W | Slot 3 card type                   |
| 0x64 | SLOT4_CARD        | R/W | Slot 4 card type                   |
| 0x65 | SLOT5_CARD        | R/W | Slot 5 card type                   |
| 0x66 | SLOT6_CARD        | R/W | Slot 6 card type                   |
| 0x67 | SLOT7_CARD        | R/W | Slot 7 card type                   |
| 0x68 | GPIO_LED          | R/W | LED control [4:0]                  |
| 0x69 | GPIO_WS2812       | R/W | WS2812 RGB LED control             |
| 0x6A | GPIO_BUTTON       | R   | Button state                       |
| 0x6B | SLOT_RECONFIG     | W   | Write any value to trigger reconfig|
| 0x6C | reserved          |     |                                    |
| 0x6D | reserved          |     |                                    |
| 0x6E | reserved          |     |                                    |
| 0x6F | reserved          |     |                                    |

### Page 7: Bus Event FIFO (0x70-0x7E)

| Reg  | Name              | R/W | Description                        |
|------|-------------------|-----|------------------------------------|
| 0x70 | FIFO_STATUS       | R   | {empty, full, 6'b0}               |
| 0x71 | FIFO_COUNT_LO     | R   | FIFO entries [7:0]                 |
| 0x72 | FIFO_COUNT_HI     | R   | FIFO entries [8]                   |
| 0x73 | FIFO_DATA0        | R   | FIFO peek data [7:0]              |
| 0x74 | FIFO_DATA1        | R   | FIFO peek data [15:8]             |
| 0x75 | FIFO_DATA2        | R   | FIFO peek data [23:16]            |
| 0x76 | FIFO_DATA3        | R   | FIFO peek data [31:24]            |
| 0x77 | FIFO_POP          | W   | Write any value to pop entry       |
| 0x78 | CAPTURE_MODE      | R/W | Capture filter mode [2:0]          |
| 0x79 | CAPTURE_ENABLE    | R/W | Capture enable                     |
| 0x7A | U2_CMD_PENDING    | R/W | Uthernet2 doorbell: R=pending sockets [3:0]; W=write-1-to-clear |
| 0x7B | reserved          |     |                                    |
| 0x7C | reserved          |     |                                    |
| 0x7D | reserved          |     |                                    |
| 0x7E | reserved          |     |                                    |

## XFER Portal (reg 0x7F)

### Subheader (little-endian fields)

- `SUB0`: `{ [7]=0, [6]=RES, [5]=CRC_EN, [4]=INC, [3:1]=SPACE, [0]=DIR }`
  - `DIR`: 0=WRITE (host->device), 1=READ (device->host)
  - `SPACE`: 3-bit memory space selector (see below)
  - `INC`: auto-increment address for multi-byte transfers
  - `CRC_EN`: reserved (0)
- `ADDR[23:0]` (low, mid, high)
- `LEN[15:0]` (low, high)

### Memory Spaces

| SPACE | Description                    | Address Range        |
|-------|--------------------------------|----------------------|
| 0     | Local 256B RAM                 | 0x000000-0x0000FF    |
| 1     | SDRAM (byte addressed)         | 0x000000-0xFFFFFF    |
| 2     | Bus event FIFO (bulk read)     | N/A (sequential)     |
| 3     | Uthernet2 (W5100) backing store | 0x0000-0x07FF regs, 0x4000-0x7FFF buffers (W5100 addrs) |
| 4-7   | Reserved                       |                      |

### SPACE 0: Local RAM

256 bytes of local SRAM within the connector. Single-cycle latency for both
reads and writes. Used for small data exchange (e.g., disk block transfers).

### SPACE 1: SDRAM Access

24-bit byte address maps to SDRAM:
- Word address = byte_addr[23:2] (21-bit for GW2AR 8MB SDRAM)
- Byte offset = byte_addr[1:0]

**Write path (byte accumulator)**:
- Incoming bytes are accumulated into a 32-bit word register.
- `byte_en` mask tracks which bytes have been written.
- On 4-byte boundary (or CS# deassert, or address crossing a word boundary
  when INC=1), the accumulated word is flushed to SDRAM via `mem_port_if`.
- Byte enables ensure partial-word writes work correctly.

**Read path (word cache)**:
- On first read (or address word change), a 32-bit word is fetched from SDRAM.
- The requested byte is extracted from the cached word by byte offset.
- Subsequent reads within the same word are served from cache.
- Word boundary crossing triggers a new SDRAM read.

### SPACE 2: Bus Event FIFO (Bulk Read)

Sequential read from the bus event FIFO. Each read returns one byte from the
current 32-bit FIFO entry:
- Bytes 0-3 of each entry are returned in order (little-endian).
- After byte 3, the entry is automatically popped and the next entry begins.
- Address is ignored (sequential only); `INC` should be set.

FIFO entry format (same as a2bus_stream packet):
```
[31:16] Address
[15:8]  Data
[7]     RW_N
[6]     M2SEL_N
[5]     M2B0
[4]     SW_GS
[3:1]   Reserved
[0]     Reset indicator
```

## WRITE Payload

Host sends `LEN` data bytes. If `INC=1`, address increments per byte.
For SPACE 1 (SDRAM), bytes are accumulated and flushed as described above.

## READ Payload

One dummy byte after subheader, then `LEN` data bytes. The first host dummy
clocks the device's first data read; subsequent dummies retrieve data bytes.
Device sends 0xFF until data is ready (for multi-cycle latency spaces).

## CS# Behavior

- CS# assertion (falling edge) enables the SPI engine and begins a new
  transaction.
- CS# deassertion (rising edge) immediately aborts any in-flight transaction,
  flushes any pending SDRAM write accumulator, and returns state to IDLE.
- Multiple transactions can occur within a single CS# assertion (back-to-back
  register reads/writes).

## State Machine Overview

```
IDLE -> OPCODE -> REG_RW or XFER header (X0..XL1)
                  -> PAYLOAD (WRITE or READ)
                  -> DONE -> OPCODE (next transaction)
```

CS# deassert at any point returns to IDLE.

## Bus Event FIFO Capture Modes

| Mode | Filter                    |
|------|---------------------------|
| 000  | Everything                |
| 001  | I/O only ($C000-$CFFF)    |
| 010  | System pages ($00xx-$01xx)|
| 011  | Graphics pages            |
| 100  | ROM access ($D000-$FFFF)  |
| 101  | Writes only               |
| 110  | Reads only                |
| 111  | ES5503 only ($C03C-$C03F) |

## Compliance Notes

- Mode 0 (MSB-first) behavior is required.
- Register reads: value follows immediately after opcode byte.
- XFER READ requires one dummy byte before first data.
- SDRAM access latency is variable; 0xFF padding used until data ready.
- Bus event FIFO entries are 32-bit; bulk read delivers 4 bytes per entry.
