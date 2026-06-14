# A2FPGA DDR3 Framebuffer Refactor — Implementation Workplan

## Project Summary

Refactor the A2FPGA (A2Mega variant) HDMI video output pipeline to use a DDR3-backed framebuffer for display. The key architectural change moves video scanners from the HDMI pixel clock domain to the Apple II native timing domain (`a2bus_if.clk_logic`, 54 MHz), outputting pixels via the `fb_*` framebuffer interface. This eliminates beam racing synchronization problems — the scanner sees VRAM writes at the correct beam-relative position because it runs on Apple II timing.

**Development repo:** https://github.com/edanuff/a2fpga_core (fork, `ddr3_framebuffer` branch)
**ddr3_framebuffer reference:** https://github.com/nand2mario/ddr3_framebuffer_gowin
**Target hardware:** Tang Mega 60K — Gowin **GW5AT-60B** (`GW5AT-LV60PG484AC1/I0`)

---

## Current Status: 480p Framebuffer Conversion (In Progress)

### What's Done (Merged to `ddr3_framebuffer` branch)

Phases 0–4 are **complete and merged**. The DDR3 framebuffer pipeline is working at 720p:

- `ddr3_framebuffer.v` integrated and outputting 720p HDMI
- `apple_video_fb.sv` renders Apple II modes at native timing into framebuffer
- `vgc_fb.sv` renders IIgs SHR modes into framebuffer
- `scan_timer.sv` provides authoritative Apple II scanline timing via `extended_cycle`
- Burst-on-HBlank rendering architecture working (burst during long PHI0)
- SuperSprite compositing on Apple II path, DebugOverlay on both paths
- F18A (SuperSprite VDP) integrated with framebuffer path
- `top.sv` fully refactored for framebuffer pipeline
- Beam racing confirmed working — rendering happens at correct scanline positions

### The Problem: 720p Scaling Looks Worse Than 480p

After completing the 720p framebuffer implementation, we discovered that the visual quality was **worse** than the original pre-framebuffer 480p direct-render implementation. The reasons:

1. **720p is poorly suited for Apple II pixel geometry.** The native Apple II resolution (560×192 or 640×200) doesn't scale cleanly to 720p (1280×720). The Bresenham nearest-neighbor upscaling produces uneven pixel sizes — some pixels are 2 wide, others 3 wide — giving an inconsistent, ugly appearance.

2. **The added resolution of 720p doesn't help.** 720p doesn't have enough pixels to produce good-looking scaling of Apple II resolutions. You'd need 1080p or higher for clean integer-multiple or interpolated scaling, and it's unclear whether this FPGA can drive 1080p (worth exploring separately).

3. **Lost visual features.** The 720p implementation lost the border areas (left/right/top/bottom) and the scanline effect (CRT-style line dimming) that the original 480p output had.

### The Solution: 480p Framebuffer

Keep the framebuffer architecture (which solves beam racing) but output at 480p instead of 720p. This gives us:

- **Beam racing correctness** from the framebuffer (the whole point of the refactor)
- **Clean pixel appearance** — 480p allows simple 2× vertical scaling with integer pixel sizes
- **Borders restored** — centered display area with border color fill
- **Scanline effect** — every other HDMI line rendered at 50% intensity (right-shift RGB by 1). Since we're 2× vertical scaling, each framebuffer line maps to 2 HDMI lines: one full brightness, one half brightness.

### What Was Being Worked On (Lost in Session Crash)

The `mystifying-bohr` Claude Code session was creating `ddr3_framebuffer_480p.v` and wiring it into `top.sv`. This was in testing when the session was lost. The work involved:

1. Creating `ddr3_framebuffer_480p.v` — a 480p variant of the framebuffer module
2. Modifying `top.sv` to use the 480p module instead of the 720p one
3. Updating PLLs for 480p timing (27 MHz pixel clock, 135 MHz TMDS)
4. Updating timing constraints (`a2mega.sdc`)
5. Updating F18A modules for 480p timing
6. Testing and debugging — was making progress when work was lost

---

## Architecture: 480p Framebuffer

### 480p vs 720p Key Differences

| Aspect | 720p (completed, merged) | 480p (in progress) |
|--------|-----------|------------|
| Resolution | 1280×720 | 720×480 |
| Pixel clock | 74.25 MHz (internal PLL) | 27 MHz (board PLL) |
| TMDS clock | 371.25 MHz (internal PLL) | 135 MHz (board PLL) |
| VIDEO_ID_CODE | 4 | 2 |
| Scaling | Bresenham nearest-neighbor | 2× vertical, centered horizontal |
| Pixel quality | Uneven pixel sizes | Clean integer scaling |
| Borders | Lost | Restored (centered in 720×480) |
| Scanline effect | Not implemented | Odd lines at 50% brightness |
| PLLs needed | pll_ddr3 + pll_hdmi (2 internal) | pll_ddr3 only (1 internal) |
| Pixel clocks | Generated internally | Provided by board PLL |

### 480p Timings

```
Horizontal: 858 total = 720 active + 16 front porch + 62 sync + 60 back porch
Vertical:   525 total = 480 active + 9 front porch + 6 sync + 30 back porch
```

### Display Layout (Apple II mode: 560×192)

```
720 pixels wide:
  [80 border] [560 active] [80 border]

480 lines tall (with 2× vertical scaling, 192 FB lines → 384 HDMI lines):
  [48 border] [384 active (192 lines × 2)] [48 border]

Within active area, alternating lines:
  Line N:   full brightness (FB line N/2)
  Line N+1: half brightness (FB line N/2, RGB >> 1)
```

### Display Layout (VGC/SHR mode: 640×200)

```
720 pixels wide:
  [40 border] [640 active] [40 border]

480 lines tall (with 2× vertical scaling, 200 FB lines → 400 HDMI lines):
  [40 border] [400 active (200 lines × 2)] [40 border]
```

### Clock Architecture (480p)

The 480p approach simplifies clock management significantly:

- **Board PLL** provides: `clk_pixel` (27 MHz), `clk_pixel_x5` (135 MHz), `clk_logic` (54 MHz)
- **`pll_ddr3`** (inside framebuffer): 27 MHz → ~297 MHz DDR3 memory clock
- **No `pll_hdmi` needed** — board PLL directly provides pixel and TMDS clocks

Total: **2 PLLs** (board + pll_ddr3), down from 3 in the 720p approach.

The `ddr3_framebuffer_480p` module receives `clk_pixel` and `clk_pixel_x5` as inputs rather than generating them internally.

### Line Buffer Architecture (New for 480p)

Instead of the 720p version's Bresenham prefetch buffer, the 480p version uses a **ping-pong line buffer**:

- Single SDPB BRAM with 2 banks (power-of-2 bank size ≥ WIDTH, so 1024 entries per bank)
- Write port: `clk_x1` (74.25 MHz DDR3 domain) fills one bank with a scanline from DDR3
- Read port: `clk_pixel` (27 MHz) reads from the opposite bank for HDMI output
- `lb_fill_sel` toggled at line boundaries, CDC'd to read domain via double-flop
- Each FB line fetched once from DDR3, displayed on 2 consecutive HDMI lines (2× vertical)
- DDR3 reads fetch 4 pixels at a time (128-bit burst), written sequentially to line buffer

### Scanline Dimming

```verilog
// Odd HDMI lines at 50% brightness (right-shift each channel by 1)
wire dim = cy[0];
wire [23:0] pixel_rgb_dimmed = dim ?
    {1'b0, pixel_rgb_raw[23:17], 1'b0, pixel_rgb_raw[15:9], 1'b0, pixel_rgb_raw[7:1]} :
    pixel_rgb_raw;
```

This produces a CRT-like scanline effect — the second of each pair of duplicated lines is rendered at half intensity.

### HDMI Overlay Interface (New for 480p)

The 480p module exposes `hdmi_cx`/`hdmi_cy` (current HDMI coordinates) and accepts `overlay_rgb_i`/`overlay_en_i` so that DebugOverlay can composite in the pixel clock domain:

```verilog
// Inside HDMI instantiation
.rgb(overlay_en_i ? overlay_rgb_i : rgb),
```

---

## Remaining Work: 480p Conversion Tasks

### Task 1: Review and Fix `ddr3_framebuffer_480p.v`

The recovered file (33,992 chars, 71 edits applied, 6 failed) is the only file that differs from the branch. Priority items:

1. Identify the 6 failed edits from the JSONL transcript
2. Review `torgb` function signature — takes `input [23:0]` but called with `COLOR_BITS`-wide data
3. Review `fetch_line_addr` multiply (`fb_line_x1 * WIDTH`) — may need optimization
4. Verify `rd_pixel_idx` sequencing doesn't have race conditions with `rd_spacing_cnt`
5. Verify line buffer bank switching CDC is correct
6. Test DDR3 read arbitration with new line-buffer approach

### Task 2: Update PLL Configuration

- Modify board PLL (`pll_hdmi.v`) to output: `clk_pixel` (27 MHz), `clk_pixel_x5` (135 MHz), `clk_logic` (54 MHz)
- Verify `pll_ddr3.v` is correct for 480p (likely unchanged — still 27→297 MHz)
- Ensure no stale references to 720p HDMI PLL

**Recovered files:** `pll_ddr3.v` (clean write), `pll_hdmi.v` (clean write)

### Task 3: Update `top.sv`

- Replace `ddr3_framebuffer` instantiation with `ddr3_framebuffer_480p`
- Connect `clk_pixel`/`clk_pixel_x5` inputs (instead of letting FB generate them)
- Wire HDMI overlay interface for DebugOverlay
- Remove any 720p-specific logic (Bresenham parameters, disp_width, etc.)
- Update `fb_width`/`fb_height` signal routing

**Status:** NOT recovered from JSONL. Must be reconstructed from the merged 720p `top.sv` plus the recovered `ddr3_framebuffer_480p.v` interface.

### Task 4: Update Timing Constraints

- Update `a2mega.sdc` for 480p clock domains
- Add constraints for 27 MHz pixel clock, 135 MHz TMDS
- Update DDR3→pixel clock CDC paths

**Recovered:** `a2mega.sdc` (2,678 chars, 1 failed edit)

### Task 5: Update F18A for 480p

- Verify F18A framebuffer modules work with 480p timing
- Update counters if they assumed 720p frame size

**Recovered:** `f18a_counters_fb.vhd` (0 failed edits), `f18a_vga_cont_fb.vhd` (0 failed edits)

### Task 6: Update Project File

- Add `ddr3_framebuffer_480p.v` to `a2mega.gprj`
- Remove or disable 720p `ddr3_framebuffer.v` reference
- Add any new PLL files

**Status:** NOT recovered. Must be manually updated.

### Task 7: Testing

- Verify DDR3 calibration at 480p
- Check border rendering (correct size, border color)
- Check scanline effect (alternating brightness)
- Verify all video modes still render correctly
- Check beam racing demos
- Verify audio pass-through
- Compare visual quality with pre-framebuffer 480p output

---

## Recovery File Assessment

### Files to Use from Recovery

| File | Recovery Quality | Action |
|------|-----------------|--------|
| `ddr3_framebuffer_480p.v` | 6 failed edits — **only file that differed** | Review carefully, fix failed edits |
| `a2mega.sdc` | 1 failed edit | Compare with branch, apply changes |
| `pll_ddr3.v` | Clean write | Use directly |
| `pll_hdmi.v` | Clean write | Use directly |
| `config.vh` | Clean write (20 chars) | Use directly |
| `f18a_counters_fb.vhd` | 0 failed edits | Compare with branch, apply if different |
| `f18a_vga_cont_fb.vhd` | 0 failed edits | Compare with branch, apply if different |
| `debugoverlay.sv` | 0 failed edits | Compare with branch, apply if different |

### Recovered But Likely Unchanged from Branch

| File | Notes |
|------|-------|
| `apple_video_fb.sv` | 1 failed edit, but was working pre-480p — compare carefully |
| `vgc_fb.sv` | 8 failed edits — **low confidence**, compare with branch |

### Files That Must Be Reconstructed

| File | Approach |
|------|----------|
| `top.sv` | Start from merged 720p version on branch, apply 480p changes based on `ddr3_framebuffer_480p.v` interface |
| `a2mega.gprj` | Manually add new files to existing project file on branch |

---

## Future Consideration: 1080p Output

Worth exploring whether the GW5AT-60B can drive 1080p HDMI. This would provide enough resolution for clean scaling of Apple II resolutions. Key questions:

- Can the FPGA's TMDS serializers handle 1080p60 (148.5 MHz pixel, 742.5 MHz TMDS)?
- Does the DDR3 bandwidth support 1080p readback?
- Would a 1080p framebuffer fit in DDR3 with acceptable write latency?

This is a separate investigation track, not blocking the 480p work.

---

## Reference: Shared Architecture (Unchanged)

### Burst-on-HBlank Rendering

On each `extended_cycle` (long PHI0), `burst_x` counts 0 to `fb_width-1` at 54 MHz. Compositing chain produces one pixel per cycle directly to `fb_we`. Duration: 560px ≈ 10.4µs, 640px ≈ 11.9µs — well within HBlank.

### `scan_timer` Module

Single source of truth for Apple II timing. Uses `a2bus_if.extended_cycle`. Provides `scanline_o` (0-261), `hsync_o` (burst trigger), `vsync_o` (frame reset), `pixel_o` (free-running intra-line counter).

### Two Rendering Paths

- **Apple II path** (560 wide): `apple_video_fb → SuperSprite → DebugOverlay → fb_we`
- **VGC path** (640 wide): `vgc_fb → DebugOverlay → fb_we`

`SHRG_MODE` selects. SuperSprite only on Apple II path (historically accurate).

### BlockRAM Shadow VRAM

Unchanged. `apple_memory` module and `video_address_o`/`video_data_i` interfaces intact. DDR3 is only for display framebuffer.

### `fb_*` Write Protocol

1. `fb_vsync` pulse resets write position to (0,0)
2. `fb_we` + `fb_data` one cycle per pixel, left-to-right, top-to-bottom
3. Internal async FIFO handles CDC from `clk_logic` (54 MHz) to DDR3 domain
4. `fb_width` must be multiple of 4
5. Pixels accumulated 4 at a time, burst-written to DDR3 as 128-bit words

### Notes for Claude Code

- **A2FPGA SystemVerilog conventions**: interfaces (`a2bus_if.slave`, `a2mem_if.slave`, `video_control_if.display`)
- **Board-specific files in `boards/a2mega/hdl/`** — don't modify shared `hdl/video/` files
- **`clk_logic` is 54 MHz** with Apple II clock enable strobes
- **`extended_cycle`** is the fork's long PHI0 detection signal
- **Device:** GW5AT-LV60PG484AC1/I0
- **Build:** `cd boards/a2mega && printf 'open_project a2mega.gprj\nrun all\nexit\n' | gw_sh 2>&1`
- **Start from merged 720p code on `ddr3_framebuffer` branch** — the 480p conversion modifies existing working code, not starting from scratch
