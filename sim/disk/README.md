# Disk card benches

> Status (2026-11-13): `tb_hdd_block.sv` added with the hdd.sv write-drain fix.

- `run.sh` — `tb_hdd_block.sv`: the ProDOS HDD card (`hdl/disk/hdd.sv`) moving one 512-byte
  block each way between the 6502 sector buffer and its memory window, driven the way the
  driver ROM does it. Requires Verilator. Written for the one-word write shift root-caused in
  [boards/a2p25/docs/HDD_BLOCK_WRITE_SHIFT.md](../../boards/a2p25/docs/HDD_BLOCK_WRITE_SHIFT.md);
  the pre-fix card fails it with every word stored at k+1.
