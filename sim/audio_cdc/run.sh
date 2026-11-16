#!/usr/bin/env bash
# Simulate hdl/displayport/audio/audio_sample_cdc.sv against a skewed
# asynchronous source bus. Usage: sim/audio_cdc/run.sh [seed ...]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${TMPDIR:-/tmp}/audio_cdc_sim.$$"
mkdir -p "$out"
iverilog -g2012 -o "$out/tb" \
    "$root/hdl/displayport/audio/audio_sample_cdc.sv" \
    "$here/tb_audio_sample_cdc.sv"
seeds=("$@"); [ ${#seeds[@]} -eq 0 ] && seeds=(1 2 3)
rc=0
for s in "${seeds[@]}"; do
    echo "== seed $s"
    vvp -n "$out/tb" +seed="$s" | tee "$out/seed_$s.log" | grep -v '^VCD' || true
    grep -q '^PASS' "$out/seed_$s.log" || rc=1
done
rm -rf "$out"
exit $rc
