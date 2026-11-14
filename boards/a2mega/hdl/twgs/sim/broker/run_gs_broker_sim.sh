#!/usr/bin/env bash
# S7b: the accelerator broker (gs_accel_broker + gs_mmu_replica) with the
# unchanged socket PHY and a 65C816 core, against the behavioural IIgs of the
# S2-S6 bench extended with the golden machine model.
# See boards/a2mega/docs/gs_socket_s7_accelerator_scoping.md 2.1-2.4, 6.2, 9
# and the header of tb_gs_broker.sv.
#
# Usage: boards/a2mega/hdl/twgs/sim/broker/run_gs_broker_sim.sh [program|rom|all]
#   program   broker bench on the built test ROM (broker_test.s): every mode,
#             108 MHz / 4 clks per step and 100 MHz / 2 clks per step, IRQ,
#             RDY stalls, a BE pause, a warm reset, expansion RAM, local slot
#             firmware, the F65C816 core; plus the same program in native, paced and
#             fast mode with the step hash and the write stream compared
#   rom       end-to-end: a ROM 01 image booted in native (S6), paced and
#             fast mode; all runs must reach the same point (step hash) and
#             show the machine the same writes to I/O, Mega II and shadowed
#             ranges, in the same order.  Needs ROM=<boot1.rom>.
#   all       both (default; the rom suite is skipped with a notice if ROM
#             is not set)
# Env: OUT   work dir, default ${TMPDIR:-/tmp}/gs_broker_sim
#      ROM   path to a ROM 01 image (128 KB), e.g. the MiSTer vsim/boot1.rom
#            built by Apple-IIgs_MiSTer/roms/Makefile; Apple ROM content is
#            never committed
#      STEPS core steps for the rom suite (default 3000000)
# Requires Verilator >= 5 (timing support), ca65/ld65.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SIM="$(cd "$HERE/.." && pwd)"
TWGS="$(cd "$SIM/.." && pwd)"
CORE="$TWGS/65C816"
FAST="$TWGS/fast"
OUT="${OUT:-${TMPDIR:-/tmp}/gs_broker_sim}"
SUITE="${1:-all}"
STEPS="${STEPS:-3000000}"
mkdir -p "$OUT"

# ---------------------------------------------------------------- test ROM
ca65 --cpu 65816 -o "$OUT/broker_test.o" -l "$OUT/broker_test.lst" "$HERE/broker_test.s" || exit 1
ld65 -C "$HERE/broker_rom.cfg" -o "$OUT/broker_test.rom" -m "$OUT/broker_test.map" "$OUT/broker_test.o" || exit 1
if [[ "$(wc -c < "$OUT/broker_test.rom" | tr -d ' ')" != "131072" ]]; then
    echo "test ROM is not 131072 bytes"; exit 1
fi

# ---------------------------------------------------------------- builds
STOCK=( "$CORE/P65C816_pkg.sv" "$CORE/mcode.sv" "$CORE/bit_adder.v" "$CORE/adder4.v"
        "$CORE/BCDAdder.v" "$CORE/AddSubBCD.sv" "$CORE/ALU.sv" "$CORE/AddrGen.sv" "$CORE/P65C816.sv" )
FASTF=( "$FAST/F65C816_pkg.sv" "$FAST/mcode.sv" "$FAST/AddSubBCD.sv" "$FAST/ALU.sv" "$FAST/AddrGen.sv"
        "$FAST/AddrBus.sv" "$FAST/F65C816.sv" )
DUT=( "$TWGS/gs_socket_phy.sv" "$TWGS/gs_mmu_decode.sv" "$TWGS/gs_mmu_replica.sv" "$TWGS/gs_accel_broker.sv"
      "$TWGS/gs_accel_romcopy.sv" "$TWGS/gs_accel_exp.sv" "$HERE/gs_exp_mem_sim.sv"
      "$HERE/tb_gs_broker.sv" "$SIM/mmu/iigs_machine_dpi.cpp" )

build() {   # name, extra verilator args...
    local name="$1"; shift
    verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -O3 \
        --top-module tb_gs_broker --Mdir "$OUT/obj_$name" -o Vtb_gs_broker \
        -CFLAGS "-O2 -I$SIM/mmu" "$@" "${STOCK[@]}" "${DUT[@]}" > "$OUT/verilate_$name.log" 2>&1
}
build b108_4                                  & p1=$!
build b100_2 +define+CLK100 -GSTEP_CLKS=2     & p2=$!
build b108_4f +define+FAST_CORE "${FASTF[@]}" & p3=$!
# data-late step (broker launches the next step's read ahead, F65C816.NA_OUT): three clks of
# 108 MHz = 36 MHz steps with two clks to decode the address, and two clks of 100 MHz = 50 MHz
build b108_3d +define+FAST_CORE -GDATA_LATE=1 -GSTEP_CLKS=3 -GADDR_CLKS=2 -GRA_COPIES=4 "${FASTF[@]}" & p4=$!
build b100_2d +define+FAST_CORE +define+CLK100 -GDATA_LATE=1 -GSTEP_CLKS=2 -GADDR_CLKS=1 "${FASTF[@]}" & p5=$!
# ... and with the near memory (a 16K-entry cache in front of the card's memories, every step
# decoded in its first clk): two-clk steps, 100 MHz = 50 MHz, 108 MHz = 54 MHz; the core with
# its microcode's successor rows read from block RAM (F65C816_MCODE_ROM: the two-clk step is
# what makes that possible, and the core stops the run if it is ever stepped in two successive clks)
# ... with gs_accel, the accelerator domain as the board build has it, beside the hand-wired
# design on the same pins (ACCEL_SHADOW: every output pin compared in every clk); at 110 MHz,
# the board's socket PLL, too; and (b110_2c) with the card's ROM image empty, for +mode=copy
# (the 110 MHz builds with the board's near-memory tag, A14-A17: -GNEAR_KW=4)
NEARX=( +define+FAST_CORE +define+F65C816_MCODE_ROM +define+ACCEL_SHADOW -GDATA_LATE=1 -GNEAR=1 -GSTEP_CLKS=2 -GADDR_CLKS=2 -GFAR_CLKS=2
        "${FASTF[@]}" "$TWGS/gs_accel.sv" )
build b100_2x +define+CLK100 "${NEARX[@]}" & p8=$!
build b108_2x "${NEARX[@]}" & p9=$!
build b110_2x +define+CLK110 -GNEAR_KW=4 "${NEARX[@]}" & p10=$!
build b110_2c +define+CLK110 -GNEAR_KW=4 -GROM_PRESET=0 "${NEARX[@]}" & p11=$!
# ... and gs_accel with banks 02/03 in block RAM (EXP_BANKS = 2), compared in runs with +exp=2
build b110_2e +define+CLK110 -GNEAR_KW=4 -GACC_EXP=2 "${NEARX[@]}" & p12=$!
# ... and with the expansion banks in a memory of varying latency behind gs_accel_exp (EXP_DDR:
# the DDR3 as the bench models it), the near memory tagging every bank with a split tag
# (these two with the split tag: its high address bits read a clk late, no two-clk step in an expansion bank)
build b110_2r +define+CLK110 -GNEAR_KW=9 -GACC_EXP=2 -GEXP_DDR=1 -GNEAR_SPLIT=1 "${NEARX[@]}" & p13=$!
build b110_2s +define+CLK110 -GNEAR_KW=9 -GACC_EXP=8 -GEXP_DDR=1 -GNEAR_SPLIT=1 "${NEARX[@]}" & p14=$!
# ... and at 105 MHz (52.5 MHz steps), the clock the accelerator-only build runs at with the DDR3,
# with the whole tag as that build has it: a step in an expansion bank is a two-clk step too
build b105_2s +define+CLK105 -GNEAR_KW=9 -GACC_EXP=8 -GEXP_DDR=1 "${NEARX[@]}" & p15=$!
# ... with every bank the card can hold (02-7F), as that build has them: the top of bank 7F is
# the highest tag a RAM entry of the near memory can have; and (b105_2k) with the ROM image
# empty, for +mode=copy (a copy empties the near memory)
build b105_2t +define+CLK105 -GNEAR_KW=9 -GACC_EXP=126 -GEXP_DDR=1 "${NEARX[@]}" & p16=$!
build b105_2k +define+CLK105 -GNEAR_KW=9 -GACC_EXP=126 -GEXP_DDR=1 -GROM_PRESET=0 "${NEARX[@]}" & p17=$!
bfail=0
wait $p1 || { echo "verilator FAILED (b108_4) - see $OUT/verilate_b108_4.log"; grep -E "%Error|error:" "$OUT/verilate_b108_4.log" | head -20; bfail=1; }
wait $p2 || { echo "verilator FAILED (b100_2) - see $OUT/verilate_b100_2.log"; grep -E "%Error|error:" "$OUT/verilate_b100_2.log" | head -20; bfail=1; }
wait $p3 || { echo "verilator FAILED (b108_4f, F65C816) - see $OUT/verilate_b108_4f.log"; grep -E "%Error|error:" "$OUT/verilate_b108_4f.log" | head -20; bfail=1; }
wait $p4 || { echo "verilator FAILED (b108_3d) - see $OUT/verilate_b108_3d.log"; grep -E "%Error|error:" "$OUT/verilate_b108_3d.log" | head -20; bfail=1; }
wait $p5 || { echo "verilator FAILED (b100_2d) - see $OUT/verilate_b100_2d.log"; grep -E "%Error|error:" "$OUT/verilate_b100_2d.log" | head -20; bfail=1; }
wait $p8 || { echo "verilator FAILED (b100_2x) - see $OUT/verilate_b100_2x.log"; grep -E "%Error|error:" "$OUT/verilate_b100_2x.log" | head -20; bfail=1; }
wait $p9 || { echo "verilator FAILED (b108_2x) - see $OUT/verilate_b108_2x.log"; grep -E "%Error|error:" "$OUT/verilate_b108_2x.log" | head -20; bfail=1; }
wait $p10 || { echo "verilator FAILED (b110_2x) - see $OUT/verilate_b110_2x.log"; grep -E "%Error|error:" "$OUT/verilate_b110_2x.log" | head -20; bfail=1; }
wait $p11 || { echo "verilator FAILED (b110_2c) - see $OUT/verilate_b110_2c.log"; grep -E "%Error|error:" "$OUT/verilate_b110_2c.log" | head -20; bfail=1; }
wait $p12 || { echo "verilator FAILED (b110_2e) - see $OUT/verilate_b110_2e.log"; grep -E "%Error|error:" "$OUT/verilate_b110_2e.log" | head -20; bfail=1; }
wait $p13 || { echo "verilator FAILED (b110_2r) - see $OUT/verilate_b110_2r.log"; grep -E "%Error|error:" "$OUT/verilate_b110_2r.log" | head -20; bfail=1; }
wait $p14 || { echo "verilator FAILED (b110_2s) - see $OUT/verilate_b110_2s.log"; grep -E "%Error|error:" "$OUT/verilate_b110_2s.log" | head -20; bfail=1; }
wait $p15 || { echo "verilator FAILED (b105_2s) - see $OUT/verilate_b105_2s.log"; grep -E "%Error|error:" "$OUT/verilate_b105_2s.log" | head -20; bfail=1; }
wait $p16 || { echo "verilator FAILED (b105_2t) - see $OUT/verilate_b105_2t.log"; grep -E "%Error|error:" "$OUT/verilate_b105_2t.log" | head -20; bfail=1; }
wait $p17 || { echo "verilator FAILED (b105_2k) - see $OUT/verilate_b105_2k.log"; grep -E "%Error|error:" "$OUT/verilate_b105_2k.log" | head -20; bfail=1; }
[[ $bfail -ne 0 ]] && exit 1

# ---------------------------------------------------------------- runs
declare -a NAMES=()
run() {     # name, build, args...
    local name="$1" bld="$2"; shift 2
    NAMES+=( "$name" )
    mkdir -p "$OUT/$name"
    ( cd "$OUT/$name" && "$OUT/obj_$bld/Vtb_gs_broker" "$@" > sim.log 2>&1 ) &
}
T="+rom=$OUT/broker_test.rom"
if [[ "$SUITE" == "program" || "$SUITE" == "all" ]]; then
    # (b) every mode, with interrupts, RDY stalls and a BE pause
    run p_native    b108_4  $T +mode=native +expect +irq
    run p_paced     b108_4  $T +mode=paced  +expect +irq
    run p_fast      b108_4  $T +mode=fast   +expect +irq
    run p_toggle    b108_4  $T +mode=toggle +expect +irq +steps=120000
    run p_fast_exp  b108_4  $T +mode=fast   +expect +irq +exp=2
    run p_fast_mb   b108_4  $T +mode=fast   +expect +irq +exp=1 +mbexp=4
    run p_fast_cx   b108_4  $T +mode=fast   +expect +irq +cxrom=1
    run p_tog_cx    b108_4  $T +mode=toggle +expect +irq +cxrom=1 +exp=2 +steps=120000
    run p_fast_1mhz b108_4  $T +mode=fast   +expect +irq +noturbo
    run p_rst_nat   b108_4  $T +mode=native +expect +irq +reset
    run p_rst_fast  b108_4  $T +mode=fast   +expect +irq +reset
    run p_rst_tog   b108_4  $T +mode=toggle +expect +irq +reset +steps=120000
    # ... and with /RES falling in the middle of a socket write cycle
    run p_rstw_nat  b108_4  $T +mode=native +expect +irq +resetw
    run p_rstw_fast b108_4  $T +mode=fast   +expect +irq +resetw
    run p_rstw_tog  b108_4  $T +mode=toggle +expect +irq +resetw +steps=120000
    run p_f816      b108_4f $T +mode=fast   +expect +irq
    run p_f816_nat  b108_4f $T +mode=native +expect +irq
    # data-late broker: every mode again, at 108/3 and 100/2
    run d_native    b108_3d $T +mode=native +expect +irq
    run d_paced     b108_3d $T +mode=paced  +expect +irq
    run d_fast      b108_3d $T +mode=fast   +expect +irq
    run d_toggle    b108_3d $T +mode=toggle +expect +irq +steps=120000
    run d_fast_exp  b108_3d $T +mode=fast   +expect +irq +exp=2
    run d_tog_cx    b108_3d $T +mode=toggle +expect +irq +cxrom=1 +exp=2 +steps=120000
    run d_fast_1mhz b108_3d $T +mode=fast   +expect +irq +noturbo
    run d_rst_fast  b108_3d $T +mode=fast   +expect +irq +reset
    run d_rst_tog   b108_3d $T +mode=toggle +expect +irq +reset +steps=120000
    run d_rstw_nat  b108_3d $T +mode=native +expect +irq +resetw
    run d_rstw_fast b108_3d $T +mode=fast   +expect +irq +resetw
    run d_rstw_tog  b108_3d $T +mode=toggle +expect +irq +resetw +steps=120000
    run d_rstpw_nat b108_3d $T +mode=native +expect +irq +resetpw
    run d2_fast     b100_2d $T +mode=fast   +expect +irq
    run d2_toggle   b100_2d $T +mode=toggle +expect +irq +steps=120000
    # near memory, two-clk steps: every mode again at 100 MHz, the main ones at 108
    run x_native    b100_2x $T +mode=native +expect +irq
    run x_paced     b100_2x $T +mode=paced  +expect +irq
    run x_fast      b100_2x $T +mode=fast   +expect +irq
    run x_toggle    b100_2x $T +mode=toggle +expect +irq +steps=120000
    run x_fast_exp  b100_2x $T +mode=fast   +expect +irq +exp=2
    run x_fast_mb   b100_2x $T +mode=fast   +expect +irq +exp=1 +mbexp=4
    run x_fast_cx   b100_2x $T +mode=fast   +expect +irq +cxrom=1
    run x_tog_cx    b100_2x $T +mode=toggle +expect +irq +cxrom=1 +exp=2 +steps=120000
    run x_fast_1mhz b100_2x $T +mode=fast   +expect +irq +noturbo
    run x_rst_fast  b100_2x $T +mode=fast   +expect +irq +reset
    run x_rst_tog   b100_2x $T +mode=toggle +expect +irq +reset +steps=120000
    run x_rstw_nat  b100_2x $T +mode=native +expect +irq +resetw
    run x_rstw_fast b100_2x $T +mode=fast   +expect +irq +resetw
    run x_rstw_tog  b100_2x $T +mode=toggle +expect +irq +resetw +steps=120000
    run x_rstpw_nat b100_2x $T +mode=native +expect +irq +resetpw
    run x8_native   b108_2x $T +mode=native +expect +irq
    run x8_fast     b108_2x $T +mode=fast   +expect +irq
    run x8_toggle   b108_2x $T +mode=toggle +expect +irq +cxrom=1 +exp=2 +steps=120000
    run x8_rst_tog  b108_2x $T +mode=toggle +expect +irq +reset +steps=120000
    # ... at 110 MHz, the board's socket clock; and the ROM image read through the socket
    run y_native    b110_2x $T +mode=native +expect +irq
    run y_paced     b110_2x $T +mode=paced  +expect +irq
    run y_fast      b110_2x $T +mode=fast   +expect +irq
    run y_toggle    b110_2x $T +mode=toggle +expect +irq +steps=120000
    run y_fast_cx   b110_2x $T +mode=fast   +expect +irq +cxrom=1
    run y_rst_tog   b110_2x $T +mode=toggle +expect +irq +reset +steps=120000
    run y_rstw_fast b110_2x $T +mode=fast   +expect +irq +resetw
    # ... and with a RDY stall every second and every fifth PHI2 cycle (the socket requests
    # raised in a step's first clk, with RDY low around them)
    run y_fast_st2  b110_2x $T +mode=fast   +expect +irq +stallp=2 +steps=120000
    run y_tog_st5   b110_2x $T +mode=toggle +expect +irq +stallp=5 +steps=120000
    # gs_accel with two expansion banks of its own, beside the design
    run z_native    b110_2e $T +mode=native +expect +irq +exp=2
    run z_paced     b110_2e $T +mode=paced  +expect +irq +exp=2
    run z_fast      b110_2e $T +mode=fast   +expect +irq +exp=2
    run z_toggle    b110_2e $T +mode=toggle +expect +irq +exp=2 +steps=120000
    run z_tog_cx    b110_2e $T +mode=toggle +expect +irq +exp=2 +cxrom=1 +steps=120000
    run z_rstw_fast b110_2e $T +mode=fast   +expect +irq +exp=2 +resetw
    run z_rst_tog   b110_2e $T +mode=toggle +expect +irq +exp=2 +reset +steps=120000
    run z_fast_st3  b110_2e $T +mode=fast   +expect +irq +exp=2 +stallp=3 +steps=120000
    run z_fast_mb   b110_2e $T +mode=fast   +expect +irq +exp=2 +mbexp=6
    # ... and with those banks behind the queue, in a memory that answers when it likes
    run w_native    b110_2r $T +mode=native +expect +irq +exp=2
    run w_paced     b110_2r $T +mode=paced  +expect +irq +exp=2
    run w_fast      b110_2r $T +mode=fast   +expect +irq +exp=2
    run w_toggle    b110_2r $T +mode=toggle +expect +irq +exp=2 +steps=120000
    run w_tog_cx    b110_2r $T +mode=toggle +expect +irq +exp=2 +cxrom=1 +steps=120000
    run w_rstw_fast b110_2r $T +mode=fast   +expect +irq +exp=2 +resetw
    run w_rst_tog   b110_2r $T +mode=toggle +expect +irq +exp=2 +reset +steps=120000
    run w_fast_st3  b110_2r $T +mode=fast   +expect +irq +exp=2 +stallp=3 +steps=120000
    run w_tog_st5   b110_2r $T +mode=toggle +expect +irq +exp=2 +stallp=5 +steps=120000
    run w_fast_mb   b110_2r $T +mode=fast   +expect +irq +exp=2 +mbexp=6
    run w_fast_slow b110_2r $T +mode=fast   +expect +irq +exp=2 +xgap=40 +xlat=90
    run w_tog_slow  b110_2r $T +mode=toggle +expect +irq +exp=2 +xgap=40 +xlat=90 +steps=120000
    # ... eight banks of them: entries of banks 04 and 08 beside bank 00's in the near memory
    run v_paced     b110_2s $T +mode=paced  +expect +irq +exp=8 +mbexp=8
    run v_fast      b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8
    run v_toggle    b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +steps=120000
    run v_rstw_fast b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +resetw
    run v_tog_slow  b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +xgap=40 +xlat=90 +steps=120000
    run v_rstx_fast b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +resetx +xlat=300
    run v_rstx_tog  b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +resetx +xlat=300 +steps=120000
    # the queue's "nearly full" forced high in long bursts: a held step may not see its socket cycle end
    run v_wb_fast   b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +wbforce
    run v_wb_tog    b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +wbforce +steps=120000
    run v_wb_rstw   b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +wbforce +resetw
    run v_wb_slow   b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +wbforce +xgap=40 +xlat=90 +steps=120000
    run v_wb_st7    b110_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +wbforce +stallp=7 +steps=120000
    run v_wb_tst5   b110_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +wbforce +stallp=5 +steps=120000
    # ... and the same design at 105 MHz, the accelerator-only build's clock
    run v5_native   b105_2s $T +mode=native +expect +irq +exp=8 +mbexp=8
    run v5_paced    b105_2s $T +mode=paced  +expect +irq +exp=8 +mbexp=8
    run v5_fast     b105_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8
    run v5_toggle   b105_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +steps=120000
    run v5_rstw     b105_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +resetw
    run v5_tog_slow b105_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +xgap=40 +xlat=90 +steps=120000
    run v5_rstx_tog b105_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +resetx +xlat=300 +steps=120000
    run v5_wb_tog   b105_2s $T +mode=toggle +expect +irq +exp=8 +mbexp=8 +wbforce +steps=120000
    run v5_wb_st7   b105_2s $T +mode=fast   +expect +irq +exp=8 +mbexp=8 +wbforce +stallp=7 +steps=120000
    # ... and all 126 banks (T24: the top of bank 7F read before anything wrote it, and in the
    # loop after a ROM copy has emptied the near memory)
    run u_native    b105_2t $T +mode=native +expect +irq +exp=126 +mbexp=126
    run u_paced     b105_2t $T +mode=paced  +expect +irq +exp=126 +mbexp=126
    run u_fast      b105_2t $T +mode=fast   +expect +irq +exp=126 +mbexp=126
    run u_toggle    b105_2t $T +mode=toggle +expect +irq +exp=126 +mbexp=126 +steps=120000
    run u_rstw      b105_2t $T +mode=fast   +expect +irq +exp=126 +mbexp=126 +resetw
    run u_copy      b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126
    run u_copy_rst  b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126 +reset
    run u_recopy    b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126 +recopy
    # ... the second copy asked for at other steps: the step that is held for it is then a read
    # of expansion RAM, which must come from the card and not from the socket
    run u_recopy_b  b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126 +recopy +recopyat=20014
    run u_recopy_c  b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126 +recopy +recopyat=20021
    run u_recopy_d  b105_2k $T +mode=copy   +expect +irq +exp=126 +mbexp=126 +recopy +recopyat=20105
    run c_copy      b110_2c $T +mode=copy   +expect +irq
    run c_copy_rst  b110_2c $T +mode=copy   +expect +irq +reset
    run c_recopy    b110_2c $T +mode=copy   +expect +irq +recopy
    run q_native    b100_2  $T +mode=native +expect +irq
    run q_fast      b100_2  $T +mode=fast   +expect +irq
    run q_toggle    b100_2  $T +mode=toggle +expect +irq +steps=120000
    # the same program, no interrupts: native = paced = fast, step for step
    run e_native    b108_4  $T +mode=native +expect +wlog=wstream.txt
    run e_paced     b108_4  $T +mode=paced  +expect +wlog=wstream.txt
    run e_fast      b108_4  $T +mode=fast   +expect +wlog=wstream.txt
    run e_fast100   b100_2  $T +mode=fast   +expect +wlog=wstream.txt
    run e_dl108     b108_3d $T +mode=fast   +expect +wlog=wstream.txt
    run e_dl100     b100_2d $T +mode=fast   +expect +wlog=wstream.txt
    run e_dx100     b100_2x $T +mode=fast   +expect +wlog=wstream.txt
    run e_dx108     b108_2x $T +mode=fast   +expect +wlog=wstream.txt
    run e_dx110     b110_2x $T +mode=fast   +expect +wlog=wstream.txt
    run e_copy      b110_2c $T +mode=copy   +expect +wlog=wstream.txt
    run f_native    b110_2e $T +mode=native +expect +exp=2 +wlog=wstream.txt
    run f_paced     b110_2e $T +mode=paced  +expect +exp=2 +wlog=wstream.txt
    run f_fast      b110_2e $T +mode=fast   +expect +exp=2 +wlog=wstream.txt
    run g_paced     b110_2r $T +mode=paced  +expect +exp=2 +wlog=wstream.txt
    run g_fast      b110_2r $T +mode=fast   +expect +exp=2 +wlog=wstream.txt
fi
DO_ROM=0
if [[ "$SUITE" == "rom" || "$SUITE" == "all" ]]; then
    if [[ -n "${ROM:-}" && -f "${ROM:-}" ]]; then
        DO_ROM=1
        R="+rom=$ROM +steps=$STEPS +wlog=wstream.txt"
        run r_native    b108_4  $R +mode=native
        run r_paced     b108_4  $R +mode=paced
        run r_fast      b108_4  $R +mode=fast
        run r_fast_cx   b108_4  $R +mode=fast +cxrom=1
        run r_fast100   b100_2  $R +mode=fast
        run r_f816      b108_4f $R +mode=fast
        run r_dl108     b108_3d $R +mode=fast
        run r_dl100     b100_2d $R +mode=fast
        run r_dx100     b100_2x $R +mode=fast
        run r_dx108     b108_2x $R +mode=fast
        run r_dx110     b110_2x $R +mode=fast
        run r_copy      b110_2c $R +mode=copy
        run s_native    b110_2e $R +mode=native +exp=2
        run s_fast      b110_2e $R +mode=fast   +exp=2
        run t_paced     b110_2r $R +mode=paced  +exp=2
        run t_fast      b110_2r $R +mode=fast   +exp=2
        run m_native    b105_2t $R +mode=native +exp=126 +mbexp=126
        run m_paced     b105_2t $R +mode=paced  +exp=126 +mbexp=126
        run m_fast      b105_2t $R +mode=fast   +exp=126 +mbexp=126
        run m_copy      b105_2k $R +mode=copy   +exp=126 +mbexp=126
    elif [[ "$SUITE" == "rom" ]]; then
        echo "rom suite: set ROM=<path to a 128 KB ROM 01 image>"; exit 1
    else
        echo "NOTE: ROM not set - the ROM 01 end-to-end suite is skipped"
    fi
fi
wait

# ---------------------------------------------------------------- results
fail=0
printf '%-12s %-5s %s\n' run result summary
for n in "${NAMES[@]}"; do
    log="$OUT/$n/sim.log"
    if grep -q '^PASS$' "$log"; then res=PASS; else res=FAIL; fail=1; fi
    printf '%-12s %-5s %s\n' "$n" "$res" "$(grep -E '^---- run:' "$log" | sed 's/^---- run: //')"
    if [[ $res == FAIL ]]; then grep -E "ERROR|FAIL|TIMEOUT|%Error" "$log" | head -8; fi
done

same() {    # label, reference run, other runs...: step hash and write stream must be identical
    local label="$1" ref="$2"; shift 2
    local h0 h t
    h0="$(grep -E '^---- point reached' "$OUT/$ref/sim.log")"
    t="$(grep -E '^---- time:' "$OUT/$ref/sim.log" | sed 's/^---- time: //')"
    echo "$label: $ref ${h0#---- }; write stream $(wc -l < "$OUT/$ref/wstream.txt" | tr -d ' ') writes"
    echo "  $ref: $t"
    for n in "$@"; do
        h="$(grep -E '^---- point reached' "$OUT/$n/sim.log")"
        t="$(grep -E '^---- time:' "$OUT/$n/sim.log" | sed 's/^---- time: //')"
        if [[ -z "$h0" || "$h" != "$h0" ]]; then
            echo "  $n: DIFFERENT POINT: ${h#---- }"; fail=1
        elif ! cmp -s "$OUT/$ref/wstream.txt" "$OUT/$n/wstream.txt"; then
            echo "  $n: same point, WRITE STREAM DIFFERS:"; fail=1
            diff "$OUT/$ref/wstream.txt" "$OUT/$n/wstream.txt" | head -6
        else
            echo "  $n: same point, identical write stream; $t"
        fi
    done
}
if [[ "$SUITE" == "program" || "$SUITE" == "all" ]]; then
    same "test program" e_native e_paced e_fast e_fast100 e_dl108 e_dl100 e_dx100 e_dx108 e_dx110 e_copy
    same "test program, two expansion banks" f_native f_paced f_fast g_paced g_fast
fi
if [[ $DO_ROM -eq 1 ]]; then
    same "ROM 01 boot ($STEPS steps)" r_native r_paced r_fast r_fast_cx r_fast100 r_f816 r_dl108 r_dl100 r_dx100 r_dx108 r_dx110 r_copy
    same "ROM 01 boot, two expansion banks ($STEPS steps)" s_native s_fast t_paced t_fast
    same "ROM 01 boot, 126 expansion banks ($STEPS steps)" m_native m_paced m_fast m_copy
fi
for n in "${NAMES[@]}"; do
    case "$n" in d*|e_dl*|r_dl*|x*|y*|z*|w*|v*|c_*|e_dx*|r_dx*|e_copy|r_copy|f_*|s_*|g_*|t_*|u_*|m_*) grep -E '^---- (local reads|near memory|step lengths|ROM copy|gs_accel|expansion memory)' "$OUT/$n/sim.log" | sed "s/^---- /$n: /" ;; esac
done
for n in "${NAMES[@]}"; do
    grep -E '^---- socket timing' "$OUT/$n/sim.log" | sed "s/^---- /$n: /"
done > "$OUT/timing.txt"
echo "socket timing per run: $OUT/timing.txt"
if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAIL"; fi
exit $fail
