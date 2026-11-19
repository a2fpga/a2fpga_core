# a2p25 resource audit — where the GW5A-25 budget goes, and what is bloat

§§1–7.10 are analysis (no RTL was changed for them); §7.11 onward and §8
record what was then implemented and measured. Numbers marked **est.** are
estimates derived from the RTL and the block-mapping rule in §2; everything
else is read from the build reports listed in §1.

## 1. Provenance

**a2p25 (audited build)**

| Item | Value |
|---|---|
| Source tree | branch `claude/a2p25-modernization-8a97cc`, commit `5b541a5f` (2026-10-12). The bitstream was committed in `e4f2e056` ("dp: EQ dwell from DPCD 0x00E, LATE_REPLY_DRAIN on the a2p25 core"). |
| Project | `boards/a2p25/a2p25.gprj`, top `boards/a2p25/hdl/top.sv`, part GW5A-LV25MG121NC1/I0 |
| Tool | GowinSynthesis / PnR V1.9.12.01; synthesis 2026-10-12 14:31, PnR 14:43 |
| Bitstream | `boards/a2p25/impl/pnr/a2p25.fs`, sha256 `a651e352f38b6f2a805a3a5e50eda949762cf2a989cfcd7db614b63af91e3fe7` |
| Reports | `boards/a2p25/impl/pnr/a2p25.rpt.txt` (flat PnR totals, tracked); `impl/gwsynthesis/a2p25_syn_rsc.xml` + `a2p25.vg` (per-instance hierarchy and primitive netlist, **untracked**, same timestamps as the PnR run, read from the build worktree) |
| Timing | 0 setup / 0 hold violations; Fmax margin thin on clk100 (100.22 vs 100 MHz), clk_pix (149.11 vs 148.5) and clk_mem (108.85 vs 108); clk_hr 57.1 vs 54, clk_sym 82.9 vs 81. Single roll; not the +0.5 ns durability bar. |
| Feature set | UTHERNET2_ENABLE=0, MOCKINGBOARD_ENABLE=0, SUPERSPRITE_ENABLE=0, SUPERSERIAL_ENABLE=0, DebugOverlay ENABLE=0, DOC_BANKS_IN_BSRAM=0, LANE_COUNT=4, FIFO_LINES=1, COLOR_BITS=18 with the line buffer stored as RGB565 |

**a2n20v2-Enhanced (comparison builds, two months older)**

| Variant | Report date / commit | fs sha256 (first 16) | Notes |
|---|---|---|---|
| `a2n20v2_enhanced` (base) | 2026-08-01, `15a5a2bd` | `f0a2afe37762a24b` | shadow in BSRAM, no framebuffer, Mockingboard + SuperSprite + SSC + Uthernet2 **in** |
| `a2n20v2_enhanced_dualrate` | 2026-08-01, `15a5a2bd` | `78387c6f471cc94c` | 108 MHz SDRAM, VGC_IN_SDRAM, no framebuffer |
| `a2n20v2_enhanced_fb` | 2026-08-09, `a57a50de` | `1d8662435c5f90a9` | dual-rate + SDRAM framebuffer — the closest counterpart to the a2p25 pipeline |

Per-instance numbers for the Enhanced come from `impl/gwsynthesis/*_syn_rsc.xml`
in the main checkout (untracked; same dates as the PnR reports).

## 2. How the counts were made — and a block-mapping rule that matters

Gowin's PnR report has only flat totals. The per-module tables below are the
synthesis hierarchy (`*_syn_rsc.xml`: REG / LUT / ALU / BSRAM primitives per
instance, children included). Synthesis totals are within 1% of PnR for logic
and registers, so they are used as-is.

**BSRAM is the exception.** Synthesis reports 42 BSRAM primitives for the
a2p25; PnR places **56 blocks**. Cross-checking the a2p25 `.vg` netlist against
the PnR block types of seven a2p25 builds (full core, five `dp_test` variants,
`psram_test`) gives one consistent rule for this device:

> On GW5A-25, a semi-dual-port primitive with a **32- or 36-bit** port
> (`SDPB` x32, `SDPX9B` x36) occupies **two** 18 Kb blocks. Primitives of
> x18 or narrower (x2, x8, x9, x16, x18), `DPB` and `pROM` occupy one.

Evidence: `dp_test_fb` has 9 x2 + 5 x32 + 3 x32 SDPB primitives and PnR shows
25 SDPB (9 + 2×8); `psram_test` has one x32 SDPB and PnR shows 2; the 11 x9 and
6 x18 SDPX9B primitives of the other `dp_test` builds map 1:1. On the
GW2AR-18 (Enhanced) synthesis and PnR BSRAM counts are identical, so this is
a GW5A mapping effect (likely the 18 Kb block offering at most 18 bits per
port in dual-port modes; the Gowin BSRAM user guide should be checked, the
local datasheet volume was not reachable during this audit). The practical
consequence: **a memory costs `ceil(width / 18)` blocks** regardless of depth
until the depth exceeds 1024; shallow, wide arrays are the expensive ones.

With that rule every one of the 56 blocks is accounted for:

| Memory (instance) | Array | Primitives | Blocks | Bits used / capacity |
|---|---|---|---|---|
| `u_framebuffer` write FIFO `wr_fifo` | 64 × 149 | 5 × SDPB x32 | **10** | 9.5 Kb / 180 Kb (5%) |
| `u_framebuffer` line buffer `line_buf` | 8192 × 16 | 8 × SDPB x2 | 8 | 128 Kb / 144 Kb |
| `sg/doc5503/cache_ram` (wavetable line cache) | 64 × 140 | 4 × SDPX9B x36 | **8** | 9 Kb / 144 Kb (6%) |
| `esp32_ospi` Disk II track lanes (4 × `lane_mem`) | 4 × 4096 × 8 | 8 × DPB x8 | 8 | 128 Kb / 144 Kb |
| `i_dp/i_pixel_cdc_fifo` | 512 × 97 | 3 × SDPX9B x36 | **6** | 49 Kb / 108 Kb |
| `sg` GLU write queue `gq_*` | 32 × 57 (data is one byte ×4) | 2 × SDPB x32 | **4** | 1.8 Kb / 72 Kb (2.5%) |
| `sg/doc5503/lu_ram0,1` | 32 × 12, 32 × 16 | 2 × SDPB x16 | 2 | 0.9 Kb / 36 Kb |
| `esp32_ospi/hdd_mem` | 512 × 32 | 2 × DPB x16 | 2 | 16 Kb / 36 Kb |
| `i_sys_pll/u_pll_init`, `i_phy/u_dphy/u_pll_init` ROMs | 2 × (64 × 28) | 2 × pROM x32 | **2** | 3.5 Kb / 36 Kb |
| `esp32_ospi/osd_vram` | 2048 × 8 | SDPB x8 | 1 | 16 Kb / 18 Kb |
| `osd_overlay` font ROM | 4096 × 8 (folded) | pROM x8 | 1 | |
| `apple_video_gen` video ROM | 4096 × 8 (folded) | pROM x8 | 1 | |
| `diskii/diskrom` | 256 × 8 | pROM x16 | 1 | 2 Kb / 18 Kb |
| `hdd/buf_mem` | 512 × 8 | DPB x8 | 1 | 4 Kb / 18 Kb |
| `slotmaker/slot_cards` | 8 × 8 | DPB x8 | **1** | 64 b / 18 Kb |
| **Total** | | 42 | **56** | |

PnR breakdown check: SDPB 25 = 8 + 10 + 4 + 2 + 1; SDPX9B 14 = 8 + 6; DPB 12 =
8 + 2 + 1 + 1; pROM 5. (TOP_INTEGRATION_PLAN §3 itemised the same memories by
primitive count — "write FIFO 5", "DP pixel FIFO 3", "bank FIFO 3" — which is
why that list never summed to the PnR total. The FIFO_LINES change saved 5
blocks, not 8; the D-PHY bank FIFO would cost 5 blocks in BSRAM, not 3.)

Device totals for the audited build:

| | a2p25 (GW5A-25) | Enhanced base (GW2AR-18) | Enhanced fb |
|---|---|---|---|
| Logic (LUT+ALU+ROM16) | 18,675 / 23,040 (82%) | 12,820 / 20,736 (62%) incl. 202 SSRAM | 15,021 / 20,736 (73%) incl. 229 SSRAM |
| Registers (FF) | 15,233 / 23,040 (67%) | 6,641 / 15,552 (43%) | 8,236 / 15,552 (53%) |
| CLS | 11,423 / 11,520 (99%) | 8,770 / 10,368 (85%) | 8,982 / 10,368 (87%) |
| BSRAM | 56 / 56 | 44 / 46 | 34 / 46 |
| DSP | 3.5 / 28 | 14.75 / 24 | 14.75 / 24 |

The a2p25 has 2.3× the registers of the Enhanced base for a smaller feature
set. CLS at 99% with logic at 82% is partly placer spreading (ed's note in the
plan), but the FF count is real: the register budget is where most of the
non-BSRAM bloat sits.

## 3. Per-block table

REG / LUT / ALU from the synthesis hierarchy (children included). a2p25 BSRAM
is the **physical** count from §2; Enhanced BSRAM/SSRAM from its synthesis
report (identical to PnR on GW2A). The Enhanced column is the `_fb` variant
unless marked (base). Classification: **ARCH** = inherent to the a2p25
architecture (no SSRAM on GW5A, HyperRAM vs SDRAM, DP vs HDMI, 1080p vs 720p,
ESP32 vs BL616), **BLOAT** = cost not required by the function.

| Block | a2p25 REG / LUT / ALU | a2p25 BSRAM | Enhanced REG / LUT / ALU | Enh. BSRAM (+SSRAM) | Delta classification |
|---|---|---|---|---|---|
| `apple_bus` (+ `gs_detector`, timing CDC) | 82 / 55 / 33 | 0 | 146 / 363 / 27 | 0 | a2p25 smaller (a2mega bus); nothing to do |
| `apple_memory` (shadow in HyperRAM; 16×57 write FIFO in regs, burst cache + VGC prefetch store) | 824 / 896 / 531 | 0 | 570 / 890 / 44 | 0 (base: 16 BSRAM aux) | ARCH for the SDRAM/HyperRAM shadow path; **BLOAT** candidate: FIFO depth 16 (≈460 FF of margin, §4 B9); 531 ALUs is high for this block (address/compare arithmetic) — worth a look but not costed here |
| `slotmaker` | 6 / 17 / 0 | **1** | 14 / 18 / 0 | 0 (+2 SSRAM) | **BLOAT**: an 8-byte table in a BSRAM block (no SSRAM on GW5A) |
| `apple_video_gen` + `apple_fb_writer` | 282 / 515 / 35 | 1 | 274 / 546 / 34 | 1 | same |
| `vgc_gen` + `vgc_fb_writer` + `scan_timer` | 406 / 482 / 79 | 0 (1 DSP) | 194 / 308 / 48 | 0 (+3 SSRAM) | a2p25 `vgc_gen` carries 2.5× the registers (349 vs 136) with the same source file — parameterisation (`VGC_IN_SDRAM` prefetch) or missing SSRAM; **check**, not costed |
| `framebuffer_1080p` (line buffer 8 banks × 1024 × 16; write FIFO 64 × 149; read FIFO 16 × 32 in regs) | 1,065 / 839 / 274 | **18** (8 + 10) | `sdram_framebuffer` 312 / 473 / 157 | 4 (+8 SSRAM) | ARCH: 1080p scanout, HyperRAM burst assembly. **BLOAT**: write FIFO 10 blocks for 64 entries (§4 B1); 8 line banks where the prefetch needs ≤ 4 (B3); 3.4× registers vs the SDRAM version (beat/overflow instrumentation, counters: `dbg_*` 8-bit counters, `completed_line_r[8]`) |
| `sound_glu` + `doc5503_pipelined` (FF register banks 7 × 256 + 768; line cache; lookup RAMs; GLU write queue) | 3,726 / 3,864 / 352 | **14** (8 + 2 + 4) | 488 / 766 / 112 | 2 (+40 SSRAM) | ARCH: no SSRAM → 2,560 FF of banks; pipelined DOC for external wavetable RAM (+~1,000 REG / 1,500 LUT core). **BLOAT**: cache 8 blocks for 1.1 KB (B2), write queue 4 blocks for 32 entries whose data field is one byte replicated four times (B5), `debug_osc_mode_r[8]` etc. small |
| `diskii` (2 drives) + `hdd` | 303 / 620 / 77 | 2 | 303 / 652 / 43 | 2 | same |
| `esp32_ospi_connector` (+ proto, OSD VRAM, 16 KB Disk II lanes, 2 KB HDD buffer) vs `bl616_spi` (+ proto, SD-SPI, 32-deep write FIFO) | 1,070 / 1,318 / 48 | **11** (8 + 2 + 1) | 1,000 / 1,334 / 98 | 4 (+2 SSRAM) | Logic equal. BSRAM: 16 KB of track lanes is a **product/firmware decision** (plan: 4 → 2 lanes, −4, firmware-visible, B8); OSD and HDD buffers are fine |
| `u_ddr3_dbg_reader` + HyperRAM port 6 | 34 / 7 / 0 (+ ≈120 FF in the arbiter queue) | 0 | — | — | **BLOAT (debug-only)**: ESP32 memory-peek instrument in the production top (B6) |
| `hyperram_ctrl` + `hyperram_phy` | 752 / 1,007 / 257 | 0 | `sdram_ports/sdram_inst` 513 / 444 / 15 | 0 | ARCH (HyperBus PHY + calibration state machine) |
| `hyperram_ports` (7 ports × 2-slot request queue, 155-bit slots) | 932 / 752 / 27 | 0 (2 DSP) | `mem_cdc[0..6]` 390 / 82 / 24 (+32 SSRAM) | 0 | ARCH mostly; the queues are FFs because there is no SSRAM. Port 6 is debug (B6). |
| `dp_transmitter` total | 3,377 / 3,750 / 350 | **6** | `hdmi` 631 / 1,032 / 69 | 0 | ARCH: DP link = AUX protocol engine + training + MSA/SDP; HDMI has none of that |
| ├ `pixel_cdc_fifo` (512 × 97) | 101 / 77 / 30 | 6 | — | — | **BLOAT**: 24-bit pixels through the CDC when the framebuffer is RGB565 (B4) |
| ├ `video_stream_packer` | 232 / 621 / 0 | 0 | — | — | ARCH (4-lane TU packing) |
| ├ `sdp_engine` (256-bit `db` + 256-bit `db_d` copy + 6×4×8 wire-byte precompute) | 586 / 961 / 0 | 0 | HDMI packet picker 480 / 342 | 0 | ARCH for the SDP; **BLOAT**: the `db_d` copy exists only for a stability check and a parity precompute (B10, 256 FF) |
| ├ `msa_inserter_4ch`, `dp_video_timing`, `audio_sample_buffer`, `maud_measure` | 537 / 182 / 84 | 0 | — | — | ARCH |
| ├ `main_stream_processing` (`insert_training_pattern` 420 REG = 6 × 80-bit delay line; `skew_channels` 111; idle/scrambler) | 797 / 330 / 26 | 0 | — | — | ARCH; the 480-FF training delay line is upstream-design heritage — worth a look, not costed |
| ├ `channel_management` / `aux_channel` / `aux_interface` (two 32 × 8 FIFOs in FFs = 512 FF; LINK_CHECK, ERRCNT_READ, ESI, debug saturating counters ≈ 60 FF) | 1,081 / 1,470 / 210 | 0 (1 DSP) | — | — | ARCH (the AUX engine; the FIFOs are FFs for lack of SSRAM). The debug/observe counters, LINK_CHECK and ERRCNT_READ are small (**< 100 FF**) and are functional link-supervision, not bloat; AFE/EDID paths are already swept (`ENABLE_AFE_ADJUST=0`) |
| `transceiver_bank_dphy` (16 × 80 async FIFO in registers = 1,280 FF; 4 × 8b10b encoders; shim) + Gowin D-PHY + PLL init | 1,789 / 1,506 / 84 | 1 (PLL ROM) | HDMI TMDS ×3 | 0 | ARCH (the BSRAM alternative is 5 blocks at x18, not 3); the PLL-init ROM block is **BLOAT** (B7) |
| `i_sys_pll/u_pll_init` | 100 / 150 / 35 | 1 | — | — | GW5A PLL init machines are needed; the 64 × 28 ROM in a BSRAM block is **BLOAT** (B7) |
| `osd_text_overlay` + `scanline_dim` | 99 / 142 / 47 | 1 | (part of BL616 OSD path) | — | same role |
| `DebugOverlay` (ENABLE=0) + top-level `dbg_hex_sync0/1`, `dbg_bits*` sync regs | 149 / 0 / 0 (+160 FF in top) | 0 | 54 / 151 (enabled) | 0 | **BLOAT (debug-only)**: a disabled overlay still costs ≈ 310 FF and sits in the composite pipeline (B6) |
| `apple_speaker`, `i_aux_pad`, `reset_sync`, top glue | ≈ 300 / 250 | 0 | `audio_out` + IIR 606 / 302 (+15 DSP) | 0 | Enhanced spends DSPs on the audio filter; a2p25 sends PCM over DP |
| Mockingboard, SuperSprite, SuperSerial, Uthernet2 (disabled) | 0 (swept) | 0 | 774 / 1,292; 1,209 / 2,210; 159 / 207; 64 / 95 | 0; 10; 1; 9 | Disabled features are fully swept by synthesis (confirmed in the log: "swept in optimizing" for all four plus `via6522`, `YM2149`, `glb6551`, `uart_*`, `ssc_rom`, `hddrom`, `edid_decode`, `afe_adjust_seq`). No generate-guard gaps remain. |

Uthernet2 on this device: `reg_mem` 2048 × 8 (1 block) + `buf_mem` 16384 × 8
(8 blocks) = **9 blocks**, x8 so no doubling — the same 9 as on the Enhanced.

## 4. Bloat items — proposals, savings, risk

Ordered by savings ÷ risk. "Shared" = the file is used by the a2mega (and
possibly other boards). Timing context: the audited build closes at 0
violations on this roll with < 1% Fmax margin on clk100 / clk_pix / clk_mem;
anything that adds logic to those cones is a timing risk, anything that only
removes registers or narrows muxes is neutral-to-positive.

| # | Item | Change | Savings (est.) | Risk | Shared HDL |
|---|---|---|---|---|---|
| **B4** | `pixel_cdc_fifo` carries 24-bit RGB | Add a `PIXEL_BITS` parameter to `dp_transmitter` (default 24 → a2mega unchanged); a2p25 passes 16 and converts RGB565↔888 at the FIFO boundary. Width 4×16+1 = 65 → 4 × x18 primitives. The framebuffer is already RGB565, so no picture change except OSD/scanline-dim quantisation to 565. | **−2 BSRAM**, −~30 LUT | Low. Symbol-clock side unchanged; the "level swings ±60 at prefill" behaviour is depth-related, not width. | `hdl/displayport/dp_transmitter.sv`, `pixel_cdc_fifo.v` (parameterised; a2mega default) |
| **B7** | PLL-init ROMs (2 × 64 × 28) in BSRAM | `syn_romstyle = "logic"` (or `distributed_rom`) on `rRom` in `boards/a2p25/hdl/gowin/pll_init.v`; GW5A has no SSRAM so this becomes ≈ 28 × 4 LUT4 per ROM. | **−2 BSRAM**, +~220 LUT | Low (the init sequencer runs at 50 MHz, once at boot; LUT ROM is fine). CLS +~110. | a2p25 only (a2mega uses its own PLL wrappers) |
| **B5a** | GLU write queue: 2 × x32 primitives for a 32 × 57 array whose data field is `{data,data,data,data}` | Store 8-bit data; split the entry into ≤ 18-bit arrays (`addr[17:0]`, `{addr[20:18], be, data}`) so synthesis emits x18 primitives. Same depth, same behaviour. | **−2 BSRAM** | Low (pure storage re-slicing; the drop counter `glu_wq_drops_o` verifies). | `hdl/sound/sound_glu.sv` (a2mega too — same saving there) |
| **B5b** | …or shrink the queue to 8 entries in FFs | Depth 32 was chosen for arbiter starvation during uploads; 8 × 33 = 264 FF. | −4 BSRAM, +264 FF | Medium: a dropped write corrupts the wavetable permanently (the RTL comment). Needs the POLY.SYNTH upload soak with the drop counter. | shared |
| **B6** | Debug-only logic in the production top | (a) `DebugOverlay` ENABLE=0 still instantiates 6 pipeline stages (149 FF) plus the top's `dbg_hex_sync0/1`, `dbg_bits*` (160 FF): generate-guard both and replace the overlay with a 6-stage register delay only if the composite alignment needs it (or re-tune `H_TRIGGER_LEAD` from 11 to 5, see MODERNIZATION §6g.1). (b) `ddr3_debug_reader` + HyperRAM port 6: remove, `NUM_DDR3_PORTS` 7 → 6 (−34 FF reader, −≈120 FF arbiter queue, smaller 7:1 muxes). | **−≈430 FF, −≈150 LUT** | Low–medium: (a) changes composite latency (scanout trigger lead must be re-verified against the SHR left-edge test); (b) removes the ESP32 memory-peek used for SHR dumps — firmware-visible; keep behind a parameter. | top.sv only |
| **B7b** | `slotmaker/slot_cards` 8 × 8 in a DPB block | `syn_ramstyle = "registers"` (64 FF, 8:1 mux). On GW2A it is already SSRAM; the attribute can be made conditional or simply applied (64 FF is nothing on any board). | **−1 BSRAM**, +64 FF | Low | `hdl/slots/slotmaker.sv` (all boards) |
| **B1a** | Framebuffer write FIFO 64 × 149 → 10 blocks | Minimal variant: split the 149-bit entry into nine ≤ 18-bit arrays so x18 primitives are inferred (9 blocks). | **−1 BSRAM** | Low | `hdl/video/framebuffer_1080p.sv` (a2mega: DDR3 port is 128-bit, same saving) |
| **B1b** | …structural variant | The HyperRAM port is 32-bit (`hyperram_ports` takes a 32-bit beat plus `wide_wr_data_hi` for the 4-beat burst). Queue 32-bit beats in a 256 × 32 FIFO built from two x16 primitives (2 blocks) plus a 64 × 21 address FIFO (2 blocks, or 1 if the address is ≤ 18 bits after the base is folded in), and assemble the burst at the arbiter side — or push beats one at a time and drop `WIDE_WR_PORT`. | **−6 BSRAM** (10 → 4), −~100 FF | Medium: touches the FIFO contract (`fifo_busy`/yield thresholds in entries → beats), the HyperRAM wide-write path and the a2mega DDR3 path; framebuffer write timing is one of the thin cones. Needs the beat/overflow counters (`dbg_fifo_overflow`, PC line) clean on hardware. | shared (`framebuffer_1080p.sv`, `hyperram_ports.sv`) |
| **B3** | Line buffer 8 banks × 1024 × 16 | The scanout repeats each source line 5× (192 → 960, 200 → 1000 raster lines) and prefetches line N+1 while N is displayed; the fetch logic already limits itself to ≤ 7 banks ahead during active video. Reduce to 4 banks (`fetch_bank_r` 3 → 2 bits, `completed_line_r[8]` → 4, "stay ≤ 3 ahead"). | **−4 BSRAM** | Medium: changes the prefetch/vblank fill schedule; must re-verify with the beat/line-not-ready counters and the SHR left-edge test. Read side is on the thin clk_pix cone, but the change removes address bits rather than adding logic. | shared (a2mega also saves 4 blocks of its 118) |
| **B2** | DOC line cache 64 × 140 → 8 blocks for 1.1 KB | Reorganise by beat: lines arrive as 4-beat bursts, so store 256 × 32 (two x16 primitives, 2 blocks) and read the single 32-bit beat selected by `addr[3:2]`; keep the 12-bit tag in a 64 × 12 array (1 block). The 140-bit read mux becomes a 32-bit one. | **−5 BSRAM** (8 → 3), −~150 LUT | Medium–high: the DOC fetch/prime pipeline is the most timing-sensitive cone on both GW5A boards (named in every a2p25 violation list). The narrower mux should help, but the slot schedule must be re-simulated (`hdl/sound` DOC testbenches) and listened to (POLY.SYNTH cases). | shared (`hdl/sound/doc5503_pipelined.sv`; a2mega same saving) |
| **B8** | Disk II track lanes 4 × 4 KB | 2 lanes (8 KB: one track per drive) per the plan's note. | −4 BSRAM | Medium: ESP32 firmware protocol change (`SPACE_DISK` layout), serving latency for two-drive access. Product decision. | `boards/a2mega/hdl/esp32/esp32_ospi_connector.sv` + ESP32 fw |
| **B9** | `apple_memory` shadow write FIFO depth 16 in registers (≈ 912 FF) | Depth 8 (the RTL says 8 overflowed before the arbiter priority fix; now "margin"). | −456 FF | Medium: a live overflow corrupts shadow video; `dbg_shadow_drop` must stay 0 through the TransWarp GS splash case that found the original overflow. | shared |
| **B10** | `sdp_engine` `db_d` 256-bit copy | Replace the `db_d === db` stability check with a one-bit "db written this cycle" flag and feed the parity precompute from `db` one cycle later (or register only the 16-bit slices the precompute reads). | −~256 FF | Medium: `db_d` was introduced for timing on the symbol clock (the a2mega 138B campaign); re-roll both boards. | shared (`hdl/displayport/audio/sdp_engine.v`) |
| **B11** | `framebuffer_1080p` instrumentation (beat/timeout detectors, 8-bit saturating counters, `completed_line_r`) and `doc5503` debug counters (`dbg_doc_*`, `debug_osc_mode_r[8]`) | Generate-guard behind a `DEBUG_COUNTERS` parameter once the PC-line telemetry is no longer needed day-to-day. | −~200–300 FF (est., not itemised) | Low, but removes the counters that verify B1/B3/B9 — do last. | shared |

Not bloat, but worth knowing:

- `aux_interface` tx/rx FIFOs (2 × 32 × 8 = 512 FF) and the D-PHY bank FIFO
  (16 × 80 = 1,280 FF) are FFs because the GW5A has no SSRAM. Each could move
  to BSRAM (1 block for both AUX FIFOs via address split; 5 blocks for the
  bank FIFO at x18) **only if** blocks are freed first — a trade, not a saving.
- `DOC_BANKS_IN_BSRAM=1` (plan: −2 k logic, +6 BSRAM) is the lever to relieve
  CLS once BSRAM is freed. Note the §2 rule: the banks must be sliced ≤ 18 bits
  wide or the cost is higher than the plan's +6 (seven 32 × 8 banks = 7
  blocks, the 32 × 24 accumulator bank = 2 blocks at x18 — **+9**, unless
  banks are paired into 16-bit arrays: 4–5 blocks). Re-estimate before relying
  on +6.
- `transceiver_bank_dphy` lane FIFO "3 blocks otherwise" in its comment is 5
  blocks under the §2 rule.

## 5. Recommended order and the target for Uthernet2 + Mockingboard

**Requirements:** Uthernet2 = 9 BSRAM + ≈ 65 REG / 100 LUT; Mockingboard =
0 BSRAM + ≈ 775 REG / 1,300 LUT / 40 ALU (Enhanced numbers; identical source).

**BSRAM target:** ≤ 46 / 56 used before Uthernet2 goes back in (9 blocks + 1
spare). **Logic target:** ≤ 17,000 logic cells (74%) and ≤ 13,500 FF (59%)
before Mockingboard, so that the post-add build sits near today's 82% / 67%
rather than above it (today's 99% CLS is already a placement-time cost).

Suggested sequence (each step = one build for resource measurement, timing
checked per the no-skating rule — a step that re-opens violations is not
"done"):

1. **Low-risk BSRAM pass (−8 blocks, 56 → 48):** B4 (−2), B7 (−2), B5a (−2),
   B7b (−1), B1a (−1). Storage re-slicing and attributes only; no behavioural
   change. One build.
2. **Debug trim (−≈430 FF):** B6 a+b behind parameters. Re-verify the SHR
   left-edge alignment if the overlay stages come out.
3. **Line buffer 8 → 4 banks (−4 blocks, → 44):** B3. Hardware check with
   the framebuffer counters and SHR scanout. This alone clears the Uthernet2
   BSRAM target.
4. **Uthernet2 back in** (`UTHERNET2_ENABLE=1`): 44 + 9 = 53 / 56. Resource
   measurement build, then DHCP test (W5100 bridge via the ESP32).
5. **Write FIFO restructure (−6 blocks)** B1b, and/or **DOC cache (−5)** B2,
   as the schedule allows — these are the medium/high-risk structural items;
   each is also worth 5–6 blocks on the a2mega. Either one brings the a2p25
   back to ≈ 47–48 / 56 with Uthernet2 in and opens the door to
   `DOC_BANKS_IN_BSRAM=1`.
6. **Logic for Mockingboard:** §7.4 (banks → BSRAM, DOC fetch path; the dominant lever), then B9 (−456 FF), B10 (−256 FF), B11 (−~250 FF)
   plus `DOC_BANKS_IN_BSRAM=1` (−~2 k logic for +5–9 blocks, affordable only
   after step 5). Expected position before enabling Mockingboard: ≈ 16.5 k
   logic / ≈ 12.5 k FF. Then `MOCKINGBOARD_ENABLE=1` and three timing rolls
   of the final source.

If only steps 1–4 are done, Uthernet2 fits and Mockingboard does not; the
Mockingboard needs the DOC banks moved to BSRAM, which in turn needs step 5.

## 6. Caveats

- Per-module REG/LUT are synthesis counts; PnR totals differ by < 1%
  (logic 18,675 vs 18,503; FF 15,233 vs 15,264).
- Physical BSRAM per memory is derived from the primitive netlist and the
  empirical mapping rule in §2, because Gowin's placement files are
  encrypted. The rule reproduces the PnR block type counts of seven builds
  exactly, but the underlying device reason should be confirmed in the GW5A
  BSRAM user guide.
- All savings are estimates from the RTL; they need a resource-measurement
  build each. None of the proposals has been built.
- The Enhanced reports are from 2026-08-01/09; the Enhanced source has moved
  since (GS auto-detect, HDD boot wait). The comparison is architectural, not
  a like-for-like snapshot.

## 7. Follow-up from review (ed, 2026-10-13)

### 7.1 DDR3-era sizing is not a requirement on PSRAM

Several structures flagged in §4 were sized for the a2mega's DDR3 latency, not
for the HyperRAM: the 64-entry × 128-bit write FIFO ("one full DDR3 128-bit
write per entry"), the 64-line DOC cache fetched as 4-beat bursts, the 8-bank
line-buffer prefetch, and the 16-deep shadow write FIFO (depth 8 overflowed
under DDR3 arbitration before the port-priority fix). The HyperRAM port is a
32-bit-beat port with a short, deterministic round trip (`hyperram_ports`
already splits the 128-bit framebuffer write into beats via
`wide_wr_data_hi`), so the beat-oriented restructures B1b and B2 are the
natural shape for this memory rather than a workaround. The next a2mega rev is
planned to carry the same PSRAM; once it does, the DDR3 path stops
constraining the shared HDL and both boards converge on the beat shape.
Depths (FIFO 64, cache 64 lines, 8 banks, shadow FIFO 16) should be re-sized
against measured PSRAM latency using the existing counters
(`dbg_fifo_overflow`, `dbg_line_not_ready`, `dbg_shadow_drop`,
`glu_wq_drops`, DOC `prime_miss`/`fetch_drop`) rather than inherited.

### 7.2 Uthernet2 socket buffer in PSRAM (−8 BSRAM, est.)

The W5100 emulation is prefetch-friendly: every Apple-side access is indirect
(address register, then data-port read/write with `MR.AI` auto-increment and
8 KB window wrap), so after each data-port access the next byte's address is
known. Apple accesses are ≥ ~1 µs apart; a HyperRAM read through the arbiter
is a few hundred ns at 54 MHz, so a byte prefetch after every access fits with
margin and needs no wait state (the Apple II bus has none we drive).

Proposal: keep `reg_mem` (2 KB, 1 block) in BSRAM; move `buf_mem` (16 KB,
8 blocks) to a HyperRAM region behind one more `hyperram_ports` port (or a
shared one with the GLU write port). Both the Apple data port and the ESP32
MACRAW bridge (`SPACE_W5100` writes in `esp32_ospi_connector`) go through that
port; writes are posted, reads are the prefetched byte, with a one-entry
write-forward for a read that follows a write to the same address.
Cost: ≈ 120 FF of arbiter queue + a small prefetch FSM (~60 FF / 80 LUT).
Result: Uthernet2 becomes a **1-block** feature, and with §5 step 1 alone
(56 → 48) it fits without the line-buffer change. Risk: medium (new port
in the arbiter, ESP32 bridge write path, DHCP/W5100 regression test);
`hdl/uthernet2/uthernet2.sv` is shared, so the PSRAM backing must be a
parameter with the BSRAM path as default for the Enhanced.

Rejected alternative: holding the socket buffer in the ESP32 and fetching
bytes over OSPI. A per-byte round trip cannot be served in the ~1 µs budget
from a FreeRTOS task, so it would need an FPGA-side window cache streamed by
the ESP32, and a window miss has no wait state to hide behind. More protocol
and a hard real-time dependency for a result the PSRAM path gives
deterministically.

### 7.3 `esp32_ospi_connector` size

At ≈ 1,070 REG / 1,318 LUT it matches the BL616 connector (1,000 / 1,334), so
it is not out of line with its counterpart, but half of its own flip-flops are
one item: `mem0`, the 64-byte SPACE 0 "test memory", kept in flip-flops to
avoid spending a BSRAM block — **512 FF** for a bring-up aid. Shrinking it to
a few bytes or generate-guarding it is a free ≈ 500 FF (low risk; the ESP32
firmware's link self-test uses SPACE 0 — check before removing). The rest is
legitimate: volume/HDD size and status registers (~160 FF), the two 32-bit HDD
access queues, GPU/video control registers, the 8-way read mux over the memory
spaces, and the protocol processor (194 FF / 588 LUT, same as the BL616's).
Add `mem0` to §5 step 2 (debug trim).

### 7.4 `sound_glu` + `doc5503_pipelined` — two separate causes

`sg` is 3,726 REG / 3,864 LUT / 14 physical BSRAM against 488 / 766 / 2 (+40
SSRAM) on the Enhanced. `sound_glu` itself is small (133 REG / 115 LUT; its
4-block write queue is B5). The rest splits into two unrelated causes:

| Part | a2p25 | Enhanced | Cause |
|---|---|---|---|
| DOC register banks (7 × 32×8 + 32×24 acc, each with a 32:1 read mux) | **2,560 REG / ~1,570 LUT** | 40 SSRAM | GW5A has no SSRAM → flip-flops. Independent of DDR3. |
| DOC core | **1,033 REG / 2,180 LUT**, 10 blocks (cache 8 + lookup 2) | 360 REG / 659 LUT, 0 | Rev-3 "service-tail latency" machinery for the DDR3 arbiter: 16-byte cache lines as 4-beat bursts (two 140-bit line registers, 64-entry tag/valid/run vectors, 140-bit byte-select mux), two-line-per-oscillator store with lookahead issue, FB-aware issue gating, 8-deep fetch FIFO, prime-pending tracking. |

**Banks → BSRAM (biggest logic lever on the device).** `DOC_BANKS_IN_BSRAM=1`
exists; under the §2 rule it must be sliced ≤ 18 bits wide: pair fl+fh,
vol+wds, wtp+control into 32 × 16 arrays (3 blocks), rts alone (1), acc as
2 × 32×12 (2) → **≈ 6 blocks for −2,560 FF / −1,570 LUT (est.)**. Not
DDR3-related; blocked only by BSRAM headroom, which §5 step 1 (−8) provides.

**DOC core → PSRAM-appropriate fetch path.** The rev-3 design hides
tens-of-microsecond DDR3 service tails. The HyperRAM round trip is short and
deterministic; the a2p25 keeps the same static-priority arbiter and the
framebuffer line fetch, so contention is not zero, but the existing counters
(`dbg_doc_prime_miss`, `dbg_doc_stale_fetch`, `dbg_doc_fetch_drop`,
`dbg_doc_req_mingap`) can measure it directly. Proposal: build a
`DOC_FETCH_MODE` parameter selecting a rev-2-style per-oscillator 32-bit word
cache with next-word prefetch (no line cache, no lookahead/gating), run the
POLY.SYNTH listening set with all 32 oscillators and the counters on the PC
line, and keep rev 3 only if the counters say so. Estimated **−500 REG /
−1,200 LUT / −8 BSRAM** (the line cache goes; the lookup RAMs shrink or go).
Risk: medium — it is a return to a known-simpler design, but the DOC fetch
cone is the usual timing offender and audio must be re-listened; shared with
the a2mega, where the DDR3 path keeps rev 3 until that board moves to PSRAM
too (then the same simplification applies there).

Taken together with B5, the `sg` block could come down from 3,726 / 3,864 /
14 to roughly **650 REG / 1,100 LUT / 10 BSRAM** (est.): the DOC stops being
the dominant logic consumer and the Mockingboard's ~775 REG / 1,300 LUT fits
in the recovered logic alone.

### 7.5 Preferred route: the a2n20 DOC on PSRAM, not a trimmed rev 3 (ed)

Rather than carve the latency machinery out of `doc5503_pipelined`, go back to
the baseline `doc5503.sv` (the a2n20v2 / Enhanced DOC) and adapt it to the
HyperRAM. Most of that adaptation already exists:

- `doc5503.sv` fetches through a request/ready interface (`wave_rd_o`,
  `wave_data_ready_i`) with a hard budget: the byte must return before
  `clk_count_r == 7`, i.e. ~7/8 of the oscillator cycle, **~838–978 ns**,
  otherwise it substitutes 0x80 (silence) for that sample. The real DOC's DRAM
  took 300–400 ns.
- `sound_glu` already has the external-memory path for it:
  `USE_BSRAM=0, USE_DDR3_PIPELINED=0` → `gen_glu_ddr3` with the baseline core
  (this was "rev 1" on the a2mega). The a2p25 top only has to flip
  `USE_DDR3_PIPELINED` from 1 to 0 — **a one-parameter build gives the
  resource measurement immediately.**

Why rev 1 failed on DDR3 and why PSRAM is different: the DDR3 arbiter showed
service tails of tens of µs for the lowest-priority port (header of
`doc5503_pipelined.sv`), so rev 1 hit the 0x80 timeout constantly (the
"stale-0x00 hazard" and 50–90% arbiter time). On the a2p25, `hyperram_ports`
is static-priority (port 0 highest) with non-preemptive grants, and the DOC
sits on port 2: above both framebuffer ports (4/5), below the two shadow
ports (0/1). Worst case before a DOC read is served ≈ one in-flight
framebuffer burst-8 (~370 ns at 108 MHz incl. latency) + up to two queued
shadow requests (~250 ns each) + its own burst-4 read (~250 ns) ≈ **1.1 µs
(est.)**; typical ≈ 400–600 ns. That is inside the budget typically and
marginal only at the tail. Mitigations, if the counters show timeouts:
move the DOC above the shadow ports (the shadow writes have their own FIFO
and the shadow reads a burst cache), shorten the FB read burst to 4, or
replace the 0x80 fallback by "hold the previous sample" (one 8-bit register
per oscillator, in the existing banks).

What it needs:

1. A build with `USE_DDR3_PIPELINED(0)` on the a2p25 (resource measurement;
   expected `sg` ≈ 3,050 REG / 2,350 LUT / 4 BSRAM with the banks still in
   FFs, i.e. **−~670 REG / −~1,500 LUT / −10 BSRAM** vs today; with the banks
   in BSRAM per §7.4 ≈ 500 REG / 800 LUT / ~10 BSRAM total, and the GLU queue
   fix B5a takes 2 more blocks back).
2. A timeout/stale counter on the baseline path (the `dbg_doc_*` counters
   exist only in the pipelined core) on the PC line, plus the POLY.SYNTH
   listening set with all 32 oscillators and the framebuffer in SHR mode
   (the worst arbiter load).
3. Shared-HDL note: `doc5503.sv` is the Enhanced/GS DOC; the PSRAM-specific
   part lives in `sound_glu`'s `gen_glu_ddr3` branch and the a2p25 top, so
   the Enhanced is unaffected. The a2mega keeps rev 3 on DDR3 and inherits
   this path when it moves to the same PSRAM.

This supersedes the "trim rev 3 / `DOC_FETCH_MODE`" proposal in §7.4 as the
first thing to try; rev 3 stays available behind the existing parameter if
the measurements say the HyperRAM tail is worse than estimated. Recommended
position in §5: run step 1 of this section **before** the §5 sequence — it is
one parameter, and its result (−10 BSRAM, −1.5 k LUT) changes how much of the
rest is needed.

**Measured (2026-10-13, resource build, `USE_DDR3_PIPELINED(0)`, otherwise
the audited tree; fs sha256 `c0a5d876…`, not flashed, not kept):**

| | audited (rev 3) | baseline DOC | delta |
|---|---|---|---|
| Logic | 18,675 (82%) | **15,706 (69%)** | **−2,969** |
| Registers (FF) | 15,233 (67%) | **14,277 (62%)** | −956 |
| CLS | 11,423 (99%) | 11,303 (99%) | placer spreading, unchanged |
| BSRAM | 56 / 56 | **46 / 56** | **−10** (SDPB 25 → 23, SDPX9B 14 → 6) |
| `sg` block | 3,726 REG / 3,864 LUT / 14 blk | **2,808 REG / 2,147 LUT / 4 blk** | −918 REG / −1,717 LUT / −10 blk |
| of which `doc5503` core (self) | 1,033 / 2,180 | **361 / 568** | the rev-3 machinery: −672 REG / −1,612 LUT |
| of which register banks (FF) | 2,560 / 1,568 | 2,336 / 1,456 | still flip-flops (§7.4 lever untouched) |
| Timing | 0 violations, thin | 4 setup violations: `i_hr_ctrl` `ck_en` half-cycle stage on clk_mem (−0.62, the known flapper), 3 AUX-channel paths on clk100 (−0.24 / −0.11 / −0.11) | not DOC-related; single roll, no closure attempted |

The logic saving (−3 k, −13 points) is larger than the §7.5 estimate because
the baseline core is lighter than the pipelined core's self figure suggested.
The remaining `sg` cost is almost entirely the FF register banks (2,336 of
2,808 REG), so §7.4 (banks → ≈ 6 BSRAM, now affordable at 46/56) would take
the block to ≈ 470 REG / 700 LUT. Functional verification of the baseline
DOC on HyperRAM (timeout counter, POLY.SYNTH set under SHR load) is still to
do; this build measured resources only.

**Measured (2026-10-13, second resource build: baseline DOC + banks in BSRAM;
fs sha256 `0156a6d0…`, not flashed, not kept):**

| | audited (rev 3) | baseline DOC | + banks in BSRAM | delta vs audited |
|---|---|---|---|---|
| Logic | 18,675 (82%) | 15,706 (69%) | **14,337 (63%)** | **−4,338** |
| Registers (FF) | 15,233 (67%) | 14,277 (62%) | **12,039 (53%)** | **−3,194** |
| CLS | 11,423 (99%) | 11,303 (99%) | **10,823 (94%)** | −600 |
| BSRAM | 56 / 56 | 46 / 56 | **54 / 56** | −2 (banks = 8 blocks, as `SP` primitives) |
| `sg` block | 3,726 REG / 3,864 LUT / 14 blk | 2,808 / 2,147 / 4 | **570 REG / 798 LUT / 12 blk** | −3,156 REG / −3,066 LUT |
| Timing | 0 viol., margins < 1% | 4 violations | **0 violations; worst slack +0.10 ns (AUX `dbg_sink_status`, clk100); clk_mem 128 vs 108 MHz, clk_pix 161 vs 148.5, clk_hr 60.4 vs 54, clk100 101.0 vs 100** | first build with real margin on clk_mem / clk_pix |

Single roll; the clk100 AUX cone is still the thin one (+0.10), the rest is
comfortable. Mockingboard (≈ 775 REG / 1,300 LUT) now fits in the recovered
logic with room to spare; Uthernet2's 9 blocks do not yet (54/56) — §5 step 1
(−8) or the §7.2 PSRAM buffer is still needed for that.

Refinement of the §2 rule from this build: the banks inferred as **single-port
`SP` primitives**, and the 24-bit accumulator bank took **one** block (SP x24
did not double). The two-blocks rule is therefore specific to the
semi-dual-port x32/x36 primitives; single-port wide memories are one block.
Banks 32 × 8 / 32 × 4 / 32 × 6 at one block each are depth-wasteful (2% fill),
so pairing banks into 16-bit records would still take 8 → 5 blocks if those
blocks are needed later.

**What this build is not.** The FSM was left untouched, so the BSRAM banks
return data one cycle late in four places: `OSC_LOAD_PARTNER_CONTROL` and
`OSC_LOAD_NEXT_CONTROL` (control bank re-addressed the cycle before),
`prev_control_r` in `OSC_REQUEST_DATA` (address reverts to the current
oscillator by default, so the read must be re-asserted and consumed one state
later), and the host read-back in `device_response` (one cycle after
`host_request` sets the address). `OSC_LOAD_REGISTERS` is already safe (all
addresses have been at the current oscillator for ≥ 1 cycle). A correct
implementation adds a one-cycle wait to those four points behind the same
parameter (~15 FF, no BSRAM change); the host read-back also needs the
write-forward register (already in the bank module) so a read following a
write to the same register returns the new value. The pipelined DOC's BSRAM
banks hit a GW5A placement rejection (PA2122, read-before-write SP mode) —
the new `osc_reg_ram` BSRAM branch disables the read during a write and
forwards the written value instead, and placed cleanly here. There is no
baseline-DOC testbench in the repo; a simulation of the four consume points
against the FF-bank reference is the verification step before hardware.

RTL touched for this measurement (left uncommitted in the working tree for
review, all default-off so the Enhanced/GS builds are unchanged):
`hdl/sound/doc5503.sv` (`BANKS_IN_BSRAM` parameter + BSRAM branch in
`osc_reg_ram`), `hdl/sound/sound_glu.sv` (passes `DOC_BANKS_IN_BSRAM` to the
baseline core), `boards/a2p25/hdl/top.sv` (`USE_DDR3_PIPELINED(0)`,
`DOC_BANKS_IN_BSRAM(1)`).

### 7.6 UG300 (Arora V BSRAM & SSRAM User Guide, 1.3.6E) — byte enables and a correction to §2

Read 2026-10-13 from ed's copy of UG300E.pdf. Two consequences.

**Correction to the §2 rule.** Table 2-1 / 2-4 / 3-7 list 512 × 32 (SDPB) and
512 × 36 (SDPX9B) as single 16 / 18 Kbit configurations of one block, with
address bits [13:5]. The device does **not** need two blocks for an x32/x36
semi-dual-port memory. The 2-blocks-per-primitive mapping measured in §2 is
therefore what the toolchain did with *inferred* x32/x36 SDP memories in these
builds, not a device limit; an explicitly instantiated `SDPB`/`SDPX9B` with
`BIT_WIDTH 32/36` may well place in one block. The empirical cost model in §2
still describes the audited build exactly and remains the right planning
number for inferred memories, but a micro-test (one instantiated 512 × 36
SDPX9B, synth + PnR, ~5 min) should settle whether B1/B2/B4/B5 can be had by
instantiation alone. Single-port x24/x32/x36 placed in one block in the
§7.5 build, consistent with the tables.

**Byte enables (UG300 §3.1–3.3).** In SP x16/x32, SPX9 x18/x36, SDPB x16/x32,
SDPX9B x18/x36 and DPB x16 / DPX9B x18, the low address bits of the write
port are byte (8-bit) or 9-bit lane enables: `AD[0]` → lane 0 (`DI[7:0]` /
`DI[8:0]`), `AD[1]` → lane 1, `AD[2]` → lane 2, `AD[3]` → lane 3, active high,
with the word address in `AD[13:5]` (x32/x36) or `AD[13:4]` (x16/x18). Partial
writes into a packed record are therefore **single-cycle, no read-modify-write**.
Write modes on the 25K: normal and write-through; read-before-write is not
supported on any Arora V 25K/60K/75K/138K device (so same-address
read-during-write must be handled as in the §7.5 bank module: read disabled
during the write, value forwarded).

**Packed DOC register file with byte lanes.** The DOC's per-oscillator state is
fl 8, fh 8, vol 8, wds 8, wtp 8, control 4, rts 6, acc 24 = 74 bits used of
8 × 9-bit lanes = 72 — one lane short of two blocks, so the clean layout is
three x36 single-port blocks (or SDP, write port A with lanes, read port B):

| Block | Lane 0 | Lane 1 | Lane 2 | Lane 3 | Fill (32 of 512 words) |
|---|---|---|---|---|---|
| A (SPX9 512 × 36) | fl | fh | vol | wds | 6% |
| B (SPX9 512 × 36) | wtp | control (4 of 9) | rts (6 of 9) | acc[7:0] | 6% |
| C (SPX9 1K × 18, 2 lanes) | acc[15:8] | acc[23:16] | — | — | 3% |

**3 blocks instead of 8**, every bank write stays a single cycle (the lane
enables replace the per-bank write ports), and `OSC_LOAD_REGISTERS` reads all
eight banks in one access as before. Two blocks is possible only if acc shares
lanes with control/rts and the halt-time control write is folded into the acc
write, which changes the FSM's write sequence — not worth the block.

What a packed file changes in the baseline FSM (on top of the §7.5 wait
states, which apply unchanged):

1. **One read address instead of eight.** The FSM already reads sequentially
   (all banks at the current oscillator in `OSC_LOAD_REGISTERS`, then the
   control bank at partner / next / previous, then host reads), so the eight
   `ram_*_osc_r` address registers collapse to one. The control-bank reads at
   other oscillators return the whole record; the FSM takes the control lane.
2. **One write port shared by host and pipeline.** Today a host write (any
   bank) and a pipeline write (acc, wds, control) can land in the same cycle
   because the banks are separate. With one write port and one address, two
   writes to different oscillators collide; a host write must be held for one
   cycle when a pipeline write fires (the pipelined DOC does the equivalent by
   barring host processing from the `cycle_start` boundary cycle). The 6502
   bus leaves ample time for a one-cycle hold.
3. **Reset / `cycle_reset` writes** all eight banks per oscillator: one
   full-lane write per block, as now.
4. **Write-through semantics** for a host read following its own write: the
   forward register from §7.5 (one record wide).

Estimate: 3 BSRAM (−5 vs the §7.5 build, −2 vs the DPB pairing of §7.4),
≈ −40 FF (seven address registers and seven write-enable paths go away),
same read timing requirement as §7.5. Shared `doc5503.sv`, behind the same
`BANKS_IN_BSRAM` parameter; the Enhanced/GS keep the SSRAM banks. Simulation
of the four consume points and of a host-write/pipeline-write collision is the
verification step; there is no baseline DOC testbench yet, so that is the
first deliverable of the real implementation.

### 7.7 The x32/x36 doubling is a project option: `Convert_SDP32_36_to_SDP16_18`

Found while preparing the §7.6 micro-test: every process config in the repo
(a2p25, all dp_test/psram_test variants, a2mega 60K/138B, Enhanced, GS) carries
`"Convert_SDP32_36_to_SDP16_18" : true`. Gowin documents it (SUG100 §4
"Place & Route options", SUG1220 `set_option -convert_sdp32_36_to_sdp16_18`)
as "convert a 32/36-bit SDPB/SDPX9B into two 16/18-bit wide SDPB/SDPX9B,
Arora V devices only", with no stated reason; the IDE's option table
(`rtlplacerouteoptions5at.xml`, id PNR30) defaults it to **True** for GW5A, so
every project created in the IDE inherits it. UG300 lists 512 × 32 / 512 × 36
as native single-block SDP configurations. Nothing in UG300, the 1.9.12.01
release notes or the bundled manuals describes it as an erratum workaround.

**Measured (2026-10-13, third resource build: §7.5 tree + option `false`;
fs sha256 `f68bd4ae…`, not flashed, not kept):**

| | §7.5 build (option true) | option false | delta |
|---|---|---|---|
| BSRAM | 54 / 56 | **44 / 56** | **−10** (SDPB 23 → 16, SDPX9B 6 → 3) |
| Logic / FF / CLS | 14,337 / 12,039 / 10,823 | 14,338 / 12,079 / 10,821 | unchanged |
| Timing | 0 viol., worst +0.10 | **0 viol., worst +0.21** (`i_hr_ctrl` ck_cnt → gap_cnt, clk_mem) | clk_mem 110.5 vs 108, clk100 102.9 vs 100, others ≥ +8% |

Exactly the §2 prediction: write FIFO 10 → 5, GLU queue 4 → 2, pixel CDC FIFO
6 → 3. Against the audited build this tree is now **−4.3 k logic, −3.2 k FF,
−12 BSRAM** with three parameter/option changes and one default-off RTL branch.

Consequences:

- §2's "two blocks per x32/x36 SDP primitive" is **a toolchain setting, not
  the device**. The cost model stays correct for any project that keeps the
  option (all of ours today). §4 items B1a (write FIFO re-slicing) and B5a
  (GLU queue re-slicing) are moot with the option off; B4 (16-bit pixels in
  the CDC FIFO) would still take 3 → 2.
- The a2mega carries the same option on GW5AT-60 (108/118 BSRAM) and 138B; its
  x32/x36 SDP memories (framebuffer write FIFO, DOC cache, GLU queue, pixel
  FIFO at FIFO_LINES 11, D-PHY-less) are the same files, so turning it off
  there is worth a resource build too.
- **Open question before relying on it: why does Gowin default it on for
  Arora V?** A plausible reason is a silicon or timing limitation of the
  native x32/x36 SDP mode on some GW5A dies, in which case the split is a
  silent workaround. The three affected memories here (framebuffer write
  FIFO, GLU write queue, DP pixel CDC FIFO) are all exercised visibly —
  picture, DOC audio, DP video — so a hardware soak of this bitstream
  configuration (SHR + POLY.SYNTH + the framebuffer/underrun counters at
  zero over an hour) is the verification, plus a question to Gowin support
  / the GW5A-25 errata (DS1103) about the option's purpose. Until then the
  option stays `true` in the committed configs; the doc records the saving
  as available, not banked.

### 7.8 Why the option exists: Gowin Design Advisory 202409001

Primary source: Gowin **Design Advisory No. 202409001**, 1.0E, 2024-09-20
(English edition; the Chinese edition is ADV-SW-20240920 — same text; both
in ed's downloads, customer-restricted so not reproduced here). Verbatim on
the purpose: the option was added "to enhance the power supply noise tolerance
of 32/36-bit SDP under certain extreme power conditions (e.g., VCC ≤ 0.85V)",
for Gowin Software V1.9.10 and above (August 23, 2024), released 22 nm
devices. It is added to
Configuration → Place & Route → General with **default True**. Affected
devices include **GW5A-25 versions A and B** (the a2p25 part is GW5A-25A),
GW5AT-60 ES/B and GW5A(S)(T)-138 B/C (both a2mega SOMs), GW5AT-75 B/C and the
15K family. Customer impact: BSRAM usage of 32/36-bit SDP doubles, and
BSRAM-heavy designs may fail with PA2017 (BSRAM over the device limit). **When
that happens, verbatim: customers "can disable the conversion function by
setting 'Convert SDP32/36 to SDP16/18' to 'False' and ensure that the power
supply VCC is not below 0.9V."** Later SUG100 editions (4.4.7E, 09/2026) list
the option as also covering pROM/pROMX9 and state the default as False, so the
default may have been relaxed in a newer EDA release than our 1.9.12.01.

Assessment of the summary ed found: the first point (a silicon tolerance
limitation worked around in software) is correct in substance, although the
advisory describes it as power-noise margin at low VCC, not "instability in
early steppings". The second and third points (Fmax and routing-congestion
benefits) are not in the advisory, SUG100, SUG1220 or UG300; the measured
builds show no timing effect from the option either way (§7.7: logic and CLS
identical, worst slack +0.21 vs +0.10 on an unrelated cone). Treat those two
as unsupported.

**What it means for us.** The GW5A-25 LV recommended VCC range is 0.87–1.03 V
(DS1103 Table 3-6); the process configs set VCC = 0.9 V. The advisory's
condition for disabling the conversion is VCC ≥ 0.9 V at the die, i.e. the
nominal with no droop allowance, while the problem regime is ≤ 0.85 V, below
the device's own recommended minimum. On both boards the core rail is
generated on the Sipeed SOM (a2-p25 `fpga_som_btb0/1`, a2mega Tang Mega SOM),
so the margin is the SOM regulator's set point and load regulation, which we
do not control. Options, in order:

1. **Measure VCC on the SOM** under the worst load (full core, SHR, DOC,
   DP running) with a scope on the core rail — if it sits at ≥ 0.9 V with
   ripple staying well above 0.87 V, the advisory's condition is met and the
   option can be turned off, worth −10 BSRAM on the a2p25 and a similar count
   on the a2mega. Record the measurement in this doc.
2. If the rail is marginal, the SOM's regulator set point may be adjustable
   (feedback divider) — a board/SOM question, not a gateware one.
3. Otherwise keep the option on and take the width out of the memories
   instead (B1b, B2, B4, B5b): the §2 cost model stays in force.

Either way the conversion is a **supply-margin workaround**, not a functional
or timing requirement, and the §7.7 bitstream is a valid design; what needs
verification is the board's VCC, not the netlist.

### 7.9 The a2p25 core rail: Tang Primer 25K SOM (schematic 52300, 2023-05-19)

The GW5A-25 core supply `VDD_0V9` is generated on the Sipeed SOM by U1302, a
Silergy SY8089A-class 1.5 MHz buck (SOT23-5, 2.2 µH, 10 µF in, 2 × 22 µF +
100 nF out), fed from `VCC_5V`. Feedback divider: R1310 = 51 kΩ (top), R1311 =
100 kΩ (bottom), both 1%. The same 0.6 V reference reproduces the TMI7003C's
1.8 / 3.3 / 2.5 V rails from their dividers, so the reading is consistent.

| | Value |
|---|---|
| Set point | 0.6 V × (1 + 51/100) = **0.906 V** nominal |
| VREF (SY8089A1 datasheet, 0.5 A CCM) | 591 / 600 / 609 mV (±1.5%) |
| Static worst case incl. 1% resistors | **0.886 – 0.926 V** |
| GW5A-25 LV recommended VCC (DS1103 Table 3-6) | 0.87 – 1.03 V |
| Advisory condition for disabling the SDP conversion | VCC ≥ 0.9 V |
| Advisory problem regime | VCC ≤ 0.85 V |

So, by design: the rail meets the device's recommended range with 16 mV of
static margin at the low corner, sits inside the advisory's problem regime by
no less than 36 mV even at the worst static corner, but **does not guarantee
the advisory's ≥ 0.9 V condition** (nominal 0.906 V, worst-case low 0.886 V,
before load-step droop and ripple). Turning the conversion off on an
unmodified SOM is therefore a judgement call with a thin paper margin, not a
clean pass. It is likely fine on a given board (the low corner needs a
−1.5% reference and both resistors at their 1% extremes in the same
direction), but it is not something to ship on.

Two ways to make it clean:

1. **Measure first.** Scope `VDD_0V9` at the SOM output capacitors under the
   full core (SHR scrolling, DOC playing, DP up) and record min/mean/ripple;
   if it is ≥ 0.9 V with droop clear of 0.87 V, note the board serial and the
   value here. This is a one-evening check and also tells us whether the rail
   is quiet enough that the advisory's concern is academic for this load.
2. **Raise the set point (one 0402 on the SOM).** The LV part is specified for
   0.9 V or 1.0 V core (DS1103 §1: "Core Power (LV version): 0.9V / 1.0V").
   Replacing R1311 100 kΩ with 86.6 kΩ gives 0.953 V (worst case 0.93 – 0.98 V,
   centred in the 0.87 – 1.03 V window, satisfies the advisory with ≥ 30 mV
   to spare); 76.8 kΩ gives 0.998 V (worst case 0.975 – 1.022 V, inside the
   1.03 V max) for the 1.0 V operating point at roughly 20 % more core power.
   Either way set `"VCC"` in the process config to match, since the timing and
   power models take it from there. This is a SOM modification, so it belongs
   with the board-rev notes, not the gateware.

With either (1) confirmed or (2) done, `Convert_SDP32_36_to_SDP16_18 = false`
is the cheapest −10 BSRAM in this document. Without them, keep the option on
and recover the blocks through B1b / B2 / B4 / B5b.

The a2mega's SOMs (Tang Mega 60K / 138K) have their own core regulators; the
same measurement applies there before the option is changed in its configs.

### 7.10 Decision (ed, 2026-10-13): leave `Convert_SDP32_36_to_SDP16_18` on

Gowin defaults the conversion on for every released 22 nm device precisely so
that customers get the low-VCC margin without reading the advisory; our core
rail (§7.9) does not guarantee the ≥ 0.9 V condition Gowin attaches to turning
it off. The −10 BSRAM of §7.7 is therefore **not banked**: the option stays
`true` in every process config (a2p25 and a2mega), and the §2 cost model —
two blocks per x32/x36 semi-dual-port primitive, i.e. `ceil(width/18)` blocks
per memory — is the planning rule for this project. The §7.7 build remains
useful only as proof that the netlist itself is sound at 44 blocks.

Consequences for the plan:

- BSRAM is recovered by taking width out of the memories, not by the option:
  B4 (16-bit pixels in the CDC FIFO, −2), B5a (GLU queue as ≤ 18-bit slices,
  −2), B1a/B1b (framebuffer write FIFO re-sliced −1, or beat-organised −6),
  B2 (DOC cache by beat, −5; moot once the baseline DOC of §7.5 is adopted,
  which removes the cache altogether), §7.6 packed DOC register file (−5 vs
  the §7.5 banks). Any new memory on GW5A should be written as x18-or-narrower
  primitives from the start.
- Position after the measured §7.5 tree (baseline DOC, banks in BSRAM, option
  on): 54 / 56 BSRAM, 14.3 k logic, 12.0 k FF. Uthernet2 (9 blocks) needs
  ≥ 9 freed: §7.6 packed banks (−5) + B4 (−2) + B5a (−2) + B7 PLL ROMs (−2) +
  B7b slotmaker (−1) = −12 → 42 + 9 = 51 / 56 with Uthernet2 in, none of it
  touching the write FIFO or the HyperRAM path. The §7.2 PSRAM socket buffer
  (−8 more) stays as the next step if blocks get tight again.
- Any EDA upgrade must be checked for a changed default (SUG100 4.4.7E already
  documents the option as default False): the committed process configs pin
  the value explicitly, and a resource build after each toolchain change should
  confirm the BSRAM count did not move.

### 7.11 Implementation: baseline DOC with DPB register banks (2026-10-13)

Implemented in `hdl/sound/doc5503.sv` behind `BANKS_IN_BSRAM` (default 0 —
the Enhanced/GS keep their SSRAM banks, byte-identical RTL path), selected by
`sound_glu`'s existing `DOC_BANKS_IN_BSRAM`, and enabled in the a2p25 top
together with `USE_DDR3_PIPELINED(0)`.

Design:

- **Five Gowin DPB blocks (true dual-port, 1K × 16, byte-lane enables),
  instantiated directly** (`osc_reg_bank_dpb`), two banks per block:
  fl|fh, vol|wds, wtp|control, rts|acc[7:0], acc[15:8]|acc[23:16]. Byte
  lanes make every bank write a single cycle with no read-modify-write
  (UG300 §3.1: for 16-bit DPB, `AD[0]`/`AD[1]` enable the two lanes, word
  address in `AD[13:4]`). Bypass read mode (one-cycle registered read),
  normal write mode (output holds on write; Arora V has no read-before-write).
- **Port A = oscillator pipeline, port B = host.** Host register writes and
  reads leave the pipeline's address registers entirely, so a host access can
  never re-address a bank the pipeline is about to read. Port B is addressed
  by the already-latched host address, so the existing `device_response`
  timing holds unchanged. Pairs share one port-A address; the FSM already
  keeps the two banks of a pair at the same address in every state (the only
  re-addressed bank in a state is the one being read or written).
- **Three timing fixes for the registered read:** one wait cycle each before
  consuming the partner and next-oscillator control words (`bank_wait_r`);
  the previous oscillator's control latched one cycle after
  `OSC_REQUEST_DATA`, in whatever state follows (`prev_ctl_pend_r`); and a
  one-cycle hold of `OSC_LOAD_REGISTERS` when a port-B write landed on the
  previous edge (`hb_wr_last_r`) — the one case where a host write and the
  pipeline's bank read meet on the same clock edge (a host access captured
  just before the slot boundary executes in the forced-IDLE cycle). ~3 extra
  cycles per oscillator slot out of ~60.
- A `DOC_SIM_CHECKS` assertion in the bank wrapper flags any same-address,
  same-lane write on both ports (the FSM never issues one).

Verification — `sim/doc5503/tb_banks_equiv.sv` / `run_banks_equiv.sh`
(iverilog + the Gowin GW5A `prim_sim.v`, so the simulated DPB is Gowin's own
model, byte enables included). Two baseline cores, FF banks vs DPB banks,
identical clocks, host traffic and a shared wavetable; compared: mixer
outputs and all 16 channel sums every clock, the ordered fetch-address
stream, every host read-back, debug taps at slot boundaries. Stimulus: 32
oscillators in random modes/table sizes, 400 host writes/reads swept across
every slot offset, 512 targeted writes to oscillator K timed to land in K's
own forced-IDLE cycle, full register read-back, wavetable rewrite under
playback, halt/one-shot/swap/sync paths, enable-count changes. **Three seeds
pass with zero mismatches**; coverage shows the hold path taken 33 times for
the loaded oscillator and the wait path ~48 k times. Negative controls that
force the hold or the wait off fail with tens of thousands of mismatches, so
the comparator detects each fix being removed. The existing `run.sh`
differential suite (baseline vs pipelined) is the FF-path regression.

**Measured (a2p25 full build, this implementation; fs `06e4c284…`, not
flashed):**

| | audited (rev 3) | §7.5 measurement (SP banks, FSM untimed) | **this** |
|---|---|---|---|
| Logic | 18,675 (82%) | 14,337 (63%) | **14,202 (62%)** |
| Registers | 15,233 (67%) | 12,039 (53%) | **11,960 (52%)** |
| CLS | 11,423 (99%) | 10,823 (94%) | **10,763 (94%)** |
| BSRAM | 56 / 56 | 54 / 56 | **51 / 56** (banks = 5 DPB) |
| `sg` block | 3,726 REG / 3,864 LUT / 14 blk | 570 / 798 / 12 | **451 REG / 551 LUT / 9 blk** |
| Timing | 0 viol., margins < 1% | 0 viol., worst +0.10 | 0 viol., worst **+0.005** (clk_pix `aud_acc`, top-level audio accumulator — roll variance, not a DOC cone); clk_mem 122 vs 108, clk_sym 101.6 vs 81 |

Against the audited build: **−4,473 logic, −3,273 FF, −5 BSRAM**, and the DOC
block is now one eighth of its former size. Not durable yet by the project's
bar (three clean rolls of the final source at ≥ +0.5 ns); the thin cones are
the AUX channel on clk100 and the audio accumulator on clk_pix, neither in
the changed logic.

Still to do before this ships: hardware listening pass on the a2p25 (system
beep, POLY.SYNTH set, 32-oscillator titles) with the DOC fetch-timeout
behaviour watched (the baseline substitutes 0x80 on a late HyperRAM read —
a stale/timeout counter on the baseline path is still worth adding), and
the a2mega keeps `USE_DDR3_PIPELINED(1)` until it moves to PSRAM.

### 7.12 First listening pass: mild distortion → stale-fetch cascade; fix + telemetry (2026-10-13 night)

**Observed (ed):** bitstream `acb48491…` (baseline DOC, DPB banks, DOC on HyperRAM
port 2) flashed and played; audibly distorted, but far less than the old
pipelined-core distortion — "a few samples" wrong, not harmonics.

**Diagnosis (by analysis and simulation; the machine was powered down before
telemetry could be read):** the baseline DOC gives each wavetable fetch ~7/8 of
the oscillator slot (≈840 ns at 7.159 MHz) and substitutes 0x80 when the read
is late. At port 2 of `hyperram_ports` (static priority, non-preemptive grants)
a DOC read could wait behind an in-flight framebuffer burst-8 (~290 ns), two
queued shadow transactions (~200 ns each) and its own ~170 ns read — at or over
the budget under SHR load. Each late read then costs **two** faults:

1. the 0x80 substitute for that sample (a tick), and
2. the "rev-1 stale hazard": the response is untagged, so when it arrives the
   GLU hands it to the DOC, which is by then fetching for the *next*
   oscillator and takes it as that oscillator's sample through the wrong byte
   lane; that oscillator's own response is left pending for the one after,
   and so on until a timeout happens to realign the stream. One late read
   corrupts a run of following oscillators — exactly "a few wrong samples".
   The pipelined core's line cache existed in part to sidestep this.

**Fix (three parts, all in the committed tree):**

- **`hdl/sound/doc_fetch_filter.sv` (new; proposal only, never committed: it was replaced by `hdl/sound/doc_fetch_cache.sv`, item 2 of the cache section below), used by `sound_glu`'s
  `gen_doc_ext` branch.** Responses come back in request order, so the filter
  keeps "accepted requests outstanding" and "of those, superseded": every DOC
  request supersedes everything still outstanding (the DOC has moved on,
  whether or not the arbiter took the request); only accepted requests
  (`rd && available`) count as outstanding, because a request issued into a
  full two-slot port queue is silently dropped and never answered. Superseded
  responses are discarded and counted; the byte lane is that of the newest
  request. No counter can saturate under real conditions (≤ 2 outstanding).
- **`doc5503.sv`:** a response arriving in the cycle the DOC presents a new
  request (`wave_rd_o` high) cannot be its own and is ignored — a one-cycle
  window the filter cannot see (it learns of the request a cycle later); a
  response landing exactly on the deadline edge is dropped rather than left
  pending for the next oscillator. Plus telemetry: fetch timeouts (wrapping)
  and max fetch latency (saturating, in 18.5 ns clk cycles).
- **a2p25 top: DOC moved to HyperRAM port 0** (shadow read 1, shadow write 2,
  GLU 3, FB 4/5, debug 6). Worst case before a DOC read is now one in-flight
  grant plus its own read, ≈ 500 ns — inside the budget. A DOC read is one
  word per ~1 µs, so the shadow paths lose at most ~170 ns per µs.

**Telemetry on the ESP32 console, no firmware change:** on the a2p25 the two
$C029 debug registers now carry DOC counters, so `viddbg` prints
`C029 writes=<DOC fetch timeouts, wraps at 256> last=0x<max fetch latency in
clk_logic cycles>`. 0x2D ≈ 45 cycles ≈ 840 ns is the budget; anything at or
above it means timeouts. Timeouts of 0 and a latmax well under 0x2D after a
POLY.SYNTH run is the pass condition. (The a2mega keeps $C029 on those
registers.) The filter's discard count is on DebugOverlay hex 6 only.

**Verification:**

- `sim/doc5503/tb_fetch_late.sv` / `run_fetch_late.sh` (proposed bench, not in the tree; the committed benches are in `sim/doc5503/`): baseline DOC + filter
  on a memory model with a two-slot acceptance queue, in-order service and
  random latency swept from fast (2–20 clk) through realistic tail (10–80
  clk, some fetches late) to pathological (50–120 clk, every fetch late,
  requests dropped). Every consumed sample is checked against the address
  requested for that slot. Result: **0 stale samples** across ~2,900
  timeouts and 5 dropped requests; the filter's discard counter and the
  DOC's timeout/latmax counters move as expected. Negative control (filter
  accounting forced off): 1,541 stale samples. Two earlier guard designs
  (DOC-side owed counter; filter superseding on accepted requests only) were
  caught by this bench — saturation above 7 outstanding, and the
  dropped-request case respectively — before reaching hardware.
- `run_banks_equiv.sh` (FF vs DPB banks): 3 seeds pass unchanged.
- `run.sh` (baseline vs pipelined, Verilator co-sim): see commit message.

**Build (flash-ready, NOT flashed — machine powered down):**
`boards/a2p25/impl/pnr/a2p25.fs`, sha256 `bbd899c0…` — 0 violations, worst
slack +0.10 ns (`i_hr_ctrl` cycle counter, clk_mem), clk_mem 109.2 vs 108,
clk100 101.4 vs 100, others ≥ +8%; logic 14,177 / FF 11,986 / BSRAM 51.

**Morning checklist:**

1. Mac on USB1, ESP32 in the application (not download mode — if `--detect`
   reports a non-Gowin IDCODE, open the CDC port once to reset it, as
   tonight), IIgs on. `GPRJ=a2p25.gprj tools/flash.sh a2p25` detached, no
   caller timeout. Power-cycle the IIgs.
2. Listening set: beep + Control Panel sliders, POLY.SYNTH, synthLAB, Music
   Construction Set, a 32-oscillator title, swap/sync instruments.
3. After each title: console `viddbg` → `C029 writes` (timeouts) and `last`
   (latmax). Expected: timeouts 0 (or not advancing between reads), latmax
   < 0x2D. If timeouts advance with the DOC at port 0, the HyperRAM round
   trip itself is longer than estimated and the next lever is the DOC's
   budget (request earlier in the slot) or burst length.
4. Also glance at `vgc stale-word swaps/frame` and `shadow-write drops` in
   the same `viddbg` output: both must stay 0 with the DOC above the shadow
   ports.

### 7.13 Second listening pass (2026-10-14): fix confirmed, WiFi telemetry, residual tail

**Result.** Bitstream `bbd899c0…` (fetch filter + DOC on HyperRAM port 0,
§7.12) flashed over USB: system beep and Arkanoid clean where the previous
image was distorted — the stale-fetch cascade was the mechanism.

**Telemetry over WiFi (no USB).** The a2p25's USB1 is normally in USB-host
mode with the image stick attached, so the CDC console is not a monitoring
path; the bench rule from the a2mega applies (WiFi only). Three facts learned
the hard way, all fixed in the ESP32 firmware (`boards/a2mega/src/a2fpga_esp32`,
BOARD_REV=225) and installed over WiFi via FTP → FIRMWARE menu → OTA:

1. The telnet remote console is **single-key**: typing a CLI word into it
   fires keys (`v` virtual DP replug, `g` FPGA reload …). Never send text to
   it. New key **`z`** prints the video/DOC debug block (FPGA regs 0x70–0x78)
   into the console tee; keys are listed in the banner.
2. The OSPI link to the FPGA is shared with the disk-serving and menu tasks
   under `fpga_link_lock()`. A burst of raw `a2spi_reg_read_status` calls
   outside that lock (the CLI's `viddbg`, and the first `z` versions) collides
   with disk streaming, panics the ESP32, and the reboot holds the Apple II in
   reset — seen twice as "the read reset the Apple". `z` is now serviced in
   `loop()` under the lock; the CLI `viddbg` takes the lock too.
3. The telnet server is single-client and drops idle sessions after a few
   seconds; read in short sessions.

The `z` block on this board: `VIDDBG MODE .. FB .. OVFL .. RD ..`,
`DOC TIMEOUTS n LATMAX n CLK (0x..)` (regs 0x71/0x72, wrapping / saturating),
`VGC HSYNC n STALE n SHADOW DROPS n`. Reading it over telnet during Arkanoid
with the fixed firmware: stable, no reboot.

**Measured under Arkanoid (SHR + disk serving + DOC):** `DOC TIMEOUTS`
advancing at **~0.4/s**, `LATMAX 0x2D` (= the ~830 ns budget, i.e. the
completed-fetch maximum is pinned at the deadline), VGC hsync 0, stale 0,
shadow drops 0. So with the DOC at port 0 the HyperRAM round trip still has a
rare tail past the budget — consistent with a 2× latency refresh collision
(RWDS-signalled, `hyperram_ctrl` header) landing behind an in-flight
framebuffer burst — and each event still cost one 0x80 sample.

**Change (built, not yet flashed): hold the previous sample on a late fetch.**
`doc5503` now keeps `curr_wds_r` (the oscillator's own last sample, loaded
from its wds register) instead of substituting 0x80 when a fetch misses the
slot deadline: a repeated sample is inaudible, a jump to mid-level is a click.
Zero-byte halt detection is unaffected; BSRAM boards never reach the branch.
`run_fetch_late.sh` and `run_banks_equiv.sh` pass. Build `5e51b3d3…`:
0 violations, worst +0.044 ns (`i_hr_ctrl` ck_en half-cycle stage — the
known flapper), logic 14,113 / FF 11,986 / BSRAM 51.

**Firmware staged for WiFi gateware updates:** `fpga_jtag.h` /
`fpgastream.c` / `fpgaupdate.c` now accept the GW5A-25 IDCODE `0x0001281B`
(image header and live chip), so `fpga_stream.py` and the FIRMWARE menu's
UPDATE FPGA can serve the a2p25 — uploaded as `a2fpga_esp32_gw5a25.bin`,
**not installed**: the native JTAG-SPI flash path is untested on this die
(it works on GW5AT-60, is broken on a configured 138K), and a failed write
would need the Mac on USB1 (stick removed) to recover. First use should be
with that recovery at hand.

**WiFi gateware update works on the GW5A-25 (2026-10-14, first use).** With the
IDCODE gate opened, the FIRMWARE menu's UPDATE FPGA took `a2p25_hold.bin`
(928,845 B, FTP-dropped onto the stick) through check → `READY` → `INSTALL
NOW` → erase/program/verify → `FPGA: DONE, RELOADING` (printed only after the
verify loop passes) → ESP32 restart, fabric back up, `z` answering. The a2p25
is now fully WiFi-maintainable: ESP32 firmware (FTP + UPDATE MCU, OTA slots),
gateware (FTP + UPDATE FPGA, or `tools/fpga_stream.py <ip> <bin>` on port
2323), telemetry (telnet `z`). Bitstream `5e51b3d3…` (hold previous sample
on a late fetch) is what the board runs from here.

**Listening result on `5e51b3d3…` (ed, 2026-10-14):** on the previous image
(0x80 on a late fetch) pops and crackles were audible during Arkanoid; with
the previous sample held instead they are gone, while the telemetry shows the
same ~0.4 late fetches/s (7 in 16 s, LATMAX 0x2D) and all video counters at 0.
So the residual HyperRAM tail is now silent rather than removed; driving the
rate itself to zero (shorter FB read burst, or issuing the DOC fetch earlier
in the slot) is optional and only worth doing if a title still shows it.
Further titles (POLY.SYNTH, synthLAB, Music Construction Set, 32-oscillator
songs, swap/loop instruments) remain to be listened to; telnet `z` gives the
counters per title.

### 7.14 Marble Madness: bandwidth, not latency — DOC word cache (2026-10-14)

**Observed (ed):** vertical displaced smearing on screen, audio fine.
`z` readings during play: `FB 0x16 / 0x32` (bit 1 = **framebuffer write FIFO
overflow**, sticky — clear in every previous read), `VGC STALE 32 / 13 / 6`
per frame (0 before), DOC late fetches **~7/s** (0.4/s under Arkanoid). All
three are one symptom: with the baseline DOC fetching one byte per oscillator
per slot, a title that drives the Ensoniq hard puts ~15% of the HyperRAM bus
under DOC reads at top priority, and the renderer's write port (priority 4,
64-entry FIFO) and the VGC's shadow reads both starve. Dropped renderer writes
leave pixels from the previous frame behind — the displaced smear. This is the
cost the pipelined core's 16-byte line cache was paying for; the baseline's
~4× higher fetch rate is the one thing §7.5 did not weigh.

**Two fixes, both in the next build:**

1. **Priority order:** shadow read 0, **DOC 1**, shadow write 2, GLU 3, FB
   write 4, FB read 5, debug 6. A late DOC fetch is now silent (§7.13 hold),
   a late VGC word is visible, so the VGC goes back above the DOC; the DOC
   stays above the shadow write FIFO and the framebuffer (the cascade fix of
   §7.12 does not depend on being at 0).
2. **`hdl/sound/doc_fetch_cache.sv`** (replaces `doc_fetch_filter.sv`, in
   every gprj that lists `sound_glu.sv`): a 64-word direct-mapped cache
   between the DOC and the HyperRAM port. Sequential wavetable walks at
   ≤ 1 byte/sample hit the same 32-bit word up to four times, so the DOC's
   bus share drops ~4× and hits are answered in two cycles (no deadline
   exposure). Index = `addr[7:2] ^ addr[13:8]` (oscillators parked at the same
   offset of different 256-byte tables do not evict each other), tag
   `addr[15:8]`; data in one single-port BSRAM (64 × 32, SP x32 = 1 block),
   tags/valid in ~600 FF. It also owns request ordering (the filter's job:
   anything outstanding is superseded by the next DOC request; only
   port-accepted reads are tracked). Coherency: all valid bits cleared on
   every GLU sound-RAM write and again when that write leaves the 32-deep
   queue for memory. Counters: hits/misses on connector regs 0x7E/0x7F
   (`viddbg`/`z` line `DOC CACHE HITS n MISS n`), superseded on the overlay.

**Verification:** `sim/doc5503/tb_fetch_cache.sv` / `run_fetch_cache.sh`:
DOC + cache on the two-slot in-order memory model, fast → tail → rewrite-
under-playback (3,000 wavetable writes with flush) → pathological phases;
every consumed byte checked against the current memory content of its
request address. **0 stale samples**; hit rate 40% on the bench's
deliberately fast walks (half the oscillators step 1–4.5 bytes/sample);
`+noflush` negative control: stale cached words. The equivalence suite and
`run.sh` are the regressions for the DOC core itself.

**Expectation on hardware:** Marble Madness with `FB` bit 1 clear, `VGC STALE`
0, `SHADOW DROPS` 0, DOC late fetches well under 1/s, and a hit/miss ratio
that tells us the real-world traffic reduction. If the write FIFO still
overflows with the DOC's traffic cut, the remaining lever is the framebuffer
write port's priority relative to the GLU write queue (both are "must not
drop" paths; the GLU queue is 32 deep with its own drop counter).

**Hardware, cache build `651bf82d…` (shadow read 0 / DOC 1 / 64-word cache),
Marble Madness, 2026-10-14:** `FB` bit 1 (write-FIFO overflow) **clear** in
every read (0x30 / 0x14 / 0x34 — was 0x16 / 0x32), `VGC STALE` 0 / 2 / 0 per
frame (was 6–32), `SHADOW DROPS` 0. The bandwidth symptom is gone. Two
telemetry lessons from the same session: (1) connector register 0x7F reads
as 0 through the OSPI protocol (not investigated; 0x7E worked) — the pair is
removed; (2) 8-bit wrapping counters cannot resolve rates of hundreds to
hundreds of thousands per second between reads seconds apart, so the DOC
fetch telemetry is now **latched per video frame** in the top (16-bit:
requests, memory reads = cache misses, late fetches) on connector regs
0x3C/3D, 0x3E/3F, 0x2F/0x4F, printed by `z` as `DOC/FRAME REQ n MEMRD n LATE n`.
Expected on Marble Madness: REQ ≈ (active oscillators) × 557 per frame
(32 slots per 35.7 µs scan, 16.7 ms frame), MEMRD a fraction of REQ equal to
the miss rate, LATE a small number — all unambiguous.
**Ed, Marble Madness on `651bf82d…`:** smear gone, audio clean.

**Per-frame telemetry, `add13bfb…`, Marble Madness (2026-10-14):**
`REQ 6150` (14 oscillators — see the §7.19 calibration; the 557/oscillator
figure above was wrong), `MEMRD 212 / 377 / 245` (3–6% of fetches reach
the HyperRAM: the cache cuts DOC traffic 16–29×), `LATE 17 / 33 / 15` (6–9% of
misses cross the deadline — held samples, inaudible), FB bit 1 clear, VGC
stale 0, shadow drops 0. Next: prefetch word+1 on every miss (sequential
walks), which converts most of those late misses into early hits at no extra
bus traffic.

### 7.15 Core build stamp in the OSD (2026-10-15)

The ESP32 menu reads the gateware build stamp through register 0x3F (write a
digit index 0–13, read the ASCII digit; 14 digits YYYYMMDDHHMMSS — the BL616
connector's convention, `fpga_core_version()` in menu.c). The ESP32 connector
never implemented it, so every a2mega/a2p25 core showed "CORE: (NO VERSION
REG)" and last night's "which image is running?" had to be answered from
install logs. `esp32_ospi_connector` now has `VERSION_STR` + `REG_CORE_BUILD`
(0x3F) and both tops pass `BUILD_DATETIME` (stamped by the build). The
telemetry byte that had landed on 0x3F moved to 0x5F (firmware follows).
Build `149ea423…` (stamp 20261015092235): 0 violations, worst +0.057, 52/56
BSRAM, logic 15,351 — awaiting the board (powered down). What the board boots
today is `edfc20fa…` (prefetch build, commit a3ad0704), verified-written over
WiFi before the shutdown; its Marble Madness per-frame read is still pending.
**Installed 2026-10-15 (WiFi, firmware then gateware):** FIRMWARE page now
reads `CORE OCT 15 2026 09:22:35` (= `149ea423…`). From here on "which image
is running" is a menu glance: telnet `m`, FIRMWARE, or the main-menu footer.

### 7.16 Prefetch measured and withdrawn; per-word invalidation (2026-10-15)

Marble Madness on `edfc20fa…` (prefetch word+1 on every miss), eight
per-frame samples over 40 s: `REQ 7028`, `MEMRD 1500–2000` (vs 212–377
without prefetch), `LATE 70–100` (vs 15–33), one `FB 0x32` (write-FIFO
overflow bit) — and in a quieter passage `REQ 1758 / MEMRD 1758`: every fetch
a miss, i.e. those instruments step a whole word or more per sample, so
word+1 is never the next fetch. The prefetch multiplied traffic by ~5 and the
extra queue depth made real misses later. **Withdrawn**: `PREFETCH` parameter
on `doc_fetch_cache`, default 0.

Kept and added: **per-word invalidation**. Every DOC-RAM write (and its
commit from the GLU queue) used to clear all 64 valid bits; on a title that
streams into sound RAM that wipes every oscillator's line per write. The GLU
now passes the written word address and only the matching line is
invalidated (outstanding reads for that line are flagged so their returned
word is not validated). Bench: 0 stale samples through 3,000 writes under
playback; the no-invalidate control still fails.

Build `cf0d626a…` (stamp `20261015153750`, installed over WiFi via the
FIRMWARE menu; 0 violations, worst +0.002 ns, 52/56 BSRAM, logic 15,047).
Marble Madness, three per-frame samples at `REQ 7028` (12–13 oscillators,
a busier passage than the 11-oscillator `REQ 6150` samples of §7.14):
`MEMRD 477 / 463 / 503` (6.6–7.2% of fetches reach memory), `LATE 28 / 38 / 27`,
`LATMAX 46 clk`, FB overflow bit clear, `VGC STALE 0`, `SHADOW DROPS 0`.
The prefetch regression (MEMRD 1500–2000, LATE 70–100) is gone; miss and
late rates are back in the §7.14 family. No visible smear, audio clean (ed).

### 7.17 Music Construction Set on `cf0d626a…` (2026-10-15)

Three per-frame samples while MCS plays:

- `REQ 6149 / 4832 / 5710`, `MEMRD 2491 / 2196 / 2169` — a **38–45 % miss
  rate** (Marble Madness: 7 %). MCS instruments step a word or more per
  sample, so the 4-byte line rarely serves a second fetch (the same
  behaviour that made the word+1 prefetch useless in §7.16).
- `LATE 186 / 156 / 165` per frame ≈ 3 % of fetches hold the previous
  sample (Marble Madness: 0.4–0.5 %). `LATMAX 46 clk` unchanged, so the tail
  is the same length; there is just far more of it.
- FB flags `0x36` on one sample: bit 1 = write-FIFO overflow count non-zero
  in that frame (bit 5 is merely "fetch active" at sample time). The other
  two samples read `0x30`, overflow clear. `VGC STALE 0`, `SHADOW DROPS 0`.

Reading: with the DOC port at priority 1 ahead of the FB write port, a
40 %-miss title puts ~2,300 extra word reads per frame on the HyperRAM
arbiter and the FB write accumulator occasionally overflows. Whether the
3 % hold-last-sample rate and the occasional overflow frame are audible or
visible is ed's call from the listening pass; levers if they are: the DOC
fetch budget (§7.13), a wider cache line (16-byte lines cost no extra
BSRAM in the SP block), or moving the DOC port below FB write with the
cache absorbing the latency.

**Verdict (ed, 2026-10-15): nothing audible or visible on MCS.** The 3 %
hold-last-sample rate and the occasional overflow frame are below the
perception threshold here; MCS passes on `cf0d626a…`. The levers above stay
on the shelf unless a later title shows them.

### 7.18 NinjaTracker on `cf0d626a…` (2026-10-15)

Three per-frame samples, text/non-SHR video mode (`MODE 0x31`):
`REQ 2023 / 1813 / 1359`, `MEMRD 274 / 224 / 85` (6–14 % miss),
`LATE 6 / 4 / 1` (≤ 0.3 % of fetches), `LATMAX 46 clk`, FB flags `0x14`
(overflow clear), `VGC STALE 0`, `SHADOW DROPS 0`. The lightest title so far:
a few oscillators, short loops that live in the cache.

Second song: `REQ 1812 / 2137 / 1934`, `MEMRD 274 / 314 / 367` (13–19 %
miss), `LATE 6 / 14 / 15` (≤ 0.8 %), FB overflow clear on all three
(`0x30` = fetch active at sample time only), `VGC STALE 0`,
`SHADOW DROPS 0`. Listening verdict pending.

### 7.19 Arkanoid read and the oscillator calibration (2026-10-15)

Three per-frame samples on `cf0d626a…`, SHR (`MODE 0xF1`):
`REQ 439 / 5710 / 439`, `MEMRD 0 / 280 / 0`, `LATE 0 / 20 / 0`, FB overflow
clear, `VGC STALE 0`, `SHADOW DROPS 0`. Two of the three frames caught the
game between sound effects with a single oscillator running; the middle one
caught an effect.

**Calibration.** `REQ 439` with one oscillator running pins the scan:
894,886 Hz / 34 slots (32 oscillators + the two idle slots the 5503 inserts
when $E1 enables all 32) / 60 Hz = **438.7 fetches per running oscillator per
frame**. Halted oscillators do not fetch, so REQ / 439 is the number of
oscillators running during the frame (fractions = oscillators that stopped
or started mid-frame). The earlier "557 per oscillator" estimate in §7.14 was
wrong. Re-derived counts for the readings so far:

- Arkanoid: 1 oscillator between effects, **13** during the effect sampled.
- Marble Madness (§7.14 / §7.16): `6150` → 14, `7028` → **16** oscillators.
- Music Construction Set (§7.17): `6149 / 4832 / 5710` → 14 / 11 / 13.
- NinjaTracker (§7.18): `1359`–`2137` → 3–5 oscillators.

So the heaviest titles seen run about half the DOC; a true 32-oscillator
load would be `REQ ≈ 14,000` per frame, and at the MCS miss rate that is
≈ 5,600 word reads per frame on the HyperRAM — the case synthLAB should show.

### 7.20 Arkanoid pops on `cf0d626a…` — differential test in progress (2026-10-15)

Ed, replaying Arkanoid on the current build after the §7.19 read: **pops that
were not there on the hold-last-sample build** (`5e51b3d3…`, no cache). The
drop handling itself has not changed since that build; the two changes since
the last clean Arkanoid listen are the word cache (§7.14) and the per-word
invalidation (§7.16). Arkanoid had not been replayed on any cache build
before this. Telemetry on the pop run was unremarkable (effect frame
`REQ 5710 / MEMRD 280 / LATE 20`, idle frames `REQ 439 / MEMRD 0 / LATE 0`),
which argues against the hold path and for a wrong *value* — a stale cached
word or a hit-path fault.

Attempted control with the two-day-old `a2p25_cache.bin` (`651bf82d…`):
**that core no longer boots the Arkanoid `.PO` image** ("unable to load
ProDOS", twice, image mounted and the Apple released after the mount). Its
provenance relative to the shadow-read/port-priority changes is uncertain,
so it was abandoned rather than debugged; the current build was reinstalled
(boot pending ed's confirmation). Two tooling notes from the detour:

- The UPDATE FPGA picker lists only the first 24 directory entries; a stick
  with many test images silently hides the rest. Twelve superseded images
  were deleted (ed's instruction). *Fixed 2026-11-14: the shared ESP32
  firmware now lists up to 128 entries per directory, alphabetized, and the
  picker shows a "LIST FULL" row when a folder exceeds that.*
- `.fs` → `.bin` is a straight pack of the bit lines (comments stripped);
  verified byte-identical against the IDE's `.bin` for the current build, so
  any committed `.fs` can be reinstalled over WiFi.

**Proper control built**: current source with `PER_WORD_INVALIDATE = 0`
(whole-cache flush on every write, the §7.14 behaviour) — a parameter on
`doc_fetch_cache` / `DOC_CACHE_PER_WORD_INVALIDATE` on `sound_glu`, default
1; only the a2p25 top is set to 0 for this build (not committed that way).
Build `f26cfbb5…`, stamp `20261015211207`, 0 violations (worst +0.040 ns),
logic 14,773, BSRAM 52/56. Staged as `a2p25_wholeflush.bin` for the stick
(board was powered down at upload time). Decision table: pops on it → the
cache hit/fill path; clean → the per-word invalidation.

**Update (ed, 2026-10-15 evening): the Arkanoid `.PO` image on the stick was
corrupted** — recopying it fixed the boot. So the "old core won't boot
ProDOS" verdict above was the image, not the `651bf82d…` core, and the pops
are now suspected to be corrupted wavetable data loaded from that image
(Arkanoid streams its samples from disk into sound RAM; bad bytes there pop
with perfectly clean fetch telemetry — which is exactly what §7.19 showed).
Listening verdict on the fresh copy pending. **Open issue: how the image was
corrupted.** Timeline: FTP uploads (three ~930 KB images) and twelve deletes
on the stick while the `.PO` was mounted and being served by the ESP32 —
FATFS/USB-MSC concurrency between the FTP task and the disk-serving task is
the prime suspect. Rule until understood: no FTP writes to the stick while
an image is mounted (unmount or power down first), and the control build
`f26cfbb5…` stays in the scratchpad.

**Update 2 (ed, 2026-10-15 late):** the hold-last-sample build (`5e51b3d3…`,
no cache) **has no pops** on the same fresh Arkanoid copy — the pops are a
cache-era regression (word cache or per-word invalidation), not the drop
handling and not the image. Fresh-copy telemetry on the current build was
normal (effect frames `REQ 3073 / MEMRD 204 / LATE 14`, idle `439 / 0 / 0`),
so the fault is a wrong sample *value*. Next discriminator: `a2p25_oldcache.bin`
(`add13bfb…` = cache + whole-cache flush + per-frame telemetry, already on
the stick, no upload needed).

**The image was corrupted a second time by the hold-build install alone (no
FTP).** Firmware reading: the menu/telnet install runs `fpgaupdate_poll()`
inside `disk_task`, the same task as `disk_poll()`, so serving is blocked
for the whole install and cannot write garbage blocks while the fabric is
dark; `hdd.sv` request flags reset clean; `esp_restart()` follows a
`fpga_jtag_reload()` + 2 s, with the image `fopen`ed `r+b` and every HDD
write `fflush`+`fsync`ed. Unexplained. Needs the damaged file (keep it next
time, diff against the good copy: random blocks / boot blocks / FAT chain).
Still-open suspects: the telnet `g` reload and `fpgastream` paths DO leave
`disk_poll` running while the fabric reconfigures (garbage `HDD_REQ` reads
→ garbage block writes) — a quiesce is warranted there regardless.
**Resolved 2026-11-17:** that suspect was the mechanism. A `fpga_stream.py`
reload left `disk_poll` reading bus junk from the unconfigured FPGA; a junk
write request with lba 0x7EFF0B made `disk.c` seek 4 GB past the end of
`disk1.nib`, FatFS extended the file, and the stick's root directory went
with it. Evidence, firmware fix (checked request reads, image-bounded seeks,
quiesce + unmount before every reload/restart, image sizes checked at mount,
write failures counted and demoting the volume to read-only) and the
unflashed build: [STICK_CORRUPTION_2026-11-17.md](STICK_CORRUPTION_2026-11-17.md).
The stick itself was failing as hardware the same evening (reads down to
100 KB/s, will not reformat on two machines); retire it.

**Update 3 (ed, 2026-10-15 late): `a2p25_oldcache.bin` (`add13bfb…`,
cache + whole-cache flush) pops too** (identified on the wire by its
telemetry shape: REQ valid, MEMRD high byte 0xFF from the then-unmapped
0x5F). Per-word invalidation is cleared; the fault is in the cache's own
request/fill/hit logic, which the bench (behavioural memory + behavioural
RAM) passes. Inspection notes, all negative: supersede is applied on hits
too; the port contract (2-slot queue, in-order single-beat reads, `q` aligned
with `ready`) is the same one the clean filter build used with `burst=0`;
the data RAM idiom is write-else-read with no same-cycle read/write; the
DOC's generic capture precedes the request-cycle clear in the always block
(request wins). Next: hardware bisect with `HIT_DISABLE=1` (all fetches via
the response path, RAM filled but never read) — pops ⇒ response/ordering
path, clean ⇒ hit path (then a hit-verify build that compares every N-th
hit against memory).

### 7.21 Arkanoid pops — ROOT CAUSE: DOC port priority, not the cache (2026-10-15)

Bisect result with `HIT_DISABLE=1` (`cc8bf554…`, every fetch through the
response path): **much more crackling**, and the telemetry explains it. With
Arkanoid idle — one oscillator, `REQ 439 = MEMRD 439`, no DOC-side
contention at all — `LATE 29–34` per frame. LATE is the DOC's own timeout
counter (`doc_dbg_to_frame_r`), i.e. **7 % of single-oscillator fetches miss
the 840 ns budget**, and each one runs the hold-last-sample path. At
~1,800 holds/s a repeated sample is no longer inaudible: it is the crackle.
With hits on, the same mechanism hits 6–9 % of the *misses* (≈ 28/frame on
Arkanoid and Marble Madness) — "some pops". The clean hold build ran at
0.4 holds/s.

The regression is the **port priority swap** that went in with the cache
commit (`63192a48`, §7.14 "shadow read back at port 0"): the hold build had
the DOC at port 0 and shadow reads at 1. Under SHR the VGC's shadow reads
are pending continuously through the active line, and `hyperram_ports` is a
static-priority arbiter — port 1 waits for the whole line. The 2026-10-14
reasoning ("a late DOC fetch is silent") was wrong at this rate.

Everything else is exonerated: per-word invalidation (whole-flush control
pops), the hit path (hits-off is worse, not better), the data RAM, the port
protocol. The cache itself masked the problem by turning 93 % of fetches
into hits.

Fix: DOC back to port 0, shadow read to 1 (`top.sv`, with the 2026-10-14
note kept and answered). The VGC-starvation case that motivated the swap was
the *uncached* DOC stream (6,000–7,000 single-word reads/frame); the cache
leaves 200–500 misses/frame, each costing the VGC one ~300 ns read. Verify
on hardware: Arkanoid `LATE` → ~0 and no pops; Marble Madness `VGC STALE 0`
and no smear; MCS (40 % miss) `VGC STALE` stays 0.

Lessons recorded: (1) **hold-last-sample is a rate-limited remedy** — the
per-frame LATE counter is the audio quality metric and must stay near zero,
not merely "silent"; (2) a bisect must list *every* change in the commit —
the priority swap rode in with the cache and nearly got the cache blamed;
(3) `DOC TIMEOUTS` (8-bit cumulative) is useless above ~100/s; read LATE.

**Fix build `92f164d6…`** (stamp `20261018145658`, DOC back at port 0; 0
violations, worst +0.010 ns; installed over WiFi 2026-10-18). Arkanoid, five
per-frame samples across idle and effects: `REQ 439 / 1318 / 3952 / 1318 /
439`, `MEMRD 26 / 100 / 230 / 122 / 0`, **`LATE 0` on every sample**
(failing build: 14–15 per effect frame, 29–34 with hits off). Cumulative
timeouts stuck at 5 across the whole run (boot transients). `VGC STALE 0`,
`SHADOW DROPS 0`, FB overflow clear. **Ed: no pops or crackles on this run.**
Marble Madness smear check pending.

**Ed, Marble Madness on `92f164d6…`: works, no smearing.** Both sides of the
priority trade now hold with the cache in place: DOC at port 0 (Arkanoid
LATE 0, no pops) and the VGC still fed (no smear, `VGC STALE 0` on the
Arkanoid run). `92f164d6…` (source + bitstream committed in a9984119) is the
a2p25 build of record. Remaining from this thread: the HDD-image corruption
around installs (§7.20, needs the damaged file), and a disk quiesce for the
telnet `g` / fpgastream reload paths.

## 8. Implementation: the BSRAM pass, Uthernet II and Mockingboard back in (2026-11-15)

Executed from §5 with §7's corrections, on the build of record (`34a5abb9`,
52/56 BSRAM, 15,317 logic, 13,487 FF, 98% CLS). One measurement build per
group; every build 0 setup / 0 hold violations with every clock above its
constraint (single rolls; the durability rolls are in §8.3).

### 8.1 What was done and what each item measured

| Item | Change | BSRAM | Logic / FF effect | Note |
|---|---|---|---|---|
| B4 | `dp_transmitter` `PIXEL_BITS=16`: RGB565 through the pixel CDC FIFO (512 × 65 instead of 512 × 97) | **−2** (6 → 4) | ~0 | Framebuffer pixels bit-exact: the expansion is the framebuffer's own `rgb565_to_666` → `torgb` chain, checked for all 65,536 codes. OSD text and scanline dim quantise to 565. a2mega default 24, netlist unchanged. |
| B5a | GLU write queue as `{be, addr[13:0]}` (18 bits) + sample byte (8 bits), `syn_ramstyle="block_ram"` | **−2** (4 → 2) | 0 | First build without the attribute: GowinSynthesis "extracted RAM" and then built both arrays from flip-flops (+827 FF, 0 blocks). The attribute is required for small arrays on GW5A. Shared file; the a2mega gets the same saving. |
| B7 | `PLL_INIT` 64 × 28 constant table as a `case` lookup | **−2** (one per instance: system PLL, D-PHY PLL) | +27 LUT / +6 FF per instance | `syn_romstyle="logic"` on the register array was ignored (still a pROM). a2p25-only file. |
| B7b | `slotmaker` slot table `syn_ramstyle="registers"` | **−1** | +82 LUT / +80 FF | The `$readmemh("slots.hex")` initial values survive as register INITs (netlist: 9 DFFs with INIT=1 = the 9 set bits of slots.hex). All boards; on GW2A it was distributed RAM. |
| B1a | Framebuffer write FIFO as nine 18-bit arrays | **0** | 0 | GowinSynthesis merged the same-addressed slices back into one 149-bit memory → the same 5 x32 primitives (10 blocks). Reverted; only B1b (beat-organised) can shrink this FIFO. |
| B3 | Framebuffer line buffer 8 → 4 banks (`LINE_BANKS` parameter, a2mega default 8) | **−4** | −16 LUT / −31 FF | Prefetch stays ≤ 3 lines ahead (3 × 74 µs at 1080p vs a ~25 µs line fetch). **Hardware check owed** (§8.4). |
| B6b | ESP32 memory-peek reader + its arbiter port behind `A2_INSTR_MEM_PEEK` (0) | 0 | −171 LUT / −114 FF (`hyperram_ports` 7 → 6 ports) + the reader | Window regs 0x34–0x3B still exist; GO never busies, data reads `DEADBEEF`. The firmware never used them. |
| 7.3 | ESP32 connector SPACE 0 test memory behind `TEST_MEM` (a2p25 0, a2mega default 1) | 0 | −342 LUT / −518 FF | Reads of SPACE 0 return 0xFF. The firmware only defines the constant. |
| — | Uthernet II `UTHERNET2_ENABLE=1` | **+9** | +111 LUT / +32 FF | `reg_mem` 1 + `buf_mem` 8 DPB blocks, as on the Enhanced. |
| — | Mockingboard `MOCKINGBOARD_ENABLE=1` | 0 | +1,627 logic / +777 FF (2 × YM2149 ≈ 420 LUT / 220 FF, 2 × 6522 ≈ 310 / 167, + top mixing) | Audio summed into the DP in-band path; IRQ into the slot IRQ. |

### 8.2 Device position after each build

| Build | Content | Logic | FF | CLS | BSRAM | Worst setup slack |
|---|---|---|---|---|---|---|
| of record `34a5abb9` | — | 15,317 (67%) | 13,487 (58%) | 11,218 (98%) | 52 | — |
| A | B4, B5a (flops), B7 (ignored), B7b, B1a (merged), B6b, 7.3 | 15,056 (65%) | 13,588 (59%) | 11,144 (97%) | **45** | +0.40 (clk_tx, D-PHY bank FIFO) |
| B | + B5a fixed, B7 as case, B1a reverted, B3, **Uthernet II in** | 14,994 (65%) | 12,786 (54%) | 11,056 (95%) | **50** | +0.23 (clk_hr, ESP32 proto) |
| C | + **Mockingboard in** | 16,621 (72%) | 13,563 (58%) | 11,159 (96%) | **50** | +0.33 (clk_pix, `aud_acc`) |

BSRAM primitives after build C: SP 1, SDPB 17, SDPX9B 4, DPB 25, pROM 3.
Against the build of record with both cards in: **+1.3 k logic, +76 FF,
−2 BSRAM, CLS −59**. The audit's logic target (≤ 17,000 before the
Mockingboard) was already met by the §7.11 DOC work; the BSRAM target
(≤ 46 before Uthernet II) was met by B4 + B5a + B7 + B7b + B3 = −11.

The `aud_acc` path (build C's worst, 9 logic levels) is the 48 kHz strobe's
29-bit Bresenham accumulator on clk_pix. The a2mega top carries the same
ratio reduced by the GCD (+4 / −12,375 in 15 bits); the a2p25 now does too
— the sign-test sequence is identical (checked over 2 M cycles), with half
the carry chain.

### 8.3 Durability rolls of the final source

Three placements of the final tree (build C + the 15-bit `aud_acc`), each
a full `tools/build.sh a2p25` run (Gowin reseeds the placer per run). Bar:
0 violations and ≥ +0.5 ns on every clock.

| Roll | fs sha256 | Logic | CLS | Setup / hold viol. | Worst setup slack (path) | Fmax margin, thinnest clocks |
|---|---|---|---|---|---|---|
| D1 | `be8b7b8a…` | 16,763 (72%) | 97% | 0 / 0 | **+0.601** clk100 (AUX channel `next_state` → `expected` reset) | clk100 106.4 / 100, clk_sym 101.1 / 81, clk_tx 113.8 / 101.2 |
| D2 | `f9e4cf48…` | 16,663 (72%) | 96% | 0 / 0 | **+0.535** clk_tx (D-PHY bank FIFO `wp_gray_r2` → `rd_pair` CE) | clk100 106.6, clk_tx 107.0, clk_hr 66.2 / 54 |
| D3 (committed) | `8998afab…`, stamp `20261115214949` | 16,336 (70%) | 97% | 0 / 0 | **+0.395** clk_tx (D-PHY bank FIFO `rp_bin_0` → `rd_pair_79` CE) | clk_tx 105.5 / 101.2, clk_hr 59.5 / 54, clk100 116.4 |

Verdict: **clean on all three rolls** (0 violations, every clock above its
constraint); the +0.5 ns bar is met on two of three. The roll that misses
it does so on the `transceiver_bank_dphy` read-pointer → `rd_pair` CE cone
on clk_tx — the same path that was build A's worst (+0.399) before either
card went in, and the pixel-serializer FIFO the audit lists under "not
bloat" (16 × 80 in registers). It is not in the changed logic; closing it
structurally (register the pointer decode, or move the bank FIFO to BSRAM
at 5 blocks — not affordable now) is a DP-link task with the dp_test gate,
not a debloat item. BSRAM is 50/56 on every roll.

The a2mega 138B project synthesises cleanly with the shared-file changes
(defaults unchanged: `PIXEL_BITS` 24, `LINE_BANKS` 8, `TEST_MEM` 1; the
GLU queue re-slice and the slot-table registers apply there too).

### 8.4 Hardware checks owed (ed, on the a2p25)

1. SHR scroll / Marble Madness with 4 line banks: `VGC STALE 0`, line-not-ready
   and line-lag counters 0, no smear or tearing (B3).
   **DONE 2026-11-17 on 6f24025d (ed playing, counters over telnet).** Marble
   Madness is the one title in this record that has moved these counters (§7.14:
   `VGC STALE` 6–32/frame and write-FIFO overflow before the DOC word cache,
   0/2/0 after, on 8 banks); Arkanoid's static playfield never has. Six `z`
   reads plus a 40-sample burst of regs 0x75/0x78/0x73 during play:

   | Counter | Reading | Meaning |
   |---|---|---|
   | FB flags bit 0 (line-not-ready this frame) | 0 in 46 of 46 samples | the 4-bank line buffer never displayed a bank holding the wrong line while sampled |
   | FB flags bit 1 (write-FIFO overflow) | 0 in 46 of 46 | renderer write port keeps up |
   | `VGC HSYNC` missed | 0 in all | |
   | `VGC STALE` (vgc_gen stale-word swaps/frame) | 0–2 typical (13 of 40 nonzero, max 2), one `z` read of 5 | same order as the October 0/2/0 on 8 banks; renderer-side read starvation, not the line buffer |
   | `SHADOW DROPS`, `OVFL` | 0 | |
   | DOC `LATE`, GLU drops, fetch drops | 0 / 0 / 0 (`MEMRD` 219–369/frame, `REQ` 7028) | DOC traffic high and clean |
   | audio CDC consumed-mixed / max step | 0 / 6144 | mailbox default, no pops (ed) |

   Caveat: this board's line-not-ready is a per-frame flash (bit 0 of reg 0x75
   holds from the first event to the next vsync); the sticky total (`LINE NOT
   READY TOTAL`) lives only on the compiled-out DebugOverlay. 46 clean random
   samples bound the event rate well below one frame in ten; a rarer event would
   need the sticky total routed to the debug window. `VGC STALE` is the §7.14
   bandwidth symptom and is independent of LINE_BANKS; its 0–2 (one 5) matches
   the post-cache baseline. **B3 (4 banks) holds under the hardest title on
   record.**
2. DOC listening set (POLY.SYNTH, Arkanoid): `GLU SOUND-RAM WRITE DROPS` 0,
   `LATE` ≈ 0 (B5a re-slice).
   **2026-11-16, first report (ed):** pops at specific places in Arkanoid on
   build 8998afab. Not yet known to be new: the A/B is the other a2p25 card,
   which runs fs 6767d681 (the 11-13 build, before this pass). The GLU drop
   counter that decides B5a's guilt fed only the `DebugOverlay`, compiled out
   on this board, so it was unobservable; the 11-16 build (fs `fc17788f…`,
   0/0 violations, 50/56 BSRAM, logic 72%, CLS 98%, worst slack +0.10 ns on the
   pre-existing clk_tx D-PHY bank-FIFO cone `wp_gray_r2 → rd_pair CE`, so a
   diagnostic roll, not a durable one) adds it and the DOC fetch-drop counter
   to the ESP32 debug window (select 0x5F, indices 46/47; telnet `z` prints
   both, firmware viddbg_log extended the same day). Reading recipe:
   [../../a2mega/docs/ESP32_CONSOLE.md](../../a2mega/docs/ESP32_CONSOLE.md).
   **A/B result (ed, 11-16):** the pops are absent on the second a2p25 running
   6767d681, so they are an artifact of this branch. The committed `.fs` did not
   change at the BSRAM-pass commit (still 6767d681), so no intermediate build
   existed; three bisect points were built from HEAD (counters in), toggling only
   the two card macros, 0/0 violations each:

   | Variant | fs | Mockingboard | Uthernet II | BSRAM | logic | worst slack |
   |---|---|---|---|---|---|---|
   | none | `27fce17d` | off | off | 41/56 | 65% | +0.34 (clk_mem) |
   | u2 | `1cf76e79` | off | on | 50/56 | 65% | +0.59 (clk_tx) |
   | mb | `497a719b` | on | off | 41/56 | 71% | +0.19 (clk_mem) |
   | both | `fc17788f` | on | on | 50/56 | 72% | +0.10 (clk_tx) |

   Order: `none` first. Pops there = the BSRAM pass itself (LINE_BANKS=4 is the
   prime suspect: it changes the framebuffer's HyperRAM read pattern; the GLU
   queue re-slice is cleared by the netlist check (SDPB bypass mode, read
   address from the pointer's next state, a dead cycle in the pop sequencer) and
   by `sim/doc5503/run.sh`, whose co-simulation of the real `sound_glu` passed
   stream-writes 0/77). Clean there = one of the cards; `mb` then `u2` decide
   which. Deploy over WiFi with `tools/fpga_stream.py` (no USB needed) and read
   indices 44–47 with telnet `z` at a popping spot.
   **`none` on the card (11-16, streamed over port 2323, stamp
   20261116084205 read back from reg 0x7E): still pops (ed, "slightly less, I
   think"), so the cards are exonerated and the BSRAM pass or something common
   to every build on this branch is at fault. Counters after the session:
   `DOC TIMEOUTS 5` (cumulative since power-up: the same five boot transients
   the clean October build showed, §7.21), `LATMAX 45 clk`, `LATE 0`,
   `MEMRD 0`, GLU write-queue drops (46) 0, DOC fetch drops (47) 0, `VGC
   STALE 0`, `SHADOW DROPS 0`. No DOC fetch missed its deadline during play:
   the HyperRAM path, and with it LINE_BANKS=4, is cleared as the mechanism.**

   **Measurement, not ears (ed).** The remaining common factor is the sample
   hand-off itself, unchanged on this branch but untimed and placement-
   dependent: `core_audio_{l,r}_w` (clk_logic, 54 MHz, `i_sys_pll`) went into
   `dp_transmitter`'s `audio_sample_word` through a plain double flop per bit in
   clk_pix (148.5 MHz, `i_dp/i_pixel_pll`); `a2p25.sdc` puts clk54 and clk_pix
   in different `set_clock_groups -asynchronous` groups, so no path between
   them is timed. A 16-bit value that changes within the per-bit skew window
   of a pixel-clock edge is captured as a mix of old and new bits; taken at
   the 48 kHz strobe that is a sample the DOC never produced, and loud when
   high bits are involved. The rate is set by placement skew and PLL phase,
   not logic, which is why it differs build to build ("slightly less" on a
   different placement) and card to card (ed's A/B used a second card). The
   GLU output register is reassigned every clk_logic cycle, so the bus
   transitions whenever the mix changes. The a2mega top has the identical
   crossing.

   Instrument + fix candidate, one build (`hdl/displayport/audio/audio_sample_cdc.sv`,
   wired in `top.sv`, read through debug-window indices 48–55, controlled by a
   write to window index 55: bit 0 selects the mailbox path, bit 1 clears):
   the raw path is kept and *detected*: a clean source value lasts 18.5 ns and
   is captured by at least two consecutive 6.7 ns pixel-clock edges, so a
   captured word that differs from both its neighbours lasted one cycle and
   is a mixed capture (no parity or reference copy, no false positives while
   T_src ≥ 2 T_dst). Counters: mixed captures (any cycle), mixed captures
   consumed at a strobe (= pops the raw path produced, counted whichever path
   feeds the DP), consumed steps > 2048 on the selected path (the symptom), and
   the largest step. The safe path is a request/acknowledge mailbox: the
   strobe toggles a request, synchronised into clk_logic it latches `{r,l}`
   and toggles an acknowledge, synchronised back it copies the latch; round
   trip ≈ 100 ns against the 20.8 µs sample period, one sample of latency.
   `sim/audio_cdc/run.sh` (iverilog, 54 MHz source with 0–2.5 ns per-bit
   skew into a 148.5 MHz capture, random phase): no skew → 0 mixed, 0 bad
   (control); skew, raw → DUT consumed-mixed count = testbench truth
   (seed 1: 432 = 432); skew, safe → 0 non-source words delivered over 9,000
   strobes while the raw path would have delivered 810. Expected on hardware:
   index 50/51 > 0 and growing at the popping spots with the raw path, 52/53
   lower with the mailbox path selected, and no pops with it; a2mega gets the
   same module once this is confirmed.

   **First measurement (11-16, build `8eca5290…`, stamp 20261116124334, 0/0
   violations, worst +0.129 clk_tx, logic 72%, 50/56 BSRAM; the first build
   `01cf58c1…` had 60 setup violations, all the detector's own 16.5 ns
   mux-subtract-abs-compare chain at 148.5 MHz, pipelined over four cycles):**

   | | raw path, boot minute | raw path, Arkanoid run |
   |---|---|---|
   | mixed captures (48/49) | 1 | 65,535 (saturated) |
   | mixed captures consumed (50/51) | 0 | **95** |
   | consumed steps > 2048 (52/53) | 94 (ProDOS boot beeps: the speaker bit is exactly a 4,096 step; largest step 4,096) | 5,650 (largest 7,168) |
   | DOC TIMEOUTS / LATE / GLU drops / fetch drops | 5 / 0 / 0 / 0 | 5 / 0 / 0 / 0 |

   Ninety-five samples the DOC never produced reached the sink in one run,
   with every memory-path counter clean: the crossing is the mechanism. Ed
   heard **no loud pops** on that run, which is the point of counting: a
   mixed word is only loud when old and new differ in high bits, so the ear
   samples the same defect at a rate set by the music and the placement.
   The mailbox A/B did not happen on this build: its switch was ESP32 scratch4
   (reg 0x0F), which `w5100.c` rewrites with bridge telemetry on every poll,
   so the selection reverted within a second (status byte showed sel 0 while
   the register read 1). Moved to a write on window index 55; rebuilt.

   **A/B on one bitstream (11-16, build `8370c1c9…`, stamp 20261116135950,
   0/0 violations, worst +0.116 clk_mem_90, logic 73%, 50/56 BSRAM; streamed
   to the card over WiFi, switch verified end to end before the runs: a write
   of 1 to index 55 made the module's own status byte read sel_safe=1, a write
   of 0 put it back). Same card, same placement, same Arkanoid passage, only
   the one register changed between the halves; counters cleared before each:**

   | | raw path | mailbox path |
   |---|---|---|
   | mixed captures (48/49) | 65,535 (saturated) | 65,535 (saturated; the raw flops still run) |
   | mixed captures consumed (50/51) = pops the raw path produced / would have | **219** | 129 (not delivered: the mailbox fed the sink) |
   | consumed steps > 2048 (52/53), selected path | 11,782 | 5,526 |
   | largest consumed step (54) | **≈ 20,736** (0x51xx, a third of full scale) | ≈ 7,168 (0x1Cxx) |
   | DOC req/frame / MEMRD / LATE / GLU drops / fetch drops | 439 / 0 / 0 / 0 / 0 | 439 / 0 / 0 / 0 / 0 |
   | heard (ed) | two pops | **none** |

   Reading: the raw path delivered 219 words the core never produced and the
   largest step in the delivered stream was ≈ 20,736; with the mailbox the
   largest step fell to ≈ 7,168, the same ceiling the earlier raw run with
   no audible pops showed (7,168), so ≈ 7,168 is the game's own largest step
   (speaker and PSG edges) and the 20,736 excursion was a mixed word. The
   consumed-mixed count on the mailbox run (129) is the pops that run would
   have had on the raw path. The step count is dominated by the game's own
   audio (5,526 on a clean run), so it separates the paths only through the
   maximum, not the count; the consumed-mixed counter is the metric. DOC
   path clean on both halves. Ed heard no pops on the mailbox run.

   **Decision (ed, 11-16): the mailbox is the power-up default** (connector
   control byte resets to 0x01; the raw path and the detector stay in for
   measurement, a write of 0 to index 55 brings the pops back on demand).
   Default-on build (11-16, source 26c26393: control byte resets to 0x01, and
   the detector's magnitude stage is one's-complement so no 16-bit carry
   chain sits in the 148.5 MHz domain; a first roll of the two's-complement
   form, `7c001674…`, was clean but placed that chain at +0.186 ns, third
   worst in the design). Three rolls of the final source, all 0 setup / 0
   hold, 50/56 BSRAM, logic 74%, CLS 98%; `i_audio_cdc` costs 127 LUT /
   387 REG (raw path, mailbox, detector):

   | roll | stamp | fs sha256 | worst setup slack |
   |---|---|---|---|
   | 1 | 20261116195344 | `f098aabb…` | +0.403 ns (clk_mem, `i_hr_ctrl` CE cone) |
   | 2 | 20261116195545 | `bf43440d…` | +0.869 ns (clk_tx, D-PHY `rp_bin → rd_pair` CE) |
   | 3 | 20261116200045 | `6f24025d…` | +0.338 ns (clk_pix, framebuffer `v_border_px → at_lead_nxt`) |

   Roll 3 is the committed build of record (`boards/a2p25/impl/pnr/a2p25.fs`,
   Fmax clk_pix 156.3 vs 148.5, clk_mem 125.5 vs 108, clk_tx 118.9 vs 101.2,
   clk_hr 64.6 vs 54, clk100 114.6 vs 100). The a2mega top carries the same
   module from commit adb557ac (source only until its next build).

   **On the card (11-17 00:xx, streamed over WiFi to config flash, verified):**
   stamp 20261116200045 read back from reg 0x7E; window-55 status 0x01 at
   power-up (mailbox selected with no write); boot minute: mixed captures 19,
   mixed consumed 0, steps > 2048 = 94 (the ProDOS beeps, largest 4,096), DOC
   counters clean. **Listening pass (ed, 11-17): Arkanoid on `6f24025d…`, no
   pops.** The 11-16 pop report is closed: cause measured, fix measured, fix
   heard. Second run on the same build, counters read after it (cold power-up,
   no register written): status 0x01, mixed captures 65,535 (saturated), mixed
   captures consumed **0**, steps > 2048 = 5,433, largest step ≈ 6,144, DOC
   counters clean. The consumed-mixed count is what the raw path would have
   delivered on this placement: 0 here against 95 / 219 / 129 on the earlier
   placements is the placement lottery itself (per-bit skew differs build to
   build), which is why the fix is the mailbox and not a lucky roll.
3. OSD text and scanline-dim colours (565 quantisation, B4); the Apple picture
   itself is bit-exact.
   **DONE 2026-11-17 (ed, on the fix build 360a7c36):** main menu over the
   display: text crisp, inverse highlight bar and scanline dimming intact,
   CORE stamp line reads the running build. On this board the menu draws on a
   black field (pixel-domain overlay), so the 565 colour question is the
   Apple picture itself, judged across Arkanoid, Marble Madness and Nox
   Archaist today with nothing noticed.
4. Slot assignments at power-up unchanged (slots.hex as register INITs, B7b).
   **DONE 2026-11-17 on 6f24025d:** read back through the connector (write
   reg 0x30 = slot, read 0x32 = card): slot 0/1 empty, 2 = SSC (3), 3 =
   Uthernet II (5), 4 = Mockingboard (2), 5 = Disk II (4), 6 = HDD (6), 7 =
   SuperSprite (1); reconfig 0. Identical to `hdl/slots/slots.hex`. The SSC
   and SuperSprite IDs sit in slots whose cards are compiled out, so those
   slots answer nothing, as before the pass.
5. Uthernet II: DHCP through the ESP32 W5100 bridge; Mockingboard: a title
   with music (Ultima IV / Skyfox), both channels, IRQ-driven playback.
   **Mockingboard DONE 2026-11-17 on 6f24025d (ed):** slot 4 set to Your Card,
   Nox Archaist (both AY chips, 6522 timer-interrupt music driver): music
   through the title sequence and in the game, no hang. That is the IRQ path
   (card → LSF0108 open-drain → slot /IRQ) and both chips in one title.
   Counters during play (Apple II video mode, DOC idle): consumed-mixed 0,
   raw-path would-have-popped 1 since boot (swallowed by the mailbox), steps
   > 2048 = 40 per 20 s with a 4096 maximum, which is what AY square-wave edges
   look like to the step detector, not a fault.
   **Observation (ed): the Mockingboard is quiet next to the other sources.**
   Not a debloat artifact: the mix is the same expression on all three tops
   (`core_audio = sg_audio + {ssp,3'b0} + {mb,3'b0} + {speaker,12'b0}`, 16-bit
   signed). Peak levels: DOC `sg_audio` = full 16-bit scale; speaker toggles
   4,096 (12.5 % FS); Mockingboard = three 8-bit channels summed into 10 bits,
   then << 3, so 3 × 255 × 8 = 6,120 at full volume on all three voices (19 %
   FS, −14.6 dB), and the AY's log volume table puts typical music well below
   that. On the a2n20v2 the DOC term is zero, so the Mockingboard only competes
   with the speaker and sounds normal; on a IIgs board the DOC titles set the
   listener's reference at full scale. Lever if wanted: `{mb, 4'b0}` (peak
   12,240, 37 % FS, +6 dB) in the shared mix expression; a DOC title and a
   Mockingboard title do not play at once, and the sum still fits 16 bits
   unless the DOC is near full scale at the same instant. Shared-HDL change
   across all tops, so a decision for its own pass, not this merge.
   **Taken as its own pass 2026-11-17 evening (ed: "yes, next pass"), branch
   `claude/mockingboard-level-6db` off the merged main, commit 8907a509:**
   `hdl/sound/core_audio_mix.sv` replaces the inline add on the a2p25,
   a2mega, a2n20v2 and a2n20v2-Enhanced tops (deprecated GS top untouched):
   Mockingboard << 4 (peak 12,240, +6 dB), 19-bit sum clamped to 16 bits so
   a full-scale DOC under a speaker click or a Mockingboard chord clips
   instead of wrapping. Bench `sim/audio_mix/run.sh` (reference model,
   200k random cases + clamp corners) PASS. a2p25 rolls of that source: 1
   `4b761551` 0/0 worst +0.013 clk_pix (framebuffer `v_border_px_r ->
   h_trigger_r`, a pre-existing cone, placement noise: rolls 2/3 put it at
   +1.56 / +0.92), 2 `64ab7913` 0/0 worst +0.85 clk_tx, 3 `bb7b63fa` 0/0
   worst +0.046 clk_mem. Roll 1 streamed (stamp 20261117204243).
   **Measured (ed's HDMI capture of Nox Archaist at << 4,
   `tests/sound/nox.m4a`): peak -31.3 dBFS, RMS -36.9 dBFS, waveform
   unipolar (min -0.0015, max +0.027 FS), L and R identical.** "A bit louder,
   still somewhat quiet." Reference through the same chain: the February
   DOC captures `game_1/game_2.m4a` peak at +1.3 / -1.9 dBFS, so the chain
   passes full scale. The DP packetizer places the 16-bit sample in the top
   16 of the 24-bit sub-frame field (`{sl, 8'h00}`, channel status word
   length 16-in-20): correct, no packing attenuation. The AY core (YM2149.sv,
   MODE 0) indexes its 32-step logarithmic YM table with the full 5 bits and
   reaches 255 at volume 15: correct. So the shortfall is the real chip's
   log DAC: ordinary music at volumes 8-12 sits 8-20 dB under the channel
   peak, and a real card's amplifier makes it up; emulators apply gain.
   At << 4 Nox's actual peak was ~885 counts (10-bit AY sum ~55 of 765).
   **Done (commit 29c62fa7): the Mockingboard gain is a live 2-bit select,
   bits 3:2 of the audio control byte at window index 55 (shift = 3 + value;
   write 0x01/0x05/0x09/0x0D for << 3/4/5/6 with the mailbox bit kept),
   power-up 2 = << 5 (full chord 24,480, 75 % FS, clip-free; << 6 clips full
   chords, the sum saturates). Index 55 reads back {0, gain, clear, sel}.**
   The level is picked by ear on one bitstream; the chosen value becomes the
   reset default. Note for the pick: at << 5 Nox should peak near -25 dBFS;
   matching DOC titles' loudness (RMS -15 to -20 dBFS) would need ~+15 dB
   over << 4, which is past << 6 and clips chords, so the honest ceiling is
   << 5 or << 6 with saturation doing the rest.
   **Next, after the level (ed): audio quality.** The a2n20 tops run
   `audio_out` (the IIR filter stage) between the mix and the output; the
   a2p25 feeds the mix straight into the DP crossing because the filter's
   DSP multipliers did not port from GW2A to GW5A at the time. Ed hears the
   difference on the Mac playback. Separate item.
   **Gain-select build (commit 29c62fa7), three rolls of the final source,
   all 0/0: roll 1 `aca89216` (stamp 20261117210112) worst +0.56 clk100 =
   BUILD OF RECORD, on the card; roll 2 `13149278` worst +0.029 clk_tx /
   +0.033 clk_pix; roll 3 `658551cf` worst +0.67 clk_tx. Position: logic
   73 %, BSRAM 50/56, +28 LUT per mixer channel. Power-up Mockingboard gain
   << 5. **Ear pick DONE 2026-11-18** (Nox Archaist title music vs the
   startup beep, stepped live through index 55 = 0x05 / 0x09 / 0x0D): Ed:
   << 5 and << 6 both sound fine, << 6 obviously louder, no audible clipping,
   lean << 6; and the level should be a user setting. So the HDL default
   stays << 5 and the ESP32 firmware owns the byte: SETTINGS → MOCKINGBOARD
   VOLUME (LOW / MEDIUM / HIGH / MAX = << 3..6, default MAX), persisted in the
   settings blob (`mb_volume`, one reserved byte, 0 = default), written at
   boot with the slot map and live on change (`audio_ctl.c`). Firmware
   `1c303a4c` (1,130,272 B, +384 B) built and INSTALLED 2026-11-18 08:14 via
   FTP + menu mirror into slot APP0: boot log `AUDIO: MOCKINGBOARD << 6
   (MAX)`, index 55 reads 0x0D; LEFT/RIGHT on the item gives HIGH/0x09 and
   MAX/0x0D with SETTINGS SAVED. Setting left at MAX.
   **Audio output filter stage DONE 2026-11-18 (the a2n20 parity item above).**
   `audio_out` (Sorgelig's 3-tap IIR low-pass + DC blocker) now runs on the a2p25
   too, on `clk_logic` AHEAD of the CDC so the band-limiting sees the full-rate
   sources (speaker bit, AY squares, DOC steps) and not the 48 kHz capture; the
   DC blocker's strobe is 54 MHz / 1125 = 48.000 kHz, frequency-locked to the
   pixel-domain strobe (one oscillator), so the mailbox carries one word per
   period. `flt_rate` 5,594,066: audio_out's accumulator drops its increment on
   the fire cycle, so the Tang Nano tops (27 MHz, 7,056,000) really filter at a
   9.268 MHz ce, and that value reproduces it at 54 MHz; the bench shows both
   configurations within 0.02 dB at every frequency (flat to 8 kHz, −0.7 dB at
   10 kHz, −4.9 dB at 15 kHz, −11.2 dB at 20 kHz, −34 dB at 50 kHz). The IIR's
   registers are all ce-enabled (ce at most every fifth clk54) and the SDC gives
   them 3 cycles; two lessons there: a `*` in get_regs did not cross hierarchy
   (the taps' `intreg` needed `*/*` patterns — first build was −0.050 ns
   single-cycle on exactly those), and synthesis absorbs the ce-enabled `inp`
   register into the DSP's AREG, so the exception must name the DSP DOUT pins.
   **The GW5A multiplier finding (ed's 2025-09 "primitives" warning, confirmed):**
   `hdl/support/iir_filter_gw5a.v` first wrote the 16×40 and 37×24 products as
   signed ≤27×≤36 pieces; bit-exact against the GW2A file in Verilator (15 M
   cycles, random coefficients, DC-blocker un-mute), netlist wiring checked by
   hand (operands, constants, AREG+CE, MULTALU static mode = A·B, no sign pins on
   Arora V — all operands signed), PnR clean — and on the card the consumed
   stream swung full scale every sample: jump counter (window 52-53) saturating
   in < 3 s and max step 0xFF at Mockingboard gain << 3, where the sources cannot
   exceed ~3,000 counts (builds `8b449d4f`, `00c69b77` = MULT27X36 kept, MULTALU
   replaced). With EVERY product a signed ≤12×≤12 piece (`fcde464a`, 33
   MULT12X12 incl. the DOC's 5) the stream is clean: jumps 0, max step 0 at
   << 3, 1,280 at << 6 with the game's music. So the MULT27X36 and MULTALU27X18
   cells GowinSynthesis 1.9.12.03 infers compute wrong results on the GW5A-25;
   MULT12X12 (the DOC's) is the only DSP cell this repo has hardware proof for.
   Cost: 14 DSP blocks (16.5/28 with the DOC) and ≈ 1,350 LUT/ALU → logic 83 %
   (was 75 %), vs 11 blocks / 275 LUT for the wrong version. Memory note
   `gw5a-wide-dsp-multipliers-wrong`. GW5A projects (a2p25, legacy rev-0,
   a2mega, a2mega_138B) list the shared file; the two board copies from 2025-09
   (which also sign-extended the low ten bits of y) are gone.
   **Rolls of the final source (commit 8122adb6 + sdc), 2026-11-18:** roll 1
   `19dfb878` 0/0, worst +0.129 clk100 (+0.648 clk_pix, +1.097 clk_mem; streamed
   first, counters clean: jumps 0 / max step 0 at << 3, 1,792 at << 6); roll 2
   `536ec2a4` ONE violation, −0.192 clk_mem_90 (`i_hr_ctrl/u_phy/ck_en_n90 →
   u_ck/D0`, the HyperRAM PHY's 90° clock-enable, 4.6 ns budget); roll 3
   `3c863693` 0/0, worst +0.118 clk_pix (+0.198 clk100, +1.305 clk_mem) =
   **BUILD OF RECORD** (the last build, so impl/pnr is one consistent set),
   committed and on the card. The earlier all-12x12 probe `fcde464a` missed the same
   clk_mem_90 path by −0.164, so 2 of 4 placements of this source fail there:
   at 83 % logic that PHY path has become placement-sensitive, where the 27x36
   version (79 %) closed 3 of 3 with +0.5 or better. Not the ≥ +0.5-on-every-
   clock bar; honest status = closes 2 of 3, knife-edge on clk100/clk_pix. The
   lever if ed wants it durable: trim ≈ 400-800 LUT — the audio CDC's RAW path
   and its counters (≈ 390 LUT, the mailbox is proven) or the DebugOverlay
   residue (B6) — or constrain the PHY ck_en flop next to its DDR cell.
   **Trim tried 2026-11-18 (ed: "trim the CDC raw path"), commit b88a0c10 on
   `claude/a2p25-audio-filter`, NOT merged:** `audio_sample_cdc` got a
   `RAW_PATH` parameter and the a2p25 passes 0 (mailbox only, no mixed-capture
   detector; bit 0 of index 55 ignored, 48-51 read 0; the jump / max-step
   counters stay; bench extended, 3 seeds PASS). It saved only ≈ 280 LUT
   (19,094 → 18,806, 83 → 82 %) and the rolls did not improve: `ebfeeb74` 4
   violations (clk100 −0.151), `a31fa48e` 0/0 but +0.039 clk100 / +0.046
   clk_pix, `efc9bb67` −0.317 clk_mem_90. So the knife-edge is the placement at
   82-83 %, not the CDC. Where the filter's cost really is: the module table
   shows the IIR at ≈ 160 LUT; the +1,000 are **ALU carry chains** — eight
   24-bit partial products summed into a 61-bit word per tap ≈ 300 ALU per tap
   plus ≈ 200 for the input product, inherent to doing the exact 37×24 in
   12×12 pieces. Ways down, all ed's call: a 2-tap filter (coeff_x2 = cy2 = 0,
   −1/3 of the adders, second-order response); dropping the lowest partial
   products (sub-LSB error, breaks the bit-exact bench); or a logic diet
   elsewhere (sdp_engine 1,119 LUT, AUX channel + interface 1,153, second
   PSG/6522 pair 690). Card still runs `3c863693`; main unchanged at 3a05b59e.
   **Ed's diagnosis, confirmed and FIXED 2026-11-18 afternoon: not density, the
   DSP positions.** Every DSP block on the GW5A-25 is in ONE row, `DSP_R19[0..27]`;
   the filter's 28 MULT12X12 were scattered along it and its adder chains settled
   in rows 2-20, columns 21-51 — the band where the DP channel-management
   cluster lived before (R15-20 C20-27, next to the DSP row). In every filter
   build the AUX logic was displaced; in the failing rolls it was scattered
   (R11C27 ↔ R31C2, 1.5-2 ns nets) and the HyperRAM PHY's ck_en flop sat 10-20
   rows from its top-edge IO (R31C79 → IOT1, a 4.26 ns net = the whole clk_mem_90
   budget). The filter's own paths have a 3-cycle budget, so its cells may live
   anywhere: `a2p25.cst` now pins the 28 cells to `DSP_R19[11..24]` (input
   products 11-12, taps 13-16 / 17-20 / 21-24), nothing else constrained. Three
   rolls, THREE clean: `eb87e606` worst +0.079 clk100 (clk_mem_90 +6.60),
   `d4a0e7d3` worst +0.118 clk_tx (+0.362 clk100, +6.43), `edb57cec` worst +0.109
   clk100 (+0.216 clk_tx, +6.08) = **BUILD OF RECORD**, committed, on the card
   (stamp 20261118133449; counters at << 3: jumps 0, max step 0, raw-path counters read 0). clk_mem_90 went from failing in 2 of 4 placements to
   +6 ns in all three; what remains at +0.1 is the chronic DP AUX (clk100) /
   D-PHY FIFO (clk_tx) knife-edge that predates the filter (pre-filter rolls
   +0.029 .. +0.56). Logic 81-83 % with the CDC raw path off (b88a0c10 kept).
   **Listening test PASSED 2026-11-18 (ed, build `edb57cec`): "sounds much better
   than without the filter." The a2n20 parity audio item is closed.**
   Listening pick NOT done:** the session stopped when the USB stick's FAT32 directory turned
   out destroyed (picker empty). Forensics from a 37 MB image of the stick:
   the firmware's Disk II track write-back (`disk.c`) received a garbage
   block number (lba 8,322,827 on a 230 KB .nib), seeked 4 GB past the end,
   and FatFS extended `disk1.nib` (entry rewritten: size 0xFDFE1600,
   1980-01-01 timestamp); the allocation was interrupted (FAT copy 2 holds a
   chain copy 1 lacks), 5.2 GB of clusters are orphaned, and the root
   directory's last 320 bytes hold Apple-side data + zeros (the other
   entries are gone). A restart alone cannot produce field-precise damage.
   Not an HDL defect of this pass. Final reading (after a wrong revision the
   same night): BOTH a junk block number and a failing stick. `disk1.nib`'s
   cluster chain is 130,045 clusters in both FAT copies, exactly what the
   recorded 4 GB size needs, contiguous from the FSInfo next-free hint, so
   FatFS really did extend the file to a 4 GB seek on a junk lba
   (8,322,827); a second 3.1 GiB orphan run starts where that chain ends.
   The stick is confirmed bad on two machines and best explains the
   Apple-side bytes in the directory sector. Firmware hardening done in
   session `disk-write-bounds` (branch `claude/strange-heisenberg-ca020e`,
   three commits 1dfc0419 / 31616ad9 / 98e7de84, fw `38f0e5b4` built, not
   flashed): checked register reads + device-ID probe before serving,
   image-bounded seeks, mount-time size plausibility, write-failure counters
   with read-only fallback, CMD+lba read twice (an Apple /RES between the
   two reads otherwise yields lba 0), quiesce + unmount before every FPGA
   reload and ESP32 restart. Junk-lba origin per that session: floating OSPI
   reads while the fabric is dark (reload window; IIgs power cycle with a
   Mac back-powering the ESP32 over USB1). Write-up
   `STICK_CORRUPTION_2026-11-17.md` (on main since the merge). **Decision 2026-11-18
   (Ed): merge the firmware branch AFTER a flash test on the card.**
   **FLASH TEST PASSED 2026-11-18 07:52, branch MERGED (f5ea6a34):**
   replacement stick in (76 root entries incl. the Mac's copies of the
   4 GB `disk1.nib`/`disk2.nib`), `.bin` FTP'd to the stick in 6 s,
   installed from the telnet menu mirror (FIRMWARE → UPDATE MCU → file →
   check "1103K -> APP1" → INSTALL; ~70 s), board back in 17 s, menu header
   MCU NOV 17 2026 22:13:35, stick + D1/D2 (RW) + HDD remounted, core stamp
   20261117210112 unchanged. Regression test: `fpga_stream.py` of the same
   aca89216 image with both drives mounted RW → directory listing before and
   after IDENTICAL (names + sizes), images remount, no OUT OF RANGE or write
   failures logged. Owed to Ed at the machine: a Disk II write-back (game
   save) under the new firmware. Telnet notes: the line mode has NO
   `fwupdate` (serial CLI only); the menu mirror's state persists between
   telnet sessions, arrows need ~0.8 s gaps, the cursor line is the
   `ESC[7m` inverse line. The recipe as planned:
   (a) copy `a2fpga_esp32_225_ospi_diskguard_38f0e5b4.bin` (sha256
   38f0e5b4…1d83cb, 1,129,888 B) to the new stick, FIRMWARE menu → UPDATE
   MCU (.BIN ON VOLUME) → INSTALL, or telnet `fwupdate <file>` then
   `fwupdate go`; or (b) `make BOARD_REV=225 DP_TEST=0 PORT=/dev/cu.usbmodemXXXX
   upload` over USB1 with the Apple II off (download-mode and back-power
   traps in `ESP32_FW_A2P25.md`). Then: images mount and list, a Disk II
   boot + a game save writes back, `fpga_stream.py` reload with a writable
   image mounted leaves the directory intact (OSD shows no OUT OF RANGE or
   write-failure counts), FIRMWARE page shows the new slot. Details:
   `stick_corruption_2026-11-17_forensics.txt`.
   An earlier stream this evening also went out with a stale file (a save
   directory collided with yesterday's read-only `rolls/g1`), caught by the
   stamp read-back: name every roll directory uniquely.
   **Uthernet II, 2026-11-17, FAULT FOUND AND FIXED (retest on hardware
   pending the build).** IP65 DATE65 on 6f24025d, slot 3 on Your Card:
   `Initializing - No device found`. Bridge side healthy (ESP32 scratch 0x0C =
   0x80/0x90: defaults seeded and read back, heartbeat, doorbell never rung).
   Monitor probe, slot 3 and a second copy of the card put in slot 7 through
   regs 0x30/0x31/0x33: `C0B4:03` / `C0B4` -> 03 and `C0F4:03` / `C0F4` -> 03,
   so the bus, M2SEL and the register front end are fine. Then IP65's actual
   check (set address 0017, read the data port twice, expect the seeded RTR
   07 D0): `C0B5:00 17`, `C0B7` -> **D0**, `C0B7` -> **55**, the bytes at
   0018 and 001A. The data port returns the byte AFTER the one addressed.
   Cause: `uthernet2.sv` auto-incremented the indirect address at
   `data_in_strobe`, which the a2mega/a2p25 bus module raises ~280 ns into
   phi0 (`DATA_COUNT`), while the 65816 latches read data at the end of phi0
   ~220 ns later; the block-RAM read output had already moved to the next
   address. The Enhanced's CPLD bridge registers read data before its strobe
   (`IO_WRITE_DATA` precedes `IO_READ_DATA` in `hdl/bus/apple_bus.sv`), which
   is why the identical shared file passed its bench and josh's ROM 01 IIgs.
   Fix (commit d9ad8c2a): increment once per bus cycle that touched the data
   port, when DEVICE SELECT falls, as a real W5100 does. Bench
   `sim/uthernet2/run.sh`: strobe at tick 15 of 27 and a two-strobe variant,
   IP65's probe, write path through both ports, doorbell, no-AI mode, MR
   reset: PASS; the pre-fix card fails it with the hardware's exact bytes
   (D0, 08). Sibling check: HDD (registered prefetch `buf_cpu_q_r`), F18A
   (TMS9918 prefetch register) and the 6522 (flag-clearing reads do not alter
   the byte read) do not have the pattern. The a2mega full core shares the
   bus module and the card, so its Uthernet II had the same defect; the next
   a2mega build picks the fix up.
   **Uthernet II DONE 2026-11-17 on the fix build (roll 1 fs `360a7c36`,
   stamp 20261117201857, streamed, stamp read back).** DATE65 after a power
   cycle: `Initializing - Ok`, `Obtaining IP address - Ok` (DHCP lease),
   `Resolving pool.ntp.org - Ok` (DNS), `Getting time - Tue Nov 17 22:27:45
   2026` (NTP), then `Setting time - Fail`. The last step is cc65's
   `clock_settime` writing the ProDOS clock, no frames involved (checked in
   `apps/date65.c`); the four network steps are the test and all passed
   through the ESP32's WiFi MACRAW bridge with MAC NAT. Bridge status after
   the run: 0x9F (MACRAW open, uplink mirrored, MAC valid, MAC filter on,
   seeded), 11 frames Apple -> wire, 184 wire -> Apple (low byte), **142 RX
   frames dropped for a full MACRAW ring** (low byte). That last number is the
   August finding (a real W5100's tiny ring overflowing under LAN
   broadcast/multicast) reproduced on WiFi; DHCP still succeeded here, so it
   is recorded, not actioned. Durability rolls of the final source
   (d9ad8c2a): roll 1 `360a7c36` 0/0 worst +0.17 ns clk_mem; roll 2
   `0bec0499` 0/0 worst +0.195 ns clk_mem (clk100 +0.81, clk_pix +1.43,
   clk_tx +1.74); roll 3 `dcccc602` 0/0 worst +0.361 ns clk_tx (clk100
   +0.60, clk_pix +0.71, clk_mem +1.04). **Build of record = roll 1
   `360a7c36` (stamp 20261117201857), the bitstream on the card for every
   check above**, committed with its timing report and resource snapshot;
   the placement/pin/power side files in `impl/pnr` are roll 3's (regenerated
   per build, identical in content for pins and power). Position: logic 73 %,
   BSRAM 50/56. Constraint note at the merge: main's `a2p25.sdc` carries one
   false path the branch never had (`hr_rst_sync_r_2 -> i_hr_ctrl/rst_n_m`,
   added by c34f7765); the build of record was timed WITHOUT it, the stricter
   case, so it holds under main's constraints too.

   **Gate status 2026-11-17 evening: items 1-5 all done on hardware.** The
   branch is ready to merge.

### 8.5 What is still off, and what it would take

- **Super Serial Card:** no UART pins on this board revision — a board
  constraint, not a budget one.
- **SuperSprite / F18A:** 16 BSRAM + ~5 k logic. BSRAM is 50/56 and logic
  72%, so it needs both the beat-organised write FIFO (B1b, −6 to −8) and the
  §7.2 Uthernet II socket buffer in PSRAM (−8) before it can be considered,
  plus a logic pass (B9 −456 FF, B10 −256 FF, B11, the §7.6 packed DOC bank
  file −2). Not started.

### 8.6 Candidates for the next pass (not in §4)

- **Pixel CDC FIFO as 1024 × 33 instead of 512 × 65** (ed, from a separate
  thread on staying clear of the `Convert_SDP32_36_to_SDP16_18` doubling,
  2026-11-16). After B4 the FIFO (`hdl/displayport/video/pixel_cdc_fifo.v`,
  instanced in `dp_transmitter` with `LANE_COUNT=4`, `PIXEL_BITS=16`) holds
  one 4-pixel group per word: 4 × 16 + 1 sof = 65 bits × 512 words. At that
  depth GowinSynthesis infers **two SDPX9B x36** primitives (512 × 36 each),
  which the option of §7.7 then splits into four x18 blocks — the conversion
  still costs two blocks here. The same bits as **1024 × 33** (two 16-bit
  pixels + sof per word) infer as two **1024 × 18** primitives, an x18
  geometry the conversion never touches: same storage, same bandwidth,
  **−2 BSRAM**, with the option left on as §7.10 requires. It is the §7.10
  rule ("x18-or-narrower primitives from the start") applied by *depth* rather
  than width: an SDP memory wider than 18 bits at 512 words lands in x32/x36
  and is doubled, the same bits at 1024 words are not.
- It is *not* a width-only change like B4: the push and pop cadence doubles on
  both sides of the gray-pointer CDC (two writes per pixel-group tick, two
  reads per stream-packer fetch), so the write side needs a 2× write strobe or
  an internal half-word sequencer, the show-ahead read contract and `rlevel`
  (which drives prefill and the underrun counter) change units, and the
  pointer compare cones the timing campaign already had to re-pipeline (the
  gray compare used to sit on the BSRAM read enable; see the comment in
  `pixel_cdc_fifo.v`) get a pointer that moves twice as often. To be weighed
  by whoever owns `dp_transmitter` on the branch that next touches it, with
  the pixel-domain simulation and an underrun-count check on hardware; not
  for the BSRAM pass that this section records.
