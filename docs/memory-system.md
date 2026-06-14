# Memory System

How the core's clients reach off-chip memory: the common port interface, multi-port arbitration,
the per-board backends (SDRAM on Tang Nano 20K, DDR3 on a2mega), and the clock-domain crossings.

## One interface, two backends

Every memory client — video shadow RAM, the framebuffer, Ensoniq sound RAM, the coprocessor —
talks to memory through the same interface, [`mem_port_if`](../hdl/memory/mem_port_if.sv). What's
behind it is board-specific and **invisible to the client**:

- **Tang Nano 20K boards** (`a2n20v2`, `a2n20v2-GS`, `a2n20v2-Enhanced`): SDRAM, via
  [`sdram_ports`](../hdl/sdram/sdram_ports.sv) → [`sdram.sv`](../hdl/sdram/sdram.sv).
- **a2mega** (Tang Mega 60K): DDR3, via [`ddr3_ports`](../hdl/ddr3/ddr3_ports.sv) → the Gowin
  DDR3 IP.

`sdram_ports` and `ddr3_ports` both present an array of `mem_port_if` ports, so client code
(framebuffer, sound, etc.) is portable across the two memory technologies.

## The port interface (`mem_port_if`)

A client drives the `client` modport; the controller side drives `controller`.

| Signal | Dir (client) | Meaning |
|---|---|---|
| `addr` | out | Word address (each board applies a per-port base offset, see below). |
| `data` | out | Write data (`DATA_WIDTH`, default 16). |
| `byte_en` | out | Per-byte write mask (`DQM_WIDTH`). |
| `wr` / `rd` | out | Write / read request (pulse). |
| `burst` | out | When high, a read returns the controller's burst length. |
| `q` | in | Read data (`PORT_OUTPUT_WIDTH`, default `DATA_WIDTH*2`). |
| `available` | in | Port can accept a new request. |
| `ready` | in | One pulse per returned read beat (or write completion). |

**Semantics:** issue a read with `rd` (+`burst` for a multi-word fetch) or a write with `wr` +
`byte_en`; the controller answers with one `ready` pulse per beat, data on `q`. Because a burst
returns several words, `q` is wider than `data` and beats arrive across successive `ready`
pulses — the CDC (below) buffers them so the client consumes one per cycle. Addressing is
**word-based**; the controller converts to the physical byte/burst address.

## Multi-port arbitration

Each board instantiates one `*_ports` arbiter with `NUM_PORTS` client ports muxed onto the single
controller:

- **Static priority — lower port index wins.** Port 0 preempts port 1, etc.
- **`PORT_BASE_ADDR[]`** gives each port its own address window (applied inside the arbiter, so
  clients address from 0). Windows must not overlap or memory aliases.
- [`mem_if_mux`](../hdl/memory/mem_if_mux.sv) is a separate 2→1 stateless mux used where two
  clients share one port by a select line (not priority arbitration).

### Per-board port maps

The index assignment encodes the priority decision for that board.

**`a2n20v2-GS` (SDRAM)** — [top.sv:162](../boards/a2n20v2-GS/hdl/top.sv)
| Port | Use |
|---|---|
| 0 | Framebuffer line **reads** (highest — must not starve, or the scanout stalls) |
| 1 | Framebuffer pixel **writes** |
| 2 | Shadow/video RAM reads (video generators) |
| 3 | Shadow/video RAM writes (CPU) |
| 4 | Ensoniq DOC reads |
| 5 | Ensoniq GLU writes |

**`a2mega` (DDR3)** — [top.sv:330](../boards/a2mega/hdl/top.sv)
| Port | Use |
|---|---|
| 0 | Framebuffer pixel **writes** (highest — writes must not be starved or pixels drop) |
| 1 | Framebuffer line **reads** |
| 2–3 | Shadow/video RAM read / write |
| 4–5 | Ensoniq DOC / GLU (ports exist but sound is BSRAM-backed here) |

> The framebuffer-read-vs-write priority is flipped between the two boards on purpose — it's the
> per-board tuning that keeps the scanout fed without dropping writes. See
> [gotchas.md](gotchas.md) and [memory_bandwidth_analysis.md](memory_bandwidth_analysis.md).

**`a2n20v2-Enhanced` (SDRAM)** has no framebuffer (it uses the HDMI-locked render path), so its
ports are shadow/video RAM, Ensoniq DOC/GLU, and the **coprocessor** SDRAM port (`MCU_MEM_PORT`).

## Clock domains & CDC

Memory runs faster than the 54 MHz logic clock, so every port crosses a clock domain:

- **SDRAM (Tang Nano 20K):** SDRAM at **108 MHz**, logic at **54 MHz**, related by `CLKDIV2`
  (every logic edge coincides with an SDRAM edge). Bridged per-port by
  [`mem_port_cdc`](../hdl/sdram/mem_port_cdc.sv). The SDRAM read clock **phase** is critical —
  a wrong PLL phase (`PSDA_SEL`) caused the GW2AR "ghosting" bug; see [gotchas.md](gotchas.md).
- **DDR3 (a2mega):** the DDR3 app clock (`clk_x1`) is **81 MHz** (324 MHz memory clock ÷ 4) and is
  **asynchronous** to the 54 MHz logic clock. Bridged per-port by an async CDC,
  [`ddr3_port_cdc`](../hdl/ddr3/ddr3_port_cdc.sv). On the GW5AT, async FIFOs must use block RAM
  (not FF arrays) or data bits corrupt — see [gotchas.md](gotchas.md).

> Note: some comments in [`ddr3_ports.sv`](../hdl/ddr3/ddr3_ports.sv) still describe an older
> "108 MHz / CLKDIV2-synchronous" DDR3 clocking; the live design is 81 MHz async (per `top.sv` and
> the `ddr3_port_cdc` header). Trust the wiring over those comments.

## The framebuffers

The board framebuffer is a memory client that owns the FB read+write ports and turns them into an
HDMI scanout:

- [`sdram_framebuffer`](../boards/a2n20v2-GS/hdl/video/sdram_framebuffer.sv) (GS) and
  [`framebuffer_480p`](../hdl/video/framebuffer_480p.sv) (a2mega).
- **Write side:** packs incoming pixels (2× RGB565 per 32-bit word) and writes them via the FB
  write port.
- **Read side:** prefetches each display line into a dual-port line buffer via the FB read port,
  then the HDMI side reads the line buffer at the pixel clock. The line buffer is itself the
  CDC between the memory side and the HDMI pixel clock.
- This is the *consumer* end of the [video pipeline](video-pipeline.md)'s Apple-timed framebuffer
  path. Tuned parameters (burst length, buffer offsets, fetch timing) live in the code and in
  [a2mega/docs/ddr3_framebuffer_480p_design.md](../boards/a2mega/docs/ddr3_framebuffer_480p_design.md)
  / [a2n20v2-GS/docs/WORKPLAN.md](../boards/a2n20v2-GS/docs/WORKPLAN.md).

## Critical constraints (don't get bitten)

- **Do not modify [`sdram.sv`](../hdl/sdram/sdram.sv)** — it's tuned controller IP.
- The **Gowin "magic" SDRAM port names** in `top.sv` (`O_sdram_*`, `IO_sdram_dq`) are matched by
  the toolchain to the on-chip SDRAM; don't rename them.
- **CAS latency and the nanosecond timing parameters are board/device-specific** — changing them
  without re-running timing analysis risks corruption.
- The SDRAM framebuffer read burst width is constrained (a value that's too large deadlocks the
  controller). Respect the value in the instantiation; see [gotchas.md](gotchas.md).
- These and other memory traps are collected in [gotchas.md](gotchas.md).

## See also

- [memory_bandwidth_analysis.md](memory_bandwidth_analysis.md) — bandwidth budget per board/port.
- [gotchas.md](gotchas.md) — SDRAM phase, GW5AT async-FIFO/BSRAM, burst-length, port-priority traps.
- [video-pipeline.md](video-pipeline.md) — the framebuffer as a display-path consumer.
- [coprocessor-interface.md](coprocessor-interface.md) — the coprocessor's `mem_port_if` SDRAM port.
- [architecture.md](architecture.md) — where memory sits in the whole design.
