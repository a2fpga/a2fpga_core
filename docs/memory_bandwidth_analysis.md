# Memory Bandwidth Analysis — A2N20v2-GS (SDRAM) & A2Mega (DDR3)

## Context

Both boards currently use their external memory exclusively for framebuffer storage.
Two expansion scenarios are under consideration:

1. **A2N20v2-GS**: Move Apple II shadow memory from BSRAM to SDRAM (freeing BSRAM — currently 44/46 = 96% full)
2. **A2Mega**: Move Ensoniq DOC5503 64 KB sound RAM from BSRAM to DDR3 (freeing BSRAM — currently 107/118 = 91% full)

This document presents the current bandwidth budget and projected utilization under each scenario to determine feasibility.

---

## 1. A2N20v2-GS — SDRAM Bandwidth Budget

### Hardware Parameters

| Parameter | Value |
|-----------|-------|
| SDRAM Clock | 108 MHz |
| Data Width | 32 bits |
| Peak Bandwidth | 108 MHz × 32 bits = **3,456 Mbps (432 MB/s)** |
| Logic Clock | 54 MHz (CLKDIV2 from 108 MHz) |
| Pixel Clock | 27 MHz |
| CAS Latency | 2 cycles @ 108 MHz |
| Burst Length | 2 words (SDRAM), 1 word (port) |
| tRCD (activate) | 18 ns → 2 cycles |
| tRP (precharge) | 18 ns → 2 cycles |
| tWR + tRP | 16 + 18 = 34 ns → 4 cycles |
| tRFC (refresh) | 80 ns → 9 cycles |
| Refresh interval | 15 µs → ~810 cycles between refreshes |

### Transaction Overhead

Each SDRAM transaction (single-word read or write) costs:

| Phase | Cycles @ 108 MHz |
|-------|-----------------|
| Activate row | 1 (command) + 1 (tRCD delay) = 2 |
| Read/Write command | 1 |
| CAS latency (read only) | 2 |
| Auto-precharge recovery | 2 (read) or 4 (write) |
| **Total read** | **~7 cycles = 65 ns** |
| **Total write** | **~7 cycles = 65 ns** |

Effective single-transaction throughput: 32 bits / 7 cycles @ 108 MHz = **494 Mbps per port** (if sole user).

With 4 ports sharing, arbitration adds 0–1 cycles per transaction depending on contention.

### Current Port Configuration (4 ports, priority order)

| Port | Use | Priority |
|------|-----|----------|
| 0 — FB_READ | Framebuffer line prefetch | Highest |
| 1 — FB_WRITE | Framebuffer pixel writes | |
| 2 — DOC_MEM | Ensoniq wavetable reads | |
| 3 — GLU_MEM | Ensoniq sound RAM writes | Lowest |

### Current Bandwidth Utilization

#### Framebuffer Writes

- Pixel packing: 2× RGB565 pixels per 32-bit word
- Apple II mode: 560 pixels/line × 192 lines × 60 Hz = 6.45 Mpixels/s → **3.225 Mwords/s × 7 cyc = 22.6 Mcyc/s**
- VGC mode: 640 × 200 × 60 Hz = 7.68 Mpixels/s → **3.84 Mwords/s × 7 cyc = 26.9 Mcyc/s**

#### Framebuffer Reads

- Same pixel count as writes (each pixel written must be read once for display)
- Apple II: 3.225 Mwords/s, but burst-2 reads (FB_READ_BURST_WORDS=2) reduce transactions
  - 1.6125 Mtransactions/s × ~9 cyc (burst-2 overhead) = **14.5 Mcyc/s**
- VGC: 1.92 Mtransactions/s × 9 cyc = **17.3 Mcyc/s**

#### Ensoniq DOC5503 Reads

- DOC clock: 7.159 MHz ÷ 8 = ~894.9 kHz oscillator cycle rate
- 32 oscillators, 1 wavetable read per osc per cycle
- Effective: up to ~894.9K reads/s (but only active oscillators read)
- Worst case (32 active): 894.9K × 7 cyc = **6.3 Mcyc/s**
- Typical (8 active): ~1.6 Mcyc/s

#### Ensoniq GLU Writes

- CPU-driven, ~1 MHz Apple II bus rate, only on explicit $C03C writes
- Negligible: < 0.1 Mcyc/s

#### Refresh Overhead

- 8,192 refreshes per 64 ms = 128K refreshes/s
- Each refresh: ~9 cycles
- Total: 128K × 9 = **1.15 Mcyc/s**

### Current Budget Summary

| Component | Mcyc/s (Apple II) | Mcyc/s (VGC) | % of 108M |
|-----------|-------------------|---------------|-----------|
| FB Write | 22.6 | 26.9 | 21–25% |
| FB Read (burst-2) | 14.5 | 17.3 | 13–16% |
| Ensoniq DOC (8 osc) | 1.6 | 1.6 | 1.5% |
| Ensoniq GLU | <0.1 | <0.1 | <0.1% |
| Refresh | 1.15 | 1.15 | 1.1% |
| **Total** | **~40** | **~47** | **37–44%** |
| **Headroom** | **~68** | **~61** | **56–63%** |

### Projected: Add Shadow Memory to SDRAM

#### Shadow Memory Requirements

Current BSRAM allocation in `apple_memory.sv`:

| Block | Address Width | Words | Size | BSRAM Blocks |
|-------|-------------|-------|------|-------------|
| Text (main+aux interleaved) | 10 bits | 1,024 | 4 KB | ~2 |
| Hires Main (0x2000-0x5FFF) | 12 bits | 4,096 | 16 KB | ~8 |
| Hires Aux (0x2000-0x5FFF) | 12 bits | 4,096 | 16 KB | ~8 |
| Hires Aux VGC (0x6000-0x9FFF) | 12 bits | 4,096 | 16 KB | ~8 |
| **Total** | | | **52 KB** | **~26** |

Freeing ~26 of 44 BSRAM blocks would drop utilization from 96% to ~39%.

#### Shadow Memory Access Pattern

**Writes** (Apple II CPU → shadow RAM):
- Rate: 1 MHz Apple II bus, not every cycle is a write to video-range addresses
- Worst case: every phi1 cycle writes to video RAM → 1M writes/s
- Realistic: ~200K–500K writes/s (most bus cycles are instruction fetches, not VRAM writes)
- Each write: 1 SDRAM transaction (32-bit word with byte enables)
- Cost: 500K × 7 cyc = **3.5 Mcyc/s** (worst realistic)

**Reads** (video generators ← shadow RAM):
- `apple_video_gen` reads via `video_address_o` / `video_rd_o` — returns 32-bit words
- Apple II video fetches 40 bytes per scanline in all modes:
  - 40-col modes (TEXT40, LORES40, HIRES40): 40 bytes = 20 reads of 32-bit words (2 bytes each)
  - 80-col modes (TEXT80, LORES80, HIRES80/DHGR): 40 main + 40 aux bytes, but
    `interleave_mux()` returns main+aux interleaved in a single 32-bit read — still 20 reads
  - apple_video_gen uses 20 chunks/line, 1 memory read per chunk = **20 reads per line**
- Read rate: 20 reads/line × 192 lines × 60 Hz = **230.4K reads/s × 7 cyc = 1.61 Mcyc/s**
- VGC reads via `vgc_address_o` / `vgc_rd_o`:
  - IIgs SHR: 160 bytes/line (320×200 @ 4bpp or 640×200 @ 2bpp = 160 bytes either way)
  - 32-bit reads → 40 pixel data reads + 1 SCB read + 8 palette reads = **49 reads per line**
  - 49 × 200 × 60 = **588K reads/s × 7 cyc = 4.12 Mcyc/s**
  - **However**: VGC stays in BSRAM (see below), so VGC reads add zero SDRAM load

#### Latency Analysis: Line-Level Budget vs Per-Read Latency

The original analysis overstated the latency challenge. The correct framing is
**line-level timing**, not per-read cycle count.

**Real Apple II hardware context:**
- 1 video byte fetch per 1 MHz clock = 1,000 ns per byte
- 40 bytes per line (hires 40-col) = 40 µs of the 63.5 µs line period
- 80 bytes per line (80-col/DHGR) = interleaved from two banks at 1 MHz

**Our design:**
- BSRAM reads: 32-bit word (4 bytes) in 2 logic cycles = 37 ns → **27× faster than real hardware**
- SDRAM reads: 32-bit word in ~7 logic cycles = 130 ns → **7.7× faster per byte, 30× accounting for 4-byte word**

**`scan_timer` drives hsync from `a2bus_if.extended_cycle`** — the Apple II long cycle
marking horizontal boundaries. This gives ~63.5 µs = **~3,429 clk_logic cycles per line**.

##### apple_video_gen Timing

Fetch runs **concurrently** with pixel output (pipelined):
- 20 chunks per line, 28 rendered pixels per chunk, 1 memory read per chunk
- Pixel output: 28 × GAP_CYCLES(4) = **112 logic cycles per chunk**
- Memory fetch per chunk: 4 cycles (BSRAM) or ~7 cycles (SDRAM) for graphics modes
- TEXT80 worst case: 10 cycles (BSRAM) or ~13 cycles (SDRAM, char ROM still BSRAM)
- **Fetch always finishes within first 13 of 112 available cycles → 99 cycles slack**
- Total memory reads per line: 20 (one per chunk), regardless of mode
- Only the priming fetch (chunk 0) adds to total line time
- Total line time increase: ~3–4 cycles (priming only). **Negligible.**

80-col/DHGR: `apple_memory.sv` `interleave_mux()` returns main+aux interleaved
in a single 32-bit read — **no separate aux fetch required**. The two sdpram32
instances (hires_main, hires_aux) have independent read ports read simultaneously.
This matches real Apple II hardware: 40 bytes per scanline in all modes. 80-col/DHGR
reads 40 main + 40 aux bytes, but our 32-bit word packs both into 20 reads.

##### vgc_gen Timing

**VGC stays in BSRAM** (see VGC Interleave Design below), so this is informational only.

Fetch is **sequential** with pixel output (not pipelined):
- IIgs SHR always reads 160 bytes/line (320×200 @ 4bpp or 640×200 @ 2bpp)
- 32-bit reads → 40 pixel data words per line
- Plus 1 SCB read + 8 palette reads = 49 total reads per line
- Each pixel word outputs 16 pixels: 16 × GAP_CYCLES(4) = 64 cycles

| Phase | BSRAM (current) | Cycles |
|-------|-----------------|--------|
| SCB fetch | 1 read × 4 cyc | 4 |
| Palette | 8 reads × 5 cyc | 40 |
| Pixel render | 40 × (4 fetch + 64 output) = 2,720 | 2,720 |
| **Total line** | | **2,764 cyc** |
| **Budget** | | **3,429 cyc** |
| **Slack** | | **665 cyc (19%)** |

Since VGC stays in BSRAM, these timings are unchanged by the shadow → SDRAM migration.

##### Required State Machine Changes

The change is **not a pipeline redesign** — it's replacing fixed wait-state
counting with a data-ready handshake:

**apple_video_gen** (`fe_step_r` state machine):
- Current: steps 1,2 are fixed delay cycles, step 3 captures data
- New: steps 1+ wait for `video_data_ready_i` signal, then capture
- Everything else unchanged — pipelined fetch/expand stays as-is

**vgc_gen** (`fetch_step_r` state machine):
- Current: steps 1,2 are fixed delay, step 3 captures data
- New: steps 1+ wait for `vgc_data_ready_i` signal, then capture
- Pixel output in step 4 unchanged

**apple_memory.sv**:
- Replace sdpram32 instances with mem_port_if connections to SDRAM ports
- Add `video_data_ready_o` / `vgc_data_ready_o` signals driven by mem_port_if.ready
- Write path: CPU writes go through mem_port_if instead of direct BSRAM
- Read mux and interleave_mux logic preserved, just sourced from SDRAM responses

#### Projected Budget with Shadow Memory

Shadow reads are only for `apple_video_gen` (20 reads/line). VGC stays in BSRAM (0 SDRAM reads).

| Component | Mcyc/s (Apple II) | Mcyc/s (VGC) | % of 108M |
|-----------|-------------------|---------------|-----------|
| FB Write | 22.6 | 26.9 | 21–25% |
| FB Read (burst-2) | 14.5 | 17.3 | 13–16% |
| Shadow Write (CPU) | 3.5 | 3.5 | 3.2% |
| Shadow Read (apple_video_gen) | 1.6 | 1.6 | 1.5% |
| Ensoniq DOC | 1.6 | 1.6 | 1.5% |
| Ensoniq GLU | <0.1 | <0.1 | <0.1% |
| Refresh | 1.15 | 1.15 | 1.1% |
| **Total** | **~45** | **~51** | **42–47%** |
| **Headroom** | **~63** | **~57** | **53–58%** |

**Verdict: Both bandwidth and latency are easily feasible.**

1. **Shadow memory adds minimal SDRAM load.** Only 20 reads/line from apple_video_gen
   (230K reads/s = 1.6 Mcyc/s). Real Apple II hardware reads only 40 bytes per scanline
   in all modes; our 32-bit words halve that to 20 reads. VGC stays in BSRAM, adding
   zero SDRAM load.
2. **Latency is NOT a challenge.** Line-level timing budget (~3,429 cycles) dwarfs
   the per-read latency increase (4 → 7 cycles). apple_video_gen has 112 logic cycles
   per chunk but only needs 7 for the SDRAM fetch — 105 cycles of slack.
   Only a wait-state change (fixed count → ready handshake) is needed, not pipeline redesign.
3. **Port count increases.** Need 2 more ports (shadow read, shadow write) → 6 total.
   The arbiter supports this but contention probability increases.
4. **BSRAM savings**: freeing ~10 blocks (96% → 74%) with VGC BRAMs retained.
5. **80-col/DHGR modes are already optimized**: single 32-bit read fetches both main+aux
   via interleave_mux — still just 20 reads per line, same as 40-col modes.

#### Reference: a2n20v2-Enhanced Board (Working SDRAM Video Implementation)

The Enhanced board (`boards/a2n20v2-Enhanced/`) already implements video reads from SDRAM,
providing a proven reference for the GS board migration.

**Enhanced board architecture** (`boards/a2n20v2-Enhanced/hdl/memory/apple_memory.sv`):

- **2 SDRAM ports** (vs GS's 4): VIDEO_MEM_PORT=0 (reads), MAIN_MEM_PORT=1 (writes)
- **Single 54 MHz clock** (no CDC needed — simpler than GS's 108/54 split)
- **Uses `apple_video.sv`** (real-time renderer, not `apple_video_gen.sv` pixel-stream)
- **VGC stays in BSRAM** — two sdpram32 blocks for interleaved aux reads

**SDRAM storage layout** (interleaved main+aux by byte position):

```
CPU write:  addr = {6'b0, bus_addr[15:1]}
            byte_en = 1'b1 << {addr[0], aux_mem_r || m2b0}
                       ↑ bank encoded in byte position within 32-bit word

Video read: addr = {5'b0, video_bank_i, video_address_i[15:1]}
            → returns 32-bit word with main+aux interleaved by byte position
            → video_data_o = video_mem_if.q  (direct pass-through)
```

**Key insight**: The CPU write path uses `byte_en` to place each byte at the correct
position within the 32-bit SDRAM word, encoding `{addr_lsb, bank_select}` into the
byte lane. The video read returns the full 32-bit word — main and aux bytes are already
interleaved. No separate aux fetch needed.

**apple_video.sv latency handling**: Issues read at step 0, latches data at step 14
(14 pixel clocks = ~518 ns later). No explicit wait states — the pipeline geometry
absorbs SDRAM latency naturally.

**Implication for GS board**: The `apple_video_gen.sv` fetch pipeline has even more
slack (112 logic cycles per chunk vs Enhanced's 28 pixel clocks). The GS migration
can follow the same SDRAM storage layout and byte_en encoding.

#### VGC Interleave Design: Detailed Analysis

##### Current BSRAM Architecture

VGC reads go through `apple_memory.sv`:
```
hires_aux_read_offset = vgc_address_i[12:1]  // shared 12-bit address into BOTH BRAMs
vgc_data_o = interleave_mux(vgc_address_i[0], hires_data_aux, hires_data_aux_6000_9FFF)
```
Two BRAMs read at the same address; `vgc_address_i[0]` selects which byte pair.

**VGC 13-bit address space** (8192 words × 4 bytes = 32 KB):
- Pixel data: addresses 0–7999 (40 words/line × 200 lines)
- SCBs: 8000–8063 (64 entries, 4 per word = 16 words)
- Palette: 8064–8191 (16 palettes × 8 words)

##### LINEARIZE_MODE Byte Mapping (Traced)

In LINEARIZE_MODE, CPU writes to $2000–$9FFF with E1=1 produce:
```
hires_write_offset[14:0] = {addr[15:13]-1, addr[12:0]}  // 32K linear byte index

BSRAM_2000: addr = offset[14:3], byte_en = offset[0] ? 0 : (1 << offset[2:1])
BSRAM_6000: addr = offset[14:3], byte_en = offset[0] ? (1 << offset[2:1]) : 0
```
Consecutive bytes (offsets 0–7) are stored as:
```
offset 0 → BSRAM_2000[0] byte 0    offset 4 → BSRAM_2000[0] byte 2
offset 1 → BSRAM_6000[0] byte 0    offset 5 → BSRAM_6000[0] byte 2
offset 2 → BSRAM_2000[0] byte 1    offset 6 → BSRAM_2000[0] byte 3
offset 3 → BSRAM_6000[0] byte 1    offset 7 → BSRAM_6000[0] byte 3
```

VGC reads reconstruct 4 consecutive bytes via interleave_mux:
```
vgc_addr=0 (bit[0]=0): interleave_mux(0, BSRAM_2000[0], BSRAM_6000[0])
  = {BSRAM_6000[15:8], BSRAM_2000[15:8], BSRAM_6000[7:0], BSRAM_2000[7:0]}
  = {offset_3, offset_2, offset_1, offset_0}  ✓ bytes 0-3 in order

vgc_addr=1 (bit[0]=1): interleave_mux(1, BSRAM_2000[0], BSRAM_6000[0])
  = {offset_7, offset_6, offset_5, offset_4}  ✓ bytes 4-7 in order
```

##### Why Pre-Interleaved SDRAM Storage Won't Work for VGC

A pre-interleaved SDRAM approach (storing VGC pixel data sequentially in SDRAM,
bypassing the two-BSRAM scheme) would require that CPU writes arrive in linearized
order. **However, real-world IIgs software writes to non-linearized memory addresses
($2000-$5FFF, $6000-$9FFF as separate hires banks) BEFORE activating SHR mode.**
This was discovered during testing — the non-LINEARIZE_MODE path is not just a
legacy fallback; it's the initial state that real apps use during startup.

Because data arrives in non-linearized format and the `interleave_mux` reconstructs
the correct byte order at read time, the two-BSRAM architecture with read-time
interleaving is functionally required for VGC. Pre-interleaving at write time
would produce corrupted output when SHR mode activates on non-linearized data.

##### Recommended: VGC Stays in BSRAM (Enhanced Board Approach)

Follow the `a2n20v2-Enhanced` board's proven architecture:

**What moves to SDRAM:**
- Text main+aux (currently `text_vram` sdpram32, ADDR_WIDTH=10) → SDRAM
- Hires main (currently `hires_main_2000_5FFF` sdpram32, ADDR_WIDTH=12) → SDRAM
- Hires aux writes are DUPLICATED: written to SDRAM (interleaved with main for
  apple_video_gen 80-col/DHGR reads) AND to BSRAM (standalone for VGC reads)

**What stays in BSRAM:**
- `hires_aux_2000_5FFF` (ADDR_WIDTH=12) — needed for VGC interleave_mux
- `hires_aux_6000_9FFF` (ADDR_WIDTH=12, VGC_MEMORY=1) — needed for VGC interleave_mux

**SDRAM storage layout** (Enhanced board's byte_en encoding):
```
CPU write:  SDRAM_addr = {6'b0, bus_addr[15:1]}
            byte_en = 1'b1 << {addr[0], aux_mem_r || m2b0}
            → main and aux interleaved by byte position within 32-bit word

Video read: SDRAM_addr = {5'b0, video_bank_i, video_address_i[15:1]}
            → returns 32-bit word with main+aux interleaved
            → apple_video_gen gets correct data without interleave_mux
```

**Read paths:**
- `apple_video_gen` reads from SDRAM video port → interleaved main+aux in one read
- `vgc_gen` reads from BSRAM → interleave_mux(vgc_addr[0], data_2000, data_6000)
  → unchanged from current design

**Write paths:**
- CPU writes to main hires ($2000-$5FFF, !E1) → SDRAM only (1 write)
- CPU writes to aux hires ($2000-$5FFF, E1) → SDRAM + BSRAM_2000 (2 writes)
- CPU writes to aux hires ($6000-$9FFF, E1) → SDRAM + BSRAM_6000 (2 writes)
- CPU writes to text ($0400-$0BFF) → SDRAM only (1 write)
- Duplicate aux writes are negligible bandwidth (~200K-500K/s vs 108M SDRAM cycles/s)

**BSRAM savings:**

| Block | BSRAMs | Action |
|-------|--------|--------|
| text_vram (ADDR_WIDTH=10) | ~2 | → SDRAM (freed) |
| hires_main (ADDR_WIDTH=12) | ~8 | → SDRAM (freed) |
| hires_aux_2000 (ADDR_WIDTH=12) | ~8 | Keep in BSRAM (VGC) |
| hires_aux_6000 (ADDR_WIDTH=12) | ~8 | Keep in BSRAM (VGC) |
| **Total freed** | **~10** | **44 → 34/46 = 74%** |

While not as dramatic as a full migration (which would reach 39%), freeing 10 BSRAMs
drops utilization from 96% to 74% — giving 12 free blocks for future features.

**Key advantages of this approach:**
- Proven on Enhanced board — same SDRAM layout and byte_en encoding
- VGC path completely unchanged — no risk to SHR rendering
- `vgc_gen.sv` requires zero modifications
- `apple_video_gen.sv` only needs wait-state change (fixed count → ready handshake)
- Non-linearize compatibility preserved (VGC always reads from BSRAM)

---

## 2. A2Mega — DDR3 Bandwidth Budget

### Hardware Parameters

| Parameter | Value |
|-----------|-------|
| DDR3 PHY Clock | 297 MHz (from pll_ddr3) |
| App Interface Clock (clk_x1) | 74.25 MHz |
| DDR3 Data Width | 16 bits, BL=8 → 128 bits per burst |
| Peak Bandwidth | 74.25 MHz × 128 bits = **9,504 Mbps (1,188 MB/s)** |
| Logic Clock (clk) | 54 MHz |
| Pixel Clock (clk_pixel) | 27 MHz |
| CL/CWL | 5 cycles @ DDR3 internal |
| App cmd latency (read) | ~15–20 clk_x1 cycles from cmd to data_valid |
| App cmd latency (write) | ~2 clk_x1 cycles (cmd + data accepted same cycle) |

### Current DDR3 Architecture

The DDR3 controller has a **single command port** (not multi-port like the SDRAM).
All access is serialized through `app_cmd` / `app_addr` / `app_en` in the `ddr3_framebuffer_480p` module.

The framebuffer module implements its own internal arbiter:
- **Write batches**: Groups of 8 writes from async FIFO (4 pixels × 18 bits each → 72-bit entries)
- **Read line fetches**: Burst of sequential reads to fill line buffer (up to 8 outstanding)
- **Priority**: Writes take precedence (writes block reads during batch)

### Transaction Details

**DDR3 Write (1 command):**
- Payload: 128 bits (4 × 32-bit pixel slots, only COLOR_BITS=18 used per slot)
- Latency: ~2 clk_x1 cycles (command + data accepted simultaneously)
- Batch: 8 commands per batch → 16 clk_x1 cycles per batch

**DDR3 Read (1 command):**
- Payload: 128 bits → 4 pixels unpacked into line buffer
- Latency: ~15–20 clk_x1 cycles from command to `app_rd_data_valid`
- Max outstanding: 8 reads (RD_MAX_OUTSTANDING)
- Line fetch: 560/4 = 140 reads for Apple II, 640/4 = 160 reads for VGC

### Current Bandwidth Utilization

#### Framebuffer Writes

- Async FIFO: 64 entries × 72 bits (4 pixels of 18-bit color each)
- Pixel input rate: 13.5 Mpixels/s (GAP_CYCLES=4, 54 MHz / 4)
- Group rate: 13.5M / 4 = 3.375M groups/s
- DDR3 commands: 3.375M × 1 cmd × 2 cyc = **6.75 Mcyc/s @ 74.25 MHz**

#### Framebuffer Reads

- Line fetches: 1 fetch per 2 HDMI lines (2× vertical scaling)
- Apple II: 140 reads × 240 fetches/frame × 60 Hz = 2.016M reads/s
  - Pipeline: 8 outstanding, ~20 cyc latency → effective ~5 cyc/read amortized
  - **~10.1 Mcyc/s @ 74.25 MHz**
- VGC: 160 × 200 × 60 = 1.92M reads → ~9.6 Mcyc/s

#### Total Current

| Component | Mcyc/s @ 74.25M (Apple II) | Mcyc/s (VGC) | % of 74.25M |
|-----------|---------------------------|--------------|-------------|
| FB Write batches | 6.75 | 6.75 | 9.1% |
| FB Read line fetches | 10.1 | 9.6 | 12.9–13.6% |
| DDR3 refresh (internal) | ~1.0 | ~1.0 | 1.3% |
| **Total** | **~17.9** | **~17.4** | **23–24%** |
| **Headroom** | **~56.4** | **~56.9** | **76–77%** |

### A2Mega BSRAM Breakdown

The a2mega uses 107/118 BSRAM blocks (91%). The largest consumers are:

| Block | ADDR_WIDTH | Size | BSRAM Blocks | Type |
|-------|-----------|------|-------------|------|
| Ensoniq sound_ram | 14 | 64 KB (16K × 32) | ~32 SDPB | mem_port_bram |
| hires_main_2000_5FFF | 12 | 16 KB (4K × 32) | ~8 SDPB | sdpram32 |
| hires_aux_2000_5FFF | 12 | 16 KB (4K × 32) | ~8 SDPB | sdpram32 |
| hires_aux_6000_9FFF | 12 | 16 KB (4K × 32) | ~8 SDPB | sdpram32 (VGC) |
| text_vram | 10 | 4 KB (1K × 32) | ~2 SDPB | sdpram32 |
| **Subtotal (movable to DDR3)** | | | **~58** | |
| Remaining (char ROM, line buf, FIFOs, etc.) | | | **~49** | Various |
| **Total** | | | **107** | |

The same VGC constraint applies: `hires_aux_2000_5FFF` and `hires_aux_6000_9FFF` must
stay in BSRAM for `interleave_mux` read-time interleaving (see Section 1 analysis).

### Projected: Move Ensoniq + Apple Video Shadow to DDR3

#### What Moves to DDR3

| Block | BSRAM Freed | Notes |
|-------|------------|-------|
| Ensoniq sound_ram (AW=14) | ~32 | DOC reads + GLU writes via DDR3 |
| text_vram (AW=10) | ~2 | CPU writes + apple_video_gen reads |
| hires_main_2000_5FFF (AW=12) | ~8 | CPU writes + apple_video_gen reads |
| **Total freed** | **~42** | **107 → 65/118 = 55%** |

| Block | BSRAM Kept | Notes |
|-------|-----------|-------|
| hires_aux_2000_5FFF (AW=12) | ~8 | VGC interleave_mux (required) |
| hires_aux_6000_9FFF (AW=12) | ~8 | VGC interleave_mux (required) |
| **Total kept for VGC** | **~16** | |

**BSRAM impact: 91% → 55%** — freeing 42 blocks gives 53 blocks available for future features.
This is the same VGC-stays-in-BSRAM approach proven on the Enhanced board, with the addition
of Ensoniq moving to DDR3 as well.

Aux hires writes are DUPLICATED to both DDR3 (interleaved with main for apple_video_gen
80-col/DHGR reads) and BSRAM (standalone for VGC reads), same as the GS board design.

#### Ensoniq Access Pattern

**DOC5503 wavetable reads:**
- DOC clock: 7.159 MHz, divided by 8 internally → 894.9 kHz oscillator cycle
- TICKS_PER_CYCLE = 54M / (7.159M / 8) = 54M / 894.9K ≈ 60 clk_logic ticks
- Each cycle processes 1 oscillator: read wavetable sample
- 32 oscillators max → up to 32 reads per 60-tick cycle = ~0.53 reads/clk_logic tick
- Effective read rate: 32 × 894.9K = **28.6K reads/s** (max, all 32 active)
- More typical (8 oscillators): ~7.2K reads/s

**GLU sound RAM writes:**
- CPU-driven via Apple II bus ($C03C–$C03F)
- Rate: sporadic, << 1M writes/s
- Typical: a few hundred writes when loading a wavetable, then quiet

**DOC latency budget:** The oscillator state machine has ~60 clk_logic ticks (1.1 µs)
per oscillator. DDR3 reads take ~20 clk_x1 cycles (~270 ns). 270 ns is well within
the 1.1 µs budget — **latency is acceptable**.

#### Apple Video Shadow Access Pattern

Same as the GS board analysis — 40 bytes per scanline in all Apple II modes:
- apple_video_gen: 20 chunks/line, 1 read per chunk = **20 reads/line**
- Read rate: 20 × 192 × 60 = **230.4K reads/s**
- CPU shadow writes: ~200K–500K/s (realistic worst case)

**Latency:** DDR3 reads take ~20 clk_x1 cycles (~270 ns = ~15 clk_logic cycles).
apple_video_gen has 112 logic cycles per chunk. Even with 15-cycle SDRAM-equivalent
latency, that leaves 97 cycles of slack. The same wait-state → ready-handshake
change to `fe_step_r` applies as on the GS board.

**VGC reads stay in BSRAM** — unchanged from current design. `vgc_gen.sv` requires
zero modifications.

#### DDR3 Address Space Allocation

DDR3 has a 28-bit address (256 MB addressable). Current framebuffer uses a tiny fraction:

| Region | Address Range | Size | Use |
|--------|--------------|------|-----|
| Framebuffer | 0x000000–0x04AFFF | ~300 KB | 640 × 480 × 18-bit pixels (128-bit packed) |
| Shadow memory | 0x100000–0x10FFFF | 64 KB | Text + hires (main+aux interleaved) |
| Ensoniq RAM | 0x200000–0x20FFFF | 64 KB | DOC wavetable + GLU sound data |
| **Total used** | | **~430 KB** | Of 256 MB available |

Address regions are widely separated to simplify decoding and avoid conflicts.

#### Combined DDR3 Budget (Ensoniq + Shadow Memory)

| Component | Mcyc/s @ 74.25M | % of 74.25M |
|-----------|-----------------|-------------|
| FB Write batches | 6.75 | 9.1% |
| FB Read line fetches | 10.1 | 13.6% |
| Shadow Write (CPU) | 1.0 | 1.3% |
| Shadow Read (apple_video_gen) | 1.15 | 1.5% |
| Ensoniq DOC reads (32 osc) | 0.57 | 0.8% |
| Ensoniq GLU writes | <0.01 | <0.01% |
| DDR3 refresh | ~1.0 | 1.3% |
| **Total** | **~20.6** | **~27.7%** |
| **Headroom** | **~53.7** | **~72.3%** |

**Verdict: Trivially feasible.** Combined Ensoniq + shadow memory adds ~3.7% DDR3 load
on top of the existing 24% framebuffer utilization. 72% headroom remains for future use.

### Multi-Port DDR3 Interface Design

#### Current Architecture Problem

`ddr3_framebuffer_480p.v` is monolithic — it contains the DDR3 PLL, DDR3 controller IP,
HDMI output, line buffers, write FIFOs, and the internal arbiter all in one module.
The DDR3 controller exposes a single `app_cmd`/`app_addr`/`app_en` command interface.

The internal arbiter (lines 712–773) currently has two clients:
1. **Write batch** (highest priority): `write_pixels_req ^ write_pixels_ack`
2. **Line fetch** (lower): `line_fetch_active && !rd_fifo_almost_full`

When neither is active, the DDR3 interface sits **idle** — this is the slot where
external mem_port_if clients can be serviced.

#### Recommended: Expose `mem_port_if` Ports from DDR3 Framebuffer

Add N prioritized `mem_port_if.controller` ports to `ddr3_framebuffer_480p`:

```
ddr3_framebuffer_480p #(
    .NUM_EXT_PORTS(3),      // shadow_read, shadow_write, ensoniq
    ...
) u_ddr3_fb (
    ...
    .ext_port(ext_mem_ports)  // mem_port_if array
);
```

**Priority scheme (existing arbiter extended):**

| Priority | Client | Condition |
|----------|--------|-----------|
| 1 (highest) | FB write batch | `write_pixels_req ^ write_pixels_ack` |
| 2 | FB line fetch | `line_fetch_active && fetch_pixel_x < fb_width` |
| 3 | External port 0 | `ext_port[0].rd \|\| ext_port[0].wr` (shadow read) |
| 4 | External port 1 | `ext_port[1].rd \|\| ext_port[1].wr` (shadow write) |
| 5 (lowest) | External port 2 | `ext_port[2].rd \|\| ext_port[2].wr` (Ensoniq) |

The arbiter's `else` clause (currently idle) becomes a priority scan of external ports.

#### CDC: clk_logic (54 MHz) → clk_x1 (74.25 MHz)

External clients operate on `clk_logic`. The DDR3 arbiter operates on `clk_x1`.
Each external port needs clock domain crossing:

**Request path (54 → 74.25 MHz):**
- Async request FIFO (shallow, 4–8 entries): addr + data + byte_en + rd/wr
- Written by client on clk_logic, read by arbiter on clk_x1
- Similar to the existing framebuffer write FIFO pattern

**Response path (74.25 → 54 MHz):**
- Async response FIFO (shallow): 32-bit read data + ready pulse
- Written by arbiter on clk_x1 when DDR3 read completes, read by client on clk_logic

This is the same pattern as `mem_port_cdc.sv` used on the GS board for SDRAM CDC,
adapted for the DDR3's wider (128-bit) internal bus.

#### DDR3 128-bit Width vs 32-bit mem_port_if

DDR3 burst length 8 means each command transfers 128 bits. External ports use 32-bit words.

**Writes:**
- Pack 32-bit write data into 128-bit DDR3 word at the correct 32-bit slot
- Use `app_wdf_mask` (16-bit, 1 per byte) to mask off the unused 12 bytes
- Address mapping: `ext_addr[1:0]` selects which 32-bit slot within the 128-bit word
- Simple, no waste — DDR3 byte masking handles partial writes natively

**Reads:**
- Issue 128-bit DDR3 read, extract the relevant 32-bit word from `app_rd_data`
- Mux by `ext_addr[1:0]`: `rd_data_32 = app_rd_data[ext_addr[1:0]*32 +: 32]`
- Reads the full 128 bits but only returns 32 bits to the client

**Optimization (optional):** For sequential access patterns (like apple_video_gen's
20 sequential reads), cache the 128-bit DDR3 word and serve 4 consecutive 32-bit
reads from cache without additional DDR3 commands. This would reduce shadow read
DDR3 commands by 4× (from 230K to ~58K commands/s).

#### Architectural Benefits

This multi-port approach provides a **general-purpose DDR3 access mechanism**:

1. **Reusable**: Any future feature needing external memory gets a `mem_port_if` port
   with automatic priority arbitration and CDC handling
2. **Non-invasive**: Framebuffer read/write paths unchanged — external ports only
   use idle DDR3 cycles
3. **Scalable**: Adding a new client is just adding a port and a priority level
4. **Safe**: Priority scheme guarantees framebuffer never starves — external ports
   only service when FB has no pending work
5. **Familiar**: `mem_port_if` is already used throughout the codebase for SDRAM
   ports, BSRAM ports, etc. — same client interface regardless of backing memory

Potential future uses beyond Ensoniq and shadow memory:
- SmartPort disk block cache
- Additional IIgs memory banks
- DMA buffer for coprocessor features

---

## 3. Comparison Summary

### A2N20v2-GS: Shadow Memory → SDRAM

| Metric | Current | Projected | Delta |
|--------|---------|-----------|-------|
| SDRAM utilization | 37–44% | 42–47% | +5–3% |
| Headroom | 56–63% | 53–58% | -3–5% |
| BSRAM usage | 44/46 (96%) | ~34/46 (74%) | -10 blocks |
| New SDRAM ports needed | 0 | +2 (shadow rd/wr) | |
| Shadow reads/line | 0 | 20 (apple_video_gen only) | +230K reads/s |
| Per-read latency | 4 cycles (BSRAM) | ~7 cycles (SDRAM) | +3 cycles |
| Chunk timing slack | 108 cyc (112 - 4 fetch) | 105 cyc (112 - 7 fetch) | -3 cycles |
| Generator changes | None | Wait-state handshake (apple_video_gen only) | Minimal |
| VGC changes | None | None (stays in BSRAM) | None |

### A2Mega: Ensoniq + Shadow Memory → DDR3

| Metric | Current | Projected | Delta |
|--------|---------|-----------|-------|
| DDR3 utilization | 23–24% | ~27.7% | +3.7% |
| Headroom | 76–77% | ~72.3% | -4% |
| BSRAM usage | 107/118 (91%) | ~65/118 (55%) | -42 blocks |
| Shadow reads/line | 0 | 20 (apple_video_gen only) | +230K reads/s |
| DOC read latency | 2 cycles | ~20 clk_x1 (~270 ns) | Within 1.1 µs budget |
| Shadow read latency | 4 cycles (BSRAM) | ~15 clk_logic (~270 ns) | Within 112-cycle chunk |
| VGC changes | None | None (stays in BSRAM) | None |
| Architecture change | None | Multi-port DDR3 interface | Moderate complexity |

### Key Takeaways

1. **A2Mega benefits most from DDR3 offloading.** Moving Ensoniq (32 blocks) + text/hires_main
   (10 blocks) to DDR3 frees 42 BSRAM blocks (91% → 55%), with only 3.7% additional DDR3 load.
   72% DDR3 headroom remains. The multi-port `mem_port_if` interface also provides a
   general-purpose mechanism for future DDR3 clients.

2. **A2N20v2-GS shadow → SDRAM is very feasible.** Shadow memory adds only ~1.6 Mcyc/s
   (1.5% of SDRAM bandwidth) because Apple II video reads just 40 bytes per scanline —
   20 reads of 32-bit words, regardless of mode. The per-read increase (4 → ~7 cycles)
   is irrelevant: apple_video_gen has 112 logic cycles per chunk but needs only 7 for the
   SDRAM fetch (105 cycles slack). Only a wait-state change (fixed count → ready handshake)
   is needed, not pipeline redesign. The 80-col/DHGR interleaved fetch (main+aux in one
   32-bit read) means no extra SDRAM transactions for double-width modes — still 20 reads.

3. **VGC must stay in BSRAM (both boards).** Real IIgs apps write to non-linearized memory
   ($2000-$5FFF, $6000-$9FFF as separate hires banks) before activating SHR mode. The
   `interleave_mux` read-time interleaving is required because data isn't written
   pre-interleaved. This is the same approach the `a2n20v2-Enhanced` board uses.
   - GS: 10 blocks freed (96% → 74%), 16 blocks retained for VGC
   - Mega: 42 blocks freed (91% → 55%), 16 blocks retained for VGC

4. **BSRAM pressure is the primary motivation.** GS is at 96% (only 2 blocks free),
   mega is at 91% (11 blocks free). Both benefit significantly from offloading to
   external RAM, with the mega seeing the largest improvement.

5. **Shared architectural changes (both boards):**
   - `apple_memory.sv`: Remove `text_vram` and `hires_main_2000_5FFF` sdpram32 instances;
     add mem_port_if connections for read/write with Enhanced board's byte_en encoding;
     duplicate aux writes to both external RAM and retained VGC BRAMs
   - `apple_video_gen.sv`: Replace `fe_step 1,2` fixed delay with ready-wait loop
   - `vgc_gen.sv`: **No changes** — continues reading from BSRAM

6. **Board-specific changes:**
   - **A2N20v2-GS**: Add 2 SDRAM ports in `top.sv`, wire via `mem_port_cdc`
   - **A2Mega**: Add multi-port `mem_port_if` interface to `ddr3_framebuffer_480p.v` with
     priority arbiter; CDC via async FIFOs (clk_logic → clk_x1); also moves Ensoniq
     `mem_port_bram` to DDR3 via same interface

7. **Existing reference implementation**: The `a2n20v2-Enhanced` board already implements
   video reads from SDRAM with interleaved byte_en encoding, VGC reads from BSRAM.
   The SDRAM storage layout and `video_mem_if.q` pass-through pattern can be directly
   reused on both boards.
