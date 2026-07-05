# Gotchas & Hard-Won Lessons

Non-obvious traps that have each cost real debugging time. Read the relevant section before
working in these areas. **When you discover a new one, add it here** — that's the whole point.

> Many of these were captured from debugging sessions. They reflect what was true when
> written; if one names a file/line/parameter, confirm it still matches current code before
> relying on it.

## Don't-touch list

- **`hdl/sdram/sdram.sv` — do not modify.** The SDRAM controller is load-bearing and timing-tuned.
- **`FB_READ_BURST_WORDS` must be `2`.** A value of `4` deadlocks the SDRAM.

## Gowin synthesis quirks

- **GW2AR supports distributed RAM; GW5AT does NOT** (GW5AT emits warnings and falls back to FFs).
- `(* syn_preserve=1 *)` prevents register merging **and** distributed-RAM inference.
- **Registered BSRAM reads are required:** `always @(posedge clk) x <= mem[addr];`
- **Wire declarations inside named `generate` blocks:** Gowin creates *local implicit* wires
  if the module-level wires aren't declared **before** the generate block. Declare SSP/RGB
  wires before the generate scope.
- **Module boundaries do NOT stop cross-module constant propagation on GW5AT.**
  `syn_dont_touch` / `syn_preserve` keep registers but not their D inputs. For CDC modules,
  use explicit wire ports (not interfaces) as defense-in-depth.
- **`$clog2(1) == 0`** → zero-width register. Avoid parameter values that produce this
  (e.g. `GAP_CYCLES = 1`).

## Interface / array traps

- **Interface array direction mismatch:** a `[N-1:0]` (descending) declaration connected to a
  module port declared `[0:N-1]` (ascending) **reverses all indices**. Symptom: CDC instances
  wired to the wrong-port signals. Fix: match directions at both declaration and port.

## Clock-domain-crossing (CDC)

- On the **GW5AT**, the gray-code `async_fifo` corrupted data crossing 54 MHz → 74.25 MHz
  (rippling band in TEXT40 mode). Fix used: **toggle-based CDC handshake** instead of the
  async FIFO for the affected ports.
- For CDC "pending" flags, set them from the client signals **directly**, not from registered
  copies (registered copies introduced pixel noise).
- The split-clock SDRAM design (108 MHz SDRAM / 54 MHz logic) is bridged by a CDC module; in
  Gowin SDC, `set_false_path` was the only reliable timing constraint (multicycle was broken,
  max_delay marginal).

## Video pipeline

- **`vgc_gen` `active` must be COMBINATIONAL.** A registered `active` creates a phase mismatch
  with `framebuffer_writer`'s pixel-tick sampling.
- **`apple_video_gen` `active` may be REGISTERED** (fetch runs concurrently) — but it must not
  have a default clear at the top of the always block.
- **VGC path needs `GAP_CYCLES >= 2`** (DDR3 write-group pending needs a 1-cycle gap).

## DDR3 (a2mega) specifics

- **Power-cycle between flashes.** Reprogramming without a power cycle can fail DDR3 init,
  producing a black screen that looks like a logic bug but isn't.
- **PnR variance:** identical designs can yield 0–198 timing violations between runs on GW5AT.
  Re-run before assuming a regression.
- Two distinct display-defect classes have been seen — *slow/stale updates* (port contention,
  fixed with wide 128-bit writes + write port priority) vs. *moving distortion* (timing margin
  at 432 MHz). Diagnose which class before chasing a fix.

## GW5A BSRAM inference (a2mega)

- **One address per BSRAM port.** An inferred dual-port array where one port uses a
  *different* address for writes vs. reads (e.g. `if (wr) mem[waddr] <= d; else q <= mem[raddr];`)
  needs a third address port, cannot map to a physical DPB, and — since GW5A has **no
  distributed RAM** (`WARN IF0005`) — silently explodes into LUTs/FFs (hundreds of thousands of
  LUTs; synthesis then grinds for tens of minutes before `ERROR RP0006`). Mux the address by
  direction instead. Two R/W ports with one address each (the `hdd.sv`/`uthernet2.sv` pattern)
  infer fine.
- **The GW5AT-60 has 118 BSRAMs and the a2mega uses all 118.** Any new BSRAM must reclaim one
  first (largest pool: Ensoniq's 64KB sound RAM = 32 BSRAMs, movable to its idle DDR3 ports).
- **`gw_sh` exits 0 on fatal errors.** `tools/build.sh` now greps for `ERROR` lines and rejects
  stale bitstreams; don't bypass it — a raw gw_sh run can leave a previous build's bitstream
  and timing report in `impl/pnr/` looking like a success.

## SDRAM clock phase (ghosting) — historical

- A ghosting artifact on the GW2AR traced to the SDRAM read clock phase (`PSDA_SEL` in the PLL).
  Known-good value is `"1010"` (~225°). This is a clue for any future SDRAM read-data integrity
  issue.

## See also

- [setup-gowin-cli.md](setup-gowin-cli.md) — build & timing-check procedure
- [architecture.md](architecture.md) — the pipeline these traps live in
- `boards/<board>/TODO.md` — current, board-specific open issues
