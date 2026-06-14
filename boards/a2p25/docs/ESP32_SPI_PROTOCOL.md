# ESP32 3‑Wire SPI Link – Protocol and Implementation Spec

This document specifies the SPI protocol between the ESP32 host and the FPGA “connector + proto proc” logic, and the behavioral requirements for the two RTL modules `esp32_spi_connector.sv` and `esp32_spi_proto_proc.sv`.

## Electrical & Timing
- Bus: 3‑wire SPI (no CS), Mode 0 (CPOL=0, CPHA=0), full‑duplex.
- MISO update: Slave updates on SCLK falling edges; host samples on rising edges. MSB‑first.
- Reframing: In absence of SCLK transitions for `IDLE_TO_CYC` core clocks, the slave returns to IDLE and a new command may begin at the next byte boundary.

## Byte Framing and Sync
- Optional sync: If `USE_SYNC=1`, a new transaction begins with two bytes 0xA5, 0x5A.
  - `status.align` is set for one byte after detecting `0xA5 0x5A`.
- Without sync: A new transaction may begin immediately with an opcode byte.

## Status Byte (transmitted during header bytes)
- Format: `{ ver[3:0], align, crcerr, busy, ok }` (MSB→LSB).
  - `ver`: `PROTO_VER[3:0]` (currently 0x1).
  - `align`: 1 for one byte after valid sync; else 0.
  - `crcerr`: 1 if CRC mismatch in header/payload when CRC is enabled; else 0.
  - `busy`: reserved (0 for now).
  - `ok`: 1 for normal operation; cleared to 0 on protocol errors.
- During header reception (sync/opcode/subheader), slave transmits STATUS bytes.

## Opcodes and Register Access
- 1‑byte opcode: `op = { rw, reg[6:0] }`.
  - `rw=1`: register READ. `reg != 127` → fixed‑size 1‑byte read.
  - `rw=0`: register WRITE. `reg != 127` → fixed‑size 1‑byte write (payload follows).
- `reg==127` selects the XFER portal (variable‑length transfer; see below).
- Register file owned by connector (addresses 0x0..0xF used):
  - 0x0..0x3: ASCII device ID: 'A','2','F','P'.
  - 0x4: `PROTO_VER` (0x01).
  - 0x5: `CAP0 = {6'b0, USE_CRC, 1'b1}` where bit0 advertises XFER portal present.
  - 0x6..0xF: general R/W registers (reset to 0x00).
- Register reads return the byte immediately following the opcode (i.e., the next slave byte after the opcode is the register value).

## XFER Portal (reg 127)
- Subheader (little‑endian fields):
  - `SUB0`: `{ [7]=0, [6]=RES, [5]=CRC_EN, [4]=INC, [3:1]=SPACE, [0]=DIR }`
    - `DIR`: 0=WRITE (host→device), 1=READ (device→host)
    - `SPACE`: 3‑bit memory space selector (0 = connector local 256B RAM)
    - `INC`: auto‑increment address for multi‑byte transfers
    - `CRC_EN`: if set and `USE_CRC=1`, CRC‑8 (poly 0x07) applies to header/payload
  - `ADDR[23:0]` (low, mid, high)
  - `LEN[15:0]` (low, high)
- WRITE payload: host sends `LEN` data bytes; if `INC`, address increments per byte.
- READ payload: deterministic first dummy byte. The first host dummy clocks the device’s first data read; subsequent dummies retrieve data bytes. If memory latency requires, the device sends 0xFF until data is ready.

## Proto Processor ↔ Connector Interface
- Register interface:
  - `reg_wr_req` (pulse), `reg_idx[6:0]`, `reg_wdata[7:0]`, `reg_rdata[7:0]` (comb OK)
- Memory interface:
  - WRITE: `mem_wr_en` (pulse), `mem_space[2:0]`, `mem_wr_addr[23:0]`, `mem_wr_data[7:0]`
  - READ: `mem_rd_req` (pulse), `mem_rd_space[2:0]`, `mem_rd_addr[23:0]`, and return via `mem_rd_valid` + `mem_rd_data[7:0]` (1+ cycle latency allowed)

## State Machine Overview (proto)
- IDLE → SYNC0 → SYNC1 → OPCODE → (HDRCRC?) → REG_RW or XFER header states (XA0..XL1) → (HDRCRC?) → PAYLOAD (WRITE or READ) → (PLCRC?) → DONE → IDLE
- On each received byte boundary, the next transmit byte is prepared and loaded on the next SCLK falling edge to be valid before the subsequent rising edge.

## Reset/Idle Behavior
- Reset returns state to IDLE, clears counters, sets `ok=1`, other status bits 0.
- If `IDLE_TO_CYC` expires without SCLK toggles, reframe to IDLE and clear any in‑flight transaction.

## Compliance
- Mode 0 (MSB‑first) behavior is required.
- Read header immediately followed by one byte that is the register value (no extra status byte after opcode).
- XFER READ requires one dummy byte before first data and supports variable latency via `mem_rd_valid`.
