// a2p25_profile.vh — build profile for boards/a2p25 (included by top.sv).
//
// ONE place for the switches that decide what this board's core carries:
// features (slot cards, audio, video options) and instrumentation (overlays,
// event logs, telemetry). The top's parameter defaults and instrument
// instances read these macros; nothing else should set them. Values below are
// the "dev" profile — exactly what this board built before this file existed.
//
// Release profile (planned): define A2_PROFILE_RELEASE (a *_defines.v listed
// first in a release .gprj, or a build.sh PROFILE=release switch once it can
// inject one) and fill the `ifdef A2_PROFILE_RELEASE block below with what
// release drops. Until then that block is empty on purpose. See
// docs/build_profiles.md for the conventions and the per-module cost table.
`ifndef A2P25_PROFILE_VH
`define A2P25_PROFILE_VH

// ---- features (GW5A-25: logic-bound at ~97% CLS, 52/56 BSRAM — see
// boards/a2p25/docs/RESOURCE_AUDIT.md before turning anything on) ----
`define A2_FEATURE_SUPERSPRITE    0   // deferred on the GW5A-25 (resource budget); slot ID stays reserved
`define A2_FEATURE_MOCKINGBOARD   0   // off for the first fit: with it 97% CLS and placement failed
`define A2_FEATURE_SUPERSERIAL    0   // no UART pins on this revision
`define A2_FEATURE_DISK_II        1
`define A2_FEATURE_UTHERNET2      1   // W5100 buffers = 9 BSRAM; back in after the 2026-11-15 BSRAM pass (RESOURCE_AUDIT §8)
`define A2_FEATURE_HDD            1
`define A2_FEATURE_ENSONIQ        1

// ---- instrumentation ----
`define A2_INSTR_DEBUG_OVERLAY    0   // off since the first clean full-core fit (10-11)
`define A2_INSTR_EVENT_LOG        0   // no CPU socket; GW5A-25 failed to place with it
`define A2_INSTR_MEM_PEEK         0   // ESP32 HyperRAM read window (regs 0x34-0x3B) on its own arbiter port; ~150 FF + a 7th port (RESOURCE_AUDIT B6b). Firmware does not use it.
`define A2_INSTR_TEST_MEM         0   // ESP32 SPACE 0 64-byte test memory, ~512 FF (RESOURCE_AUDIT 7.3). Firmware does not use it.

`ifdef A2_PROFILE_RELEASE
// Release overrides go here (undef + redefine). Empty: release == dev today.
`endif
`endif
