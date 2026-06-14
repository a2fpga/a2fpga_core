# DDR3 Framebuffer 480p — Design Document

## Overview

`ddr3_framebuffer_480p.v` is a DDR3-backed framebuffer for the Tang Mega 60K
(A2Mega variant) that displays Apple II video at 480p (720x480 @ 59.94 Hz)
over HDMI. Unlike the 720p reference design (`ddr3_framebuffer.v`) which
performs arbitrary upscaling, this module uses **integer 2x vertical scaling**
with no horizontal scaling, producing clean pixel-perfect output.

The Apple II framebuffer (560x192 or 640x200) is stored in DDR3 SDRAM. Pixels
are written by the Apple II logic domain, stored via an async FIFO and batch
writer, then read back one scanline at a time into a line buffer BRAM for
display on the HDMI output.

### Key Design Differences from 720p Reference

| Aspect | 720p (`ddr3_framebuffer.v`) | 480p (`ddr3_framebuffer_480p.v`) |
|--------|---------------------------|----------------------------------|
| Output resolution | 1280x720p @ 60 Hz | 720x480p @ 59.94 Hz |
| HDMI pixel clock | Internal PLL (74.25 MHz = `clk_x1`) | External board PLL (27 MHz `clk_pixel`) |
| Clock domains | `clk_x1` used for both DDR3 and HDMI | Separate: `clk_x1` (DDR3), `clk_pixel` (HDMI) |
| Scaling | Fractional upscaling via accumulators | Integer 2x vertical, 1:1 horizontal, borders |
| Read buffer | 64-pixel prefetch register in `clk_x1` | 1024-entry line buffer BRAM, true dual-port |
| Scanline effects | None | Odd-line dimming (50% brightness) |

The critical architectural consequence is that the 720p version has **one clock
domain** for both DDR3 reads and HDMI output (both use `clk_x1` at 74.25 MHz),
so no CDC is needed for pixel data. The 480p version has **separate clock
domains** (`clk_x1` for DDR3, `clk_pixel` for HDMI), requiring a true
dual-port BRAM to bridge them.

---

## Clock Domains

```
   Board Crystal (50 MHz)
         |
    [clk_pll] (board PLL)
    /    |    \
  27 MHz  135 MHz  54 MHz
clk_pixel clk_pixel_x5  clk (logic)
  (HDMI)   (TMDS 5x)   (Apple II FB writes)
         |
    [pll_ddr3] (DDR3 PLL, input: clk_27 = 27 MHz)
         |
      297 MHz
    memory_clk
         |
  [DDR3 Controller]
         |
     74.25 MHz
      clk_x1
  (DDR3 app interface)
```

| Clock | Frequency | Domain | Purpose |
|-------|-----------|--------|---------|
| `clk_pixel` | 27 MHz | HDMI output | Pixel generation, HDMI encoder, line buffer reads |
| `clk_pixel_x5` | 135 MHz | TMDS | HDMI serialization (5x pixel clock) |
| `clk` | 54 MHz | Apple II logic | Framebuffer writes (`fb_we`, `fb_data`) |
| `clk_x1` | 74.25 MHz | DDR3 app | DDR3 read/write commands, line buffer fills |
| `memory_clk` | 297 MHz | DDR3 PHY | Internal to DDR3 controller |
| `clk_g` | 50 MHz | Reference | PLL configuration, DDR3 controller reference |

### Clock Relationships

- `clk_pixel` (27 MHz) and `clk_x1` (74.25 MHz) are **asynchronous** — derived
  from different PLLs. All signals crossing between them require proper CDC.
- `clk_x1 / clk_pixel` = 74.25 / 27 = 2.75x — `clk_x1` is 2.75x faster
  than the pixel clock. This means for every pixel displayed, the DDR3 domain
  has ~2.75 cycles to work with.
- `clk` (54 MHz) is asynchronous to all others — the async FIFO handles the
  write-path CDC.

---

## Module Interface

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WIDTH` | 640 | Maximum framebuffer width (multiples of 4) |
| `HEIGHT` | 480 | Maximum framebuffer height |
| `COLOR_BITS` | 18 | Color depth: 12 (RGB444), 15 (RGB555), 18 (RGB666), or 24 (RGB888) |

### Port Groups

**Clock and Reset:**
| Port | Dir | Width | Clock Domain | Description |
|------|-----|-------|-------------|-------------|
| `clk_27` | in | 1 | — | 27 MHz input for DDR3 PLL |
| `clk_g` | in | 1 | — | 50 MHz crystal for PLL reference |
| `pll_lock_27` | in | 1 | — | Lock indicator for clk_27 source PLL |
| `rst_n` | in | 1 | — | Active-low reset |
| `clk_out` | out | 1 | — | 74.25 MHz DDR3 domain clock output (`clk_x1`) |
| `ddr_rst` | out | 1 | `clk_x1` | Reset signal synchronized to DDR3 domain |
| `init_calib_complete` | out | 1 | `clk_x1` | DDR3 calibration complete |
| `clk_pixel` | in | 1 | — | 27 MHz HDMI pixel clock (from board PLL) |
| `clk_pixel_x5` | in | 1 | — | 135 MHz TMDS serialization clock |

**Framebuffer Write Interface:**
| Port | Dir | Width | Clock Domain | Description |
|------|-----|-------|-------------|-------------|
| `clk` | in | 1 | — | Write-side clock (54 MHz logic clock) |
| `fb_width` | in | 11 | `clk` | Active framebuffer width (560 or 640) |
| `fb_height` | in | 10 | `clk` | Active framebuffer height (192 or 200) |
| `fb_vsync` | in | 1 | `clk` | Start of frame (rising edge triggers new frame) |
| `fb_we` | in | 1 | `clk` | Pixel write enable (streaming, left-to-right, top-to-bottom) |
| `fb_data` | in | COLOR_BITS | `clk` | Pixel data to write |
| `border_color` | in | COLOR_BITS | `clk` | Border fill color (quasi-static, CDC'd internally) |
| `sleep_i` | in | 1 | `clk` | When high, output black screen |

**Audio:**
| Port | Dir | Width | Clock Domain | Description |
|------|-----|-------|-------------|-------------|
| `sound_left` | in | 16 | `clk` | Left audio sample (CDC'd to `clk_pixel`) |
| `sound_right` | in | 16 | `clk` | Right audio sample (CDC'd to `clk_pixel`) |

**HDMI Overlay Interface:**
| Port | Dir | Width | Clock Domain | Description |
|------|-----|-------|-------------|-------------|
| `hdmi_cx` | out | 11 | `clk_pixel` | Current horizontal pixel counter |
| `hdmi_cy` | out | 10 | `clk_pixel` | Current vertical line counter |
| `fb_rgb_o` | out | 24 | `clk_pixel` | RGB888 framebuffer output (before overlay mux) |
| `overlay_rgb_i` | in | 24 | `clk_pixel` | Overlay RGB input (debug overlay) |
| `overlay_en_i` | in | 1 | `clk_pixel` | Overlay enable (muxes overlay over framebuffer) |

**DDR3 Physical Interface:**
Standard DDR3 signals (addr, bank, cs, ras, cas, we, ck, cke, odt, reset, dm,
dq, dqs) directly connected to the Gowin DDR3 Memory Interface IP.

**HDMI Physical Output:**
| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `tmds_clk_p/n` | out | 1 | TMDS clock differential pair |
| `tmds_d_p/n` | out | 3 | TMDS data differential pairs (R, G, B) |

---

## 480p HDMI Timing

Video ID Code 2 (CEA-861): 720x480p @ 59.94 Hz

### Horizontal (per scanline)

| Region | cx range | Pixels | Duration @ 27 MHz |
|--------|----------|--------|-------------------|
| **Visible** | 0–719 | 720 | 26.67 us |
| Front porch | 720–735 | 16 | 0.59 us |
| Hsync pulse | 736–797 | 62 | 2.30 us |
| Back porch | 798–857 | 60 | 2.22 us |
| **Total** | 0–857 | **858** | **31.78 us** |

### Vertical (per frame)

| Region | cy range | Lines | Duration |
|--------|----------|-------|----------|
| **Visible** | 0–479 | 480 | 15.25 ms |
| Front porch | 480–488 | 9 | 0.29 ms |
| Vsync pulse | 489–494 | 6 | 0.19 ms |
| Back porch | 495–524 | 30 | 0.95 ms |
| **Total** | 0–524 | **525** | **16.68 ms** |

### Counter Behavior (from `hdmi.sv`)

- `cx` increments every `clk_pixel` rising edge. Wraps: 857 → 0.
- `cy` increments when `cx` wraps (i.e., at the transition from cx=857 to
  cx=0). Wraps: 524 → 0.
- Visible area: `cx < 720 && cy < 480` (registered one cycle delayed in HDMI
  module).
- `cy=0` is the **first visible line** (assuming `START_Y=0`).

---

## Display Layout (Active Area Within 720x480)

For Apple II mode (560x192):
```
              720 pixels
  |<--80-->|<---560--->|<--80-->|
  |  h_bdr |  active   | h_bdr |  cy=0..47   (v_border = 48 lines)
  |--------|-----------|--------|
  |  h_bdr |  FB line 0| h_bdr |  cy=48,49   (2 HDMI lines per FB line)
  |  h_bdr |  FB line 0| h_bdr |
  |  h_bdr |  FB line 1| h_bdr |  cy=50,51
  |  h_bdr |  FB line 1| h_bdr |
  |  ...   |    ...    |  ...  |
  |  h_bdr | FB line191| h_bdr |  cy=430,431
  |  h_bdr | FB line191| h_bdr |
  |--------|-----------|--------|
  |  h_bdr |  active   | h_bdr |  cy=432..479 (v_border = 48 lines)
```

### Border Calculations

```
h_border = (720 - fb_width) / 2     = (720 - 560) / 2 = 80
v_border = (480 - fb_height*2) / 2  = (480 - 384) / 2 = 48

h_active_start = h_border            = 80
h_active_end   = 720 - h_border      = 640
v_active_start = v_border             = 48
v_active_end   = 480 - v_border       = 432

FB line number = (cy - v_active_start) / 2  (integer division)
```

For VGC/SHR mode (640x200):
```
h_border = (720 - 640) / 2 = 40
v_border = (480 - 400) / 2 = 40
```

---

## Data Flow: Write Path

```
Apple II Logic (clk, 54 MHz)
    |
    | fb_we + fb_data (streaming pixels, L→R, T→B)
    v
[4-Pixel Grouper] ── wgrp_cnt (0,1,2,3) ── wgrp_data (4*COLOR_BITS)
    |
    | fifo_write (when 4 pixels assembled)
    v
[Async FIFO] ── 64 entries × 4*COLOR_BITS ── gray-code pointer CDC
    |
    | fifo_read (clk_x1 domain)
    v
[Batch Write Controller] (clk_x1, 74.25 MHz)
    |
    | Batches of 8 groups (32 pixels) when fifo_level >= 8
    | mem_dir_write flag blocks reads during write batches
    v
[DDR3 Controller]
    |
    | app_cmd=WRITE, 128-bit bursts (4 pixels × 32-bit words)
    v
DDR3 SDRAM
```

### Write Path Details

1. **Pixel Grouping** (`clk` domain): Incoming pixels are accumulated 4 at a
   time into `wgrp_data`. Each pixel occupies `COLOR_BITS` within a
   `4*COLOR_BITS` word. When 4 pixels are ready, `wgrp_pending` is set.

2. **Async FIFO**: 64-entry deep, `4*COLOR_BITS` wide. Uses gray-code pointer
   synchronization for safe CDC between `clk` (54 MHz) and `clk_x1`
   (74.25 MHz). The `read_available` output gives the fill level in `clk_x1`
   domain.

3. **Batch Write Controller** (`clk_x1`): Waits for 8+ groups in FIFO, then
   issues 8 consecutive DDR3 writes (32 pixels). This batching amortizes DDR3
   command overhead. The `mem_dir_write` flag is set during write batches to
   prevent read/write conflicts on the DDR3 bus.

4. **Frame Reset**: On `fb_vsync` rising edge (detected via toggle CDC to
   `clk_x1`), the FIFO is drained of stale data and write coordinates
   (`wr_x`, `wr_y`) reset to (0,0).

5. **DDR3 Address Layout**: Each pixel occupies 32 bits in DDR3 regardless of
   `COLOR_BITS` (zero-padded). Address = `{row * WIDTH + col, 1'b0}` where
   the `1'b0` is the byte-address LSB (16-bit DDR3 data bus, so addresses are
   in units of 16-bit words; each 128-bit burst = 8 × 16-bit words = 4
   pixels).

---

## Data Flow: Read Path

```
                    clk_pixel (27 MHz)              clk_x1 (74.25 MHz)
                    ─────────────────               ──────────────────
                          |                               |
                    [HDMI module]                    [cy CDC: gray-code]
                      cx, cy                         cy_sync1 (10-bit)
                          |                               |
                    [Border calc]                   [Border calc (x1)]
                    in_active area?                  fb_line_x1 = (cy-vstart)/2
                          |                               |
                    [lb_rd_addr]                    [Line Fetch Trigger]
                    = next_cx - h_start              fb_line changed?
                          |                               |
  lb_rd_data ←── [Line Buffer BRAM] ──← lb_wr_en   [DDR3 Read Commands]
  (read port)     true dual-port        lb_wr_addr   app_cmd=READ
                  1024 × COLOR_BITS     lb_wr_data        |
                          |                          [DDR3 Responses]
                    [torgb → RGB888]                 app_rd_data_valid
                          |                          128-bit → 4 pixels
                    [Scanline Dimming]                     |
                    cy[0] → 50% on odd              [4-cycle pixel writeback]
                          |                          rd_pixel_idx (0,1,2,3)
                    [Sleep / Reset Mux]
                          |
                       rgb output
                          |
                    [HDMI Encoder]
                    (with overlay mux)
                          |
                    TMDS output
```

### Read Path Details

#### 1. cy Clock Domain Crossing

The `cy` counter is in `clk_pixel` (27 MHz) and must be safely brought to
`clk_x1` (74.25 MHz) to determine which FB line to fetch.

**Why gray code:** Binary multi-bit CDC via double-flop is unsafe. When
multiple bits change simultaneously (e.g., 47→48 = 0b0101111→0b0110000, 5 bits
change), the synchronizer can capture any combination of old/new bits for one
cycle, producing a glitched intermediate value. Gray code guarantees only 1 bit
changes per increment, making double-flop synchronization safe.

```
clk_pixel:  cy → gray encode → cy_gray
                                   |
clk_x1:                    cy_gray_sync0 → cy_gray_sync1
                                              |
                                     gray→binary decode
                                              |
                                          cy_sync1 (safe 10-bit value)
```

**Latency:** 2 `clk_x1` cycles for the double-flop, plus 1 `clk_pixel` cycle
for the gray encode register = ~2-3 `clk_x1` cycles total (~27-40 ns). This
means `cy_sync1` lags the real `cy` by a few cycles, but this is acceptable
because the lag is much smaller than a scanline period.

#### 2. Line Buffer (True Dual-Port BRAM)

```verilog
reg [COLOR_BITS-1:0] line_buf [0:1023];  // synthesis → SDPB BRAM

// Write port (clk_x1)
always @(posedge clk_x1)
    if (lb_wr_en)
        line_buf[lb_wr_addr] <= lb_wr_data;

// Read port (clk_pixel)
always @(posedge clk_pixel)
    lb_rd_data <= line_buf[lb_rd_addr];
```

True dual-port BRAM on Gowin FPGAs supports simultaneous read and write on
different clocks natively. The Gowin synthesis tool infers an SDPB (Simple
Dual-Port Block RAM) primitive from this pattern. No additional CDC logic is
needed for the data path — the BRAM handles it at the hardware level.

**Size:** 1024 entries × 18 bits = 18 Kbits (fits in a single Gowin BSRAM
block which provides 18 Kbits).

#### 3. Line Fetch Trigger Logic

The fetch logic runs in `clk_x1` and monitors `cy_sync1` to detect when the
display has moved to a new FB line:

```
cy_sync1 changes (detected via cy_prev comparison)
    |
    ├── cy near v_active_start (VBlank) AND line 0 not yet fetched
    |       → trigger fetch of line 0
    |
    └── cy in active area AND fb_line_x1 != last_fetched_line
            → trigger fetch of current FB line
```

**VBlank prefetch:** Line 0 is fetched 2 scanlines before the active area
begins (`cy_is_vblank_before_active`), ensuring it's ready before the first
visible scanline.

**Active area fetch:** When `fb_line_x1` (= `(cy_sync1 - v_active_start) >> 1`)
differs from `last_fetched_line`, a new fetch is triggered. With 2x vertical
scaling, each FB line is displayed for 2 HDMI scanlines, so the fetch triggers
on the first scanline of each pair.

#### 4. DDR3 Read Sequence

Once `line_fetch_active` is set:

```
[ddr3_rw block]                    [response handler block]
     |                                      |
  fetch_pixel_x = 0                         |
     |                                      |
  Issue READ cmd ──────────────────→  DDR3 controller
  addr = fetch_pixel_x + line_addr         |
  fetch_pixel_x += 4                       |
  rd_pending = 1                           |
     |                              app_rd_data_valid
     | (wait for rd_done)                  |
     |                              Latch 128-bit response
     |                              Write pixel 0 → line_buf[fetch_write_x]
     |                              Write pixel 1 → line_buf[fetch_write_x+1]
     |                              Write pixel 2 → line_buf[fetch_write_x+2]
     |                              Write pixel 3 → line_buf[fetch_write_x+3]
     |                              fetch_write_x += 4
     | ←── rd_done pulse ──────────  rd_pixel_idx reaches 3
  rd_pending = 0                           |
     |                                      |
  (repeat until fetch_pixel_x >= fb_width)  |
     |                                      |
  fetch_pixel_x done                 fetch_write_x >= fb_width
     |                              line_fetch_active = 0
```

**Key constraint:** `rd_pending` ensures only one DDR3 read is in flight at a
time. This prevents response overlap that previously caused a "barcode pattern"
artifact. The DDR3 controller returns responses in order, with ~15-20 cycle
latency.

**Timing budget:** For 560-pixel width: 140 reads × ~20 cycles each = ~2800
`clk_x1` cycles = ~37.7 us. A scanline is 858 × (74.25/27) = ~2360 `clk_x1`
cycles = ~31.8 us. **This is tight!** The one-at-a-time `rd_pending` approach
means the fetch may take slightly longer than one scanline. However, since each
FB line displays for 2 scanlines, we have ~63.6 us total, which is comfortably
sufficient.

**Important: The one-at-a-time read constraint is a bottleneck.** Future
optimization could pipeline reads (issue next read while previous response is
being processed) to reduce total fetch time to ~20 us. This would require a
small response FIFO or careful tracking of in-flight reads.

#### 5. Display Output

The output path runs entirely in `clk_pixel` (27 MHz):

1. **Read address generation:** `lb_rd_addr = next_cx - h_active_start_px`,
   set one cycle early to account for BRAM read latency.

2. **Pixel selection:** `in_active ? lb_rd_data : border_color_px`

3. **Color conversion:** `torgb()` function expands `COLOR_BITS` to RGB888:
   - 18-bit (RGB666): `{R[5:0],2'b0, G[5:0],2'b0, B[5:0],2'b0}`

4. **Scanline dimming:** Odd HDMI lines (`cy[0]==1`) are displayed at 50%
   brightness via right-shift: `{1'b0, R[7:1], 1'b0, G[7:1], 1'b0, B[7:1]}`.
   This produces a CRT-like scanline effect.

5. **Sleep/reset:** Black screen when `sleep_sync1` or `ddr_rst` is active.

6. **Overlay mux:** In the HDMI encoder instantiation, `overlay_en_i` selects
   between the framebuffer `rgb` and the debug overlay `overlay_rgb_i`. The
   debug overlay (DebugOverlay module) provides status information.

---

## CDC Summary

| Signal | From → To | Method | Notes |
|--------|-----------|--------|-------|
| `cy` (10-bit) | `clk_pixel` → `clk_x1` | Gray-code + 2-stage flop | Safe for monotonic counter |
| `fb_vsync` (toggle) | `clk` → `clk_x1` | Toggle + 2-stage flop | Edge detection via XOR |
| `fb_width`, `fb_height` | `clk` → `clk_x1` | Quasi-static (single flop) | Changes only on mode switch |
| `border_color` | `clk` → `clk_pixel` | 2-stage flop | Quasi-static |
| `sleep_i` | `clk` → `clk_pixel` | 2-stage flop | Quasi-static |
| `sound_left/right` | `clk` → `clk_pixel` | 2-stage flop | Audio samples |
| **Line buffer data** | `clk_x1` → `clk_pixel` | **True dual-port BRAM** | Hardware-level CDC |

### Line Buffer: Why No Ping-Pong

**Previous approach (ping-pong, eliminated):** Two BRAM banks alternated: one
being filled while the other was read. A `lb_fill_sel` signal toggled on fill
completion and was CDC'd to the read side as `lb_read_sel`. This caused
multiple problems:

1. **Mid-scanline bank switching:** `lb_fill_sel` toggled when the fill
   completed (mid-scanline in `clk_x1`). The CDC propagated this to
   `clk_pixel` mid-scanline, causing the read side to switch banks partway
   through a line → visible horizontal ripple.

2. **Latching attempts failed:** Latching `lb_read_sel` at `cx==0` eliminated
   the mid-scanline switching but introduced bank-alignment problems. With 2x
   vertical scaling, the toggle from filling line N+1 caused the second
   scanline of line N's display pair to read from the wrong bank.

3. **Fundamental incompatibility:** A 2-bank ping-pong with 2x vertical
   scaling requires the display to read the same bank for 2 consecutive
   scanlines, but each fill toggles the bank. The timing of when the toggle
   occurs, when the CDC propagates, and when the read side samples it creates
   unavoidable race conditions across the asynchronous clock boundary.

**Current approach (single buffer, true dual-port BRAM):** A single 1024-entry
BRAM with write port on `clk_x1` and read port on `clk_pixel`. The FPGA's
BRAM primitive handles the cross-clock access at the hardware level. No bank
selection signal needs to cross clock domains.

**Write/read overlap safety:** The fetch of a new FB line writes to addresses
0..559 (or 0..639) while the display reads from those same addresses. However:

- Each FB line is displayed for 2 HDMI scanlines (~63.6 us at 27 MHz).
- The fetch takes ~37.7 us (one-at-a-time reads) or potentially less with
  optimization.
- The fetch triggers when `fb_line_x1` changes, which is at the start of the
  first HDMI scanline of a new pair.
- During the fetch period, the display is reading old data that is being
  overwritten. For the brief overlap window, BRAM reads may return either old
  or new data depending on exact timing. Since the new data is what we want
  displayed (it IS the current line), either outcome is visually acceptable.
- By the second HDMI scanline of the pair, the fetch is complete and the
  buffer contains the correct data for the entire scanline.

**Remaining concern:** The first few pixels of the first HDMI scanline of each
pair may show stale data from the previous line, since the fetch and display
start at roughly the same time (both triggered by the cy transition). In
practice, the cy CDC latency means the fetch starts 2-3 `clk_x1` cycles after
the real cy transition, by which time the display has only advanced a few
pixels into the visible area. If this is visible, the fix would be to trigger
the fetch earlier (e.g., during the second scanline of the PREVIOUS pair) to
ensure data is ready before the new pair begins.

---

## DDR3 Read/Write Arbitration

Both read and write operations share the single DDR3 controller port. The
arbitration logic in the `ddr3_rw` always block handles this:

```
Priority: Writes > Reads

if (write pending) {
    Issue write command + data
    Wait for completion
} else if (fetch_needs_reset) {
    Reset fetch_pixel_x to 0 for new line
} else if (line fetch active && not all pixels read && !rd_pending) {
    Issue read command
    Set rd_pending
}
```

**`mem_dir_write` flag:** Set during write batches to prevent the read path
from issuing commands. Cleared when the batch completes. This ensures writes
get uninterrupted DDR3 access during their batch window.

**`rd_pending` flag:** Owned by the `ddr3_rw` block. Set when a read command
is issued, cleared by the `rd_done` pulse from the response handler. Ensures
only one read is in flight at a time.

**Two-block architecture:** The response handler and the DDR3 command issuer
are in separate always blocks (Verilog requires each `reg` to be assigned in
exactly one always block). Communication is via:
- `rd_done` wire (response handler → command issuer): pulse to clear
  `rd_pending`
- `line_fetch_active` (response handler → command issuer): indicates a fetch
  is in progress
- `fetch_line_addr` (response handler → command issuer): base address for
  current line's reads

---

## Current Status and Future Work

### Current Status: Stable With BRAM Contention Fix

The remaining "moving distortion" issue (especially visible during VGC
animation or other active video-memory writes) was traced to contention in
`apple_memory.sv`, not the DDR3 line-buffer path itself.

`sdpram32` instances in `apple_memory.sv` infer Gowin SDPB block RAM. With
continuous read-enable and simultaneous writes, read/write overlap can produce
undefined/unstable pixels. The fix was:

1. Drive BRAM read-enable from real scan fetch strobes:
   - `video_read_active = video_rd_i && !vgc_active_i`
   - `vgc_read_active = vgc_rd_i && vgc_active_i`
2. Route each VRAM bank's `read_enable` from those strobes instead of `1'b1`.
3. Add deferred VRAM write strobe logic (`write_strobe_vram`) so shadow-memory
   writes are delayed while either active video read strobe is asserted.

This removes deterministic read/write overlap windows that previously caused
visible corruption.

### Remaining Improvement Opportunities

1. **Pipelined DDR3 reads:** Issue the next read while the prior response is
   being unpacked into the line buffer. This would increase timing margin for
   wide active regions.
2. **Fetch lead optimization:** Start line fetch slightly earlier in HBlank to
   maximize fill completion margin before active pixels.
3. **Timing margin cleanup:** Current `clk_logic` timing passes but with modest
   headroom in this configuration; further path cleanup is advisable.

### Lessons Learned

1. **True dual-port BRAM is still the right CDC primitive for line-buffer
   crossing** (`clk_x1` write, `clk_pixel` read).
2. **Inferred SDPB read-enable must be explicit.** Leaving read-enable tied on
   can expose read/write collision behavior when upstream writers are active.
3. **Sparse writes are not a guarantee.** Even low-rate Apple bus writes can
   coincide with scan reads unless arbitration/strobing is explicit.
4. **Gray-code CDC for raster counters remains essential** for clean
   cross-domain line tracking.

---

## File Structure Summary

| Line Range | Section |
|-----------|---------|
| 1–23 | Module header and documentation |
| 24–83 | Module port declarations |
| 87–150 | Clock generation (DDR3 PLL, mDRP) |
| 155–220 | DDR3 controller instantiation |
| 222–249 | Audio clock generation and CDC |
| 251–266 | Border color and sleep CDC |
| 268–313 | HDMI TX instantiation (480p, VIDEO_ID=2) |
| 315–461 | Write path (pixel grouping, async FIFO, batch writer) |
| 463–497 | Line buffer (true dual-port BRAM) |
| 499–577 | Read path: cy CDC, border calc, fetch trigger wires |
| 578–663 | Read path: line fetch FSM and DDR3 response handler |
| 665–727 | DDR3 read/write arbitration |
| 729–779 | 480p output path (borders, dimming, sleep, RGB) |
| 781–793 | `torgb()` color conversion function |
| 795–978 | Utility modules (`async_fifo`, `crossdomain`) |
