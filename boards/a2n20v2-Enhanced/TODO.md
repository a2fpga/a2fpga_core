# A2N20v2-Enhanced TODO

> Status (2026-10-25): rewritten. The previous list (audio clock bug, PicoSoC interface,
> "complete Disk II") described early 2026; all of it shipped. Current standings are in
> `docs/boards.md`; the user-facing feature list is in [README.md](README.md).

## Shipped (for orientation)

- BL616 MCU coprocessor over 4-wire SPI (the PicoSoC soft core is gone): on-screen menu,
  settings persistence, slot map applied before the Apple's reset is released
- Disk II (.nib/.dsk/.do/.po/.2mg, on-the-fly GCR) and ProDOS HDD (.hdv/.po/.2mg) image serving
  from a USB stick or the SD card tunnel
- USB host: XInput gamepads, HID keyboards and media remotes, mass storage, USB-Ethernet
  (CDC-ECM) through a hub (EHCI queue-head pool sized for it)
- Uthernet II (W5100) MACRAW bridge, hardware-verified with IP65 / ADTPro / Contiki
- Telnet console and menu mirror, FTP, modem on the Super Serial Card
- Self-update of the MCU firmware and the FPGA core from the USB stick
- Audio clock fixed; the WS2812 status LED as an MCU liveness watchdog
- Three builds: classic (46/46 BSRAM), dual-rate SDRAM (SHR aux banks in SDRAM), framebuffer

## Open

- [ ] **Dual-rate / `_fb` CDC request path is not timing-verified** (word-granularity corruption
      hazard): [upstream #52](https://github.com/a2fpga/a2fpga_core/issues/52)
- [ ] Lift the HDD read-only containment in `firmware_host/disk.c` (`mount_hdd`, `rw = false`):
      the shifted/interleaved-word corruption it guarded against was the shared `hdl/disk/hdd.sv`
      write drain, fixed 2026-11-13 ([a2p25 write-up](../a2p25/docs/HDD_BLOCK_WRITE_SHIFT.md));
      needs a write test on this board first
- [ ] Startup gate when the card is powered before the Apple (supplemental power): the reset
      contract is jumped and the Apple does not boot. Reported in agent notes with a proposed
      fix (an `a2_alive` level gate that re-arms the hold); nothing for it is in the tree
- [x] Supersede the GS build: the shared `apple_bus` / `apple_memory_sdram`, the dual-rate SDRAM
      path and the `_fb` framebuffer variant are here; `a2n20v2-GS` is deprecated (2026-10-25)
- [ ] Uthernet II: hardware TCP/UDP socket modes (only MACRAW is implemented)
- [ ] Classic build has no BSRAM headroom (46/46): any new feature must reclaim blocks first;
      build with `RESOURCE_FAIL=bsram`
- [ ] IIgs bus-timing items shared with a2n20v2 ([a2n20v2/TODO.md](../a2n20v2/TODO.md))

## Known issues

- Build warning about `doc_osc_halt_w` in `top.sv` (cosmetic)
- Flashing the BL616 with `make flash` bricks the fused Tang Nano 20K boards; use the
  `/flash-mcu` skill (`a2n20-mcu-program`) only. See the BL616 README.

## Build status

- Last verified builds: 2026-10-23 (all three projects, 0 timing violations; resource snapshots
  in `impl/*_resources.json`)
