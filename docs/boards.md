# Board Matrix

> Status (2026-11-15): rebuilt from the `.gprj` files, the `*_profile.vh` switches and the
> committed `impl/*_resources.json` snapshots of the 2026-10-23/25 builds; a2p25 rows from
> the 2026-11-15 build (Mockingboard + Uthernet II in). The a2n9 and a2n20v1 rows are from
> their project files only (no recent build).

The A2FPGA core targets several boards that differ by FPGA, framebuffer memory, display
output, coprocessor and maturity. **Pick the right board before doing anything**: the build
command, memory architecture and known issues all depend on it. If a task doesn't name a
board, ask the user.

Each board lives under `boards/<dir>/` with its own Gowin project(s), board-specific `hdl/`,
build outputs in `impl/pnr/`, a `TODO.md` and a `docs/` folder indexed from its README.
Deprecated boards and builds live under [`boards/deprecated/`](../boards/deprecated/README.md);
`tools/build.sh` and `tools/flash.sh` still find them by name.

## Matrix

| Board | FPGA | Off-chip memory | Framebuffer | Display | Ensoniq DOC | Coprocessor | `.gprj` | Status |
|---|---|---|---|---|---|---|---|---|
| [`a2n20v2`](../boards/a2n20v2/README.md) | Tang Nano 20K, GW2AR-LV18QN88C8/I7 | none used | none (display-locked) | HDMI 720x480 | no | none | `a2n20v2.gprj` | **Stable production** (recommended; IIgs supported) |
| [`a2n20v2-GS`](../boards/deprecated/a2n20v2-GS/README.md) (`boards/deprecated/`) | Tang Nano 20K, GW2AR-LV18QN88C8/I7 | SDRAM | SDRAM | HDMI 720x480 | SDRAM | none | `a2n20v2_gs.gprj` | **Deprecated build**: superseded by a2n20v2-Enhanced, which has the GS-specific build features |
| [`a2n20v2-Enhanced`](../boards/a2n20v2-Enhanced/README.md) | Tang Nano 20K, GW2AR-LV18QN88C8/I7 | SDRAM | none / SDRAM (see variants) | HDMI 720x480 | SDRAM | BL616 (4-wire SPI) | `a2n20v2_enhanced.gprj`, `_dualrate.gprj`, `_fb.gprj` | Beta: USB host (gamepad, storage, Ethernet), disk-image serving, menu, self-update of MCU and FPGA from a USB stick |
| [`a2mega`](../boards/a2mega/README.md) | Tang Mega SOM, **two dies**: GW5AT-LV60PG484AC1/I0 (60K) or GW5AST-LV138PG484AC1/I0 (138K) | DDR3 | DDR3, 1080p | USB-C DisplayPort Alt Mode, 1080p, 2-lane HBR (board 1.0a3) | DDR3 (pipelined DOC) | ESP32-S3 (8-bit OSPI) | `a2mega.gprj` (60K), `a2mega_138B.gprj` (138K) | WIP, active development: Enhanced feature set ported to the ESP32 and live on the IIgs; 65C816 in-socket work on the 138K; board rev 1.0a4 gated |
| [`a2p25`](../boards/a2p25/README.md) | Tang Primer 25K, GW5A-LV25MG121NC1/I0 | HyperRAM 64 Mbit | HyperRAM, 1080p | USB-C DisplayPort Alt Mode, 1080p, 4-lane RBR through the hardened MIPI D-PHY (board rev displayport1) | HyperRAM (pipelined DOC) | ESP32-S3 (8-bit OSPI, shared a2mega firmware) | `a2p25.gprj` (`legacy_a2p25_rev0.gprj` is the unmaintained previous revision) | WIP: IIgs boots on the new core over DP 1080p with SHR and DOC audio (2026-10-11); Mockingboard + Uthernet II in since 2026-11-15 (96% CLS, 50/56 BSRAM) |
| [`a2n9`](../boards/deprecated/a2n9/README.md) (`boards/deprecated/`) | Tang Nano 9K, GW1NR-LV9QN88PC6/I5 | none used | none | HDMI 720x480 | no | none | `a2n9.gprj` | **Deprecated board**: development board never released beyond a limited set of testers; no IIgs, no SuperSprite |
| [`a2n20v1`](../boards/deprecated/a2n20v1/README.md) (`boards/deprecated/`) | Tang Nano 20K, GW2AR-LV18QN88C8/I7 | none used | none | HDMI 720x480 | no | none | `a2n20v1.gprj` | **Deprecated board**: development board never released beyond a limited set of testers; superseded by a2n20v2 |

> ⚠️ **The `.gprj` filename does not always match the directory name, and the a2mega has one
> per die.** Use the exact name from the table in the `open_project` line of a build, or
> `GPRJ=<file> tools/build.sh <board>`; `tools/build.sh` and `tools/flash.sh` refuse to guess
> on multi-project boards. See
> [setup-gowin-cli.md](setup-gowin-cli.md#4-building-a-board--the-pipe-method-only-supported-way).

### Which cards each board carries

Decided per board in `boards/<board>/hdl/<board>_profile.vh` (see
[build_profiles.md](build_profiles.md)); on the a2mega the three classic cards are per die
(`dp_test_die_pkg`). Default slots from `hdl/slots/slots.hex`: SSC 2, Uthernet II 3,
Mockingboard 4, Disk II 5, ProDOS HDD 6, SuperSprite 7.

| Board | SuperSprite | Mockingboard | Super Serial | Disk II | Uthernet II | ProDOS HDD |
|---|---|---|---|---|---|---|
| a2n20v2, a2n20v1 | ✓ | ✓ | ✓ | | | |
| a2n9 | | ✓ | ✓ | | | |
| a2n20v2-GS | ✓ | ✓ | ✓ | | | |
| a2n20v2-Enhanced | ✓ | ✓ | ✓ | ✓ | ✓ (BL616 USB-Ethernet bridge) | ✓ |
| a2mega 60K | | | | ✓ | ✓ (ESP32 WiFi bridge) | ✓ |
| a2mega 138K | ✓ | ✓ | ✓ | ✓ | ✓ (ESP32 WiFi bridge) | ✓ |
| a2p25 | off (budget: 16 BSRAM + ~5k logic) | ✓ | off (no UART pins) | ✓ | ✓ (ESP32 WiFi bridge) | ✓ |

### The three Enhanced builds

All three are the same `top.sv`; the variant tops `top_dualrate.sv` and `top_fb.sv` add the
defines. The resource numbers are the committed snapshots.

| Project | Defines | What changes | BSRAM |
|---|---|---|---|
| `a2n20v2_enhanced.gprj` | (classic) | SDRAM at the logic clock; SHR aux banks in BSRAM; display-locked render, no framebuffer | 46/46 |
| `a2n20v2_enhanced_dualrate.gprj` | `DUAL_RATE_SDRAM` | SDRAM at 108 MHz behind `mem_port_cdc` (the GS scheme); the VGC/SHR aux banks move to SDRAM (`VGC_IN_SDRAM`) | 31/46 |
| `a2n20v2_enhanced_fb.gprj` | `DUAL_RATE_SDRAM` + `VIDEO_FRAMEBUFFER` | dual-rate plus the SDRAM framebuffer (`sdram_framebuffer` + `framebuffer_writer`), beam-racing kept | 35/46 |

### Where each build stands (committed snapshots)

| Build | Logic (CLS) | BSRAM | Binding resource |
|---|---|---|---|
| a2n20v2_gs | 77% | 19/46 | |
| a2n20v2_enhanced (classic) | 86% | 46/46 | BSRAM: nothing to give; build with `RESOURCE_FAIL=bsram` |
| a2n20v2_enhanced_dualrate / _fb | 86% / 88% | 31 / 35 of 46 | |
| a2mega (60K) | 67% | 107/118 | BSRAM |
| a2mega_138B | 38% | 134/340 | clk100 timing at the +0.5 ns policy line (see `boards/a2mega/docs/timing_round2.md`) |
| a2p25 | 96% | 50/56 | logic and BSRAM; see `boards/a2p25/docs/RESOURCE_AUDIT.md` §8 before adding anything |

## Notable per-board differences

- **Framebuffer memory differs by board.** DDR3 on the a2mega (no ghosting), HyperRAM on the
  a2p25 (controller `hdl/hyperram/`, 108 MHz, no CDC), SDRAM on the Tang Nano 20K boards
  (108 MHz behind `mem_port_cdc` on the GS and the dual-rate Enhanced builds). The controllers
  and their quirks are in [memory-system.md](memory-system.md) and [gotchas.md](gotchas.md).
- **Display output differs by board.** The Tang Nano boards drive HDMI 720x480 through
  `hdl/hdmi/`; the a2mega and a2p25 drive USB-C DisplayPort 1080p through the shared
  `hdl/displayport/` core with a per-board PHY (GW5A SERDES on the a2mega, D-PHY-as-serializer
  plus an SN75DP130 on the a2p25). See [video-pipeline.md](video-pipeline.md).
- **IIgs support** is on the a2n20v2 family and the two DP boards; the a2mega and a2p25
  autodetect the IIgs on the bus (`hdl/bus/gs_detector.sv`), the Tang Nano boards use the DIP
  switch or the same detector. The a2mega 138K build can also take over the IIgs CPU socket
  (`GS_SOCKET`, `boards/a2mega/hdl/twgs/`).
- **Coprocessor firmware.** `a2n20v2-Enhanced`: BL616 MCU, firmware under
  `boards/a2n20v2-Enhanced/src/a2n20_bl616/`. `a2mega` and `a2p25`: one ESP32-S3 firmware tree,
  `boards/a2mega/src/a2fpga_esp32/`, built with `BOARD_REV=103` (a2mega 1.0a3) or `225` (a2p25
  displayport1). The on-FPGA PicoRV32 soft core (PicoSoC) of earlier revisions has been removed
  (see the Enhanced [src/README.md](../boards/a2n20v2-Enhanced/src/README.md)).
- **Programming.** The Tang Nano boards are programmed and flashed over the Tang board's USB-C
  connector, whose BL616 presents an FTDI-compatible JTAG+serial interface. The a2mega and a2p25
  expose JTAG for an external programmer and are also programmable over USB with openFPGALoader's
  `-c esp32s3` cable through their ESP32-S3 (the `esp32_usb_jtag` firmware).

## Flashing

Use the `/flash` skill or `tools/flash.sh <board> [--sram]` (`GPRJ=`/`FS=` on multi-project
boards); it wraps the commands below with the per-board rules.

```bash
openfpgaloader -b tangnano20k -f boards/a2n20v2/impl/pnr/a2n20v2.fs   # Tang Nano 20K boards (v1, v2, GS, Enhanced)
openfpgaloader -b tangnano9k  -f boards/deprecated/a2n9/impl/pnr/a2n9.fs   # Tang Nano 9K (deprecated)
openFPGALoader --bulk-erase -f -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs   # a2mega 60K, flash to SPI (138K: a2mega_138B.fs)
openFPGALoader -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs                   # a2mega, SRAM (volatile, for test builds)
openFPGALoader --bulk-erase -f -c esp32s3 boards/a2p25/impl/pnr/a2p25.fs     # a2p25, through its ESP32-S3
```

GW5A boards (a2mega, a2p25) have three rules that `tools/flash.sh` applies and
[gotchas.md](gotchas.md#a2mega-recovering-from-a-corruptinterrupted-config-flash-write-gw5a)
explains: every project is built with `bit_security 0` (the SecurityBit default races the JTAG
flash path); the flash phase needs a **500 kHz** JTAG clock through the ESP32 bridge, not the
10 MHz default; and when the board is in an indeterminate state, bulk-erase at 500 kHz first,
then flash. Power-cycle between flashes on the DDR3 board; reprogramming without one can fail
DDR3 init and show a black screen that looks like a logic bug.

## Per-board documentation {#per-board-documentation}

Each board's `README.md` (linked in the matrix) is the entry point for that board and indexes
its `TODO.md` and `docs/` folder; the deep material lives there, not in this wiki.

| Board | What its `docs/` holds |
|---|---|
| [a2mega](../boards/a2mega/README.md#documentation) | 1.0a3 bring-up plan and journal, bench test log, 1.0a4 rev requirements, DisplayPort link policy and adapter census, M5 runtime AFE, timing round 2, the pipelined Ensoniq-on-DDR3 design, ESP32 OSPI protocol and Enhanced-port design, 138K SOM ball map, the 65C816 in-socket scoping, TransWarp GS reference; history in `docs/archive/` |
| [a2p25](../boards/a2p25/README.md#documentation) | displayport1 modernization plan with bench results, DP-over-D-PHY design, ball map, PSRAM test, resource audit, top integration plan, ESP32 firmware and feature port; previous-revision notes in `docs/archive/` |
| [a2n20v2-Enhanced](../boards/a2n20v2-Enhanced/README.md#documentation) | Uthernet II design and FPGA-to-BL616 contract, disk-image serving design; BL616 firmware, SPI protocol, USB host and build setup under `src/a2n20_bl616/docs/` |
| [a2n20v2-GS](../boards/deprecated/a2n20v2-GS/README.md#documentation) (deprecated) | the SDRAM framebuffer workplan (implemented; archived) |
| a2n20v2; deprecated a2n9 / a2n20v1 | board README + TODO only; [boards/deprecated/README.md](../boards/deprecated/README.md) says why each is there |

> **Convention:** board-specific design notes, workplans and session notes go in
> `boards/<board>/docs/`; superseded ones move to `boards/<board>/docs/archive/`. See
> [conventions.md](conventions.md#per-board-docs).
