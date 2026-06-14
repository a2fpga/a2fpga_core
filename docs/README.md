# A2FPGA Documentation Wiki

This is the reference wiki for the A2FPGA Multicard Core — written to be useful to both
human contributors and coding agents. Each file is a single, dense topic. Start here, then
follow links into the topic you need.

> **Agents:** the routing rules and inviolable constraints live in [`../AGENTS.md`](../AGENTS.md).
> This index is the map of *reference* material.

## Onboarding path (read in this order)

1. [getting-started.md](getting-started.md) — first-run environment setup: which toolchains you need and how to install them (or run `/setup`).
2. [setup-gowin-cli.md](setup-gowin-cli.md) — get the Gowin toolchain running for headless/agentic builds (macOS-focused).
3. [architecture.md](architecture.md) — how the code is organized: shared `hdl/` vs per-board, the video/sound/bus pipelines, key file map.
4. [boards.md](boards.md) — the board matrix: which board uses which chip/memory, status, and quirks.
5. [conventions.md](conventions.md) — coding style, `.gprj` rules, how to add files.
6. [gotchas.md](gotchas.md) — hard-won lessons and traps that will silently cost you days.

## Reference topics

| Doc | What's in it |
|---|---|
| [getting-started.md](getting-started.md) | First-run environment setup — toolchain matrix, per-board needs, the `/setup` skill |
| [setup-gowin-cli.md](setup-gowin-cli.md) | Installing Gowin, the macOS CLI fix, `gw_sh` invocation, timing checks |
| [architecture.md](architecture.md) | Module organization, the subsystems, where things live |
| [video-pipeline.md](video-pipeline.md) | The two display paths, `pixel_stream_if`, how to add a video generator |
| [bus-interface.md](bus-interface.md) | Apple II bus snooping (`a2bus_if`), the slot/card system, building a virtual card |
| [coprocessor-interface.md](coprocessor-interface.md) | How an MCU (BL616/ESP32) observes & controls the core; building a connector |
| [memory-system.md](memory-system.md) | `mem_port_if`, multi-port arbitration, SDRAM/DDR3 backends, CDC, framebuffers |
| [audio.md](audio.md) | Sound sources, mixing, filtering, CDC, HDMI audio; per-board differences |
| [peripheral-cards.md](peripheral-cards.md) | The emulated cards (SuperSprite, Mockingboard, SSC, Disk II, CardROM) and reused cores |
| [boards.md](boards.md) | Per-board chip/memory/status matrix, `.gprj` names, flashing |
| [conventions.md](conventions.md) | SystemVerilog style, naming, `.gprj` path rules, file-add procedure |
| [gotchas.md](gotchas.md) | Known traps: Gowin synth quirks, CDC bugs, SDRAM/DDR3 lessons |
| [ROADMAP.md](ROADMAP.md) | Backlog and future direction; how it relates to GitHub issues |
| [adr/](adr/) | Architecture Decision Records — the *why* behind irreversible choices |

## Deep technical references (existing)

| Doc | Topic |
|---|---|
| [memory_bandwidth_analysis.md](memory_bandwidth_analysis.md) | DDR3 / SDRAM bandwidth headroom analysis |

## Maintaining these docs

- **One source of truth per fact.** If a command or detail appears in two files, one of
  them should link to the other instead of copying.
- **Evergreen here, temporal elsewhere.** Time-sensitive state (what's in progress, current
  branch, today's blocker) belongs in `boards/<board>/TODO.md`, [ROADMAP.md](ROADMAP.md), or
  GitHub issues — not in reference docs that are assumed current.
- **Promote lessons.** When you discover a non-obvious trap, add it to [gotchas.md](gotchas.md)
  so the next contributor (human or agent) doesn't rediscover it.
