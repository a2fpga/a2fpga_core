# A2N20v2-GS SDRAM Framebuffer Workplan

## Goal

Add SDRAM-based framebuffer support to the a2n20v2-GS board (Tang Nano 20K), enabling beam-racing game effects (e.g. Arkanoid, Bugz) to display correctly via HDMI. This combines:

- **SDRAM infrastructure** from the a2n20v2-Enhanced board
- **Framebuffer architecture** from the a2mega DDR3 framebuffer
- Adapted for SDRAM's simpler timing (single logic clock domain, no async FIFO needed)

## Current State

The a2n20v2-GS board currently has:
- Basic video pipeline: `apple_video` -> `vgc` -> `SuperSprite` -> `DebugOverlay` -> HDMI
- 480p HDMI output (720x480 @ 59.94 Hz, VIDEO_ID_CODE=2)
- No SDRAM — all memory is BRAM-only
- No framebuffer — video is rendered in real-time (beam racing doesn't work)

## Architecture Overview

### Why a Framebuffer?

The current `apple_video` module renders pixels in the HDMI pixel clock domain (27 MHz), synchronized to HDMI scan position. Apple II software that relies on precise CPU-to-beam timing ("beam racing") fails because the FPGA's HDMI timing doesn't match the Apple II's native video timing.

A framebuffer solves this by:
1. Rendering video in the **Apple II native timing domain** (54 MHz logic clock, driven by `scan_timer`)
2. Storing rendered pixels in **SDRAM**
3. Reading pixels back at **HDMI pixel clock rate** for display

### Clock Domains (Simplified vs DDR3)

The SDRAM approach is significantly simpler than the a2mega's DDR3 approach:

| Domain | DDR3 (a2mega) | SDRAM (a2n20v2-GS) |
|--------|---------------|---------------------|
| Logic clock | 54 MHz | 54 MHz |
| Memory controller | 74.25 MHz (separate PLL) | 54 MHz (same as logic) |
| Memory PHY | 297 MHz (DDR3 PLL) | 54 MHz phase-shifted |
| Pixel clock | 27 MHz | 27 MHz |
| TMDS clock | 135 MHz | 135 MHz |
| **Total domains** | **4** | **2** (logic + pixel) |

Since the SDRAM controller runs on the same 54 MHz logic clock, **no async FIFO** is needed between the framebuffer write path and memory — writes go directly through a `mem_port_if` port.

### Data Flow

BRAM and SDRAM serve distinct roles:

1. **BRAM** — Apple II bus writes are shadowed to BRAM (via `apple_memory`, same as current design). The framebuffer renderers (`apple_video_fb`, `vgc_fb`) read VRAM from BRAM.
2. **SDRAM** — Used only for framebuffer pixel storage (rendered RGB) and Ensoniq 128K sound memory. Not involved in Apple II memory shadowing.

```
Apple II Bus (CPU writes)
    |
    v  data_in_strobe
[apple_memory] -----> BRAM (shadow of text, hires, aux pages)
    |                    (same as current design, no SDRAM involvement)
    |
    v  (renderers read from BRAM)
[apple_video_fb] -- renders pixels using scan_timer timing
    |                reads VRAM from BRAM (text, lores, hires, dhires)
    |
[vgc_fb] -- renders IIgs SHR pixels using scan_timer timing
    |          reads from BRAM aux banks (interleaved format)
    |
    v  fb_we + fb_data (RGB666, 18-bit)
[sdram_framebuffer] -- pixel write accumulator
    |
    v  SDRAM via FB_WRITE_PORT (write, port 1)
[sdram_ports] -- SDRAM controller with 4-port arbitration
    |
    v  (SDRAM at 54 MHz, 32-bit data bus)
[Tang Nano 20K on-chip SDRAM, 8MB]
    |
    ^  SDRAM via FB_READ_PORT (read, port 0)
[sdram_framebuffer] -- line fetch FSM
    |
    v  line_buf write (54 MHz)
[Line Buffer BRAM] -- true dual-port, hardware CDC
    |
    v  line_buf read (27 MHz pixel clock)
[480p output logic] -- borders, 2x vertical scaling, scanline dimming
    |
    v  RGB888
[HDMI encoder] -- 720x480 @ 59.94 Hz
```

### BRAM vs SDRAM Split

| Memory Region | Storage | Reason |
|---------------|---------|--------|
| Text pages ($0400-$0BFF) | BRAM | Existing shadow, fast single-cycle reads for renderer |
| Hires pages ($2000-$5FFF) main bank | BRAM | Existing shadow, fast single-cycle reads for renderer |
| Hires pages ($2000-$9FFF) aux bank | BRAM | VGC needs interleaved byte-pair reads in one cycle |
| Framebuffer pixels (rendered RGB) | SDRAM | Too large for BRAM (~500KB) |
| Ensoniq DOC sound memory (128K) | SDRAM | Too large for BRAM |
| Line buffer (1-2 scanlines) | BRAM | True dual-port CDC between 54 MHz and 27 MHz |

### Display Layout

```
720 pixels wide:  [80 border] [560 active] [80 border]   (Apple II modes)
                  [40 border] [640 active] [40 border]   (IIgs SHR modes)
480 lines tall:   [48 border] [384 active = 192x2] [48 border]   (Apple II)
                  [40 border] [400 active = 200x2] [40 border]   (IIgs SHR)
```

- 2x integer vertical scaling (each framebuffer line -> 2 HDMI lines)
- Odd HDMI lines dimmed to 50% for CRT scanline effect (when enabled)
- Border color from Apple II/IIgs palette

### SDRAM Memory Layout

```
Address space: 21-bit (2MB)

Framebuffer region (upper SDRAM):
  Base address: 0x180000 (1.5MB offset)
  Size: 640 * 200 * 4 bytes = 512,000 bytes (~500KB)
  Each pixel: 32-bit word (18-bit RGB666, 14 bits unused)
  Row stride: 640 words (2560 bytes) -- always 640 wide for uniform addressing

Ensoniq region (lower SDRAM):
  Base address: 0x000000
  Size: 128KB (0x00000 - 0x1FFFF) for DOC sound memory
  GLU registers: mapped separately
```

### SDRAM Port Allocation (4 ports)

```
Port 0: FB_READ_PORT   -- Framebuffer line reads (highest priority, display-critical)
Port 1: FB_WRITE_PORT  -- Framebuffer pixel writes (rendered RGB → SDRAM)
Port 2: DOC_MEM_PORT   -- Ensoniq DOC 128K sound memory
Port 3: GLU_MEM_PORT   -- Ensoniq GLU registers
```

**Port usage patterns:**

- **FB_READ_PORT (read-only)**: `sdram_framebuffer` fetches full scanlines into line buffer BRAM. Highest priority to prevent display tearing.

- **FB_WRITE_PORT (write-only)**: `sdram_framebuffer` writes rendered RGB666 pixels. One pixel per 32-bit word at framebuffer base address + linear offset.

- **DOC_MEM_PORT (read/write)**: Ensoniq DOC sound chip reads/writes 128K of wavetable sound memory.

- **GLU_MEM_PORT (read/write)**: Ensoniq GLU register access.

Framebuffer reads get highest priority since display stalls cause visible artifacts. Framebuffer writes are next. Ensoniq ports are lower priority since audio has buffering tolerance.

### SDRAM Bandwidth Budget

At 54 MHz with 32-bit bus, single-word access:
- Theoretical max: ~54M words/sec, but with overhead (activate, precharge, refresh): ~10-15M words/sec effective

**All four ports share SDRAM bandwidth:**

| Port | Direction | Access Pattern | Est. Accesses/sec |
|------|-----------|----------------|-------------------|
| FB_READ (0) | Read | 640/line × 200 lines × 60 fps | ~7.7M |
| FB_WRITE (1) | Write | 560-640/line × 192-200 lines × 60 fps | ~7.7M |
| DOC (2) | R/W | 32 oscillators × ~24K samples/sec | ~0.8M |
| GLU (3) | R/W | Register access, sparse | ~0.01M |
| **Total** | | | **~16.2M** |

This is within the effective bandwidth because:
- FB reads and writes are sequential (same SDRAM row), so open-row optimization reduces per-access overhead to ~2 cycles instead of ~8
- With open-row: effective bandwidth rises to ~27M words/sec for sequential patterns
- Ensoniq access is sparse relative to framebuffer
- No VRAM reads compete for SDRAM — renderers read from BRAM

---

## Implementation Phases

### Phase 1: Module Development (parallel, no hardware needed)

These three workstreams can proceed in parallel. New modules are added to the project file but **not wired into `top.sv`** yet (or added commented-out). The existing video pipeline continues to work unchanged.

#### 1A: SDRAM Infrastructure

**Goal**: Add `sdram_ports` controller and `mem_port_if` array to the project, with ports tied off.

**Files to create/modify**:

1. **`boards/a2n20v2-GS/hdl/top.sv`** — Add SDRAM port declarations and `sdram_ports` instantiation
   - Add SDRAM I/O ports (O_sdram_clk, O_sdram_addr, IO_sdram_dq, etc.)
   - Add `mem_port_if` array instantiation (4 ports)
   - Instantiate `sdram_ports` controller (matching Enhanced board parameters)
   - Wire phase-shifted clock from PLL to SDRAM
   - Tie off all 4 port client signals (rd=0, wr=0, addr=0, etc.) so SDRAM initializes but is idle
   - `apple_memory` remains unchanged (BRAM-only, no SDRAM ports)

2. **`boards/a2n20v2-GS/hdl/a2n20v2_gs.cst`** — No SDRAM pin changes needed (Gowin auto-manages on-chip SDRAM via "magic" signal names)

3. **`boards/a2n20v2-GS/hdl/gowin/clk_logic/clk_logic.v`** — Verify PLL outputs include phase-shifted clock for SDRAM (already has `clkoutp`)

4. **`boards/a2n20v2-GS/a2n20v2_gs.gprj`** — Add SDRAM source files to project:
   - `hdl/sdram/sdram.sv`
   - `hdl/sdram/sdram_ports.sv`
   - `hdl/memory/mem_port_if.sv`

**Validation**: Project synthesizes cleanly with SDRAM controller present but idle.

#### 1B: Scan Timer and Framebuffer Renderers

**Goal**: Copy and adapt framebuffer-aware renderers from a2mega. These are standalone modules — not connected in `top.sv` yet.

**Files to copy from a2mega**:

1. **`boards/a2n20v2-GS/hdl/video/scan_timer.sv`** — Copy from `boards/a2mega/hdl/video/scan_timer.sv`
   - Provides `scanline_o`, `hsync_o`, `vsync_o` driven by Apple II bus timing
   - No modifications needed — it reads from `a2bus_if` directly

2. **`boards/a2n20v2-GS/hdl/video/apple_video_fb.sv`** — Copy from `boards/a2mega/hdl/video/apple_video_fb.sv`
   - Framebuffer-aware Apple II video renderer
   - Outputs `fb_we_o`, `fb_data_o` (RGB666) instead of direct RGB888
   - May need minor adjustments if it references a2mega-specific interfaces

3. **`boards/a2n20v2-GS/hdl/video/vgc_fb.sv`** — Copy from `boards/a2mega/hdl/video/vgc_fb.sv`
   - Framebuffer-aware IIgs Super Hi-Res renderer
   - Same `fb_we_o`, `fb_data_o` interface

4. **`boards/a2n20v2-GS/a2n20v2_gs.gprj`** — Add new source files (can be included in project even if not instantiated in top.sv)

**Validation**: Files are syntactically correct and included in project. Review interfaces for a2mega-specific dependencies and adapt as needed.

#### 1C: SDRAM Framebuffer Module

**Goal**: Write the new `sdram_framebuffer.sv` module. This is standalone — not connected in `top.sv` yet.

**New file**: **`boards/a2n20v2-GS/hdl/video/sdram_framebuffer.sv`**

This is the core new module. It replaces `ddr3_framebuffer_480p.v` with an SDRAM-specific implementation that is simpler due to the single memory clock domain.

**Module interface**:
```systemverilog
module sdram_framebuffer #(
    parameter COLOR_BITS = 18    // RGB666
) (
    // Clocks and reset
    input  logic clk,            // 54 MHz logic clock (also SDRAM clock)
    input  logic clk_pixel,      // 27 MHz pixel clock
    input  logic rst_n,

    // Framebuffer write interface (from apple_video_fb / vgc_fb)
    input  logic fb_vsync,       // Frame start
    input  logic fb_we,          // Pixel write enable
    input  logic [COLOR_BITS-1:0] fb_data,  // RGB666 pixel
    input  logic [10:0] fb_width,   // 560 or 640
    input  logic [9:0]  fb_height,  // 192 or 200

    // SDRAM port interfaces (directly use mem_port_if)
    mem_port_if.client fb_write_port,   // For writing pixels to SDRAM
    mem_port_if.client fb_read_port,    // For reading scanlines from SDRAM

    // HDMI scan position (from HDMI encoder, pixel clock domain)
    input  logic [10:0] hdmi_cx,
    input  logic [9:0]  hdmi_cy,

    // Video output (pixel clock domain)
    output logic [23:0] rgb_o,          // RGB888 output

    // Configuration
    input  logic [COLOR_BITS-1:0] border_color,
    input  logic scanline_en            // Enable CRT scanline dimming
);
```

**Internal architecture**:

1. **Write Path** (all in 54 MHz logic clock domain — no FIFO needed):
   - Accept `fb_we`/`fb_data` from renderer
   - Maintain write position counters (`wr_x`, `wr_y`)
   - On `fb_vsync`: reset to (0, 0)
   - On `fb_we`: write pixel to SDRAM via `fb_write_port`
     - Address = `FB_BASE + wr_y * fb_width + wr_x`
     - Data = `{14'b0, fb_data}` (zero-pad to 32 bits)
   - Increment `wr_x`, wrap at `fb_width` and increment `wr_y`
   - Handle `available` signal — if port busy, buffer one pixel

2. **Read Path / Line Fetch FSM** (54 MHz logic clock domain):
   - Monitor HDMI `cy` (pixel clock) via gray-code CDC to get current display line
   - Calculate which framebuffer line to prefetch: `fb_line = (cy - v_border) >> 1`
   - When display line changes (new `fb_line` detected):
     - Fetch entire scanline from SDRAM into line buffer BRAM
     - Issue sequential reads: `fb_read_port.addr = FB_BASE + fb_line * fb_width + x` for x = 0..fb_width-1
     - Write returned data into line buffer BRAM at position `x`

3. **Line Buffer** (true dual-port BRAM, hardware CDC):
   - 1024 entries x 18 bits (2 banks x 512)
   - Write port: 54 MHz (SDRAM read responses)
   - Read port: 27 MHz (HDMI pixel output)
   - Bank select by line parity — prevents read/write collision

4. **Output Path** (27 MHz pixel clock domain):
   - Calculate border regions from `fb_width`, `fb_height`
   - Read line buffer at `hdmi_cx - h_border` offset
   - Expand RGB666 to RGB888 via `torgb()` function
   - Apply scanline dimming on odd lines: `{1'b0, R[7:1], 1'b0, G[7:1], 1'b0, B[7:1]}`
   - Output border color for non-active pixels

**Validation**: Module compiles as part of the project. Interface review against `mem_port_if` and framebuffer renderer outputs.

---

### Phase 2: Integration and Top-Level Wiring (requires hardware)

**Goal**: Wire all Phase 1 modules into `top.sv` and get end-to-end video working.

**Modify**: **`boards/a2n20v2-GS/hdl/top.sv`**

1. Remove direct `apple_video` → `vgc` → `SuperSprite` → HDMI chain
2. Instantiate `scan_timer` connected to `a2bus_if`
3. Replace `apple_video` with `apple_video_fb`, replace `vgc` with `vgc_fb`
4. Add framebuffer mux:
   ```
   fb_we = vgc_fb_active ? vgc_fb_we : apple_video_fb_we
   fb_data = vgc_fb_active ? vgc_fb_data : apple_video_fb_data
   ```
5. Instantiate `sdram_framebuffer` with:
   - `fb_write_port` → `mem_ports[FB_WRITE_PORT]`
   - `fb_read_port` → `mem_ports[FB_READ_PORT]`
   - Remove port tie-offs from Phase 1A
   - RGB output → SuperSprite → DebugOverlay → HDMI
6. Wire HDMI `cx`/`cy` back to `sdram_framebuffer`
7. Update `DebugOverlay` with framebuffer debug values (write count, line fetch status, etc.)
8. Connect `border_color` from `a2mem_if` soft switches

**Modify**: **`boards/a2n20v2-GS/hdl/a2n20v2_gs.sdc`**
- Add timing constraints for SDRAM ↔ pixel clock CDC paths
- Verify false paths between 54 MHz and 27 MHz domains through line buffer

**Validation**: Full video output — Apple II text mode, graphics modes, IIgs SHR all display correctly via framebuffer

---

### Phase 3: SuperSprite Integration (requires hardware)

**Goal**: Ensure VDP overlay compositing works with framebuffer output.

The a2mega's framebuffer renders SuperSprite compositing **into** the framebuffer during `apple_video_fb` rendering. We need to verify this path works:

1. `apple_video_fb` outputs Apple II RGB to SuperSprite module
2. SuperSprite composites VDP graphics
3. Composited output feeds back as `fb_data` for framebuffer writes

**If SuperSprite compositing is NOT in the framebuffer path** (current a2n20v2-GS has it post-framebuffer):
- Option A: Move SuperSprite compositing into the framebuffer write path (matches a2mega)
- Option B: Keep SuperSprite post-framebuffer (simpler, but beam racing won't apply to VDP)

**Validation**: F-18 Interceptor or other SuperSprite-using software displays correctly

---

### Phase 4: Ensoniq DOC Sound Integration (requires hardware)

**Goal**: Add Ensoniq DOC/GLU support using SDRAM for 128K sound memory.

This mirrors the a2n20v2-Enhanced implementation:

1. Add Ensoniq DOC and GLU modules
2. Connect to `mem_ports[DOC_MEM_PORT]` and `mem_ports[GLU_MEM_PORT]`
3. Mix Ensoniq audio into the existing audio chain
4. Verify SDRAM bandwidth is sufficient with framebuffer + Ensoniq concurrent access

**Validation**: IIgs system sounds, music playback through HDMI audio

---

### Phase 5: Testing and Optimization (requires hardware)

**Goal**: Verify all video modes and optimize SDRAM access patterns.

**Test matrix**:
- [ ] Apple II Text 40-column
- [ ] Apple II Text 80-column
- [ ] Apple II Lo-Res
- [ ] Apple II Hi-Res
- [ ] Apple II Double Hi-Res
- [ ] IIgs Super Hi-Res 320 mode
- [ ] IIgs Super Hi-Res 640 mode
- [ ] Beam racing games (Arkanoid, Bugz)
- [ ] SuperSprite VDP overlay
- [ ] Ensoniq audio playback
- [ ] Scanline effect (DIP switch toggle)
- [ ] Debug overlay toggle (S2 button)
- [ ] Sleep mode (HDMI blank when CPU stopped)

**Optimization opportunities**:
- SDRAM burst mode for sequential line reads (if timing permits)
- Write coalescing (batch multiple pixels per SDRAM transaction)
- Prefetch multiple lines ahead during VBlank

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SDRAM bandwidth contention (FB read + write + Ensoniq) | Low | High | Only 4 ports, FB is sequential (open-row), Ensoniq is sparse; no VRAM reads compete |
| Line fetch doesn't complete within 2-scanline window | Low | Medium | 640 sequential reads with open-row ≈ ~24µs, window is ~127µs (5x margin) |
| FB_WRITE port busy when renderer outputs pixel | Medium | Medium | Buffer 1-2 pixels; stall renderer if FB_WRITE port busy |
| Ensoniq + framebuffer concurrent access causes audio glitches | Low | Medium | Ensoniq ports are lowest priority; audio has buffering tolerance for occasional stalls |
| FPGA resource utilization too high | Low | Medium | Tang Nano 20K GW2A has 20K LUTs; current design uses ~60%; SDRAM controller adds ~1K LUTs |

## Files Summary

### New files
- `boards/a2n20v2-GS/hdl/video/sdram_framebuffer.sv` — Core framebuffer module (write path, read FSM, line buffer, output)
- `boards/a2n20v2-GS/hdl/video/scan_timer.sv` — Copy from a2mega
- `boards/a2n20v2-GS/hdl/video/apple_video_fb.sv` — Copy from a2mega
- `boards/a2n20v2-GS/hdl/video/vgc_fb.sv` — Copy from a2mega

### Modified files
- `boards/a2n20v2-GS/hdl/top.sv` — Add SDRAM ports, sdram_ports controller, mem_port_if array (4 ports), swap apple_video/vgc for _fb versions, add sdram_framebuffer (apple_memory stays unchanged)
- `boards/a2n20v2-GS/a2n20v2_gs.gprj` — Add source files
- `boards/a2n20v2-GS/hdl/a2n20v2_gs.sdc` — Timing constraints for CDC paths

### Reused shared files (already in repo)
- `hdl/sdram/sdram.sv` — SDRAM controller FSM
- `hdl/sdram/sdram_ports.sv` — Multi-port arbitration wrapper
- `hdl/memory/mem_port_if.sv` — Port interface definition
