# Architecture Decision Records (ADRs)

An ADR captures a decision with lasting consequences — **the *why*, not the how** — so that
future contributors (and agents) don't re-litigate settled choices or unknowingly build
something contrary to a deliberate decision.

## When to write one

Write an ADR when a choice is **hard to reverse or easy to violate by accident**: a memory
architecture, a CDC strategy, a board's status change, a "we tried X and rejected it" outcome.
Don't write one for routine code — that's what the code and PR history are for.

## Format

- Filename: `NNNN-short-title.md` (zero-padded sequence, e.g. `0002-ddr3-no-double-buffering.md`).
- Copy [`template.md`](template.md) to start.
- Status is one of: `Proposed`, `Accepted`, `Superseded by NNNN`, `Deprecated`.
- Keep it short. The value is the rationale and consequences, not length.

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-agents-md-as-router.md) | AGENTS.md as the single router; docs/ as the wiki | Accepted |

> Add a row here for each new ADR.
