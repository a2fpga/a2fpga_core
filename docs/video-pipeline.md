# Video Pipeline & Display Paths

How Apple II video gets from the bus to HDMI. The core's design **decouples the video generator
from the display backend** through one interface,
[`pixel_stream_if`](../hdl/video/pixel_stream_if.sv). This page covers that model, the two
consumer modes, the architectural direction, the interface contract, and **how to add a new
video generator** (e.g. a Videx 80-column card).

## The model: generators → `pixel_stream_if` → a consumer

A **video generator** turns Apple video memory into a stream of pixels and pushes them into
`pixel_stream_if`. It **knows nothing about what happens next** — whether a framebuffer exists,
what memory the board has, or how the frame reaches HDMI. A **consumer** on the far side of the
interface owns all of that. There are two consumers, and each board picks one:

| Consumer | Path name | Mechanism | Off-chip RAM? | Beam-racing |
|---|---|---|---|---|
| [`framebuffer_writer`](../hdl/video/framebuffer_writer.sv) | **Apple-timed framebuffer** | Generator clocked by Apple video timing; pixels captured into SDRAM/DDR3, HDMI scans out the finished frame | Required | **Kept intact** |
| [`direct_display`](../hdl/video/direct_display.sv) | **HDMI-locked render** | Generator clocked by the HDMI pixel clock; pixels go straight to the HDMI encoder | None | Breaks |

The two consumers differ in **which clock the generator is timed against**, and that single fact
determines whether Apple software that uses *beam-racing* keeps working.

> **Beam-racing is an Apple-side application technique — not something the A2FPGA does.** An
> Apple program races the video beam by rewriting display memory (or flipping soft switches) in
> step with the scan, producing effects that change partway down a single frame (e.g. mid-frame
> mode splits in games like *Arkanoid* and *Bugz*). The A2FPGA's job is to reproduce the Apple's
> display faithfully; the question for each consumer is whether it **keeps these techniques
> intact** or **breaks** them.

### Apple-timed framebuffer (consumer: `framebuffer_writer`)

Timing (`hsync`/`vsync`/`scanline`) is synthesized from the Apple bus by
[`scan_timer`](../hdl/video/scan_timer.sv), so the generator captures each Apple scanline *as the
Apple produces it* and the writer stores it in an off-chip framebuffer. A display reader scans
the finished frame out at HDMI timing.

- **Clocks:** generator + writer run on `clk_logic` (~54 MHz), gated by a `pixel_clk_en` strobe
  at the Apple capture rate; the framebuffer is read out on the HDMI pixel clock — the buffer is
  the clock-domain boundary.
- **Board framebuffer:** `sdram_framebuffer` on GS, [`framebuffer_480p`](../hdl/video/framebuffer_480p.sv) on a2mega.
- **Boards today:** `a2mega` (DDR3), `a2n20v2-GS` (SDRAM).
- **Beam-racing: kept intact** — because capture is clocked by the Apple's own video timing,
  software that races the beam (*Arkanoid*, *Bugz*) reproduces faithfully; the finished frame is
  just presented to HDMI delayed by up to one frame, which is invisible.

> **Why the framebuffer is the consumer that keeps beam-racing intact** (it's counterintuitive):
> the win isn't the buffer itself, it's that the generator is clocked by the *Apple's* video
> timing rather than HDMI's, so it samples each line in the same timing relationship the
> application assumed. The buffer just bridges the two unsynchronized clock domains.

### HDMI-locked render (consumer: `direct_display`)

[`direct_display`](../hdl/video/direct_display.sv) drives `pixel_clk_en` from the **HDMI** pixel
clock and sends RGB straight to the HDMI encoder — same generators, no framebuffer.

- **Clock:** the generator runs gated by the HDMI pixel clock.
- **Off-chip RAM:** none. This is the path for boards that have no framebuffer memory, or that
  don't intend to spend it on video.
- **Beam-racing: breaks** — with no buffer to bridge the Apple-vs-HDMI clock mismatch, VRAM is
  sampled whenever the HDMI scan arrives, so mid-frame effects land at the wrong place and tear.
  This is an inherent limit of having no framebuffer, **not** a defect of `direct_display`.
- On `a2n20v2-GS`, `USE_DIRECT_DISPLAY` (default `0` = framebuffer) selects this consumer. It was
  first added to isolate SDRAM "ghosting" artifacts, and is now the intended model for
  framebuffer-less boards (see the direction below).

## Architectural direction: one renderer model for every board

**Every board should converge on this model — pixel-stream generators plus a consumer — so the
generators are written once and the framebuffer is invisible to them.** Concretely:

- **New generators target `pixel_stream_if`** (the `apple_video_gen` / `vgc_gen` style), never
  the HDMI raster directly.
- **The legacy raster-driven generators** — [`apple_video`](../hdl/video/apple_video.sv) and
  [`vgc`](../hdl/video/vgc.sv), still used by `a2n20v2`, `a2n20v2-Enhanced`, `a2p25`, `a2n9`,
  `a2n20v1` — are to be **migrated** onto the pixel-stream generators feeding a `direct_display`
  consumer. Those boards then run the *identical* generators the framebuffer boards use, with
  only the consumer differing.
- **`direct_display` is a first-class output model, not a test fixture.** It began as a
  ghost-isolation aid; it becomes the standard HDMI-locked consumer for any board that can't or
  won't carry a framebuffer.
- **The framebuffer is hidden from the renderer.** A board with off-chip memory uses
  `framebuffer_writer` (and gets beam-racing for free); a board without it uses `direct_display`.
  The generator code is identical — the choice is a single consumer swap in `top.sv`.

The payoff: one set of video generators to maintain and test, new display features land on every
board at once, and the only per-board video decision is **"framebuffer or direct."**

## The `pixel_stream_if` contract

[`pixel_stream_if`](../hdl/video/pixel_stream_if.sv) is the seam between a video **generator**
and a **consumer** (`framebuffer_writer`, `direct_display`, or a testbench). All signals are
synchronous to the consumer's clock (typically `clk_logic`).

| Signal | Dir (generator modport) | Meaning |
|---|---|---|
| `pixel_clk_en` | input | Clock enable. Advance exactly one pixel on each cycle it's high. **Not a clock.** |
| `hsync` | input | Scanline-start pulse (1 cycle). |
| `vsync` | input | Frame-start pulse (1 cycle) — latch mode registers here. |
| `scanline` | input `[8:0]` | Current scanline number (0–261). |
| `r`,`g`,`b` | output `[7:0]` | RGB888 for the current pixel. |
| `active` | output | High during valid visible pixels. |

**Generator obligations** (learned the hard way — see [gotchas.md](gotchas.md)):

- Advance the pixel pipeline **only** on `pixel_clk_en`; present the pixel on the same enabled cycle.
- **`active` timing matters and differs per generator.** `vgc_gen`'s `active` must be
  **combinational** (a registered `active` causes a phase mismatch with the consumer's pixel
  sampling); `apple_video_gen`'s `active` may be **registered** because its fetch runs
  concurrently. Get this wrong and you get column/phase artifacts. See [gotchas.md](gotchas.md).
- Allow a few pixels of **warm-up** before asserting `active` if your output depends on
  artifact history (NTSC-style coloring).
- Don't assume back-to-back pixels: the framebuffer consumer strobes `pixel_clk_en` with a gap
  (**`GAP_CYCLES ≥ 2`** — the DDR3 write group needs a 1-cycle gap), and `direct_display`
  strobes it at the HDMI pixel rate. Your generator must be correct for any `pixel_clk_en` cadence.
- **VRAM reads are not part of this interface.** The generator owns its own memory-read ports
  (`video_address_o`/`video_rd_o`/`video_data_i`, or `vgc_*`), kept separate so memory
  arbitration is decoupled from pixel timing.

## Adding a new video generator (e.g. Videx 80-column)

Use [`apple_video_gen`](../hdl/video/apple_video_gen.sv) and
[`vgc_gen`](../hdl/video/vgc_gen.sv) as templates, and **target `pixel_stream_if`** — never write
a new HDMI-raster-driven generator. A pixel-stream generator works with *both* consumers
unchanged: feed it to `framebuffer_writer` on a framebuffer board, or to `direct_display` on one
without, and it runs on every board.

A generator module should:

1. **Expose the `pixel_stream_if.generator` modport** and honor the contract above (work for any
   `pixel_clk_en` cadence).
2. **Consume the bus/mode interfaces it needs:**
   - [`a2bus_if`](../hdl/bus/a2bus_if.sv) to snoop the Apple bus (decode your card's soft
     switches / I/O, e.g. Videx mode and bank registers).
   - [`a2mem_if`](../hdl/memory/a2mem_if.sv) and/or `video_control_if` for shared mode state
     (TEXT/HIRES/COL80/etc.) and external enable.
3. **Drive its own memory-read port** for whatever it displays (character ROM / screen RAM),
   the way the existing generators route `video_*` / `vgc_*`.
4. **Produce RGB888 + `active`** on `pixel_clk_en` cycles, latching mode/base-address at `vsync`.

To wire it into a board, instantiate it alongside the existing generators and feed its
`pixel_stream_if` into the board's consumer (`framebuffer_writer` or `direct_display`), or
multiplex it with the existing generators the way `a2mega`/`GS` select between `apple_video_gen`
and `vgc_gen`.

## Module reference

| File | Role |
|---|---|
| [`pixel_stream_if.sv`](../hdl/video/pixel_stream_if.sv) | Generator↔consumer interface |
| [`apple_video_gen.sv`](../hdl/video/apple_video_gen.sv) / [`vgc_gen.sv`](../hdl/video/vgc_gen.sv) | Pixel-stream generators (the model to use) |
| [`apple_video.sv`](../hdl/video/apple_video.sv) / [`vgc.sv`](../hdl/video/vgc.sv) | **Legacy** HDMI-raster generators — to be migrated onto the pixel-stream generators |
| [`scan_timer.sv`](../hdl/video/scan_timer.sv) | Synthesizes Apple-timed `hsync`/`vsync`/`scanline` from the bus |
| [`framebuffer_writer.sv`](../hdl/video/framebuffer_writer.sv) | Consumer: pixel stream → framebuffer write port |
| [`framebuffer_480p.sv`](../hdl/video/framebuffer_480p.sv) | a2mega DDR3 framebuffer (board frame store) |
| [`direct_display.sv`](../hdl/video/direct_display.sv) | Consumer: pixel stream → HDMI (HDMI-locked, no buffer) |
| [`f18a_gen.sv`](../hdl/video/f18a_gen.sv) | F18A/TMS9918A (SuperSprite) generator |

## See also

- [gotchas.md](gotchas.md) — the generator-timing traps (combinational vs registered `active`,
  `GAP_CYCLES`, generate-block wire declarations).
- [memory_bandwidth_analysis.md](memory_bandwidth_analysis.md) — framebuffer bandwidth budget.
- [memory-system.md](memory-system.md) — the framebuffer memory backends and port arbitration.
- [architecture.md](architecture.md) — where the video pipeline sits in the whole design.
