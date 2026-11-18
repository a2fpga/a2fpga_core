#!/bin/sh
# hdl/support/iir_filter_gw5a.v (Arora V arithmetic) against hdl/support/iir_filter.v
# (the GW2A file), both under hdl/sound/audio_out.v, cycle for cycle; plus the
# frequency response of the a2p25 configuration (54 MHz, flt_rate 5,594,066)
# beside the Tang Nano one (27 MHz, 7,056,000). Requires Verilator.
set -e
cd "$(dirname "$0")"
mkdir -p obj_dir
# The reference copy gets _ref module names so both can live in one simulation.
perl -pe 's/\bIIR_filter\b/IIR_filter_ref/g; s/\biir_filter_tap\b/iir_filter_tap_ref/g; s/\bDC_blocker\b/DC_blocker_ref/g' \
    ../../hdl/support/iir_filter.v > obj_dir/iir_filter_ref.v
perl -pe 's/\bmodule audio_out\b/module audio_out_ref/; s/\bIIR_filter\b/IIR_filter_ref/g; s/\bDC_blocker\b/DC_blocker_ref/g' \
    ../../hdl/sound/audio_out.v > obj_dir/audio_out_ref.v
verilator --binary --timing -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-REALCVT -Wno-TIMESCALEMOD --timescale 1ns/1ps -Wno-fatal -j 4 \
    --top-module tb_audio_out_gw5a -o tb_audio_out_gw5a \
    ../../hdl/support/iir_filter_gw5a.v ../../hdl/sound/audio_out.v \
    obj_dir/iir_filter_ref.v obj_dir/audio_out_ref.v tb_audio_out_gw5a.sv
./obj_dir/tb_audio_out_gw5a "$@" | tee audio_out_run.log
grep -q "AUDIO OUT RESULT: PASS" audio_out_run.log
