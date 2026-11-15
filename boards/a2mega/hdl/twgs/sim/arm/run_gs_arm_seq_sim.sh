#!/usr/bin/env bash
# The socket arm sequencer (gs_socket_arm_seq.sv) - the S6 reset rule with
# the LAST release of /RESET as its reference - feeding the real socket PHY
# and a PHI2-clocked core.  See the header of tb_gs_arm_seq.sv for the cases
# and boards/a2mega/docs/gs_socket_s7_accelerator_scoping.md 9.5.
#
# Usage: boards/a2mega/hdl/twgs/sim/arm/run_gs_arm_seq_sim.sh [+plusargs]
#   +nrand=N     extra random hold times of the second card (default 2)
#   +seed=N      seed for them
#   +vcd
# Env: OUT (work dir, default ${TMPDIR:-/tmp}/gs_arm_seq_sim)
# Requires Verilator >= 5 (timing support).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWGS="$(cd "$HERE/../.." && pwd)"
CORE="$TWGS/65C816"
OUT="${OUT:-${TMPDIR:-/tmp}/gs_arm_seq_sim}"
mkdir -p "$OUT"

FILES=( "$CORE/P65C816_pkg.sv" "$CORE/mcode.sv" "$CORE/bit_adder.v" "$CORE/adder4.v"
        "$CORE/BCDAdder.v" "$CORE/AddSubBCD.sv" "$CORE/ALU.sv" "$CORE/AddrGen.sv"
        "$CORE/P65C816.sv" "$TWGS/gs_socket_phy.sv" "$TWGS/gs_socket_arm_seq.sv"
        "$HERE/tb_gs_arm_seq.sv" )

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -O3 \
    --top-module tb_gs_arm_seq --Mdir "$OUT/obj" -o Vtb_gs_arm_seq \
    --trace --trace-depth 3 \
    "${FILES[@]}" > "$OUT/verilate.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "verilator FAILED (rc=$rc) - see $OUT/verilate.log"; grep -E "%Error" "$OUT/verilate.log" | head -20; exit $rc
fi
( cd "$OUT" && ./obj/Vtb_gs_arm_seq "$@" ) | grep -v "CPU_RESET" | tee "$OUT/sim.log"
grep -q '^PASS$' "$OUT/sim.log"
