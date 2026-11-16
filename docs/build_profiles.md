# Build profiles and resource accounting

Two things keep a core from silently outgrowing its die: knowing what each
module costs on every build, and having one place per board that says what the
core carries. This page covers both.

## Resource report (every build)

`tools/build.sh` ends every full build by running
`tools/resource_report.py <board> <proj>`. It reads the Gowin synthesis
hierarchy (`impl/gwsynthesis/<proj>_syn_resource.html`) and the place-and-route
totals (`impl/pnr/<proj>.rpt.txt`), prints the device utilisation and a
per-module LUT / REG / BSRAM table, writes a compact snapshot to
`boards/<board>/impl/<proj>_resources.json` (tracked in git) and diffs the
build against the snapshot committed at `HEAD`:

```
>> Resources: boards/a2n20v2-Enhanced a2n20v2_enhanced   (baseline: HEAD:...)
   device (place & route):
     BSRAM          46/46      100%      +2
   notable module changes (|LUT|+|REG| >= 50, or any BSRAM):
     ~ top/uthernet2: LUT +60 REG 0 BSRAM +2
```

Environment knobs for `tools/build.sh`:

| variable | effect |
|---|---|
| `RESOURCE_BASELINE=<ref\|file\|none>` | what to diff against (default `HEAD`, i.e. the committed snapshot) |
| `RESOURCE_FAIL=bsram\|lut\|reg` | fail the build (exit 5) if that device-level resource grew versus the baseline |

Build the Tang Nano boards with `RESOURCE_FAIL=bsram`: the classic Enhanced is
at 46/46 and has nothing to give. Commit the regenerated snapshot together with
the change that moved the numbers, so the next build diffs against the new
reality and the history of the JSON is the cost history of the design.

The tool runs standalone too (`tools/resource_report.py a2p25 --baseline main`),
and `--no-write` leaves the snapshot alone.

Two regressions the merge of 2026-10-22 paid for are each a one-line entry in
this report: a 128x48 "distributed_ram" event log that Gowin built as ~5.8k
flops in every core that used the shared ESP32 connector (the a2p25 failed to
place), and a `sound_glu` parameter default that moved the DOC register banks
into five BSRAM blocks on boards that never asked.

## Build profiles (one file per board)

Every board top includes `boards/<board>/hdl/<board>_profile.vh` right after
`datetime.svh`. It is the single place that says what the core carries:

```verilog
// ---- features ----
`define A2_FEATURE_UTHERNET2      1
`define A2_FEATURE_MOCKINGBOARD   1
// ---- instrumentation ----
`define A2_INSTR_DEBUG_OVERLAY    1
`define A2_INSTR_EVENT_LOG        0
```

The top's parameter defaults read the macros (`parameter bit UTHERNET2_ENABLE =
`A2_FEATURE_UTHERNET2`), and instrument instances read them directly
(`.ENABLE(`A2_INSTR_DEBUG_OVERLAY)`). Conventions:

- **`A2_FEATURE_*`** removes or adds a function the user can tell is there
  (a slot card, audio, a video option). Off means the `generate` branch is
  gone and the slot ID stays reserved.
- **`A2_INSTR_*`** is an instrument: overlays, event logs, telemetry counters,
  bus traces. Off means the logic is gone **but its registers keep their
  addresses and read zero**. The register map never renumbers for a profile,
  so the ESP32 / BL616 firmware keeps working; firmware should probe
  `REG_CAPABILITIES` (connector reg 0x05) rather than assume an instrument is
  present.
- Per-die switches stay where they are (`dp_test_die_pkg::FEATURE_*` on the
  a2mega chooses per SOM). Variant defines keep selecting variants
  (`GS_SOCKET`, `DUAL_RATE_SDRAM`, `VIDEO_FRAMEBUFFER`); a profile file may
  consult them (`A2_INSTR_EVENT_LOG` is 1 only under `GS_SOCKET`).
- A module-level parameter that gates something costly must default to the
  cheap setting when a board does not choose (`doc5503 BANKS_IN_BSRAM`,
  `esp32_ospi_connector EVT_LOG`), and the board that wants it passes it
  explicitly from its profile. Defaults that reach other boards are how the
  two regressions above happened.

Adding a switch: define the macro in every board's profile file (with that
board's current value), make the top read it, build the affected boards and
commit the regenerated snapshots with the change. The resource report is the
proof that a profile-only commit changed nothing.

### The profiles today (dev)

The values in each file are exactly what the board built before the file
existed; the first commit of this scheme changed no bitstream. The release
profile does not exist yet: each file ends with an empty
`` `ifdef A2_PROFILE_RELEASE `` block for the overrides, and the define will come
from a `*_defines.v` listed first in a release `.gprj` (the pattern
`gs_socket_defines.v` already uses) or from a `PROFILE=release` switch in
`tools/build.sh` once it can inject one. A release build is its own
timing-closure target: removing logic reseeds placement, so it gets its own
durability rolls under the no-skating rule, not a free ride on the dev build's.

Two cautions when turning instruments off. Some sit inside timed pipelines:
the a2mega's DebugOverlay is a stage of the clk_pix chain and the framebuffer's
`H_TRIGGER_LEAD` is counted through it, so it gets a stage-preserving bypass,
not removal, or the picture moves a pixel. And the instrumentation the ESP32
firmware reads over the window registers (DOC telemetry 40–47, event log
32–39, DP readback 0x3C–0x3F) is also what the bench procedures in
`boards/a2p25/docs/RESOURCE_AUDIT.md` depend on.

## Where the fabric actually is (2026-10-23 builds)

Modules *named* as instrumentation (DebugOverlay, OSD, DDR3 debug reader,
event log, bus-event FIFO) are about 1% of any board. The telemetry embedded in
functional modules (the ESP32 connector's ~117 debug-register references, the
AUX ladder's observe counters, the DOC and framebuffer per-frame counters) is
perhaps 3–5% and is reclaimable only by parameters inside those modules.
Features are where capacity is, and the binding resource differs per board:

| board | bound by | the large consumers |
|---|---|---|
| a2p25 (GW5A-25) | logic, 96% CLS; 50/56 BSRAM (Uthernet II + Mockingboard in, 2026-11-15) | sdp_engine 4-lane 4.8%, HyperRAM ctrl 4.0%, ESP32 connector 2.3% + 11 BSRAM, framebuffer 3.6% + 9 BSRAM, DOC fetch cache 3.2%, Mockingboard 3.1% |
| Enhanced classic (Tang Nano 20K) | BSRAM 46/46 | Uthernet II 9 blocks, aux hires banks 16, F18A VDP RAM 8 + sprites 2, BL616 connector 3; Mockingboard pair + SSP ~1.7k LUT |
| Enhanced dualrate / fb | 31 / 35 of 46 BSRAM | aux banks already in SDRAM; same logic set |
| GS | 19/46 BSRAM, 77% CLS | SDRAM framebuffer 4 blocks |
| a2mega 60K | 66% CLS, 107/118 BSRAM | DDR3 PHY 3.7k LUT / 7.2k REG, pipelined DOC 2.0k LUT, framebuffer 13 BSRAM, connector 11 |
| a2mega 138B | 37% CLS | as 60K plus the socket core; clk100 at the +0.5 ns policy line |

`tools/resource_report.py <board> --top 40` prints the current table.
