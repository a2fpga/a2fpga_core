# A2P25 TODO

## Status

**Work In Progress** - Tang Primer 25K version, coming soon.

## High Priority

- [x] Eliminate LCAM packet loss during IIgs burst transfers (confirmed 32,768/32,768, 0 corrupted, 0 drops)
- [x] ES5503 audio bring‑up: generate sound on ESP32‑S3 and play via FPGA I2S
- [x] ES5503 sample rate conversion: correct pitch (26,320 Hz → 48,000 Hz via zero-order hold)
- [x] ES5503 audio gaps: MAME-style stream update on write + prebuffer ring buffer
- [x] ES5503 audio quality: clock drift fix, cubic interpolation, biquad anti-aliasing
- [x] GLU address pointer desync: track auto-increment on $C03D reads (was only tracking writes)
- [x] FPGA serialization verified: zero packet loss (fpgastats CLI command added, SPI regs 11-15)
- [x] ES5503 write/generate race condition: mutex now protects g_es5503->write()
- [ ] ES5503 key-on timing mismatch: always reset accumulator on halt=0 write (pending test)

## Medium Priority

- [ ] Complete the FAT32 SD Card support
- [ ] Enable configuration through a web-based UX rather than OSD

## Low Priority / Future

- [ ] Document ESP32-S3 to FPGA communication protocol
- [ ] Create web-based configuration UI

## Architecture Notes

- Uses ESP32-S3 for control/configuration
- LCAM interface between ESP32-S3 and FPGA
- ES5503 (Ensoniq DOC) emulation runs on ESP32-S3

## Known Issues

- VSYNC cadence metric: In VSYNC‑EOF mode, "Packets per EOF" may read ~250–350 vs the ideal ~409 because LCD_CAM length‑EOF can still trigger alongside VSYNC. Data integrity is unaffected (counts match, 0% corruption, 0 drops). Firmware sets
  `cam_rec_data_bytelen=4095` in VSYNC‑EOF to minimize interference. Consider adding a de‑noised cadence estimate/warning or use length‑EOF preset for canonical tests.

## Build Status

- Last verified build: Unknown
- Board design in progress


## Current Work

Testing using the following assembly code running on the IIgs and monitoring via the Arduino console:
```
        CLC             ; enter native mode (if coming from emulation)
        XCE

        SEP   #$20      ; A = 8-bit
        REP   #$10      ; X/Y = 16-bit

        LDA   #$00
        PHA
        PLB             ; DBR = $00 so absolute accesses use bank 00

        LDX   #$8000    ; 32768 iterations
@loop:  STZ   $C03D     ; store zero to $C03D
        DEX
        BNE   @loop

        RTS
```

which assembles to the following bytes:
```
0300: 18 FB E2 20 C2 10 A9 00 48 AB A2 00 80 9C 3D C0
0310: CA D0 FA 60
```

This stores bytes at the theoretical maximum speed that the IIgs 65816 is capable of writing to
the 65816 and allows us to see error rates with the current ESP32-S3 LCAM code.

In order for the A2P25 to be viable for IIgs use, we must be able to handle memory transfers
with zero packet loss since the A2P25 requires ES5503 sound generation to occur on the ESP32-S3.

## ES5503 Audio Bring‑Up Plan

Goals
- End‑to‑end: IIgs writes ES5503 regs/wave RAM → ESP32 emulates ES5503 → I2S slave‑TX to FPGA → audible output.
- No packet loss (maintained), glitch‑free audio, minimal setup (use presets/quiet logging).

Plan of Attack
- [x] Bus→Emulator wiring
  - [x] Verify handle_es5503_write() updates emulator regs and wave RAM on ES5503 address range ($C03C–$C03F).
  - [x] Add counters/CLI to confirm write counts and last N writes for quick sanity.
- [x] ES5503 core completeness
  - [x] Implement/verify oscillator stepping at 7.15909 MHz base, phase accumulators, sample fetch, loop/stop behavior.
  - [x] Implement envelope/volume/pan per oscillator; 32‑voice mode (IIgs standard).
  - [x] Generate mono/stereo frames at native ES5503 rate (26,320 Hz for 32 oscillators).
- [x] I2S pipeline to FPGA
  - [x] Confirm FPGA provides BCLK/LRCLK and pin mapping; keep ESP32 in SLAVE TX as implemented.
  - [x] Tone smoke test (existing tone/radio paths) to validate physical link and FPGA playback.
  - [x] Swap I2S task source to ES5503 generate path (guarded by CLI `es5503start/stop`).
- [x] Sample rate conversion (26,320 Hz → 48,000 Hz)
  - [x] Zero-order hold upsampling: generate 281 ES5503 samples, duplicate to fill 512-sample I2S buffer.
  - [x] Default oscillator count to 32 (IIgs boot writes 0xE1 before ESP32 ready).
  - [x] Verified: pitch is now correct (no chipmunk/fast playback).
- [x] Mixer/integration
  - [x] Mix enabled oscillators with proper gain to avoid clipping; add soft‑clip or headroom.
  - [x] Expose CLI to mute/solo voices and print minimal status (active voices, peak meter).
- [x] Performance/robustness
  - [x] Ensure i2s_tx_task keeps up without starving LCD_CAM (already mitigated by GDMA_CH=2 and yields).
- [x] Validation
  - [x] Use IIgs demos that write ES5503 wave RAM/regs; expect audible output on FPGA audio.
  - [x] Confirm zero LCAM drops during audio playback and no audible underruns.

Remaining Issues
- [x] Audio gaps (~10ms): Fixed via MAME-style stream update on write.
      **Root cause**: Our emulator generated audio in ~10ms chunks. If an oscillator was briefly
      halted when we generated, we'd output 10ms silence instead of ~100μs. MAME avoids this by
      calling `m_stream->update()` BEFORE each register write, generating audio up to that moment.
      **Solution**: Two triggers now generate audio into the ring buffer:
      1. Timer trigger: I2S task calls `es5503_stream_update()` periodically
      2. Write trigger: `handle_es5503_write()` calls `es5503_stream_update()` before control reg writes
      A mutex protects ES5503 state since both LCAM task and I2S task access it.
      See docs/LCAM_SESSION_NOTES.md for full implementation details.

- [x] Selective write trigger: Initial MAME-style approach called stream_update on EVERY write,
      causing 32,768 mutex ops during burst test → 381 underruns. Fixed by only triggering on:
      - Oscillator control registers (0xA0-0xBF) - affect halt/start timing
      - Oscillator enable register (0xE1) - affects oscillator count
      Wave RAM writes and other registers skip the trigger (no timing impact).

- [x] Non-blocking write trigger: Even selective triggering caused underruns when control
      registers written rapidly. I2S task couldn't acquire mutex → couldn't generate audio.
      Fixed by making write trigger non-blocking (timeout=0). If mutex busy, skip sync - I2S
      task will generate audio anyway. I2S task uses 10ms timeout to ensure it gets priority.

- [x] Gap verification: Compared captured_13.wav vs source frontleft.wav. All significant gaps
      in captured audio correspond to gaps in source material. Only one extra 9.3ms gap found.
      Audio is faithfully reproducing source content.

- [x] Clock drift / buffer drain: Ring buffer steadily drained ~0.7 samples/cycle due to clock
      domain mismatch between ESP32 micros() and FPGA I2S clock. Fractional accumulator slowed
      drain but couldn't eliminate it. Fixed by redesigning I2S task to generate audio directly
      (512 frames per iteration) instead of relying on time-based ring buffer. Ring buffer now
      only used for write-trigger (MAME-style) audio. Result: zero underruns.

- [x] Tinny distortion (ZOH → linear interpolation): Zero-order hold (sample duplication)
      created staircased waveforms with high-frequency artifacts. Replaced with linear
      interpolation using 8.8 fixed-point math. Improved but angular "jags" remained at
      ES5503 sample boundaries (every ~1.82 output samples).

- [x] Resampling jags (linear → cubic + biquad): Linear interpolation creates angular corners
      at each ES5503 sample point. Analysis of captured_16.wav showed 2748 large jumps with
      mean run length 1.16 (expected 1.82). Fixed with two improvements:
      1. **Catmull-Rom cubic interpolation**: C1-continuous curves through sample points,
         no angular transitions. Uses 4 neighboring samples with Horner's method in 8.8
         fixed-point. Cross-chunk boundary bridging via static prev_sample variables.
      2. **2-pole Butterworth biquad LPF** (fc=10kHz, 12dB/oct): Replaces 1-pole IIR
         (alpha=0.8, 6dB/oct) with steeper rolloff. Q14 fixed-point coefficients.

Nice‑to‑Haves
- [ ] Add a test preset: `es5503preset demo` to load a simple patch/wave and play a reference pattern.

## Current Status (2026‑01‑28)

- IIgs burst capture (32,768 writes to $C03D): PASS — Words received 32768, Corruption 0.0%, Ring drops 0, Address range $C03D–$C03D.
- Default mode: VSYNC‑EOF with gated VSYNC every 409 packets in HDL; ESP32 sets `cam_rec_data_bytelen=4095` in VSYNC‑EOF and `CHUNK_BYTES=4090` in length‑EOF.
- Diagnostics & CLI: Added `statsbrief`, throttled per‑buffer logs (`lcamlog`, `lcamlogevery`, `lcamlograte`), and one‑shot `lcamdebug N`. Parsing fixes applied.
- I2S concurrency: LCD_CAM capture sustained with GDMA_CH=2 and background recovery.
- ES5503: Recognizable audio achieved from IIgs app; pitch correct (26kHz→48kHz sample rate conversion).
- Audio gaps: RESOLVED via MAME-style stream update with optimizations:
  - Selective trigger: only control registers (0xA0-0xBF) and E1 call stream_update
  - Non-blocking write trigger: uses 0ms mutex timeout to avoid blocking I2S task
  - I2S task priority: uses 10ms mutex timeout, always gets to generate audio
  - Ring buffer (2048 frames, 15ms prebuffer) smooths output
  - Gap verification: captured audio gaps match source material gaps
- Clock drift: RESOLVED — direct I2S generation (512 frames/iteration) eliminates clock domain mismatch. Zero underruns achieved.
- Audio quality: Catmull-Rom cubic interpolation + 2-pole Butterworth biquad LPF (fc=10kHz, 12dB/oct). Pending final listening test.
- GLU desync: FIXED — auto-increment on $C03D reads was not tracked, causing DOC register writes to target wrong oscillators. This explained tones not stopping, sounds not playing, and strange audio during game play.
- Ring buffer: Increased from 1024 to 4096 entries to prevent overflow during heavy bus traffic.
- Diagnostics: Added `s_glu_read_auto_inc` and `s_read_packet_count` counters to `stats` output.
- FPGA serialization: Verified zero packet loss via `fpgastats` (34,952/34,952, 0 dropped, overwrite flag clear). Counters wired to SPI regs 11-15.
- ES5503 write/generate race: FIXED — `g_es5503->write()` was unprotected by mutex while I2S task's `update_stream()` reads/writes back `pOsc->control`. Fix: mutex now wraps all DOC register writes (50ms timeout), with MAME-style stream update in same critical section. Diagnostic counters (`s_mutex_ok_count`, `s_mutex_fail_count`) added to `stats` output.
- ES5503 key-on timing mismatch: FOUND — MAME's key-on check (halt=1→halt=0 transition) fails when our shadow hasn't halted yet due to clock domain mismatch (ESP32 micros() vs IIgs crystal). Fix: always reset accumulator when halt=0 is written, since IIgs Sound Manager pattern is always: program note → write control with halt=0.

## Next Actions

- [ ] **CRITICAL**: Test both fixes (mutex + key-on timing) with games — verify sounds start/stop correctly, tones end properly, no dropped notes.
- [ ] Optional: Add de‑noised VSYNC cadence metric and warn if deviates >±10% from target (409) in VSYNC‑EOF.
- [ ] Optional: Add a test preset to temporarily switch to length‑EOF for canonical runs (pretty EOF stats) and switch back to VSYNC‑EOF for normal operation.
- [ ] Document field checklist for verifying capture (expected stats, CLI snippets) in the firmware README (linked below).
- [ ] ES5503: Add voice activity + peak meter to `es5503info`; optional compat toggle to ignore 0x00 halts during bring‑up; validate multi‑voice mixing, pan/volume, and headroom; confirm E1 sequencing with IIgs programs.

Further Reading / Playbook
- Full session knowledge and procedures: `boards/a2p25/docs/LCAM_SESSION_NOTES.md`
- Firmware checklist and expected stats: `boards/a2p25/src/a2fpga_esp32/README.md`
## LCAM Investigation Summary

- Apple IIgs test sends 32,768 ES5503 packets at ~13.5 MB/s (PCLK 13.5 MHz).
- Root cause of loss was GDMA descriptor churn from per-packet VSYNC→EOF (EOF every ~10 bytes), not just FIFO depth.
- Fixes implemented so far:
  - SPI protocol on FPGA: bit order, sync sequencing, first-byte read behavior, and single-driver cleanup; testbench passes.
  - ESP32: length-EOF mode with large chunks and stitching; VSYNC‑EOF mode with gated cadence; GDMA channel moved to 2; background relink on GDMA reset; dummy handling for XFER; improved stats/CLI.
- Results to date:
  - Corruption: 0.0% in both modes once aligned.
  - Capture count: near-complete; exact 32,768 requires proper end-of-burst handling (see plan).

Further Reading / Playbook
- Full session knowledge and procedures: `boards/a2p25/docs/LCAM_SESSION_NOTES.md`
- Firmware checklist and expected stats: `boards/a2p25/src/a2fpga_esp32/README.md`

## LCAM Resolution Plan (Actionable)

1) FPGA (Serializer/Sync)
- Gate VSYNC once every 409 packets and assert one VSYNC at end-of-burst.
- Ensure no stray VSYNC inside the burst; keep PCLK at 13.5 MHz.

2) ESP32 Firmware Defaults
- Default mode: VSYNC‑EOF.
- `CHUNK_BYTES=4090` (409×10), `DESC_COUNT=8`, `GDMA_CH=2`.
- Disable alignment/stitching in VSYNC‑EOF mode; keep VSYNC glitch filter enabled.

3) Verification (Hardware)
- IIgs burst test: confirm
  - Words received = 32768 exactly
  - Corruption rate = 0.0%
  - Words captured ≈ 80–81 (EOFs per 4 KB + final partial)
- Re-test with I2S enabled to verify no LCD_CAM interruption; GDMA relink should maintain streaming.

4) Fallback (If VSYNC cadence unavailable)
- Use length‑EOF with alignment detection + tail flush (send dummies until `bytes_sent % CHUNK_BYTES == 0`).
- Expect perfect counts with 0.0% corruption.

5) Ops/Docs
- Keep CLI: `lcammode vs|len`, `status`, `addrwin`.
- Document expected stats and pass criteria in README/firmware notes.
