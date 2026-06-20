# Uthernet II FPGA ↔ BL616 contract

How the FPGA `Uthernet2` card (`hdl/uthernet2/uthernet2.sv`) and the BL616 W5100 engine
(`firmware_host/w5100.c`) communicate over the existing SPI link. See
[BL616_SPI_PROTOCOL.md](BL616_SPI_PROTOCOL.md) for the base SPI register/XFER protocol and
[UTHERNET2.md](UTHERNET2.md) for the overall design.

## 1. Backing store — SPI memory SPACE 3

The card holds the W5100 register + buffer space in BSRAM (port A = Apple II, port B =
BL616). Port B is exposed to the BL616 as XFER **memory SPACE 3**, addressed in **natural
W5100 addresses** (the card compresses to physical BSRAM internally):

| W5100 address | contents |
|---|---|
| `0x0000–0x07FF` | common registers + the four socket register blocks (`0x0400 + n*0x100`) |
| `0x4000–0x5FFF` | TX buffers (8 KB) |
| `0x6000–0x7FFF` | RX buffers (8 KB) |

Access from firmware:

```c
fpga_spi_xfer_read (FPGA_SPACE_W5100, w5100_addr, buf, len);   /* space 3 */
fpga_spi_xfer_write(FPGA_SPACE_W5100, w5100_addr, buf, len);
```

W5100 multi-byte registers are **big-endian** (MSB at the lower address).

## 2. Command doorbell — register 0x7A (`U2_CMD_PENDING`)

When the Apple II writes a socket command register `Sn_CR` (W5100 `0x0401 / 0x0501 /
0x0601 / 0x0701`), the card latches a per-socket *pending* bit and keeps the written
command value in BSRAM.

| reg | bits | read | write |
|---|---|---|---|
| `0x7A` | `[3:0]` = sockets 0–3 | 1 = command pending for that socket | **write-1-to-clear** |

Firmware loop (`w5100_poll`):

```c
uint8_t pending = fpga_spi_reg_read(FPGA_REG_U2_CMD_PENDING) & 0x0F;   /* 0x7A */
for each socket n with pending bit:
    cmd = read Sn_CR from BSRAM (SPACE 3)
    dispatch(n, cmd)
    write Sn_CR = 0 back   (the W5100 auto-clears Sn_CR once accepted)
fpga_spi_reg_write(FPGA_REG_U2_CMD_PENDING, pending);   /* clear serviced bits */
```

The card sets a pending bit (set wins over a simultaneous clear, so a command is never
lost) and clears it on the write-1-to-clear strobe.

## 3. Register ownership

| Written by the Apple II (read by firmware) | Written by firmware (read by the Apple II) |
|---|---|
| `MR`, `SHAR`, `RMSR`/`TMSR`, `Sn_MR`, `Sn_CR`, `Sn_TX_WR`, `Sn_RX_RD`, TX buffer data | `Sn_SR`, `Sn_RX_RSR`, `Sn_TX_FSR`, `Sn_TX_RD`, RX buffer data |

The only latency is the firmware poll interval (~1 ms); W5100 software spins on `Sn_SR` /
`Sn_RX_RSR` anyway, so this is invisible in practice.

## 4. MACRAW data flow (socket 0)

- **OPEN** (`Sn_MR`=MACRAW): firmware reads `RMSR`/`TMSR` for the socket-0 buffer sizes,
  resets the ring pointers, reads `SHAR` (the Apple II MAC), sets `Sn_SR=SOCK_MACRAW`
  (0x42), and starts bridging. A polled MAC sync then programs the dongle's hardware MAC =
  `SHAR` (via `r8152_write_hwaddr`) so the adapter's filter passes the Apple II's frames —
  see *MAC strategy* in [UTHERNET2.md](UTHERNET2.md). (Promiscuous is a compile-time fallback.)
- **SEND**: firmware reads `Sn_TX_RD`/`Sn_TX_WR`, copies the frame out of the TX ring
  (handling wrap), transmits it verbatim on the adapter, then sets `Sn_TX_RD = Sn_TX_WR`
  and refreshes `Sn_TX_FSR`.
- **RX** (wire → Apple II, from the USB RX hook): apply the MAC filter (`Sn_MR.MF`:
  broadcast/multicast or our `SHAR`), prepend the 2-byte MACRAW length header (`frame_len +
  2`, big-endian), write `[len_hi, len_lo, frame]` into the RX ring (handling wrap),
  advance the internal write pointer, and update `Sn_RX_RSR`.
- **RECV**: the Apple II advanced `Sn_RX_RD`; firmware recomputes `Sn_RX_RSR` from the
  pointers.
- **CLOSE/DISCON**: `Sn_SR=CLOSED`, stop bridging.

## 5. Clocking / timing notes

- Both BSRAM ports run on `clk_logic` (54 MHz) — single clock domain, no CDC.
- SPACE 3 is a drop-free path by construction (single-cycle BSRAM, no SDRAM arbitration),
  modeled on SPACE 0; contrast SPACE 1 (SDRAM), which uses a write FIFO for reliability.
- The data-port read is registered BSRAM (NO_CHANGE write mode — the supported Gowin DPB
  mode); the internal address is stable cycles ahead of the Apple II read window.
