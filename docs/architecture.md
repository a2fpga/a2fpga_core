# Architecture & Code Organization

How the A2FPGA codebase is laid out, so you (or an agent) can find the right file and know
which questions to ask before changing anything.

## Top-level layout

| Path | Contents |
|---|---|
| `hdl/` | **Shared HDL** (SystemVerilog/Verilog/VHDL) portable across all boards — bus interfaces, video pipeline, sound, debug overlay, memory controllers. |
| `boards/<board>/` | Per-board project: Gowin `.gprj`, board-specific `hdl/` (incl. `top.sv`), build outputs in `impl/pnr/`, and `TODO.md`. See [boards.md](boards.md). |
| `boards/<board>/hdl/` | Board wiring and `top.sv`; board-specific framebuffer/video/bus. |
| `boards/<board>/src/` | Apple II utilities, sample code, and coprocessor firmware (e.g. the BL616 firmware under `boards/a2n20v2-Enhanced/src/a2n20_bl616/`). |
| `tools/` | Build tooling and Gowin setup scripts ([setup-gowin-cli.md](setup-gowin-cli.md)). |
| `tests/` | Targeted HDL test assets (e.g. sound VCDs) for manual inspection. |
| `releases/` | Prebuilt artifacts for users. |

**Rule of thumb:** portable logic → `hdl/`; anything that knows about a specific FPGA, its
pins, or its memory → `boards/<board>/hdl/`. The per-board `top.sv` is the integration point.

## What the core does (one paragraph)

The A2FPGA card sits on the Apple II bus, snoops all display-memory accesses, and renders the
Apple II / //e / IIgs display to 720x480 HDMI. It also emulates popular peripheral cards
(Mockingboard sound, SuperSprite/TMS9918a, Super Serial Card). See the top-level
[README.md](../README.md) for the user-facing feature description and credits.

## The video pipeline

Video generators are decoupled from the display backend by `pixel_stream_if`: a generator emits
pixels into that interface and knows nothing about the framebuffer. Each board picks a **consumer**:

- **`framebuffer_writer`** → **Apple-timed framebuffer** (SDRAM/DDR3) — keeps Apple beam-racing
  techniques intact. Used by `a2mega`, `a2n20v2-GS`.
- **`direct_display`** → **HDMI-locked render** — no framebuffer, for boards that don't carry one.

The direction is for every board to use this model (migrating the legacy raster generators
`apple_video`/`vgc`). **Full detail — the contract, the architectural direction, and how to add a
video generator (e.g. a Videx card) — is in [video-pipeline.md](video-pipeline.md).** Do not edit
the SDRAM controller `hdl/sdram/sdram.sv`.

## Memory

Off-chip memory (SDRAM on the Tang Nano 20K boards, DDR3 on a2mega) is reached through one common
port interface, `mem_port_if`, fronted by a per-board multi-port arbiter with static priority and
a clock-domain crossing. The framebuffer, video shadow RAM, Ensoniq sound RAM, and the coprocessor
are all memory clients. **Full detail — the port contract, arbitration/priority, the SDRAM vs DDR3
backends, the CDC, and the framebuffers — is in [memory-system.md](memory-system.md).**

## Sound & peripheral emulation

Audio — the sound sources, mixing, filtering, CDC, and HDMI audio — is documented in
[audio.md](audio.md). The emulated peripheral cards themselves (SuperSprite/F18A, Mockingboard,
Super Serial Card, Disk II, CardROM) and the open cores they reuse are in
[peripheral-cards.md](peripheral-cards.md).

## Bus interface

The core snoops the Apple II bus (via the per-board `apple_bus` and board-specific interface
hardware — a CPLD on the a2n20 cards, discrete level-shifters elsewhere) and exposes it as
`a2bus_if`; virtual peripheral cards consume it plus `slot_if`. **Full detail — the
`a2bus_if`/`slot_if` contracts, the slot/card decode, driving data back, and how to add a card —
is in [bus-interface.md](bus-interface.md).** The coprocessor-facing control/config interfaces
(`a2bus_control_if`, `video_control_if`, `slotmaker_config_if`, `drive_volume_if`, `f18a_gpu_if`)
are in [coprocessor-interface.md](coprocessor-interface.md).

## See also

- [boards.md](boards.md) — per-board differences
- [gotchas.md](gotchas.md) — the non-obvious traps in this pipeline
- [conventions.md](conventions.md) — how to add a module correctly
