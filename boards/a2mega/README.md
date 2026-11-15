# A2Mega Card

> Status (2026-10-25): describes board revision 1.0a3 (unreleased, under development; two SOM
> options). Hardware verification of the ESP32 feature port on the a2mega itself is not
> recorded in the repo; the a2p25 carries the same firmware and verified it there.

The A2Mega is the A2FPGA Apple II card built around a Sipeed Tang Mega SOM on a carrier of
our own design. Two interchangeable SOMs are supported, each with its own project:

| SOM | Device | Project | Notes |
|---|---|---|---|
| Tang Mega 60K | GW5AT-LV60PG484AC1/I0 | `a2mega.gprj` | BSRAM-bound (107/118); the three classic cards are off on this die |
| Tang Mega 138K | GW5AST-LV138PG484AC1/I0 | `a2mega_138B.gprj` | all cards; the 65C816 in-socket build (`GS_SOCKET`); its own DP SERDES IP generated in the IDE |

The board's one external port is USB-C: 4-lane DisplayPort Alt Mode (2 lanes used, HBR,
1080p), USB 2 to the ESP32, and USB-PD, with a TUSB1046A redriver and a FUSB302B PD
controller managed by the ESP32. There is no SD card and no USB-A port; storage and input go
through the ESP32. The framebuffer, the shadow memory and the Ensoniq wavetable live in DDR3.
The next revision, 1.0a4, is specified in
[docs/board_1_0a4_requirements.md](docs/board_1_0a4_requirements.md) and gated on the
exercise plan.

What the core carries (decided in `hdl/a2mega_profile.vh` and per die in `dp_test_die_pkg`):
Apple II / //e / IIgs video including SHR through `framebuffer_1080p` and the shared
DisplayPort core; the IIgs Ensoniq DOC in the fabric with its wavetable in DDR3 (pipelined
DOC); Disk II (slot 5), ProDOS hard disk (slot 6) and Uthernet II (slot 3, bridged to WiFi);
on the 138K also SuperSprite, Mockingboard and the Super Serial Card; IIgs autodetect on the
bus; on the 138K, optionally, the IIgs's own CPU socket.

## Building and flashing

```bash
GPRJ=a2mega.gprj      tools/build.sh a2mega     # 60K SOM
GPRJ=a2mega_138B.gprj tools/build.sh a2mega     # 138K SOM
GPRJ=a2mega.gprj      tools/flash.sh a2mega     # to SPI flash; --sram for a volatile test load
```

`GPRJ=` is required: the board has several projects (the two cores, `a2mega_dp_test*.gprj`
colorbars benches for each die, `flash_rescue.gprj`). Flashing goes through the ESP32-S3's USB
JTAG bridge (`openFPGALoader -c esp32s3`); the GW5A rules (SecurityBit off in every project, a
500 kHz flash phase, bulk-erase first when the board's state is unknown) are in
`docs/gotchas.md` and applied by `tools/flash.sh`. Every a2mega build is held to the timing
policy in [docs/timing_round2.md](docs/timing_round2.md): no re-rolls, +0.5 ns on every clock,
three clean rolls of the final source. Over the network, the ESP32 can stream a bitstream to
the FPGA (`tools/fpga_stream.py`, port 2323) and reload it from the telnet console.

## ESP32-S3 coprocessor

The on-board ESP32-S3 runs the shared firmware in [`src/a2fpga_esp32/`](src/a2fpga_esp32/)
(`make compile` with `arduino-cli`; `BOARD_REV=103` for this board), which also serves the
a2p25. It owns the USB-C PD / Alt Mode policy and HPD, the JTAG bridge and the FPGA updater,
and the a2mega port of the a2n20v2-Enhanced feature set over the 8-bit OSPI link
([docs/ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md), [docs/ESP32_OSPI_DESIGN.md](docs/ESP32_OSPI_DESIGN.md)):

- on-screen menu and console rendered by the FPGA's OSD overlay, also mirrored on a telnet
  console over WiFi
- Disk II (.nib/.dsk/.do/.po/.2mg) and ProDOS hard disk (.hdv/.po/.2mg) image serving, with a
  file picker; images live on the ESP32's flash filesystem and arrive by FTP (no SD card on 1.0a3)
- Uthernet II (W5100) networking: the FPGA emulates the W5100 in MACRAW mode and the ESP32
  bridges frames to WiFi with MAC NAT (`wifi.txt` on the filesystem: SSID, password, optional
  static address)
- runtime slot configuration and the Apple II reset hold until media is mounted
- FPGA core self-update from a bitstream file, over JTAG to the config flash

Menu input from a USB gamepad, keyboard or remote on the USB-C port is the feature port's
item P2 ([boards/a2p25/docs/ESP32_FEATURE_PORT.md](../a2p25/docs/ESP32_FEATURE_PORT.md)),
verified on the a2p25.

## Documentation

- [Project documentation wiki](../../docs/README.md) — Gowin CLI setup, architecture, conventions, gotchas
- [Agent & contributor guide](../../AGENTS.md)
- [This board's tasks & status (TODO.md)](TODO.md)
- Board documentation (`docs/`), grouped:
  - **Board revision and bench ground truth**
    - [test_log.md](docs/test_log.md) — the bench log (every experiment, two tables); ground truth for the 1.0a3 campaign
    - [bringup_1_0a3_log.md](docs/bringup_1_0a3_log.md) — the 1.0a3 bring-up journal · [BRINGUP_1_0A3_PLAN.md](docs/BRINGUP_1_0A3_PLAN.md) — the executed plan (section 1 lists the board's USB-C, PD, SERDES and ESP32 pin facts)
    - [board_1_0a4_requirements.md](docs/board_1_0a4_requirements.md) — the 1.0a4 rev gate · [a2p25_carryover_2026-10-11.md](docs/a2p25_carryover_2026-10-11.md) — what the a2p25 proved for it (its *Remaining gates* section is the live list; the 2026-08 exercise plan is archived)
    - [apple_off_backfeed_level_shifters.md](docs/apple_off_backfeed_level_shifters.md) — level-shifter back-feed with the Apple off (1.0a4 design note)
    - [btb_pinout_1_0a3.md](docs/btb_pinout_1_0a3.md), [a2mega_pinmap_1_0a3.csv](docs/a2mega_pinmap_1_0a3.csv), [tang_mega_die_names.json](docs/tang_mega_die_names.json) — pin and ball maps (cited from the `.cst` files)
    - [SOM_138B_BALLMAP.md](docs/SOM_138B_BALLMAP.md), [tang_mega_138k_analysis.md](docs/tang_mega_138k_analysis.md) — the 138K SOM
    - [SOURCES.md](docs/SOURCES.md) — provenance of vendor material (and what was removed)
  - **DisplayPort output**
    - [adapter_census_results.md](docs/adapter_census_results.md), [acquisition_matrix_results.md](docs/acquisition_matrix_results.md) + [protocol](docs/acquisition_matrix_protocol.md) — which hubs, converters and monitors train, and the link policy that came out of it
    - [m5_afe_adjust_design.md](docs/m5_afe_adjust_design.md), [m5_runtime_afe.md](docs/m5_runtime_afe.md) — runtime swing / pre-emphasis adjustment (the M5 work)
    - [offset_wrap_investigation.md](docs/offset_wrap_investigation.md) — the rotated-image bug and its (applied) fix
    - `gowin_serdes_re_findings.md` — SERDES CSR decode behind the replay ROM (fork-only)
  - **Timing and placement**
    - [timing_round2.md](docs/timing_round2.md) — the durable-closure policy and log (current through the 2026-10-25 re-closure)
    - [pnr_structural_analysis.md](docs/pnr_structural_analysis.md), [cdc_constraint_audit.md](docs/cdc_constraint_audit.md) — the structural campaign and the CDC audit behind it
  - **Memory and audio**
    - [ensoniq_ddr3_pipelined_design.md](docs/ensoniq_ddr3_pipelined_design.md) — the pipelined DOC (shipped; proof in `sim/doc5503/`)
    - [scan_timer_design.md](docs/scan_timer_design.md) — the Apple-timed scan timer
  - **Flashing**
    - [jtag_flash_reliability.md](docs/jtag_flash_reliability.md) — the flashing saga; the 2026-08-15 section has the root cause (SecurityBit + auto-boot race)
  - **ESP32 coprocessor**
    - [ESP32_OSPI_DESIGN.md](docs/ESP32_OSPI_DESIGN.md), [ESP32_ENHANCED_PORT.md](docs/ESP32_ENHANCED_PORT.md)
  - **IIgs CPU socket (138K)**
    - [gs_socket_65816_scoping.md](docs/gs_socket_65816_scoping.md) — the in-socket 65C816: electrical contract, datasheet departures, the S4 integration record
    - [gs_socket_s7_accelerator_scoping.md](docs/gs_socket_s7_accelerator_scoping.md) — accelerator scoping (open questions); §9: memory-map replica and broker proven in simulation (2026-11-11)
    - [gs_socket_s7_fast_core_exploration.md](docs/gs_socket_s7_fast_core_exploration.md) — fast-core exploration log: bench, Fmax probe, optimization ladder
    - [gs_socket_s7_accel_only_build.md](docs/gs_socket_s7_accel_only_build.md) — the accelerator-only build (`a2mega_accel_138B.gprj`): contents, control registers, bring-up ladder; built and simulated, not flashed
    - [adb_micro_rom01_notes.md](docs/adb_micro_rom01_notes.md), [twgs_reference.md](docs/twgs_reference.md) — the IIgs ADB micro's reset behaviour and the TransWarp GS reference
  - [docs/archive/](docs/archive/README.md) — the DDR3 framebuffer refactor, Ensoniq-on-DDR3 post-mortem, JTAG research, the 2026-08 DP bring-up planning and AUX captures
