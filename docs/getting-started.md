# Getting Started (environment setup)

This project is organized so that **coding agents (Claude Code and similar) can be productive
quickly**. Clone it, run your agent **in the repo root**, and ask it to set up your build
environment — or run the **`/setup`** skill. This page is the reference for what tools you need
and how to get them; `/setup` automates the checks and walks you through installs.

> The agent entry point is [`../AGENTS.md`](../AGENTS.md); the full wiki index is
> [README.md](README.md).

## Toolchain matrix

| Tool | Needed for | When | Check it's present | Get it |
|---|---|---|---|---|
| **Gowin EDA** (`gw_sh`) | Building any board bitstream (synthesis + place & route) | **Always** | `command -v gw_sh`, or the macOS app at `/Applications/GowinIDE.app/.../bin/gw_sh` | [setup-gowin-cli.md](setup-gowin-cli.md) · download links in [tools/README.md](../tools/README.md#getting-the-software) |
| **openFPGALoader** | Flashing a bitstream to a board | To flash hardware | `openFPGALoader --version` | macOS: `brew install openfpgaloader` (`brew upgrade` for latest) |
| **T-Head RISC-V GCC + Bouffalo SDK** | Building the **BL616** MCU firmware | Only if doing BL616 firmware dev (a2n20v2-Enhanced) | `/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc` **and** `$BL_SDK_BASE` set | [a2n20v2-Enhanced BL616 README](../boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md) |
| **Arduino CLI + ESP32 core** | Building the **ESP32-S3** firmware/JTAG programmer | Only for a2mega / a2p25 | `arduino-cli version` and `arduino-cli core list \| grep esp32` | [a2p25 a2fpga_esp32 README](../boards/a2p25/src/a2fpga_esp32/README.md) |

## What you need, by board / task

- **Build or flash any board** → Gowin + openFPGALoader. That's it for the common case.
- **a2n20v2** (the production board most users have), just building/flashing → Gowin + openFPGALoader.
- **a2n20v2-Enhanced**, working on the **BL616 firmware** → also the T-Head RISC-V toolchain + Bouffalo SDK.
- **a2mega or a2p25** → also the **Arduino + ESP32-S3** toolchain. These boards are programmed via an
  on-board ESP32-S3, so the Arduino toolchain is needed both for the ESP32 firmware *and* for the
  `esp32_usb_jtag` programmer that `openFPGALoader -c esp32s3` talks to (see [boards.md](boards.md)).

## Important toolchain notes

- **Gowin on macOS** needs a one-time CLI patch — run `tools/gowin_cli_fix_macos.sh`. See
  [setup-gowin-cli.md](setup-gowin-cli.md#2-macos-one-time-fix-required).
- **BL616 must use the T-Head toolchain**, not Homebrew's `riscv64-unknown-elf-gcc` — the Homebrew
  build lacks the T-Head extensions the BL616 needs. The T-Head toolchain must be **first on PATH**.
  See the [BL616 README](../boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md).
- The **Education edition of Gowin builds every board** in this repo — no license needed for that.

## Run the setup helper

- **Claude Code:** run **`/setup`** — it detects your OS and what's already installed, then guides
  the rest (asking before it installs anything).
- **Any agent:** ask it to "set up the A2FPGA build environment"; point it at this page.

## Verify it works

A quick synthesis run confirms the Gowin toolchain is wired up correctly:

```bash
tools/build.sh a2n20v2 syn      # synthesis-only smoke test (no place & route)
```

Then flash to confirm openFPGALoader (with hardware attached): `tools/flash.sh a2n20v2 --sram`.

## See also

- [setup-gowin-cli.md](setup-gowin-cli.md) — Gowin install + the `gw_sh` build flow in detail.
- [tools/README.md](../tools/README.md) — Gowin download links, the macOS fixer, `build.sh`/`flash.sh`.
- [boards.md](boards.md) — which board uses which chip, programmer, and toolchain.
