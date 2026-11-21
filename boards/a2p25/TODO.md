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
      word late (`hdd.sv` drain, fixed 2026-11-13, bench `sim/disk/run.sh`); hardware-confirmed 2026-11-13 (flashed; the IIgs
      power-cycles clean after writes) — [docs/HDD_BLOCK_WRITE_SHIFT.md](docs/HDD_BLOCK_WRITE_SHIFT.md)
- [ ] Known risks, plan section 7: D-PHY amplitude margin at the SN75DP130 input (EQ override
      is the knob), the D-PHY PLL cascade soak, `TX_CLK_O` gating check via telemetry,
      HyperRAM CK# floating on non-Infineon parts (never write CR1), IODELAY semantics vs UG289
- [ ] Resource ceiling: 96% CLS, 50/56 BSRAM with Mockingboard and Uthernet II in (2026-11-15);
      SuperSprite is off. Any addition needs a reclaim first (RESOURCE_AUDIT §8.5);
      `tools/resource_report.py a2p25`
- [ ] Hardware checks for the 2026-11-15 pass: RESOURCE_AUDIT §8.4 (4 line banks, GLU queue,
      OSD colours, slot defaults, DHCP, Mockingboard)
- [ ] Fold the TOP_INTEGRATION_PLAN section 6 decisions into MODERNIZATION_PLAN and archive it
- [ ] USB-C-to-HDMI adapters: only RBR-capable, lane-count-honest adapters work (plan section
      6h recipe); document the qualified list for users
- [ ] USB sticks: USB 3.x sticks (PNY Elite-X Fit, Verbatim Nano 3.2) fail enumeration BEHIND
      THE HUB on the ESP32-S3 host (the PNY works straight on USB1); USB 2.0 sticks work
      (2026-11-19, ESP32_FEATURE_PORT.md P3). Firmware 2026-11-20: bounded hub-port power-cycle
      retry (`usbhub_retry.c`, 3 cycles per plug) + SETTINGS `USB HUB PORT RETRY` (ALL PORTS
      default since 11-20 / PER-PORT; telnet `usb retry on|off`). Tested 11-20 on the 05E3:0610
      hub (ganged port power): PER-PORT refuses by design; ALL PORTS RECOVERED THE PNY AFTER 2
      CYCLES (dongle re-enumerated by itself, P3 has both logs); Verbatim recovers too and the
      remote works after a ladder (Ed, 11-20 evening). Open: RTL8152B uplink through a ladder
      (re-enumerates, re-DHCP), unplug mid-ladder, replug after a give-up;
      ⚠ PNY WRITES: FTP `STOR` onto the PNY breaks after ~6 s with a 0-byte file (3/3, card
      stays up; the K&ZZ AND the ladder-recovered Verbatim take the same 1.3 MB upload with
      byte-exact readback, 11-20) — PNY-specific MSC write failure while reads are fine;
      DOS33.NIB is mounted RW on it, so Disk II write-back to the PNY is suspect; next = log
      the SCSI WRITE(10)/fwrite error status (ESP32_FW_A2P25.md, P3);
      recommend USB 2.0 to users and keep a tested list

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
