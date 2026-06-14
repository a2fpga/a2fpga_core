---
name: build
description: Build (synthesize + place & route) an A2FPGA FPGA board with the Gowin gw_sh CLI and verify timing. Use when the user asks to build, synthesize, compile, run PnR, or generate a bitstream for a board (a2mega, a2n20v2, a2n20v2-GS, a2n20v2-Enhanced, a2p25, a2n9, a2n20v1).
---

# Build an A2FPGA board

Builds a board with the Gowin `gw_sh` CLI via the supported pipe method, then checks
the timing report. Wraps `tools/build.sh` (the single source of truth — humans run the
same script directly).

## Steps

1. **Determine the board.** If the user named one, use it. If not, ask which board
   (list: `a2mega`, `a2n20v2`, `a2n20v2-GS`, `a2n20v2-Enhanced`, `a2p25`, `a2n9`,
   `a2n20v1`). See [docs/boards.md](../../../docs/boards.md). Do not guess.

2. **Run the build** from the repo root:
   ```bash
   tools/build.sh <board>        # full build: synthesis + place & route + bitstream
   tools/build.sh <board> syn    # synthesis only (faster sanity check)
   ```
   Builds take minutes — run in the background and wait for completion rather than
   polling. The script auto-discovers the board's `.gprj` (names don't always match the
   directory, e.g. `a2n20v2-GS` → `a2n20v2_gs.gprj`).

3. **Report the timing result.** The script prints setup/hold violation counts and the
   bitstream path, and exits non-zero if violations are present or no bitstream was
   produced. A build is **clean** only when:
   - 0 setup-violated and 0 hold-violated endpoints, and
   - Actual Fmax ≥ Constraint for every clock (confirm in the report:
     `boards/<board>/impl/pnr/<proj>_tr_content.html`), and
   - TNS = 0.000 for every clock domain.

   If violations exist, say so plainly with the numbers — do **not** report success.

## Notes

- Never invoke `gw_sh` with `-exit -e` or from `~/bin/` — only the pipe method (the script
  uses it). Toolchain setup: [docs/setup-gowin-cli.md](../../../docs/setup-gowin-cli.md).
- macOS gw_sh path is the default; override with `GW_SH=/path/to/gw_sh` if needed.
- GW5AT (a2mega) PnR has run-to-run variance — a clean design can occasionally show
  violations; re-run before assuming a regression. See [docs/gotchas.md](../../../docs/gotchas.md).
- Power-cycling is a *flashing* concern (see the `flash` skill), not a build concern.
