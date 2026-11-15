#!/usr/bin/env bash
# S7 fast-core bench: stock P65C816 (reference) vs F65C816 (DUT) on ideal
# memory, lockstep + architectural compare, per-benchmark step counts.
# See boards/a2mega/docs/gs_socket_s7_fast_core_exploration.md.
#
# Usage: run_cpu_bench.sh [prog.s | +plusargs ...]
#   default program: prog/bench_all.s (assembled with ca65/ld65 into OUT)
#   +lockstep=0     architectural compare only (cycle-count-changing rungs)
#   +rom=<boot1.rom>  ROM 01 boot stress instead of a program
#   +datalate       DUT on a synchronous memory addressed one step ahead (NA_OUT)
#   +stall +trace +vcd +cycles=N   see tb_cpu_bench.sv
#   +ce2            both cores step every second clk at most
#   +define+F65C816_MCODE_ROM   build the DUT with its microcode in block RAM (needs +ce2)
# Env: OUT (work dir, default ${TMPDIR:-/tmp}/cpu_bench)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWGS="$(cd "$HERE/../.." && pwd)"
STOCK="$TWGS/65C816"
FAST="$TWGS/fast"
OUT="${OUT:-${TMPDIR:-/tmp}/cpu_bench}"
mkdir -p "$OUT"

PROG="$HERE/prog/bench_all.s"
ARGS=()
VDEFS=()
for a in "$@"; do
    case "$a" in
        *.s) PROG="$a" ;;
        +define+*) VDEFS+=( "$a" ) ;;
        *)   ARGS+=( "$a" ) ;;
    esac
done

FILES=( "$STOCK/P65C816_pkg.sv" "$STOCK/mcode.sv" "$STOCK/bit_adder.v" "$STOCK/adder4.v"
        "$STOCK/BCDAdder.v" "$STOCK/AddSubBCD.sv" "$STOCK/ALU.sv" "$STOCK/AddrGen.sv" "$STOCK/P65C816.sv"
        "$FAST/F65C816_pkg.sv" "$FAST/mcode.sv"
        "$FAST/AddSubBCD.sv" "$FAST/ALU.sv" "$FAST/AddrGen.sv" "$FAST/AddrBus.sv" "$FAST/F65C816.sv"
        "$HERE/tb_cpu_bench.sv" )

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
    --top-module tb_cpu_bench --Mdir "$OUT/obj" -o Vtb_cpu_bench \
    --trace --trace-depth 3 -O3 "${VDEFS[@]+"${VDEFS[@]}"}" \
    "${FILES[@]}" > "$OUT/verilate.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "verilator FAILED (rc=$rc) — see $OUT/verilate.log"; grep -E "%Error" "$OUT/verilate.log" | head -20; exit $rc
fi

PROGARG=()
if ! printf '%s\n' "${ARGS[@]+"${ARGS[@]}"}" | grep -q '^+rom='; then
    name="$(basename "${PROG%.s}")"
    ca65 --cpu 65816 -o "$OUT/$name.o" -l "$OUT/$name.lst" "$PROG" || exit 1
    ld65 -C "$HERE/prog/bank0.cfg" -o "$OUT/$name.bin" -m "$OUT/$name.map" "$OUT/$name.o" || exit 1
    PROGARG=( "+prog=$OUT/$name.bin" )
fi
( cd "$OUT" && ./obj/Vtb_cpu_bench "${PROGARG[@]+"${PROGARG[@]}"}" "${ARGS[@]+"${ARGS[@]}"}" ) | tee "$OUT/sim.log"
exit "${PIPESTATUS[0]}"
