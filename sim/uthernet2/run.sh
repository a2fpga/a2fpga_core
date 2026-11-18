#!/bin/sh
# Uthernet II card bench (hdl/uthernet2/uthernet2.sv): indirect data port on a
# bus with an early data strobe (a2p25/a2mega timing). Requires Verilator.
set -e
cd "$(dirname "$0")"
verilator --binary --timing -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNSIGNED \
    -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-fatal -j 4 \
    --top-module tb_uthernet2 -o tb_uthernet2 \
    ../../hdl/bus/a2bus_if.sv ../../hdl/slots/slot_if.sv ../../hdl/uthernet2/uthernet2.sv \
    tb_uthernet2.sv
./obj_dir/tb_uthernet2 | tee uthernet2_run.log
grep -q "UTHERNET2 RESULT: PASS" uthernet2_run.log
