# Board Matrix

The A2FPGA core targets several boards that differ by FPGA chip, framebuffer memory, and
maturity. **Pick the right board before doing anything** — the build command, memory
architecture, and known issues all depend on it. If a task doesn't name a board, ask the user.

Each board lives under `boards/<dir>/` with its own Gowin project, board-specific `hdl/`,
build outputs in `impl/pnr/`, and a `TODO.md` with current status and priorities.

## Matrix

| Board                                                      | FPGA module / chip                    | VRAM          | FB    | Ensoniq | `.gprj` file            | Status                                                 |
| ---------------------------------------------------------- | ------------------------------------- | ------------- | ----- | ------- | ----------------------- | ------------------------------------------------------ |
| [`a2n20v2`](../boards/a2n20v2/README.md)                   | Tang Nano 20K / GW2AR-LV18QN88C8/I7   | BSRAM         | None  | None    | `a2n20v2.gprj`          | **Stable production** (recommended; supports IIgs)     |
| [`a2n20v2-GS`](../boards/a2n20v2-GS/README.md)             | Tang Nano 20K / GW2AR-LV18QN88C8/I7   | BSRAM + SDRAM | SDRAM | SDRAM   | `a2n20v2_gs.gprj`       | Experimental — IIgs/Ensoniq audio focus                |
| [`a2n20v2-Enhanced`](../boards/a2n20v2-Enhanced/README.md) | Tang Nano 20K / GW2AR-LV18QN88C8/I7 | SDRAM | SDRAM | SDRAM | `a2n20v2_enhanced.gprj` | Experimental — BL616 MCU coprocessor for USB & SD Card |
| [`a2mega`](../boards/a2mega/README.md) | Tang Mega 60K / GW5AT-LV60PG484AC1/I0 | DDR3 | DDR3 | BSRAM | `a2mega.gprj` | WIP, active development |
| [`a2p25`](../boards/a2p25/README.md) | Tang Primer 25K / GW5A-LV25MG121NC1/I0 | BSRAM | None | ESP32 | `a2p25.gprj` | WIP, no off-chip memory, no FB possible |
| [`a2n9`](../boards/a2n9/README.md) | Tang Nano 9K / GW1NR-LV9QN88PC6/I5 | BSRAM | PSRAM | None | `a2n9.gprj` | Deprecated — limited resources, no IIgs |
| [`a2n20v1`](../boards/a2n20v1/README.md) | Tang Nano 20K / GW2AR-LV18QN88C8/I7 | BSRAM | None | None | `a2n20v1.gprj` | Deprecated — superseded by a2n20v2 |

> ⚠️ **The `.gprj` filename does not always match the directory name.** Use the exact name
> from the table above in the `open_project` line of a build. See
> [setup-gowin-cli.md](setup-gowin-cli.md#4-building-a-board--the-pipe-method-only-supported-way).

## Notable per-board differences

- **Framebuffer memory differs by board.** `a2mega` uses DDR3 (no ghosting); the Tang Nano 20K boards use SDRAM. The memory controller and its quirks are board-specific — see
  [gotchas.md](gotchas.md) and `boards/<board>/hdl/video/`.
- **IIgs / super-hires support** is currently on the a2n20v2 family and later board.
- **Coprocessor firmware:** `a2n20v2-Enhanced` uses an external **BL616 MCU** (firmware under
  `boards/a2n20v2-Enhanced/src/a2n20_bl616/`, built outside Gowin). The earlier on-FPGA PicoRV32 soft core (PicoSoC) has been removed — see that board's [src/README.md](../boards/a2n20v2-Enhanced/src/README.md).  Newer boards (a2mega, a2p25) use an ESP32S3 module as a co-processor.
- The Tang Nano boards are programmed and flashed via the USC-C connector present on the Tang board which emulates an FTDI JTAG+Serial interface.  The Tang Mega and Tang Primer boards have JTAG connections exposed for an external programmer to connect to as well as being programmable over USB-C using openfpgaloader with the `-c esp32s3` option.

## Flashing

Most boards flash over USB with [openFPGALoader](https://github.com/trabucayre/openFPGALoader):

```bash
openfpgaloader -b tangnano20k -f boards/a2n20v2/impl/pnr/a2n20v2.fs   # Tang Nano 20K boards (v1, v2, GS, Enhanced)
openfpgaloader -b tangnano9k  -f boards/a2n9/impl/pnr/a2n9.fs          # Tang Nano 9K
openFPGALoader --bulk-erase -f -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs   # Tang Mega 60K (a2mega) — flash to SPI
openFPGALoader -c esp32s3 boards/a2mega/impl/pnr/a2mega.fs                   # Tang Mega 60K — SRAM (volatile, for test builds)
openFPGALoader --bulk-erase -f -c esp32s3 boards/a2p25/impl/pnr/a2p25.fs     # Tang Primer 25K (a2p25) — on-board ESP32S3
```

> Power-cycle between flashes on DDR3 boards (`a2mega`) — reprogramming without a power cycle
> can fail DDR3 init and produce a black screen that looks like a logic bug. See [gotchas.md](gotchas.md).

## Per-board documentation

Each board's `README.md` (linked in the matrix above) is the entry point for that board and links
to its `TODO.md` and any board-specific design docs under `boards/<board>/docs/`:

| Board | Board docs |
|---|---|
| [a2mega](../boards/a2mega/README.md) | DDR3 framebuffer refactor workplan, DDR3 480p design, scan-timer design, ESP32 OSPI protocol, TransWarp GS reference (`boards/a2mega/docs/`) |
| [a2n20v2-GS](../boards/a2n20v2-GS/README.md) | SDRAM framebuffer workplan (`boards/a2n20v2-GS/docs/`) |
| [a2n20v2-Enhanced](../boards/a2n20v2-Enhanced/README.md) | BL616 firmware + protocol (`src/a2n20_bl616/`) |
| [a2p25](../boards/a2p25/README.md) | LCAM capture session notes, ESP32 SPI protocol (`boards/a2p25/docs/`) |
| a2n20v2 / a2n9 / a2n20v1 | board README + TODO only |

> **Convention:** board-specific design notes, workplans, and session notes go in
> `boards/<board>/docs/`. See [conventions.md](conventions.md#per-board-docs).
