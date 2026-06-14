---
name: flash
description: Flash an A2FPGA board's bitstream onto the device with openFPGALoader. Use when the user asks to flash, program, upload, load, or deploy a bitstream to a board (a2mega, a2n20v2, a2n20v2-GS, a2n20v2-Enhanced, a2p25, a2n9, a2n20v1).
---

# Flash an A2FPGA board

Programs a board's bitstream with `openFPGALoader`, using the correct cable/board config
per board. Wraps `tools/flash.sh` (humans run the same script directly).

**Flashing is a real, outward action on hardware** — confirm the board and that a device is
connected before running, unless the user already said to go ahead.

## Steps

1. **Determine the board.** If unspecified, ask. See [docs/boards.md](../../../docs/boards.md).

2. **Confirm a bitstream exists.** The script flashes `boards/<board>/impl/pnr/<proj>.fs`.
   If it's missing, build first with the `build` skill (`tools/build.sh <board>`).

3. **Preview, then flash.** To show the exact command without running it:
   ```bash
   DRY_RUN=1 tools/flash.sh <board>
   ```
   Then flash:
   ```bash
   tools/flash.sh <board>          # write to persistent SPI flash (default)
   tools/flash.sh <board> --sram   # load to volatile SRAM (lost on power-down; for quick test)
   ```

## Per-board programming config (handled by the script)

| Board(s) | openFPGALoader |
|---|---|
| a2n20v1, a2n20v2, a2n20v2-GS, a2n20v2-Enhanced (Tang Nano 20K) | `-b tangnano20k` |
| a2n9 (Tang Nano 9K) | `-b tangnano9k` |
| a2mega (Tang Mega 60K), a2p25 (Tang Primer 25K) | `-c esp32s3` (on-board ESP32S3; flash adds `--bulk-erase -f`) |

## Notes

- **a2mega (DDR3): power-cycle the board between flashes.** Reprogramming without a power
  cycle can fail DDR3 init and produce a black screen that looks like a logic bug, not a
  programming failure. The script prints this reminder. See [docs/gotchas.md](../../../docs/gotchas.md).
- Loader install (macOS): `brew install openfpgaloader`.
