# A2Mega TODO

## Status

**Work In Progress** - Tang Mega 60K version, coming soon.

## High Priority

- [ ] Test the OSPI interface from the ESP32 to ensure it works
- [ ] Complete the OSPI control interface for:
  - [ ] ESP32 OSD display capability
  - [ ] Disk II emulation support

## Medium Priority

- [ ] Complete the FAT32 SD Card support
- [ ] Enable configuration through a web-based UX rather than OSD
- [ ] Investigate using the PPO interface to treat the FPGA as an LCD display
- [ ] Investigate implementing IIgs acceleration (similar to Transwarp GS)
- [ ] Implement and test SDRAM support

## Low Priority / Future

- [ ] Document ESP32 to FPGA communication protocol
- [ ] Create web-based configuration UI

## Architecture Notes

- Uses ESP32 for control/configuration instead of internal PicoSoC
- OSPI interface between ESP32 and FPGA
- Tang Mega 60K provides significantly more FPGA resources

## Build Status

- Last verified build: Unknown
- Board design in progress
