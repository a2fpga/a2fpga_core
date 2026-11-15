# S7 — the accelerator-only build

Status: on hardware since 2026-11-12 (section 3). The DDR3 build of
section 3b ran on 2026-11-13 and runs the benchmark 12 to 14 times faster
than the machine (section 3c). That run found a defect in the near
memory's empty entry; the build with the fix (m0) is on the card since
18:21 the same day and ran the same benchmark without it (section 3c).
Built since (t0, section 3e): the near memory as lines of sixteen bytes, a
DDR3 read filling a whole line, and every step in the expansion banks two
clks on a hit; three placements at 105 MHz with no violation. **Flashed
2026-11-14 08:53 and run the same morning (section 3f): card memory
verifies with no mismatch, and the benchmark's average is 44.02 MHz where
m0 had 33.34; the sieve and the sort are above 48, the floating point
tests 36 to 38.**
Built since and not on the card (section 3h): a copy of the Mega II's RAM
below `$C000` (banks E0/E1) kept in the DDR3, read in place of the socket
when a request bit asks, switchable at any step. Simulated in full; **at
105 MHz five placements of ten have no violation, which is not closure.**
One clean placement (x0) is on the card since 2026-11-14 15:39 as an
experiment, by Ed's decision: the floating point tests go from 37.81 and
35.76 to 48.14 and 44.51 over ten runs, the average from 44.24 to 47.48;
the switch works while the machine runs.
Parents: [`gs_socket_s7_accelerator_scoping.md`](gs_socket_s7_accelerator_scoping.md)
(what the accelerator is) and
[`gs_socket_s7_fast_core_exploration.md`](gs_socket_s7_fast_core_exploration.md)
(§2d: why an accelerator-only card beside an a2p25; "Rung 5": the timing).

## 1. What it is

`a2mega_accel_138B.gprj` builds the a2mega 1.0a3 with the 138B SOM as a CPU
accelerator and nothing else:

- `hdl/twgs/gs_accel.sv`, the accelerator domain as one module: the socket
  PHY, the broker with the near memory and the two-clk step, the `F65C816`
  core with its microcode in block RAM, banks 00/01 and the ROM image in
  block RAM (128 KB each), and `gs_accel_romcopy`, which reads the ROM image
  through the socket.
- The ESP32 connector, for control and telemetry, with everything else it
  serves in the full build tied off.
- The slot side passive: level shifters on as inputs, the data bus never
  turned round, no /IRQ, /INH, /DMA or /RDY, the two daisy chains passed
  through. The one slot line the card can drive is /RESET, through the
  ESP32's reset hold, as in the full build.
- No framebuffer, DisplayPort, slot cards, slot ROM or I/O decode, or OSD.
  The DisplayPort balls are not ports of this top; they take the
  bitstream's unused-pin default (input with pull-up), as in the DP test
  builds. The DDR3 was left out the same way until section 3b, which gives
  it to the accelerator.

Clocks: the 50 MHz crystal; `clk_logic` (the board PLL's 54 MHz) for the
connector; `clk_gs` for the accelerator, from `gowin_gs_pll`, **the S6 socket
PLL, unchanged: 110 MHz**, so the core steps at **55 MHz**. (With the DDR3,
section 3b, the build is at 105 MHz and 52.5 MHz steps.)

> The decision recorded on 2026-11-12 was "108 MHz", made on the statement
> that S6's PHY had run on hardware at 108 MHz. It ran on this PLL, which is
> 110 MHz (50 MHz × 22 / 10; `hdl/a2mega_138b.sdc` constrains it at
> 9.091 ns); "108" is the nominal figure in the PHY's comments and the clock
> of the simulation bench. The build keeps the hardware-proven PLL and PHY
> rather than introduce a new PLL recipe for 2 %. Say so if a true 108 MHz
> is wanted; the same design closes there as well (probe `_n8`).

## 2. Control and telemetry

Through the connector's GS window, with the firmware the S6 build already
has (`gs`, `gs set <idx> <val>`, `gs trace` on telnet). Nothing in the
firmware was changed for this build.

| window register | S6 meaning | here |
|---|---|---|
| 0 CTRL | arm, sweep, listen, trace bits, clear | bit 0 arm, bit 2 listen, bit 7 clear, as S6 (the firmware's auto-arm drives it); the other bits do nothing |
| 2 | address-delay sweep | the same |
| 3 | data-hold sweep tap | nothing |
| 29 | trace trigger address, low | the accelerator's requests (below) |
| 30 | … high | nothing |
| 31 | … bank | **must hold `A5`**, or register 29 is ignored |

Requests in register 29:

| bit | name | effect |
|---|---|---|
| 0 | FAST | local steps at 55 MHz. Needs CARDMEM. |
| 1 | CARDMEM | the card's memory is the memory of record. In native mode its byte goes to the core and is compared with the socket's (the verify count). |
| 2 | CXROM | internal `$C100–$CFFF` firmware served from the image. Taken when the core is in reset or held (so: at /RES, or set it with COPY). |
| 3 | COPY | 0 → 1: read the ROM image through the socket. The core is held between two steps for about 46 ms. |
| 4 | SLOW | (section 3h; not in the build on the card) reads of the Mega II's RAM below `$C000` in banks E0/E1 come from the card's copy. Needs CARDMEM. May change at any step. |

Bits 0–2 take effect only once an image has been copied since power-up.
**With register 29 at 00, or without the key, the card is S6 on the new
core: every step a socket cycle, every byte from the socket.** That is the
state after power-up, and after `gs trig` (which writes `FF FF FF` to
29–31: no key).

Telemetry is the S6 window with two fields carrying something else:

| field in `gs` | here |
|---|---|
| status, cycles, stalls, BE-low, PHI2 period and high time, last address | the same |
| hold mismatches | verify count |
| hold samples | `{mode, 5A}`; mode: bit 7 ROM image valid, 6 copy busy, 5 core held, 4 fast, 3 card memory, 2 cxrom, 1 E0/E1 reads from the copy (section 3h) |

`gs trace` prints 64 lines; here line *n* is telemetry word *n* (read
`bank:addr data` as one 32-bit number): 0 core steps, 1 socket cycles for
the core, 2 posted writes, 3 clks waited for the write buffer, 4 local
reads in place, 5 local reads that waited, 6 `{verify count, 00, mode}`,
7 address of the last verify mismatch, 8 `{copies, 00, sum of the image's
bytes mod 65536}`, 9 `{shadow, CYAREG, SLTROMSEL, STATEREG}`, 10 the other
switches, 11 PHY bus cycles; with section 3h's build 13 `{E0/E1 verify
count, 00, 0000, built with the copy, the copy whole, SLOW requested, SLOW
in effect}` and 14 the address of the last E0/E1 mismatch. LEDs (active low): heartbeat, socket ours,
core running, fast.

## 3. A bring-up ladder (proposal)

Each step is observable before the next is taken. All four steps were run
once on 2026-11-12 (below), without video and with the machine idling.

1. **S6 equivalence.** Power up beside the a2p25; let the firmware arm as
   it does for S6; register 29 untouched. The machine should behave exactly
   as with the S6 bitstream. This is already new on hardware: the
   `F65C816` core, the broker's native mode and the 110 MHz core clock
   domain (S6's core ran on PHI2).
2. **Key and copy.** `gs set 31 0xA5`, `gs set 29 0x08`. Mode shows copy
   busy, then ROM image valid; word 8 gives the image's byte sum, to be
   compared with the sum of a dump of that machine's ROM. The machine
   pauses for about 46 ms.
3. **Card memory, native.** `gs set 29 0x0A`. The core now takes the card's
   bytes; the verify count must stay 0. A count that moves gives the
   address in word 7.
4. **Fast.** `gs set 29 0x0B`. LED 3 on; words 0 and 1 show steps running
   ahead of socket cycles.

Things to know before step 3:

- Banks 00/01 on the card hold what the core has **written since the
  socket was armed**. Anything else differs from the machine's RAM: RAM
  written before a re-arm without a power cycle, RAM written by slot DMA.
  Step 3 is where that shows.
- /RES during a copy cuts it short (image not valid; copy again). A warm
  reset keeps a valid image and the card's RAM.
- The step that was held and every byte in the near memory are not trusted
  after a copy: the near memory is emptied before the core goes on.

### First hardware run, 2026-11-12

ROM 01 IIgs, the card alone (no a2p25: no video, no boot device), slot
powered, firmware of Sep 13 2026 arming as for S6 (mode 4). Bitstream sha256
`48c06bbc…c8c04baa`, source 857d136c, flashed over USB with read-back verify.
Read over telnet with `gs`, `gs events` and `gs trace`.

| step | what was done | result |
|---|---|---|
| 1 | power-on, register 29 untouched | startup beep, then the ROM's no-device beep. Signature `5A`, mode 00. The core ran the ROM to the "No device connected!" screen and sat in its sliding-apple loop (FF:A55E–A5AA, polling `$C019`); 280 M steps, one socket cycle each, 0 stalls. Event log: release, arm 36 ms later, no /RESET fall afterwards |
| 2 | `gs set 31 0xA5`, `gs set 29 0x08` | mode 80, 1 copy, image sum `7EE8` = the sum of a ROM 01 image; the machine carried on |
| 3 | `gs set 29 0x0A` | mode 88; verify count 0 after 76 M cycles |
| 4 | `gs set 29 0x0B` | mode 98; rates over 12.7 s of wall clock: 3.566 M steps/s, 0.510 M socket cycles/s for the core, 1.020 M PHY cycles/s, 2.55 M local read hits/s, 0 misses, 119 posted writes/s (the loop's two text-screen writes per frame); 0 stalls; the core stayed in the same loop |

What this does and does not show:

- The loop is bound by the bus, not by the core: each pass reads `$C019`,
  a slow soft switch, so it runs 7 steps per socket cycle and one socket
  read per two Mega II cycles (a native pass takes four). It is no measure
  of the 55 MHz step rate: the longest local run in it is six steps.
- Fast mode has no byte-for-byte check, and there was no video. The
  evidence that the core stayed right is that it stayed in the loop, with
  the expected two forwarded writes per frame.
- Nothing but the idle loop has run: no program, no disk, no interrupts
  beyond what the ROM enables at that screen, no reset while fast.
- The telemetry words are read a byte at a time and are not latched: a
  word can be off by `0x100` or `0x10000` when a carry lands mid-read. Read
  twice before trusting a difference.

### With the a2p25 in slot 3, the same day

The same card and bitstream, an a2p25 in slot 3 for video and storage (a
USB stick on its hub), Marble Madness booting from the stick.

| step | result |
|---|---|
| power-on, two cards holding /RESET | the a2mega let go at 450 ms, the a2p25 held the line until 8.49 s (waiting for its stick), the firmware armed 26 ms after the rise; no /RESET fall afterwards. The game boots and plays on the new core: 2.07 M steps/s, one socket cycle each, 0 stalls |
| `gs set 29 0x08` with the game running | 1 copy, sum `7EE8` again |
| `gs set 29 0x0A` | verify count 0 after 95 M cycles, about 3.3 M bytes served by the card and compared |
| `gs set 29 0x0B` | the game keeps playing, with no artifacts and its music at tempo, but **slower**: 1.449 M steps/s against 2.077 M native. 1.184 M socket cycles/s for the core in 2.367 M PHY cycles/s: one idle cycle behind every cycle of the core |

Two things this showed:

- **The game runs from banks 02 and 03.** The card holds banks 00/01 and
  the ROM; expansion RAM on the card is S7d. Only about 3 % of the game's
  cycles are reads the card can serve, so fast mode has little to give it.
  Speed shows on software that lives in banks 00/01: eight-bit programs.
- **A defect: in fast mode a socket step behind a socket step waited a
  whole PHI2 cycle behind an idle one.** The sequencer decides a fast-mode
  step in its third clk; the PHY issues in the second. Fixed in the source
  after this run (scoping doc §10.5); the card still carries the build
  without the fix (aoz). The idle loop's "one socket read per two Mega II
  cycles" above is a different thing and stands: there the core runs six
  local steps between two reads, and an idle cycle is already on the bus
  when the next read is known.

A benchmark, the same evening, the same build (aoz, without the fix): a
TML Pascal program that times six tests at the machine's speed, waits for
the speed to be changed, and times them again. Times in 60ths of a second;
fast mode was switched on at its prompt (copy, card memory with a verify
count of 0, then fast).

| test | base | fast mode | ratio |
|---|---|---|---|
| 10 iterations of the sieve | 413 | 437 | 0.95 |
| selection sort of 500 strings | 1159 | 1060 | 1.09 |
| 100 iterations of a floating-point test | 475 | 49 | 9.7 |
| 15,000 Gamm units (floating-point mix) | 1545 | 314 | 4.9 |
| 10 iterations of Fibonacci calls | 2021 | 1794 | 1.13 |
| 5,000 iterations of integer math | 1564 | 1083 | 1.44 |

The program rates the floating-point test at 26 MHz and the Gamm mix at
13 MHz against a base it takes as about 2.5 MHz; its average is 8.5 MHz.
The split is the memory map again. The floating-point work is done by
SANE in the ROM, on a stack and direct page in bank 00: all the card's.
The sieve, the sort and the calls are the program's own code and data in
expansion RAM: every step a socket cycle, and with this build's defect a
socket step behind a socket step waits a cycle, so the sieve came out
slower than base.

**The same benchmark on fx2, the build with the fix** (flashed 19:38 the
same evening; the same machine, cards and firmware; the base pass run
again and within one tick of the first on every test):

| test | base | aoz, fast | fx2, fast | fx2 ratio | the program's MHz |
|---|---|---|---|---|---|
| 10 iterations of the sieve | 413 | 437 | 322 | 1.28 | 3.24 |
| selection sort of 500 strings | 1159 | 1060 | 805 | 1.44 | 3.63 |
| 100 iterations of a floating-point test | 476 | 49 | 41 | 11.6 | 31.35 |
| 15,000 Gamm units | 1546 | 314 | 253 | 6.1 | 16.25 |
| 10 iterations of Fibonacci calls | 2020 | 1794 | 1417 | 1.43 | 3.59 |
| 5,000 iterations of integer math | 1564 | 1083 | 863 | 1.81 | 4.57 |

The program's average went from 8.49 to 10.44 MHz. Every test is faster
than on aoz, by 1.20 to 1.36, and none is below base. At the program's
prompt the core takes 0.844 M socket cycles a second of the same 1.86 M
(aoz: 0.668 M), and steps 12.4 M times a second (aoz: 9.7 M). The build
ran the boot, the ROM copy (sum `7EE8`) and card memory (verify count 0)
as aoz did.

After fast mode has run, register 29 must not go back to 00 without a
reset: the machine's copy of banks 00/01 is stale by design. `0x0A` is the
way back to PHI2 pacing, and its verify count then means nothing.

## 3a. Banks 02/03 in block RAM (2026-11-12, not flashed)

`gs_accel` has a parameter `EXP_BANKS`, 0 or 2, and the board top sets 2:
expansion banks 02 and 03 in block RAM, beside banks 00/01 and on the same
terms. They follow every write of the core from the moment the socket is
armed; with card memory on they are the memory of record, and in native
mode each byte they give the core is compared with the socket's (the same
verify count). A stopgap for S7d's DDR3: 64 more blocks, 243 of 340.

- **Two banks, not four**, because the near memory's tag (`NEAR_KW = 4`:
  A14–A17) reaches bank 03 and no further. Four would want a wider tag
  and a new floorplan for the near blocks.
- **The machine must have banks 02/03 itself** (a memory card in a ROM 01
  machine). The card does not add memory the machine lacks.
- **A step in banks 02/03 is three or four clks, not two**: the first-clk
  cheap view covers banks 00/01 and the ROM only, so these steps are
  decided from the full decode. About 27 to 37 MHz against 55.
- Telemetry word 12 is `EXP_BANKS` (2 on this build, 0 on aoz and fx2).

**The far memories now have two clks in each direction.** The first build
with the 64 extra blocks failed 44 paths by up to 0.482 ns, everywhere:
the banks and the ROM image are 192 blocks all over the die, and three of
their paths were still single-clk, pulling the broker and the core apart.

| path | before | now |
|---|---|---|
| read data, blocks → the broker's `alt_q` | one clk | two: the broker waits a clk longer on a far read (`FAR_CLKS = 2`) and does not look at the data in the clk after its launch |
| RAM write, the broker's registers → blocks | one clk | through one more register per data bit in `gs_accel`: the write lands a clk later |
| read and write enables | one register to every block | a copy per data bit (`RA_COPIES = 8`) |

A step served by the near memory is unchanged. The late write is safe
because the broker cannot launch a far read until three clks and more
after it makes a write; the bench stops any run in which a read is
launched within two. In simulation the far data reads wrong in the clk it
is not yet valid, in the bench's model and in `gs_accel`, so a broker that
looked early would show. Cost: 60,000 steps of the test program take
9.455 ms against 9.444.

Verification: the suite is 102 runs, 14 of them with `gs_accel` holding two
banks and compared pin for pin with the bench's design in every clk
(native, paced, fast, toggling, with internal slot firmware, warm resets, a
machine with six expansion banks behind it, dense RDY stalls, and a ROM 01
boot): 247,013,471 clks; over all 49 runs with the module beside the
design, 535,896,565 clks. The test program runs code from bank 02 and, because
everything it wrote there stayed in the near memory, pushes those entries
out and reads the bytes back from the expansion blocks themselves, onto
the socket. Six mutations of the new logic, all detected (three were not
until that test existed). A bench fault found on the way: the final
comparison of the card's RAM could be taken in the clk the last step's
write was landing.

Timing, three placements of the committed source:

| build | failing | worst slack |
|---|---|---|
| fe1 (the far paths as they were) | 44 | −0.482 |
| **fe2, the committed source** | **0** | **+0.007** |
| fep1 (a telemetry constant changed) | 0 | +0.003 |
| fep2 (changed again) | 0 | +0.012 |

In fe2 the far data has 8.96 ns of slack on its two-clk path; the step
paths are where they were (core → core +0.21, near memory → core +0.08).
Size: 6,764 logic cells, 3,468 FF, 243 block RAMs. Build stamp
`20261112202241`, bitstream sha256 `6761a20a0f4d85f3…974a5dfb27`.

**On hardware** (flashed 21:10 the same evening; telemetry word 12 reads 2;
ROM copy sum `7EE8`; card memory at PHI2 pace for 17 s, about 24 M bytes
served and compared, verify count 0; then fast). The same benchmark:

| test | base | fx2, fast | fe2, fast | fe2 ratio | the program's MHz |
|---|---|---|---|---|---|
| 10 iterations of the sieve | 413 | 322 | 318 | 1.30 | 3.28 |
| selection sort of 500 strings | 1159 | 805 | 795 | 1.46 | 3.68 |
| 100 iterations of a floating-point test | 476 | 41 | 38 | 12.5 | 33.83 |
| 15,000 Gamm units | 1546 | 253 | 240 | 6.4 | 17.14 |
| 10 iterations of Fibonacci calls | 2020 | 1417 | 1401 | 1.44 | 3.64 |
| 5,000 iterations of integer math | 1564 | 863 | 853 | 1.83 | 4.63 |

The program's average went from 10.44 to 11.03 MHz: one to seven percent
per test. The two banks work (nothing wrong in 24 M compared bytes, a
clean run), and they are not where this program lives: with the program
waiting at its prompt the socket shows accesses to bank 04, twice in some
fifty samples, and none above it. Where a program is loaded on this
machine was the thing not known, and two banks do not reach it. Not
sampled while a test was running.

## 3b. Expansion memory on the DDR3, at 105 MHz (2026-11-13)

The benchmark of section 3a runs from bank 04: sampled at PHI2 pace (every
step on the socket), 70 % of the steps of its sieve, sort, call and integer
tests are in bank 04 and 30 % in bank 00; four of 1,062 samples are in bank
7F. Two banks of block RAM stop one short. This build puts every expansion
bank, 02 to 7F, in the board's DDR3 - S7d as the scoping doc has it.

**What is in the build.** The full build's DDR3: its PLL block
(`board_plls`, the clock chain calibration was proven with), its reset
sequencer and calibration watchdog, `DDR3_Memory_Interface_Top`,
`ddr3_ports` and `ddr3_port_cdc`, with the accelerator as the only client
(port 1 is tied off). In the accelerator's clock: `gs_accel_exp`, one queue
of writes and reads in program order, and in the top a byte-to-word
adapter (the arbiter's words are 32 bits; a read's byte lane is kept until
its word comes back). `gs_accel` is built with `EXP_DDR = 1`,
`EXP_BANKS = 126`, `NEAR_KW = 9`.

**The near memory tags every bank.** Its entry is the byte, the tag as it
was (two bits that say ROM and "A12 moved", and A14–A17), and A18–A22. The
first fourteen bits are read with the core's next address, in the same
fourteen blocks as every build before this one, and they are all the
first-clk decision needs. RAM above bank 03 is marked in the two bits that
were {ROM, A12 moved}: both set, a pair nothing else uses (ROM is {1, 0},
and nothing moves A12 above bank 03). A step of the cheap view is never in
those banks, so its entry matches exactly when the old fourteen bits match.
The five high address bits are in five blocks of their own, read a clk
later at the step's address - a register - and written a clk after the
rest of the entry; only the registered full compare uses them, and it has
the time. A first version spent a fifteenth bit ("an address bit above A17
is set") in the first-clk compare; this one costs that compare nothing.

**Waiting for the memory.** A near miss in an expansion bank queues a read
and waits for it: a fast step in place (the broker's count stands while
`lm_rwait_i`), about 25 clks in the bench's model. A PHI2-paced step cannot
stand still, so its socket cycle is not taken as complete until the byte is
there; the cycle - a read of RAM - is issued again meanwhile. It may not
take the socket's byte instead: after fast mode the machine's copy is
stale (a first version did, and a toggling run stopped at once). Writes go
into the same queue; when it is within six entries of full every fast step
that could write there waits at its strobe.

**Granted only when it is safe.** Card memory needs the DDR3 calibrated and
a queue that has never overflowed, as well as a ROM image. If the DDR3
does not come up, the card is S6 on the new core and stays so. Telemetry
word 12 is `{EXP_DDR, queue overflowed, memory ready, EXP_BANKS}`: `057E`
on a good start. The DDR3's sequencer state and retry count are in the
firmware's debug registers, as in the full build.

**The card's copy is what the core wrote since the socket was armed**, as
for banks 00/01. The DDR3 does not start at zero. In PHI2-paced card-memory
mode every byte the near memory gives is compared with the socket's, and
so is every byte fetched from the DDR3 (the verify count).

**A defect found on the way, never built into a bitstream that ran.** When
the queue was nearly full the broker held a fast step at its strobe. A
step whose socket request had been raised ahead (the early request of
section 3) was held too, its socket cycle completed with the step still
undecided, and the cycle would have been issued twice. The bench did not
fill the queue often enough to show it. It does now: `+wbforce` forces
"nearly full" in long bursts, and a check stops the run if a step's socket
cycle completes before the step is decided. Six of six such runs failed
before the fix and pass after it: a step whose request is already at the
socket is not held by the queue.

**Verification (simulation).** The broker suite, 140 of 140 runs;
the decode sweep (981,101,952 vectors), the replica benches and both
socket benches pass on the same source. The bench's
memory answers reads 8 to 39 clks late and is not always ready
(`gs_exp_mem_sim`; `+xlat`, `+xgap` make it slower than the core writes);
both the bench's design and `gs_accel` beside it have one, and the pins
are compared in every clk. New in the test program: banks 04 and 08
against bank 00 at one near-memory index; a 96-byte block move into bank
02; a reset dropped on a step that is waiting for its byte (`+resetx`).
Seven mutations of the new logic: six detected (the marking of high banks
among them); the seventh (a byte that comes back to a step a reset removed
is not dropped) changes nothing at any latency the DDR3 could have - the
byte is back before the reset is over - and stays as a safeguard. The S6
pin comparison is off in PHI2-paced runs of this configuration: a cycle
issued again is not S6. Nine runs are at 105 MHz (`b105_2s`).

**Timing: 110 MHz did not hold, 105 MHz does.** The rule is three
placements of one source with no failing path, against a clock uncertainty
of 0.5 ns (so "+0.03" below is 0.53 ns of real margin, and a small negative
number is a path that works with less than the margin asked for). Seven
rounds of the source:

| round | what changed | failing paths (worst slack, ns) in each placement |
|---|---|---|
| 1 | first build | 560 (−2.529) |
| 2 | the queue's "nearly full" and "waiting" as registers | 0 (+0.019), 97 (−0.281), 20 (−0.092) |
| 3 | the queue registered at both ends; high tag bits written a clk late | 0 (+0.018), 0 (+0.028), 88 (−0.986) |
| 4 | the {1, 1} marking in place of a fifteenth tag bit | 43 (−0.391), 26 (−0.152), 98 (−0.753) |
| 5 | the PHY's enable as a register; the queue in one block RAM | 11 (−0.031); the others not built |
| 6 | one write-enable register for the far memories; dead register copies removed | 80 (−0.513), 8 (−0.131), 0 (+0.038) |
| 7, 110 MHz | the defect's fix; cycle completion from registers a clk ahead | 140 (−1.788), 138 (−1.497), 1 (−0.075) |
| **7, 105 MHz** | **the same source, `ACC_CLK_105`** | **0 (+0.029), 0 (+0.037), 0 (+0.028)** |

At 110 MHz the same source lands anywhere from one path 0.075 ns short of
the margin to 140 paths 1.8 ns short, by placement. The DDR3's controller
sits on the left edge of the device and the socket on the bottom and lower
right; the accelerator is pulled between them, and its paths are mostly
wire (5 to 7 ns of 8.5). The failing families differ from placement to
placement (the core's two-clk loop through the near memory, the far
memories' write side, the PHY's enable to the broker), which is the sign
of a design at the edge and not of one bad path. So the build as committed
runs the accelerator at **105 MHz: 52.5 MHz steps**, from a second PLL
recipe (`gowin_acc_pll`, 50 MHz × 21 / 10), selected by `ACC_CLK_105` in
`accel_only_defines.v`; `gen_sdc.py` reads the same line for the period.
Comment the line out and regenerate the constraints for 110 MHz. The
block-RAM build of section 3a (on the card today) closed at 110 MHz and
is unchanged by this.

Changes made for timing that are in every build from now on, each exact
and checked in simulation where it is a register standing for a function:
the PHY's `enabled` is a register (asserted equal to the old function in
every clk); the ROM copy's two terminal comparisons are registered flags;
the broker's cycle-completion conditions are registered a clk ahead of the
PHI2 fall event (asserted equal at every fall event); the far memories'
write enables come from one register; the queue is one block RAM (this
device has no distributed RAM, so a small memory is otherwise built from
registers).

Size: 11,131 logic cells, 11,416 FF, 192 of 340 block RAMs (the two banks
of section 3a are gone; the near memory is 14 + 5 blocks; the queue is
one). Build k0: stamp `20261113103322`, bitstream sha256
`4aad21337ff394c4…b620fb41072f`.

**Not known, not done.** Whether the DDR3 calibrates in this build on the
card: nothing but the full build has run it. The socket PHY has run on
hardware only at 110 MHz; at 105 MHz its points are the same counts of a
clk 4.8 % longer (in simulation at 100, 105, 108 and 110 MHz). The round trip's real length.
What a program's working set does to a 16K-entry cache of single bytes when
a miss costs 25 clks and brings one byte (the arbiter returns a 32-bit
word, of which three bytes are dropped). Not run on hardware. (It has
been since: section 3c.)

## 3c. The DDR3 build on hardware: a crash, its cause, the benchmark (2026-11-13)

k0 was flashed at 14:14 with the IIgs off (first attempt, verified) and
the card power-cycled. ROM 01 machine, the a2p25 beside it, as section 3.

**What worked at once.** Telemetry word 12 reads `057E`: the DDR3
calibrated, the queue never overflowed, 126 banks. The socket PHY at
105 MHz: armed 22 ms after the slot's /RESET rose, no stall. Key and copy:
one copy, sum `7EE8`.

**The first switch to card memory crashed the machine.** GS/OS was up and
the benchmark at its prompt. Register 29 = `0x0A` (card memory at PHI2
pace, verify on): inside two seconds the verify count was at its ceiling
(65,535), the core was executing in bank 67, the keyboard dead. Back to
`0x08` (socket bytes; fast mode had not run) and a reset.

**What the monitor cleared.** From the IIgs monitor, with card memory on
for the reads: a 64K fill of bank 02 and its dump; single bytes in every
lane of the DDR3's word in banks 02, 04 and 08; a bank of `EA` executed
end to end (65,535 steps) and a bank of `AD` (21,845 instructions) in bank
04. Nothing wrong. Then GS/OS again with the benchmark at its prompt, in
card memory at PHI2 pace: eleven short pulses, then 7 s, 30 s and 240 s
without a mismatch. So the DDR3, the queue, the byte lanes and the tagging
of the high banks are good on hardware, and the crash did not come back.

**The cause: an entry that held nothing carried the tag of RAM at
7F/C000-FFFF.** An empty near-memory entry was marked by a tag of all
ones. That was no byte's tag while the tag held A14-A17: RAM has a zero in
the first of its two leading bits, ROM in the second. Section 3b marks RAM
above bank 03 with both set, and all ones became a real tag: {1, 1} and
A14-A22 all ones is the top 16K of bank 7F. The entries are empty at
power-up (the block RAM's zeros, stored inverted) and after a ROM copy,
which empties all 16,384. A read of 7F/C000-FFFF then found its index
empty and took the empty entry's byte for the memory's. GS/OS keeps code
and data at the top of the last bank (the socket showed `7F/C363` in use),
so the first card-memory run after the copy went wrong at once. The
monitor's fills had rewritten every one of the 16,384 indices with real
entries, which is why nothing failed afterwards: the fault needs an entry
that is still empty.

The bench did not have it. Its expansion memory stopped at 16 banks, its
runs used 8, and an empty entry's byte was 00, the same as memory nothing
had written.

**The fix.** The empty entry has a tag of its own (`NM_EMPTY` in
`gs_accel_broker`): with the split tag, {1, 1} and A18-A22 all zero, a
combination no byte has, because {1, 1} is only ever written for RAM with
one of those bits set. (Without the split tag it stays all ones.) The
broker writes it on a flush and for a byte the tag cannot name. In
`gs_accel` the five high address bits are now stored as they are and the
fourteen others inverted as before, so a block RAM's power-up zeros read
as exactly that tag. No logic is added; the first-clk compare is as it
was.

In the bench: the expansion memory reaches bank 7F (`EXP_MAX = 126`); an
empty entry's byte is `EE`; one byte of bank 7F holds `D9` in every memory
model before anything runs. The test program has T24: it reads that byte
(nothing has written it), writes and reads 7F/E100 against bank 00's
6100 at the same index, and reads both again on every pass of its loop,
so a ROM copy in the middle of the run (`+recopy`) empties the near memory
under them. Two builds have all 126 banks at 105 MHz (`b105_2t`, and
`b105_2k` with the ROM image empty for `+mode=copy`), `gs_accel` beside
the design in both. And in every simulation build the broker checks at
elaboration that the empty tag is no RAM page's and no ROM page's, for the
parameters it is built with.

Before the fix, on those builds: PHI2-paced, fast and toggling runs fail
at the read of the unwritten byte (the broker delivers the empty entry's
`EE`), and the copy-again run fails at 7F/E100 in the first loop pass
after the second copy ("the broker delivered 00, the ideal machine holds
7e") - the crash of this section. With the broker fixed and `gs_accel`'s storage left as it
was, the pin comparison fails (`gs_accel` answers 00 out of an entry its
block RAM powered up with). With the fix, the broker suite passes 152 of
152 runs (the 140 of section 3b, eight of T24's on the two new builds, and
a ROM 01 boot with 126 banks in native, paced, fast and copy mode: the
step hash `6012b76169ecc820` and the 128,393-write stream of every other
boot). The decode sweep (981,101,952 vectors), the replica benches and
both socket benches pass.

**The benchmark on k0** (the bitstream with the defect, after the
monitor's fills, so with no empty entry left; fast mode on at 15:10:41).
The program was run twice, both passes in fast mode. 60ths of a second;
"machine" is the base pass of section 3, "fe2" the block-RAM build of
section 3a:

| test | machine | fe2, fast | k0, first pass | k0, second pass | against the machine | against fe2 | the program's MHz |
|---|---|---|---|---|---|---|---|
| 10 iterations of the sieve | 413 | 318 | 33 | 33 | 12.5 | 9.6 | 31.59 |
| selection sort of 500 strings | 1159 | 795 | 88 | 88 | 13.2 | 9.0 | 33.22 |
| 100 iterations of a floating-point test | 476 | 38 | 35 | 35 | 13.6 | 1.09 | 36.73 |
| 15,000 Gamm units | 1546 | 240 | 130 | 130 | 11.9 | 1.85 | 31.63 |
| 10 iterations of Fibonacci calls | 2020 | 1401 | 158 | 158 | 12.8 | 8.9 | 32.24 |
| 5,000 iterations of integer math | 1564 | 853 | 115 | 114 | 13.6 | 7.4 | 34.61 |

The program's average is 33.34 MHz (fe2: 11.03). The four tests that run
the program's own code in bank 04 are nine times faster than on fe2, which
took every one of those steps from the socket; they are now within ten
percent of the floating-point test, whose work is in the ROM and bank 00
and was the card's already. One tick is three percent of the short tests.
At the program's prompt the core steps 15.4 M times a second and takes
0.45 M socket cycles a second of the machine's 1.68 M; 9.5 M reads a
second are answered by the near memory and 0.5 M are not. The queue in
front of the DDR3 did not overflow (word 12 still `057E`).

**The fixed source, built.** Three placements at 105 MHz, no setup or hold
violation in any (worst slack +0.024, +0.002 and +0.018 ns; the tool
stops when the constraint is met). Size as k0 (11,050 logic cells, 11,416
FF, 192 block RAMs). Build m0: stamp `20261113175022`,
bitstream sha256 `aaa7ca899b7fcd5a…bdfa95db0a7fa73711`. (On k0 a ROM
copy or a power cycle leaves empty entries again; a 64K fill from the
monitor after the copy and before card memory goes on,
`00<02/0000.FFFFZ`, rewrites every index - the card follows every write -
and is what the run above rested on.)

**The fixed build on hardware** (m0 flashed 18:17 to 18:21 with the IIgs
off, first attempt, verified; the card power-cycled). Word 12 `057E`, no
stall, copy sum `7EE8`. Then the step that crashed k0, with nothing
written from the monitor: GS/OS up, the benchmark at its first prompt,
card memory at PHI2 pace straight after the copy for 5 s and for 60 s -
verify count 0, no mismatch address. The benchmark's base pass was run on
socket bytes (register 29 = `0x08`), so it is the machine's; at the
program's prompt for the speed, card memory for 20 s more (verify count
still 0) and fast mode at 18:34:35:

| test | base | m0, fast | ratio | the program's MHz |
|---|---|---|---|---|
| 10 iterations of the sieve | 413 | 33 | 12.5 | 31.59 |
| selection sort of 500 strings | 1159 | 88 | 13.2 | 33.22 |
| 100 iterations of a floating-point test | 476 | 35 | 13.6 | 36.73 |
| 15,000 Gamm units | 1546 | 130 | 11.9 | 31.63 |
| 10 iterations of Fibonacci calls | 2020 | 158 | 12.8 | 32.24 |
| 5,000 iterations of integer math | 1564 | 114 | 13.7 | 34.61 |

The program's average is 33.34 MHz, and every time is k0's: the fix adds
no logic and costs nothing. The base pass is the base pass of section 3
to the tick. Rates at the prompt as on k0 (15.4 M steps a second, 0.45 M
socket cycles). The build has no stamp that can be read over telnet: that
m0 is what runs rests on the verified flash, the power cycle (the verify
count, which only a reconfiguration clears, was back at 0) and the step
that no longer fails. No access to bank 7F was among the socket samples
taken during the 65 s, so the bench (T24) and the benchmark are the
evidence for that RAM, not those seconds alone.

Entered as 52.5 MHz, the program expects the sieve in 19.9 ticks and gets
33; its average of 33.34 MHz is 64 % of the step rate. What the rest is
spent on (socket cycles, near misses that bring one byte from the DDR3)
is not measured yet.

**Not known, not done.** A run longer than
the benchmark. The round trip's real length, and what a larger working
set does to the 16K entries. The DDR3's power-on self-test writes sixteen
bytes of its pattern at 40/0000 before the card is armed; nothing reads
them back before writing, as far as is known, and they are still there.

## 3d. Where the step rate goes (2026-11-13, m0 on the card)

The benchmark's 33 MHz against 52.5 MHz steps, measured: the card's
counters (telemetry words 0 to 5 and 11) logged over the console 2.4 times
a second while the program ran ten rounds twice, both passes in fast mode
(20 rounds, 567 samples inside the run). The tests show as plateaus; the
two shortest (sieve, 0.55 s; floating point, 0.58 s) are a sample or two
each and the sieve is not resolved.

| test | steps, M/s | the program's MHz | socket cycles, M/s | reads not in the near memory, M/s | clks per step |
|---|---|---|---|---|---|
| selection sort | 32.7 | 33.22 | 0.008 | 0.007 | 3.21 |
| Fibonacci calls | 31.8 | 32.24 | 0.008 | 0.003 | 3.30 |
| integer math | 33.9 | 34.61 | 0.008 | 0.002 | 3.09 |
| floating point (10 samples) | 35.4 | 36.73 | 0.204 | 0.376 | 2.97 |
| Gamm units | 31.1 | 31.63 | 0.193 | 0.579 | 3.38 |
| at the program's prompt | 15.4 | | 0.453 | 0.498 | 6.83 |

**The program's MHz is the step rate**, test for test, within four
percent. To pass 48 on this program the core has to step 48 M times a
second while it runs.

**In the three tests that only compute, the loss is one thing: a step in
banks 04 to 7F takes four clks, not two.** They take 8,000 socket cycles a
second (about one percent of the time) and miss the near memory a few
thousand times a second, and still average 3.1 to 3.3 clks a step. The
bench says why (`---- step lengths`, new in `tb_gs_broker`, with code and
data in bank 04 called from the test program's loop): a read or a write in
banks 04-7F that hits the near memory completes in exactly 4 clks, every
time, where a step of the cheap view completes in 2. Section 3b chose
that: the five high tag bits are read a clk after the rest and only the
registered compare sees them, so no step in those banks is the cheap
view's. With 2 clks for a step elsewhere and 4 there, 3.1 to 3.3 clks a
step is 55 to 65 % of the steps in bank 04 and above - the program's code
and data (section 3b sampled 70 % of its steps in bank 04). Of the time:
62 % is the two clks every step has, 37 % the two more on steps in the
high banks, 1 % socket cycles.

**In the two floating-point tests** 41 % (Gamm) and 33 % of the time is
not a two-clk step: 0.2 M socket cycles a second and 0.4 to 0.6 M reads a
second that are not in the near memory. The counters cannot split the two
(no counter of clks, only of events; a fit over the two tests gives about
80 clks for a socket cycle and 50 for a miss, from ten samples of one of
them). What the socket cycles are is not known; a toolbox call goes
through bank E1, the machine's, and that is the first guess.

**At the prompt** the program polls the keyboard: 0.45 M socket cycles a
second, each a cycle at the machine's slow rate.

**What follows.** A two-clk step for a near-memory hit in banks 04-7F
would take the three computing tests from 3.2 to about 2.05 clks a step:
some 51 M steps a second, 51 on the program's scale. It needs the high
tag bits in the first-clk decision (or one bit that stands for them), and
that compare is the path the 105 MHz build closes by 0.02 ns; a three-clk
step there (35 MHz in those banks, about 40 M steps a second on these
tests) is the smaller change. For the floating-point tests: counters of
clks by kind of step, to split socket cycles from misses before choosing.
The first is written (next paragraph); the rest is not done.

**The two-clk step in the expansion banks: written, verified in
simulation, not durable in timing (2026-11-13, evening).** The tag is
whole again (`NEAR_SPLIT = 0`, now a parameter of `gs_accel`; the split
tag of section 3b is kept as the other value): data, {ROM, A12 moved} and
A14-A22, nineteen blocks, all read with the core's next address. The
cheap view (`gs_mmu_decode` `fast_exp`) takes a read or a write in any
bank the card backs while only banks 00/01 shadow (CYAREG bit 4 clear):
plain RAM at its own address. The five tag bits this adds to the first-clk
compare are compared against the address register directly, gated by
A23, not through the cheap view: a RAM step's high bits are the
address's, a ROM step's are zero and its bank has A23 set or is 00/01.
Where expansion steps are the cheap view's, every cheap step waits for
room in the expansion memory's queue. The empty entry is all ones again.

In the bench a hit in banks 04-7F is two clks (the test program's bank 04
code: 51,528 two-clk steps where the split tag had 40,093, no four-clk
read left). 155 runs pass, the ROM 01 boot with 126 banks at the same step
hash; the decode sweep has 85,994,305 expansion vectors (the physical
address, no ROM, no fold, the bank's own bit 0) and no failure; replica
and socket benches pass. Seven mutations of the new logic, all detected -
one (the bank bit taken from RAMRD in an expansion bank) only after the
sweep gained a check and the test program a write in bank 04 with RAMRD
and RAMWRT set.

Timing, with all nineteen blocks placed (R46 / R64, sites 16 to 22): the
rule is three placements with no violation, and it is not met.

| clock | placement 0 | placement 1 | placement 2 |
|---|---|---|---|
| 105 MHz | +0.002 | 73 paths, -1.069 ns | +0.002 |
| 100 MHz (`ACC_CLK_100`, new) | +0.012 | 25 paths, -0.743 ns | +0.034 |

The failing placement is the same perturbation at both clocks, and what
fails in it is not the new logic alone: three-level paths in the PHY and
the ROM copy with 7 ns of wire, the near memory to the core, the core to
the near address. A first build with three of the blocks left to the
placer (it put them in R28) and the high tag bits through the cheap view
failed by 0.79 ns on 95 paths. So: the design was at the edge with
fourteen near blocks, and nineteen tip some placements over; 5 % of clock
does not buy it back. Not flashed. Ideas not tried: a ten-bit tag (ROM
coded as "A12 moved" with A22, eighteen blocks, no site 16); a three-clk
step for these hits on the split tag's fourteen blocks (about 40 M steps a
second on the computing tests where two clks would give 51 M).

**A defect found on the way, in the source only so far.** The bank 04
code changed which step a second ROM copy lands on in the bench's
copy-again run, and that run failed: the step that was held for the copy
read its byte from the socket. `gs_accel_romcopy`'s `valid_o` drops when
a copy starts, the grants of fast mode and card memory dropped with it,
and the one step held across the copy ran as a socket step - of a machine
whose RAM is stale once the card's memory has been the memory of record.
A first copy is not affected (nothing has been granted yet), and neither
is anything this page's ladder does; it takes a second copy asked for in
fast mode. Now the grants stand on `usable_o`: a complete image, or a
complete image being copied again (nothing is written before the core is
held, and it is held until the copy is complete). In the bench the second
copy can be asked for at any step (`+recopyat`): 45 points on two builds
pass, two of them fail without the change, and three are in the suite
(155 runs, all passing). **m0, on the card, has the defect; the change is
not built.**

## 3e. The near memory as lines of sixteen bytes (2026-11-13/14)

The DDR3 answers every read with sixteen bytes, and the near memory of
sections 3b to 3d kept one of them. It also kept an 11-bit tag beside
every byte: 19 bits a byte, nineteen blocks for 16 KB, and nineteen blocks
on the core's next address are what the two-clk step of section 3d could
not carry on every placement. This build (`NEAR_LINE` in the broker and
`gs_accel`; the default of the board top, `ACC_BYTE_CACHE` in the defines
goes back) makes the near memory lines.

**What it is.** 1,024 lines of 16 bytes, one tag for a line: eight blocks
of 1K x 16 for the eight words of a line, one block of tags. Nine blocks,
with ten or eleven address bits each where the entries had nineteen with
fourteen. A hit is as it was: the tag read with the core's next address,
compared whole in the step's first clk. Each data block's read port is a
byte wide (the primitive's ports need not be one width) and gives its
word's byte; which word is picked by address bits 3 to 1, a register.

**A miss brings the line.** Every far read is of sixteen bytes:

- the DDR3's through the arbiter's burst read, which is one read of the
  memory handed over as its four words (the top collects them; the queue,
  `gs_accel_exp` with `LINE`, is otherwise as it was, writes one byte each);
- the block memories' (banks 00/01, the ROM image) because they are now
  sixteen bytes wide: for each word of a line as many blocks of 1K x 16
  as there were blocks of 16K x 1 for a bit, a byte write being one byte
  of one of them. The same 64 + 64 blocks.

The broker takes its byte as before and the line is written into the near
memory in one clk, the clk before the step ends, through a register (the
far memories' two thousand outputs are muxed where they are; 128 bits go
to the blocks beside the core).

**A line is there whole or not at all, and always equal to the far
memory.** A write always goes to the far memory. In the near memory it
changes its byte if the line is there - the tag read at the launch of the
write's own step says so - and does nothing if it is not: there is no
write that installs. Two cases empty the line instead: the tag read at the
launch is not to be trusted (it was written at or since the launch), and
the byte lives under another index ($Cxxx of banks 00/01, kept under the
$Dxxx index as before). A read launched in the clk of, or before, any
write to its line is not used. The ROM copy empties 1,024 tags.

**`gs_bram16be`.** Written as an array with two write enables, a 1K x 16
memory became two blocks under GowinSynthesis, one a byte: the first build
used 318 of the 340. The primitive (SDPB) has the byte enables in the low
address bits of its write port; the module instantiates it and simulation
has the array.

**In the bench** (the test program, 126 banks, fast mode, against the
whole-tag byte memory of section 3d): 545 far reads where there were
4,213; 249 reads of the expansion memory where there were 2,338; 98.6 %
of local steps two clks. The ROM 01 boot fills 225 lines where it filled
2,433 bytes and reaches the same step hash with the identical write
stream, on the DDR3 build and on two builds with block RAM alone.
176 runs pass (21 new), the decode sweep and the other benches are as they
were. Eight mutations of the line logic, all detected - one (a write made
in the very clk the next read of its byte is launched) after the test
program gained self-modifying code in a page whose writes are not the
cheap view's ($6200).

**Not in any bench:** the top's collecting of the four words (the order of
the arbiter's beats is read from its source, `ddr3_ports`). On hardware
the PHI2-paced card memory of the ladder checks it: every byte the DDR3
returns is compared with the machine's. A PHI2-paced step fills no line
(a line is filled by a fast step), so in that mode every read of an
expansion bank goes to the DDR3 - slower, and a longer test of it.

**Timing: three placements at 105 MHz with no violation, after six
rounds.** The array form (318 blocks, no floorplan) failed by 7.6 ns.
With the primitive and the nine blocks placed (R46 / R64 sites 18 and 19,
the tags in R46[20]) 34 paths failed by up to 0.18 ns and the build took
half an hour. Then the fill register, the byte-wide read port and a copy
of the far write data for each word: 14 paths, 0.18 ns. Then the first-clk
compare in two registers (`fh_q`: the tag's address bits against the
address register; `fx_q`: the four bits the cheap view makes) and the
verify copy of the card's byte declared the two-clk path it is: two
placements of three clean, the third 1.31 ns short on 97 paths; the same
source at 100 MHz (`ACC_CLK_100`), two of three, the third 0.22 ns short.
That one named the cause: its worst path, the tag block to the compare,
was 2.0 ns of logic and 5.6 ns of wire - the tags were in R46 beside the
core and the broker is placed below it, twenty rows away. With the tag
block in R64[20], on the core's second copy of its next address like the
odd words there:

| placement | 0 | 1 | 2 |
|---|---|---|---|
| worst slack, ns | +0.000 | +0.002 | +0.006 |

(The tool stops when the constraint is met.) 13,088 logic cells, 11,842
FF, 182 of 340 block RAMs. Build t0: stamp `20261114020946`, bitstream
sha256 `dd5d16229b2438a8…6339edea96909e7720`. **Flashed 2026-11-14
08:50 to 08:53, IIgs off, first attempt, write verified; section 3f is
its run on the machine.** It carries
everything since m0: the line memory, the two-clk step in every bank the
card holds, and the ROM copy's grant across a second copy (section 3d).
What to expect of it on the benchmark is section 3d's arithmetic - about
2.05 clks a step where the computing tests have 3.2; section 3f has what
the machine gave.

## 3f. The line memory on the machine (2026-11-14, t0 on the card)

Flashed 08:50 to 08:53 with the IIgs off, the card power cycled, ROM 01.
The ladder of section 3, in order:

| step | result |
|---|---|
| DDR3 | word 12 = `057E` |
| ROM copy (register 29 = `08`) | one copy, sum `7EE8` |
| card memory, paced, verify (`0A`), 5 s | no mismatch |
| the same, 60 s | no mismatch; the last bus address seen in banks 00, 02, 03, 04, E0, E1, FE, FF |
| the same, 4 s, then fast (`0B`) at the benchmark's prompt | no mismatch; the machine runs on |

Paced card memory fills no line, so every read of bank 04 in those holds
went to the DDR3 through the top's four-beat line assembly and was
compared with the machine's byte. That assembly has no bench; this is
its first test, and it is a narrow one (what the machine read in 70 s at
a prompt and through one base pass's start).

The benchmark's fast pass (one round, 52.5 entered) ran to its report.
Counters over the pass, sampled each 0.42 s:

| | |
|---|---|
| the pass, first test to report | 8.74 s |
| core steps | 315.1 M = 36.05 M a second = 2.91 clks a step |
| socket cycles for the core | 1.564 M |
| near memory hits / misses | 202.3 M / 0.359 M |
| best samples (no socket cycles) | 45 to 49 M steps a second = 2.15 to 2.33 clks a step |
| samples with socket cycles (0.2 M a second) | 30 to 37 M steps a second |
| verify mismatches, word 7 | 0 |

So the computing stretches run at 45 to 49 M steps a second where m0 had
31 to 34 (section 3d), and the stretches with socket cycles are where m0
had them, about 35. One round is too short to give each test its own
rate: a test lasts one to six samples. At the prompt the rate is 15.6 M a
second as before (the prompt's loop is socket cycles).

The program's report for the same pass (TML Pascal benchmark, one run,
times in its ticks; the base pass with register 29 = `08`, the fast pass
with 52.5 entered; m0's column is section 3c's):

| test | base | t0 | m0 | t0 against base | "Actual MHz" t0 | m0 |
|---|---|---|---|---|---|---|
| sieve, 10 iterations | 413 | 21 | 33 | 19.7 | 49.65 | 31.6 |
| selection sort, 500 strings | 1159 | 60 | 88 | 19.3 | 48.72 | 33.2 |
| floating point, 100 iterations | 476 | 34 | 35 | 14.0 | 37.81 | 36.7 |
| Gamm, 15000 units | 1546 | 115 | 130 | 13.4 | 35.76 | 31.6 |
| Fibonacci calls, 10 iterations | 2020 | 110 | 158 | 18.4 | 46.31 | 32.2 |
| integer math, 5000 iterations | 1564 | 86 | 114 | 18.2 | 45.88 | 34.6 |
| the program's average | | | | | **44.02** | 33.34 |

(m0's "Actual MHz" here is 52.5 x expected / measured from its times, as
the program computes it.) Two tests are above 48 and the average is 84 %
of the 52.5 MHz step rate, where m0 had 64 %. The two floating point
tests are the ones with socket cycles in the counters above, and they
hold the average down: 34 and 115 ticks where two clks a step would give
24 and 78.

## 3g. What the floating point tests wait for (2026-11-14, t0 on the card)

A second run, ten rounds, the card in fast mode throughout. The program's
times: sieve 20.8, sort 59.4, floating point 33.9, Gamm 115.1, Fibonacci
109.8, integer 85.6; average 44.24 MHz. (Its base column in that run is
not a pass the counters saw - one pass of 88 s is all that ran - and
means nothing.)

During the run the console read the address of the last cycle the card
put on the socket about ten times a second (`last_addr` in `gs`), with
the telemetry words between. A park cycle is a read of `FF/0000`, so
bank FF in a sample is an idle socket and any other bank is a cycle of
the core's. The three address bytes are read one after another and come
from different cycles: the bank is a fair sample of where the socket's
time goes, a whole address is not.

| stretch | steps, M/s | socket cycles, M/s | misses, M/s | PHY cycles, M/s | bank of the sample |
|---|---|---|---|---|---|
| Fibonacci, integer (18 s, 168 samples) | 45.8 | 0.008 | 0.001 | 2.83 | FF 100 % |
| floating point, Gamm (13 s, 120 samples) | 34.9 | 0.219 | 0.132 | 2.31 | FF 74 %, E1 21 %, E0 5 % |
| between tests (15 s, 136 samples) | 28.4 | 0.288 | 0.014 | 2.11 | FF 60 %, E1 38 %, E0 2 % |
| the prompt (220 s, 2,040 samples) | 15.6 | 0.461 | 0.183 | 1.63 | FF 41 %, E1 31 %, E0 26 % |

What it says:

- **The core's socket cycles in the floating point tests are in banks E1
  and E0, and nowhere else.** Those are the machine's slow memory: the
  machine stretches each such cycle to its 1 MHz side. From the PHY
  count, an idle cycle is 351 ns and a cycle of the core's in these
  tests 1.2 us.
- **They are the whole of what the floating point tests lose.** The
  socket is the core's for 26 % of the time (the samples), 0.26 s in a
  second (the counts), and the core also waits for the idle cycle in
  progress before each one. 105 M clks less 30 % leaves 2.1 clks a step
  for the 34.9 M steps: the same step the computing tests have.
- The page and low bytes that are not a park cycle's fall in page 00
  (`00` to `03`, `64` to `6A`, `C0`, `C1`, `DE`, `EF`, `FF`), page 03
  (`C0`, `C8`, `CA`) and page 1D. That is the look of the tool
  dispatcher: `JSL $E10000`, the vector there, the tool locator's
  pointers at `E1/03C0` and up, a table in `E1/1Dxx`. SANE is a tool
  set, and every floating point operation is a tool call. It is a
  reading of torn samples, not a trace.
- Between tests the cycles are spread over `E1/2000` to `9FFF`: the
  program drawing on the super hi-res screen. Not in any test's time.
- The computing tests take 2.29 clks a step with no socket cycle and no
  miss to speak of: one step in seven or so is longer than two clks, and
  the counters do not say which.

Two things would raise the average, then:

1. The card holding a copy of the RAM of banks E0/E1 and answering
   reads from it, writes still going to the machine. The replica already
   has the Mega II's side of the map (`gs_mmu_decode`, `slowram_*`), the
   posted write already exists, and paced card memory would verify the
   copy as it verifies banks 00/01. It makes memory fast that is slow on
   the machine and on a TransWarp GS: a decision, so a request bit. By
   the arithmetic above the two floating point tests would come to 24
   to 26 and 81 to 85 ticks and the average to about 49.
2. Finding the steps of plain computing code that take more than two
   clks (the bench has a histogram of step lengths).

### A second benchmark: A2Desktop's (the same day)

A2Desktop's benchmark desk accessory (`src/desk_acc/benchmark.s` in
a2stuff/a2d) reads the card at about 36 MHz. Its loop counts passes in
one video frame, and one pass is 176 cycles of plain code (a counter and
a 32-turn spin, put there so that a IIgs's slow read is a small part)
and **one read of `$C019`**, with 97 passes a frame taken as 1 MHz. On
the card that is 176 local steps and one socket cycle in I/O space,
which the machine fits to its 1 MHz side. So a pass can only be a whole
number of the Mega II's cycles (0.98 us): 176 steps at 52.5 MHz are
3.35 us, the read takes the rest of five cycles, 4.90 us, and the frame
holds 3,406 passes: 35.1. Four cycles would read 43.9 and want the 176
steps and the read inside 3.92 us, about 62 MHz of steps; six would
read 29.3. The reading therefore says nothing fine: a band of step
rates some 15 MHz wide reads 35.1, from the mid or high 40s to about 60
(where the band's ends are depends on the fixed part of the read, which
is not measured: 0.6 to 1.4 us is the range considered). This is arithmetic
from the source and the counters above, not a measurement of the loop:
with the accessory open the card shows the core's socket time in bank
00's I/O page (`C019` the most common low byte), each such cycle about
1.8 us of socket time.

### What the machine itself offers for slow memory (the same day)

Looked up after the two benchmarks, in the Apple IIGS Hardware Reference
(second edition, chapter 2) and Apple IIGS Technical Notes #70 and #72:

- **No switch makes banks E0/E1 fast.** "Because the memory controlled
  by the Mega II contains the display buffers, it always runs at the
  1.024-MHz speed." A Mega II cycle is taken for "all external and most
  internal I/O operations", shadowed video writes, inhibited memory
  accesses and "Mega II memory accesses to banks $E0 and $E1".
- **The machine's own answer is shadowing**: a fast copy in banks 00/01
  that is read at full speed, with each write repeated into E0/E1. The
  Shadow register (`$C035`) chooses the regions - the text pages, the
  hi-res pages, super hi-res, the auxiliary hi-res pages, and I/O with
  the language card - and bit 4 of the Speed register (`$C036`) extends
  it to every RAM bank ("for proper operation of the Apple IIGS
  operating system, this bit must always be set to 0"). QuickDraw II
  uses it when asked: bit 15 of the MasterSCB given to `QDStartUp`
  "requests that QuickDraw II use the memory at $012000 to shadow onto
  the real screen memory at $E12000", which "speeds up QuickDraw II,
  since memory in bank $01 can be read at full speed" (TN #72). The
  regions are video and I/O only: nothing shadows `E1/0000` to `1FFF`,
  where the tool dispatcher's vectors and tables are.
- **Some I/O is fast by design**: "Certain registers internal to the FPI
  (the DMA register, the Speed register, and the Shadow register) are
  read and written at high speed. Similarly, reading the interrupt ROM
  addresses ($C071 through $C07F) does not slow the system. In addition,
  two registers (the State register and the Slot ROM Select register)
  ... are written at 1.024 MHz and read at 2.8 MHz". `$C019` is not
  among them. On the card these all go to the socket, where the machine
  gives them a fast cycle; the replica holds the same registers, so
  their reads could be answered on the card.
- The cost of one slow cycle is the manual's: up to 1 us of waiting
  (0.5 average) for a single Mega II cycle, and consecutive ones at
  1.024 MHz. TN #70 describes the notches of the A2Desktop reading:
  "one loop writing data to the graphics memory may run at the same
  speed as a second loop with a higher cycle count".
- The ZipGS's registers (`$C058` to `$C05F`, from the 6502bench symbol
  file) have a language card cache bit, delays for slots, speaker,
  paddles and counters, and nothing for E0/E1. What the TransWarp GS
  does there was not found in a document that could be read (its
  manuals are scans, its programmer's reference did not load).

So a card copy of E0/E1 RAM for reads is the machine's shadowing idea
carried to memory Apple did not shadow. It has no official switch.

## 3h. A copy of the Mega II's RAM on the card (2026-11-14, built and simulated; timing not closed; not flashed)

Section 3g: what the floating point tests lose is socket cycles in banks
E0/E1, the machine's slow memory, most of them the tool dispatcher's
reads. The machine's own answer to slow memory is a fast copy that is
read while writes go to both (shadowing, section 3g), and this is that,
for the RAM of E0/E1 itself. Ed's decisions: the copy in the DDR3 behind
the ordinary near memory, not in block RAM; and a switch that can be
turned on and off while the machine runs, to be a setting of the OSD.

**What it is.** The card keeps a copy of the Mega II's RAM below `$C000`
of banks E0/E1 - 96K: no I/O, no slot space and no language card are
there - in the DDR3's first 128K, which the 126 expansion banks leave
free (the card's banks 00/01 are block RAM). To the far path, the fills
and the near memory it is two more banks of expansion memory; its lines
have tags of their own, taken from codes the ROM's tags leave unused, so
the tag is no wider and the step's first clk has nothing new in it but
one term of the socket-only test.

**The copy follows the machine in every mode, whatever the switch says:**

- a write to E0/E1 is the socket cycle it always was, and its byte goes
  to the copy when that cycle completes (as a native step's write does:
  a step that /RESET cuts short writes neither);
- a write the FPI shadows from a bank the card holds - stored there and
  posted to the socket, as before - is repeated in the copy at E0 + the
  low 17 bits of its address, a clk later (a step is two clks and no
  read is launched within two clks of a write, so that clk is free even
  when the write is the expansion memory's own: a shadowed write in an
  expansion bank, `CYAREG[4]`). If the near memory holds that line of
  the copy it gets the byte too: the same index, the same byte of the
  line;
- a write the FPI shadows from a bank the card does not hold is a socket
  cycle and a write of the copy alone.

**The switch only says where a read comes from** (request bit 4, SLOW):
the socket, as before, or the copy - a local read like any other, a near
hit (four clks: not the cheap view's two) or a far read that brings its
line from the DDR3. The broker takes it when the core steps. Neither
the machine's RAM nor the copy is ever stale, so it may change at any
step, in either direction, any number of times. That is unlike FAST,
which leaves the machine's banks 00/01 behind and cannot be taken back
without a reset.

It is granted when card memory is in effect, the DDR3 was ready at the
machine's last reset, and nothing has been lost from the DDR3's queue
since (telemetry word 13). What the machine's RAM held from before that
reset the copy does not have: after a power-up that is RAM nothing has
written.

**Checking it on the machine** is paced mode with the switch on
(register 29 = `1A`): every read of that RAM is then the card's and is
compared with the byte the socket returns, as banks 00/01 are in `0A`.
Mismatches in E0/E1 have a count of their own (word 13) and the address
of the last (word 14). Unlike the count for banks 00/01 it means
something at any time, also after fast mode has run. While such a step
waits for the DDR3 its socket cycle, a read of RAM, is issued again, as
an expansion bank's is.

What is not in it, and was said to be when the switch was proposed: a
comparison while the switch is off in fast mode. It would need a far
read beside each socket cycle, in the sequencer's tightest part.

**Departures from the machine, all with the switch on:** reads of E0/E1
below `$C000` take four clks or a DDR3 read where the machine takes a
cycle of its 1 MHz side - software that times itself by the slow memory
sees it; and the machine no longer sees those reads at all (park cycles
in their place). Writes, `$C000` and up, and everything with the switch
off are as before, cycle for cycle. One exposure is the posted write's:
a shadowed write that /RESET drops from the buffer is in the copy, as it
is in the card's bank 00/01, and not in the machine.

**The model it rests on.** Which byte of the Mega II's RAM an access to
E0/E1 or a shadowed write reaches is the replica's decode
(`gs_mmu_decode`, the MiSTer core's), with the bank latch and the IIe
switches. Nothing on the card depended on that part of it before. It
agrees with the bench's machine, which is the same model; the machine
itself checks it in paced mode. One case where the Hardware Reference
reads differently from the model: a shadowed write to bank 01 with the
bank latch off, where the model has the Mega II take the bank bit and
the manual has it ignore it.

**Simulation.** The board-configuration builds of the broker bench
(`b105_2t`, `b105_2k`) keep the copy in every run and compare it with
the ideal machine's Mega II RAM at the end, and gs_accel's with the
design's; the `k_`, `j_` and `m_*_c` runs read from it (`+slow=1`) or
switch the request through the run (`+slow=2`): every mode, resets,
stalls, the DDR3 slow and its queue held, the ROM image read through the
socket, the card backing no bank, two and 126. The test program has a
test of every way into that RAM (T25: a shadowed write with the copy's
line in the near memory and without, a read-modify-write in the bank,
the bank latch off with the IIe switches, ALTZP, a block move over
itself). As everywhere in this bench, every byte delivered to the core
is compared with the ideal machine's and every socket cycle with the
cycles the program owes.

Results, on the source of the last timing round (y, below): the broker
suite 210 of 210 runs; in the ROM 01 boot of 3,000,000 steps the runs
with the copy read (`m_fast_c`), switched through the run (`m_fast_sw`:
the request changed 6,507 times), paced with it (`m_paced_c`) and with
the ROM copied (`m_copy_c`) reach the native run's point (step hash
`6012b76169ecc820`) with its stream of 128,393 writes; the test program's
six `j_` runs likewise. `gs_accel` beside the bench's design in 143 runs,
2,038,229,843 clks of pin comparison, no difference. The decode sweep
runs every Mega II and expansion vector three times (no copy, the copy
with the switch off, and on): 1,875,164,248 tests, no failure. Replica,
socket, arming and the ten core benches pass. Twenty-six mutations of
the new logic (the decode's rules, the store at the cycle's end, the
repeat of a forwarded write, the twin update of a cached line, the tags,
the address map, the grant), each run through thirteen runs: all
detected.

What the switch changes in simulation: the test program, which spends
much of its time in E0/E1, averages 20.49 MHz with it and 7.04 without
(4,123 reads of that RAM, 313 of them far reads). The ROM 01 boot hardly
reads that RAM: 6.58 MHz with it, 6.52 without.

**Timing and size.** **Three placements with no violation at 105 MHz were not
reached, so by this project's rule the build does not count and nothing
was flashed.** Ten placements over four rounds, five clean:

| round | source | placements |
|---|---|---|
| v | an earlier source | +0.006 (one build) |
| w | the first complete source | 13 paths, -0.212; +0.008; +0.001 |
| x | the write registers' two clks stated (below) | +0.000; 24 paths, -0.201; +0.002 |
| y | x and the registered tag (below) | 48 paths, -0.348; 52 paths, -0.354; stopped at 40 min in routing |

Round w's failure was the new logic: the step's address through the full
decode into the write registers (`whit_r`), nine levels. Those registers
are loaded with a value that is used no sooner than the third clk of a
step, so the paths into them are two-clk paths; that is now said in the
constraints (`gen_sdc.py`) and held to in simulation (`wr_bad`: what
they load earlier reads wrong, and a write made with it shows). In
round x that path has 6 to 8 ns to spare, and what failed in x1 is what
was at the edge before this section: the tag block to the first-clk
compare, the compare to the core's clock enable, in a placement that
spread the core over thirty rows. Round y took the two later compares
off the tag block's outputs (`rtag_q`, a registered copy of the tag for
the full decode's compare and the write's): no help - both placements
that finished failed across the design (the PHY to the ROM copy, the
DDR3 controller's own write buffer, the core's two-clk paths), with the
worst path the same tag compare at 2.0 ns out of the block RAM, 1.6 ns
of logic and 5.7 ns of wire.

So: t0 closed three of three with +0.000 to +0.006, which is no margin,
and about 150 more logic cells beside the core make it a coin toss per
placement. The new logic adds one term to one first-clk signal
(`fast_sock`); the rest of what fails is not its logic but its
neighbours. Section 3e has the same history: there the cure was a
floorplan change, and 100 MHz did not buy the failing placement back.
Not tried: more floorplan for the first-clk compare and its register;
100 MHz for this build; the first-clk test without its new term (reads
of E0/E1 then start from the registered decode with the switch on).

The source in the tree is round y's (the regression and the mutations
above are of it). `ACC_NO_SLOW_COPY` in the defines builds without the
feature; that build has not been placed since `rtag_q` and the new
constraints went in. (The card ran t0 until the experiment below.)

Size: 13,236 logic cells, 11,929 FF, 182 of 340 block RAMs (t0: 13,088
logic cells, the same 182).

**Not known.** What the benchmark gives with it (by section 3g's
arithmetic the two floating point tests come to 24 to 26 and 81 to 85
ticks and the average to about 49: an estimate from 120 samples). How
the copy compares with the real machine's Mega II RAM: the paced verify
has not been run. Whether anything the machine does writes that RAM
behind the processor's back (a card that does DMA would).

### On the machine: x0, as an experiment (2026-11-14 afternoon)

Ed's decision: flash one placement that has no violation, to learn what
the copy is worth before more time goes into the timing. x0 is round x's
first placement (+0.000 ns; that source closed two of three), so **this
is a build that does not meet the three-placement rule, on the card as a
measurement and nothing more.** Its source is the tree's without
`rtag_q` (the full regression passed on it too). Flashed 15:39 with the
machine off.

Ladder: word 13 reads `0C` (built with the copy, the copy whole); ROM
copy, sum `7EE8`; paced verify of banks 00/01 for 40 s, no mismatch;
then paced verify with the copy (`1A`): 60 s at the benchmark's prompt
and through part of a base pass, word 13's count 0 and word 14 0, with
E0 and E1 among the sampled socket addresses. (Part, because the card
was put in fast mode for a minute in the middle of that base pass by
mistake - told the prompt was up when it was not. A whole base pass in
`1A` is still owed, and that run's base times are not the machine's.)

Fast with the copy (`1B`), 52.5 entered, one run, against section 3f's
one run without it:

| test | ticks without | ticks with | Actual MHz without | with |
|---|---|---|---|---|
| sieve | 21 | 21 | 49.65 | 49.65 |
| string sort | 60 | 59 | 48.72 | 49.55 |
| floating point, 100 iterations | 34 | 28 | 37.81 | 45.91 |
| 15,000 Gamm units | 115 | 93 | 35.76 | 44.22 |
| Fibonacci | 110 | 110 | 46.31 | 46.31 |
| integer math | 86 | 86 | 45.88 | 45.88 |
| average | | | 44.02 | 46.92 |

Ten runs, the same evening, against section 3f's ten without it:

| test | ticks without | ticks with | Actual MHz without | with |
|---|---|---|---|---|
| sieve | 20.80 | 20.90 | 50.12 | 49.89 |
| string sort | 59.40 | 59.10 | 49.21 | 49.46 |
| floating point, 100 iterations | 33.90 | 26.70 | 37.92 | 48.14 |
| 15,000 Gamm units | 115.10 | 92.40 | 35.73 | 44.51 |
| Fibonacci | 109.80 | 109.40 | 46.39 | 46.56 |
| integer math | 85.60 | 85.20 | 46.09 | 46.31 |
| average | | | 44.24 | 47.48 |

The two tests that wait for the slow memory gain 27 and 25 % over ten runs; the others
do not move. Less than section 3g's arithmetic gave (24 to 26 and 81 to
85 ticks): that took every socket cycle in E0/E1 away, and what the
telemetry shows in the Gamm stretch is 43.5 M steps a second where it
was 34.9, socket cycles 0.052 M a second where they were 0.219 (so about
a fifth of them remain: writes, and whatever is at `$C000` and up), and
read misses up from 3.8 to 5.3 for each thousand steps: about three in
ten of the reads that moved to the copy go to the DDR3 for their line.

The switch while the machine runs, at the report's keypress prompt,
register 29 changed `1B`, `0B`, `1B` with eight seconds in each:

| | copy read | not | copy read again |
|---|---|---|---|
| core steps, M/s | 30.93 | 15.64 | 30.93 |
| socket cycles for the core, M/s | 0.151 | 0.460 | 0.151 |
| read misses, M/s | 0.459 | 0.183 | 0.459 |

That loop runs twice as fast with it. The E0/E1 mismatch count is still
0 after it.

Not done: a whole base pass in paced verify with the copy; what the remaining socket cycles of the floating point tests
are; and the timing, which is where section 3h left it.

## 3i. The computing tests' other clks: writes to the program's stack (2026-11-14, x0 on the card)

Against the AppleSqueezer GS Turbo's published times for this benchmark
(22, 62, 27, 91, 107, 82 ticks; stock 410, 1151, 472, 1535, 2006, 1553)
section 3h's ten runs (20.9, 59.1, 26.7, 92.4, 109.4, 85.2) are level in
total - 18.23 times the stock machine for both - ahead on the sieve, the
sort and the first floating point test, and behind on Gamm, Fibonacci
and integer math, by 1.5 to 4 %. Those last are the tests section 3g
left at 2.29 clks a step with almost no socket cycle and no miss: in the
Fibonacci stretch of section 3h's log, 46.0 M steps a second, 0.004 M
socket cycles, 0.001 M misses - 2.28 clks a step, which is one step in
seven at four clks if that is what they are.

**They are writes the cheap view does not take.** A step is two clks
when the first-clk view (`gs_mmu_decode` `fast_rw`) says it is the
card's alone. For a write in banks 00/01 that view excludes every page
that CAN be shadowed - `$0400-$07FF` and all of `$2000-$9FFF` - without
looking at the shadow register, and such a write waits for the full
decode: four clks (the bench's "local write" class). On the machine:

- the shadow register reads `1E` with the benchmark up (telemetry word
  9): hi-res 1 and 2, super hi-res and the auxiliary hi-res pages all
  inhibited. Nothing in `$2000-$9FFF` is shadowed;
- the program's direct page and stack are in that range. In paced mode
  (every step a socket cycle, so the last socket address is the last
  step's) 342 samples at the report's prompt have 94 in bank 00: pages
  38 (18 samples), 3C (6) and 66 (4) beside the zero page, the system's
  stack in BE/BF and the firmware in C3 to C5. The first mismatch of
  the old verify count after fast mode was at 00/3BEC.

So every push, every store to a local and every store through the
direct page in this program is a four-clk step. Recursion and integer
arithmetic on stack frames are mostly that; the sieve and the sort
write to arrays in the program's own bank (an expansion bank: two clks)
and lose less. It is an inference from the rule, the register and the
addresses - the telemetry does not count writes - but nothing else in a
stretch without socket cycles or misses takes more than two clks except
an internal cycle at `$Cxxx` and a write at `$D000` and up.

**What would take it away:** the cheap view asking two things the
replica already holds - main `$2000-$5FFF` is shadowed only if
`shadow[1]` or `[2]` is clear, main `$6000-$9FFF` never, auxiliary
`$2000-$9FFF` only if `shadow[3]` is clear or an auxiliary hi-res page
is shadowed (`shadow[4]` clear with `[1]` or `[2]`). Two terms of the
shadow register and the bank bit the view already makes for the tag.
The decode sweep proves a cheap view a subset of the full decode on
every vector, so the rule cannot be wrong unnoticed. The bound is the
program's own "expected time" column for 52.5 MHz: 19.9, 55.7, 24.5,
78.3, 97.0, 75.2 ticks. Not built: it is logic in the step's first clk,
where this design has no margin (section 3h).

## 4. What is verified, and what is not

Verified in simulation (the broker suite, `hdl/twgs/sim/broker`):

- `gs_accel` runs beside the bench's hand-wired design on the same socket
  inputs, and **every output pin is compared in every clk** (`ACCEL_SHADOW`),
  in native, paced, fast and toggling modes, with interrupts, RDY stalls, a
  BE pause, warm resets, at 100, 105, 108 and 110 MHz. ROM 01 boot at 110 MHz:
  50,850,536 clks, no difference; over the suite's 79 runs with the module
  beside the design (2026-11-13), 814,174,211 clks.
- The ROM copy (`+mode=copy`): the image starts empty, the design runs
  native from the socket, copies 131,072 bytes through the socket, empties
  the near memory and goes on in fast mode. The image is compared with the
  machine's ROM byte for byte; the test program gives its results; the ROM
  01 boot reaches the same step hash (`6012b76169ecc820`) and the identical
  128,393-write stream as every other mode.
- Fault injection on the new logic (the hold, the copy, the flush, the
  module's memories and grants): 12 of 16 detected. The four that are not:
  the write enable's timing and which copy of the address a near-memory
  block reads (nothing a zero-delay simulation can see), the bank test on
  RAM writes (no expansion memory here), and the tag the flush writes when
  the held step's address is in ROM (it is then the same tag; the bench
  checks it directly when it is not). Four of the twelve needed two things
  the bench gained for them: a second copy made from fast mode, mid-cycle,
  and checks that a copy ends with the near memory empty and the held step
  not trusting its byte. That run also showed the flush is needed: 207
  entries read from the empty image were in the near memory at the first
  copy.
- The suite is 88 runs, all passing; the CPU lockstep bench is unchanged by
  this build.
- The empty near-memory entry (section 3c, found on hardware): all 126
  banks in two builds at 105 MHz, a byte at the top of bank 7F read before
  anything wrote it and again after a ROM copy; the suite is 152 runs.
- The early socket request (scoping doc §10.5): a test of code and 16-bit
  data in a Mega II bank, also called from the interrupt-enabled loop; a
  bench property that no idle cycle is issued in front of a socket-only
  step; two runs with a RDY stall every second and every fifth PHI2 cycle.

Timing (138B, 0.5 ns setup uncertainty; constraints generated by
`hdl/accel_probe_138b/gen_sdc.py`, floorplan and pins by `gen_floorplan.py
accel`):

| build | failing | worst slack | `clk_gs` (110 MHz) reaches | `clk_logic` (56.25 MHz) reaches |
|---|---|---|---|---|
| ao3 | 0 | +0.012 | 110.07 MHz | 71.8 MHz |
| aop1 (a telemetry constant changed) | 0 | +0.016 | 110.19 MHz | 73.9 MHz |
| aop2 (changed again) | 0 | +0.030 | 110.18 MHz | 79.1 MHz |
| **aoz, the source of 857d136c (on the card)** | **0** | **+0.002** | **110.02 MHz** | 72.8 MHz |

With the early socket request (§10.5 of the scoping doc); fx2 is on the card:

| build | failing | worst slack |
|---|---|---|
| fx1 (the request with two RDY terms it did not need) | 6 | −0.062 |
| **fx2, the committed source** | **0** | **+0.008** |
| fxp1 (a telemetry constant changed) | 0 | +0.047 |
| fxp2 (changed again) | 0 | +0.006 |

fx1's six failures were spread over paths that were already at the edge
(none in the new logic); taking the two terms out, which simulation showed
change nothing, took their load off the sequencer's registers.

No setup or hold violation in any of the four, and they are four
placements: every build of this project carries its own build stamp, so
no two netlists are the same. Step paths of aoz: core → core +0.22, core →
near address +0.04, near memory → core +0.07, clock enable into the core
+0.39. As in the probe, the slacks are small because the tool stops when
the constraint is met; the probe's 116 MHz build (114.3 MHz reached) is the
measure of margin, and it has not been repeated on this build. A first
build without the near memory's floorplan failed by 0.8 ns: the floorplan
is part of the design.

Size: 6,591 logic cells (5,737 LUT, 854 ALU), 3,177 FF, 179 of 340 block
RAMs (fx2: 6,571 logic cells, 3,178 FF, 179 block RAMs). At synthesis the accelerator is about 4,100 of the LUTs and the
connector about 1,500.

Not verified, not done:

- **The top level is not simulated.** `accel_only_top.sv` is wiring: PLLs,
  the connector with its tie-offs, two-flop crossings, the key compare,
  the slot pins. The slot side's passivity is by inspection of that file.
- The firmware (Sep 13 2026) arms and controls it, alone and beside an
  a2p25 (section 3); nothing else of the firmware has been looked at
  against this build (its DDR3-ready input is tied high; volumes, video, USB and DP
  status read as nothing).
- The build with the early socket request has run on hardware for one
  boot and one benchmark (section 3); nothing longer.
- No speed control or Zip / TransWarp registers (S7e), no ROM 3.
- The reset rule's gateware sequencer (`gs_socket_arm_seq`) is not in this
  build; arming is timed by the firmware, as in S6.
- The timing probes were not rebuilt after the broker gained the hold
  (they tie it off); their recorded results are those of commit `caa48d98`.
- Open from before: the write of a step completing in the clk /RES is
  seen is not exercised by the bench.

## 5. Building

    GPRJ=a2mega_accel_138B.gprj RESOURCE_BASELINE=none tools/build.sh a2mega all

The a2mega directory holds many projects: always name the project, and
check the build stamp (`CORE:` line) before trusting a hardware test.
Regenerate the constraints with `python3 hdl/accel_probe_138b/gen_sdc.py`
and `python3 hdl/accel_probe_138b/gen_floorplan.py accel`.

Provenance of x0 (the copy of the Mega II's RAM, section 3h; an
experiment, one clean placement of a source that closed two of three;
flashed 2026-11-14 15:39): sources = commit `7ab26835` without `rtag_q`
and with the `mc(2, NMQ, nh_dq)` line in `gen_sdc.py`; the same tool and
device; build stamp `20261114124800`; bitstream sha256
`308790d3bf5d88f2…6e5418a29d98`.

Provenance of t0 (the line memory, section 3e; flashed 2026-11-14 08:53):
sources = the
commit that adds this paragraph; the same tool and device; build stamp
`20261114020946`; bitstream sha256
`dd5d16229b2438a8…6339edea96909e7720`.

Provenance of m0 (the empty-entry fix, section 3c; on the card): sources
= the commit that adds this paragraph; the same tool and device; build
stamp `20261113175022`; bitstream sha256
`aaa7ca899b7fcd5a…bdfa95db0a7fa73711`.

Provenance of k0 (the DDR3 build at 105 MHz, section 3b): sources = the
commit that adds this paragraph; the same tool and device; build stamp
`20261113103322`; bitstream sha256 `4aad21337ff394c4…b620fb41072f`.

Provenance of fx2 (the early socket request, on the card): sources = the
commit that adds this paragraph; the same tool and device; build stamp
`20261112184610`; bitstream sha256 `cc7d3cb5a33f90d8…2476b571f5`.

Provenance of aoz: sources = the commit that adds this page; Gowin
V1.9.12.01, GW5AST-LV138PG484AC1/I0 device version B; build stamp
`20261112104329`; bitstream sha256 `48c06bbc72bca6da…7cb8c04baa`. The
bitstream options are the 138B full build's (`impl/a2mega_138B_process_config.json`
copied, with the probe's place and route options).
