# A2Mega Card

This is the project version that builds the FPGA bitstream for the 
[Tang Mega 60K](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k.html)
version of the A2FPGA Apple II card.

The A2Mega does not use FTDI-compatible programming and must be programmed using
[OpenFPGALoader](https://github.com/trabucayre/openFPGALoader).  It is also possible
to program the Tang Mega 60K directly using the instructions [here](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k.html).

Flash the FPGA with the latest version of OpenFPGALoader:

`openFPGALoader --bulk-erase -f -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs`

For development, you can use the SRAM program option for testing builds (will lose the programming on power-down):

`openFPGALoader -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs`


Coming soon

## Documentation

- [Project documentation wiki](../../docs/README.md) — Gowin CLI setup, architecture, conventions, gotchas
- [Agent & contributor guide](../../AGENTS.md)
- [This board's tasks & status (TODO.md)](TODO.md)
- Board design docs:
  - [DDR3 480p framebuffer refactor workplan](docs/A2FPGA_DDR3_Framebuffer_Refactor_Workplan.md)
  - [DDR3 480p framebuffer design](docs/ddr3_framebuffer_480p_design.md)
  - [Scan timer design](docs/scan_timer_design.md)
  - [ESP32 OSPI protocol & design](docs/ESP32_OSPI_DESIGN.md)
  - [TransWarp GS reference](docs/twgs_reference.md)
