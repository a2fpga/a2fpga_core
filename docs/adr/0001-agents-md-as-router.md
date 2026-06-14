# 0001. AGENTS.md as the single router; docs/ as the wiki

- **Status:** Accepted
- **Date:** 2026-06-12

## Context

Project guidance had drifted across multiple overlapping files: `CLAUDE.md` (a2mega-only,
with a stale "current branch"), `AGENTS.md` (all-boards, more complete), `tools/README.md`
(good Gowin setup that agents never opened because nothing pointed them to it), and a
`SESSION_LOG.md` that had gone 8 months stale. Hard-won lessons lived only in a private,
machine-local agent memory — invisible to other contributors and to agents on other machines.
The same fact (e.g. the `gw_sh` invocation) appeared in three places and could disagree.

The goal: make new contributors — human or agent — productive quickly, without each one
re-discovering setup steps and known traps.

## Decision

- **`AGENTS.md` is the single, canonical "router"**: short, stable, mostly pointers, plus the
  handful of inviolable rules. It is the one file auto-loaded into agent context.
- **`CLAUDE.md` becomes a one-line stub** pointing to `AGENTS.md`. (Both names exist because
  different tools auto-load different ones; only one carries content.)
- **Reference material lives in a flat `docs/` wiki** indexed by `docs/README.md`, one dense
  topic per file, loaded on demand.
- **One source of truth per fact.** Files link rather than copy.
- **Evergreen vs. temporal split:** reference docs are assumed current; time-sensitive state
  goes in `boards/<board>/TODO.md`, `docs/ROADMAP.md`, or GitHub issues.
- **Hard-won lessons are promoted into `docs/gotchas.md`** from private memory.

## Consequences

- Agents follow explicit imperative pointers from the router (e.g. "before your first build,
  read setup-gowin-cli.md"), fixing the discoverability gap that made `tools/README.md` unread.
- Editing one fact means editing one file; the others link to it.
- Contributors must **maintain the split**: don't inline reference content into the router,
  and don't put temporal state into evergreen docs.
- `SESSION_LOG.md` was superseded by per-board `TODO.md` + ROADMAP + issues, and has been removed.

## Alternatives considered

- **Keep both AGENTS.md and CLAUDE.md as full files, kept in sync** — rejected: reintroduces
  the exact drift problem.
- **One big wiki file** — rejected: too large to load selectively; agents need small, targeted docs.
- **Rely on private agent memory** — rejected: not shared across contributors or machines.
