---
name: setup
description: First-run environment setup for the A2FPGA project — detect which build/flash toolchains are installed (Gowin, openFPGALoader, BL616 firmware, ESP32 firmware) and guide installing the missing ones. Use when a new user or agent is getting started, has just cloned the repo, or asks to set up / check the build environment.
---

# Set up the A2FPGA build environment

Detect what's installed and guide the user through installing what's missing. Reference doc:
[docs/getting-started.md](../../../docs/getting-started.md) (toolchain matrix + per-board needs).

**Rules:**
- **Always confirm with the user before installing anything** or running `sudo`. Detect and report
  first, then offer.
- Scope the firmware toolchains to what the user actually needs — ask which board they're using and
  whether they're doing firmware development, rather than installing everything.

## Step 1 — Identify the platform and the goal

- Detect the OS (`uname`). The install commands below are macOS/Homebrew-centric; on Linux/Windows
  adapt and point to [tools/README.md](../../../tools/README.md).
- Ask: **which board** (a2n20v2 is the common one), and **build/flash only, or firmware dev too?**
  Use the answer to decide whether Steps 4–5 apply.

## Step 2 — Gowin EDA (always required, to build any bitstream)

Detect:
```bash
command -v gw_sh || ls /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh 2>/dev/null
```
- **Missing:** offer to download/install the Gowin **Education** edition (no license; builds every
  board here). Links are in [tools/README.md](../../../tools/README.md#getting-the-software)
  (current as of the date noted there). Confirm before downloading/installing.
- **macOS:** the CLI binaries need a one-time patch — run `tools/gowin_cli_fix_macos.sh` (no sudo).
  See [docs/setup-gowin-cli.md](../../../docs/setup-gowin-cli.md#2-macos-one-time-fix-required).
- **Verify** it actually builds: `tools/build.sh a2n20v2 syn` (synthesis-only smoke test). A clean
  run confirms the toolchain works.

## Step 3 — openFPGALoader (required to flash hardware)

Detect: `openFPGALoader --version` (or `openfpgaloader`).
- **Missing:** macOS → offer `brew install openfpgaloader`.
- **Present but old:** newer A2FPGA boards need recent board support (e.g. `-c esp32s3`); if the
  version looks old, offer `brew upgrade openfpgaloader`. Report the version and let the user decide.

## Step 4 — BL616 firmware toolchain (only for a2n20v2-Enhanced firmware dev)

Only if the user is developing the BL616 MCU firmware. This needs **three** things — the
T-Head toolchain, the Bouffalo SDK **at the right tag**, and the env pointing at both. Detect all
three:
```bash
# 1) T-Head RISC-V GCC (XuanTie) — NOT Homebrew's riscv64-unknown-elf-gcc
/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc -dumpversion 2>/dev/null   # expect 10.4.0
# 2) Bouffalo SDK present AND pinned to the tested tag
echo "BL_SDK_BASE=$BL_SDK_BASE"
[ -n "$BL_SDK_BASE" ] && git -C "$BL_SDK_BASE" describe --tags 2>/dev/null           # expect v2.3.27
```
- **T-Head GCC:** required for the BL616 extensions (`xtheade`, `zpsfoperand`); **do not** substitute
  Homebrew's `riscv64-unknown-elf-gcc`, and it must be **first on PATH**. Building it is from-source
  and involved — don't attempt inline; point to the README's Toolchain section.
- **SDK version is critical.** The firmware is written against a specific bundled CherryUSB.
  **Require tag `v2.3.27` (CherryUSB v1.5.3).** If `describe --tags` shows anything else (or a bare
  `master`), the build will likely fail with CherryUSB API errors — this is the most common
  cross-machine setup mistake. Fix (confirm with the user first; a bump to a newer SDK is a
  deliberate port): `cd "$BL_SDK_BASE" && git fetch --tags && git checkout v2.3.27`.
- Authoritative steps (toolchain build, SDK pin, env vars, both `firmware/` and `firmware_host/`
  builds) are in
  [boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md](../../../boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md)
  (Build Environment Setup) and its
  [docs/macos_build_setup.md](../../../boards/a2n20v2-Enhanced/src/a2n20_bl616/docs/macos_build_setup.md).
  Once in place, offer to run `PATH=/opt/riscv-toolchain/xuantie/bin:$PATH BL_SDK_BASE=<path> make
  CHIP=bl616 BOARD=bl616dk` (a clean run ends with `Built target combine`).

## Step 5 — ESP32-S3 toolchain (only for a2mega / a2p25)

Only if the user is on a2mega or a2p25. These boards use Arduino-style ESP32-S3 sketches (`.ino`)
for both the on-board firmware and the `esp32_usb_jtag` programmer that `openFPGALoader -c esp32s3`
uses. Detect:
```bash
arduino-cli version 2>/dev/null && arduino-cli core list 2>/dev/null | grep -i esp32
```
- **Missing:** offer `brew install arduino-cli`, then install the ESP32 core
  (`arduino-cli core install esp32:esp32`) — confirm first. Arduino IDE works too.
- For board/sketch specifics, point to
  [boards/a2p25/src/a2fpga_esp32/README.md](../../../boards/a2p25/src/a2fpga_esp32/README.md).

## Step 6 — Summarize

Report a checklist of what's present / installed / still needed, and the next action (e.g. "run
`tools/build.sh <board>` to build, `tools/flash.sh <board>` to flash"). Link
[docs/getting-started.md](../../../docs/getting-started.md) for the full reference.
