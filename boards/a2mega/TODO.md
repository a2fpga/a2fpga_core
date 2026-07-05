# A2Mega TODO

## Status

**Work In Progress** — Tang Mega 60K version. The a2n20v2-Enhanced feature set
(menu, SD disk serving, WiFi networking, FPGA self-update) is ported and
building; hardware bring-up of the new co-processor paths is next. See
[docs/ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md).

## High Priority — bring-up of the Enhanced port (all code in place, untested on hardware)

- [ ] Verify the OSPI link end-to-end from the ESP32 (`+++` CLI: `spitest`, `spireg 7`)
- [ ] Verify SD card pins (`PIN_SD_D2`=IO35 inferred from schematic) and 4-bit SDMMC mount
- [ ] Verify USB HID gamepad readback regs (0x16-0x1B) and menu navigation
- [ ] Verify OSD text overlay rendering (`A2REG_VIDEO_ENABLE`, SPACE 1 writes;
      check glyph bit order — flip `row_byte_r[subcnt_r[3:1]]` indexing if mirrored)
- [ ] Verify Disk II track serving (SPACE 4 windows) and HDD block serving (SPACE 5)
- [ ] Verify Apple II reset hold/release polarity through the 74LVC2G06 (a2_res_out_n)
- [ ] Verify W5100 MACRAW bridge + WiFi MAC NAT against IP65/Contiki
- [ ] Verify GW5A JTAG self-update path (IDCODE probe first — reg constants
      mirrored from openFPGALoader's GW5A support, not yet run on silicon)

## Medium Priority

- [ ] Wire MCU scratch regs (0x06, 0x0C-0x0F) to DebugOverlay slots for bring-up
- [ ] Bluetooth HID gamepads/keyboards via the ESP32 (feed the same pad regs)
- [ ] Keyboard passthrough (FPGA usb_hid_host key regs → Apple II keyboard)
- [ ] Enable configuration through a web-based UX (ESP32 WiFi) alongside the OSD
- [ ] Investigate using the PPO interface to treat the FPGA as an LCD display
- [ ] Investigate implementing IIgs acceleration (similar to Transwarp GS)

## Low Priority / Future

- [ ] ESP32 firmware OTA update from the SD card
- [ ] Gamepad → Apple II paddle/joystick emulation (not in Enhanced either)

## Architecture Notes

- Uses ESP32-S3-MINI-1-N8 for control/configuration instead of internal PicoSoC
- OSPI (8-bit parallel) interface between ESP32 and FPGA — register map in
  [docs/ESP32_OSPI_DESIGN.md](docs/ESP32_OSPI_DESIGN.md), Enhanced-port additions in
  [docs/ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md)
- USB-A port is wired to the FPGA (usb_hid_host core), not the ESP32;
  micro-SD, WiFi, and JTAG-to-FPGA are on the ESP32
- Disk track/HDD block buffers are BSRAM (XFER SPACE 4/5), not DDR3
- ⚠️ **BSRAM is at the device limit.** New BSRAM consumers must reclaim first.
  The Ensoniq 64KB wavetable (32 BSRAMs) is NOT trivially movable to DDR3 —
  the DOC's ~838 ns per-fetch deadline loses to DDR3 tail latency (that's why
  it's in BSRAM). Candidate reclaims: Uthernet II buffer aliasing (−3…−6,
  verify driver RMSR/TMSR use first); DOC arbiter-priority preemption is an
  unproven research option

## Build Status

- FPGA + ESP32 firmware (arduino-cli) both build from this tree; see git log
