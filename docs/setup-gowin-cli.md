# Gowin CLI Setup (for headless / agentic builds)

This is the operational guide for building A2FPGA boards from the command line with
`gw_sh`. For Gowin **download links** and the full macOS fixer-script details, see
[`../tools/README.md`](../tools/README.md) — this doc links there rather than copying.

## Why CLI matters here

Agentic development depends on headless builds. The Gowin GUI is not scriptable from an
agent; `gw_sh` (a Tcl shell) is. Every build/timing step below is designed to run from a
shell an agent controls.

## 1. Install Gowin

Download the Gowin EDA (Education edition builds all parts currently used by A2FPGA boards).
Links and editions: [`../tools/README.md`](../tools/README.md#getting-the-software).

> ⚠️ Version sensitivity: the main README notes some boards/flows are sensitive to Gowin
> version. Check [boards.md](boards.md) and `boards/<board>/TODO.md` if a build misbehaves.

## 2. macOS one-time fix (required)

On macOS the Gowin binaries need their dynamic-link references patched before `gw_sh` runs.
For **CLI-only** use (no sudo):

```bash
tools/gowin_cli_fix_macos.sh
```

Idempotent and safe to re-run. If it reports "nothing to fix", a newer Gowin build resolved
the issue upstream. For full GUI use, see `tools/gowin_eda_mac_fixer.sh`. Details:
[`../tools/README.md`](../tools/README.md#macos-setup).

## 3. The `gw_sh` path

```
macOS:   /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
Windows: C:\Gowin\Gowin_V<ver>\IDE\bin\gw_sh.exe
Linux:   /opt/gowin/IDE/bin/gw_sh
```

## 4. Building a board — the pipe method (ONLY supported way)

> ✅ **Easiest:** use the helper script, which auto-discovers the board's `.gprj` and runs
> the timing check for you:
> ```bash
> tools/build.sh <board>        # full build (syn + PnR + bitstream)
> tools/build.sh <board> syn    # synthesis only
> ```
> Claude Code users: the `/build` skill does the same. The manual method below is what the
> script runs under the hood.

> ❌ Never use `gw_sh -exit -e ...` or run a copy from `~/bin/`. Use the pipe method.

```bash
cd boards/<board>
echo 'open_project <project>.gprj
run all
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

- `run all` = synthesis + place & route + bitstream. `run syn` = synthesis only.
- **The `.gprj` filename is not always `<board>.gprj`.** See [boards.md](boards.md) for the
  exact project file per board (e.g. `a2n20v2-GS` uses `a2n20v2_gs.gprj`).
- `prebuild.tcl` runs automatically on `open_project`, regenerating `hdl/datetime.svh`.
- OpenGL/Chromium warnings on macOS are safe to ignore.

## 5. Checking timing (REQUIRED after every P&R) {#checking-timing}

A build is **not done** until timing is verified clean:

```bash
grep -E "Violated|Fmax" boards/<board>/impl/pnr/<board>_tr_content.html | head -20
```

A healthy build has:
- **0** setup-violated and **0** hold-violated endpoints
- Actual **Fmax ≥ Constraint** for every clock
- **TNS = 0.000** for every clock domain

> Note: on the GW5AT, identical designs can yield 0–198 violations between PnR runs.
> If a clean design suddenly violates, re-run before assuming a logic regression.
> See [gotchas.md](gotchas.md).

## 6. Key output files (under `boards/<board>/impl/`)

| File | Purpose |
|---|---|
| `pnr/<board>.fs` | Bitstream for programming |
| `pnr/<board>.rpt.txt` | Resource usage, I/O banks, clocks, pinout (quick CLI review) |
| `pnr/<board>_tr_content.html` | Timing report (check this!) |
| `pnr/<board>.power.html` | Power analysis |
| `gwsynthesis/<board>.log` | Synthesis log (warnings/errors) |

## See also

- [`../tools/README.md`](../tools/README.md) — downloads, fixer scripts, full Tcl reference
- [boards.md](boards.md) — per-board `.gprj` names and flashing commands
