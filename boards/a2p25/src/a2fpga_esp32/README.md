ESP32 Firmware (A2P25) — LCAM Checklist

Quick Build/Flash
- Build: `make -C boards/a2p25/src/a2fpga_esp32 compile`
- Flash: `make -C boards/a2p25/src/a2fpga_esp32 flash PORT=/dev/tty.usbmodemXXXX`
- Monitor: `make -C boards/a2p25/src/a2fpga_esp32 monitor PORT=/dev/tty.usbmodemXXXX`

Console Commands (type +++ to enter)
- `status` / `stats`: print LCAM and bus statistics
- `lcammode vs` | `lcammode len`: select VSYNC‑EOF or length‑EOF mode
- `i2sstart` | `i2sstop`: enable/disable slave‑TX (for concurrency testing)
- `addrwin $C000-$C0FF`: set alignment scoring window (length‑EOF only)
- `lcampreset normal|canon`: presets (normal = VSYNC‑EOF, quiet logs; canon = length‑EOF, quiet logs)
- ES5503 audio:
  - `es5503start` / `es5503stop`: enable/disable ES5503 audio (auto‑starts I2S on start)
  - `audiostop`: halt all ES5503 oscillators (silence)
  - `es5503info`: show oscillators + GLU counters + ES write mirror totals
  - `es5503reg <reg> [val]`: read/write ES5503 register (accepts $E1, 0xE1, or E1)
  - `es5503mem <addr> [len]`: dump ES5503 wave RAM
  - `es5503resetwrite`: reset GLU/ES write counters (does not clear wave RAM)
  - `fulltest`: load sine and play via ES5503
  - `starttone` / `stoptone`: simple I2S tone generator (path sanity)

Recommended Defaults
- Mode: VSYNC‑EOF (requires FPGA gated VSYNC every 409 packets and final VSYNC at end‑of‑burst)
- `CHUNK_BYTES = 4090`, `DESC_COUNT = 8`, `GDMA_CH = 2`
- VSYNC glitch filter enabled on LCD_CAM

IIgs Burst Test (Expected Results)
- Setup: Run the 32,768‑write assembly loop to `$C03D` on the IIgs.
- On ESP32:
  1) `status` (confirm capture running)
  2) `lcammode vs`
  3) After burst ends, `stats`
- Pass criteria:
  - Words received (non‑heartbeat): 32768
  - Corruption rate: 0.0%
  - Words captured (EOF count): ~80–81
  - Ring buffer drops: 0

Fallback (length‑EOF)
- Use `lcammode len` and keep alignment/stitching enabled.
- Sender pads dummies until `bytes_sent % CHUNK_BYTES == 0` to flush final tail.
- Expected: 32768 received, 0.0% corruption, drops=0.

Stability/Recovery
- If starting I2S causes LCD_CAM to stop:
  - Ensure `GDMA_CH=2`, then `i2sstop`/`i2sstart`.
  - The poller auto‑recovers LCD_CAM (`lcdcam_recover_if_needed`).

More Details
- See `boards/a2p25/docs/LCAM_SESSION_NOTES.md` for architecture, rationale, and deeper troubleshooting.

IIgs Stress Test Program
- Assembly (native mode burst writes to `$C03D` at max speed):
  ; enter native mode (if coming from emulation)
  CLC
  XCE

  ; A=8-bit, X/Y=16-bit
  SEP   #$20
  REP   #$10

  ; DBR = $00 so absolute uses bank $00
  LDA   #$00
  PHA
  PLB

  ; 32768 iterations of STZ $C03D
  LDX   #$8000
@loop:
  STZ   $C03D
  DEX
  BNE   @loop

  RTS

- Bytes (for quick entry/verification):
  0300: 18 FB E2 20 C2 10 A9 00 48 AB A2 00 80 9C 3D C0
  0310: CA D0 FA 60

Quick Reference (What “Good” Looks Like)
- Mode: VSYNC‑EOF
- Words received (non‑heartbeat): 32768
- Corruption rate: 0.0%
- Words captured (EOF count): ~80–81
- Ring buffer drops: 0
- With I2S active: Same as above; LCD_CAM continues streaming

Example: Passing Stats (VSYNC‑EOF)
  Bus packet statistics:
    Total packets: 32768
    Write packets: 32768
    Read packets: 0
    ES5503 packets: 32768
    Corrupted packets: 0
    Address range: $C03D-$C03D
    Corruption rate: 0.0%
  LCD_CAM statistics:
    Words captured: 80 (total by LCD_CAM)
    Words received: 32768 (non-heartbeat only)
    Ring buffer drops: 0
    Drop rate: 0.0%
    LCD_CAM mode: VSYNC-EOF, addr window: $C000-$C0FF

Common Pitfalls and Quick Fixes
- Words received < 32768 (VSYNC‑EOF):
  - Ensure FPGA gates VSYNC every 409 packets and asserts one final VSYNC at end of burst.
  - Verify VSYNC glitch filter is enabled on ESP32 (cam_vsync_filter_thres = 1).
- Words received < 32768 (length‑EOF):
  - Enable tail flush on sender: pad dummy packets until `bytes_sent % CHUNK_BYTES == 0`.
  - Keep alignment detection and cross‑boundary stitching enabled.
- Non‑zero corruption:
  - VSYNC‑EOF: alignment/stitching should be disabled; re‑select `lcammode vs`.
  - Length‑EOF: ensure alignment detector converges (use `addrwin $C000-$C0FF`).
- LCD_CAM stops after `i2sstart`:
  - Confirm `GDMA_CH=2` for LCD_CAM; background recovery should re‑arm inlink automatically.
  - Try `i2sstop` then `i2sstart` and recheck `status`.

ES5503 Bring‑Up Tips
- Silence with running voice: wave bytes are 0x80 (DC zero). Voice won’t halt, but outputs 0. Ensure non‑0x80 content in the voice’s wave region.
- Immediate halt: a 0x00 byte halts the voice; ensure first non‑zero sample after key‑on.
- E1 enables voices: set `E1=(N-1)<<1` to enable N voices.
- Compare ES bytes with OSD: `es5503resetwrite` → playback → `es5503info` → “ES writes (FPGA‑mirror): total=…”. This matches OSD delta per playback.

Presets for Speed
- `lcampreset normal`: VSYNC‑EOF + quiet logging. Use for most runs.
- `lcampreset canon`: length‑EOF + quiet logging. Use for "pretty" EOF stats; sender should pad to CHUNK_BYTES boundary.

Mode Selection Guide
- Prefer VSYNC‑EOF if FPGA can provide gated VSYNC every 409 packets plus a final VSYNC; yields lowest CPU overhead and natural alignment.
- Use length‑EOF when VSYNC gating isn’t available; rely on alignment/stitching and tail flush on sender for exact counts.

Key Tunables (ESP32)
- `CHUNK_BYTES` (default 4090): must be a multiple of 10 for packet alignment.
- `DESC_COUNT` (≥ 8): increase to absorb bursty CPU load.
- `GDMA_CH=2`: isolates LCD_CAM from I2S usage.
- `cam_vsync_filter_thres=1`: reduces spurious EOFs from short VSYNC glitches.

I2S Concurrency Check
1) Start capture (`lcammode vs`) and confirm stats increment.
2) Run `i2sstart`; verify LCD_CAM continues (no drop in Words captured/received growth).
3) After burst, confirm pass criteria still met.
