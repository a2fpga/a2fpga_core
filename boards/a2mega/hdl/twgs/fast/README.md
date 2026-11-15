# F65C816 — fast variant of the 65C816 core (S7 exploration)

This directory is the **working copy** of `../65C816/` for the S7 accelerator
fast-core exploration ([`boards/a2mega/docs/gs_socket_s7_fast_core_exploration.md`](../../../docs/gs_socket_s7_fast_core_exploration.md)).
Every module carries an `F65C816_` prefix (package `F65C816_pkg`) so the
stock core and this one can be instantiated side by side — the bench in
`../sim/bench/` runs them in lockstep, the stock core being the reference.

Provenance and license are those of `../65C816/README.md` (srg320's
SNES_MiSTer P65C816, GPL-3.0, SystemVerilog conversion and IIgs changes by
Alan Steremberg). Nothing here is in a board build; the stock core stays
the one `a2mega_138B.gprj` uses until a rung is promoted.

Differences from the stock core, by rung (the log in the exploration doc
is authoritative):

- **Rung 1** — `AddSubBCD.sv`: one behavioral 17-bit add plus parallel
  decimal correction instead of `BCDAdder`/`adder4`/`bit_adder` (those
  files are not part of this variant). Bit-exact (`../sim/bench/tb_addsub_eq.sv`).
  `mcode.sv`: `AF_TAB`, the `ALU_TAB` lookup folded into the microcode ROM
  at generation time, registered alongside `MI`.
- **Rung 2a** — `mcode.sv` carries `syn_romstyle = "logic"` at module level:
  the microinstruction register is fabric flops behind LUT ROM, not BSRAM.
- **Rung 2b** — `gen_fast_mcode.py` now generates `mcode.sv` from the stock
  table with the pre-decoded columns `AF_TAB` (ALU control) and `XT_TAB`
  (one-hot `SB_SEL`/`DB_SEL`, `W16_FORCE/M/X`); `F65C816_pkg.sv` extends
  `FMCode_r` with those fields; `F65C816.sv` builds `w16` and the `SB`/`DB`
  operand muxes from them. The struct types are prefixed `F` (`FMCode_r`,
  `FALUCtrl_r`, `FMicroInst_r`) because both cores import their package at
  file scope and share a compilation unit in the bench.

`mcode.sv` here is **generated** — edit `gen_fast_mcode.py` (or the stock
table) and rerun it; do not hand-edit the tables.
- **Rung 2c** — `XT_TAB` gains the `LOAD_P == 001` condition tree
  (`PF_PLB/PLD/TSX/FORCE/M8/X8/M16/X16`); `AddrGen.sv` writes the MVN/MVP
  PC repeat as `PCr + ({16{PCDec}} & 16'hFFFD)` so the ALU carry reaches
  the PC through the data path, not a register enable.
- **Rung 2d** — `AddSubBCD.sv`: one unbroken 17-bit carry chain plus a
  parallel 9-bit low-byte chain for the byte carry, and a flat decimal-carry
  lookahead (a guard-bit-per-nibble chain was tried and regressed: the
  synthesizer splits the chain at each guard; see the exploration log). `ALU.sv`: one-hot `FST`/`SEC` and
  `SEL_ADD` from the microcode (`FALUCtrl_r` is 25 bits) turn every select
  into one AND-OR level; bit-exact against the stock ALU on all 256 control
  words (`../sim/bench/tb_alu_eq.sv`).

- **Rung 3 (data-late step)** — the core now produces the address of the
  *next* step during the current one (`NA_OUT`), so a synchronous memory can
  register it at the step edge and the step becomes one clock instead of an
  address clock plus data clocks. `A_OUT` is the register of `NA_OUT`, so the
  bus is unchanged and the lockstep bench checks it on every step.
  - `AddrBus.sv` (`F65C816_AddrBus`) is the stock `ADDR_BUS` block moved
    verbatim into a module. The core instantiates it twice: on the registers
    (simulation cross-check only; synthesis sweeps it) and on their next
    values.
  - Next values: `AddrGen.sv` exports `PC_n`/`AA_n`/`AB_n`/`DX_n`; `SP_n`,
    `PBR_n`, `SPW_n` and the emulation-mode stack-tracking flags are split
    into next-value logic plus registers (same expressions, moved).
  - The next step's microcode address fields are registered with the
    microinstruction: `SUCC_TAB` (generated) holds the fields of both
    possible successor rows, and the `NextState` decision (`NS_ZERO`,
    `NS_INC2`) picks one, so there is no ROM lookup behind `NextState`.
    `F65C816_naf` (`NA_TAB`) is the direct lookup, kept as the simulation
    reference. (Used in synthesis, GowinSynthesis shared its decode with the
    main microcode ROM and so put memory data → `NextIR` in front of it.)
    `IR`, `D`, `DBR`, `EF` and the interrupt-class flags are read from their
    registers; that is exact because of table properties the generator
    asserts (every opcode's step 1 addresses `PBR:PC` with no write; `D`,
    `DBR`, `EF` load only where the successor step does not read them).
  - The MVN/MVP repeat decision is `A != 0` from the register instead of the
    ALU carry-out (same value in that step; asserted by the generator and in
    simulation), which removes memory → ALU → carry → PC adder from the
    next-address path.
  - Two later cuts for the integrated build, both exact and checked in
    simulation: `VPA`'s two-cycle term comes from the microinstruction
    (`STATE == 1 & VA == 00 & STATE_CTRL == 010`; the generator asserts that
    this is "last cycle" for those rows), so the bus status is a function of
    registers; and the stack-tracking values that feed the next address are
    computed without the last-cycle term (`*_a`: a last cycle is followed by
    a fetch at `PBR:PC`, which reads none of them).
  - For the broker (S7b, `gs_accel_broker` with `DATA_LATE`), three more, all
    exact and cross-checked in simulation on every step:
    `NST_OUT` is the NEXT step's bus status (`{VPB, WE, internal}`), from the
    registered successor fields and, for a fetch step, a small per-opcode
    table (`F65C816_st1`: step 1's `VA[0]` and the two-cycle flag), so the
    broker can register a step's kind when the core steps and decide the step
    from registers only. The next address is split into `NA_MOVE` (next
    register values, increment forced to zero) and `NA_STAY` (current
    registers, the successor's increment), picked by "increment is zero";
    the generator asserts that a step that loads `AA`/`AB`, `DX`, `SP` or
    `PBR` is never followed by an access through that register with a
    non-zero increment, so the long next-value logic never feeds the
    incrementer. And the step enable has separate copies for the microcode
    registers, the address generator, the register file and the P / DR /
    stack-tracking registers (`EN_m`, `EN_g`, `EN_r`, `EN_p`), each fed by its
    own bit of the `CE_X` port, which the broker drives from preserved
    copies of its clock-enable register (one net from that register to
    every core register was 5 ns; copies made with `syn_keep` or
    `syn_maxfan` inside the core were merged again by GowinSynthesis).
    `CE_X` must equal `{4{CE}}`; simulation checks it.
  - Rung 4a (2026-11-12): the next microinstruction and the next address are
    formed as candidates and the late `NextState` decision only selects.
    `NextState` is 0, `STATE + 1` or `STATE + 2` (1 in the fetch step, with
    the opcode on the bus; asserted on every step in simulation), so
    `F65C816_mcode` takes the registered `IR` / `STATE` plus `NIR`,
    `NS_ZERO`, `NS_INC2` and looks up both successor rows and the fetched
    opcode's first row; `NA_OUT` is evaluated for the fetch candidate and
    both successor rows (`SN`) and selected by the same decision.
  - Rung 5 (2026-11-12), for a core that steps no faster than every second
    clk (the broker's two-clk step). Build with `F65C816_MCODE_ROM` defined:
    `F65C816_mcode_s` replaces `F65C816_mcode`. `IR` and `STATE` are then
    registers a whole clk before the step ends, so both successor rows are
    read from them in block RAM (`F65C816_mrom`, two synchronous reads of the
    packed row table, 24 blocks) in the clk before the step ends; step 1 of
    the fetched opcode is still a lookup from the data bus
    (`F65C816_mst1`, 256 rows), and the decision selects as before. The
    registered row is the same. The microcode was 4,189 of the integrated
    probe's 7,393 LUTs; it is 448. The module stops a simulation if the
    core is ever stepped in two successive clks; the lockstep bench runs
    this build with `+ce2`.
  - The same day, four cuts of logic that was in front of late signals for
    no functional reason, each exact and each asserted where it rests on
    the microcode table (`gen_fast_mcode.py`):
    the next `P` takes the ALU's flags in its last level (the stock case
    statement had them six levels down);
    the adder's carry in is the carry flag alone (no control word shifts
    the operand and then adds, so the operand's shifted-out bit never
    reaches the carry chain; `tb_alu_eq.sv` skips the words that would);
    the ALU has one result for both widths with the adder's sum ORed in
    last, and each decimal digit is formed for both values of its carry in
    (`tb_alu_eq.sv`, `tb_addsub_eq.sv`);
    the address generator forms the high address byte per use (`AAH` +
    index from registers; `DH` + index for both values of the low byte's
    carry), and the stock `AB = D_IN + carry` (`ABSCtrl` 10), which no row
    uses, is gone; the RTL page carry in `AddrBus.sv` is a compare, not a
    sum.
  - `NA_OUT_B` is `NA_OUT[13:0]` again from gates of its own, for a memory
    whose read-address loads are far apart.
  - Memory contract (bench `+datalate`, probe `CPU_PROBE_DATALATE`): read
    port addressed by `NA_OUT`, clock-enabled by `RDY_OUT`; write port at
    `A_OUT`/`D_OUT`/`WE` on the step edge; a one-entry bypass serves a read of
    the byte written at the same edge (the bench returns garbage from the
    memory there, so the bypass is proven necessary and sufficient).

Probe variants: `a2mega_cpu_probe_138b_fast_addr.gprj` constrains only the
register → BSRAM-address paths to one 108 MHz clock (`set_max_delay`), so
its report shows the address cone the normal probe hides behind the data cone.
`a2mega_cpu_probe_138b_fast_dl.gprj` is the data-late probe: one clock per step, so its
reported Fmax is the step rate. The two-edge probes still build, but since rung 3
their address clock starts at the `A_OUT` register, so they no longer measure the
address cone.
