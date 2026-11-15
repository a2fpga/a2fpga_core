# S7 — Accelerating the in-socket 65C816 (scoping)

Status: scoping, 2026-09-13. Follows S6 (`gs_socket_65816_scoping.md` §8b:
auto-arm, reset sequencing). Sections 0–8 are that scoping as written; the
numbers in them are from the S4–S6 builds and the bench. **2026-11-11: S7a
(memory-map replica) and S7b (broker) exist and pass in simulation, with the
reset rule as a gateware module — §9, which also records every departure
from sections 2–7.** **2026-11-12: an accelerator-only board build exists
(§10.4); it ran on a ROM 01 machine the same day, and the first defect
that showed is fixed in the source (§10.5); two expansion banks in block
RAM as a stopgap for S7d (§10.6), then S7d itself on the DDR3 (§10.7), built
at 105 MHz.** **2026-11-13: S7d ran on the machine. Every test of the
benchmark is 12 to 14 times the machine's speed (the program's average
33 MHz); the run found a defect in the near memory's empty entry, fixed,
flashed and run the same day (§10.7). 2026-11-14: the near memory as
16-byte lines with a two-clk step in every bank, built, flashed 08:53 and
run: card memory verifies, the benchmark's average 44.02 MHz (33.34
before), the sieve 49.65 and the sort 48.72 (§10.7).** The same day, built and
not flashed: a copy of the Mega II's RAM in the DDR3 with a switch for
reads of it; five placements of ten clean at 105 MHz, which is not
closure (§10.7).

## 0. Summary

S2–S6 put a 65C816 core in the IIgs CPU socket and made it a transparent
replacement: the core is clocked by PHI2 from the socket pin, one core step
per motherboard cycle, 2.86 MHz on fast cycles and 1 MHz on Mega II cycles.
S7 makes it an accelerator that is faster than every card that has been sold
for the machine.

- **Target: ≥ 1.5× the AppleSqueezer GS, i.e. ≈ 9–10× a stock 2.8 MHz IIgs**
  on the classic Applesoft benchmarks, and GS/OS, games and disk I/O working
  as they do behind a TransWarp.
- **Means: the core runs on its own clock (28 MHz planned, 40 MHz ceiling)
  from memory on the card, and the socket is used only for I/O, the Mega II
  banks and video shadowing.** The speed comes from owning the memory, not
  from the clock. That is what the benchmark table says about the existing
  cards.
- **Fits the 138B**: banks $00/$01 and a ROM 01 image are 256 KB of the
  418 KB of block RAM that is free today; expansion RAM comes from the DDR3.
- **The work is the memory-map replica** (language card, ALTZP, RAMRD/RAMWRT,
  80STORE, shadowing, ROM select) and a two-clock-domain bridge in the socket
  PHY. The MiSTer IIgs core we already borrowed the CPU from has both as
  separable, unit-tested modules.

## 1. What the benchmarks say

Times in seconds (ed, 2026-09-13), speedup = stock ÷ card:

| CPU | clock | Sieve | String | Float 1 | Float 2 | Fibonacci | Integer |
|---|---|---|---|---|---|---|---|
| Stock | 2.8 | 410 | 1151.2 | 472 | 1535 | 2006 | 1553.4 |
| TWGS | 15 | 99 (4.1×) | 270 (4.3×) | 92 (5.1×) | 317 (4.8×) | 605 (3.3×) | 307 (5.1×) |
| TWGS | 13.75 | 108 | 292 | 87 | 394 | 634 | 330 |
| TWGS | 12.5 | 117 | 304 | 111 | 382 | 645 | 347 |
| ZipGS | 16 | 98 (4.2×) | 259 (4.4×) | 123 (3.8×) | 395 (3.9×) | 507 (4.0×) | 420 (3.7×) |
| ZipGS | 15 | 99 | 262 | 128 | 415 | 523 | 431 |
| ZipGS | 14 | 110 | 282 | 135 | 432 | 548 | 443 |
| AppleSqueezer GS | | 69 (5.9×) | 193 (6.0×) | 89 (5.3×) | 291 (5.3×) | 339 (5.9×) | 263 (5.9×) |

Three facts fall out:

1. A 15 MHz CPU with perfect memory would be 15 ÷ 2.8 = 5.4× stock. TransWarp
   and Zip reach 3.3–5.1× at 15–16 MHz. Their caches are write-through and
   small (8–32 KB), so **every store and every miss costs a full 350 ns
   motherboard cycle** — 5–6 of their own cycles. Fibonacci, the most
   stack- and store-heavy test, is where they lose most (3.3×).
2. The AppleSqueezer is a flat 5.9× on every test, which is the signature of
   a core (≈ 16.5 MHz equivalent) whose reads *and writes* never leave the
   card except for I/O and shadowed video. **It owns banks $00/$01, the ROM
   and its own 8 MB of expansion.**
3. Nobody accelerates $E0/$E1 or I/O: those are Mega II cycles at 1 MHz for
   every card, ours included. Code that draws SHR by writing $E1/2000 directly
   is bus-bound on every accelerator.

So the design target is Squeezer's memory model with a faster core.

## 2. Architecture

### 2.1 Two clock domains, one socket

Today (`hdl/twgs/gs_socket_phy.sv`): the core's clock **is** PHI2 (inverted
pin, CE = 1); the 110 MHz `clk_gs` PLL clock only runs the pin sequencer that
places address/data inside each PHI2 cycle.

S7: the core runs on **`clk_core`**, and the PHY becomes a **bus-cycle
broker** between the core and the socket:

- **Local hit** (see §2.2): the memory answers in one `clk_core` cycle; the
  core never waits.
- **External cycle** (I/O, $E0/$E1, shadow write, slot space): the broker
  stalls the core (CE low or RDY_IN low — the core already honours RDY_IN),
  waits for the next PHI2 cycle boundary, performs exactly one socket cycle
  with the timing the PHY already produces, then releases the core with the
  data. Stretched Mega II cycles and the FPI's RDY are followed as today.
- **Every PHI2 cycle still shows a legal 65816 cycle on the socket.** While
  the core is busy locally the socket presents an *internal* cycle: VDA = VPA
  = 0, the previous address repeated, R/W high, data bus released. This is
  the behaviour the phantom-`$C028` fix (S5) already gave the PHY, and it is
  what a real 65816 does during its own internal cycles, so the FPI is
  satisfied. E and M/X keep reflecting the core's real mode.
- Interrupts, NMI, ABORT, /RES and RDY are sampled per PHI2 cycle by the PHY
  (as now) and crossed into `clk_core` with two-flop synchronisers; the core
  sees them at instruction boundaries as before.

**Clock choice.** Simplest: run the core *in the `clk_gs` (110 MHz) domain
with a clock enable* every 4th cycle → 27.5 MHz effective, a single clock
domain with the pin sequencer, no CDC inside the PHY, and the speed step is a
CE ratio (÷4 = 27.5, ÷8 = 13.75, ÷16 = 6.9 MHz, native = PHI2-paced). The
alternative, a dedicated PLL output, buys nothing until the core needs more
than 27.5 MHz. Ceiling: the core's PHI2 domain closes at 40.4 MHz in builds
13/14 with no constraint pressure; S2 synthesis estimated ~52 MHz single-
cycle. Plan for 27.5 MHz; treat 40 as the stretch.

### 2.2 Memory of record on the card

| region | where | policy |
|---|---|---|
| banks $00/$01 (128 KB) | BSRAM, 64 blocks | reads local; writes local **and** forwarded to the bus when the address is in a shadowed video range (§2.4) |
| ROM ($FE/$FF on ROM 01 = 128 KB; $FC–$FF on ROM 3 = 256 KB) | BSRAM, 64 blocks for ROM 01 (ROM 3: 128 blocks, or DDR3 + cache) | read-only local; loaded once from the motherboard at bring-up (§2.6) |
| expansion banks $02–$7F (up to 8 MB) | DDR3 behind a BSRAM cache (16–32 blocks) | local; nothing on the motherboard is involved (the machine's own memory card, if any, is bypassed) |
| $E0/$E1 (Mega II slow RAM) | motherboard | every access is a socket cycle |
| I/O $C000–$C0FF, slot ROM $C100–$CFFF that is not internal, $C800 space of slot cards | motherboard | every access is a socket cycle; the soft-switch writes are *also* decoded locally to keep the map replica current |
| language-card RAM in $00/$01 $D000–$FFFF | part of banks $00/$01 above | local |

Why banks $00/$01 can be owned outright: on the IIgs nothing but the CPU
reaches fast RAM — the Mega II cannot, video shadowing is performed by the
FPI on the CPU's *write cycles*, and slot DMA into fast RAM is exotic
(the TransWarp has exactly the same blind spot and nobody notices). The one
thing we must preserve is the shadowing side effect, hence §2.4.

### 2.3 The memory-map replica

Everything in §2.2 depends on knowing, for each core access, which physical
region the machine would have used. That is the FPI's and the Mega II's
decode, driven by soft switches the core itself writes. The replica tracks
them from the core's own bus cycles (they all pass through the broker):

| state | set by | matters for |
|---|---|---|
| LCRAM / LCBNK2 / RDROM / LC write-enable | reads of $C080–$C08F (the two-read protocol) | $D000–$FFFF in $00/$01: ROM image vs LC RAM bank 1/2 |
| ALTZP | $C008/$C009 | zero page, stack and LC RAM: main vs aux (bank 0 vs 1) |
| RAMRD / RAMWRT | $C002–$C005 | $0200–$BFFF reads/writes: bank 0 vs 1 |
| 80STORE, PAGE2, HIRES | $C000/$C001, $C054/$C055, $C056/$C057 | text/hires page aux switching overrides RAMRD/RAMWRT |
| INTCXROM, SLOTC3ROM, INTC8ROM | $C006/$C007, $C00A/$C00B, $CFFF | $C100–$CFFF: internal ROM (local) vs slot card (bus) |
| SHADOW ($C035) | write | which video ranges of $00/$01 must be forwarded (bits are inhibits: text1, hgr1, hgr2, SHR, aux hgr, text2 on ROM 3, IOLC) |
| CYAREG ($C036) | write | bit 7 fast/slow (native pacing), bit 4 shadow-all-banks, bits 0–3 disk-slot motor detectors (slowdown, §2.5) |
| STATEREG ($C068) | write | all of the above bits in one register (GS/OS uses it) |
| ROMBANK ($C028, ROM 01) | write | which half of the ROM image |

`rtl/mmu.sv` in the MiSTer Apple IIgs core is exactly this function: pure
combinational, `{bank, addr, we}` + register state → physical region and chip
enables, with a C++ golden model and a sweep test (`vsim/mmu_tb.cpp`). It is
GPL-3 like the CPU core we already ship. Port it, keep its tests, and add
our two outputs: *local?* and *forward-write?*.

### 2.4 Write forwarding (shadowing)

For a write into banks $00/$01 the replica decides three things:

1. update the local copy (always, unless the address is I/O);
2. **forward to the socket** if the address is in a range the machine shadows
   into $E0/$E1 and the corresponding SHADOW inhibit bit is clear — text page
   1 ($0400–$07FF), hires 1/2 ($2000–$5FFF), double-hires (bank 1 $2000–$5FFF),
   SHR (bank 1 $2000–$9FFF), text page 2 on ROM 3 — or if it is I/O or
   language-card-inhibited space (SHADOW bit 6);
3. otherwise stay local.

The forwarded write is an ordinary bank-$00/$01 write on the socket, so the
FPI writes the motherboard's fast RAM *and* performs its shadow copy exactly
as it would for a real CPU; the Mega II's display stays right and the
motherboard's copy of those pages stays coherent. Forwarded writes are posted
(the core continues; the broker owns a one-deep write buffer and stalls only
if a second external cycle arrives before the first completes), which hides
most of their cost behind local work.

### 2.5 Speed control and slowdown rules

Every accelerator has to drop to native speed around things that count
cycles. The rules the existing cards use, which we adopt:

- **CYAREG bit 7 = 0 (the machine's own "slow" mode)**: run PHI2-paced,
  i.e. today's S6 behaviour. The Control Panel's Normal/Fast setting keeps
  meaning what it means.
- **Disk slots**: while a slot's motor-detect bit in CYAREG is set and its
  $C0n0 I/O range has been touched, run at native for ≈ 300 ms after the
  last touch (the FPI does the same for its 2.8 → 1 MHz step). Configurable
  per slot like the TransWarp's slot table.
- **Speaker and timing loops**: the Zip/TransWarp approach — slow down on
  $C030 access for a few ms — is available and configurable; default on.
- **Interrupts**: TransWarp's optional "slow on interrupt" is advisory; not
  needed by GS/OS. Off by default.

Software-visible control: emulate the **ZipGS $C058–$C05F unlock protocol**
and the **TransWarp $BC0000 latch**, so existing control panels, CDAs and
games can detect an accelerator and set its speed. Both exist as small
modules in the MiSTer core (`zipgs_regs.sv`, `twgs_regs.sv`, verified
against KEGS/GSplus and the TWGS ROM). The card's own menu/telnet gets a
speed selector (native, 6.9, 13.75, 27.5 MHz) and cache/forwarding toggles,
which is also the bring-up ladder.

### 2.6 Bring-up sequence (adds to S6)

S6's sequencing is unchanged: hold, release with the socket off, arm 20 ms
later, never inside the ROM 01's re-assert window. S7 adds, after arming and
before the core leaves reset:

1. Read the ROM image through the socket into BSRAM at native speed (128 KB
   at 2.8 MHz ≈ 50 ms; done once per power-up, or cached in the ESP32's flash
   and verified against a few probe reads).
2. Banks $00/$01 start empty; RAM is not assumed to hold anything at power-on.
   (Warm resets keep the local copy, as the machine keeps its RAM.)
3. Soft-switch state starts from the reset defaults the FPI/Mega II apply;
   the replica mirrors them.

### 2.7 A card-only opportunity (noted, not S7)

Our own emulated slot cards (HDD block device, Disk II, Uthernet, Mockingboard)
live in the same FPGA as the core. Their I/O and ROM space could be served
inside the chip with no socket cycle at all, and the HDD block transfer
could run at core speed. No other accelerator can do that. It changes the
$C0n0/$Cn00 decode for our slots only and is a natural S8.

## 3. Performance model

Per core cycle at 27.5 MHz (36 ns): local hit = 1 cycle; forwarded write =
posted, usually free; external cycle = wait for a PHI2 slot ≈ 350 ns fast /
980 ns slow ≈ 10 / 27 core cycles.

| workload | external fraction | expected speedup vs stock |
|---|---|---|
| Applesoft benchmarks (bank 0 + ROM; text writes forwarded) | ≈ 1–3 % | **≈ 9–10×** (Squeezer 5.9×, TWGS 4–5×) |
| GS/OS desktop (fast RAM + SHR writes via bank 1 shadow) | 5–15 % | 4–7× |
| SHR code writing $E1 directly | 30–60 % | 1.5–2.5×, same as every card |
| disk I/O windows | native by rule | 1× while active |

At the 40 MHz ceiling the compute-bound figure becomes ≈ 14×. The
benchmark set in §1 is the acceptance test: **all six under Squeezer's
times ÷ 1.5**.

## 4. Resources and timing (138B)

| item | BSRAM blocks | notes |
|---|---|---|
| build 14 today | 131 / 340 | socket, event log, HDD, video, DOC |
| banks $00/$01 | 64 | 2 KB per 18 Kbit block at byte width |
| ROM 01 image | 64 | ROM 3: 128, or DDR3 + cache |
| expansion cache | 16–32 | 32–64 KB direct-mapped, write-back to DDR3 |
| **total** | **275–291 / 340** | ROM 3 in BSRAM: 339–355 → ROM 3 goes to DDR3 |

Logic: the replica and broker are small (the MiSTer MMU is 400 lines of
combinational decode); the 64:1 and 128:1 BSRAM read muxes are the widest
structures and are trivial at 27.5 MHz. Timing risk is the usual 138B one:
the DP block's knife edge (clk100/clk_sym/clk_pix at +0.01…+0.3 ns); the S7
logic stays in `clk_gs`/`clk_core` and does not touch it. Socket builds take
21–41 min (S4 record); expect the same.

DDR3: 512 MB on the 138K SOM, seven ports already arbitrated; one more
client for the expansion backing store.

## 5. Risks and open questions

1. **Fidelity of the replica.** A wrong decode is a crash, not a slowdown.
   Mitigations: the MiSTer golden-model sweep; a "native" mode that bypasses
   the local memory entirely (today's S6 behaviour) selectable at runtime; a
   "verify" mode for the bench that performs every local read *also* on the
   bus and logs mismatches into the event log (the trace ring exists).
2. **ROM 01 vs ROM 3.** Different ROM size, TEXT2 shadow bit, $C028 ROMBANK,
   a few soft-switch details. Scope S7 to ROM 01 (the bench machine) with
   the ROM 3 differences kept as parameters, not forgotten.
3. **Coherency with anything else that touches fast RAM.** Slot DMA cards
   (rare); the a2mega's own emulated cards do not DMA. Document it, provide
   the native-mode escape.
4. **The machine's own expansion card.** If one is fitted, GS/OS will size
   memory from *our* responses, and the motherboard card is simply idle.
   Fine, but the sizing must be consistent (a menu setting: 1/4/8 MB).
5. **Reset and the 10 ms window** (S6): unchanged; the core is still armed
   20 ms after the edge. The ROM copy (§2.6) happens after arming.
6. **Timing-sensitive software** beyond disks: the standard accelerator
   slowdown set (§2.5) has covered the TWGS/Zip installed base for 35 years;
   we ship the same knobs.
7. **ADB micro/SYNC timing**: the ROM's first ADB exchange happens at native
   speed on the bus regardless; no change.

## 6. Verification plan

1. **Replica unit tests**: port `mmu.sv` + its C++ golden model; extend the
   model with *local?* / *forward?* and sweep all soft-switch combinations
   over both banks. Pure simulation, no hardware.
2. **Broker simulation**: the existing PHY bench against the FPI clock model
   (`clock_divider.v`) with the core on `clk_gs`/CE; assertions that every
   PHI2 cycle carries a legal cycle and that external cycles meet the S2
   timing rules; posted-write ordering.
3. **Bench ladder** (each step a runtime toggle, native mode always one
   command away):
   1. native mode = S6 (regression);
   2. local ROM reads only, RAM still on the bus;
   3. banks $00/$01 local with forwarding, still PHI2-paced (verify mode
      compares against the bus);
   4. speed steps 6.9 → 13.75 → 27.5 MHz;
   5. expansion RAM from DDR3;
   6. the six benchmarks, GS/OS boot from the HDD device, a disk-image boot
      through the Disk II device, a few timing-sensitive games; Zip and
      TWGS control panels.

## 7. Work plan

| step | content | deliverable |
|---|---|---|
| S7a | memory-map replica (port MiSTer `mmu.sv` + tests, add local/forward outputs) | sim-tested module, PR |
| S7b | broker: core on `clk_gs`/CE, external-cycle stall/resume, internal cycles on the socket, posted write | sim against the FPI model; bench step 1–2 at native pacing |
| S7c | banks $00/$01 + ROM image in BSRAM, write forwarding, verify mode, ROM copy at arm | bench steps 2–3 at native pacing, then speed steps |
| S7d | expansion RAM: DDR3 client + BSRAM cache | bench step 5 |
| S7e | speed control: CYAREG pacing, slot/speaker slowdown, Zip + TWGS register models, menu/telnet | compatibility runs |
| S7f | benchmarks and acceptance | test_log rows, numbers against §1 |

Each step is a PR against `epic-merge-prep` on top of S6, per the project
rule; S7a and S7b can proceed in parallel and neither needs the bench.

## 8. Questions for ed

1. Speed steps to expose (proposal: native, 6.9, 13.75, 27.5 MHz; 40 as a
   bench-only experiment).
2. ROM 3 in scope for S7 or parameterised only?
3. Expansion RAM default size (proposal 8 MB) and whether to hide the
   motherboard's memory card entirely.
4. Software interface: Zip protocol, TransWarp latch, both, or only our own
   menu? (Proposal: both models, they are small and existing software expects
   one of them.)
5. Is the "serve our own slot cards inside the chip" S8 worth moving up —
   it is the one thing that makes disk-bound work faster than any card.

## 9. S7a + S7b in simulation, and the reset rule (2026-11-11)

Simulation only: nothing here is in a `.gprj`, no board build was run, nothing
was flashed. §9.6 lists what is not done.

### 9.1 What exists

| piece | path (under `boards/a2mega/hdl/twgs/`) | what it is |
|---|---|---|
| decode | `gs_mmu_decode.sv` | the MiSTer `rtl/mmu.sv` (GPL-3 header kept), function unchanged, plus `is_local`, `forward_write`, `local_we`, `region`, the RAM / ROM-image address |
| replica | `gs_mmu_replica.sv` | soft-switch tracker fed by completed socket cycles + the decode |
| broker | `gs_accel_broker.sv` | core on a clock enable in the PHY's clock domain; local / socket / posted-write / idle cycles; native mode |
| arm sequencer | `gs_socket_arm_seq.sv` | the S6 arm rule timed from the last release of /RESET (§9.5) |
| golden model | `sim/mmu/iigs_mmu_model.h` | port of the MiSTer `vsim/mmu_tb.cpp` model + the two new answers + a tracker model + a whole-machine memory model |
| replica tests | `sim/mmu/run_mmu_replica_sim.sh` | decode sweep and tracker tests |
| broker bench | `sim/broker/run_gs_broker_sim.sh`, `tb_gs_broker.sv`, `broker_test.s` | program suite and ROM 01 end-to-end suite |
| arm bench | `sim/arm/run_gs_arm_seq_sim.sh`, `tb_gs_arm_seq.sv` | reset-rule cases at real time scale |

`gs_socket_phy.sv`, `gs_socket_ctl.sv`, both CPU cores and the ESP32
firmware are unchanged. The broker takes the core through its port list;
the bench runs the stock `P65C816` and the restructured `F65C816` in it.

### 9.2 Replica (S7a)

The decode keeps every MiSTer output under its own name, so the MiSTer golden
model still checks them, and adds the accelerator's answers. The tracker
never looks at the core's local accesses: it is fed only the socket cycles
that completed (address, direction, write data), which are exactly the
cycles the FPI and the Mega II saw, so its state is a function of what the
motherboard saw. That works because every switch that moves the map is in
I/O space and I/O space is never local.

Sweep (`run_mmu_replica_sim.sh`, 71 s): **869 952 896 decode vectors, 0
failures** — all 2^18 combinations of the nine IIe / language-card switches,
the seven SHADOW bits, the bank latch and the all-banks shadow bit, over
banks 00, 01, 02, 03, 7E, 7F, 80, E0, E1, FC–FF and 53 boundary addresses,
read and write, for ROM 01 and again for ROM 3; the slot space against all
256 SLTROMSEL values; every expansion bank against every backed size; 6 M
random vectors. Tracker: 97 directed facts (the language-card protocol,
STATEREG, ROMBANK, INTC8ROM, the IOLC inhibit, all-banks shadow) checked on
the RTL and on the golden model, and 3 M random bus cycles with the full
state and a decode compared after each, for ROM 01 and for ROM 3:
**5 999 973 checks each, 0 failures**. Mutated RTL fails both (checked).

ROM 3 differences carried as the `ROM3` parameter (`rom_select` in the
decode): text page 2 shadows (SHADOW bit 5), banks FC/FD are ROM, `$C028`
is not a ROMBANK toggle.

### 9.3 Broker (S7b)

The core, the broker, the replica and the PHY's pin sequencer share one
clock. A core step is `STEP_CLKS` clocks (parameter, default 4; the local
memory is strobed `ADDR_CLKS` clocks into the step, default 1, and its data
is taken at the end; 2 clocks per step is the minimum and is what the
100 MHz runs use). Per step the replica classifies the access:

- **local**: served by the card's memory; the socket shows an idle cycle;
- **socket**: the core is held, the PHY runs one cycle with its S2–S6
  timing, the core steps on the PHI2 fall that completes it;
- **posted write** (`forward_write`): stored locally at once and queued in
  the one-deep buffer; it always goes out before any later socket cycle, and
  a second forwarded write waits for the buffer;
- **native mode** (`native_i`, runtime): every step is a socket cycle, one
  per PHI2 cycle.

Bench (`run_gs_broker_sim.sh`): the S2–S6 socket bench (FPI PHI2 model,
level-shifter delays, the W65C816S timing checks) with the golden machine
model behind the socket, a reference core stepped in lockstep on a second,
ideal machine, and a queue of the socket cycles the program is owed, derived
from the reference side with the golden decode. Every PHI2 cycle must be the
head of that queue or an idle read of the park address; every byte handed to
the core must be the ideal machine's; with nothing outstanding the
motherboard model's Mega II RAM, I/O registers and switches must equal the
ideal machine's; at the end the card's RAM must equal the ideal machine's.
In native mode an S6 PHY and PHI2-clocked core run beside the design on the
same socket inputs and all card-driven pins are compared every clock.

**Test ROM** (`broker_test.s`; 60 000 core steps per run, 120 000 in the
mode-switching runs; every run has an RDY stall every 311 socket cycles and
one BE + RDY pause; all but the four equality runs raise /IRQ twice). 21
runs, all pass:

| runs | clock, clks per step | what |
|---|---|---|
| native, paced | 108 MHz | every step a socket cycle: 60 001 steps = 60 001 socket cycles, 0 idle; 2 436 216 clks of pin comparison with S6, 0 differences; paced: verify count 0 |
| fast | 108 MHz, 4 | 60 002 steps on 6 089 PHI2 cycles: 851 socket cycles for the core, 478 posted writes, 4 703 idle; 5 901 clks spent waiting for the write buffer |
| fast, 1 MHz FPI (`+noturbo`) | 108 MHz, 4 | passes; the per-PHI2 interrupt sample fails here (§9.4 item 3) |
| toggle (paced ↔ fast at pseudo-random points), also with expansion + local slot firmware | 108 MHz, 4 | 120 005 steps, pass |
| fast with 2 expansion banks; with 1 of the machine's 4; with `cxrom_local` | 108 MHz, 4 | pass |
| warm reset (/RES for 12 cycles, half way) in native, fast, toggle | 108 MHz, 4 | pass; native releases with RDY low; 0 posted writes dropped |
| `F65C816` in fast and in native | 108 MHz, 4 | pass (native: pins identical to S6 with the stock core) |
| native, fast, toggle | 100 MHz, 2 | pass; fast: 60 007 steps on 3 734 PHI2 cycles |

The same program without interrupts in native, paced, fast (108 MHz / 4) and
fast (100 MHz / 2): the four runs end at the same point (step hash
`a81f325bc9229f39` over all 60 000 steps) and put the identical 900 writes
to I/O, Mega II and shadowed ranges on the socket, in the same order. Time
for those 60 000 steps: 22.530 ms native, 3.612 ms fast at 108 / 4 (16.6 MHz
average step rate, 6.2×), 2.833 ms at 100 / 2 (21.2 MHz, 8.0×). The walk is
I/O-heavy by design; a local step is 27 MHz and 50 MHz.

**ROM 01 end to end** (`ROM=<boot1.rom>`, 3 000 000 core steps, six runs:
native, paced, fast, fast with `cxrom_local`, fast at 100 MHz / 2, fast with
`F65C816`). All six reach the same point — step hash `6012b76169ecc820`,
1 064 distinct opcode addresses, last fetches `FF:A577`–`FF:A585` — and
their write streams to I/O, Mega II and shadowed ranges are byte-identical
files of 128 393 writes. Native: 3 000 001 socket cycles, 167 299 977 clks
of pin comparison with S6, 0 differences. Paced: verify count 0, i.e. over
the whole run every byte the card's memory returned was the byte the
motherboard model returned on the socket. Fast (108 / 4): 2 315 837 local
steps, 191 653 socket cycles for the core, 81 872 posted writes, 286 586
idle cycles; 486.9 ms against 1 549.2 ms native (3.2×; 460.6 ms at
100 / 2). That stretch of the ROM is bound by the socket, not the core: it
draws the text screen (81 872 shadowed text-page writes, each a sync cycle
of about 1 µs; the core waited 6.1 M clks = 56.6 ms for the write buffer)
and does 44 410 I/O writes. How far the ROM gets is set by the bench machine
(§9.6), not by the design.

**Socket timing** (limits: 4 MHz-grade W65C816S, tADS/tBAS ≤ 75 ns, tAH/tBH/
tDHW ≥ 20 ns, tMDS ≤ 70 ns), worst case over all runs:

| PHY clock | tADS max | tBAS max | tAH min | tBH min | tMDS max | tDHW min | read release |
|---|---|---|---|---|---|---|---|
| 108 MHz (S6 bench today: 65.5 / 66.5 / 56.3 / 47.1 / 56.3 / 56.3 / 57.3) | 65.6 | 66.6 | 56.3 | 47.0 | 56.3 | 56.3 | 57.3 |
| 100 MHz | 70.0 | 71.0 | 60.0 | 50.0 | 60.0 | 60.0 | 61.0 |

At 100 MHz the address is 5 ns inside the 75 ns limit with `OUT_DELAY` = 2.
The broker's outputs are registers in the PHY's own clock, so `OUT_DELAY` = 1
is open at 100 MHz (one clock earlier); not tried.

**Native-mode regression** (`sim/run_gs_socket_sim.sh`, unchanged files):
program mode PASS (6 062 socket cycles), ROM mode PASS (200 000 cycles).

**Does the bench notice?** Eight deliberate faults in the broker, one at a
time: socket cycle allowed to overtake the posted write; idle cycles
repeating the previous address; the forwarded write not stored locally; no
internal-cycle substitution; RDY ignored; a second write accepted into the
full buffer; the native request presented late; per-PHI2 interrupt sample in
fast mode. All eight fail the bench (the last one in the 1 MHz FPI run).

### 9.4 Departures from sections 2–7, and readings chosen

1. **Idle cycles park on a ROM read** (`FF:0000`), not "the previous address
   repeated" (§2.1). Repeating the previous address after an I/O or slot
   access repeats its side effects for as long as the core stays local
   (speaker, keyboard strobe, IWM data, the language-card two-read protocol).
   A bank-FF read is a fast cycle with no effect anywhere.
2. **Internal cycles** (VDA = VPA = 0) reach the socket in fast mode only
   when their address is in I/O or slot space, and then exactly as S6 shows
   them (aimed at `$C0xx`: the previous step's address repeated as a read —
   the broker does that substitution itself, the PHY's own "previous
   address" would be the park address). Elsewhere they cost a step and no
   socket cycle.
3. **Interrupt lines in fast mode use two-flop synchronisers**, not the
   once-per-PHI2 sample of §2.1. With the per-cycle sample the core sees
   /IRQ low for up to a whole PHI2 cycle after the handler's acknowledging
   write released it, reaches RTI and takes the interrupt again: the bench
   at 1 MHz FPI speed counts 4 handler entries for 2 interrupts with that
   change put back. Native mode keeps the at-the-fall sample (S6).
4. **Native mode is two switches.** `native_i` is the pacing (every step a
   PHI2-paced socket cycle, pin-identical to S6). `mem_bypass_i` chooses the
   data source in native mode: 1 = everything from the socket (S6; writes are
   still copied into the card's memory), 0 = the card's memory stays the
   memory of record (§6.3 step 3, and what §2.5's slowdowns need). Reason: a
   pure-S6 native mode entered after fast mode has run would read the
   motherboard's stale copy of banks 00/01. Paced ↔ fast can be switched at
   any step in either direction (bench: switched at pseudo-random points);
   `mem_bypass_i` may be set only while fast mode has not run since power-up.
   The verify comparison (§5 risk 1) is built in for the paced mode and is
   meaningful under the same condition.
5. **§2.4 "or if it is I/O or language-card-inhibited space".** I/O is not a
   forwarded write, it is a socket cycle. Language-card RAM writes are local
   only: the machine does not copy the language card into E0/E1. With SHADOW
   bit 6 set, `$C000–$FFFF` of banks 00/01 is plain local RAM.
6. **`$C071–$C07F` of bank 00 reads from the ROM image.** It is the FPI's
   interrupt-dispatch ROM, not I/O (MiSTer: "IRQ dispatch ROM", a fast cycle
   in its clock model; bench G27 saw the BRK vector lead to `$C074`).
7. **Slot space `$C100–$CFFF` is a socket cycle by default**
   (`cxrom_local_i` = 0); §2.2 has internal firmware local. With the switch
   set, pages the replica knows to be internal (INTCXROM, the slot's
   SLTROMSEL bit, SLOTC3ROM, INTC8ROM — all tracked) are read from the image,
   except `$C3xx` and `$CFFF`, which always go out because the Mega II and
   the slot cards change state on them, and except writes. Why off by
   default: the internal-versus-slot rule cannot be checked against a
   reference here (MiSTer has no slot cards and uses SLTROMSEL alone; the
   machine's reset value of SLTROMSEL and its slot-3 rule are not confirmed),
   a wrong "internal" is a crash, and those pages are not hot. Both settings
   pass the bench, including the ROM 01 boot.
8. **ROMBANK** (§2.3 "write; which half of the ROM image"): tracked as a
   toggle on ANY access to `$C028` on ROM 01 (bench G21) and through
   STATEREG bit 1. While it is set the bank-00/01 ROM windows are socket
   cycles: the motherboard decides which half appears. Banks FE/FF stay local.
9. **Expansion banks** are local only below `02 + exp_banks_i`; the rest go
   to the socket (§2.2 bypasses the machine's memory card for all of 02–7F).
   No DDR3 or cache was built (S7d); the bench backs up to 16 banks with a
   behavioural array.
10. **Soft switches `$C000–$C00B` answer in every bank where the address
    decodes as I/O.** MiSTer restricts them to banks 00/E0; the machine has
    one I/O space. HIRES is cleared by reset. Reset values otherwise follow
    MiSTer (SHADOW `$08`, bank latch set, SLTROMSEL 0, CYAREG `$80`; CYAREG
    bit 7 is tracked but not used yet — the S2 bench FPI starts at 1 MHz).
    A cycle that RDY stretches counts once.
11. **Only shadowed writes are posted.** I/O, slot and Mega II writes stall
    the core until they complete (the tracker must be current before the
    next step is decoded). A posted write still in the buffer when /RES
    falls is dropped — at most one byte of a shadowed page, which the card's
    memory still holds.
12. **RDY low also holds local steps** in fast mode (the TransWarp's
    GS_PAUSE); the cycle the PHY is running repeats as in S6.
13. **Vector pulls** keep the MiSTer rule (VP low reads ROM in the bank-00
    language-card range, and `$FFEE/EF/FE/FF` always). The ROM 3 schematic
    wires the CPU's VPB to a VP pin on the CYA; `gs_socket_65816_scoping.md`
    §3.3 says the motherboard does not use VP. If a ROM 01 FPI ignores VP
    the replica would return the ROM vector where the machine returns the
    language-card RAM vector. Check on the bench with the paced mode's
    verify counter before trusting interrupts under LC RAM.
14. **§6.2 "against the FPI clock model (`clock_divider.v`)".** The bench is
    the S2–S6 socket-level FPI model, with the fast / sync cycle
    classification taken from `slow_class_now` of `clock_divider.v` (I/O,
    E0/E1 and shadowed writes are sync cycles; the SHADOW/CYAREG/STATEREG
    and `$C071–$C07F` exceptions). `clock_divider.v` itself produces clock
    enables for a core that shares its clock and was not instantiated: the
    socket bench needs PHI2 as a pin.
15. **Clocking.** §2.1 says 110 MHz / 27.5 MHz; the bench runs the PHY at
    108 MHz with 4 clocks per step (27 MHz) and at 100 MHz with 2 clocks per
    step (50 MHz), the two cases the fast-core log asks for. The PHY is
    unchanged (`OUT_DELAY` = 2); in native mode the broker must present the
    next request by the PHY's issue clock, i.e. `ADDR_CLKS` ≤ `OUT_DELAY`.

### 9.5 The reset rule

**Where the S6 sequencing lives.** In the ESP32 firmware:
`boards/a2mega/src/a2fpga_esp32/gs_socket.c` is the state machine (hold,
clock-alive wait, release, wait for the line, arm). The gateware has no arm
timing: `gs_socket_ctl.sv` passes `arm_i`/`listen_i` straight to the PHY;
the PHY only re-registers /RES per PHI2 cycle (core in reset until /RES has
been high at two falls); `hdl/esp32/esp32_ospi_connector.sv` holds the slot
reset and has the POR probe and hardware arm that the bench modes 0 and 1
use (`por_done`, arm in the same clock).

**What the default firmware (mode 4) does today.** It releases its own hold
with the socket off, then polls the slot /RESET level in STATUS, 1 ms apart,
from the disk task loop; the first high sample starts a timer, a low sample
clears it, and after `late` ms (20) of high samples it writes CTRL.arm. So
its reference is already "the line reads high", not "our release": a second
card that holds the line simply keeps it waiting. What it does not
guarantee: a low pulse shorter than the gap between two polls — and the gap
is as long as the disk task is busy — is never seen, so the arm can land
less than 20 ms after a release; and modes 0, 1 and 3 arm at or before the
release by design.

**Gateware side: `gs_socket_arm_seq.sv`.** The slot /RESET pin (the
wired-AND of the motherboard, our own hold and every other card) is
synchronised; a request is passed to the PHY only when the line has been
continuously high for `delay_ms_i`; any low sample restarts the count. Until
then both `arm_o` and `listen_o` are low, so the control-input shifter stays
off as S6 requires. Once passed the request stays passed while it is
asserted (S6: a later /RESET is the PHY's business); `rearm_i` optionally
drops the socket on every later /RESET fall and repeats the sequence.
`seq_en_i` = 0 is a wire-through. It needs one pin and the request bits and
nothing from the slot-side logic.

Bench (`sim/arm/run_gs_arm_seq_sim.sh`, real time scale, the sequencer
driving the real PHY and a PHI2-clocked core): motherboard release alone;
a second card holding the line 3.3, 31.7, 137.9 ms and two seeded random
times (17.2 and 78.7 ms by default) after the motherboard releases;
/RESET re-asserted 9.97 ms into the window for 5 ms (the ROM 01 mark) and
a 3 µs glitch 100 µs before the end; a request arriving 30 ms after the
release; /RESET after arming with and without `rearm`; the bypass. In every
case the socket is completely off (no drive, control shifter off) until the
arm, the arm comes 20.0016 ms after the LAST release (20 ms + 2 clks), and
the core then starts and runs. 13 releases, 11 arms, 2 count restarts,
PASS. Three deliberate faults (count from the first release; listen not
withheld; one millisecond short) fail it.

**Not done.** The sequencer is not instantiated in a board build: wiring it
into the 138B top needs a register (enable, delay, rearm, state) in the GS
window and a build, and the accelerator-only top that will use it does not
exist yet. S6 as shipped is therefore unchanged, firmware included.

**Firmware change needed** (not made; `gs_socket.c`, mode 4 only, the other
modes are bench knobs and stay as they are):

1. `ST_TIMED_HOLD` → on releasing our hold, write the sequencer's delay
   (`s_late_ms`), set its enable, and write `CTRL = LISTEN | ARM` at once.
   The request is withheld by the gateware until 20 ms after the last
   release, so nothing reaches the socket earlier than today.
2. `ST_WAIT_RISE` → no level polling and no timer. Poll the sequencer state
   (0.1 s is enough): "passed" → `ST_ARMED`; clock lost → `enter_machine_off`
   as now.
3. `gs late <ms>` writes the delay register; `gs` prints the sequencer
   state, the line's high time and the restart count.
4. The "SLOT RESET NEVER ROSE AFTER OUR RELEASE" message becomes "ANOTHER
   CARD IS HOLDING /RESET" and is not an error.
5. `enter_machine_off` clears CTRL as now (the request drops, the sequencer
   re-arms itself for the next power-up).

Behaviour that changes for a machine with no other reset holder: none, apart
from the arm point being 20 ms after the edge instead of 20–22 ms after the
first poll that saw it.

### 9.6 Not done, open

- No board build, no timing: the replica's decode sits in the address path
  of a local step (core address → aux / language-card translation → memory
  address); the fast-core log puts the bare address cone at 10.9 ns. S7c
  has to register or pre-decode it. The new modules are in no `.gprj`.
- Local memory is behavioural in the bench (128 KB RAM, the ROM image, up to
  16 expansion banks). BSRAM wiring, the ROM copy at arm (§2.6), DDR3 and
  its cache, speed control and the Zip / TransWarp registers (S7c–S7e) are
  not started.
- The bench machine is a model: I/O is a register file that reads back what
  was written, plus the soft-switch status bits and a VBL flag / video
  counters that advance with every read of them (a function of the access
  sequence, never of time, so runs at different speeds stay comparable). It
  has no slot cards and no ADB, so the ROM 01 run is a boot as far as that
  model lets it go (§9.3) — the same point in every mode, not a boot to
  BASIC.
- There is no top level for the accelerator-only build: PHY, broker, core
  and memories are wired together only in the bench. `gs_socket_ctl.sv`'s
  telemetry (trace ring, sweeps, counters) is not carried over; the broker
  has its own counters and the replica's state as outputs.
- Unverified against hardware: item 13 (VP), the SLTROMSEL reset value and
  slot-3 rule (item 7), the bank-01/E1 answer of `$C000–$C00B` (item 10),
  the effect of ROMBANK beyond "A14 cleared" (item 8). The paced mode with
  the verify counter is the instrument for all four.
- A read of fast RAM by anything but the CPU (slot DMA) and the a2p25 /
  a2mega slot-side logic watching the bus for bank-00 accesses that are now
  local were not looked at; forwarded writes and all I/O still appear.
- The ROM 01 re-assert itself is not modelled in the broker bench; the arm
  bench models it as a holder of the line.

## 10. The broker on the data-late step, and the first timing builds (2026-11-11)

Section 9's broker strobes the local memory from the core's address
(two-edge step). With the `F65C816` core's next-step address (`NA_OUT`) the
broker now also runs the data-late step (`DATA_LATE = 1`): the next step's
read, its memory-map decode and its data-source select are launched and
registered a step ahead and checked when the step runs; the core's clock
enable is a register (a socket step completes the clk after the PHI2 fall
event); native mode decides in the second clk and hands the PHY its request
live; the local-memory port is split into a read launch (one read address
per memory) and a write. The two-edge mode is unchanged and still tested
with the stock core. `gs_mmu_replica` gained the `pf_*` views for it.

Changes to section 9's record:

- 9.3 clocking: with a registered clock enable the PHY's issue point is two
  clks after the core steps; `ADDR_CLKS = 2` is used with `DATA_LATE`
  (`ADDR_CLKS = 1` two-edge is unchanged).
- 9.6 "the replica decode sits in the local-step address path": no longer
  for a step that follows a local step; such a step uses the decode made a
  step ahead. Other steps wait one clk for a registered copy.
- Bench: `broker_test.s` T16b (self-modifying code), timing-contract
  assertions in `tb_gs_broker.sv`, data-late builds `b108_3d` / `b100_2d`
  and their runs in `run_gs_broker_sim.sh`.

Design, verification table, the six probe builds
(`a2mega_accel_probe_138b.gprj`, `hdl/accel_probe_138b/`) and the levers
still open are in `gs_socket_s7_fast_core_exploration.md`, "Integration".
In short: functionally complete in simulation; the core and memory paths
fit 36 MHz steps, the next-read-address and broker-decision paths do not
yet.

### 10.1 Later the same day: decision from registers, and four behaviours to know

The second round of timing work (exploration log, "Integration, second
round") changed the interface and fixed two functional points. For the
record of section 9:

- **Ports.** Core → broker: `cpu_na_i` (next address), `cpu_nst_i` (next
  step's `{VPB, WE, internal}`), `cpu_rdy_i` (the core takes this step; low
  in WAI / STP). Broker → memories: `lm_ren_o` / `lm_wen_o` are registers,
  `RA_COPIES` copies each, with as many copies of the two read addresses
  (`lm_ram_ra_o`, 17 bits; `lm_rom_ra_o`, 18 bits: a ROM 3 image is 256 KB).
  PHY parameters: `CORE_SUBST = 0` (the broker substitutes internal I/O
  cycles itself) and `WDATA_LATE = 1` (the PHY takes the write data again the
  clk after the issue; a native step's request is registered a clk before
  its data). Both default to the S6 behaviour.
- **A step is decided from registers only.** The status of a step
  (`pl_int`, `pl_we`, `pl_vp_n`, `pl_io_int`) is registered from `cpu_nst_i`
  every time the core steps; the decode is the one made a step ahead, or a
  registered copy of the direct decode, which is itself made from the
  registered status. Nothing is decided in the first clk of a step (`dec_ok`
  is an explicit factor of the strobe). The memory-map switches take a
  socket cycle's effect the clk after it completes.
- **WAI / STP.** A waiting core does not take steps (`cpu_rdy_i` low): the
  status stands and nothing is treated as decoded ahead. The bench now has a
  WAI between its two interrupts and requires that it waits. That test found
  the stock core's WAI wake-up inverted (fixed in both cores, see
  `hdl/twgs/65C816/README.md`); the S6 build has the same core and needs the
  fix when it is next built.
- **A native-mode write reaches the card's copy when its socket cycle
  completes**, not when the step is decided. Before, a native write step cut
  short by /RESET wrote the card's RAM and not the motherboard's, so the copy
  and the memory of record came apart by one byte (found when the WAI moved
  a reset onto a write).
- **A fast-mode local write of a step cut short by /RESET stays written**
  (the write is in the second clk of the step; the reset arrives when it
  arrives). It is the same as the reset arriving a step later; the bench
  gives the ideal machine the same write and counts it. If that write was
  also a forwarded (shadowed) one, its socket half is dropped with the
  posted-write buffer, as 9.5 already records for a buffered write.
- **Timing contract.** The multicycle exceptions are generated
  (`hdl/accel_probe_138b/gen_sdc.py`) from the register groups named there;
  each group's claim is asserted in clks by `tb_gs_broker.sv`. A two-clk
  startpoint is always a register that changes only when the core steps, and
  its endpoints are either enabled by a register (memory ports, core) or sit
  behind the `dec_ok` factor.


### 10.2 The near memory and the two-clk step (2026-11-11)

The goal moved to a step rate above the current AppleSqueezer's 48 MHz
(exploration log, "Toward a step under 20.8 ns" and "The near memory and
the two-clk step"). Two things stood in the way of a 20 ns step and both
are structural, so the broker gained a second way of running local steps,
`NEAR = 1` (with `DATA_LATE`, `ADDR_CLKS = 2`). The decode-ahead broker of
section 10 / 10.1 is unchanged and still builds (`NEAR = 0`).

- **Near memory.** A direct-mapped cache of single bytes, 16K entries of
  `{tag, byte}`, one 16K × 1 block per entry bit, beside the core. It is the
  only memory the core's next address reaches. The index is the low 14
  address bits, untranslated; the tag names the physical byte (ROM or RAM,
  address bits above the index, and whether the language card moved A12).
  The banks and the ROM image ("far") are read only on a miss, from
  registers, and every local write goes to both. Ports: `nm_ren_o` (= the
  core's clock enable), `nm_ra_o`, `nm_rdata_i`, `nm_rtag_i`, and a write
  port from registers. Tags must power up all ones.
- **No decode ahead; two tiers of decode in the step.** The step's address
  and status are registers from the moment the core steps. In its first
  clk a cheap view (`gs_mmu_decode` `fast_*`: bank, page, a few switches)
  classes the common steps as the card's alone and names their tag: reads
  in banks 00/01 outside `$Cxxx` or in a ROM bank, writes in banks 00/01
  where nothing can be shadowed, internal cycles outside `$Cxxx`. The view
  is a subset of the full decode, proven on every vector of the decode
  sweep. In the second clk the core's clock enable is one gate behind the
  three registers that clk produced, so such a step is two clks, the step
  after a socket cycle included. Every other step (a socket cycle, a near
  miss, an expansion bank, a forwarded or language-card write, `$Cxxx`, a
  vector pull, RDY low) goes through the sequencer as before, deciding
  from the registered full decode, which has two clks to settle.
- **Writes.** A local write is registered at the decision and made in the
  following clk, to both memories, from registers. A near entry written at
  or after the launch of the next read is not used for that read.
- **The core's data** is the near memory's byte or one register (`alt_q`:
  far data, or the socket byte).
- **One byte, one entry.** The only local bytes with two addresses that
  differ below A14 are `$C000-$CFFF` of banks 00/01 (language-card bank 1
  as `$Dxxx`; plain RAM as `$Cxxx` when IOLC shadowing is inhibited). They
  live under the `$Dxxx` index only; a read through `$Cxxx` is always a far
  read.
- **What it changes for the machine:** nothing. The step sequence does not
  depend on the near memory; a miss costs clks, never a step. The card's
  memory of record is still the far memory, and the bench compares every
  near entry with it at the end of each run.
- **What it settles on the side:** the size of the ROM image (256 KB on a
  ROM 3) and of the banks no longer matters to the step, and the expansion
  banks on DDR3 are the same miss path with a longer wait.
- **Not done:** anything that loads the far memory behind the broker's back
  (the ROM image at bring-up, an ESP32 poke) must do it before the core
  runs or invalidate the near memory; there is no such port yet.

### 10.3 The step at 54 MHz, and what the broker changed for it (2026-11-12)

The integrated probe closes at 108 MHz with two clks per step, three
placements, and at 100 MHz likewise (exploration log, "Rung 5"). The core's
part is in the log; the broker's part, none of it visible to the machine:

- **The step's address is two registers.** `ea_r` is the core's next
  address as given; `ea_k` follows the effective address in every clk. A
  step that is an internal cycle aimed at I/O space repeats the address
  before it and reads it from `ea_k`; the first-clk view is taken of `ea_r`
  and one registered bit. The PHY's address is `ea_k`, which is the
  effective address from a step's second clk, before any request is raised.
- **Native mode's interrupt lines** come from the PH2-domain flops
  registered in every clk (`irq_e`), not from the copy loaded at the fall
  event: the same sample at the core's step, two clks sooner. Fast mode is
  unchanged (`irq_h`). The testbench asserts in clks that the lines the
  core sees are steady for two clks before every step, and the S6
  comparison catches a line that is a step late.
- **The step registers reset on `run_c`**, the registered view of /RES, a
  clk after the sequencer, in a clk in which nothing reads them.
- **The write registers load in every clk**; the write decision is one
  register (`wen_r`).
- **The near memory's read address has two copies** (`NA_OUT_B` of the
  core), one per row of block RAM in the probe. The broker passes the first;
  the probe's top level wires the second.
- **The core's microcode is in block RAM** in the near-memory builds
  (`F65C816_MCODE_ROM`), which the two-clk step makes possible: the core is
  never stepped in two successive clks, in any mode.

At 108 MHz the PHY's timing is the one S6 ran on hardware, and section 2.1's
"108 / N" is N = 2. **Decided 2026-11-12 (ed): the accelerator-only build
uses 108 MHz**, 54 MHz steps (exploration log §2d).

### 10.4 The accelerator-only build (2026-11-12)

It exists: `a2mega_accel_138B.gprj`, described in
[`gs_socket_s7_accel_only_build.md`](gs_socket_s7_accel_only_build.md),
built and simulated, not flashed. What it settles from the lists above:

- **The top level** of section 9.6: `hdl/twgs/gs_accel.sv` is the
  accelerator domain as one module, and the broker bench runs it beside
  its own hand-wired design with every output pin compared in every clk.
- **The ROM image** of section 2.6: read through the socket by
  `gs_accel_romcopy`, on request rather than at every arm. The broker
  gained a hold for it: the core is not stepped past the step in progress,
  and the socket's idle cycles become the reads. Afterwards the near
  memory is emptied, which is also the missing "invalidate" of section
  10.2.
- **The clock**: the S6 socket PLL unchanged, which is 110 MHz, not the
  nominal 108: 55 MHz steps.
- **Control**: the S6 firmware's GS window, with the trace-trigger address
  registers carrying the accelerator's requests under a key. With no
  request the card is S6 on the new core.

Still to do: everything of S7d and S7e, ROM 3. The first hardware run is in
the build's page.

### 10.5 A socket step behind a socket step (2026-11-12)

**What the first hardware run showed.** In fast mode, Marble Madness (code
and data in banks 02/03, which the card does not hold) ran at 0.70 of its
native rate: 1.184 M socket cycles a second for the core in 2.367 M PHY
cycles. One idle cycle went out behind every cycle of the core.

**Why.** The PHY issues the next cycle two clks after the core steps
(a native step's request is registered in the step's first clk for that
reason). A fast-mode step that is not one of the cheap view's is decided
at the strobe, in the third clk, from the registered full decode. So the
step behind a socket step always found an idle cycle issued and waited a
whole PHI2 cycle for the next issue point. Section 3's model has no such
cost, and the bench did not look for it: its program had some forty socket
steps in a row in a fast-mode run, and nothing compared the socket's cycle
count with the model's.

**The change.** `gs_mmu_decode` has a second cheap answer, `fast_sock`: a
read or a write in this bank is a socket cycle and nothing else, whatever
the switches say - a Mega II bank, an expansion bank the card does not
back, any other bank from `$80` up that is not a ROM bank. It is a
function of the bank and the backed size only, checked against the full
decode on every vector of the sweep (464,177,802 of 981,101,952 vectors are
in the class). The broker raises the request of such a step (not an
internal cycle, not a vector pull) in its first clk, as a native step's is:
the same registers (`ea_k`, the status, the write data registered in the
second clk for the PHY to take a clk after the issue). The step is still
decided at the strobe from the full decode, which must agree; a
simulation check stops the run if a request raised ahead belongs to a step
that is not that socket cycle, or if such a step completes without it. No
cycle reaches the socket that did not before: the same cycles go out, one
PHI2 cycle sooner. `SOCK_PRE = 0` gives the old timing, for comparison.

RDY needs no term in it. While RDY is low the cycle on the bus is being
repeated, so the request cannot be issued before the fall that finds RDY
high, which is also the fall that lets the strobe go. Two mutations that
added or removed a RDY term changed nothing in 74 + 24 runs, the 24 with a
stall every 2 to 13 PHI2 cycles; the terms came out, and with them six
failing paths of the first build.

**In simulation** (110 MHz, the test program with code and 16-bit data in
bank E1, called from the interrupt-enabled loop):

| | `SOCK_PRE = 0` | `SOCK_PRE = 1` |
|---|---|---|
| socket steps behind a socket step | 3,336 | 3,334 |
| ... of them behind an idle cycle | 3,336 | 6 |
| 60,000 steps | 14.409 ms | 11.145 ms |

The six that remain are back-to-back accesses to `$C0xx` (R-M-W on a soft
switch): I/O in banks 00/01 depends on the switches and is not in the
class. A ROM 01 boot has 79 of those in 3,000,000 steps.

**What it does not do.** An internal cycle between two socket steps still
costs a PHI2 cycle: the step behind it starts two clks later and misses
the issue point, as before. The cycle is no longer than the one a native
step spends on that internal cycle, so code in a bank the card does not
hold should now run at about its native rate, not above it; S7d is what
makes it faster. A later issue point (the PHY's `out_extra`) would catch
the step behind one internal cycle at the cost of address setup on the
socket; not tried. The idle loop's rate (one `$C019` read per two Mega II
cycles) is unchanged: six local steps separate its reads.

**Verification.** Suite 88 runs (two new: a RDY stall every second and
every fifth PHI2 cycle); a bench property (no idle cycle issued in front
of a socket-only step, with the bench's own bank test); `gs_accel` beside
the design, 35 runs, 290,331,590 clks; ROM 01 boot hash and write stream
unchanged (`6012b76169ecc820`); nine mutations of the new logic, seven
detected, the other two the RDY terms above. Timing: three placements of
the committed source with no violation (build page).

**On hardware** (the build page has the table): the same benchmark before
and after, every test faster by 1.20 to 1.36 and none below base; the
tests that run from expansion RAM, which this section said should reach
about their native rate, came out at 1.28 to 1.44 of it, their stack,
direct page and ROM calls being the card's.

### 10.6 Two expansion banks in block RAM, and the far memories at two clks (2026-11-12)

A stopgap for S7d, in `gs_accel` (`EXP_BANKS = 2`): banks 02/03 as 64 more
blocks beside banks 00/01, the broker's `exp_banks_i` no longer zero. The
bench already backed expansion banks with an array; the module now does
with blocks, and is compared pin for pin in runs with two banks.

It needed the far memories finished as far memories. Section 10.2 has them
"reached and left only through registers", which was true of the read
address and of nothing else: read data went to `alt_q` in one clk, a write
left the broker's registers for every block in one clk, and one register
enabled them all. With 128 blocks that closed; with 192 it failed 44
paths. Now: `FAR_CLKS = 2` (a far read waits one clk more; its data is not
looked at in the clk after the launch), a write register per data bit in
`gs_accel` (the write lands a clk later; the broker launches no far read
within three clks of a write, and the bench checks two), and
`RA_COPIES = 8`. The same three things will be wanted by a DDR3 client,
whose data is later still.

What it does not do: the cheap view does not know expansion banks, so a
step there is three or four clks. Details, verification and timing: the
build page, section 3a.

### 10.7 S7d: the expansion banks on the DDR3 (2026-11-12, 11-13)

Built, in simulation and as a board build that meets timing at 105 MHz
(52.5 MHz steps) on three placements; at 110 MHz it does not hold, and the
build page (section 3b) has the seven rounds. The build page has
the description and the numbers. What differs
from section 2.2 and the plan of section 7:

- **No separate cache.** The near memory is the cache, for every bank: its
  tag was widened to A22, with the added bits kept out of the first-clk
  compare (RAM above bank 03 is marked there in a pair of the old tag's
  bits that nothing else uses; the bits themselves are read a clk later
  from the step's address register).
- **One ordered queue** for writes and reads in front of the DDR3
  (`gs_accel_exp`), on the full build's `ddr3_ports` / `ddr3_port_cdc`. The
  crossing is theirs; the accelerator's clock domain ends at the queue.
- **The broker's far path waits** on a signal instead of counting clks
  (`EXP_WAIT`), and a PHI2-paced step waits by having its socket cycle
  issued again.
- **A read brings one byte.** The 32-bit word the arbiter returns holds
  three more; filling their entries too is the obvious next step and is
  not done.
- **The clock is the price.** With the DDR3's controller on the left edge
  and the socket at the bottom, the accelerator no longer closes at
  110 MHz by a margin that survives a change of placement. 105 MHz does.
  The 1.0a5 board's HyperRAM is the planned home for this memory and has
  no such controller; whether 110 MHz comes back there is to be measured.
- **A defect in the first version** (a step held by a full queue after its
  socket request had been raised ahead) was found by forcing the queue
  full in the bench, and fixed before any bitstream ran.

**On hardware, 2026-11-13** (build page, section 3c). The DDR3 calibrated
and the queue never overflowed. The first switch to card memory under
GS/OS crashed: the widened tag had made "all ones", the mark of an empty
near-memory entry, the real tag of RAM at 7F/C000-FFFF, so after a ROM
copy a read there took an empty entry's byte. The bench ran no bank above 09
and never read that RAM from an empty entry; it now has all 126 banks
and does. The empty entry has a tag no byte has, and the block RAM's
power-up zeros read as it. Before that fix was built, with every entry
rewritten by hand from the monitor, the same bitstream ran the benchmark
in fast mode: 12 to 14 times the machine on every test, the program's own
code in bank 04 nine times faster than with two banks of block RAM. The
fixed source meets timing on three placements at 105 MHz. Flashed the
same evening, it ran card memory under GS/OS straight after the ROM copy
with a verify count of 0, and the benchmark with the same times.

**The near memory as lines (2026-11-14, build page sections 3d and 3e).**
Measured on that build: the benchmark's MHz is the step rate, and in its
computing tests a hit in banks 04 to 7F took four clks, 37 % of the time.
And a miss brought one byte of the DDR3's sixteen. The near memory is now
1,024 lines of sixteen bytes under one tag each, nine blocks for
nineteen; every far read is a line (the DDR3's burst, the block memories
sixteen wide) and fills it; a write changes a byte of a line that is
there and installs nothing; a step in any bank the card holds is two clks
on a hit. 176 bench runs, three placements at 105 MHz with no violation.
Flashed 2026-11-14 08:53 and run on the machine the same morning: card
memory verify with no mismatch (bank 04 through the DDR3's line read), the
benchmark's fast pass at 45 to 49 M steps a second on its computing
stretches and about 35 M where the core takes socket cycles. The
benchmark's own figures: average 44.02 MHz (33.34 before), sieve 49.65,
sort 48.72, Fibonacci 46.31, integer 45.88, floating point 37.81, Gamm
35.76 (the build page, section 3f).

**A copy of the Mega II's RAM (2026-11-14, build page section 3h; not
flashed).** What the floating point tests lose is socket cycles in banks
E0/E1 (build page section 3g). The card now keeps a copy of that RAM
below `$C000` in the DDR3's unused first 128K, behind the near memory
like an expansion bank: writes go to the machine as before and to the
copy, and a request bit, which may change at any step, says whether a
read comes from the socket or from the copy. In simulation it is
complete (210 runs, 26 mutations detected). At 105 MHz it is not closed:
five placements of ten have no violation, and what fails is mostly what
was at the edge before it.
