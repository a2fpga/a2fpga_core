# A2P25 Card

> Status (2026-10-25): rewritten for the displayport1 board revision. The IIgs boots on the
> new core over DisplayPort 1080p with SHR and DOC audio (2026-10-11); the board is in
> active bring-up and not a release.

The A2P25 is the A2FPGA Apple II card built around the
[Tang Primer 25K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html)
SOM (Gowin GW5A-LV25MG121). The current board revision, **displayport1**, adds a 64 Mbit
HyperBus PSRAM (Infineon S27KL0642), an ESP32-S3 coprocessor on an 8-bit OSPI link, and a
USB-C DisplayPort Alt Mode output driven from the GW5A's hardened MIPI D-PHY used as a raw
serializer (4 lanes, RBR, 1080p) through an SN75DP130 retimer. It is unreleased and under
development; the earlier revision is not maintained.

What the core carries on this board (decided in `hdl/a2p25_profile.vh`; the GW5A-25 is
logic-bound at ~97% CLS and 52/56 BSRAM):

- Apple II / //e / IIgs video including SHR, through a HyperRAM framebuffer scanned out at
  1080p over DisplayPort (`framebuffer_1080p` + the shared `hdl/displayport` core)
- IIgs Ensoniq DOC in the fabric (`doc5503_pipelined`, wavetable in HyperRAM behind a fetch
  cache at the arbiter's top priority)
- Disk II (slot 5) and ProDOS hard disk (slot 6) images served by the ESP32
- IIgs autodetect on the bus; the Apple's reset is held by the ESP32 until media is mounted
- Mockingboard (slot 4) and Uthernet II (slot 3, ESP32 WiFi bridge) since the 2026-11-15
  BSRAM pass (`docs/RESOURCE_AUDIT.md` §8)
- Off: SuperSprite (16 BSRAM + ~5k logic, does not fit), Super Serial Card (no UART pins on
  this revision)

## Building and flashing

```bash
tools/build.sh a2p25                    # a2p25.gprj (the only full-core project)
tools/flash.sh a2p25                    # through the on-board ESP32-S3 (openFPGALoader -c esp32s3)
```

The board has several bench projects beside the core: `a2p25_dp_test*.gprj` (DisplayPort
colorbars, 2 and 4 lanes, probes, blind-sink and AUX-observation variants),
`a2p25_psram_test_ck54/81/108.gprj` (the HyperRAM eye-scan test at three clock rates),
`a2p25_psram_test_ck108_xc.gprj` (the same at 108 with device detection, for the Xccela second source) and
`legacy_a2p25_rev0.gprj` (the previous revision's core under `hdl/legacy/`, not maintained). Pass
`GPRJ=<file>` to `tools/build.sh` and `tools/flash.sh` for those; both refuse to guess.
Build with `bit_security 0` as every GW5A project here does (see `docs/gotchas.md`).

## ESP32-S3 coprocessor

The board runs the **shared a2mega ESP32-S3 firmware** (`boards/a2mega/src/a2fpga_esp32/`)
built as board revision 225: USB-C PD and DP Alt Mode entry (FUSB302B, mux control, HPD
reconstruction from PD VDMs), the Enhanced feature set over the OSPI link (on-screen menu and
console, Disk II and HDD image serving, slot configuration, reset hold), WiFi with a telnet
console and FTP, and network bitstream streaming. Build and flash instructions:
[docs/ESP32_FW_A2P25.md](docs/ESP32_FW_A2P25.md); the feature port's status:
[docs/ESP32_FEATURE_PORT.md](docs/ESP32_FEATURE_PORT.md) (P1–P4 verified 2026-10-12). Storage is
the ESP32's LittleFS plus USB mass storage on the ESP32's own USB port; there is no SD card.

## Documentation

- [Project documentation wiki](../../docs/README.md) — Gowin CLI setup, architecture, conventions, gotchas
- [Agent & contributor guide](../../AGENTS.md)
- [This board's tasks & status (TODO.md)](TODO.md)
- Board design docs (`docs/`):
  - [MODERNIZATION_PLAN.md](docs/MODERNIZATION_PLAN.md) — the displayport1 plan: priorities, clocking, the HyperRAM controller and memory map, the bench ladder and every bench result (DP first light, PSRAM, 4-lane 1080p, framebuffer, the IIgs boot, SHR and DOC root causes, the USB-C-to-HDMI adapter investigation), known risks, build provenance
  - [DP_ALTMODE_DPHY_DESIGN.md](docs/DP_ALTMODE_DPHY_DESIGN.md) — why DisplayPort over the D-PHY, the analog chain, the alternatives rejected, the link policy inherited from the a2mega census
  - [PINOUT_DISPLAYPORT1.md](docs/PINOUT_DISPLAYPORT1.md) — netlist-derived ball map (cited from every `.cst`)
  - [PSRAM_TEST.md](docs/PSRAM_TEST.md) — the HyperRAM eye-scan test and its results
  - [RESOURCE_AUDIT.md](docs/RESOURCE_AUDIT.md) — per-module resource accounting on the GW5A-25, the DOC fetch cache, the port-priority decision; read before adding anything
  - [TOP_INTEGRATION_PLAN.md](docs/TOP_INTEGRATION_PLAN.md) — how the new top was derived from the a2mega top (memory map, resource scoping, decisions)
  - [HDD_BLOCK_WRITE_SHIFT.md](docs/HDD_BLOCK_WRITE_SHIFT.md) · [STICK_CORRUPTION_2026-11-17.md](docs/STICK_CORRUPTION_2026-11-17.md) — the two disk-path corruption root causes: the `hdd.sv` one-word write shift (11-13) and the ESP32 firmware serving a junk write request from an unconfigured FPGA during a reload, which extended a `.nib` to 4 GB and took the stick's directory with it (11-17); read before touching `disk.c` or a restart/reload path
  - [ESP32_FW_A2P25.md](docs/ESP32_FW_A2P25.md) · [ESP32_FEATURE_PORT.md](docs/ESP32_FEATURE_PORT.md) — the firmware on this board and the Enhanced feature port; its consoles (serial CLI, key-driven telnet, FTP, port 2323) are in [../a2mega/docs/ESP32_CONSOLE.md](../a2mega/docs/ESP32_CONSOLE.md)
  - [HyperRAM bandwidth budget (§3)](../../docs/memory_bandwidth_analysis.md#3-a2p25--hyperram-bandwidth-budget) — the original budget, revised by the modernization plan's section 4
  - [docs/archive/](docs/archive/README.md) — the previous revision's material: the LCAM capture-link notes (the link is proven lossless transfer work and may be reused; its ES5503 use is abandoned), the 3-wire SPI protocol
- [src/README.md](src/README.md) — points at the shared ESP32 firmware in `boards/a2mega/src/` (the previous revision's firmware was deleted 2026-10-25)
