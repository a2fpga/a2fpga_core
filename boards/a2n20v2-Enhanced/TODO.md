# A2N20v2-Enhanced TODO

## High Priority

- [ ] **Fix audio output** - `clk_audio_w` has no driver, causing `audio_out`, `apple_speaker`, and related modules to be swept away during synthesis optimization
- [ ] Complete interface between PicoSoC and the rest of the system
- [ ] Complete the Disk II emulation and integrate with OSD

## Medium Priority

- [ ] Figure out how to persist settings to either the Tang Nano 20K attached flash or onto the SD Card
- [ ] Create the on-screen display (OSD) software
- [ ] Determine how to enter the OSD on a IIgs since /INH to replace the ROM is not viable

## Low Priority / Future

- [ ] Document the PicoSoC peripheral memory map
- [ ] Add configuration options for slot assignments via OSD

## Known Issues

- Audio modules are being optimized away due to missing clock driver (see High Priority)
- Build warnings about `doc_osc_halt_w` undeclared signal (line 608 in top.sv)

## Build Status

- Last verified build: 2026-01-16
- Timing: All constraints met (clk_logic: 69.3 MHz actual vs 54 MHz required)
- Resource usage: Logic 42%, BSRAM 68%, DSP 64%
