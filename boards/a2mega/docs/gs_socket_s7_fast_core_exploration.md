# S7 fast core — exploration log (benchmax)

Status: active, started 2026-11-11. Child of
[`gs_socket_s7_accelerator_scoping.md`](gs_socket_s7_accelerator_scoping.md)
(§2.1 clock choice, §3 performance model). Nothing here is in a board
build; everything is measured in simulation and in a core-only Fmax probe.

## 0. Goal and the two levers

Wall time on the bench = `steps × step_time + external_cycles`. The
scoping doc fixes the integration structure: the core runs in the 108 MHz
domain with a clock enable, so the step rate is **108 / N** (N = 4: 27 MHz,
the plan; N = 3: 36 MHz; N = 2: 54 MHz). Within one step the memory of
record (BSRAM, banks $00/$01) needs its own clock edge, so a step is

    address clock (regs → A_OUT → BSRAM address)  +  data clocks (BSRAM DO → mux → ALU → flags/regs)

Levers, in the order this exploration pulls them:

1. **Shorten the data cone** (timing-only rewrites, cycle-exact). Decides N:
   cone Fmax ≥ 54 MHz ⇒ two data clocks fit ⇒ N = 3; cone ≥ 108 ⇒ N = 2.
2. **Fewer steps per instruction** (cycle-count changes, architecture-exact
   only). Dead internal cycles, 16-bit fetches from the local memory, a
   data-late pipeline that frees the address clock.

The classic cards never got past lever 1 because their memory was on the
motherboard; ours is on the card, so lever 2 is open to us.

## 1. Infrastructure

| piece | path | what it does |
|---|---|---|
| fast core | `boards/a2mega/hdl/twgs/fast/` (`F65C816*`) | the variant under exploration; starts as a renamed copy of `65C816/` |
| bench | `hdl/twgs/sim/bench/run_cpu_bench.sh` | Verilator: stock `P65C816` (reference) and `F65C816` (DUT) on identical ideal memories, same clock/reset/RDY |
| programs | `hdl/twgs/sim/bench/prog/bench_all.s` (ca65) | seven workloads with checkpoint marks, each self-checking a known result, and an eighth of corner cases the stock core alone judges |
| Fmax probe | `boards/a2mega/a2mega_cpu_probe_138b_{stock,fast}.gprj` | core + 128 KB BSRAM in the address-clock/data-clock step on the 138B; `GPRJ=… tools/build.sh a2mega all` |
| adder equivalence | `hdl/twgs/sim/bench/tb_addsub_eq.sv` | exhaustive 8-bit × modes + random 16-bit, stock vs fast `AddSubBCD` |

The bench compares on two layers. **Lockstep** (`+lockstep=1`, default):
address, RWB, VPA/VDA/VPB and write data must match every step — for
cycle-exact rungs. **Architectural** (always on): at every opcode fetch the
register file (PC, A, X, Y, SP, D, P with E, PBR, DBR) and the ordered
write stream are queued per core and compared head-to-head — for rungs that
change the step count, run with `+lockstep=0`. `+stall` adds pseudo-random
RDY stalls; `+rom=<boot1.rom>` boots the ROM 01 image (banks FE/FF, the
reset-state map in 00/01/E0/E1, $C0xx as a write-back register file) as a
lockstep stress — the ROM is never committed, point at the MiSTer
`vsim/boot1.rom`. `+ce2` steps both cores every second clk at most, which
the block-RAM microcode needs (`+define+F65C816_MCODE_ROM` builds the DUT
with it).

Probe reading: the clock Fmax reported for `clk_cpu` is the cone frequency.
The constraint (18 ns) is a target that makes the placer try, not a
pass/fail; the build "fails" timing by design until the cone is faster than
the constraint.

## 2. Baseline (stock core, 2026-11-11)

Bench (`run_cpu_bench.sh`, 4.6 M steps, 1.42 M instructions, 4.5 s wall):

| mark | workload | steps | steps / instr |
|---|---|---|---|
| 1 | sieve (BYTE, 8191 flags, 16-bit zp, (zp),Y) | 1 359 532 | 2.93 |
| 2 | fib16 (iterative 16-bit, 512 × 23) | 588 855 | 2.88 |
| 3 | strings ((zp),Y copy + compare, 256 × 64) | 542 503 | 3.65 |
| 4 | bcd (decimal counter + ADC/SBC sweep) | 507 425 | 3.13 |
| 5 | stack (recursive fib, JSR/RTS/PHA/PLX, `adc 1,s`) | 459 299 | 3.39 |
| 6 | interp (bytecode VM, `jmp (abs,x)`) | 759 201 | 3.84 |
| 7 | native (16-bit copy/sum, MVN, shift-add mul, 16-bit BCD) | 387 709 | 3.70 |

Probe, stock core, 138B (`a2mega_cpu_probe_138b_stock`, 18 ns constraint):

| | |
|---|---|
| clk_cpu Fmax | **48.09 MHz** (17 logic levels, 228 violated endpoints at 55.6) |
| worst data delay | 19.96 ns |
| critical cone | microcode BSRAM `DO` → ALU control → ALU → `PCr/CE` (via carry out), `T`, `P` |
| logic / regs / CLS | 2 028 LUT / 290 / 1 190 |

Two things the report says that the scoping doc did not know:

- The cone **starts at a BSRAM output**: the microcode ROM lives in BSRAM
  (`MC.VA_0_s7/DO[3]` etc.), so every control path pays the BSRAM
  clock-to-out before its first LUT. Pre-decoding control into wider ROM
  words costs BSRAM width (one 2048×9 block per 9 bits) and removes LUT
  levels — the 138B has 340 blocks.
- It **ends in the ALU**: `PCr/CE` is reached through the ALU carry out
  (`PCDec`), `P` through the flags, `T` through the result. The adder was a
  gate-level ripple (`bit_adder` × 16 plus four serial decimal correction
  adders), which synthesis keeps as written.

## 2b. Decision 2026-11-11: fidelity is true north

Ed's call after the baseline: **the shipping core stays cycle-faithful**.
Every instruction takes the step count a real 65816 takes, so the lockstep
bench is the gate for everything on the main line and "native speed"
remains one step per PHI2 with real-CPU timing. The reason is testing cost:
a core whose cycle counts differ from the real part needs the whole
cycle-timed software corpus (IWM 5.25-inch writes, demos, sound loops)
exercised to find the edge cases, and we do not want to pay for that.

A **ludicrous mode** — non-faithful, bubbled data-late, step diet — is
welcome as an *optional, selectable* core for users who want the bleeding
edge and for benchmarks, on two conditions: the faithful core is always
present and is the default, and ludicrous is never the only path to a
feature. It is vanity-metric work and is scheduled after the main line.

Consequences for the ladder:

- The same ~2.7 ns is needed either way. In the two-edge step, N = 3
  gives the data cone two 108 MHz clocks (≈ 17.5 ns usable) for today's
  20.2 ns. In a one-edge data-late step at 54 MHz, the cone from BSRAM DO
  to the registers has the same 17.5 ns. So **rung 2 is first on every
  path**, and it is cycle-exact by construction.
- A **cycle-exact data-late** core exists in principle: the address for a
  bus cycle must be at the BSRAM pins one step earlier than the stock core
  produces it, which means the *microcode* must also be one step ahead —
  the next microinstruction has to come out of a LUT ROM in the same step
  that fetches the opcode, not out of a BSRAM read a step later. That is a
  restructure of `P65C816.sv`/`mcode.sv`, not a microcode rewrite, and
  lockstep verifies it. It is the main line's route to N = 2 (54 MHz) and
  it is gated on rung 2a below (microcode ROM in fabric) being affordable.
- Bubbled data-late and the step diet are ludicrous-mode only.

## 2c. After the plateau: the structural options (2026-11-11)

The two-edge step needs, per step, the address cone (one clock) plus the
data cone (tC2Q + output mux + core, measured 18.7 ns after rungs 1-2d).
At 108 MHz that is N = 4 unless the data cone fits two clocks (17.5 ns
usable). All four options below keep the core cycle-exact; they differ in
what else they touch. The speedups use the scoping doc's §3 model
(Applesoft-class, 1-3 % external cycles); 2× Squeezer ≈ 11.8× stock.

| option | step rate | touches | status |
|---|---|---|---|
| A. 108 MHz, N = 4 | 27 MHz, ≈ 9-10× | nothing (the plan) | always available |
| B. core PLL at 100 MHz, N = 3 | 33 MHz, ≈ 11× | the HyperRAM-spine clock decision of 09-05 (100 is not 2:1 with clk_logic 54; broker CDC) | data fits (0.8 ns margin); **address 10.9 > 9.5 ns** — needs the ADDR_BUS IR pre-decode (≈ −2 ns) first |
| C. 108 MHz, N = 3, memory clock phase-shifted | 36 MHz, ≈ 12-13× | a second PLL output for the BSRAM clock | **dead**: address 10.9 and data 18.7 sum to 29.6 ns against a 27.8 ns step; a phase shift only moves the shortfall between the edges |
| D. cycle-exact data-late core (3x) | 54 MHz at 108 (needs the same 1.2 ns) or 50 MHz at 100 (fits), ≈ 15-16× | core control-path restructure: microcode and address one step ahead | design not started |

A fifth lever is fidelity-compatible and worth noting: a small cache in
front of the 128 KB banks (one to four blocks, placed near the core; one
mux level) with a **CE stall on a miss**. The core's step count per
instruction is unchanged — the broker already stretches steps for external
cycles — only wall time moves. Hit path saves ~2 levels and the long BSRAM
exit nets; a 5-10 % miss rate at two clocks each costs ~0.15 clocks per
step. It is the kind of thing that turns a 1.2 ns miss into a fit, but it
is two weeks of work and a second memory hierarchy; only if B/C fail.

## 2d. Proposed clocking after the verdict (ed, 2026-11-11)

**One accelerator domain, isolated at the socket.** A dedicated PLL output
(100 MHz) clocks the socket PHY's pin sequencer; the data-late core steps at
50 MHz (CE or a synchronous 50 MHz output of the same PLL); the 128 KB banks
and the ROM image live in that domain. PHY ↔ core is synchronous logic.
Everything the accelerator does with the rest of the machine — video, I/O,
slot space, the Mega II banks, the card's own peripherals — is a socket
cycle: out to the motherboard and back in through the slot, as every real
accelerator does. No fabric fast path; S8 (serving our own slot cards
inside the chip) becomes a deliberate later exception.

Consequences:

- The 108 MHz HyperRAM/DOC spine is untouched. The DOC budget on a2p25
  was a 7 % miss fixed by priority, not headroom, and "glitch-free under
  typical usage" is not a margin to spend on a 7 % clock cut.
- The only remaining clock crossing is the expansion-RAM cache miss path
  (DDR3 now, HyperRAM later), which already stalls the core: a few core
  clocks per miss in wall time, never in step count. ESP32 housekeeping is
  a slow register handshake.
- On the shared backing store the DOC cannot be stalled and the core can:
  **DOC first, CPU stalls.** (The TransWarp plan's "CPU at arbiter
  priority 0" is superseded by this for the shared-memory case.)
- The PHY sequencer at 10 ns instead of 9.3 ns resolution: sample points
  and output-enable delays are re-derived in clocks; the socket-timing
  bench (`hdl/twgs/sim/tb_gs_socket.sv`) re-validates it.
- The core clock is free to move later: if a rung finds the 1.5 ns, the
  PLL goes to 108 and nothing else is re-timed.

Open checks: a free 100 MHz PLL output on the 138B SOM (the a2mega PLL
plan lists unused CLKOUTs); the broker's miss-path CDC design.

**Decided 2026-11-12 (ed): 108 MHz.** Rung 5 (§4) found the 1.5 ns, so the
accelerator domain runs at 108 MHz: the PHY's pin sequencer at 108 MHz, the
core stepping every two clks, 54 MHz. Nothing else in this section changes:
it is still one accelerator domain isolated at the socket, and the
HyperRAM/DOC spine is still untouched. The 100 MHz figures above and the
open check for a free 100 MHz PLL output are superseded; what is open
instead is where the accelerator's 108 MHz comes from in the
accelerator-only build (the PLL output the S6 build already uses, or one of
its own). The 100 MHz probe (`a2mega_accel_probe_138b_n2`) stays as a
margin instrument; `a2mega_accel_probe_138b_n8` is the reference.

**Correction and outcome, the same day.** S6's socket clock on hardware is
not 108 MHz: the board's socket PLL (`gowin_gs_pll`) is 110 MHz (50 × 22 /
10, constrained at 9.091 ns in `a2mega_138b.sdc`), and "108" in this log,
in the scoping doc and in the PHY's comments is the nominal figure and the
simulation bench's clock. The accelerator-only build therefore keeps that
PLL unchanged, which is what "the PHY S6 ran on hardware" means: **110 MHz,
55 MHz steps**. The probe closes there too (one placement, 0 failing,
+0.007), and the board build closes at 110 MHz:
[`gs_socket_s7_accel_only_build.md`](gs_socket_s7_accel_only_build.md).

**Memory placement on the HyperRAM board rev (ed, 2026-11-11):** instead of
putting the accelerator's expansion banks on the HyperRAM beside the DOC,
**give the DDR3 to the accelerator and move the slot side (framebuffer,
shadow, DOC, peripherals) to the HyperRAM** — i.e. make a2mega's slot side
the a2p25 architecture, which already runs the full core at 1080p×4 with
SHR and DOC audio from a 108 MHz HyperRAM (`docs/memory_bandwidth_analysis.md`
§3, `boards/a2p25/docs/MODERNIZATION_PLAN.md`). The DDR3 then has one
client: no arbiter tails (the 0.55-1.6 µs unbounded-under-FB-load tails
were the reason the TransWarp plan rejected CPU-on-DDR3), the
`ddr3_port_cdc` FIFO BSRAM (33 of 90 blocks) is freed, and the two boards
share one slot-side gateware. Supersedes the "CPU → HyperRAM" placement in
the TransWarp plan for the board rev.

**Testing the split on today's boards (ed, 2026-11-11).** The board-rev
architecture can be exercised before any board exists: an
**accelerator-only a2mega build** (socket PHY + core + local banks/ROM +
DDR3 as the single-client expansion store + ESP32 for control/telemetry
over WiFi/telnet; no framebuffer, shadow snoop, DOC, slot ROM/I/O decode or
OSD) in one slot of a IIgs, with an **a2p25 in another slot** providing
video, DOC audio, disks and peripherals from its HyperRAM. The two cards
share nothing but the motherboard bus, which is exactly the claim the
single-domain design makes, so the pair is a stronger test than the merged
board would be: any coupling the accelerator secretly needs shows up as a
failure instead of a fast path. It also makes the single-client DDR3
latency measurable on real hardware and shows the slot-side gateware
running unmodified beside an accelerator (a2p25 sees the accelerator's
forwarded bank $00/$01 writes as ordinary CPU writes, §2.4 of the scoping
doc).

Interaction points to watch: (1) **/RESET** — a2p25 holds the open-drain
slot /RESET until its mounts are done (`reset_hold`); the accelerator's S6
sequencer sees that as the socket /RES it already re-registers, so the
hold simply lengthens the reset, but the arm window is measured from the
*release*, which is now a2p25's, not the ADB micro's. This is not a
bench artefact to design around: the accelerator must coexist with any
reset-holding card (our own slot cards, other vendors' storage cards), so
the S6 sequencer's arm reference is defined as *the last release of
/RESET*, whoever held it (ed, 2026-11-11). (2) **Slot I/O
ownership** — the accelerator build must claim no $C0n0/$Cn00/$C800 space
and must never assert /INH or /DMA, or it collides with a2p25's slots.
(3) **No OSD on the accelerator** — speed/mode control goes through the
ESP32 (telnet), or later through a2p25's OSD by a side channel; nothing on
the bench needs that yet. (4) The a2mega must carry the **138B SOM** (the
cone numbers are 138B; the 60K has not been measured for this core).

## 3. The ladder

| rung | change | exactness | expected |
|---|---|---|---|
| 1 | `AddSubBCD` as one behavioral add (carry chain) + parallel decimal correction; `ALU_TAB` folded into the microcode ROM (`AF_TAB`) | cycle-exact | done: exact, no cone change |
| 2a | microcode tables `syn_romstyle = "logic"`: microinstruction register in fabric flops behind LUT ROM, removing the BSRAM tC2Q + column net (~3.2 ns) from the head of every control path | cycle-exact | cone −1.5…−3 ns; also the enabler for 3x |
| 2b | pre-decode into ROM width: one-hot `BUS_CTRL` selects + `w16` terms (done), then `LOAD_P`/`LOAD_PC` conditions per opcode, shallower LUT ROM | cycle-exact | done part: 18 → 16 levels, Fmax flat within roll noise (50-52); ~1.5 ns still to find |
| 3 | cycle-exact data-late: the address of the next step formed from next-state values (`NA_OUT`), registered inside the BSRAM at the step edge; one clock per step; `A_OUT` = its register; writes at the step edge with a one-entry read bypass | cycle-exact (lockstep, incl. stalls, interrupts, ROM 01 boot) | **done 2026-11-11**: 41.1 MHz naive, 49.5 MHz after two next-address cuts (first rolls, core + 128 KB memory) — **main line** |
| 4a | the next microinstruction and the next address as candidates, the late `NextState` decision selects | cycle-exact | **done 2026-11-12**: with the broker's near memory, 50 MHz steps in the integrated probe (one placement) |
| 5 | for a core that steps every second clk at most: the microcode's successor rows read from block RAM a clk early (`F65C816_MCODE_ROM`); late signals taken out from behind logic they did not need | cycle-exact | **done 2026-11-12**: the integrated probe closes 108 MHz / 54 MHz steps and 100 MHz / 50 MHz, three placements each; half the LUTs |
| L1 | ludicrous: bubbled data-late where 3x's address path does not close | architecture-exact | optional core |
| L2 | ludicrous: step diet (RMW double write, dummy reads on indexed page crossings, 16-bit operand fetch as one local read) | architecture-exact, local memory only | 10-20 % fewer steps |

**Re-ranked after rung 1 (2026-11-11).** The data clocks of the
two-edge step have to hold tC2Q + output mux + the whole core cone
(≈ 20 ns), so N = 3 needs ≈ 2.5 ns out of a 14-level fabric cone and N = 2
is out of reach by tuning. Rung 3 changes the shape instead: with the
synchronous BSRAM, latching the address *at* the step edge and consuming
the data in the following step makes each step one clock — the memory
access overlaps the previous step's execute, the structure Arlet Ottens'
6502 uses to run one bus cycle per clock from block RAM. The same ≈ 20 ns
cone then gives N = 2 (54 MHz steps at 108) directly, and every rung-2 ns
is upside on top. The cost is a microcode re-schedule: every use of `D_IN`
(the `DB` mux, `AddrGen` operand captures, `NextIR`, `PBR/DBR/P/DR/T`
loads) moves one step later, and an address that depends on the byte just
read (operand high byte → effective address) needs either a bubble or a
short combinational path from the BSRAM output into the address mux
(tC2Q + mux + a byte concatenation, inside one 9.3 ns clock). Rung 3 is
therefore promoted to the main line; rung 2 becomes its finishing pass.

Rungs 1, 2a, 2b and 3x are verified by lockstep; L1 and L2 by the
architectural layer plus the ROM boot, and they ship only beside the
faithful core. Each rung gets one probe build and a row in §4; a rung that
does not move the cone or breaks the bench is reverted, not kept.

## 4. Log

- **2026-11-11 baseline.** Bench and probe built; stock numbers above.
- **2026-11-11 rung 1 (sim).** New `F65C816_AddSubBCD`: 17-bit behavioral
  add for the binary and decimal-subtract paths (decimal subtract's nibble
  carries are the binary carries; digits get −6 where the carry out is 0),
  generate/propagate decimal carries and parallel digits for decimal add,
  overflow on the uncorrected nibble sum with the mode's carry-in. Bit-exact
  against the stock module on 3 572 864 vectors (exhaustive 8-bit operand
  space in all 16 mode combinations, exhaustive upper byte with random lower
  bytes, 2 M random 16-bit). `ALU_TAB` folded into a second registered ROM
  column (`AF_TAB`, generated from the stock tables). Full bench, `+stall`
  and 1 M-step ROM 01 boot in lockstep: PASS. Probe build (`a2mega_cpu_probe_138b_fast`):
  **48.40 MHz**, 17 levels, 186 violated endpoints, 2 145 LUT — the cone
  did not move. The worst path is now data-BSRAM `DO[0]` → `DB` mux → ALU →
  zero-detect/result select → `P[1]` (Z), 20.16 ns:

  | segment | levels | ns | note |
  |---|---|---|---|
  | BSRAM tC2Q | — | 2.2 | data memory block, `mem_mem_6_6_s` |
  | 64:1 BSRAM output mux (`mem_DOL`) | 3 | 4.2 | 2.0 ns net out of the BSRAM column, 1.4 ns fan-out-19 net into the core |
  | `DB` operand mux | 3 | 2.9 | `BUS_CTRL` decode + select |
  | adder (`t1`, `AluR`) | 3 | 2.6 | the rewritten path; was similar before |
  | result select / zero detect (`n755`, `n752`) | 5 | 5.0 | `secOp` result mux, 16-bit zero, `ZO` |
  | `P[1]` load mux (`n1524`) | 3 | 2.2 | the `LOAD_P == 001` condition tree |
  | | 17 | 20.2 | cells 33 %, routing 56 %, tC2Q 11 % |

  Reading: the GW5A fabric costs ~1.2 ns per level here, routing included,
  so 17 levels ≈ 20 ns whatever the adder does. The memory's share
  (tC2Q + output mux + the nets to the core) is 6.4 ns on its own; the
  core's own cone from the `DB` inputs to `P` is ~13.7 ns / 14 levels. The
  stock worst path had the same length but started at the microcode
  BSRAM; the fold moved that start into fabric flops (`MC.ALU_CTRL.w16_s4/Q`
  now appears as a launch point at 20.0 ns), which is why the worst path
  changed identity without changing length. Rung 1 is kept (it is exact and
  removes a 16-stage ripple from the netlist) but it is not the lever.
- **2026-11-11 memory share isolated.** `a2mega_cpu_probe_138b_fast_1blk`
  (same core, one 2 KB block, no output mux): **55.17 MHz**, 18 levels,
  17.3 ns, 8 violated endpoints. The worst path now starts at the
  *microcode* BSRAM (`MC.ALU_CTRL.w16_s9/DO[3]`, tC2Q 2.0 + 1.2 ns net) →
  `SB`/`DB` muxes → adder → result → zero → `P`. So:

  | cone | MHz | ns | what it bounds |
  |---|---|---|---|
  | core alone (microcode BSRAM → regs) | 55.2 | 17.3 | the fabric cone; ~3.2 ns of it is the microcode ROM's tC2Q + net |
  | core + 128 KB memory (tC2Q + 64:1 mux) | 48.4 | 20.2 | the data clocks of the two-edge step as the plan has it |

  For N = 3 at 108 MHz the two data clocks give 18.5 ns minus 0.5 ns
  uncertainty and setup ≈ 17.5 ns for the 20.2 ns cone: ~2.7 ns to find.
  Candidates, by size: microcode register out of BSRAM into fabric flops or
  a pre-decoded wider ROM whose first LUT level disappears (≈ 1.5-2 ns),
  one-hot `BUS_CTRL` for the `SB`/`DB` muxes (≈ 1 ns), flag-load tree
  pre-decoded per opcode (≈ 1 ns). That is rung 2, and it decides whether
  N = 3 is real. N = 2 is rung 3 only.

- **2026-11-11 rung 2a.** `F65C816_mcode` carries `syn_romstyle = "logic"`
  at module level (on the table itself the attribute is silently ignored —
  SUG550 §5.17 allows module, reg or instance). Probe
  `a2mega_cpu_probe_138b_fast`: **52.07 MHz**, 18 levels, 18.68 ns, 74
  violated endpoints (from 48.40 / 20.16 ns / 186). MCode is now 1 253 LUT +
  56 regs and 0 BSRAM (was 23 LUT + 7 BSRAM); whole probe 3 359 LUT, 64
  BSRAM. Worst path still data-BSRAM `DO` → `DB` mux (3) → `CIIn` carry-in
  (2) → carry chain → `AluR` result select (5) → `P[1]` load (3). Gap to the
  N = 3 budget (≈ 17.5 ns): **1.2 ns**. Lockstep: PASS (attribute only).

- **2026-11-11 rung 2b.** `gen_fast_mcode.py` now generates `fast/mcode.sv`
  with a second pre-decoded column (`XT_TAB`: one-hot `SB_SEL`/`DB_SEL`,
  `W16_FORCE/M/X`); `w16` and the operand muxes are built from it. Lockstep
  full bench, `+stall`, 1 M-step ROM boot: PASS. Probe: **50.11 MHz, 16
  levels** (from 18), 19.12 ns, 94 violated endpoints, 3 593 LUT. Two fewer
  levels but 0.4 ns *slower* than 2a: the worst path carries three nets of
  0.9-1.5 ns (`DB_2`, `n848_s6`, `PCr_14_s5`) where 2a's had one. This is one
  placement roll against one; the two results are inside the roll-to-roll
  spread this project has measured elsewhere (timing_round2.md), so 2a+2b
  reads as **≈ 50-52 MHz, 18.7-19.1 ns**, about **1.5 ns short of the N = 3
  budget**. The worst path now ends at `PCr/CE`: carry out → `PCDec` →
  `LOAD_PC` decode → PC enable; path 4 is the LUT-ROM lookup itself
  (`X_1/Q` → `NextState` → `XT_TAB` → `XT`, 19.3 ns), so the microcode LUT
  ROM is at the edge of the budget too.

  Where this leaves the main line: the two-edge step is N = 4 (27 MHz, the
  plan) unless ~1.5 ns more comes out, and the same cone gives a cycle-exact
  data-late core N = 2 (54 MHz) minus the same 1.5 ns. Remaining cycle-exact
  cuts, by expected size: pre-decode the `LOAD_P == 001` flag-load condition
  and the `LOAD_PC`/`PCDec` enable per opcode (1 level each); split the
  microcode LUT ROM by opcode class so the lookup is shallower; two more
  placement rolls of the final 2b source before trusting any of these
  numbers to ±0.5 ns.

- **2026-11-11 rung 2c.** Flag-load condition tree (`LOAD_P == 001`, the
  PLB/PLD/TSX specials) pre-decoded into `XT_TAB` (now 25 bits); the
  MVN/MVP PC repeat written as `PCr + ({16{PCDec}} & 16'hFFFD)` so the ALU
  carry reaches the PC through the data path instead of a register enable
  behind the whole decode; probe constraint tightened to 17 ns (the N = 3
  budget). Bench gained PLB/PLD/TSX/PHB/PHD coverage in both modes (and a
  push-order bug in that new code was caught by the mark counts, not by
  lockstep — both cores executed it identically). Lockstep full, `+stall`,
  ROM 1 M: PASS. Probe: **52.32 MHz, 19 levels, 18.62 ns**, 124 violated
  endpoints, 3 645 LUT. The PC endpoints are now `PCr/D` (enable gone), but
  the worst path shows **six LUT levels after the adder just to form `CO`**
  (`CO_s26…s8`): the rung-1 adder recovers byte/nibble carries from the sum
  by XOR, then muxes by width and decimal mode, then by `secOp`. Path 4 is
  again the LUT-ROM lookup (`DR_0/Q` → `MI.va`, 18.5 ns). Budget gap ≈ 1.1 ns.

- **2026-11-11 rung 2d, first try — REGRESSION, reverted in part.** One-hot
  ALU control (`FST`/`SEC`/`SEL_ADD` as microcode columns, `FALUCtrl_r` 25
  bits, ALU selects as AND-OR; bit-exact on 5.12 M vectors × all 256 control
  words, `tb_alu_eq.sv`) plus a 20-bit adder with a guard bit above every
  nibble so nibble/byte carries are sum bits. Lockstep: PASS. Probe:
  **47.46 MHz, 23 levels, 20.6 ns.** The path says why: GowinSynthesis
  splits the carry chain at each guard bit into four CLS segments
  (`g_3 → g_5`, `g_8 → g_10`, `g_13 → g_15`) with 0.97-1.2 ns of routing
  between them, so the chain costs ~4 ns instead of ~1.2. Lesson: **never
  put constants inside a carry chain on GW5A; one unbroken add, side
  chains for extra carries.** Replaced by a 17-bit chain plus a parallel
  9-bit low-byte chain for `co8` (adder equivalence sweep re-run).

- **2026-11-11 rung 2d, corrected.** One 17-bit chain + parallel 9-bit
  low-byte chain for `co8`, flat decimal lookahead, one-hot ALU control.
  Lockstep full, `+stall`, ROM 1 M: PASS. Probe: **52.20 MHz, 19 levels,
  18.69 ns**, 104 violated endpoints, 3 616 LUT. Worst path: data `DO` →
  mux → `DB` (3) → adder → `Result8` → carry/zero select (6, `CO_Z`) →
  the masked PC add (16-bit chain, 1.8 ns net in front) → `PCr/D`.

  **Plateau.** Four cycle-exact rungs with sound local reasoning (2b, 2c,
  2d×2) left the cone where 2a put it: 50.1 / 52.3 / 47.5 / 52.2 MHz. The
  remaining 18.7 ns is roughly half routing on a 19-level cone that starts
  5.7 ns after the edge (tC2Q 2.2 + BSRAM exit net 2.1 + mux and entry
  nets). Rearranging LUTs is not going to find the last 1.2 ns here.
  What is left is structural, and it comes in three flavours (see §2c).

- **2026-11-11 address cone measured.** `a2mega_cpu_probe_138b_fast_addr`
  (27.8 ns base period; `set_max_delay 9.260` from core registers to the
  BSRAM `AD` pins; results in the report's Timing Exceptions section):
  **10.9 ns, 8 levels — 2.8 ns cells, 7.7 ns routing.** The path is
  `IR` → the ADDR_BUS special-case decode (`n1710`, 2 levels) → the
  address mux (`a_*`, 4 levels, 1.0-1.3 ns nets between) → a **2.3 ns net
  with fan-out 65** into the 64 BSRAM blocks' address pins. The same report
  also shows the microcode LUT-ROM lookup at 26 ns under a relaxed
  constraint (`Y` → `NewAAL` → `NextState` (fan-out 175, 3.1 ns net) →
  five ROM levels), i.e. the core-internal paths stretch to whatever they
  are given; in the real step they have the whole step, and the earlier
  probes held them to one data-clock budget — an over-constraint that
  distorted every data-cone number so far. The `_mc` variant corrects it
  (core → core as 2-cycle, data cone at 18.52 ns).

  **Implication for the two-edge step at 108 MHz:** address 10.9 > 9.26
  and data 18.7 > 17.5 — short on *both* edges, by ~2 ns each. At 100 MHz
  N = 3 the data cone fits but the address cone does not (10.9 > 9.5)
  unless the IR-dependent ADDR_BUS terms are pre-decoded (−2 levels,
  ≈ −2 ns) or the memory clock is phase-lagged ~1.5 ns, which eats the data
  margin again. The address fan-out net is inherent to a 64-block memory.
  The data-late structure (D) is the only option that does not have to
  win both edges: its step is max(address, data) = the data cone, so 2 ×
  100 MHz fits today (50 MHz steps) and 2 × 108 needs the same 1.2 ns.

- **2026-11-11 data cone, step structure modelled.**
  `a2mega_cpu_probe_138b_fast_mc` (18.52 ns base = two 108 MHz clocks,
  core → core paths 2-cycle): **50.96 MHz, 19.0-19.2 ns on the data cone**,
  65 violated endpoints, all of them `DO` → core registers (`PCr`, `P`,
  `T`, `X`, `Y`, microcode registers). Same path anatomy as before: tC2Q
  2.2 + 1.9 ns BSRAM exit net + mux + 0.8/0.9 ns nets into `DB` + ALU +
  carry/zero select + 1.6 ns net into the PC adder. Across five placements
  the data cone has read 18.6-19.2 ns; call it **19 ± 0.3 ns**. Verdict
  for the two-edge step at 108 MHz: not by LUT work. (Note: `get_regs
  {u_cpu/*}` did not reach the nested `u_cpu/MCode/*` registers — one
  microcode-lookup path still appears at one cycle; use two patterns next
  time.)

### Where this leaves the goal (2× Squeezer ≈ 11.8× stock)

| structure | step | ≈ speedup | what it needs |
|---|---|---|---|
| two-edge, 108 MHz, N = 4 | 27 MHz | 9-10× (1.6× Squeezer) | nothing; the plan |
| two-edge, 100 MHz, N = 3 | 33 MHz | 11× (1.9×) | address cone 10.9 → ≤ 9.5 ns (ADDR_BUS IR pre-decode, est. −2 ns); data 19.0 vs 19.5 budget — no margin |
| data-late (cycle-exact), 100 MHz, N = 2 | 50 MHz | 15-16× (2.6×) | the 3x restructure; data cone 19.0 fits the 19.5 budget; address cone irrelevant (< step) |
| data-late (cycle-exact), 108 MHz, N = 2 | 54 MHz | 16-17× (2.8×) | 3x plus 1.5 ns the fabric has not given up |

Only the data-late core clears 2× with margin, and it does so at the same
cone we have today. The cost is the restructure of the control path
(microcode and address one step ahead) and the 100 MHz clock decision
(the 09-05 HyperRAM-spine choice assumed 108; 100 is not 2:1 with
clk_logic 54, so the broker gets a CDC or the spine moves too).

### Review of the morning (2026-11-11, re-read of the `_mc` probe report)

Read from `impl/pnr/a2mega_cpu_probe_138b_fast_mc` (no new build):

- **Correction:** the data memory is not behind a 64:1 mux. Synthesis
  mapped the 128 KB as 64 blocks of 16K×1 (`BIT_WIDTH=1`), eight blocks per
  data bit, so the output mux is **8:1 per bit** and costs 0.74 ns of cells.
  The memory side of the cone is tC2Q 2.2 + exit net 1.9 + mux 0.7 =
  4.9 ns; the "64:1" label in the earlier anatomy tables is wrong, the
  delays there are right. Nothing is left to win from re-organising the
  memory; only the 1.9 ns exit net (placement) is soft.
- **The top 25 paths are a wall 0.34 ns thick** (19.16 … 18.82 ns) ending in
  five different places: `PCr` through `ALU CO → PCDec → PC adder` (the
  MVN/MVP repeat decision, a 4 ns tail after the ALU result), `Y`/`X`/`T`,
  `P`, and the microcode registers. Cutting any one exposes the next within
  0.1 ns, which is what rungs 2b-2d experienced. A cycle-exact cut for the
  first exists (the repeat decision is `A != 0` at the start of the step,
  a register compare or a maintained flag, not the ALU carry-out) and is
  worth doing inside the restructure, not as another rung.
- **A pure core→core path is in the wall:** `X → AddrGen add → NewAAL →
  NextState → microcode LUT ROM → MI`, 18.3 ns, of which about 8 ns is the
  ROM lookup behind `NextState`. (It showed up single-cycle because the
  multicycle exception does not match the nested `u_cpu/MCode/*`
  registers.) In the two-edge step this path has the whole step; in the
  data-late step it has **one** step, so it is a real 50 MHz constraint.
- **Honest margin at 50 MHz steps:** 20.0 − 0.5 uncertainty = 19.5 ns
  against a 19 ± 0.3 ns wall is +0.2 … +0.8 ns, and the data-late path
  that no probe has measured yet is *memory data → next memory address in
  one step*. The 2× goal needs only ≥ 33-36 MHz steps, and the accelerator
  domain's PLL is free, so the frequency is a dial: data-late at 40 MHz
  (25 ns) clears 2× with ~5 ns in hand; 50 is the stretch, not the
  requirement.

### Rung 3: the data-late step (2026-11-11)

**What changed.** The microcode was already one step ahead (the
microinstruction register is loaded from `NextIR`/`NextState`), so the whole
restructure reduces to *the address one step ahead*: `F65C816` now outputs
`NA_OUT`, the stock address function (`AddrBus.sv`, the `ADDR_BUS` block
moved verbatim) evaluated on the values the registers will hold after the
current step. `A_OUT` is the register of `NA_OUT`. The memory registers
`NA_OUT` at the step edge (BSRAM read port, clock-enabled by `RDY_OUT`),
its data is the core's `D_IN` for the following step, and writes go to
`A_OUT`/`D_OUT` at the step edge on the second port with a one-entry bypass
for a read of the byte just written. One clock per step.

**Exactness.** Lockstep against the stock core, every step, in all modes:

| bench | result |
|---|---|
| program, ideal memory | PASS, 4,610,768 steps |
| program, `+datalate +stall` | PASS; 4,096 same-edge write/read collisions, all served by the bypass (the bench memory returns garbage there) |
| ROM 01, `+datalate +stall`, 6 M clocks | PASS |
| ROM 01, `+datalate +irq +stall` (2,924 IRQ assertions, 373 NMI pulses) | PASS |

`+irq` (pseudo-random IRQ/NMI on both cores) is new; no earlier rung had
interrupt coverage. Where the next-address function reads a register
instead of its next value (`IR`, `D`, `DBR`, `EF`, the interrupt-class
flags), `gen_fast_mcode.py` asserts the table property that makes it exact
(every opcode's step 1 addresses `PBR:PC` with no write; those registers
load only where no successor step reads them). In simulation the registered
`A_OUT` is also compared with the stock function of the registers on every
clock.

**Timing (probe `a2mega_cpu_probe_138b_fast_dl`, 138B, 0.5 ns uncertainty,
one clock = one step, so Fmax is the step rate):**

| build | change | step rate | worst slack @ target | failing paths |
|---|---|---|---|---|
| 1 | naive next-address logic, 20 ns target | 41.05 MHz | −4.36 ns | 932 |
| 2 | + repeat decision from `A`, + registered successor address fields, 20 ns target | **49.52 MHz** | −0.19 ns | 38 |
| 3 | same source, 21 ns target (clean-close check) | **47.62 MHz, clean** | +0.002 ns | 0 |

Build 3 is the gate result: the data-late core plus its 128 KB memory closes
at **47.6 MHz steps with the 0.5 ns policy uncertainty and zero violations**
(one roll; the three-roll durability rule applies to the integrated build,
not to this probe). The placer stops at the constraint, so +0.002 ns says
"met", not "no more to find"; build 2 shows about 0.8 ns more is there.

- Build 1's worst paths were all in the new logic: `mem → ALU → carry-out →
  PC adder → next address` (the MVN/MVP repeat decision), and `mem → NextIR
  → next-address fields`. The second was a synthesis artefact: the direct
  lookup `NA_TAB[{IR, NextState}]` shared decode terms with the main ROM
  (`M_TAB[{NextIR, NextState}]`; sound, because `NextIR` is `IR` whenever
  `STATE != 0`, but it puts the memory data in front of the lookup).
- Cuts (both cycle-exact, both asserted): the repeat decision is `A != 0`
  from the register (in that step the ALU computes `A − 1` in 16 bits, so
  its carry-out is exactly that); the address fields of **both** possible
  successor rows are registered with the microinstruction (`SUCC_TAB`) and
  the `NextState` decision picks one, so no ROM sits behind `NextState`.
- After build 2 the wall is the old data wall again (`mem → ALU → P / T`,
  `mem → microcode registers`) with the next-address paths level with it
  (`Y → AAL carry → NextState → RTL offset → address`, `mem → D + operand →
  DX + inc → address`). 3,870 LUT / 416 FF / 64 BSRAM.

**What the probe does not contain** (integration costs to expect):
the ROM image and cache as further `D_IN` sources (one more mux level on
the data cone); the broker's local-or-socket decision on the registered
`A_OUT` feeding the core's clock enable; whatever the full build's placement
costs versus an empty device. The PLL is a dial (§2d): plan the first
integrated build at 40 MHz steps and move up from there.

**Clock choice this opens (not yet decided).** Under the two-edge step,
three clocks of the existing 108 MHz (27.8 ns) did not fit (address 10.9 +
data 19 ns). Under the data-late step the same 27.8 ns only has to cover
the ~21 ns single-clock cone, with about 6 ns in hand. So **108 MHz / 3 =
36 MHz steps needs no new PLL frequency and no re-derived socket timing**
(the PHY keeps its validated 9.3 ns sequencer), and 36 MHz is at the 2×
AppleSqueezer line. It is the natural first integrated build; 100 / 2 or a
faster PHY clock / 3 is the later step toward the 47.6 MHz the probe closes.

**System track, same day** (branch `s7-system-replica-broker`, scoping doc
§9 there): memory-map replica, broker and a last-release-of-/RESET arm
sequencer, all in simulation, all benches re-run here and passing. The
broker is written for the two-edge step (memory strobed after the step
edge from `A_OUT`); moving it to the data-late contract (read address =
`NA_OUT`, local-or-socket decision from the registered `A_OUT` feeding the
clock enable) is the integration step. Its ROM 01 run is a reminder of the
socket bound: 3 M steps took 487 ms fast against 1549 ms native, 5.3 steps
per PHI2 cycle, because that stretch is 81,872 shadowed text-page writes.

**Consequence for the two-edge probes:** they still build, but their
address clock now starts at the `A_OUT` register, so they no longer measure
the address cone.

### Integration: the data-late broker and the accelerator probe (2026-11-11)

Both tracks merged (281d76c5), then the broker (`hdl/twgs/gs_accel_broker.sv`)
was moved from the two-edge step to the data-late memory contract and the
whole accelerator domain was put through place and route for the first time
(`a2mega_accel_probe_138b.gprj`: PHY + broker + replica + `F65C816` + 128 KB
RAM + 128 KB ROM image in block RAM, on the real socket balls, 108 MHz,
three clks per step = 36 MHz). **Functionally complete and verified;
timing does not close at 36 MHz yet.**

**What the broker does now** (`DATA_LATE = 1`; the two-edge mode is kept and
still passes with the stock core):

- At the end of every local step it launches the next step's memory read at
  the core's `NA_OUT`, and registers that step's memory-map decode (as a
  read and as a write) and the data-source select with it. The step then
  decides from registers. This is speculation and it is checked, not
  assumed: a step that did not follow a local step, a vector pull, a
  substituted address, a map change or a local write since the launch
  takes the slow path (a registered copy of the direct decode, one clk
  later; a relaunch that waits a full step). Correctness never rests on the
  guess. In simulation every use of the step-ahead decode is compared with
  the direct decode and stops the run on a difference.
- The core's clock enable is a register. A socket step completes the clk
  after the PHI2 fall event, which also gives the socket data byte three
  clks to the core. Native mode decides in the second clk of a step and
  hands the request to the PHY live in that clk, so it is still
  pin-identical to S6 (2.4 M clks compared).
- Each local memory has its own read address carrying only what it needs
  (the RAM: the language-card A12 fold and the main/aux bit, no bank
  compare; the ROM image: the ROM bank bit), exact for every bank that
  memory is used for. The broker records what was launched and compares
  that.
- Core: `VPA` no longer depends on the next-state logic (the two-cycle term
  comes from the microinstruction; the generator asserts the table fact),
  and the emulation-mode stack-tracking values feed the next address
  without the last-cycle term (exact: a last cycle is followed by a fetch).

**Verification** (all from the working tree):

| check | result |
|---|---|
| broker suite, 42 runs (native, paced, fast, toggling; stock core two-edge; `F65C816` data-late at 108/3 and 100/2; interrupts, RDY stalls, BE, warm reset, expansion RAM) | PASS |
| ROM 01, 3 M steps, data-late broker | same step hash and identical 128,393-write stream as native |
| new: self-modifying code (RMW of the next opcode byte); assertions on step spacing, launch → use, select steadiness, decision clk, settle time of the registered decode | PASS |
| twelve injected faults (broker and the new address logic) | all fail the suite |
| replica sweep (869,952,896 decode vectors + tracker), CPU lockstep bench, native socket regression | PASS |
| local reads already in place when the step runs | 97.9 % (test program), 91.2 % (ROM boot stretch) |

The bench's FPI model keeps the bank byte while RDY is low, so an RDY stall
on a reset release is only valid in native mode (scoping doc 9.6); the
periodic stall is now kept clear of the release in fast mode.

**Timing** (probe builds, 138B, 0.5 ns uncertainty; budgets: step-length
paths three clks = 27.8 ns, the broker's decision two clks = 18.5 ns):

| build | change | failing paths | core → core | mem → core | → next read address | core → broker (2 clk) | core → RAM write (2 clk) |
|---|---|---|---|---|---|---|---|
| 1 | first pass | 3,362 | +1.76 | +1.65 | −2.60 | −7.90 | −9.57 |
| 2 | `VPA` from the microinstruction; fabric read-address registers covered | 2,166 | +2.65 | +3.73 | −1.82 | −2.33 | −4.07 |
| 3 | registered clock enable; step decode a step ahead; registered fallback decode | 1,912 | +0.74 | +1.98 | −5.17 | (one-clk, −7.9) | +2.67 (data) |
| 4 | stack-tracking next values without last-cycle; native decision in clk 2 | 1,415 | +1.68 | +3.35 | −4.78 | −1.50 | −1.14 |
| 5 | per-memory read addresses; live request native-only; missed read presented two clks | 851 | +2.26 | +2.24 | −4.56 | −1.66 | −1.78 |
| 6 | read-address drivers replicated (`syn_maxfan`) | 775 | +1.29 | +1.49 | −3.31 | −1.83 | −3.56 |

Reading:

- **The core and memory data paths fit 36 MHz in every build**, as the
  standalone probe predicted.
- **The next-read-address path is 2-5 ns over.** After build 5 the worst
  path is an ordinary low address bit: next-address logic ~17-19 ns, then
  the mux, then **~9 ns of routing to the memory blocks**. RAM and ROM
  together are 128 blocks on those nets, twice the standalone probe, and
  they sit in BSRAM columns far from each other. Replicating the drivers
  bought about 1.3 ns.
- **The broker's own two-clk paths are 2-4 ns over**, and they are what
  still hangs on the core's outputs in the step itself: the bus-status
  signals (`VPA`/`VDA`/`WE`, through `internal` / substituted address)
  into the write enable, the request and, in build 6, a statistics counter.
- A few one-clk paths remain (the native live request into the PHY, the
  registered decode's address onto the RAM write port, the verify counter,
  the fall event into the freshness flag); each has an obvious local fix.

**Levers not yet pulled, in the order I would try them:**

1. *Step kind a step ahead.* Have the core output the NEXT step's bus
   status (write / read / internal / vector pull, from the successor rows
   already registered in `SUCC_TAB`) beside `NA_OUT`; the broker registers
   it at the launch, and nothing in a step's decision depends on the core's
   outputs any more. Removes the two-clk group except for data.
2. *Floorplan the memories* (region constraints for the RAM and ROM blocks
   next to the core) and replicate per column; the 9 ns is placement.
3. Local fixes for the one-clk list above; statistics from registered
   pulses.
4. *Fall back to four clks per step (27 MHz)*: every step-length group has
   more than 9 ns at four clks; the two-clk and one-clk groups still need
   items 1 and 3.
5. Lower the sequencer clock a few percent (three clks of ~100 MHz =
   33 MHz) at the cost of re-deriving the socket timing.

The 47.6 MHz of the standalone core probe is the core and one memory on an
empty device; the integrated accelerator domain is the number that counts,
and today it is "27 MHz with work, 36 MHz with more work".

### Integration, second round: decision from registers, memory size, WAI (2026-11-11)

Continues the entry above from build 6. Same probe (`accel_probe_top`,
138B, 108 MHz, three clks per step = 36 MHz, 0.5 ns uncertainty), now three
projects that differ only in the second local memory.

**Builds.** "Failing" is the count of failing endpoints, "worst" the worst
slack of any path.

| build | change | failing | worst | note |
|---|---|---|---|---|
| 7 | step decided from registers only: the core announces the next step's bus status (`NST_OUT`), the broker registers it | 438 | −2.83 | every two-clk group positive |
| 8 | next address split (`NA_MOVE` / `NA_STAY`); native request registered in the first clk; registered hit compare | 405 | −2.52 | placer put the RAM in the outermost strips |
| 9 | memories floorplanned in strips (below); PHY's own internal-cycle substitution off | 718 | −2.23 | address −2.17, write enable −2.23 |
| 10 | quadrant floorplan over six strips; read-address copies; registered write enable | 751 | −3.57 | worse: the core is pulled apart |
| 11 | strips again, with the copies; memories written out block by block | 579 | −3.73 | what is left is one-clk nets |
| 12 | status registered at every core step; registered, replicated memory enables; PHY takes write data a clk after the issue; constraints regenerated | 199 | −1.96 | (32 KB second memory) |
| 13 | registered one-hot PHY select; registered-status direct decode; switches updated a clk later; separate reset copy; `dec_ok` | 102 / 78 / not routed | −1.17 / −0.66 / n/a | 32 KB / 128 KB / 256 KB second memory |
| 14a | socket request taken from registers (`ea_r` + status); clock-enable copies from the broker (`CE_X`); data registers out of the reset branch | 38 | −0.35 | 128 KB |
| 14b | same sources, RAM one strip lower (R64/R82, nearer the bottom-edge pins) | 63 | −0.40 | 128 KB; the standard layout stays |
| 14c | same sources as 14a, the probe's loader stand-in (`ld_a`, `ld_d`, `ld_we`) declared false paths | 17 | −0.24 | 128 KB |

Build 13, 128 KB (the ROM 01 machine), by group: core → core +0.54,
memory → core +0.43, the three paths into the read address −0.34 to −0.53,
one-clk paths −0.45 to −0.66. Build 14c, same machine: core → core +1.28,
memory → core +0.39, core → read address −0.23 (`X` → `ADB`), and the
one-clk paths that are left are the broker's PHY select to the pad
registers (`sel_pw_r → u_phy/gs_d_o`, −0.24, of which 5.3 ns is the net to
the pad) and the interrupt copy into the address register's enable
(`irq_c → ea_r`, −0.16).

**What the die looks like.** The 138B has its block RAM in horizontal
strips 18 rows apart (R10, R28, ... R100), 36 to 38 sites per strip across
the whole width, one every 6.5 columns. Banks 00/01 are 64 blocks of
16K × 1, so they span most of two strips whatever is done, and the farthest
block is about 100 columns (≈ 5 ns) from the core. Left alone the placer
used the outermost strips. The layout that works
(`hdl/accel_probe_138b/gen_floorplan.py`): RAM in the two strips the core
sits between, the second memory in the next two out, the eight blocks of a
data bit together, two bits to a quarter of the width, and one copy of the
read addresses and enables per quarter. A layout by distance over six
strips was worse. The socket's pins are on the bottom edge and the lower
right edge, 100 to 180 columns from where the placer puts the broker; the
one-clk paths to the pin registers are mostly that distance.

**Does the size of the second memory matter?** Ed pointed out that a ROM 3
has 256 KB of ROM (the probe had assumed 128 KB). Measured, same sources:

| second memory | blocks in all | failing | worst |
|---|---|---|---|
| 32 KB (a cache in front of a backing store) | 80 | 102 | −1.17 |
| 128 KB (ROM 01 image) | 128 | 78 | −0.66 |
| 256 KB (ROM 3 image) | 192 | not routed | n/a |

A 32 KB second memory is no better than the whole 128 KB image: the
difference between the first two rows is placement noise, and a ROM 01
machine needs no cache for timing. The 256 KB image is a different
problem: with 192 of the die's blocks pinned to strips the router had not
finished after 13 minutes (the others take 5 to 8 for the whole flow) and
was stopped. A ROM 3 machine needs either a cache in front of the ROM, a
longer step for ROM reads, or a layout of its own. Not decided.

**Design changes** (all exact, all cross-checked in simulation on every
step they apply to):

- *The core announces the next step.* `NST_OUT` beside `NA_OUT`; the broker
  registers both when the core steps (`pl_int`, `pl_we`, `pl_vp_n`,
  `pl_io_int`, and the effective address `ea_r`). A step's socket request is
  those registers; a step's decision is made from them and from the decode
  registered a step ahead, or from a registered copy of the direct decode,
  which is itself made from the registered status. The core's outputs reach
  only what is passed on (write data, addresses).
- *Nothing is decided in the first clk of a step*, and that is now an
  explicit register factor (`dec_ok`) of the decision, not only a
  consequence of a counter compare: the two-clk paths end at registers that
  are captured every clk, so their inputs must be steady while the
  startpoints settle.
- *Enables are registers, in copies.* Read launch, RAM write enable and the
  core's clock enable each have several preserved copies (`ren_c`, `wen_c`,
  `ce_c`); `syn_maxfan` and `syn_keep` copies were merged again by
  GowinSynthesis, registers with `syn_preserve` (or logic fed by them) are
  not.
- *The switches take a socket cycle's effect a clk later* (`cyc_stb_q`),
  which takes the PHY's fall event out of the replica's write enables.
- *Constraints are generated* (`gen_sdc.py`) from named register groups, and
  each group's claim is a bench assertion in clks. Two were wrong before
  this round (a one-clk write-enable path and a one-clk request path were
  inside two-clk groups) and one was missing an assertion (how soon after a
  switch change the decode may be used: a mutation that delayed the switch
  update a second clk passed the suite until the assertion was added).

**Three functional findings.**

1. *WAI in the stock core was inverted.* The SystemVerilog conversion tests
   `IRQ_N == 1` where srg320's VHDL has `IRQ_N = '0'`: a WAI ended after a
   few cycles with no interrupt pending, and never ended when /IRQ fell
   while it executed. Fixed in `P65C816.sv` and `F65C816.sv`. The S6 build
   carries the same core and has the bug until it is rebuilt. Found because
   the broker now gates on the core's "takes this step" output and I added
   a WAI to the test program to exercise it; the lockstep benches could not
   see it (both cores had it).
2. *A native-mode write reached the card's copy before its socket cycle.*
   A reset between the two left the card's RAM one byte different from the
   motherboard's. The copy is now written when the cycle completes. Bench:
   `+resetw` (reset in the middle of a socket write) and `+resetpw` (reset
   in the cycle before a native write).
3. *A fast-mode local write of a step cut short by /RESET stays written*
   (it is in the second clk of the step). Accepted and counted by the bench:
   it is the reset arriving one step later.

**Verification** (working tree, after build 14's changes):

| bench | result |
|---|---|
| broker suite, `all` (41 program runs + 8 ROM 01 runs of 3 M steps) | 49 / 49 PASS; ROM 01 step hash `6012b76169ecc820` and the same 128,393-write stream in all eight modes; 98.0 % of local reads launched ahead in the test program, 91.2 % in the ROM stretch |
| replica sweep | PASS, 869,952,896 decode vectors and 5,999,973 tracker checks, twice |
| S6 socket bench (program and ROM) | PASS |
| arm sequencer | PASS |
| CPU lockstep, program (plain, `+datalate`, `+stall`, `+datalate +stall`) | PASS |
| CPU lockstep, ROM 01 (plain, `+irq`, `+datalate +irq`, `+datalate +irq +stall`) | PASS |

The replica, socket, arm and CPU benches ran before the last broker-only
change (`wen_nat & run_now`) and the bench additions, which they do not
compile. Fifteen fault injections were run against the broker suite
(one-line mutations of the new logic): twelve are detected. Two of the
twelve were missed at first and are why the suite gained `+resetw`,
`+resetpw`, the native kept-write error and the switch-settle assertion.
The three that are not detected are defensive terms with no observable
effect (`fresh_ok`'s `RDY` factor and the enable copies during WAI / STP,
where nothing the core does is visible).

**Where this leaves 36 MHz.** Not closed, 17 endpoints inside 0.24 ns on
the ROM 01 machine, and no longer the target (next paragraph). What is left
is two kinds of path. The broker-to-pad paths need either the PHY's issue
moved a clk later than S6 (a register at the pad; needs the S6 hardware
sweep to say the socket timing allows it) or the broker placed at the pads
(`GROUP` / `GRP_LOC`, not tried). The core-to-read-address path is the
same one the faster step has to shorten anyway.

**The target moved.** Ed, 2026-11-11: the current AppleSqueezer (GS Turbo)
advertises 48 MHz. From the maker's page: no 65C816 chip any more, a soft
core written from scratch on a larger Xilinx FPGA, claimed cycle accurate,
settings 2.8 / 7 / 14 / 21 / 48 MHz, "17 times" stock (= 48 / 2.8), DDR3. So
"2× the AppleSqueezer" is 96 MHz, which this hardware will not do with a
faithful core. **New goal (ed): exceed the Squeezer's 48 MHz by some
margin, however narrow.** Fidelity stays first. In step time that is under
20.8 ns; the natural configuration is §2d's (100 MHz PHY clock, two clks
per step, 50 MHz).

### Toward a step under 20.8 ns: where the time goes (2026-11-11)

Four measurements, all 138B, 0.5 ns uncertainty, one roll each.

| build | what | result |
|---|---|---|
| 15 | integrated probe as it stands, 100 MHz, `STEP_CLKS` 2, `ADDR_CLKS` 1 (`a2mega_accel_probe_138b_s2`) | 2292 failing, worst −5.9 ns |
| w20 | same netlist, **every** path given one whole 20 ns step (a what-if, not a contract) | needs 26.3 ns (38.1 MHz) |
| dl4 | the core alone with its 128 KB memory, today's source, 20 ns target (`a2mega_cpu_probe_138b_fast_dl`) | needs 21.0 ns (47.7 MHz) |
| dln | the core alone with a **16 KB** memory (eight blocks, no output mux), 19 ns target (`a2mega_cpu_probe_138b_fast_dln`) | **met, 52.6 MHz, zero violations**; at an 18 ns target 53.3 MHz (−0.75 ns) |

What they say:

- Build 15 fails in two ways. The broker in the 2 / 1 configuration still
  makes a write-enable decision inside one clk (the registered write enable
  exists only for `ADDR_CLKS` ≥ 2), 15.7 ns against 10. That is broker work
  and fits a step. The other is the core ↔ memory loop itself, which w20
  isolates.
- w20: with nothing else in the way the loop is 26.3 ns inside the
  integrated design, 5.3 ns more than the same core needs alone (dl4). The
  worst path shows why: ROM block at the far left of its strip → 2.0 ns to
  the output mux → 2.6 ns to the core → next address → 2.8 ns to the read
  address mux → **6.4 ns** to a RAM block at the far right. The 128 blocks
  of banks 00/01 and the ROM image are four strips across the whole die;
  no floorplan makes 128 blocks close to one core (a block site is about
  117 logic sites of area).
- dl4 against this morning's 49.5 MHz: the additions since (`NST_OUT`, the
  split next address, the enable copies) cost about 0.8 ns, or it is roll
  noise. Its two walls are `index register → page-cross carry → NextState →
  microcode lookup` and `memory → DB → ALU → flags`.
- dln: take the memory's size away and the core closes 19 ns clean. The
  memory paths leave the top of the report; what is left is all `Y → carry
  → NextState → …`, inside the core.

**Conclusion: the flat memory is the wall, and the cache of §2c ("a fifth
lever") is now the main line.** Its shape, fitted to the broker as it is:

- *Near memory.* A direct-mapped, per-byte cache beside the core: 16K
  entries of {tag, data}, each bit of the entry in its own 16K × 1 block
  (about 19 blocks, no output mux). The launch a step ahead goes to it
  alone, addressed by the low 14 bits of `NA_OUT` untranslated, so the
  replica's address translation leaves the address path as well.
- *Tag.* What identifies the physical byte beyond the index (bank, RAM or
  ROM, language-card bank 1), from the replica's step-ahead decode, a
  register. The step's check of its speculative launch (`ld_*` today) gains
  "and the tag read equals the tag wanted". A hit is a fast step.
- *Far memory.* The banks and the ROM image as they are, but read only
  through the existing missed-launch path (`ml_*`: registered address,
  `SLOW_CLKS`), so every path to and from them is multi-clk from registers
  and they can sit anywhere. A miss is that path plus one near write. Every
  local write goes to both (a write never misses: the entry is the byte).
- *What it costs.* Wall time on a miss (about three clks), never a step.
  Fidelity is untouched: the step sequence does not depend on the cache.
- *What else it settles.* ROM 3's 256 KB (far memory, any size), and the
  expansion banks on DDR3 later (the same miss path with a longer wait),
  which the plan needed a cache for anyway (§2d).
- *Care points.* An index is the logical low bits, so a physical byte must
  be reachable under one index only. Banks 00/01 seen through the IIe
  switches keep their low bits. Language-card bank 1 does not (logical
  `$Dxxx`, physical `$Cxxx`): it gets a tag bit, and `$C000-$CFFF` as plain
  RAM (I/O and language-card shadowing inhibited) is served from the far
  memory only and invalidates its alias.

Then, in this order: the broker's 2 / 1 contract (everything the step
decides from registers of the step before, plus the tag compare, inside
the first clk); and in the core, both successor microinstructions
registered so the late `NextState` only selects (`SUCC_TAB` extended to the
whole row, and the fetched opcode's first row from a 256-entry table of
its own), which is the wall dln shows.

### The near memory and the two-clk step (2026-11-11)

Built what the section above sets out, in two steps, and the second one
changed its shape.

**Step one: the near memory behind the decode-ahead broker.** A 16K-entry
cache of `{tag, byte}`, the launch a step ahead going to it alone, the big
memories read through the missed-launch path. It worked first time in
simulation (the suite, ROM 01, a coherence check of every entry against
the far memory at the end of each run). The what-if build (every path
20 ns, `nw20`) said 41.7 MHz, up from 38.1, and showed what was still in
the way: the core's next address is not valid until 18 ns after the step
edge, and the replica's decode of it for the following step (the decode
"ahead" that the tag and everything else the broker registers at a launch
are made from) adds 5.4 ns behind that. **Decode-ahead cannot fit a 20 ns
step**, whatever the memory.

**Step two: decode in the step, not ahead of it** (`gs_accel_broker`
`NEAR = 1`; the two were folded into one mode). The step's address and
status are registers from the moment the core steps (`ea_r`, `pl_*`: they
were already). So:

- clk 1 of the step: the replica decodes those registers. Registered at
  its end: the decode (`aq_*`, as before), "this step completes locally"
  (`go_q`: not native, no socket cycle needed, write buffer free if it
  forwards, RDY high), "it needs the near memory's byte" (`rdn_q`) and the
  tag compare (`nh_dq`: the tag read at the launch against the tag the
  decode names; not used if that entry was written at or after the launch).
- clk 2: the core's clock enable is `go_q & (~rdn_q | nh_dq)`, one gate
  behind registers, in four copies. The near memory is read again at that
  edge, at the core's next address.
- A local write is registered in clk 2 (address, data, near index and tag)
  and made in the clk after, from registers, to both memories.
- The core's data is the near byte or one register (`alt_q`: far data on a
  miss, the socket byte on a socket read).
- Everything that is not a two-clk step (socket cycle, near miss, a
  forwarded write waiting for the buffer, RDY low) is the old sequencer
  deciding in clk 2 from the registered decode, as before.

The core's next address now drives the near memory's address pins, `ea_r`
and nothing else; the replica's two prefetch decoders are gone from the
netlist. The step after a socket cycle is a two-clk step like any other
(decode-ahead could not launch for it: 8.8 % of the local reads in the
ROM 01 stretch).

**Simulation** (`run_gs_broker_sim.sh`, builds `b100_2x` and `b108_2x`:
100 MHz = 50 MHz steps, 108 MHz = 54 MHz steps):

| | |
|---|---|
| program suite | 62 / 62 runs, 21 of them on the near-memory broker (every mode, resets in and before socket writes, expansion RAM, local slot firmware, both clocks) |
| ROM 01, 3 M steps | step hash `6012b76169ecc820` and the 128,393-write stream identical to native, at both clocks |
| near memory in that stretch | 2,433 misses in 2,144,424 local reads (99.9 % two-clk steps); 3,112 of 16,384 entries used |
| fault injections | 27 one-line mutations of the new logic, 18 detected |

Of the nine not detected, eight are terms the design does not need
(a redundant line, now removed; two guards on the `$Cxxx` alias that back
each other up; two that invalidate a stale launch in cases no step
produces; three that restate what the registers already guarantee). The
ninth is a real gap in the bench: the write of a step that completes in
the very clk /RESET is seen is not exercised (the logic has no special
case for it: a write registered is a write made).

Three injections were missed at first and are why the test program gained
T18 (one byte written and read through both of its addresses, `$Dxxx` in
language-card bank 1 and `$Cxxx` with IOLC inhibited), T19 (a read that
goes to the other bank than writes do, of an address last written there)
and an eviction read in T16b, and the bench a check that a step is never
completed while RDY is low. The expected-result table had also stopped two
entries short of the program's results; it covers them now.

**Timing** (`a2mega_accel_probe_138b_n2`: 138B, 100 MHz, the generated
contract `accel_probe_138b_n2.sdc`, 0.5 ns uncertainty):

| build | what | failing | worst one-clk | worst step path |
|---|---|---|---|---|
| nw20 | near memory, decode ahead; what-if (every path 20 ns) | 173 | n/a | needs 24.0 ns (41.7 MHz) |
| xw20 | near memory, decode in the step, no floorplan; what-if | 198 | n/a | needs 22.2 ns (45.1 MHz) |
| n2a | real contract; near blocks one per site index, 46 columns wide | 69 | −0.43 | −0.42 |
| n2b | same, with the step-address hold moved from its enable to its data | 422 | −2.70 | −4.13 |
| n2d | near blocks packed into site indices 18-21 | 137 | −1.07 | −1.20 |
| n2e | n2d with `Place_Option` 2 / `Route_Option` 1 | n/a | n/a | router not finished in 25 min, stopped |

Three placements of one design differ by more than anything changed
between them (n2a to n2b is one register's enable; identical floorplan), so
none of them is a result to stand on. Read together they say **about 47 to
48 MHz**: level with the target, not past it, against 38 MHz for the flat
memory this morning.

What is at the limit, all at once:

- *The decode, one clk.* `ea_r` → replica decode → `go_q` / `rdn_q` /
  `nh_dq`: ten levels, 10.5 to 11 ns. The depth is the general decode
  (`is_local` behind the aux-bank logic behind the expansion-bank bound).
- *The clock enable, one clk.* It is one gate behind registers but it is
  not a short path: the core uses its enable in load conditions (`EN_m` …
  inside data logic, not only on clock-enable pins), and `go_c` → core
  measures 8.9 to 9.9 ns.
- *The core's own loop, two clks.* `index → page-cross carry → NextState →
  microcode` and `near memory → DB → ALU → flags`, 20.4 to 21.2 ns: the
  wall the standalone probe shows at 53 MHz, plus 1.5 ns.

Next, in this order:

1. *A cheap first-clk decision.* Most steps can be classed "local, no side
   effect, nothing to forward" from the bank, the page and a few switch
   bits (a read in banks 00/01 below `$C000` or in a ROM bank; a write
   below `$0400`; an internal cycle outside `$Cxxx`), without the full
   decode. It only has to be a subset of what the full decode allows, and
   the replica's exhaustive sweep can prove that it is. Then the enable can
   be a register again (decided and combined in the first clk).
2. *The core:* both successor microinstructions registered, the late
   `NextState` only selecting between them (and the fetched opcode's first
   row from a 256-entry table of its own).
3. A clock a little under 100 MHz is always there: 97 MHz is 48.5 MHz.

**What the contract is now.** Thirty-odd exception lines instead of
seventy, in four statements: core / near memory / data select / `alt_q` to
core / near address / step registers are step paths (two clks); the core's
outputs reach other broker registers in the second clk at the soonest; a
far read's address is presented for two clks; the mode changes only when
the core steps. Everything else is one clk, the decode included.

**Floorplan facts** (`gen_floorplan.py near`). Some block-RAM site indices
hold two 16K × 1 blocks (`[A]` and `[B]`: 16, 18, 19, 21, 23 near the
middle of the die), the others one (17, 20, 22); naming a half of a single
site is error CT1130 and the build stops, leaving the previous timing
report in place. The standalone core probe that closes 52.6 MHz had its
eight blocks in four neighbouring sites. Left to itself in the integrated
design the placer put near-memory blocks 100 columns from the core.

**Design note for item 1 (not built yet).** Two tiers of decode instead of
one:

- *Cheap, in the first clk, for the common classes.* From the bank, the
  page, `we`, `/VP`, ROMBANK and the ROM type only:
  a read in banks 00/01 below `$C000`, or at `$D000-$FFFF` unless
  ROMBANK (ROM 01), or in a ROM bank; a write in banks 00/01 below `$C000`
  outside the pages that can be shadowed (`$0400-$07FF`, `$0800-$0BFF` on a
  ROM 3, `$2000-$9FFF`); an internal cycle outside `$Cxxx`; never a vector
  pull. For those the tag is cheap as well: ROM or not (`RDROM` and IOLC
  for the language-card area), the A12 fold (`LCBNK2`, IOLC, `RDROM`), and
  the main / aux bit, which the replica already forms without the bank
  compare for the read address (`aux00_rd`; the write view with RAMWRT).
  `gs_mmu_decode` gets these as outputs and the decode sweep proves, over
  every vector, that the class implies `is_local`, no side effect and no
  forwarded write, and that the cheap tag is the full decode's.
- *Full, with two clks, for everything else* (socket steps, expansion
  banks, forwarded and language-card writes, `$Cxxx`): the registered copy
  of the decode used from the third clk, as the decode-ahead broker's slow
  path does. Its paths become two-clk paths again.

With the first tier that shallow, the core's clock enable can be decided
and combined with the tag compare in the first clk and be a plain register
again (`ce_r`), and a write of a cheap-class step takes its address from
the cheap view.

### Two tiers of decode, built; what is left is the core (2026-11-12)

The design note above is built (`gs_mmu_decode` `fast_*`, the broker's
`fa_q` / `fb_q` / `fh_q`), with one change found on the way: deciding and
combining with the tag compare into one clock-enable register in the first
clk was nine levels again, so the first clk ends in three registers
(completes anyway; completes if the byte is there; the byte is there) and
the enable is one gate behind them in the second.

**Proof and simulation.**

- The decode sweep checks the cheap view against the golden model on every
  one of its 869,952,896 vectors: where it says "the card's alone" the
  full decode says local, no side effect, nothing forwarded, write stored,
  and its ROM / bank-bit / A12-fold answers are the full decode's. 115 M
  read, 10.5 M write and 447 M internal-cycle vectors are in the class; no
  failures. Four deliberate errors in the cheap view (a shadowable page
  let through, ROMBANK ignored, the fold without IOLC, the hi-res aux rule
  without HIRES) are each caught.
- Broker suite 72 / 72, ROM 01 hash and write stream unchanged. In the
  ROM 01 stretch 96.9 % of the local steps are two-clk steps; the rest are
  mostly its 81,872 forwarded text-page writes, which now take four.
- The registered full decode now reads wrong in simulation until its two
  clks have passed (`aq_bad`), in every data-late configuration, so that a
  use of it before its timing contract allows fails instead of working by
  the grace of a zero-delay decode. That caught an injected fault the suite
  had passed (a cheap-class write taking its tag from the full decode).
- Test T20 reads the two ROM banks at one address in both orders (caught
  another). 15 injections on this logic, 14 detected; the one left is
  equivalent on this code (re-using the far memories' output registers is
  safe again now that the decode is used two clks later; it stays off).

**Timing** (same probe and contract generator; the full decode is a
two-clk path again, the probe's power-up reset is out of the timing):

| build | what | failing | worst one-clk | worst step path |
|---|---|---|---|---|
| n2f | two tiers, enable registered in the first clk | 158 | −1.54 (cheap view → enable, nine levels) | −1.53 |
| n2g | first clk ends in three registers | 432 | −2.88 | −3.52 |
| n2h | n2g + the probe's reset net a false path; the launch-index compare off the write port's mux | 201 | none in the worst 25 | −1.77 |

- n2g was the second placement of the bad kind (n2b the first). Both had
  the probe's power-up reset among their worst paths: one counter bit to
  the clear of 1,100 registers, by default a one-clk path. It is a stand-in
  for a reset that is released long before the socket is armed, and it is
  now a false path. One build since is not proof that this was the cause.
- In n2h **every failing path in the worst 25 is the core's own loop**:
  `AAL → page-cross carry → NextState → microcode registers` (−1.73) and
  `→ next address → near memory / ea_r` (−1.77), then `near memory → core`
  (−0.88). The broker's own paths have slack: enable into the core +1.1,
  full decode +8.6, far memory +10.

**So the broker is no longer the limit; the core is, by 0.4 to 1.8 ns
depending on the placement.** What the paths ask for, in the core, all
checkable by the lockstep bench:

1. *The next microinstruction as candidates.* `NextState` is `STATE + 1`,
   `STATE + 2` or 0, and in the fetch step always 1 with the opcode from
   memory. Look up both successor rows from the registered `IR` / `STATE`,
   the fetched opcode's first row from a 256-entry table of its own, and
   let the late decision select (`NS_ZERO`, `NS_INC2`, "fetch step").
2. *The next address as candidates.* The same decision selects the address
   fields (`SN`) today and the address adder sits behind it; evaluate the
   address for each candidate row in parallel and select the result.
3. *The flags.* `memory → DB → ALU → flags → P` is the path behind those.

### Rung 4a: the next microinstruction and the next address as candidates (2026-11-12)

Items 1 and 2 of the list above, in the core (`F65C816.sv`,
`gen_fast_mcode.py`). `NextState` is 0, `STATE + 1` or `STATE + 2`, and 1 in
the fetch step with the opcode on the bus; simulation now asserts exactly
that on every step.

- The microcode module takes the **registered** `IR` / `STATE` and looks up
  both successor rows; the fetch step looks up `{opcode on the bus, 0}`;
  `NS_ZERO` / `NS_INC2` / "fetch step" select. No table behind the late
  decision.
- The next address is evaluated for the fetch candidate and for both
  successor rows (`SN`) in parallel, each the way it was (next register
  values without an increment, or current values with it), and the same
  decision selects the result. Five more `AddrBus` instances.

Exact: lockstep against the stock core in every mode (program plain,
`+stall`, `+datalate`, `+datalate +stall`; ROM 01 plain, `+irq`,
`+datalate +irq`, `+datalate +irq +stall`: 7 to 8 M steps, 3,915 IRQ
assertions, 485 NMI pulses), and the broker suite 72 / 72 with it.

| build | what | result |
|---|---|---|
| dln18 (before) | core + 16 KB, 18 ns target | 53.3 MHz |
| r4dln17 | the same with the candidates, 17 ns target | **55.2 MHz** (−1.13 ns) |
| n2i | integrated, 100 MHz | 133 failing, step paths −1.2 to −2.3, a poor placement (enable into the core −0.9 where n2h had +1.1) |

What the standalone report shows next (all three level at about 18.1 ns):

- `A_OUT_r → din → …`: the probe's own write bypass compare; the
  integrated design has no such path.
- `STATE → microcode registers`: the candidate lookup itself, from
  registers. Nine levels, of which 4.0 ns is the net from `STATE` (fan-out
  305, it now feeds two lookups). Register copies of `IR` / `STATE` for
  the lookups would take most of that.
- `index register → AAL sum → next value → next address`: the adder is
  5.5 ns in; the address-source selection behind it (`AddrBus`, per
  candidate) is nine levels. It decodes a 4-bit mode and special sequences
  for every candidate; one-hot source selects carried in `SUCC_TAB` (the
  way `XT_TAB` did it for the data buses) would flatten it.

And in the integrated design the interrupt lines reach the step-address
register through the core's next-status logic in one clk (`irq_s → nx_two →
NST → ea_r`, −2.3 in n2i's placement): the lines want to be held from one
core step to the next in fast mode (native mode must stay as it is, pin for
pin).

**Where this leaves the goal.** Not met. Six placements of the near-memory
design at 100 MHz lie between −0.4 and −2.3 ns on the step paths when the
placement is of the good kind, that is 49 to 45 MHz, and the placement is
not under control: one build to the next moves more than any single change
here has. What is in hand is real (the flat-memory design this started from
needed 26 ns): the broker is out of the way and proven, the core stands
alone at 55 MHz. What is still needed is about 1.5 ns in the core's loop and
a placement that repeats.

### 50 MHz: the integrated probe closes (2026-11-12)

Two more changes after rung 4a, both small, both from the reports above:

- The microcode lookups get their own copies of `IR` / `STATE` (`IR_m`,
  `STATE_m`, preserved): the net from `STATE` was 4 ns of the lookup.
- In fast mode with the near memory the interrupt lines the core sees are
  held from one core step to the next (`irq_h`, `nmi_h`, `abort_h`, loaded
  from the two-flop synchronisers at every core step). The core's next
  status hangs off them (a pending interrupt changes the next step's VPA)
  and the step registers off that; held, it is a step path. Native mode
  takes the lines as before, pin for pin with S6.

Lockstep bench and the whole broker suite (72 / 72) pass with both.

**Build n2j** (`a2mega_accel_probe_138b_n2`: PHY, broker with the near
memory, replica, `F65C816`, near memory, banks 00/01 and the ROM 01 image;
138B, 100 MHz, two clks per step, 0.5 ns setup uncertainty):

| | |
|---|---|
| setup violations | **0** |
| hold violations | 0 |
| worst setup slack | +0.012 ns (`IR → next address → nl_ok`) |
| Fmax of the 100 MHz clock | 100.06 MHz |
| step paths (two clks) | core → core +0.08, core → near address +0.02, near memory → core +0.02 |
| clock enable into the core | +0.88 |
| full decode (two clks) | +7.7 |
| broker → socket pads | +0.11 |
| size | 8,110 LUT, 1,178 FF, 142 block RAMs |

Provenance: sources = commit `ed8f71e6` plus the two changes above (the
commit that adds this entry); Gowin V1.9.12.01, GW5AST-LV138PG484AC1/I0
device version B; bitstream sha256 `65ee2c57e190ec56…6e5605` (a timing
instrument, never flashed).

**That is a 20 ns step: 50 MHz, against the AppleSqueezer's 48.** With the
fidelity rule intact: the core is cycle-exact by the lockstep bench, and the
broker's near memory changes wall time only.

What this result is and is not:

- It is one placement, with 0.01 ns to spare beyond the policy's 0.5 ns.
  The tool is deterministic (the same build again, with a different
  `Route_Maxfan`, is identical to the last digit), so "another roll" means
  a changed source, and changed sources have moved this design by more
  than a nanosecond tonight. The project rule for calling a clock closed
  (three rolls of the final source) is not met.
- The probe's power-up reset is a false path, and the socket's `d_f` data
  byte is constrained as the asynchronous crossing it is.
- It is the accelerator domain on an otherwise empty 138B. The
  accelerator-only build adds the control plane and, later, the DDR3 miss
  path, neither of which is in the step.
- 100 MHz is the number chosen for the PHY in §2d. The PHY's timing at
  100 MHz passes the socket bench; it has not been on hardware (S6 ran at
  108 MHz).

**Perturbed builds of that source** (probe-only changes that alter the
netlist and not the design; the committed files are as n2j):

| build | change | failing | worst slack | note |
|---|---|---|---|---|
| n2j | none | 0 | +0.012 | |
| n2k | `Route_Maxfan` 20 instead of 23 | 0 | +0.012 | identical to n2j: not a different placement |
| n2p2 | the loader stand-in steps by 3 | 0 | +0.012 | identical to n2j again |
| n2p1 | the configuration register powers up with another value | 0 | +0.001 | a different placement (core → core +0.35, enable +1.23) |
| n2p3 | … with a third value | 2 | −0.011 | a third placement; 11 ps short of the policy margin (raw slack +0.49 ns) |
| n2m104 | n2j's source at 104 MHz (52 MHz steps) | 74 | −0.86 on the step paths, −0.54 on one-clk paths | the step paths come out at 20.1 ns |

Three distinct placements at 100 MHz: two meet the constraint with the
0.5 ns margin, the third misses it by 0.011 ns. The 104 MHz build says the
same thing from the other side: asked for 19.2 ns, the tool reaches
20.1 ns. **The design sits at a 20 ns step with the policy margin, with
nothing to spare**: 50 MHz is reached but is not durable by the project's
three-roll rule, 49 MHz would be (the same three builds have 0.19 ns and
more at a 10.1 ns clk). Either is above the Squeezer.

The margin to make 50 MHz itself durable is the same list as before (the
address-source selection behind the index adder, the flags).

### Rung 5: the microcode from block RAM; 54 MHz steps at 108 MHz (2026-11-12)

The 50 MHz design sat on its limit on every front at once: the worst twenty
endpoints of n2j were spread over the next address, the flags, the register
file and the microcode, all within 0.2 ns of each other. A wider report
(`report_timing -max_paths 400 -max_common_paths 1`, now generated into the
probe's constraints) and the paths themselves showed two different things.

**1. Logic in front of late signals for no functional reason.** Each of
these is exact; where it rests on the microcode table the generator asserts
it.

- *The broker's tail behind the core's next address.* `ea_r` kept its value
  when the next step was an internal cycle aimed at I/O space, so a compare
  of the next address sat in front of 24 enables, eight levels after the
  address was known. Now `ea_r` always loads, `ea_k` follows the effective
  address in every clk with no enable (a step that repeats an address reads
  it there), and the cheap view is taken of `ea_r` itself (the only thing
  it is asked about a repeated address is one registered bit). The
  launch-clk write compare that fed `nl_ok` is made a clk later from
  registers, beside the one that was already there.
- *The flags.* The next `P` takes the ALU's carry and zero in its last
  level; the stock case statement had them six levels down.
- *The adder's carry in* was `CR | ~secOp[0]`, `CR` being the bit a shift
  moves out of the operand. No control word shifts and then adds, so it is
  the carry flag, and memory data no longer reaches the carry chain's
  first cell through two levels of logic.
- *The ALU result*: one result for both widths, the adder's sum ORed in
  last; each decimal digit formed for both values of its carry in.
- *The address generator's high byte*: `AAH` + index from registers alone,
  `DH` + index for both values of the low byte's carry. The stock form put
  that carry in front of the bank byte through `AB = D_IN + carry`
  (`ABSCtrl` 10), which no row of the microcode uses.
- *The RTL page carry* in the address function is a compare, not a sum.
- *The broker's step registers and the PHY.* `ea_r` and the next step's
  status reset on `run_c`, the registered view of the reset, and no longer
  hang off the PHY's fall event; the write registers load in every clk
  (they are used only in the clk after the write is decided), so the
  decision is on one register; the verify compare takes the card's byte
  from a register; the PHY's address is `ea_k`.
- *Native mode's interrupt lines* reached the core one clk before its step
  (`irq_c`, loaded at the fall event). With the near memory the core now
  sees the PH2-domain flops registered in every clk (`irq_e`, as `alt_q`
  is for the data byte): the same sample, two clks before the step. A
  mutation that delays it by a step is caught by the S6 comparison.

**2. The size.** The first build with only the broker's tail and the flags
changed (n2r) was *worse*: 67 failing endpoints, −0.9 ns, on paths the
changes had not touched. With a front that wide, any changed netlist moves
the placement by more than a few levels of logic gain. The microcode
lookups were 4,189 of the probe's 7,393 LUTs, with one register driving 802
loads: that was the thing to change.

**Rung 5.** With the two-clk step the core never steps in successive clks,
so `IR` and `STATE` are registers a whole clk before a step ends. The two
successor rows are therefore *read* from them in a synchronous memory in the
clk before the step ends (`F65C816_mrom`: the packed row table, two reads,
24 block RAMs), instead of looked up in LUTs; step 1 of the opcode on the
bus is still a lookup from the data (256 rows, in LUTs); the late decision
selects as before, and the registered row is the same. Built with
`F65C816_MCODE_ROM` defined (`F65C816_mcode_s`); the LUT form stays the
default and the reference. The module stops a simulation if it is stepped
in two successive clks, and the lockstep bench gained `+ce2` to run it.

This is rung 2a turned round: 2a took the microcode *out* of block RAM
because the block's clock-to-output sat at the head of every control path
of a one-clk step. Here the block is read a clk early and the
microinstruction register is still flops.

Microcode: 4,189 LUTs → 448. The probe at synthesis: 7,393 LUTs → 3,739,
142 block RAMs → 166. One more thing for the placement: the near memory's blocks sit in two
rows of block RAM 18 rows apart, and the read address (the core's latest
output) had one net to all of them; the core now gives it twice
(`NA_OUT_B`, its own gates), one copy per row.

**Builds** (138B, two clks per step, 0.5 ns setup uncertainty; all with the
constraints generated by `gen_sdc.py`):

| build | source | clk | failing | worst slack | Fmax of the clk |
|---|---|---|---|---|---|
| n2r | tail + flags only | 100 MHz | 67 | −0.906 | 92.6 |
| n2s | + rung 5, adder carry in | 100 MHz | 0 | +0.049 | 100.4 |
| n2s108 | the same | 108 MHz | 10 | −0.090 | 107.5 |
| n8a | + address generator, ALU result, step registers | 108 MHz | 10 | −0.128 | 106.5 |
| **n8b** | + interrupt lines, PHY address, RTL carry, second address copy (**the committed source**) | **108 MHz** | **0** | **+0.011** | **108.1** |
| n8b116 | the same | 116 MHz | 29 | −0.173 | 114.3 |

**That is an 18.5 ns step: 54 MHz, on the clock frequency the rest of the
machine already runs at.** The 116 MHz build says where the design
actually sits: asked for 17.2 ns, the tool reaches 17.5 ns (57 MHz), so at
108 MHz there is about 0.5 ns on the one-clk paths and 1 ns on the step
paths beyond the policy's margin, and at 100 MHz about 1.2 ns and 2.5 ns.

**Three placements of the committed source at each clock** (the probe's
configuration register powers up with another value: a different netlist,
the same design; Fmax shows they are different placements):

| | 100 MHz (50 MHz steps) | 108 MHz (54 MHz steps) |
|---|---|---|
| committed | 0 failing, +0.035, 100.2 MHz | 0 failing, +0.011, 108.1 MHz |
| perturbation 1 | 0 failing, +0.114, 101.2 MHz | 0 failing, +0.050, 108.3 MHz |
| perturbation 3 | 0 failing, +0.068, 100.4 MHz | 0 failing, +0.004, 108.0 MHz |

No setup or hold violation in any of the six. By the project's rule (three
rolls of the final source, 0.5 ns on every clock) both step rates are
closed in the probe. The worst slacks are small because the tool stops
when the constraint is met; the 116 MHz build is the measure of margin.

Step paths of n8b: core → core +0.59, core → near address +0.15, near
memory → core +0.12, core → step registers +0.56; clock enable into the
core +0.92; full decode (two clks) +4.1.

Provenance: sources = the commit that adds this entry; Gowin V1.9.12.01,
GW5AST-LV138PG484AC1/I0 device version B; bitstreams (timing instruments,
never flashed) sha256 `9462b1624e9614a9…73de360d` (`a2mega_accel_probe_138b_n8`, 108 MHz) and
`62d2c0c3b2cacec4…e105162c` (`a2mega_accel_probe_138b_n2`, 100 MHz); 4,428 logic cells (3,734 LUT and 694 ALU; it was 8,110), 1,226 FF, 166 block RAMs.

**Verification on the committed tree.**

- CPU lockstep bench, stock core against `F65C816`, every step compared:
  the test program (4.6 M steps) plain, with stalls, data-late,
  data-late with stalls;
  the ROM 01 boot plain, with interrupts, data-late with interrupts,
  data-late with interrupts and stalls (7 to 8 M steps, 3,915 IRQ, 485
  NMI). The same with the microcode in block RAM and both cores stepped
  every second clk (`+ce2`; ROM boot 7 M steps, 7,824 IRQ, 980 NMI).
- ALU and adder against the stock ones: 4,160,000 and 3,572,864 vectors,
  no mismatch.
- Broker suite: 72 / 72. The near-memory builds run the core with its
  microcode in block RAM. ROM 01 boot, 3 M steps: step hash
  `6012b76169ecc820` and the identical 128,393-write stream in every mode,
  as before; 96.9 % of local steps are two-clk steps, as before.
- Decode sweep: 869,952,896 vectors, no failure (the replica has a second
  decode instance for the cheap view).
- Fault injection, new logic only. Broker: 10 of 10 detected (the
  address split four ways, the launch-clk write, the write registers, the
  verify register, the reset view, the interrupt lines twice). Core, in
  the lockstep bench: 13 of 13 detected after the bench program gained
  an eighth workload (below); 7 of the first 10 were, before it.
- The testbench asserts the new timing rule in clks: the interrupt lines
  the core sees do not change in the two clks before a step.
- The three core mutations that went unseen were in logic no bench program
  reached: `BIT #imm` (the only instruction that loads Z alone), direct
  page,X in emulation mode with `DL` = 0, and RTL in emulation mode with
  the stack pointer at the top of page 1. `bench_all.s` has a mark 8 for
  them now (339 steps), and the same mutations are caught.

What this result is and is not:

- It is the probe: the accelerator domain on an otherwise empty 138B, its
  power-up reset a false path, never flashed. The accelerator-only build
  adds the control plane and the DDR3 miss path, neither in the step.
- At 108 MHz the PHY's timing is S6's, which has run on hardware. §2d
  chose 100 MHz for the PHY because the core needed it; it said the PLL
  would go to 108 if a rung found the 1.5 ns, and this is that rung.
- Block RAM: the probe uses 166 of 340. The microcode takes 24 and could
  take 12 as a two-port memory, or fewer with the constant columns packed
  out; nothing here needed it.
- Not rebuilt: the decode-ahead probes (`a2mega_accel_probe_138b`, `_s2`,
  `_w20`, `_c32`, `_r3`) and the core-only probes. Their sources are the
  same files; the suite runs their configurations.
- Still open from before: the bench does not exercise the write of a step
  completing in the clk /RESET is seen; the ROM 3 image (256 KB) has not
  been built with the near memory; nothing invalidates the near memory if
  the far memory is written behind the broker.

## 5. Questions for ed

1. Rung 3 changes the step count per instruction. The scoping doc's
   slowdown rules (native pacing in disk windows, CYAREG) assume the core
   can be made cycle-faithful on demand; a data-late core needs a
   "faithful" mode or the pacing comes from the broker. Which?
2. Memory-side rungs (mux select pre-decode, 16-bit reads) belong to the
   S7 broker, not the core. Fine to prototype them inside the probe?
3. The near memory (cache) changes what "50 MHz" means: a hit is a
   two-clk step, a miss about three clks more. Is the goal the step rate
   (the Squeezer's own kind of number) or a measured benchmark against one?
4. May the S7 PHY issue a clk later than S6's? It would put a register at
   the pads (the last one-clk paths at 36 MHz); it needs the S6 hardware
   sweep to say the socket timing has the room.
5. ROM 01 hardware: the vector-pull behaviour (`/VP`) the replica assumes
   has only been seen in simulation.
6. ~~The accelerator's clock: 108 or 100 MHz for the accelerator-only
   build?~~ **Answered 2026-11-12: 108 MHz** (§2d). The step is 54 MHz and
   the PHY is S6's, already on hardware (which is in fact 110 MHz: see the
   correction in §2d). In the broker bench the socket
   timing of the 108 MHz near-memory builds is the same as the S6
   configuration's, to the tenth of a nanosecond (tADS 65.6, tBAS 66.6,
   tAH 56.3, tBH 47.0, tMDS 56.3, tDHW 56.3 ns), in native and in fast
   mode.
