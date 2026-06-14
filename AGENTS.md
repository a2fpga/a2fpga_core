# A2FPGA — Agent & Contributor Guide

> This file is the **router**. It is auto-loaded into every agent's context, so it
> stays short and stable. It does not contain reference material — it points to it.
> The reference material lives in [`docs/`](docs/README.md). When a fact below would
> go stale (commands, board details, lessons learned), it belongs in `docs/`, not here.

**New here?** Start with the wiki index: **[docs/README.md](docs/README.md)**.

**Setting up a new environment?** Run the **`/setup`** skill (or ask the agent to "set up the
build environment") — it detects what's installed and guides the rest. Reference:
**[docs/getting-started.md](docs/getting-started.md)**.

## Inviolable rules (do not violate without explicit user sign-off)

1. **FPGA builds use `gw_sh` via the pipe method only.** Never `gw_sh -exit -e` or
   from `~/bin/`. Before your first build, **read [docs/setup-gowin-cli.md](docs/setup-gowin-cli.md)**.
2. **Always check timing after every place & route.** A build is not "done" until you
   confirm 0 violated endpoints, Fmax ≥ constraint, and TNS = 0.000. See
   [docs/setup-gowin-cli.md](docs/setup-gowin-cli.md#checking-timing).
3. **New HDL is SystemVerilog (`.sv`)**, 4-space indent, `lower_snake_case` files/modules,
   `UPPER_SNAKE_CASE` params. Full rules: [docs/conventions.md](docs/conventions.md).
4. **`.gprj` paths must be relative**, never absolute. New files must be added to the
   `.gprj` of every board that uses them. See [docs/conventions.md](docs/conventions.md#gprj-files).
5. **Do not modify `hdl/sdram/sdram.sv`.** See [docs/gotchas.md](docs/gotchas.md).

## Routing table — where to look

| You need to… | Go to |
|---|---|
| Set up your environment / install toolchains (first run) | [docs/getting-started.md](docs/getting-started.md), or run `/setup` |
| Set up the Gowin CLI (esp. macOS) | [docs/setup-gowin-cli.md](docs/setup-gowin-cli.md) |
| Understand how the codebase is organized | [docs/architecture.md](docs/architecture.md) |
| Know which board is which (chip, status, quirks) | [docs/boards.md](docs/boards.md) |
| Avoid known traps / hard-won lessons | [docs/gotchas.md](docs/gotchas.md) |
| Follow coding & project conventions | [docs/conventions.md](docs/conventions.md) |
| Understand *why* a design choice was made | [docs/adr/](docs/adr/) (decision records) |
| Find what to work on next | [docs/ROADMAP.md](docs/ROADMAP.md) + `gh issue list` + `boards/<board>/TODO.md` |
| Build a board | `/build` skill, or [docs/setup-gowin-cli.md](docs/setup-gowin-cli.md) |
| Flash a board | `/flash` skill, or [docs/boards.md](docs/boards.md) |

## Starting a session

1. Identify which **board** the work targets (boards differ in chip, memory, and status —
   see [docs/boards.md](docs/boards.md)). If unclear, **ask the user**.
2. Check `boards/<board>/TODO.md` for that board's current priorities, blockers, and status.
3. For feature work, also scan [docs/ROADMAP.md](docs/ROADMAP.md) and `gh issue list`.

## Commit & PR conventions

- Concise imperative commits ("Fix HDMI clock mux"); reference issues (`#123`) when relevant.
- PRs: state motivation, affected boards, build/tool versions; attach logs or screenshots
  for visual/audio changes. Keep diffs scoped.
- Before committing `.gprj` changes, verify all paths are relative.
