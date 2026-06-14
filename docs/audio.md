# Audio

How the core's sound sources are mixed, filtered, crossed into the HDMI clock domain, and
embedded in the HDMI stream. Output is **16-bit stereo at 44.1 kHz**.

## The chain

```
sources (clk_logic 54 MHz)  →  mix (sum, signed 16-bit)  →  CDC (→ clk_pixel)
   →  filter (audio_out: IIR low-pass + DC block)  →  HDMI audio packets  →  HDMI
```

## Sources

Each source is produced on the logic clock and exposes a small audio output:

| Source | Module | Output | Width | Notes |
|---|---|---|---|---|
| Apple II speaker | [`apple_speaker`](../hdl/sound/apple_speaker.sv) | `speaker_o` | 1-bit | Toggled by `$C030`; decays |
| Mockingboard | [`mockingboard`](../hdl/mockingboard/mockingboard.sv) | `audio_l_o`/`audio_r_o` | ~10-bit, stereo | Two AY-3-8910/YM2149 PSGs |
| SuperSprite | [`supersprite`](../hdl/supersprite/supersprite.sv) | `ssp_audio_o` | ~10-bit, mono | AY-3-8910 on the sprite card |
| Ensoniq DOC 5503 | [`sound_glu`](../hdl/sound/sound_glu.sv) → [`doc5503`](../hdl/sound/doc5503.sv) | `audio_l`/`audio_r` | signed 16-bit, stereo | IIgs 32-voice wavetable; not on every board |
| ESP32-S3 ES5503 (a2p25) | [`i2s_receiver`](../hdl/sound/i2s_receiver.sv) | `i2s_sample_l/r` | signed 16-bit, stereo | ES5503 runs on the MCU, enters over I2S |

## Mixing

In `top.sv`, the unsigned sources are left-extended to a common width and summed with the signed
DOC output into a signed 16-bit stereo pair. From
[a2n20v2-Enhanced/hdl/top.sv:818](../boards/a2n20v2-Enhanced/hdl/top.sv):

```systemverilog
wire [12:0] speaker_audio_ext_w = {speaker_audio_w, 12'b0};
wire [12:0] ssp_audio_ext_w     = {ssp_audio_w, 3'b0};
wire [12:0] mb_audio_l_ext_w    = {mb_audio_l, 3'b0};   // (and _r)
assign core_audio_l_w = sg_audio_l + ssp_audio_ext_w + mb_audio_l_ext_w + speaker_audio_ext_w;
assign core_audio_r_w = sg_audio_r + ssp_audio_ext_w + mb_audio_r_ext_w + speaker_audio_ext_w;
```

The sum can in principle overflow by a bit; the filter stage clamps (saturates) rather than
reserving headroom. Boards without Ensoniq simply omit the `sg_audio_*` term.

## Filtering

[`audio_out`](../hdl/sound/audio_out.v) (built on [`iir_filter`](../hdl/support/iir_filter.v),
from the MiSTer/Sorgelig audio lineage) band-limits the mixed signal before it's resampled to
44.1 kHz, then runs a **DC blocker** (high-pass) to remove offset. The filter is configured by
coefficients passed from `top.sv` (`flt_rate`, `cx`/`cx0..2`, `cy0..2`) — e.g.
[a2n20v2-Enhanced/hdl/top.sv:846](../boards/a2n20v2-Enhanced/hdl/top.sv). An `ENABLE` parameter
can bypass it (a2p25 currently defaults the filter off). The exact coefficient math lives in
`iir_filter.v`; treat the values in `top.sv` as the tuned configuration.

## Clock-domain crossing & sample timing

- **CDC:** the mixed audio is resampled from `clk_logic` (54 MHz) into `clk_pixel` (27 MHz) by
  [`cdc_sampling`](../hdl/support/cdc_sampling.sv) (`WIDTH=16`, one instance per channel —
  [top.sv:826](../boards/a2n20v2-Enhanced/hdl/top.sv)). Audio changes slowly relative to both
  clocks, so sampling the word across the boundary is safe.
- **Sample timing:** [`audio_timing`](../hdl/sound/audio_timing.sv) generates the `clk_audio`
  sample strobe at `AUDIO_RATE` (44100 Hz) via fractional-N division, plus I2S bit/word clocks.

## Into HDMI

The filtered `audio_sample_word[1:0]` (L/R, 16-bit) feeds the [`hdmi`](../hdl/hdmi/hdmi.sv) module
(`AUDIO_RATE=44100`, `AUDIO_BIT_WIDTH=16`). HDMI builds IEC-60958 audio sample packets
([`audio_sample_packet`](../hdl/hdmi/audio_sample_packet.sv)) and the N/CTS clock-regeneration
packets ([`audio_clock_regeneration_packet`](../hdl/hdmi/audio_clock_regeneration_packet.sv)),
interleaved with video into the TMDS stream. `clk_audio` paces sample capture.

## Board differences

| Board | Speaker | Mockingboard | SuperSprite | Ensoniq DOC | Notes |
|---|---|---|---|---|---|
| a2mega | ✓ | ✓ | ✓ | ✓ (DOC RAM in **BSRAM**) | |
| a2n20v2-Enhanced | ✓ | ✓ | ✓ | ✓ (DOC RAM in SDRAM) | |
| a2n20v2-GS | ✓ | ✓ | ✓ | ✓ (DOC RAM in SDRAM) | |
| a2n20v2 | ✓ | ✓ | ✓ | ✗ | production; no IIgs sound |
| a2n20v1 / a2n9 | ✓ | ✓ | ✓ (n9: no SSP) | ✗ | older/deprecated |
| a2p25 | ✓ | ✓ | ✓ | ✗ on-FPGA | **ES5503 runs on the ESP32-S3**, audio enters via I2S |

The DOC path is gated by `` `define ENSONIQ `` in each board's `top.sv`. On a2p25 the IIgs sound
is emulated on the coprocessor instead of in the FPGA (see [a2p25/TODO.md](../boards/a2p25/TODO.md)
and its [LCAM session notes](../boards/a2p25/docs/LCAM_SESSION_NOTES.md)).

## Adding a sound source

1. Produce a sample stream (signed preferred; unsigned is fine if you document the offset).
2. Add it to the `core_audio_l_w` / `core_audio_r_w` sum in `top.sv`, left-extending to match the
   mix width. Mind the overflow note above — scale so the combined sum stays in range.
3. If it lives off-FPGA (like the a2p25 ES5503), bring it in over I2S with `i2s_receiver` and add
   it after the CDC, as a2p25 does.

## See also

- [gotchas.md](gotchas.md) — audio-clock driver pitfalls (a missing `clk_audio` driver sweeps the
  audio path away in synthesis — a real bug on a2n20v2-Enhanced).
- [architecture.md](architecture.md) — where audio sits in the whole design.
- [coprocessor-interface.md](coprocessor-interface.md) — the a2p25 ES5503-on-MCU path.
