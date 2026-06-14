# Coprocessor Interface

How an external coprocessor (MCU) observes and controls the A2FPGA core, and the contract for
building a new coprocessor connector. This is the surface originally built for the on-FPGA
PicoSoC; it now backs the **BL616** (a2n20v2-Enhanced) and **ESP32-S3** (a2mega, a2p25) MCUs,
and is the integration point for any future controller.

## The model

A **connector** module sits between the serial transport (SPI / OSPI) to the MCU and the rest
of the core. Its job is to bridge that transport to a fixed set of SystemVerilog interfaces.
Those interfaces split cleanly into two directions:

- **Observe (read-only):** the connector watches the Apple II.
- **Control (driven by the connector):** the connector steers the core on the MCU's behalf.

```
        MCU (BL616 / ESP32-S3)
              │  SPI / OSPI
        ┌─────┴──────┐
        │  connector │  ── observes ──>  a2bus_if, a2mem_if (+ bus-event FIFO)
        │ (register  │
        │  file +    │  ── controls ──>  a2bus_control_if, video_control_if,
        │  mem spaces)│                  slotmaker_config_if, drive_volume_if[2],
        └────────────┘                  f18a_gpu_if, (optional) mem_port_if
```

The connector exposes a **register file + memory spaces** over the wire (see the per-transport
protocol docs); register writes/reads and memory transfers are what the MCU firmware uses to
read the observe interfaces and drive the control interfaces.

## Observe surface (read-only)

| Interface | What the coprocessor sees |
|---|---|
| [`a2bus_if`](../hdl/bus/a2bus_if.sv) (`.slave`) | Live Apple II bus: address/data/strobes and the control lines (INH/IRQ/RDY/DMA/NMI/RESET). **Observed only** — the connector does not drive these (the one exception is `a2bus_control_if.ready`, below). |
| [`a2mem_if`](../hdl/memory/a2mem_if.sv) (`.slave`) | Decoded Apple soft-switch / mode state (TEXT/HIRES/PAGE2/COL80/…, IIgs color & SHRG bits) and the keyboard (`keycode`, `keypress_strobe`). Read-only for the coprocessor. |
| Bus-event FIFO ([`a2bus_event_fifo`](../boards/a2n20v2-Enhanced/hdl/bl616/a2bus_event_fifo.sv)) | A capture queue of bus transactions so the MCU can pull a stream of events without keeping up with the bus in real time. Used by the BL616 path; exposed as FIFO registers + a bulk-read memory space. |

## Control surface (driven by the connector)

| Interface | What the coprocessor controls |
|---|---|
| [`a2bus_control_if`](../hdl/bus/a2bus_control_if.sv) (`.control`) | A single `ready` line gating whether the bus controller proceeds — a one-way "MCU is up" handshake, not full bus mastering. |
| [`video_control_if`](../hdl/video/video_control_if.sv) (`.control`) | Override the displayed video mode and colors (for an on-screen display / config UI). `enable` plus the mode/color fields; the video generators consume the `.display` side. |
| [`slotmaker_config_if`](../hdl/slots/slotmaker_config_if.sv) (`.controller`) | Assign which virtual card occupies each slot at runtime (`slot`, `card_i`, `wr`, `reconfig`; reads back `card_o`) — reconfigure cards without a rebuild. |
| [`drive_volume_if`](../hdl/disk/drive_volume_if.sv) (`.volume`), `volumes[2]` | Disk volumes: present mount state/size/read-only and service block I/O (`lba`/`blk_cnt`/`rd`/`wr`/`ack`). Two volumes. The Disk II controller is the `.drive` side. |
| [`f18a_gpu_if`](../hdl/f18a/f18a_gpu_if.sv) (`.master`) | F18A (TMS9918A) GPU: execution control plus VRAM / palette / register access. (The a2mega OSPI connector currently uses this for memory access only and stubs execution.) |
| [`mem_port_if`](../hdl/memory/mem_port_if.sv) (`.client`), **optional** | One SDRAM port for the MCU (`addr`/`data`/`wr`/`rd`/`burst` → `q`/`available`/`ready`). Present on the BL616 path; the ESP32 connectors use local BRAM spaces instead. |

> The `a2mem_if`/`a2bus_if` "master vs slave" modport names refer to who drives the *Apple-side*
> data; the **coprocessor is always the reader** of those two. It writes only through the control
> interfaces above.

## Reference connectors

Three connectors implement this contract today. **The BL616 connector is the canonical, full
implementation** — start there. Transport and protocol details live in the per-board protocol docs.

| Connector | Board | Transport | Scope | Protocol doc |
|---|---|---|---|---|
| [`bl616_spi_connector`](../boards/a2n20v2-Enhanced/hdl/bl616/bl616_spi_connector.sv) | a2n20v2-Enhanced | 4-wire SPI (CS#-framed) | **Full**: all control interfaces + SDRAM port + bus-event FIFO + on-FPGA SD master | [BL616_SPI_PROTOCOL.md](../boards/a2n20v2-Enhanced/src/a2n20_bl616/docs/BL616_SPI_PROTOCOL.md) |
| [`esp32_spi_connector`](../boards/a2p25/hdl/esp32/esp32_spi_connector.sv) | a2p25 | 3-wire SPI (sync-framed) | Minimal/diagnostic (register + local-RAM space) | [ESP32_SPI_PROTOCOL.md](../boards/a2p25/docs/ESP32_SPI_PROTOCOL.md) |
| [`esp32_ospi_connector`](../boards/a2mega/hdl/esp32/esp32_ospi_connector.sv) | a2mega | Octal SPI (8-bit parallel) | Memory-mapped: video, slots, volumes, F18A VRAM | [ESP32_OSPI_DESIGN.md](../boards/a2mega/docs/ESP32_OSPI_DESIGN.md) |

The protocol docs are the **authoritative source for the register map, opcodes, framing, and
memory spaces** — this page intentionally does not duplicate them (they'd drift). What's common
across all three: an opcode that selects register read/write or a variable-length memory
transfer ("XFER") portal, a status byte, and a small set of memory spaces (a local scratch RAM
is always present).

## The bridge pattern

Every connector follows the same shape:

1. **Instantiate a protocol processor** (`*_spi_proto_proc` / `*_ospi_proto_proc`) that turns the
   serial frames into a simple internal bus: `reg_wr_req` / `reg_idx` / `reg_wdata` / `reg_rdata`
   for the register file, and `mem_*` signals for the memory spaces.
2. **Hold a register file** mirroring the control state (video override, slot assignments, volume
   state, GPU regs, …). The first registers are a device-ID / version / capability / status block
   the MCU polls to detect the FPGA is up.
3. **Implement the memory spaces** — at minimum a small local scratch RAM (space 0); optionally an
   SDRAM bridge (BL616) and the bus-event FIFO read space.
4. **Drive the control interfaces** combinationally from the register file; **read the observe
   interfaces** into readable registers.

## Building a new coprocessor connector

Use [`bl616_spi_connector`](../boards/a2n20v2-Enhanced/hdl/bl616/bl616_spi_connector.sv) as the
template. Minimum viable connector:

1. Pick/implement a transport + protocol processor (reuse an existing `*_proto_proc`, or write one
   to a new protocol doc modeled on the existing ones).
2. Expose the device-ID/version/status registers so firmware can detect and version-check the FPGA.
3. **Drive every control interface your board wires up** — at least `a2bus_control_if.ready`,
   `video_control_if`, `slotmaker_config_if`, and `volumes[2]`. Interfaces you don't implement
   yet must still be **driven to safe constants** (stub them), or synthesis sweeps logic and the
   bus may stall.
4. Add memory spaces / FIFO / SDRAM access as the board needs them.

**Stub pattern when no coprocessor is present.** Each board's `top.sv` has an `else` branch that
ties every control interface to constants so the design builds and runs without an MCU — e.g. in
[a2n20v2-Enhanced/hdl/top.sv](../boards/a2n20v2-Enhanced/hdl/top.sv) the no-coprocessor branch
sets `a2bus_control_if.ready = 1'b1`, `video_control_if.enable = 1'b0`, the F18A signals to their
idle values, and `spi_miso = 1'b1`. A new connector must drive the same set.

> **Board-specific extras are not part of the shared contract.** The BL616 connector also carries
> raw wires for an on-FPGA SD-card SPI master, LEDs, WS2812, and a button. Those are BL616/board
> features, not interfaces a generic coprocessor must implement.

## See also

- [BL616_SPI_PROTOCOL.md](../boards/a2n20v2-Enhanced/src/a2n20_bl616/docs/BL616_SPI_PROTOCOL.md) — canonical wire protocol & register map.
- [ESP32_SPI_PROTOCOL.md](../boards/a2p25/docs/ESP32_SPI_PROTOCOL.md), [ESP32_OSPI_DESIGN.md](../boards/a2mega/docs/ESP32_OSPI_DESIGN.md) — the ESP32 variants.
- [architecture.md](architecture.md) — where the coprocessor sits in the whole design.
- [boards.md](boards.md) — which board uses which MCU and transport.
- The BL616 firmware side: [src/a2n20_bl616/README.md](../boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md).
