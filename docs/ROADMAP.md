# Roadmap & Backlog

Forward-looking work for the A2FPGA core. This is the place an agent or contributor looks to
answer *"what could I work on?"* and to surface candidate features to the maintainer.

## How this relates to other sources

| Source | Use for |
|---|---|
| **This file** | Larger directional items and the maintainer's intended future work. |
| **GitHub issues** (upstream `a2fpga/a2fpga_core`) | Reported bugs and concrete tracked tasks. **Always check these too.** |
| **`boards/<board>/TODO.md`** | Per-board, often in-progress or short-term items. |

> **Agents:** before proposing or starting a feature, check all three, then *offer* the user
> a specific item rather than picking one unilaterally. Confirm scope and target board first.

## Checking GitHub issues

Issues live on the **upstream** repo `a2fpga/a2fpga_core` (this fork has issues disabled), so
target it explicitly:

```bash
gh issue list -R a2fpga/a2fpga_core                       # open issues
gh issue list -R a2fpga/a2fpga_core --label enhancement   # feature requests
gh issue view <n> -R a2fpga/a2fpga_core                   # details
```

## Themes

These are the active directions, summarized from the per-board `TODO.md` files and open
issues. They are **not prioritized** — priority is the maintainer's call. Each links to the
authoritative detail rather than copying it (that lives in the board TODOs / issues).

### 1. Graphics accuracy & artifacts (cross-board)

The largest cluster of reported bugs is Apple II / IIgs display accuracy in the shared
`hdl/video/` pipeline. Reproductions and discussion in issues:
[#39 Shufflepuck HGR](https://github.com/a2fpga/a2fpga_core/issues/39),
[#26 graphic/character artifacts](https://github.com/a2fpga/a2fpga_core/issues/26),
[#25 hi-res with 80-col](https://github.com/a2fpga/a2fpga_core/issues/25),
[#24 lines/artifacts on some IIgs software](https://github.com/a2fpga/a2fpga_core/issues/24),
[#30 IIgs super-hi-res](https://github.com/a2fpga/a2fpga_core/issues/30).

### 2. IIgs bus-timing reliability (production)

Sporadic garbage data on some IIgs systems from the data-byte sampling window in
`apple_bus.sv` — a regression introduced when denoising the ph1 clock to pass mbaudit.
Top-priority item in [a2n20v2/TODO.md](../boards/a2n20v2/TODO.md) and
[a2n20v2-GS/TODO.md](../boards/a2n20v2-GS/TODO.md). Affects the stable board.

### 3. IIgs audio — Ensoniq DOC 5503

Active across several boards with different implementations:
[#33 DOC5503 mixer](https://github.com/a2fpga/a2fpga_core/issues/33); on **a2p25** the
ES5503 runs on the ESP32-S3 and is largely working (see
[a2p25/TODO.md](../boards/a2p25/TODO.md) and
[a2p25/docs/LCAM_SESSION_NOTES.md](../boards/a2p25/docs/LCAM_SESSION_NOTES.md)); **a2mega**
has its own DDR3-backed DOC path (see [gotchas.md](gotchas.md)).

### 4. Coprocessor, storage & configuration

Bringing SD-card disk mounting, on-screen display / config UI, and settings persistence to
the boards with a coprocessor:
- **a2mega** (ESP32-S3 over OSPI): OSD, Disk II, FAT32, web UI — [a2mega/TODO.md](../boards/a2mega/TODO.md).
- **a2n20v2-Enhanced** (BL616 over SPI): audio-clock fix, OSD, Disk II — [a2n20v2-Enhanced/TODO.md](../boards/a2n20v2-Enhanced/TODO.md).
- **a2p25** (ESP32-S3): FAT32, web config — [a2p25/TODO.md](../boards/a2p25/TODO.md).

### 5. a2mega (Tang Mega 60K) bring-up

The DDR3 board under active development: framebuffer stability, ESP32 OSPI interface, and
possible IIgs acceleration (TransWarp-GS-like). See [a2mega/TODO.md](../boards/a2mega/TODO.md),
its [DDR3 refactor workplan](../boards/a2mega/docs/A2FPGA_DDR3_Framebuffer_Refactor_Workplan.md),
and the DDR3 sections of [gotchas.md](gotchas.md).

### 6. Board maturity

- **a2n20v2-GS** is intended to eventually become the main a2n20v2 release.
- **a2n20v1** and **a2n9** are deprecated (maintenance-only, kept in sync with shared HDL).

### Explicitly not planned / rejected

- **On-FPGA PicoSoC (PicoRV32) soft core** — removed. Coprocessor functionality is now an
  external MCU: BL616 on a2n20v2-Enhanced, ESP32-S3 on a2mega and a2p25. See
  [ADR-0001](adr/0001-agents-md-as-router.md) context and the Enhanced
  [src/README.md](../boards/a2n20v2-Enhanced/src/README.md).
- **BrianHG DDR3 controller port** — evaluated and rejected (Altera-centric PHY; use the
  Gowin DDR3 IP instead).

> Maintainer: add longer-term/aspirational items here as they come up, and record anything you
> specifically do *not* want built (with a one-line why) so contributors don't re-propose it.
