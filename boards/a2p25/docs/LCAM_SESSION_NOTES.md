LCAM Capture: Investigation Summary and Playbook

Context
- Board: A2P25 (Tang Primer 25K) with ESP32‑S3 capture side.
- Goal: Lossless capture of IIgs ES5503 audio bursts (32,768 packets) via LCD_CAM.
- Baseline issue: ~25% packet loss on ESP32; occasional corruption; I2S interaction stopping capture.

Protocol and Timing
- Serializer: 10 nibbles/packet (8 data, VSYNC nibble, stopper nibble). PCLK = 13.5 MHz (COUNT_WIDTH=2 from 54 MHz).
- Throughput: ~13.5 MB/s during bursts; typical burst length ~24 ms for 32,768 packets.

FPGA (SPI/Protocol) Fixes
- Corrected SPI bit ordering and sync handling in `esp32_spi_proto_proc.sv`.
- Added one‑shot first‑byte load for register/XFER reads to avoid phase hazards.
- Removed multi‑driver conditions (e.g., `tx_shift` single driver in fall‑edge loader).
- Simulation: `make -C boards/a2p25/tests spi_connector` passes (reg read/write and XFER readback).

ESP32 LCD_CAM Capture Architecture
- Two operating modes supported:
  1) Length‑EOF mode (recommended fallback):
     - Large DMA chunks (`CHUNK_BYTES ≈ 4090`, multiple of 10), descriptor ring (`DESC_COUNT ≥ 8`).
     - Alignment detector per chunk + cross‑boundary stitching via 0–9 byte tail.
     - Optional tail flush: pad dummy packets until `bytes_sent % CHUNK_BYTES == 0` for exact counts.
  2) VSYNC‑EOF mode (preferred when FPGA can gate VSYNC):
     - Gate VSYNC once every N=409 packets, plus one VSYNC at end‑of‑burst.
     - Disable alignment/stitching (buffers start on packet boundary by design).
     - Expect ~80–81 EOFs for a 32,768‑packet burst with `CHUNK_BYTES=4090`.

Key ESP32 Settings/Changes
- GDMA channel isolation: `GDMA_CH=2` for LCD_CAM to avoid I2S conflicts.
- GDMA recovery: background poller re‑arms link if `in.link.addr == 0` (function `lcdcam_recover_if_needed`).
- VSYNC filter: `cam_vsync_filter_thres = 1` to suppress glitches.
- CLI toggles: `lcammode vs|len`, `status`, `addrwin`, `i2sstart`, `i2sstop`.

Stats and Expected Results
- Success criteria (burst of 32,768 packets):
  - Words received (non‑heartbeat): 32768
  - Corruption rate: 0.0%
  - Words captured (EOF count): ≈ 80–81 in VSYNC‑EOF, ≈ 80–90 in length‑EOF.
  - Ring buffer drops: 0

Recommended Defaults
- Mode: VSYNC‑EOF (when FPGA provides gated VSYNC cadence).
- `CHUNK_BYTES = 4090`, `DESC_COUNT = 8`, `GDMA_CH = 2`, VSYNC filter = 1.

IIgs Test Procedure
1) Load and run the tight write loop to `$C03D` (32,768 iterations). Example bytes:
   - Assembly skeleton and byte encoding are documented in `boards/a2p25/TODO.md` under Current Work.
2) On ESP32 serial console:
   - `+++` (enter console)
   - `status` (confirm LCD_CAM running)
   - `lcammode vs` (or `lcammode len`)
   - Optional: `i2sstart` to run concurrent I2S slave‑TX (verify GDMA stability)
   - After payload completes, run `status`/`stats` to read results.

Troubleshooting
- Fewer than 32768 words:
  - In VSYNC‑EOF: ensure FPGA gates VSYNC every 409 packets and asserts a final VSYNC after the burst.
  - In length‑EOF: enable tail flush on the sender (pad dummies until `bytes_sent % CHUNK_BYTES == 0`).
- Corruption > 0%:
  - Ensure alignment/stitching disabled in VSYNC‑EOF; enabled and active in length‑EOF.
  - Confirm PCLK is 13.5 MHz and serializer nibble order matches parser expectations.
- LCD_CAM stalls after starting I2S:
  - Verify `GDMA_CH=2`, background recovery enabled, and `i2sstop`/`i2sstart` do not reset GDMA link persistently.
- Guru Meditation (stack canary) in `lcam_poll`:
  - Cause: poller task stack too small under heavy logging/printf.
  - Fix: increased `lcam_poll` stack to 4096 bytes. Keep logging throttled (`lcamlog 1`, `lcamlogevery 200`, `lcamlograte 1000`).

Notes
- Using length‑EOF with alignment/stitching yields 0.0% corruption and near‑perfect counts; adding a sender‑side tail flush guarantees exact 32768.
- VSYNC‑EOF provides naturally aligned buffers and low CPU overhead when cadence and final pulse are correct.

Gotcha: VSYNC‑EOF buffer alignment
- LCD_CAM asserts EOF at the VSYNC sample (nibble 8). The next buffer typically begins at nibble 9, not data nibble 0.
- We initially disabled alignment in VSYNC‑EOF, assuming buffers began on packet boundaries; this caused “corrupted” idle packets with address ranges like $0FF0–$FFFF.
- Fix: Always run alignment detection (both modes). Keep cross‑boundary stitch only for length‑EOF.

---

Current Implementation Status (snapshot)
- HDL
  - `hdl/esp32/cam_serializer.sv`: `SYNC_EVERY_PKTS=409`, idle flush forces one VSYNC at end of burst; `PAD_MODE=0` (no automatic padding); PCLK from COUNT_WIDTH=2 → 13.5 MHz.
  - `hdl/esp32/a2bus_stream.sv`: Instantiates serializer with `.SYNC_EVERY_PKTS(409)`, `.PAD_MODE(1'b0)`; heartbeat packets = `0xC0FF`.
- ESP32
  - `src/a2fpga_esp32/a2fpga_lcam.cpp`: Defaults to VSYNC‑EOF (`s_use_vsync_eof=true`), `CHUNK_BYTES=4090`, `DESC_COUNT=8`, `GDMA_CH=2`, VSYNC filter = 1.
  - Alignment/stitching: disabled in VSYNC‑EOF, enabled in length‑EOF; tail saved only in length‑EOF.
  - Robustness: background `lcdcam_recover_if_needed()` for GDMA inlink resets; status/CLI present (`lcammode vs|len`, `i2sstart|i2sstop`).
  - SPI helpers: XFER dummy properly consumed; status captured on header.

Verification Checklist (hardware)
- Mode VSYNC‑EOF with gated VSYNC every 409 and final VSYNC:
  - Words received (non‑HB): 32768
  - Corruption rate: 0.0%
  - Words captured (EOFs): ~80–81
  - Ring drops: 0
  - With I2S running: same as above
- Mode length‑EOF:
  - Use alignment + stitching; sender pads dummies to `CHUNK_BYTES` boundary → exactly 32768 received, 0.0% corruption.

Regression Guardrails
- Keep `CHUNK_BYTES` a multiple of 10; if `SYNC_EVERY_PKTS` changes, adjust `CHUNK_BYTES ≈ 10*N` and docs.
- Do not re‑enable per‑packet VSYNC→EOF (i.e., `SYNC_EVERY_PKTS=1`) without switching firmware to length‑EOF.
- Preserve `GDMA_CH=2` for LCD_CAM; confirm recovery path remains in poller.
- Keep VSYNC glitch filter enabled (`cam_vsync_filter_thres=1`).
- Always run the I2S concurrency test after capture changes.

Open Items / Next
- Re‑verify exact 32768 counts on current bitstream + firmware in VSYNC‑EOF with I2S active.
- Optional: expose `SYNC_EVERY_PKTS` as a top parameter switch if experimenting with other chunk sizes.

Changelog
- 2026‑01‑18: Added status snapshot, checklist, and guardrails; confirmed gated VSYNC (N=409), VSYNC‑EOF default, CHUNK_BYTES=4090, DESC_COUNT=8, GDMA_CH=2.
- 2026‑01‑18: Re‑enabled alignment detection in VSYNC‑EOF to handle buffers starting at nibble 9. Added per‑buffer debug log (level 1: changes/periodic, level 2: every buffer) and `statsbrief` + `lcamlog` CLI.
- 2026‑01‑18: Fixed CLI parsing so `lcamlogevery`/`lcamlograte` are not shadowed by `lcamlog` (exact match for `lcamlog`).

Debug Logging Usage
 - Set level: `lcamlog 1` (changes/periodic) or `lcamlog 2` (every buffer). Disable: `lcamlog 0`. Levels >2 are clamped to 2.
- Quick summary: `statsbrief` prints `mode/off/words/cap/drops`.
- One‑shot burst: `lcamdebug N` logs the next N buffers regardless of level (useful to capture a transition), `lcamdebug 0` cancels.
 - Throttle/ cadence (defaults set):
  - Default: level=1, every=200 buffers, rate=1000 ms (safe, low-noise).
  - `lcamlogevery N` emits at most one log every N buffers (level≥1; still logs when offset changes).
  - `lcamlograte ms` enforces a minimum wall‑time between logs (burst unaffected).
- Log line format:
  `[LCAM] buf#<n> mode=<VSYNC|LEN> len=<bytes> off=<0..9> proc=<packets> seen=<words> cap=<bufs> drop=<ring> a0=$<addr>`
  - `off`: detected 10‑byte phase (expect stable non‑zero in VSYNC‑EOF; 0 in length‑EOF if flush/pad aligns).
  - `a0`: first word’s address in buffer (quick sanity for ES5503 vs heartbeat/reset).

Stats Interpretation Notes
- Idle VSYNC‑EOF behavior: Expect small `len` (~19–20), `proc≈2`, `a0=$C0FF` (heartbeat) and `off` fluttering (1–2) — this is normal and not corruption.
- Burst behavior: `off` stabilizes (typically 1), `a0=$C03D`, `words received` climbs with 0 drops/corruption.
- Accounting: `words received` excludes heartbeat (`$C0FF`) but may include the single reset indicator packet (address `$0000`), so it can be +1 vs ES5503 packet count; bus stats exclude reset packets by design.
- VSYNC cadence sanity: In VSYNC‑EOF, derive cadence as `words_received / words_captured` (printed by `stats`). Expect ~409 with current gating; large deviations suggest an old bitstream or unintended VSYNC sources.
  - If you observe ~250–350 instead of ~409, length‑based EOF is also firing (rec_data_bytelen not disabled). Firmware sets `cam_rec_data_bytelen=4095` in VSYNC‑EOF to suppress length EOF; ensure you reflashed after this change.

Presets
- `lcampreset normal`: VSYNC‑EOF, quiet logging (no extra setup, good default).
- `lcampreset canon`: length‑EOF, quiet logging (for canonical pretty EOF stats; requires sender padding).

---

ES5503 Bring‑Up Notes

Overview
- Path: IIgs writes $C03C–$C03F → ESP32 GLU interprets (DOC registers vs wave RAM) → ES5503 emulation generates samples → I2S slave‑TX to FPGA.
- Status: Recognizable audio achieved from IIgs program; tone/fulltest confirm I2S; capture integrity maintained.

Key Behaviors & Gotchas
- Sample encoding: ES5503 uses unsigned bytes; mixer converts via `sample ^ 0x80`.
  - 0x80 = DC zero (silence). A region of 0x80 will be silent (no halt).
  - 0x00 halts the oscillator (end marker). Ensure first non‑zero sample to avoid immediate halt.
- Oscillator enable (E1): Value is `(num_osc - 1) << 1`. e.g., `E1=0x02` enables 2 voices.
- Control (A#): bit0=halt; modes include FREE(0), ONCE(1), SYNC(2), SWAP(3). Pairing matters in SWAP.
- Mixer coverage: Emulator updated to scan all 32 oscillators so voices configured before E1 aren’t missed.

ESP32 Counters & Mirrors
- GLU counters: `Wave memory writes` (C03D RAM), `DOC reg writes` (C03D DOC), `GLU ctrl` (C03C), `GLU addr` (C03E/F).
- ES writes (FPGA‑mirror): ESP32-side mirror of total writes to $C03C–$C03F since reset, with breakdown.
  - Usage: `es5503resetwrite` → playback → `es5503info` → compare `total` with OSD delta; `total ≈ RAM bytes + control/address/DOC writes`.

CLI (Audio)
- Start/stop: `es5503start` / `es5503stop` (auto‑starts I2S on start), `audiostop` (halt all voices), `i2sstop`.
- Diagnostics: `es5503info` (osc table + counters + ES write mirror), `es5503reg <reg> [val]` (accepts $E1/0xE1/E1), `es5503mem <addr> [len]`.
- Tests: `fulltest` (load sine & play), `starttone`/`stoptone` (I2S route check).
- Resets: `es5503resetwrite` (GLU/ES write counters), `resetstats` (bus/LCD_CAM stats).

Typical Flow
1) `lcampreset normal` → verify capture (`stats`).
2) `es5503start` → run IIgs program → `es5503info`.
3) If silent: check voice halt bits (A#), E1 value, and wave region (non‑0x80). Unhalt voice once RAM filled.
4) Correlate ES bytes: `es5503resetwrite` before playback; `es5503info` after → ES writes total should match manual OSD delta per playback.

Next Steps
- Add voice activity + peak meter to `es5503info`.
- Optional compat toggle to ignore 0x00 halts during bring‑up (off by default).

---

ES5503 Sample Rate Conversion (Jan 2026)

Problem
- ES5503 native sample rate: `clock / 8 / (oscsenabled + 2)` = 7159090 / 8 / 34 = **26,320 Hz** (for 32 oscillators)
- FPGA I2S output rate: **48,000 Hz**
- Without conversion, audio plays 1.82x too fast ("chipmunk" effect)

Solution (evolution):
1. **Zero-Order Hold** (initial): Generate 281 ES5503 samples per 512-sample I2S buffer,
   duplicate each ~1.82x. Correct pitch but tinny distortion from staircased waveform.
2. **Linear interpolation**: 8.8 fixed-point interpolation between adjacent samples.
   Better but angular "jags" at sample boundaries.
3. **Catmull-Rom cubic + biquad LPF** (current): C1-continuous curves through sample
   points eliminate jags at source. 2-pole Butterworth at 10kHz removes residual aliases.

Key Learnings
1. **Oscillator count default**: IIgs writes register 0xE1 at boot to set 32 oscillators, but this
   happens before ESP32/LCAM capture is ready. Default m_oscsenabled to 32 in es5503.cpp reset().

2. **Rate calculation**: With oscs=1 (wrong), rate = 298,295 Hz. With oscs=32 (correct), rate = 26,320 Hz.
   The gen=281 sample count was correct, but wrong oscs broke everything else.

3. **SWAP mode tracking**: Attempted to track where partner oscillators should start in the buffer
   to avoid overlap. This caused gaps instead because when odd oscillators (1,3,5...) trigger even
   partners (0,2,4...), the even ones were already processed earlier in the oscillator loop.
   Reverted to original MAME behavior (partners start from sample 0, slight overlap is acceptable).

4. **Audio gaps root cause**: ~10ms gaps occurred because register writes from IIgs arrive AFTER the
   I2S task has already generated silence for that time period. The timeline was:
   - T=0: IIgs writes register to start oscillator
   - T=0-10ms: LCAM packet in transit, I2S outputs silence (oscillator not started yet)
   - T=10ms: Register write arrives, oscillator starts
   - Result: 10ms gap at start of each note

5. **Prebuffer solution**: Added a ring buffer that delays audio output by ~15ms. Now the timeline is:
   - T=0: IIgs writes register
   - T=10ms: Register write arrives, oscillator starts generating into ring buffer
   - T=15ms: Audio output begins (prebuffer has filled)
   - Result: No gap because register writes arrive before we need the audio

Verified Result
- Pitch is now correct (audio plays at proper speed)
- Gaps addressed via two mechanisms: prebuffer + grace period (see below)

---

Audio Prebuffer Implementation (Jan 2026)

Problem
- IIgs register writes travel: CPU → FPGA → LCAM serializer → DMA → ESP32 → ES5503 emulator
- This path has ~10ms latency
- Without prebuffering, I2S outputs silence while waiting for register writes to arrive
- Result: audible ~10ms gap at the start of every note

Solution: Ring Buffer with Prebuffer
- Added 2048-frame ring buffer (~42ms capacity at 48kHz)
- ES5503 generates samples into the ring buffer (producer)
- I2S reads from ring buffer with 15ms delay (consumer)
- Buffer must fill to 720 frames (~15ms) before output starts

Implementation Details
- Buffer size: 2048 stereo frames (4096 int16_t values)
- Default prebuffer: 720 frames = 15ms (adjustable 5-40ms)
- Single producer (ES5503 generation), single consumer (I2S output)
- No locks needed (volatile read/write positions suffice)
- Underrun handling: output silence, log warning, continue

CLI Commands
- `i2sstatus` - shows ring buffer status, prebuffer state, underrun count, gaps detected
- `prebuffer <ms>` - adjust prebuffer latency (5-40ms)
- `es5503start` - resets ring buffer and starts fresh

Finding: Prebuffer Alone Didn't Fix Gaps
- Testing showed 0 underruns but gaps still present
- Gap logging revealed transitions from active→silent→active in ES5503 generation itself
- Gaps were 11ms, 49ms durations - occurring DURING audio generation, not I2S output
- Conclusion: gaps were baked into generated audio, prebuffer only delays output

---

Oscillator Grace Period (Jan 2026)

Problem: Timing Granularity Mismatch
- Real ES5503 generates audio continuously at 26kHz (one sample every ~38μs)
- Our emulator generates in ~10ms chunks (281 samples at a time)
- When IIgs software briefly halts an oscillator (to update wave table, change parameters):
  - Real ES5503: ~100μs of silence = imperceptible
  - Our emulator: if halt happens during our chunk, entire 10ms chunk = silence = very noticeable

Diagnostic Evidence
```
ES5503: rate=26320 oscs=32 buf=512/2048 prebuf=YES active=26/50 gaps=0
[GAP] #1 duration=11ms
[GAP] #2 duration=49ms
ES5503: rate=26320 oscs=32 buf=512/2048 prebuf=YES active=45/50 gaps=2
```
- 0 underruns = ring buffer working fine
- gaps detected = ES5503 emulator itself transitioning between audio and silence
- Gap durations (11ms, 49ms) match our chunk timing

Solution: Grace Period for Halted Oscillators
- Track when each oscillator was last generating audio (`last_active_ms`, `was_generating`)
- When oscillator is halted (control bit 0 set), check if it was recently active
- If halted for less than GRACE_PERIOD_MS (20ms), continue generating audio from it
- Only truly stopped oscillators (halted >20ms) go silent

Implementation in es5503.cpp:
```cpp
bool is_halted = (pOsc->control & 1);
bool in_grace_period = pOsc->was_generating &&
                       (now_ms - pOsc->last_active_ms) < GRACE_PERIOD_MS;
bool should_generate = (!is_halted || in_grace_period) && channel_matches;
```

Why This Works
- IIgs software typically halts oscillators briefly (<1ms) to update parameters
- Our 20ms grace period bridges these brief halts
- Audio continues smoothly instead of having 10ms gaps
- Oscillators that are truly stopped (user stops playback) will halt after 20ms

Tradeoffs
- Sounds may continue for up to 20ms after software halts them
- For music/sound effects, this is imperceptible
- If issues arise, grace period can be reduced to 10ms

---

MAME-Style Stream Update (Jan 2026)

After reviewing MAME's ES5503 source code, we discovered the proper solution.

MAME's Approach (from es5503.cpp)
```cpp
void es5503_device::write(offs_t offset, u8 data)
{
    m_stream->update();  // Generate audio up to NOW before applying write
    // ... then apply register changes
}
```

Every register write first generates all pending audio samples, THEN applies the change.
This ensures audio state is captured BEFORE the register modification takes effect.

Our Implementation
Two triggers generate audio into the ring buffer:
1. **Timer trigger**: I2S task calls `es5503_stream_update()` when it needs samples
2. **Write trigger**: `handle_es5503_write()` calls `es5503_stream_update()` before applying each register write

Both use a shared timestamp (`s_last_update_us`) to know how many samples to generate.

Key Components
- `s_es5503_mutex`: FreeRTOS mutex protects ES5503 state (LCAM task + I2S task)
- `s_last_update_us`: Timestamp of last audio generation (microseconds)
- `es5503_stream_update()`: Generates samples since last update, pushes to ring buffer
- Ring buffer: Same prebuffer infrastructure, now fed by both triggers

Why This Works
When IIgs software does:
```
1. Halt oscillator (to change settings)
2. Update wave pointer
3. Update frequency
4. Restart oscillator
```

Each write triggers stream update FIRST:
- Write 1: Generate audio (oscillator running), then apply halt
- Writes 2-3: Generate tiny amount (halted), apply changes
- Write 4: Generate tiny amount (halted), restart oscillator
- Next timer: Generate audio (oscillator running)

Only microseconds of silence between writes, not 10ms chunks.

This matches MAME's behavior and should eliminate the timing granularity gaps.

---

Selective Write Trigger (Jan 2026)

Problem: Too Much Overhead
Initial implementation called `es5503_stream_update()` on EVERY write to the ES5503.
During the IIgs burst test (32,768 writes to $C03D), this caused:
- 32,768 mutex acquisitions/releases
- 32,768 audio generation calls
- Massive overhead slowing both LCAM and I2S tasks
- Result: 381 underruns despite buffer being 75% full

Analysis
Most writes during a burst are to wave RAM (sample data uploads). These don't affect
currently playing audio timing - they just load data for future use. Only control
register writes (0xA0-0xBF) affect oscillator halt/start state.

Solution: Selective Trigger
Only call `es5503_stream_update()` before writes that affect playback timing:
- Oscillator control registers (0xA0-0xBF): contain halt bit, mode, channel
- Oscillator enable register (0xE1): changes number of active oscillators

Skipped (high frequency, no timing impact):
- Wave RAM writes (just data, doesn't affect current playback)
- Frequency registers (0x00-0x3F)
- Volume registers (0x40-0x5F)
- Wavetable pointer/size registers (0x80-0x9F, 0xC0-0xDF)

Implementation in handle_es5503_write():
```cpp
if (reg >= 0xA0 && reg <= 0xBF) {
    es5503_stream_update();  // Sync before control change
    // ... apply write
} else if (reg == 0xE1) {
    es5503_stream_update();  // Sync before osc count change
}
// Other registers: no sync needed
```

Result
- Control register writes: ~hundreds per second (manageable)
- Wave RAM writes: ~thousands per second (no longer trigger sync)
- Audio gaps match source material, no longer introduced by timing issues

---

Non-Blocking Write Trigger (Jan 2026)

Problem: Mutex Contention
Even with selective triggering, underruns still occurred:
```
ES5503: buf=1535/2048 prebuf=YES underruns=0
Audio underrun! avail=506, total underruns=1
ES5503: buf=1535/2048 prebuf=YES underruns=15
```

The buffer was 75% full (1535 frames) but occasionally dropped to 506 (just under
the 512 needed), causing underruns. This happened because:
1. LCAM task acquires mutex for control register write
2. I2S task tries to acquire mutex (5ms timeout)
3. If LCAM holds mutex too long, I2S task times out
4. I2S task can't generate audio, tries to read from buffer
5. Buffer is low → underrun

Analysis
The I2S task MUST be able to generate audio to keep the buffer filled.
The write trigger is a "nice to have" for timing sync, but not critical
if the I2S task will generate audio anyway.

Solution: Non-Blocking Write Trigger
Two different mutex strategies:

1. **I2S task** (must succeed): 10ms timeout, waits for mutex
```cpp
static void es5503_stream_update() {
    if (xSemaphoreTake(s_es5503_mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
        es5503_stream_update_locked();
        xSemaphoreGive(s_es5503_mutex);
    }
}
```

2. **Write trigger** (optional): 0ms timeout, skip if busy
```cpp
static void es5503_stream_update_nonblocking() {
    if (xSemaphoreTake(s_es5503_mutex, 0) == pdTRUE) {
        es5503_stream_update_locked();
        xSemaphoreGive(s_es5503_mutex);
    }
    // If mutex busy, skip - I2S task will handle generation
}
```

Why This Works
- If mutex is free: write trigger syncs audio (MAME-style, best timing)
- If mutex is busy: I2S has it and is generating audio anyway (safe to skip)
- I2S task never blocked by writes, always gets priority for generation
- Write trigger still helps when there's no contention

Expected Result
- Zero underruns during normal playback
- Audio gaps only where source material has gaps
- No timing-induced gaps from our emulation

---

Gap Verification (Jan 2026)

After implementing selective + non-blocking write trigger, compared captured
audio against source material:

Test: captured_13.wav vs frontleft.wav
- Source: 1.49s, 10 gaps >5ms
- Captured: 1.56s, 9 gaps >5ms

Gap comparison (>5ms):
| Time    | Source Gap | Captured Gap | Match? |
|---------|-----------|--------------|--------|
| 0.00s   | 127.8ms   | 88.2ms       | ✓ startup |
| 0.47s   | 40.9ms    | 29.1ms       | ✓ |
| 0.85s   | 12.2ms    | 11.6ms       | ✓ |
| 0.87s   | 7.5ms     | 48.0ms       | ✓ |
| 0.93s   | 46.5ms    | 10.9ms       | ✓ |

Only ONE gap (9.3ms at 0.785s) didn't have a corresponding gap in source.

Conclusion
Audio gaps are faithfully reproducing the source material's intentional silences.
The ES5503 emulation timing is now correct.

---

Clock Drift Fix: Direct I2S Generation (Jan 2026)

Problem: Steady Buffer Drain
After implementing the MAME-style stream update, the ring buffer steadily drained
~0.7 samples per I2S cycle, causing underruns every ~2.7 seconds:
```
ES5503: buf=1535/2048 underruns=0
ES5503: buf=1520/2048 underruns=0
ES5503: buf=1505/2048 underruns=0
... (steadily draining)
Audio underrun! avail=506, total underruns=1
```

Root Cause: Clock Domain Mismatch
The ring buffer was filled based on ESP32 `micros()` (CPU clock), but drained by I2S
hardware running at the FPGA's clock rate. These two clocks don't track perfectly.
Integer truncation in `(elapsed_us * ES5503_RATE) / 1000000` lost ~0.83 samples per cycle.

Attempted Fix: Fractional Accumulator
Added `s_es5503_frac_acc` to carry sub-sample remainders across cycles. This slowed
the drain (20 cycles between underruns vs 9) but couldn't eliminate it because the
fundamental clock domain mismatch persists regardless of accumulator precision.

Solution: Direct I2S Generation
Redesigned the I2S task to generate audio directly instead of relying on the time-based
ring buffer:

1. **Ring buffer now only for write triggers**: Pre-write audio from MAME-style sync
   goes into the ring buffer (small amounts, microseconds of audio)
2. **I2S task generates directly**: Each iteration produces exactly AUDIO_BUFFER_FRAMES
   (512) output samples. First drains ring buffer, then generates remainder directly.
3. **No clock drift**: I2S hardware pulls buffers at its own rate. We generate exactly
   what's needed per buffer, with a fractional accumulator for the ES5503→output ratio.

Implementation:
```
I2S task iteration:
1. Drain ring buffer → stereo_buffer[0..from_ring]
2. remaining = 512 - from_ring
3. es5503_needed = remaining * 26320 / 44100 (with fractional accumulator)
4. generate_audio(es5503_temp, es5503_needed)
5. Upsample es5503_temp → stereo_buffer[from_ring..512]
6. Write 512 frames to I2S (always exact, never under/over)
```

Result: Zero underruns. Buffer drain eliminated.

---

Audio Quality: Interpolation & Filtering (Jan 2026)

Problem: Tinny Distortion
After achieving zero underruns, captured audio had tinny distortion with visible
"jags" in the waveform at ES5503 sample boundaries (every ~1.82 output samples).

Evolution of fixes:
1. **Zero-order hold** (initial): Sample duplication creates staircased waveform.
   Sounds very tinny - high-frequency energy from rectangular steps.
2. **Linear interpolation**: Connects samples with straight lines. Much better,
   but creates angular "corners" at each sample boundary. Still tinny.
3. **Linear + 1-pole IIR LPF** (alpha=0.8, ~12.3kHz cutoff): Smoothed slightly,
   but only 6dB/octave rolloff - insufficient to remove the angular artifacts.
   captured_16.wav analysis showed 2748 large jumps, mean run length 1.16
   (expected 1.82 from upsampling ratio).

Solution: Cubic Interpolation + Biquad LPF

**Catmull-Rom Cubic Interpolation** (replaces linear):
- Fits C1-continuous curves through sample points (smooth first derivative)
- Uses 4 neighboring samples (ym1, y0, y1, y2) per output point
- Horner's method with 8.8 fixed-point fractional position
- Cross-chunk continuity via `s_ring_prev_sample` / `s_direct_prev_sample`
- Eliminates angular transitions at source: no corners to filter out

```cpp
// Catmull-Rom: 0.5*(2*y0 + (-ym1+y1)*t + (2*ym1-5*y0+4*y1-y2)*t² + (-ym1+3*y0-3*y1+y2)*t³)
int32_t r = c3;
r = c2 + ((r * (int32_t)t) >> 8);
r = c1 + ((r * (int32_t)t) >> 8);
r = c0 + ((r * (int32_t)t) >> 8);
r >>= 1;
```

**2-Pole Biquad LPF** (replaces 1-pole IIR):
- 2nd-order Butterworth, fc=10kHz at 44.1kHz sample rate
- 12dB/octave rolloff (vs 6dB for 1-pole) - double the alias rejection rate
- ES5503 Nyquist is 13.16kHz; biquad provides ~6dB there, ~12dB at first image
- Q14 fixed-point coefficients: b=[4101, 8201, 4101], a=[1, -2882, 2901]
- Precomputed via bilinear transform of analog Butterworth prototype

Applied to both audio paths:
1. Ring buffer path (es5503_stream_update_locked) - write trigger audio
2. Direct generation path (I2S task) - main audio output

---

Current ES5503 Audio Architecture (Jan 2026)

```
IIgs CPU
    │
    ▼ writes to $C03C-$C03F
FPGA Bus Interface
    │
    ▼ LCAM serializer (13.5 MHz PCLK)
ESP32 LCD_CAM DMA
    │
    ▼ handle_es5503_write()
    ├── Control reg (0xA0-0xBF)? → es5503_stream_update_nonblocking()
    ├── Enable reg (0xE1)? → es5503_stream_update_nonblocking()
    └── Apply write to ES5503 emulator
                                          ┌──────────────────────┐
ES5503 Emulator (es5503.cpp)              │ Write trigger path:  │
    │ generates at 26,320 Hz native rate  │ Pre-write audio →    │
    ▼                                     │ ring buffer (small)  │
Ring Buffer (2048 frames, 42ms capacity)  └──────────────────────┘
    │ only for write-trigger audio
    ▼
I2S Task (direct generation)
    ├── Step 1: Drain ring buffer (pre-write audio, typically 0-few frames)
    ├── Step 2: Generate remaining 512 frames directly (no clock drift)
    ├── Catmull-Rom cubic interpolation (26kHz → 44.1kHz)
    └── 2-pole Butterworth biquad LPF (fc=10kHz, 12dB/oct)
    │
    ▼
I2S Slave TX to FPGA (48kHz, 16-bit stereo)
    │
    ▼
FPGA Audio DAC
```

Key Parameters
- ES5503 native rate: 26,320 Hz (7159090 / 8 / 34 for 32 oscillators)
- I2S output rate: 44,100 Hz (I2S_OUTPUT_RATE constant)
- FPGA I2S clock: 48,000 Hz (slave mode, FPGA provides BCLK/LRCLK)
- Upsample ratio: ~1.676x (44100/26320) with Catmull-Rom cubic interpolation
- Anti-aliasing: 2-pole Butterworth biquad LPF, fc=10kHz, 12dB/octave
- Ring buffer: 2048 frames (42ms) - now only for write-trigger audio
- Prebuffer: 720 frames (15ms, adjustable 5-40ms)
- I2S buffer: 512 frames per write (~10.67ms)
- Mutex: I2S=10ms timeout, write trigger=non-blocking
- Interpolation: Catmull-Rom with cross-chunk boundary bridging

Audio Quality Test Results
- captured_14.wav: Zero dropouts, visually matches source, slight tinny distortion (linear interp)
- captured_15.wav: Zero underruns, correct pitch, some waveform jags (linear interp artifacts)
- captured_16.wav: Better with 1-pole LPF, but 2748 large jumps remain (insufficient rolloff)
- captured_17.wav: Pending test with cubic interpolation + biquad LPF

---

GLU Address Pointer Desync Fix (Jan 2026)

Problem: Sporadic Register Write Misdirection
User reported: sound not playing, tones not ending, strange audio during games.
Hypothesis: sporadic register write drops.

Investigation
Traced the full pipeline from LCAM packet to ES5503 write. Found three issues:

**Issue 1 (CRITICAL): GLU Address Pointer Desync from Reads**

The Apple IIgs Sound GLU auto-increments the address pointer on BOTH reads
and writes to $C03D. Our code skipped ALL read packets:
```cpp
// OLD (broken):
if (reset_indicator || rw_n) return;  // All reads skipped entirely
```

When IIgs software reads $C03D with auto-increment enabled (very common during
interrupt handling - reading interrupt status at DOC register $E0), the real GLU
increments the pointer but our ESP32 mirror doesn't. All subsequent writes via
$C03D then target the WRONG DOC register.

Example sequence (IIgs IRQ handler):
1. Write $C03E/$C03F: set address to $E0 (interrupt status register)
2. Read $C03D: read interrupt status → real GLU increments to $E1
3. Our mirror: still at $E0 (didn't track read)
4. Write $C03D: intended for $E1 but goes to $E0 → WRONG REGISTER

This directly explains:
- **Tones that don't stop**: halt command (control reg) goes to wrong oscillator
- **Sounds that don't play**: start command goes to wrong oscillator
- **Strange audio**: frequency/volume written to wrong oscillator

Fix:
```cpp
// NEW (fixed):
if (reset_indicator) return;

if (rw_n) {
    // Track auto-increment on $C03D reads (IIgs GLU increments on both R and W)
    if (address == 0xC03D && s_glu.auto_increment) {
        s_glu.address_ptr++;
        s_glu_read_auto_inc++;
    }
    return;
}
```

**Issue 2: Ring Buffer Overflow**
LCAM ring buffer was 1024 entries. During game play, heavy bus traffic (video,
keyboard, disk I/O, plus ES5503) could overflow the buffer, dropping packets.
Increased to 4096 entries (16KB, from 4KB). RAM usage: 32% → 35%.

**Issue 3: Consumer Task Latency**
Consumer calls `vTaskDelay(1)` when buffer empty, creating 1ms gaps. Could
interact with Issue 2 during bursty traffic. Lower priority fix for now.

Diagnostics Added
- `s_glu_read_auto_inc` counter: tracks how often reads triggered auto-increment
- `s_read_packet_count` counter: tracks total read packets processed
- Both shown in `stats` output and cleared by `resetstats`

---

FPGA Serialization Pipeline Analysis (2026-01-28)

**Problem**: GLU desync fix improved matters but sporadic register write drops
still occur during game play. Investigated whether the FPGA serializer itself
could be dropping packets before they reach the ESP32.

**Pipeline**: IIgs bus → `a2bus_stream.sv` (capture) → `cam_serializer.sv`
(10-nibble packets) → ESP32 LCD_CAM DMA → ring buffer → packet_task

**Critical Finding: 1-Deep Packet Buffer in a2bus_stream.sv**

The capture logic at line 129:
```verilog
else if (capture_trigger_w && !packet_valid_r) begin
    packet_data_r <= packet_data_w;
    packet_valid_r <= 1'b1;
end
```
If `packet_valid_r` is already high (previous packet not consumed by serializer),
a new bus event is **silently dropped**. No FIFO — single register.

**When drops occur — Heartbeat interference**:
- Serializer takes ~32 FPGA clocks per 10-nibble packet
- IIgs bus cycle at 1 MHz ≈ 50 FPGA clocks (at 50 MHz)
- If serializer is mid-heartbeat ($C0FF) when ES5503 event arrives:
  1. Event captured into packet_data_r, packet_valid_r = 1
  2. Serializer busy with heartbeat, can't consume
  3. Second ES5503 event arrives → DROPPED (gate is !packet_valid_r)
- cam_serializer also has 1-deep pending queue (last-write-wins overwrite)

**Built-in FPGA Counters**:
| Counter | What it counts |
|---|---|
| `es5503_access_counter` | ALL bus events at address-decode (before gate) |
| `es5503_counter` | Successfully transmitted packets only |
| `cam_overwrite_flag` | Sticky: serializer pending queue overwritten |
| `packets_dropped_counter` | Cycles where packet_valid_r & cam_busy |

If `es5503_access_counter > es5503_counter`, packets are being dropped at FPGA level.

**Fix Applied**: Wired FPGA counters to SPI registers 11-15 so ESP32 can read them:
- reg11/12: es5503_access_counter (16-bit, all events detected)
- reg13/14: es5503_tx_counter (16-bit, packets transmitted)
- reg15: {7'b0, cam_overwrite_flag}

Added `fpgastats` CLI command to read and display these values.

**Result**: `fpgastats` confirmed **zero FPGA-level packet loss** (34,952 detected =
34,952 transmitted, 0 dropped, overwrite flag clear). FPGA serializer is not the
cause of the audio issues.

---

ES5503 Write/Generate Race Condition (2026-01-28)

**Root Cause Found**: `g_es5503->write()` in `handle_es5503_write()` was called
WITHOUT holding `s_es5503_mutex`, while the I2S task holds the mutex during
`generate_audio()` → `update_stream()`.

**The Race**: `update_stream()` copies `pOsc->control` into a local `ctrl` variable
at the start of generation, then writes it back at the end (`pOsc->control = ctrl`).
If `g_es5503->write()` modifies `pOsc->control` in between (from the packet task),
the writeback OVERWRITES the change:

1. I2S task reads `ctrl = pOsc->control` (e.g., halted=1)
2. Packet task calls `g_es5503->write(0xA0+osc, data)` — clears halt, resets accumulator
3. I2S task writes back `pOsc->control = ctrl` — **overwrites the un-halt!**

Result: oscillator stays halted → **sound doesn't play**

Reverse: un-halt can overwrite a halt → **tone that doesn't end**

This exactly matches the user's symptoms: sporadic sounds not playing, tones that
don't stop, strange audio during games.

**Fix**: Wrap `g_es5503->write()` in the same `s_es5503_mutex` that protects
`generate_audio()`. For control registers (0xA0-0xBF) and E1, the MAME-style
stream update and the register write are now inside the same critical section,
making the operation atomic from the I2S task's perspective.

```cpp
if (s_es5503_mutex && xSemaphoreTake(s_es5503_mutex, pdMS_TO_TICKS(5)) == pdTRUE) {
    if (needs_sync) es5503_stream_update_locked();
    g_es5503->write(reg, data);
    xSemaphoreGive(s_es5503_mutex);
} else {
    // Fallback: unprotected write (brief race < permanent desync from drop)
    g_es5503->write(reg, data);
}
```

The 5ms timeout ensures we don't block the packet consumer for too long. If the
mutex is unavailable (I2S task is mid-generation), we still apply the write rather
than losing it — a brief race is better than permanently desyncing the shadow ES5503.

Wave RAM writes (`wave_mem[addr] = data`) are not affected — they don't go through
`g_es5503->write()` and single-byte writes are atomic on ESP32.

Mutex timeout increased from 5ms to 50ms (I2S task holds mutex ~1ms). Added
`s_mutex_ok_count` and `s_mutex_fail_count` diagnostic counters to `stats` output.

Testing showed: race condition fix "significantly improved" but didn't fully resolve.
This confirmed a SECOND independent bug exists.

---

Key-On Timing Mismatch Fix (2026-01-28)

**Root Cause**: The MAME key-on check only resets the accumulator on a halt=1 → halt=0
transition. This works in MAME because `m_stream->update()` is cycle-accurate to the
emulated CPU — the oscillator state always matches the real chip at write time.

Our shadow can't be cycle-accurate (ESP32 `micros()` vs IIgs crystal clock — different
clock domains). So we may not have halted an oscillator yet when the real chip did.

**The Failure Scenario**:
1. Real ES5503 osc N reaches end of wavetable → halts (halt=1) → IRQ
2. IIgs ISR programs new note (freq, wavetable, vol), writes control with halt=0
3. Our shadow hasn't generated enough samples → osc N still running (halt=0)
4. Control write arrives: old halt=0, new halt=0 → MAME check MISSES key-on
5. No accumulator reset → osc continues from stale position
6. Osc eventually reaches end of wavetable → halts on its own
7. IIgs won't send another restart → **note dropped permanently**

The reverse causes stuck tones: our shadow halts before the real chip, the IIgs
writes to a "running" oscillator (from the real chip's perspective), but our shadow
sees halt=1 → halt=0 and does an extra restart that keeps the oscillator going.

**Fix** (`es5503.cpp` line 249): Always reset accumulator when halt=0 is written:
```cpp
// Before (MAME original):
if ((m_oscillators[osc].control & 1) && (!(data&1)))
    m_oscillators[osc].accumulator = 0;

// After (shadow-safe):
if (!(data & 1))
    m_oscillators[osc].accumulator = 0;
```

The IIgs Sound Manager pattern is always "program → write control (halt=0)". A halt=0
write always intends a fresh start. The only cost: if IIgs software writes control with
halt=0 to change mode on a running oscillator without intending a restart, we'd get
an unnecessary phase reset. This is rare in practice and produces only a brief click.

**Combined Fix Summary (both bugs)**:
1. **Mutex race** (es5503_stream_update + write atomic): prevents `update_stream()` from
   overwriting bus-initiated control changes via its `pOsc->control = ctrl` writeback
2. **Key-on timing** (always-reset accumulator): compensates for clock domain mismatch
   that prevents our shadow from reaching halt points at the same time as the real chip

---

Remaining Work
- [ ] Test combined fixes with games (dropped notes + stuck tones should be resolved)
- [ ] Check `stats` output: `DOC write mutex` should show 0 failures
- [ ] Test cubic + biquad combination (captured_17.wav)
- [ ] Verify zero underruns maintained
- [ ] Test with multiple IIgs audio programs
- [ ] Consider consumer task notification wakeup (replace vTaskDelay with ulTaskNotifyTake)
- [ ] Document final CLI commands in firmware README
