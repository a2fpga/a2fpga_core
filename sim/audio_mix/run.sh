#!/bin/sh
# Saturating audio mix (hdl/sound/core_audio_mix.sv) against a reference model. Requires Verilator.
set -e
cd "$(dirname "$0")"
verilator --binary --timing -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-fatal -j 4 \
    --top-module tb_core_audio_mix -o tb_core_audio_mix \
    ../../hdl/sound/core_audio_mix.sv tb_core_audio_mix.sv
./obj_dir/tb_core_audio_mix | tee audio_mix_run.log
grep -q "AUDIO MIX RESULT: PASS" audio_mix_run.log
