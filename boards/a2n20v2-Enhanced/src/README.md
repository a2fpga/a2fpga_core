# A2N20v2-Enhanced Coprocessor Firmware

The A2N20v2-Enhanced uses an external **BL616 MCU** as its coprocessor for on-screen
display, FAT32 SD-card support, and host communication. The firmware lives in:

- [`a2n20_bl616/`](a2n20_bl616/README.md) — BL616 firmware, build setup, and protocol docs.

The FPGA build selects this path via `` `define BL616_SPI `` in
[`../hdl/top.sv`](../hdl/top.sv); it communicates with the FPGA over SPI (see
[`a2n20_bl616/docs/BL616_SPI_PROTOCOL.md`](a2n20_bl616/docs/BL616_SPI_PROTOCOL.md)).

> **History:** earlier revisions used an on-FPGA PicoRV32 soft core (PicoSoC) with its own
> RISC-V firmware (`boot/`, `firmware/`, `libraries/`) and `hdl/picosoc/`. That path has been
> removed in favor of the BL616 MCU (`` `undef PICOSOC `` in `top.sv`). If you need the old
> PicoSoC sources, recover them from git history.
