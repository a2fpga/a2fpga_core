#!/bin/sh
# HDD card block-transfer bench (hdl/disk/hdd.sv): write drain and read fill
# must move all 128 words of a block in place. Requires Verilator.
set -e
cd "$(dirname "$0")"
verilator --binary --timing -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNSIGNED \
    -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-fatal -j 4 \
    --top-module tb_hdd_block -o tb_hdd_block \
    ../../hdl/bus/a2bus_if.sv ../../hdl/slots/slot_if.sv ../../hdl/memory/mem_port_if.sv \
    ../../hdl/disk/drive_volume_if.sv ../../hdl/support/rom.v ../../hdl/disk/hdd.sv \
    tb_hdd_block.sv
# hdd.sv's boot ROM reads hdd_rom.hex relative to the working directory
(cd ../../hdl/disk && "$OLDPWD/obj_dir/tb_hdd_block") | tee hdd_block_run.log
grep -q "HDD BLOCK RESULT: PASS" hdd_block_run.log
