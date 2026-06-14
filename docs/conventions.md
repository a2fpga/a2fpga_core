# Coding & Project Conventions

These are the rules new code must follow. The non-negotiable subset is mirrored in
[`../AGENTS.md`](../AGENTS.md); this file is the full version.

## HDL style

- **SystemVerilog required for new modules.** Use `.sv` (not `.v`).
- 4-space indentation, **no tabs**.
- Use `logic` for SV nets; prefer **explicit widths**.
- Files & modules: `lower_snake_case` (e.g. `picosoc_sdram.sv`, `a2bus_if.sv`).
- Parameters & constants: `UPPER_SNAKE_CASE`.
- Keep portable logic in `hdl/`; per-board `top.sv` lives under `boards/<board>/hdl/`.

## `.gprj` files {#gprj-files}

- **New HDL files must be added to the `.gprj` of every board that uses them.**
- Paths in `.gprj` are **relative to the `.gprj` location** (e.g. `hdl/top.sv` or
  `../../hdl/sound/audio_out.v`).
- **Never use absolute paths.** The Gowin GUI inserts absolute paths when adding files —
  convert them to relative before committing.
- Shared modules: referenced from a board as `../../hdl/<path>`.
- Board-specific modules: referenced as `hdl/<filename>`.
- The `.gprj` filename is not always `<board>.gprj` — see [boards.md](boards.md).

## Adding a new module (checklist)

1. Decide placement: portable → `hdl/`, board-specific → `boards/<board>/hdl/`.
2. Add the file to each consuming board's `.gprj` with a **relative** path.
3. Build the affected board(s) and verify synthesis + **timing** clean
   ([setup-gowin-cli.md](setup-gowin-cli.md#checking-timing)).
4. If it touches the video/CDC/memory paths, re-read [gotchas.md](gotchas.md) first — that's
   where the silent failures live.

## Testing

- No global CI. Targeted artifacts live under `tests/` (e.g. `tests/sound/`).
- Provide small benches/VCDs when adding new HDL blocks.
- Verify synthesis/PnR for all impacted boards; sanity-check on hardware when possible.
- Include reproduction steps in PRs.

## Commits & PRs

- Concise imperative commit subjects ("Fix HDMI clock mux"). Reference issues (`#123`).
- PRs: motivation, affected boards, build steps, tool versions; attach logs/screenshots for
  visual or audio changes. Keep diffs scoped.
- Verify `.gprj` paths are relative before committing.

## Configuration

- Board feature toggles (card enables, slot assignments) live as `top.sv` parameters.
  Document any default changes in the PR.
- `prebuild.tcl` may generate `hdl/datetime.svh`; never commit machine-local paths.

## Per-board documentation {#per-board-docs}

Each board is documented by a small, consistent set of files so contributors (and agents) can
find their way from the top-level wiki down to board-specific detail:

- **`boards/<board>/README.md`** — the board's entry point. Ends with a **Documentation** section
  linking up to the wiki ([docs/](README.md)), to [AGENTS.md](../AGENTS.md), to the board's
  `TODO.md`, and to any board docs. Also linked from [boards.md](boards.md).
- **`boards/<board>/TODO.md`** — current, temporal status and priorities for that board.
- **`boards/<board>/docs/`** — board-specific **design docs, workplans, and session notes**.
  This is the home for anything that isn't a board overview or a task list: framebuffer designs,
  protocol specs, refactor plans, capture notes, etc.
- **Sub-project firmware** (e.g. `src/a2n20_bl616/`) keeps its own `README.md` + `docs/`.

Rules that keep this discoverable:

- **Every `.md` must be reachable** by links from [docs/README.md](README.md) → [boards.md](boards.md)
  → the board `README.md` → board `docs/`. An unlinked doc will not get read. When you add a doc,
  add the link in the board `README.md` (and `boards.md` if board-wide).
- **Don't strand docs at a board root.** New design notes/workplans go in `boards/<board>/docs/`,
  not loose in the board directory.
- **If a doc is cited from code** (e.g. `// See boards/<board>/docs/foo.md`), keep the citation
  path correct when you move the doc.

## Design intent — "how I want things built"

This captures preferences so new contributors don't build things in ways that have to be
redone. The items below are **derived from existing decisions in the code, ADRs, and
[gotchas.md](gotchas.md)** — the maintainer should confirm and extend them. For a decision with
lasting consequences, write an [ADR](adr/) and link it here.

**Established patterns (observed in the codebase — confirm/refine):**

- **Coprocessor = external MCU, not an on-FPGA soft core.** PicoSoC/PicoRV32 was removed; new
  coprocessor functionality (SD card, OSD, config, audio emulation) lives in MCU firmware —
  BL616 on a2n20v2-Enhanced, ESP32-S3 on a2mega/a2p25 — talking to the FPGA over SPI/OSPI/LCAM.
  Don't reintroduce an on-FPGA CPU core.
- **All video generators target `pixel_stream_if`; the framebuffer is hidden from the renderer.**
  Generators are written once and run on every board; the board picks a *consumer* —
  `framebuffer_writer` (Apple-timed framebuffer, keeps beam-racing intact) or `direct_display`
  (HDMI-locked, no framebuffer). The legacy HDMI-raster generators (`apple_video`/`vgc`) are to be
  migrated to this model; don't write new raster-driven generators. See
  [video-pipeline.md](video-pipeline.md).
- **CDC: prefer a toggle-based handshake over the gray-code async FIFO.** The async FIFO
  corrupted data on the GW5AT; toggle-handshake is the proven pattern. For CDC modules, use
  explicit wire ports (not SystemVerilog interfaces) as defense against GW5AT constant
  propagation. See [gotchas.md](gotchas.md).
- **Use SystemVerilog interfaces (`*_if.sv`) for control/data planes** between modules
  (e.g. `a2bus_if`, `mem_port_if`, `*_control_if`) — except the CDC exception above.
- **Keep the shared/board-specific boundary clean:** portable logic in `hdl/`, anything that
  knows about a specific FPGA/pins/memory in `boards/<board>/hdl/`. Don't leak board specifics
  into `hdl/`.
- **Don't touch the load-bearing memory controllers** (`hdl/sdram/sdram.sv`); respect the
  tuned parameters called out in [gotchas.md](gotchas.md).

**Maintainer — add your own intent here**, e.g. anything you've had to correct in a PR more
than once, naming/structure preferences, or features you want built a particular way.
