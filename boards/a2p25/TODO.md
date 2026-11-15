# A2P25 TODO

> Status (2026-10-25): body replaced with the displayport1 open items; the previous revision's
> ES5503-on-ESP32 plan that was here (2026-01-28, abandoned) is in git history and summarized
> in [docs/archive/README.md](docs/archive/README.md).

## Status

**displayport1 board rev in bring-up; the IIgs boots on the new core over DP 1080p with SHR
and DOC audio (2026-10-11)** — see
[docs/MODERNIZATION_PLAN.md](docs/MODERNIZATION_PLAN.md) for the current plan,
priorities (DP colorbars → AUX validation → PSRAM test → DOC/framebuffer/
shadow on PSRAM) and the bench ladder. The board has no LCAM link, I2S or UART; the
IIgs sound is the fabric DOC5503 on PSRAM.

## Open (from MODERNIZATION_PLAN.md sections 6–7, ESP32_FEATURE_PORT.md and RESOURCE_AUDIT.md)

- [ ] ESP32 feature port P5 onward ([docs/ESP32_FEATURE_PORT.md](docs/ESP32_FEATURE_PORT.md)):
      USB host on USB1 with the runtime OTG role policy (pads, keyboards, remotes, mass
      storage), image storage strategy without an SD card
- [ ] Keep the DOC's per-frame LATE count at zero as the core grows (telnet `z`); the fetch
      cache and port priority 0 are the current fix ([docs/RESOURCE_AUDIT.md](docs/RESOURCE_AUDIT.md))
- [x] HDD image corruption seen around installs: the HDD card stored every written word one
      word late (`hdd.sv` drain, fixed 2026-11-13, bench `sim/disk/run.sh`); hardware
      confirmation pending — [docs/HDD_BLOCK_WRITE_SHIFT.md](docs/HDD_BLOCK_WRITE_SHIFT.md)
- [ ] Known risks, plan section 7: D-PHY amplitude margin at the SN75DP130 input (EQ override
      is the knob), the D-PHY PLL cascade soak, `TX_CLK_O` gating check via telemetry,
      HyperRAM CK# floating on non-Infineon parts (never write CR1), IODELAY semantics vs UG289
- [ ] Resource ceiling: 97% CLS, 52/56 BSRAM; SuperSprite, Mockingboard and Uthernet II are off.
      Any addition needs a reclaim first; `tools/resource_report.py a2p25`
- [ ] Fold the TOP_INTEGRATION_PLAN section 6 decisions into MODERNIZATION_PLAN and archive it
- [ ] USB-C-to-HDMI adapters: only RBR-capable, lane-count-honest adapters work (plan section
      6h recipe); document the qualified list for users

## Shipped on displayport1 (2026-10-01 → 10-12)

- DP colorbars through the D-PHY chain (first anyone has driven DP from a MIPI D-PHY as a raw
  serializer), 4-lane 1080p; AUX path validated with the corrected network (carried to a2mega 1.0a4)
- HyperRAM at 108 MHz, zero errors; framebuffer, shadow memory and the pipelined DOC on it
- The full core: IIgs boots, SHR (scanout trigger fix) and DOC audio (4-lane SDP) root-caused
  and fixed on 2026-10-11
- ESP32 feature port P1–P4 verified (reset hold, menu input, disk serving, console)

## Build status

- Last verified build: 2026-10-25 (`a2p25.gprj`, 0 violations, clk100 +1.200; snapshot in
  `impl/a2p25_resources.json`); provenance table in MODERNIZATION_PLAN.md section 8
