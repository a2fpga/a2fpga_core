---
name: flash-mcu
description: Flash the BL616 MCU firmware on the a2n20v2-Enhanced board (Tang Nano 20K) using the a2n20-mcu-program tool. Use when the user asks to flash, program, upload, or update the BL616 / MCU / microcontroller firmware (the FT2232 device build or the USB-host XInput build) — NOT the FPGA bitstream (use the `flash` skill for that).
---

# Flash the BL616 MCU firmware (a2n20v2-Enhanced)

Programs the **BL616 microcontroller** on the Tang Nano 20K with one of the
a2n20v2-Enhanced firmware builds, via
`boards/a2n20v2-Enhanced/src/a2n20_bl616/tools/a2n20-mcu-program` (a wrapper
around `bflb-iot-tool` that auto-detects board state and picks the flash
strategy/address).

This is **not** the FPGA bitstream — for that use the `flash` skill.

**Flashing writes to hardware.** Confirm which firmware build and that the board
is connected before flashing, unless the user already said to go ahead.

## Which firmware

From `boards/a2n20v2-Enhanced/src/a2n20_bl616/`:

| Build | Binary | What it is |
|---|---|---|
| Device (default) | `firmware/build/build_out/a2n20_bl616_bl616.bin` | FT2232 JTAG+UART bridge + CLI |
| USB host | `firmware_host/build/build_out/a2n20_bl616_host_bl616.bin` | Standalone USB-host XInput joystick mode |

Build first if the `.bin` is missing (T-Head toolchain, clean build, explicit
`BL_SDK_BASE` — see the [BL616 README](../../../boards/a2n20v2-Enhanced/src/a2n20_bl616/README.md)).

## Steps

1. **Ask the user to put the board in ROM boot mode** (physical, only they can
   do it): disconnect USB → hold the **UPDATE** button (behind HDMI) → connect
   USB-C to the **Debug** port → release. It then enumerates as a Bouffalo CDC
   device, e.g. `/dev/cu.usbmodemXXXX`. Wait for them to confirm.

2. **Confirm boot mode and find the port** (do not flash yet):
   ```bash
   ls /dev/cu.usbmodem*          # the boot-mode CDC port
   ./tools/a2n20-mcu-program --detect
   ```
   `--detect` labels a fused board "USB Debugger" in normal mode; in boot mode
   it shows the Bouffalo CDC (it mislabels boot mode as "CDC DEMO bricked" —
   that's expected, same VID/PID).

3. **Flash non-interactively** (run from `boards/a2n20v2-Enhanced/src/a2n20_bl616/`):
   ```bash
   ./tools/a2n20-mcu-program --stage2 \
       --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin \
       --port /dev/cu.usbmodemXXXX --non-interactive --verify-flash
   ```
   - `--non-interactive` never prompts, assumes boot mode, implies
     `--skip-verify`. The command exits **non-zero** on failure — check the exit
     code and look for the `[OK] ... flashed successfully` line. Do NOT trust a
     "Programming complete!" line alone on older copies.
   - `--verify-flash` reads the written region back and byte-compares it to the
     image (no power-cycle needed). Recommended — it's the only PC-side proof a
     host-mode firmware flashed correctly, since it's invisible as a USB device
     once running. A real mismatch exits non-zero.
   - `--stage2` flashes at `0x40000` (correct for fused boards; keeps Sipeed
     Stage 1). Omit `--stage2` to let auto-detect choose, but auto-detect's
     interactive Step 1 expects the board in *normal* mode first, so for the
     agent flow prefer explicit `--stage2` with the board already in boot mode.
   - Baud auto-falls-back on write failure (default 500000 → 115200). 2000000 is
     unreliable; don't force it.

4. **Tell the user how to run it.** To run the flashed firmware: disconnect the
   PC, power-cycle the board **with no PC attached** (the 2nd-stage app only
   runs when no host is enumerating the BL616), then for the host build plug the
   USB joystick into the Debug port.

## Identify which firmware is running

To check what's *running* (not just flashed), use `--probe-cli`:

```bash
./tools/a2n20-mcu-program --probe-cli
```

It opens the device's serial port(s), sends the `Ctrl-X Ctrl-C Enter` break-in +
`help`, and reports who answers:
- **A2N20 (ours):** `a2n20>` prompt, "A2N20 BL616 Firmware" banner → exit 0.
- **Stock (Gowin/Sipeed):** `TangNano20K />` prompt, `pll`/`chip_id`/`reboot`… →
  exit 1.
- **No serial ports:** board is in boot mode or running the **host-mode**
  firmware (a USB host exposes no serial device) → exit 2.

## Notes

- A running **host-mode** firmware is invisible from the PC (it's a USB host,
  not a device), so `--probe-cli` finds no serial — the only confirmation it's
  *running* is on-device behavior (e.g. the HDMI/Apple II screen).
- If the tool can't find the boot port, the board isn't in boot mode — have the
  user redo the UPDATE-button entry; don't retry blindly.
