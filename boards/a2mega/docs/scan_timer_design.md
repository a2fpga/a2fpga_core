# scan_timer Design Document

## Purpose

`scan_timer` generates scanline and pixel counters from Apple II bus timing,
used by `apple_video_fb` and `vgc_fb` to determine which scanline to render
to the DDR3 framebuffer. It converts the `extended_cycle` pulse (one per
horizontal scanline) into a 0-261 scanline counter.

## Problem: Vertical Counter Misalignment

### Mega II Counter Structure (TN #39)

The real Apple IIgs Mega II chip uses a 9-bit vertical counter that does **not**
start at zero. Per Apple IIgs Technical Note #39:

- NTSC mode: counter ranges from **$0FA through $1FF** (262 values)
- Counter value **$100** corresponds to **scan line 0** (first visible line)
- Counter value **$1BF** corresponds to scan line 191 (last visible line for
  standard modes)
- Counter value **$1C0** corresponds to scan line 192 (VBL begins)
- Counter values **$1C0-$1FF** and **$0FA-$0FF** are the 70 VBL lines

The counter layout:

```
$0FA (250) -- VBL (6 lines before visible)
$0FB (251)
$0FC (252)
$0FD (253)
$0FE (254)
$0FF (255)
---- MSB flips 0->1 ----
$100 (256) -- Scan line 0 (first visible)
$101 (257) -- Scan line 1
  ...
$1BF (447) -- Scan line 191 (last visible, standard modes)
$1C0 (448) -- Scan line 192 (VBL starts, $C019 triggers)
  ...
$1F9 (505) -- Last line before wrap
---- wraps to $0FA ----
```

### The Original Bug

Our `scan_timer` initialized `scanline_counter_r` to 0 on reset. Since
`extended_cycle` pulses are derived from the real Apple II's phi1 clock,
each pulse corresponds to a real hardware scanline. After reset, the Mega II
starts at $0FA (a VBL line), but we started at 0 (a visible line).

This meant we were **6 scanlines ahead** of the real hardware: our scanner
was reading VRAM for "line 0" while the Apple II was still in VBL. Games that
do raster chasing --- timing their draws relative to the beam position by
polling $C02E or $C019 --- would see tearing at the wrong scanline.

### The Fix

Initialize `scanline_counter_r` to 256 on reset. After 6 `extended_cycle`
pulses (256, 257, 258, 259, 260, 261 -> wrap to 0), our counter reaches 0
at the same moment the Mega II reaches $100 = scan line 0.

### MAME Cross-Reference

MAME's `get_vpos()` function in `apple2gs.cpp` confirms this mapping:

```c
int apple2gs_state::get_vpos()
{
    int vpos = m_screen->vpos();
    if (vpos < BORDER_TOP)
        vpos += m_screen->height();
    vpos += 256 - BORDER_TOP;
    if (vpos > 511)
        vpos -= m_screen->height();
    return vpos;
}
```

With `BORDER_TOP = 16` and `screen height = 262`, MAME vpos 16 maps to
Mega II counter 256 = $100 = scan line 0.

## Bus Data Sampling Fix (apple_bus.sv)

The a2mega's `apple_bus.sv` originally only sampled the data bus on CPU write
cycles (`if (!rw_n_r) data_r <= a2_d_i`). This meant that `a2bus_if.data`
contained stale data from the last write during read cycles --- the VGC/Mega II
response on the bus was never captured.

Fixed by removing the write-only guard: `data_r <= a2_d_i` now executes on
every bus cycle. On writes, we capture the CPU's data (same as before). On
reads, we capture the peripheral's response, enabling bus snooping of $C019
and $C02E.

The a2n20v2 board's `apple_bus.sv` has a different architecture (uses a bridge
IC) and already samples read data correctly.

## Bus-Snooped Resync

Even with the correct reset value, drift could occur if the FPGA reset
timing doesn't perfectly align with the Mega II's reset. Two optional resync
mechanisms snoop the bus to correct drift using ground-truth data from the
Mega II.

### VGC_VERTCNT_LOCK (parameter, default 1)

Snoops CPU reads of **$C02E** (VertCnt register). When the Mega II responds
to a CPU read, the actual counter value appears on the data bus. We capture
it and compare against our counter.

**$C02E format**: Contains {V5,V4,V3,V2,V1,V0,VC,VB} --- the top 8 bits
of the 9-bit counter. The 9th bit (VA) is in $C02F[7], which we don't snoop,
giving us 2-scanline precision.

**Conversion**:
- `nine_bit_approx = {vertcnt_byte, 1'b0}` (VA assumed 0)
- If `vertcnt_byte >= $80`: `expected_line = {0, vertcnt_byte[6:0], 1'b0}`
  (values $100-$1FF map to our 0-255)
- If `vertcnt_byte < $80`: `expected_line = {vertcnt_byte, 1'b0} + 6`
  (values $0FA-$0FF map to our 250-261)

**Timing**: Uses the same `read_strobe` pattern as the keyboard snoop in
`apple_memory.sv` (`rw_n && data_in_strobe`), gated by `!m2sel_n`.

**Note**: Not all games read $C02E. Testing with Arkanoid showed zero $C02E
reads but heavy $C019 polling.

### VGC_VBL_LOCK (parameter, default 1)

Snoops CPU reads of **$C019** (VBL status soft switch). Detects transitions
of the VBL bit to snap our counter to known boundaries.

**$C019 polarity on Apple IIgs** (per TN #40):
- Bit 7 = **1 (high)** ($80): VBL active (beam in blanking)
- Bit 7 = **0 (low)** ($00): VBL not active (beam in visible area)

Note: this is the **inverted sense** from the Apple IIe, where bit 7 low
indicates VBL. The Apple IIgs Hardware Reference originally documented this
incorrectly; TN #40 corrected it. MAME PR #14177 also confirmed this.

The VBL polarity is automatically selected at runtime using `a2bus_if.sw_gs`:
- `sw_gs = 1` (IIgs): bit 7 high = VBL active
- `sw_gs = 0` (IIe):  bit 7 low  = VBL active

This means the same bitstream works correctly on both IIgs and IIe computers
without recompilation.

**Transition detection**:
- Bit 7 goes 1->0 (VBL ending): snap to scan line 0
- Bit 7 goes 0->1 (VBL starting): snap to scan line 192

#### Tight-Poll Filter

A critical insight from hardware testing: games poll $C019 in two patterns:

1. **Tight poll loop** (e.g. `LDA $C019 / BPL loop`): consecutive reads
   every ~8 bus cycles (~7.8us at 1.023 MHz). Transitions detected during
   tight polling have ~1 scanline precision.

2. **Sparse single checks**: one read per game loop iteration, scattered
   across the frame. Transitions between sparse reads are imprecise ---
   the actual VBL boundary could be dozens of scanlines away from where
   we detect the bit change.

Without filtering, sparse-check transitions produce large, incorrect deltas
(observed: 39, 55, 81+ lines) that cause massive visible glitches when
applied as corrections.

The **tight-poll filter** only trusts transitions where two consecutive
$C019 reads are within `TIGHT_POLL_MAX` clk_logic cycles (default 600,
~11us at 54 MHz). This is generous enough for any reasonable polling loop
while rejecting sparse reads that are thousands of cycles apart.

A typical two-phase VBL wait routine (from game source code):

```asm
waitForVbl entry
vblLoop1 anop
        short m
        lda #$fe
        cmp >READ_VBL       ; tight poll: wait out current VBL
        bpl vblLoop1
vblLoop2 anop
        cmp >READ_VBL       ; tight poll: wait for VBL start
        bmi vblLoop2
        long m
        rtl
```

Both loops produce tight reads. The transition from loop1 to loop2
(VBL->active, scanline 0) and the exit of loop2 (active->VBL, scanline 192)
are both detected with high precision.

### RESYNC_THRESHOLD (parameter, default 2)

Both lock mechanisms only apply a correction when the absolute delta between
our counter and the snooped expected value exceeds this threshold. This
prevents frequent small corrections from the inherent +/-1 scanline jitter
in polling-based transition detection.

With threshold = 2:
- 0-2 line delta: tolerated (cosmetically invisible, normal polling jitter)
- 3+ line delta: corrected (genuine drift requiring one-time fix)

The `abs_delta` function computes distance on the 262-line ring, correctly
handling wrap-around (e.g. counter at 260 and expected at 1 = delta of 3).

### Observed Behavior

Hardware testing with Arkanoid (IIgs) showed:
- $C019 reads: constant (heavy VBL polling)
- $C02E reads: zero (game doesn't use VertCnt)
- After one VBL correction at startup, delta stabilizes at 0-1
- Our scanline at resync: alternates between C0/C1 (192-193) and 00/01 (0-1),
  confirming we're right at both VBL boundaries
- Raw $C019 byte: alternates 00/$80, confirming IIgs polarity is correct
- Correction count: goes to 1 and stays --- the free-running counter
  maintains sync after the initial nudge

## Debug Overlay

When enabled, the debug overlay displays scan_timer diagnostics:

| Hex Slot | Content |
|----------|---------|
| 0-1 | Last resync delta (9 bits) |
| 2-3 | Our scanline at resync moment (9 bits) |
| 4 | Last raw bus byte ($C019 or $C02E) |
| 5 | (reserved) |
| 6 | VBL correction count |
| 7 | VERTCNT correction count |

Expected healthy behavior: hex 6 goes to 00 or 01 shortly after boot and
stays there. Hex 7 stays at 00 unless the game reads $C02E. If either
counter climbs steadily, the resync logic needs investigation.

## Module Interface

```systemverilog
module scan_timer #(
    parameter VGC_VERTCNT_LOCK = 1,   // snoop $C02E reads for resync
    parameter VGC_VBL_LOCK = 1,       // snoop $C019 reads for resync
    parameter RESYNC_THRESHOLD = 2    // min delta to trigger correction
    // VBL polarity auto-detected at runtime via a2bus_if.sw_gs
) (
    a2bus_if.slave a2bus_if,
    output [8:0] scanline_o,    // 0-261
    output hsync_o,             // pulse per scanline
    output vsync_o,             // pulse at frame boundary (261->0)
    output [9:0] pixel_o,       // free-running pixel counter within scanline

    // Debug outputs for DebugOverlay
    output [8:0] dbg_last_delta_o,
    output [8:0] dbg_last_expected_o,
    output [8:0] dbg_last_actual_o,
    output [7:0] dbg_last_raw_data_o,
    output [7:0] dbg_vbl_correct_o,
    output [7:0] dbg_vertcnt_correct_o,
    output [7:0] dbg_c02e_count_o,
    output [7:0] dbg_c019_count_o
);
```

## References

- Apple IIgs Technical Note #39: Mega II Video Counters
- Apple IIgs Technical Note #40: VBL Signal
- Apple IIgs Technical Note #70: Mega II Video Counter Registers
- MAME `src/mame/apple/apple2gs.cpp`: `get_vpos()`, `apple2_interrupt()`
- MAME PR #14177: VBL sync fix confirming $C019 polarity
