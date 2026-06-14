# Gowin FPGA Tools

## Documentation

- Gowin Software EDA IDE User Guide: https://cdn.gowinsemi.com.cn/SUG100E.pdf
- Gowin Software Tcl Commands User Guide: https://cdn.gowinsemi.com.cn/SUG1220E.pdf
- Gowin Software Quick Start Guide: https://cdn.gowinsemi.com.cn/SUG918E.pdf

## Getting The Software

As of 6/12/26, the direct links to the Gowin Software via their CDN are the ones below:

Full Edition (Requires License and Registration with Gowin)

- Windows V1.9.12.02 SP2: https://cdn.gowinsemi.com.cn/Gowin_V1.9.12.02_SP2_x64_win.zip

- Linux V1.9.12.02 SP2: https://cdn.gowinsemi.com.cn/Gowin_V1.9.12.02_SP2_linux.tar.gz

- Mac V1.9.12.02 SP2: https://cdn.gowinsemi.com.cn/Gowin_V1.9.12.02_SP2_macOS.dmg

Education (No License Required):

- Mac V1.9.11.03 Education: https://cdn.gowinsemi.com.cn/Gowin_V1.9.11.03Education_macOS.dmg

- Linux V1.9.11.03 Education: https://cdn.gowinsemi.com.cn/Gowin_V1.9.11.03_Education_Linux.tar.gz

- Windows V1.9.11.03 Education: https://cdn.gowinsemi.com.cn/Gowin_V1.9.11.03_Education_x64_win.zip

All parts currently used by A2FPGA boards should build with the education version.

## Build & Flash Helper Scripts (recommended)

Two scripts wrap the common workflows so you don't have to remember per-board details
(the `.gprj` filename, the openFPGALoader cable/board tag, the timing check). Run them
from the repo root:

```bash
tools/build.sh <board>          # synthesis + place & route + bitstream, then timing check
tools/build.sh <board> syn      # synthesis only
tools/flash.sh <board>          # program the bitstream to SPI flash (persistent)
tools/flash.sh <board> --sram   # load to volatile SRAM (lost on power-down)
```

`<board>` is a directory under `boards/` (e.g. `a2mega`, `a2n20v2-GS`). Both scripts
auto-discover the board's `.gprj`/bitstream, so the directory-vs-filename mismatch
(e.g. `a2n20v2-GS` → `a2n20v2_gs.gprj`) is handled for you. Use `DRY_RUN=1` to preview
the command without running it. `build.sh` reports timing violations and fails if the
build is not clean.

Claude Code users get the same workflows as the `/build` and `/flash` skills
(`.claude/skills/`). The manual `gw_sh` invocation is documented below for reference.

## Command Line Synthesis with gw_sh

The Gowin EDA includes a Tcl-based command line tool called `gw_sh` that can be used to run synthesis and place & route without opening the GUI.

### Location

**macOS:**
```
/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

**Windows:**
```
C:\Gowin\Gowin_V1.9.9\IDE\bin\gw_sh.exe
```

**Linux:**
```
/opt/gowin/IDE/bin/gw_sh
```

### macOS Setup

On macOS, the Gowin IDE binaries need their dynamic-link references fixed
before the command line tools will run. There are two options:

**CLI builds only (recommended, no sudo):** If you only need command line
synthesis/place & route with `gw_sh`, run:
```
tools/gowin_cli_fix_macos.sh
```
This patches just the command-line/engine binaries (`gw_sh`,
`GowinSynthesis`, etc.) to use the libraries bundled in `IDE/lib`. It
requires no `sudo` (the installed app is owned by your user), is safe to
re-run, and is idempotent — if it reports "nothing to fix", a newer Gowin
build has resolved this upstream and the script is no longer needed. Pass
a custom IDE path as the first argument if Gowin is not in the default
`/Applications/GowinIDE.app` location.

**Full GUI install:** To also use the Gowin IDE GUI (and remove the
Gatekeeper quarantine), apply the complete fixer at install time:
```
gowin_eda_mac_fixer.sh
```
This additionally strips quarantine (needs `sudo`) and fixes the GUI/help
binaries. See the script header for usage.

### Running Synthesis

To run synthesis only:
```bash
cd boards/<board>
echo 'open_project <board>.gprj
run syn
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

Example for a2mega:
```bash
cd boards/a2mega
echo 'open_project a2mega.gprj
run syn
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

### Running Full Build (Synthesis + Place & Route)

To run the complete build flow including bitstream generation:
```bash
cd boards/<board>
echo 'open_project <board>.gprj
run all
exit' | /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
```

### Key Tcl Commands

| Command | Description |
|---------|-------------|
| `open_project <file.gprj>` | Opens a Gowin project file |
| `run syn` | Runs synthesis only |
| `run pnr` | Runs place & route only (requires prior synthesis) |
| `run all` | Runs full flow: synthesis + place & route |
| `exit` | Exits gw_sh |

### Output Files

After synthesis (`impl/gwsynthesis/`):
- `<board>.vg` - Synthesized netlist
- `<board>.log` - Full synthesis log with warnings/errors
- `<board>_syn.rpt.html` - Synthesis report
- `<board>_syn_resource.html` - Detailed resource breakdown

After place & route (`impl/pnr/`):
- `<board>.fs` - Bitstream file for programming
- `<board>.rpt.txt` - **Comprehensive text report** with resource usage, I/O banks, clocks, and pinout
- `<board>.rpt.html` - Place & route report (HTML version)
- `<board>.log` - P&R log
- `<board>.power.html` - Power analysis report
- `<board>.pin.html` - Pin assignment details
- `<board>.tr.html` / `<board>_tr_content.html` - Timing reports

**Tip:** The `.rpt.txt` file is particularly useful for quick command-line review of resource utilization.

### Checking Timing Results (Important!)

After place & route, **always check the timing report for violations**. The detailed timing analysis is in `impl/pnr/<board>_tr_content.html`.

Key sections to review in the timing report:

1. **Timing Summaries** - Look for:
   - `Numbers of Setup Violated Endpoints` - must be 0
   - `Numbers of Hold Violated Endpoints` - must be 0

2. **Max Frequency Summary** - Shows actual vs. constrained frequency:
   ```
   Clock Name    | Constraint    | Actual Fmax
   clk_logic     | 54.000(MHz)   | 69.279(MHz)   <- Good: Fmax > Constraint
   ```
   If Actual Fmax is less than Constraint, timing is violated.

3. **Total Negative Slack (TNS)** - Should be 0.000 for all clocks. Any negative value indicates timing violations.

Example: checking for violations from command line:
```bash
# Look for violation counts and frequency summary
grep -E "Violated|Fmax" boards/<board>/impl/pnr/<board>_tr_content.html | head -20
```

A healthy timing report shows:
- Zero violated endpoints (setup and hold)
- Actual Fmax >= Constraint for all clocks
- TNS of 0.000 for all clock domains

### Using a Tcl Script

For more complex builds, create a Tcl script file:
```tcl
# build.tcl
open_project a2mega.gprj
run all
exit
```

Then run it:
```bash
/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh build.tcl
```

### Notes

- The project's `prebuild.tcl` script (if present) runs automatically when opening the project, generating files like `hdl/datetime.svh` with build timestamps.
- Warnings about OpenGL/Chromium on macOS can be safely ignored for command line builds.
- For the full Tcl command reference, see the Gowin Software Tcl Commands User Guide (SUG1220E.pdf).



