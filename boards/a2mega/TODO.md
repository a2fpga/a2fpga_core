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

## Bring-up status (2026-07-05 live IIgs session)

**WORKING on real hardware**: FPGA core (REG-mode DDR3 calibrates, video
clean), OSPI link (at 2 MHz + workarounds below), OSD console rendering,
SD disk serving — **ProDOS 8 boots from a .dsk over the link**, WiFi
joins + DHCP, boot-time slot config, reset policy.

Open issues from the session, in priority order:

- [ ] Flash the esp32_ospi_proto_proc live-reg_rdata build (built 07-05
      11:58, timing-clean, never flashed — needs IIgs powered off), then
      remove the double-read shim in a2fpga_ospi_link.c
- [ ] Fabric: fix the OSPI sync-skew (feed the proto proc raw esp_sclk —
      it has its own 2FF; cdc_denoise on top skews the sample point
      55-110ns) and re-tune the SPI clock upward from 2 MHz
- [ ] Runtime slot remapping breaks the moved card's I/O (boot-time map
      works; after SLOT_SELECT/CARD/RECONFIG the card's ROM reads work
      but the drive never serves data — repro: remap DiskII to slot 4/6,
      PR#n hangs with motor on, zero sectors)
- [ ] CLI SPI commands bypass the fpga_link mutex — races the disk/menu/
      w5100 tasks and can crash the firmware; also spir len 4096 crashes
      outright (cap + route through fpga_link)
- [ ] DOS 3.3 master image (dos_3.3.dsk) crashes deterministically at
      00/1FBA with RAMRD/ALTZP flipped in Q — ProDOS boots fine, track
      content verified byte-identical to reference GCR, sector 0 + 7 more
      sectors load correctly; likely image/IIgs interplay (try
      dos33_fixed.dsk); park unless it reproduces with known-good images
- [ ] SD 4-bit mount fails, 1-bit works — audit PIN_SD_D1/D2/D3 against
      the board (D2=IO35 was inferred, not confirmed)
- [ ] SD mount is boot-time-only — retry on card-detect (IO46)
- [ ] fpgaupdate: target impl/pnr/a2mega.bin (2.6 MB binary), not the
      20 MB ASCII .fs; fix the menu picker extension filter
- [ ] tools/flash.sh (a2mega): add --verify + bounded retries; document
      "power the host machine off before flashing" (verified failure
      mode) and "openFPGALoader flash writes are flaky — heartbeat after
      power cycle is the real verifier (config CRC)"
- [ ] Arduino/IDF logging: ESP_LOGI is compiled out by the precompiled
      core — use printf (or Serial) for anything that must be visible

## DDR3 / BSRAM roadmap (from the 2026-07 fresh-eyes review)

Done: DDR3 controller MC buffers → registers (BSRAM 118→102); wrap-safe
hdmi_cy CDC; reset-deassert synchronizers; response-FIFO overflow guard;
burst-alignment assert. Open, in recommended order:

- [ ] Bench-verify the REG-mode controller + CDC hardening with the TEXT40
      soak test (the rippling-band reproducer) — required before trusting
      any of the DDR3-path changes
- [ ] C4: round-robin arbitration below the two framebuffer ports — the
      static-priority arbiter has no fairness bound for ports 2-5; this is
      the gate for adding ANY new DDR3 client
- [ ] DOC-on-ESP32 over the PPO bus (see the a2p25 postmortem): FPGA
      timestamps every $C03C-$C03F snoop against a 7M-locked counter and
      streams events over the idle PPO lines (LCD_CAM-shaped, 8 data +
      PCLK + SYNC); ESP32 runs the ES5503 model in DOC cycles. Frees ~28
      BSRAMs net. Make-or-break: event-loss hardening (FPGA event FIFO,
      seq+CRC, OSPI credit flow control, snooped-read-data resync).
      Fallback if it stalls: DOC-side prefetch converts the 838 ns fetch
      deadline to ~30 us, which DDR3 meets — wavetable to DDR3 without
      touching the DOC engine's real-time core
- [ ] Disk track windows → DDR3 after C4 lands (−6 BSRAM net of CDC cost;
      nibble cadence is ~32 us, hugely latency-tolerant)
- [ ] Uthernet II buffer aliasing (−3…−6) — first verify what RMSR/TMSR
      splits IP65/Contiki-class MACRAW drivers actually program

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
