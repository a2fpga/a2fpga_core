# Uthernet II (W5100) emulation — a2n20v2-Enhanced

An emulated [a2RetroSystems Uthernet II](https://a2retrosystems.com) Ethernet card for
the Apple II, built from a virtual FPGA slot card plus a network engine on the BL616 MCU.
The card is based on the WIZnet **W5100** hardware TCP/IP chip; this implementation splits
the W5100 the same way the real chip is built — **memory + register front-end** in the
FPGA, **network engine** on the BL616.

> Status: **MACRAW bridge implemented; hardware validation pending.** FPGA + firmware both
> build clean. TCP/UDP hardware-socket modes are a future phase (see *Roadmap*).

## Why MACRAW first

Apple II networking software splits into two camps by how it drives the W5100:

| Uses the W5100 **hardware TCP/UDP sockets** | Uses **MACRAW** + its own TCP/IP stack |
|---|---|
| ii-vision, a2stream, native-socket apps | **IP65** (telnet65, wget65, dns65, httpd65, …), **ADTPro** (built on IP65), **Contiki**, **Marinetti** (GS/OS), **A2osX** |

The mainstream ecosystem (IP65 and everything on it, incl. ADTPro) puts the W5100 in
**MACRAW** mode (`Sn_MR=$44`, socket 0) and runs its own stack on raw Ethernet frames, so
MACRAW is implemented first. Because those stacks run on the Apple II, the Apple II appears
on the LAN as its **own host with its own MAC/IP**, and the BL616 bridges its frames at
layer 2 through the USB-Ethernet adapter.

## Architecture

```
 Apple II bus ─$C0nX─▶ [ uthernet2.sv (FPGA) ]          [ BL616: w5100.c ]        wire
  (≈1 MHz, in-cycle)   - 4 C0nX regs: MR / ADDRHI /     - poll doorbell (0x7A)    │
                         ADDRLO / DATA (indirect)        - MACRAW socket 0:        │
                       - 18 KB dual-port BSRAM            OPEN/SEND/RECV/CLOSE     │
                         (regs + TX/RX buffers)          - SEND: drain TX ring ────┼─▶ USB-Eth
                       - auto-inc + 8KB-window wrap        -> eth_output(frame)    │   (promisc)
                       - doorbell on Sn_CR write         - RX: wire frame ─────────┼──
                            │ port B (SPI SPACE 3)         MAC-filter, +2B len,    │
                            └────────────────────────────▶ write RX ring          │
```

- **FPGA card** (`hdl/uthernet2/uthernet2.sv`): the W5100 in **indirect bus mode**. Four
  device-select ($C0nX) registers — MR, address-high, address-low, data — index an on-chip
  copy of the W5100 16 KB address space (registers `0x0000–0x07FF`, TX/RX buffers
  `0x4000–0x7FFF`) held in BSRAM and served to the Apple II at bus speed. Data-port access
  auto-increments the pointer (with the W5100 8 KB-window wrap). Writing a socket command
  register `Sn_CR` raises a per-socket doorbell.
- **BL616 engine** (`firmware_host/w5100.c`): polls the doorbell, reads the command +
  registers/buffers over SPI **memory SPACE 3**, and runs the W5100 behavior. For MACRAW
  it is a layer-2 bridge: SEND drains the TX ring and transmits the frame verbatim; wire
  frames are MAC-filtered, framed with the 2-byte MACRAW length header, and pushed into the
  RX ring. The bridge plumbing (promiscuous mode, raw TX/RX) is in `firmware_host/main.c`.

See [UTHERNET2_PROTOCOL.md](UTHERNET2_PROTOCOL.md) for the exact FPGA↔BL616 contract.

## Network model (bridged)

The Apple II runs its own stack and gets its own DHCP IP; the BL616 is transparent at
layer 2. When a MACRAW socket is open, all wire frames go to the Apple II's RX ring and the
BL616's own lwIP is idle; before that, the BL616 keeps its own DHCP/overlay path.

### MAC strategy — make the two MACs equal at the source

Rather than running the adapter promiscuous and filtering per packet, the bridge makes the
**dongle's hardware MAC equal the Apple II's `SHAR`**, so the dongle's normal filter accepts
the Apple II's frames with zero per-packet work. Two parts, both handled by an idempotent
sync that `w5100_task` polls (the dongle MAC is only known after USB enumeration, and this
also covers either plug order and re-plug):

1. **Preload** `SHAR` (SPACE 3) with the dongle's MAC once the adapter enumerates → stacks
   that *read* their MAC from the card adopt the dongle's MAC.
2. **Mirror-on-overwrite**: when the Apple II writes its own `SHAR` (IP65 writes a hardcoded
   `00:08:DC:A2:A2:A2` before it opens MACRAW), the BL616 programs that MAC onto the dongle
   via the driver's `r8152_write_hwaddr()` (CRWECR unlock → PLA_IDR → relock). This is the
   path that makes IP65/ADTPro work.

**Promiscuous (`RCR_AAP`) is a fallback only**, behind the `W5100_BRIDGE_FORCE_PROMISC`
compile switch, in case the runtime dongle-MAC change proves unreliable. (A software
dest-MAC filter remains in `w5100_macraw_rx` as belt-and-suspenders.)

## C0nX register map (indirect mode)

Mirrored every 4 bytes across `$C0n0–$C0nF` (matches the real card / AppleWin `U2_C0X_MASK`
= 0x03); IP65 uses the `$C0n4–$C0n7` mirror.

| offset[1:0] | register | function |
|---|---|---|
| 0 | MR      | Mode Register — `RST` (0x80) resets, `AI` (0x02) enables data-port auto-increment |
| 1 | IDM_AR0 | indirect address, high byte |
| 2 | IDM_AR1 | indirect address, low byte |
| 3 | IDM_DR  | data register: R/W the W5100 byte at the current address, then auto-increment |

## FPGA resources

The full 16 KB buffer + 2 KB register space is backed in BSRAM as two power-of-two
true-dual-port arrays (2 KB + 16 KB = **9 BSRAM blocks**). On the GW2AR-18 this lands at
**42/46 BSRAM (92%)**, 0 timing violations. MACRAW does not change this (it uses socket 0
within the same fixed 16 KB map).

## Build & enable

- **FPGA**: the card is enabled by default (`UTHERNET2_ENABLE=1`, `UTHERNET2_ID=5` in
  `hdl/top.sv`). Build with `tools/build.sh a2n20v2-Enhanced`. Assign it to a slot via the
  BL616 slot-config registers (`0x60–0x67`) or `hdl/slots/slots.hex`.
- **Firmware**: `firmware_host/` (USB-host build). `w5100.c` is compiled in and the
  `w5100` task is spawned in `main()`. Flash **only** via `/flash-mcu` (Stage 2 @0x40000) —
  never `make flash` (it bricks the fused board).
- **Uplink**: plug a supported USB-Ethernet adapter (RTL8152) into the BL616's USB port.

## Test recipe (pending hardware)

1. Plug in the USB-Ethernet adapter; confirm link.
2. In the Apple II, with the Uthernet II in its slot, run an **IP65** app:
   - `DHCP` → the Apple II obtains its own LAN lease;
   - `PING` a LAN host;
   - `TELNET65` to a host;
   - **ADTPro over Ethernet** disk transfer.
3. On the LAN, Wireshark should show frames carrying the **Apple II's own MAC/IP**.

## Known limitations / roadmap

- **MACRAW only** (the IP65/ADTPro/Contiki/Marinetti/A2osX path). Hardware TCP/UDP socket
  modes (for ii-vision, a2stream, native-socket apps; proxy/BL616-IP model) are a future
  phase, as are IPRAW, a card slot ROM, and virtual DNS.
- **Promiscuous OCP write + the end-to-end bridge are not yet hardware-validated.**
- Per-frame SPI throughput (~600 µs / 1514 B each way at 20 MHz) suits interactive use
  (telnet/ADTPro); bulk streaming is the socket path's job (future phase).
