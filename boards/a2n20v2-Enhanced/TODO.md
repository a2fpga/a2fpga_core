# A2N20v2-Enhanced TODO

## High Priority

- [ ] **Fix audio output** - `clk_audio_w` has no driver, causing `audio_out`, `apple_speaker`, and related modules to be swept away during synthesis optimization
- [ ] Complete interface between PicoSoC and the rest of the system
- [ ] Complete the Disk II emulation and integrate with OSD

## Medium Priority

- [ ] Figure out how to persist settings to either the Tang Nano 20K attached flash or onto the SD Card
- [ ] Create the on-screen display (OSD) software
- [ ] Determine how to enter the OSD on a IIgs since /INH to replace the ROM is not viable

- [x] Lift the HDD read-only containment in `firmware_host/disk.c` (`mount_hdd`, `rw = false`):
      done 2026-11-15 after a write test on this board. Two `hdl/disk/hdd.sv` write-drain bugs were
      behind the corruption: every word one word late (fixed 2026-11-13,
      [a2p25 write-up](../a2p25/docs/HDD_BLOCK_WRITE_SHIFT.md)) and, on this board's shared storage
      port, every other word dropped because the drain never waited for write completion (fixed
      2026-11-15, ST_DRAIN_WAIT)

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
