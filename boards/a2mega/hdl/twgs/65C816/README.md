# P65C816 — 65C816 CPU core

A SystemVerilog conversion of the VHDL 65C816 CPU core written by
**srg320** for [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer),
with modifications for the Apple IIgs.

## Provenance

The original core is the `P65C816` VHDL implementation in
`rtl/CPU/` of SNES_MiSTer (`P65C816.vhd`, `AddrGen.vhd`, `ALU.vhd`,
`AddSubBCD.vhd`, `BCDAdder.vhd`, `MCode.vhd`, `P65816_pkg.vhd`).
Those files were translated to SystemVerilog/Verilog, preserving the
microcode-driven structure and the cycle-level bus behaviour, and then
extended for this core's needs.

Upstream: https://github.com/MiSTer-devel/SNES_MiSTer
Author:   srg320 — https://github.com/srg320

## Changes from the original

- Translated from VHDL to SystemVerilog / Verilog.
- `ABORT_N` handling and the `VPA`/`VDA`/`VPB`/`MLB` bus-status outputs are
  exercised by the Apple IIgs memory controller, which needs them to
  distinguish opcode fetches, data cycles and vector pulls for shadowing
  and language-card decode.
- Timing adjusted for the IIgs FPI/Mega II bus: the core is driven by a
  clock enable (`CE`) and stalled via `RDY_IN` so the memory controller
  can insert the IIgs's RAM-refresh and slow-bus stretch cycles.
- Assorted fixes found while running the Apple IIgs ROM self-tests and
  the 65C816 instruction-level test suites.
- WAI wake-up restored to the original's condition (2026-11-11): the
  conversion tested `IRQ_N == 1` where the VHDL has `IRQ_N = '0'`, so a WAI
  ended at once when no interrupt was pending and never ended when /IRQ went
  low while it executed. Found by the S7 broker bench (`sim/broker`, the WAI
  in `broker_test.s`).
- Submodules carry a `P65C816_` prefix (`P65C816_ALU`, `P65C816_AddrGen`,
  `P65C816_AddSubBCD`, `P65C816_BCDAdder`, `P65C816_adder4`,
  `P65C816_bit_adder`, `P65C816_mcode`): the a2mega build also contains
  Gowin's encrypted DDR3 controller, whose netlist already defines a module
  named `ALU`, and the generic names collided. Names only — no logic
  differs from the MiSTer source.
- Emulation-mode stack address helpers (`pld_sum2low_w`, `pld_sum2car_w`,
  `spw_sum1_w`, `rtl_off_w`, `rtl_sum9_w`) are continuous assignments
  instead of branch-scoped temporaries inside the ADDR_BUS block. Same
  values; the temporaries made GowinSynthesis infer a latch (EX2420 on
  `sum2low[8]`), and a latch loop made timing-driven routing of the full
  a2mega 138B design thrash (2 of 6 builds finished; the design without
  the core routed in 15 minutes).

## Files

| File | Role |
|------|------|
| `P65C816.sv` | Top level: state machine, registers, bus interface |
| `P65C816_pkg.sv` | Shared types and microcode record definitions |
| `mcode.sv` | Microcode ROM — decodes opcode to control signals |
| `AddrGen.sv` | Effective-address generation |
| `ALU.sv` | Arithmetic/logic unit |
| `AddSubBCD.sv` | Binary and BCD add/subtract |
| `BCDAdder.v` | BCD adder used by `AddSubBCD` |
| `adder4.v`, `bit_adder.v` | Adder primitives |
| `65C816.qip` | Quartus file list for this directory |

## License

GPL-3.0, inherited from SNES_MiSTer. See `LICENSE` in this directory for
the full text.

SNES_MiSTer's repository carries the GPL-3.0 license text without an
"or any later version" grant, so this conversion is labeled GPL-3.0 only
rather than GPL-3.0-or-later; only the upstream author (srg320) could
extend that.
