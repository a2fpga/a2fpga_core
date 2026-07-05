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

## ESP32 co-processor (Enhanced feature set)

The on-board ESP32-S3 runs the a2mega port of the a2n20v2-Enhanced feature
set (see [docs/ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md)):

- **On-screen menu & console** rendered by the FPGA's OSD overlay, driven by
  a USB gamepad plugged into the board's USB-A port (handled by the on-FPGA
  `usb_hid_host` core; SELECT toggles Apple II ⇄ menu, Y toggles menu ⇄ console)
- **Disk-image serving from the micro-SD card**: Disk II (.nib/.dsk/.do/.po/.2mg)
  and ProDOS hard disk (.hdv/.po/.2mg) volumes, with a file picker and
  subdirectory browsing
- **Uthernet II (W5100) networking over WiFi**: the FPGA emulates the W5100 in
  MACRAW mode and the ESP32 bridges frames to WiFi with MAC NAT. Configure
  credentials in `A2FPGA/wifi.txt` on the SD card (line 1 SSID, line 2 password)
- **FPGA core self-update** from a bitstream file on the SD card (menu →
  Firmware → FPGA UPDATE), via bit-banged JTAG to the GW5A's config flash
- **Runtime slot configuration** from the menu

The ESP32 firmware lives in [`src/a2fpga_esp32/`](src/a2fpga_esp32/) and builds
with `arduino-cli` (`make compile` in that directory). The ESP32 itself is
reflashed over its USB-C port; it also acts as the USB JTAG bridge that
openFPGALoader uses to program the FPGA.

## Documentation

- [Project documentation wiki](../../docs/README.md) — Gowin CLI setup, architecture, conventions, gotchas
- [Agent & contributor guide](../../AGENTS.md)
- [This board's tasks & status (TODO.md)](TODO.md)
- Board design docs:
  - [DDR3 480p framebuffer refactor workplan](docs/A2FPGA_DDR3_Framebuffer_Refactor_Workplan.md)
  - [DDR3 480p framebuffer design](docs/ddr3_framebuffer_480p_design.md)
  - [Scan timer design](docs/scan_timer_design.md)
  - [ESP32 OSPI protocol & design](docs/ESP32_OSPI_DESIGN.md)
  - [ESP32 Enhanced feature-set port (menu, disks, WiFi, self-update)](docs/ESP32_ENHANCED_PORT.md)
  - [TransWarp GS reference](docs/twgs_reference.md)
