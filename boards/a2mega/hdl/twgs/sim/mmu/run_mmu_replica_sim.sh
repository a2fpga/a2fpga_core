#!/usr/bin/env bash
# S7a: the memory-map replica against its golden model.
#   gs_mmu_decode.sv   (port of the MiSTer rtl/mmu.sv + local / forward_write)
#                      swept against iigs_mmu_model.h (port of vsim/mmu_tb.cpp)
#   gs_mmu_replica.sv  (soft-switch tracker + decode), ROM 01 and ROM 3 builds,
#                      directed facts and randomized bus-cycle sequences
# See boards/a2mega/docs/gs_socket_s7_accelerator_scoping.md 2.3, 6.1 and 9.
#
# Usage: boards/a2mega/hdl/twgs/sim/mmu/run_mmu_replica_sim.sh [+quick]
#   +quick    phase 1 of the decode sweep at 1/16 (smoke test, ~10 s)
# Env: OUT (work dir, default ${TMPDIR:-/tmp}/gs_mmu_sim)
# Requires Verilator >= 5 and a C++ compiler.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWGS="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/gs_mmu_sim}"
mkdir -p "$OUT"
VFLAGS=( --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -CFLAGS "-O2 -I$HERE" )
fail=0

build() {   # name top mdir tb [extra verilator args]
    local name="$1" top="$2" mdir="$3" tb="$4"; shift 4
    verilator "${VFLAGS[@]}" --top-module "$top" --Mdir "$mdir" -o "$name" "$@" "$tb" \
        > "$mdir.verilate.log" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "verilator FAILED for $name (rc=$rc) - see $mdir.verilate.log"
        grep -E "%Error|error:" "$mdir.verilate.log" | head -20
        exit $rc
    fi
}

build Vgs_mmu_decode gs_mmu_decode "$OUT/obj_decode" "$HERE/mmu_decode_tb.cpp" \
      "$TWGS/gs_mmu_decode.sv"
build Vgs_mmu_replica gs_mmu_replica "$OUT/obj_replica_rom01" "$HERE/mmu_replica_tb.cpp" \
      "$TWGS/gs_mmu_decode.sv" "$TWGS/gs_mmu_replica.sv"
build Vgs_mmu_replica gs_mmu_replica "$OUT/obj_replica_rom3" "$HERE/mmu_replica_tb.cpp" \
      -GROM3=1 "$TWGS/gs_mmu_decode.sv" "$TWGS/gs_mmu_replica.sv"

{
    "$OUT/obj_decode/Vgs_mmu_decode" "$@"            || fail=1
    "$OUT/obj_replica_rom01/Vgs_mmu_replica"         || fail=1
    "$OUT/obj_replica_rom3/Vgs_mmu_replica" +rom3    || fail=1
    if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAIL"; fi
} 2>&1 | tee "$OUT/sim.log"
grep -q '^PASS$' "$OUT/sim.log"
