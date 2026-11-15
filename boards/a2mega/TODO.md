# A2Mega TODO

> Status (2026-10-25): board 1.0a3, unreleased and under development, Tang Mega 60K or 138K
> SOM. The live state lives in the board plans: the 1.0a4 rev gate
> [docs/board_1_0a4_requirements.md](docs/board_1_0a4_requirements.md) with
> [docs/a2p25_carryover_2026-10-11.md](docs/a2p25_carryover_2026-10-11.md), the timing policy
> and log [docs/timing_round2.md](docs/timing_round2.md), the socket work
> [docs/gs_socket_65816_scoping.md](docs/gs_socket_65816_scoping.md) section 8b. The 2026-07
> bring-up TODO of the previous board revision is archived at
> [docs/archive/todo_2026-07_enhanced_port_bringup.md](docs/archive/todo_2026-07_enhanced_port_bringup.md).

## Where it stands

The full core runs on the IIgs over USB-C DisplayPort on both SOMs; the ESP32 carries the
Enhanced feature set (menu, disk and HDD serving, Uthernet II over WiFi, self-update, telnet,
FTP). The board has not been attached since 2026-10-11; the 2026-10-22 merge and the
2026-10-25 138B re-closure are built (60K d4826cf7, 138B def55e2d, both 0/0) but not flashed.

## Open

- [ ] Flash and re-verify the merged core on the IIgs: SHR, 2-lane DP audio, disk boot, the
      ESP32 menu (the SHR scanout fix and the 4-lane audio fix came from the a2p25 and have not
      been seen on this board)
- [ ] Bench items left by the merge record: SHR left edge and vertical position, OSD FIRMWARE
      page CORE date, the adapter-census `d` command on this board, PR #34 auto-arm on the 138B
- [ ] ESP32 feature port on this board: USB host input on the USB-C port (item P2) and the
      image storage strategy (LittleFS + FTP today) are verified on the a2p25, not here
- [ ] 138K socket: S6 auto-arm reset sequencing (which chip sinks /RESET on the IIgs is the
      open question, [docs/adb_micro_rom01_notes.md](docs/adb_micro_rom01_notes.md)); then the
      S7 accelerator scoping ([docs/gs_socket_s7_accelerator_scoping.md](docs/gs_socket_s7_accelerator_scoping.md)); fast-core exploration under way ([docs/gs_socket_s7_fast_core_exploration.md](docs/gs_socket_s7_fast_core_exploration.md): the accelerator-domain probe closes 54 MHz steps at 108 MHz, 2026-11-12); accelerator-only build made and simulated, first hardware run pending ([docs/gs_socket_s7_accel_only_build.md](docs/gs_socket_s7_accel_only_build.md))
- [ ] Board rev 1.0a4: close the OPEN items of the requirements doc; the pre-revision exercise
      plan's remaining gates are a maintainer question
- [ ] DDR3 arbiter: round-robin fairness below the two framebuffer ports before adding any new
      DDR3 client; then the disk track windows and the HDD block windows could leave BSRAM
- [ ] 60K BSRAM (107/118): reclaim before adding (Uthernet II buffer aliasing is the candidate)
- [ ] Timing: every build under the no-skating rule; the 138B clk100 next floor is the
      `train_interval` x625 multiply, clk_sym the pixel FIFO BSRAM data-out family
- [ ] Deep listening pass of the pipelined DOC (percussive and swap cases)
- [ ] Nice to have: Bluetooth HID through the ESP32, keyboard passthrough to the Apple II,
      web configuration UX, gamepad-to-paddle emulation
- Idea parked, not for the DOC: the PPO / LCD_CAM-shaped link as a low-latency FPGA-to-ESP32
  transport (the a2p25's LCAM capture work is the reference, `boards/a2p25/docs/archive/`)

## Architecture notes

- ESP32-S3-MINI-1 over the 8-bit OSPI link: register map in
  [docs/ESP32_OSPI_DESIGN.md](docs/ESP32_OSPI_DESIGN.md) (with `a2fpga_regs.h` authoritative
  after the 2026-10-22 remap), port design in [docs/ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md)
- Disk track and HDD block buffers are BSRAM inside the OSPI connector (XFER spaces), not DDR3
- Flash only with `tools/flash.sh` and `GPRJ=` (SecurityBit off, 500 kHz flash phase,
  bulk-erase when the state is unknown; `docs/gotchas.md`)

## Build status

- 2026-10-25: `a2mega.gprj` (60K) d4826cf7 and `a2mega_138B.gprj` def55e2d, 0 violations;
  resource snapshots in `impl/*_resources.json`; neither flashed
