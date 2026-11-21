# ESP32 firmware on the a2-p25 "displayport1" board

The a2-p25 displayport1 revision runs the **a2mega ESP32-S3 firmware**
(`boards/a2mega/src/a2fpga_esp32/`) built as board revision **225**. The
previous revision's LCAM-era firmware was deleted from `boards/a2p25/src/`
on 2026-10-25 (git history has it).

What the a2mega firmware brings over unchanged: the USB-C PD stack
(FUSB302B), DP alt-mode entry and mux control, HPD-to-FPGA reconstruction
from PD VDMs (level plus 0.75 ms IRQ pulses), WiFi, the telnet console
(key-driven; see [ESP32_CONSOLE.md](../../a2mega/docs/ESP32_CONSOLE.md) before using it),
FTP, network bitstream streaming, the JTAG updater and the USB JTAG bridge.

## Build and flash

```sh
cd boards/a2mega/src/a2fpga_esp32
make BOARD_REV=225 compile              # dp_test variant (default DP_TEST=1)
make BOARD_REV=225 DP_TEST=0 compile    # variant for an OSPI-speaking core
make BOARD_REV=225 PORT=/dev/cu.usbmodemXXXX upload
```

- **Module:** ESP32-S3-MINI-1-N4R2, the same as the a2mega 1.0a3. The
  Makefile uses the same FQBN: `FlashSize=4M, PSRAM=enabled,
  PartitionScheme=min_spiffs, USBMode=hwcdc, CDCOnBoot=cdc` (was `default`
  until 2026-11-19, `no_ota` before 2026-10-12 — see the partition note
  under "Updating the firmware" below).
- **Upload port:** use **USB1**, the ESP32's own USB-C port (native USB on
  IO19/IO20). It is a separate connector from the video port (USB2), so the
  CDC console (`+++` then `help`) stays available while a monitor is
  attached.
- **Download mode:** hold S2 (BOOT, IO0) and tap S1 (EN). See the /RES
  warning below: the Apple II is held in reset while the ESP32 is in
  download mode.
- **Shared build directory:** every revision builds into `./build`.
  arduino-cli rebuilds fully when the defines change. Run `make clean` if
  in doubt.
- **Build result (2026-10-01):** arduino-cli 1.2.2 with esp32 core 3.3.5.
  All three variants compile clean (`--warnings all`, no new warnings):
  - 225 dp_test: 999,339 B (47 %) of the 2 MB app partition.
  - 225 OSPI: 1,025,123 B.
  - 103: 1,032,955 B.

  `make BOARD_REV=225 compile` produced
  `build/a2fpga_esp32.ino.bin` with sha256 `d43c6b44…29504`. Nothing has
  been flashed yet.
- **Build result (2026-11-17, disk-path hardening):** `make BOARD_REV=225
  DP_TEST=0 compile` from a clean `build/` → `build/a2fpga_esp32.ino.bin`,
  1,129,888 B (sketch 86 % of the 1.25 MB slot), sha256
  `38f0e5b46e645fcdc3452131616a8820a43d2f24353069d603eb335b7f1d83cb`,
  no warnings in the changed files, **not flashed**. What changed and why:
  [STICK_CORRUPTION_2026-11-17.md](STICK_CORRUPTION_2026-11-17.md) (checked
  request reads, read twice against an Apple /RES mid-request, image sizes checked at mount, image-bounded seeks, write
  failures counted and demoting the volume to read-only, images closed and
  stick unmounted before every restart and reload).
- **Build result (2026-11-19, BLE HID + USB-Ethernet + min_spiffs):** `make
  BOARD_REV=225 DP_TEST=0 compile` from a clean `build/` at c623db18 (clean
  tree), arduino-cli 1.2.2 / esp32 core 3.3.5 → `build/a2fpga_esp32.ino.bin`,
  1,335,936 B (sketch 67 % of the 1,966,080-byte min_spiffs slot), 0 warnings,
  sha256 `62153cbf6181fd641f895706f872b89adb63c58d1972060f2de7c9249103b0a4`.
  **Flashed** the same evening over USB1 (`make … PORT=/dev/cu.usbmodem4101
  upload`, esptool auto-reset worked from the running Oct-15 firmware, hash
  verified) onto the card at 192.168.232.66: that was its one-time
  `default` → `min_spiffs` partition switch (LittleFS now 8 KB of 128 KB; WiFi
  credentials survived). Then `GPRJ=a2p25.gprj tools/flash.sh a2p25` through
  the new firmware's JTAG bridge wrote and read-back-verified the build of
  record `712bc5c2…` (commit c623db18, stamp 20261119182343) in 44 s; after CLI
  `reconfig` the core reports DONE, link UP, HyperRAM calibrated, and register
  0x7E reads the stamp back. Before this the card ran firmware Oct 15 2026
  09:21 and a core with no version register.
- **Build + flash (2026-11-20, hub-port enumeration retry):** `make
  BOARD_REV=225 DP_TEST=0 compile` at 3ffd5108 (clean tree), arduino-cli
  1.2.2 / esp32 core 3.3.5 → `build/a2fpga_esp32.ino.bin`, 1,338,352 B
  (sketch 1,338,207 B = 68 % of the min_spiffs slot), no new warnings under
  `--warnings all`, sha256
  `ced8953a33f7de427a7525adeb21883f50900981bff2ba4dc0db2123ddd60639`.
  **Flashed over the air** onto the card at 192.168.232.66 with the K&ZZ
  USB 2.0 stick on the hub as the volume: `curl -T` to FTP, renamed on the
  stick to `a2fpga_esp32_225_hubretry_3ffd5108.bin`, then the telnet menu
  mirror (FIRMWARE → UPDATE MCU → file → INSTALL MCU FIRMWARE NOW; the
  picker shows `1306K -> APP1`). Rebooted into `MCU NOV 20 2026 08:32:37`,
  slot APP1; stick remounted, DOS33.NIB served, USB DEVICES lists hub
  05E3:0610 + dongle 1915:1025 + stick 090C:1000 all in use. PNY test the
  same morning: the chain fired and the ganged-power guard refused (P3).
- **Build + flash (2026-11-20, `USB HUB PORT RETRY` setting):** `make
  BOARD_REV=225 DP_TEST=0 compile` at 18bfd578 (clean tree; the BOARD_REV=103
  build also clean, no new warnings under `--warnings all`) →
  `build/a2fpga_esp32.ino.bin`, 1,339,248 B, sha256
  `8763a288feef2f87eca88703095a9fd92f1164533503c1db9bd3736ec8318c64`.
  **Flashed over the air** the same way (K&ZZ stick as the volume, file
  `a2fpga_esp32_225_hubretry2_8763a288.bin`, telnet menu mirror FIRMWARE →
  UPDATE MCU → INSTALL; picker `1307K -> APP0`). Rebooted into `MCU NOV 20
  2026 08:57:10`, slot APP0; hub + dongle + K&ZZ enumerated; telnet `usb
  retry on` answered `hub port retry setting saved`, `usb` shows `hub port
  retry: ALL PORTS`. Then K&ZZ swapped for the PNY behind the hub: `HUB 1
  PORT 3 RECOVERED AFTER 2 PORT POWER CYCLES`, STORAGE 59153 MB, DOS33.NIB
  served (ESP32_FEATURE_PORT.md P3 has the log).
- **Build (2026-11-20, default flipped to ALL PORTS, `usb_hub_retry_perport`):**
  `make BOARD_REV=225 DP_TEST=0 compile` from the source of bee90d1a (clean
  tree) → 1,339,264 B, sha256
  `348a140bb991f8b8a5f3ae6c644a86318364012ea30de7227132f07b3b0b3016`;
  `make BOARD_REV=103 compile` clean (sketch 1,345,875 B); `--warnings all`
  pass shows only the pre-existing hits. **Flash pending:** the OTA upload
  could not go through the PNY 13FE:6700 as the volume — `curl -T` to FTP
  broke the data connection after ~6 s three times (full rate twice,
  150 kB/s once), leaving a 0-byte file, with the card up the whole time
  (telnet stayed connected, no reboot, no stick drop; the FTP server logged
  only `CLIENT CONNECTED`). The K&ZZ 090C:1000 took the same 1.3 MB upload
  twice earlier the same morning, so this is a PNY write-path problem on
  the full-speed host (reads serve Disk II fine); the flash goes through the
  K&ZZ. **Flashed** once Ed put the K&ZZ back: `curl -T` onto it as
  `a2fpga_esp32_225_hubretry3_348a140b.bin` went through first time, telnet
  menu mirror FIRMWARE → UPDATE MCU → file → INSTALL (`1307K -> APP1`),
  rebooted into `MCU NOV 20 2026 18:02:30`, slot APP1, hub + dongle + K&ZZ
  enumerated, DOS33.NIB served. As expected the byte saved under 18bfd578
  read back as `PER-PORT ONLY`; `usb retry on` saved it, and SETTINGS shows
  `USB HUB PORT RETRY  ALL PORTS` with `NVS … LD:OK SV:OK`. This is the
  firmware on the card now. PNY swapped in behind the hub afterwards: the
  ladder recovered it at the second cycle again (P3).
- **Build + flash (2026-11-20 evening, storage write diagnostics):** `make
  BOARD_REV=225 DP_TEST=0 compile` → 1,341,392 B, sha256
  `4736ba59bbda926b0613947d0e0f21c64e1e3934b32f41cef218b95ed6b3be86`; 103
  build clean; `--warnings all` only pre-existing hits. Adds: every failed
  READ(10)/WRITE(10) logged with LBA, SCSI stage (CBW / data phase / CSW
  missing / CSW malformed / CHECK CONDITION), CSW status and REQUEST SENSE
  key/ASC/ASCQ (first 5, then every 50th; `usb` prints the totals and the
  last one); telnet `usb probe <lba> [read]` (one-sector read, and for an
  all-zero sector a same-zeros WRITE(10) + read-back, each step timed).
  Purpose: the PNY 13FE:6700 (64 GB) refuses FTP writes while the two 32 GB
  sticks take them — find the failing stage and bisect the address. Flashed
  OTA through the Verbatim 18A5:0250 (`a2fpga_esp32_225_probe_4736ba59.bin`,
  picker `1309K -> APP0`); the Verbatim re-recovered at ladder cycle 2 on
  the reboot. Baseline on the Verbatim: `usb probe 2048` and `usb probe
  61439000` (29999 MB in) both PASS, read 3–6 ms, write 5–8 ms.
  **PNY result + CARD CRASH (same evening):** PNY swapped in (ladder, cycle
  2 again). `usb probe 2048 read`: ok, 6 ms, zeros. `usb probe 2048`
  (write): `WRITE FAILED after 1943 ms: WRITE lba 2048 x1: CSW MALFORMED
  csw=00 data=512` — the 512 data bytes went out, the stick then held the
  CSW past the 1.5 s wait, the retry read came back malformed. The next
  command (`usb probe 60000000 read`) never answered: the card REBOOTED
  (PNY back at addr 3, failure counters zero, console ring restarted,
  Apple II reset with it). **Root cause (firmware, not the stick):** this
  IDF's `usb_transfer_t.timeout_ms` is "currently not supported yet"
  (usb_types_stack.h), so `bulk_xfer` waiting 1.5 s and then
  `usb_host_transfer_free()` left the CSW transfer in flight; when the PNY
  finally answered, the host stack completed into freed memory. The two
  32 GB sticks never held a CSW that long, so the hazard never fired before.
  So the PNY's symptom is a WRITE(10) whose status takes > 1.5 s (how long,
  and whether it then succeeds, is what the next build measures), and the
  crash is ours.
- **Build (2026-11-20 evening, transfer cancel + reset reason), UNFLASHED:**
  `bulk_xfer` on its own timeout now halts + flushes the endpoint (the stack
  completes the transfer as CANCELED, the callback fires), waits for that,
  clears the endpoint and frees; if the callback still does not come the
  transfer is leaked, never freed in flight (`usb` prints timeout/leak
  counts). WRITE(10) gets an 8 s CSW wait (reads keep 1 s); the failure log
  says `AFTER A TIMEOUT` when that is what happened. Boot logs `RESET
  REASON: PANIC (FIRMWARE CRASH) / TASK WATCHDOG / …` for anything but
  power-on, so the next crash names itself. **Built at 98ff773e** → 1,342,256 B,
  sha256 `70055b45a633b4042356b2bb43dfa0789454866d76014f8610a6121de6ae9c70`;
  103 clean; warnings pass only pre-existing hits. **Flashed** OTA through the
  Verbatim (`a2fpga_esp32_225_cancel_70055b45.bin`, picker `1310K -> APP1`),
  boots as `MCU NOV 20 2026 18:57:11`; Verbatim re-recovered at ladder cycle
  2; `usb probe 2048` / `usb probe 61439000` PASS (write 6 / 8 ms). This is
  the firmware on the card. **PNY re-probe on it:** `usb probe 2048` write
  ok in **1940 ms** (first write after power-up), then 2048 / 2049 / 4096 /
  67108864 (32 GB) / 121000000 (59 GB) all PASS at 17–47 ms; 8 KB FTP write
  0.5 s; 1.3 MB FTP write 69 s, read back 9 s, byte-exact; test files
  deleted; card up throughout, no timeouts counted. The PNY write problem
  was the firmware's 1.5 s wait plus the in-flight free. Closed.

## Pin map (ESP32-S3-MINI-1 U5)

**Source:** a `kicad-cli sch export netlist` of
`the a2-p25 board repo` @ `displayport1` (working tree, 2026-10-01).
The ESP32 is on the "ESP32 & IO" sheet. FPGA balls come from
[PINOUT_DISPLAYPORT1.md](PINOUT_DISPLAYPORT1.md).

| GPIO | Module pad | Net | Far end | Firmware macro / use |
|---|---|---|---|---|
| IO0 | 4 | Net-(U5-IO0) | S2 (BOOT) to GND | `PIN_BOOT_BTN`. Strapping pin: read only |
| IO1 | 5 | LED0 | D6, active high (549 Ω) | `PIN_LED0`: 1 Hz heartbeat |
| IO2 | 6 | LED1 | D7, active high (549 Ω) | `PIN_LED1`: mirrors the HPD level sent to the FPGA |
| IO3 | 7 | DP_I2C_SDA | FUSB302B, TUSB546A CTL0/SDA, DP130 SDA_CTL; R23 10k pull-up | `PIN_I2C_SDA` |
| IO4 | 8 | DP_I2C_SCL | FUSB302B, TUSB546A FLIP/SCL, DP130 SCL_CTL; R24 10k pull-up | `PIN_I2C_SCL` |
| IO5 | 9 | FUSB302B_INT_N | U10 INT_N; R25 10k pull-up | `PIN_FUSB_INT` |
| IO6 | 10 | VBUS_SRC_EN | U11 TPS2553 EN; R46 1k pull-down | `PIN_VBUS_SRC_EN` |
| IO7, IO8, IO9 | 11–13 | NC | none | IO7 = `PIN_SRST`, the dummy TRST for the USB JTAG bridge |
| IO10 | 14 | ESP32_INT_N | J2.3, FPGA ball B2 | `PIN_FPGA_INT_N`. In dp_test it is `PIN_DP_HPD_OUT` |
| IO11–IO18 | 15–22 | ESP32_OPI_D0–D7 | J2.5/7/9/11/10/12/14/16, balls C2 F2 F1 A1 K1 K2 J4 K4 | `PIN_OPI_D0..7`. In dp_test, IO11 is the UART RX |
| IO19 / IO20 | 23 / 24 | ESP32_USB_D_N / _P | USB1 (with TVS D3/D4) | native USB CDC + JTAG |
| IO21 | 25 | ESP32_OPI_CS | J2.15, ball E1 | `PIN_OPI_CS` (unused by the protocol) |
| IO26 | 26 | NC | none | (quad-PSRAM CS1 inside the module) |
| IO47 | 27 | ESP32_OPI_CLK | J2.17, ball D1 | `PIN_OPI_CLK` |
| IO33 | 28 | FPGA_~RES_OUT | U1 74LVC2G06 1A, then 1Y = BUS_~RES (slot pin 31); R1 4.7k pull-up | `PIN_A2_RESET_OUT`. **HIGH asserts /RES** |
| IO34–IO37 | 29, 31–33 | NC | none | none |
| IO48 | 30 | FPGA_DONE | J1.25, ball D7 (DONE); R29 1k pull-up | `PIN_FPGA_DONE` |
| IO38 | 34 | ESP32_RECONFIG_N | J2.13, ball D8; R32 1k pull-up | `PIN_FPGA_RECONFIG_N`. Input except for CLI `reconfig` |
| IO39 | 35 | ESP32_JTAG_TCK | J2.21 (C1), J3.4; R31 5.1k pull-down | `PIN_TCK` |
| IO40 | 36 | ESP32_JTAG_TMS | J2.23 (B1), J3.5 | `PIN_TMS` |
| IO41 | 37 | ESP32_JTAG_TDI | J2.27 (A3), J3.6 | `PIN_TDI` |
| IO42 | 38 | ESP32_JTAG_TDO | J2.25 (A2), J3.3 | `PIN_TDO` |
| TXD0 / RXD0 (IO43/44) | 39 / 40 | NC | none | The a2mega UART pads are absent here |
| IO45, IO46 | 41, 44 | NC | none | Strapping pins, left alone |
| EN | 45 | CHIP_PU | R22 10k / C15 1 µF, S1 to GND | reset button |

**Differences from the a2mega 1.0a3**, all handled in `board_pins.h`:

- JTAG is TCK=39, TMS=40, TDI=41, TDO=42. The a2mega uses 40/41/42 with
  TDO on 39.
- I2C is on IO4/IO3 instead of IO1/IO2. FUSB302B INT_N is on IO5 instead of
  IO3.
- VBUS_SRC_EN is on IO6 instead of the IO46 strap pin.
- There is no debug UART on IO43/IO44.
- There is no PPO bus and no ESP_GPIO spares.
- IO38 is the FPGA RECONFIG_N, so the JTAG bridge's TRST dummy moved to the
  unconnected IO7. **Never park TRST on IO38 on this board.**

The expected pin map from the task was confirmed on every line, with
JTAG order TCK/TMS/TDI/TDO = IO39/40/41/42.

**Strapping pins:**

- IO0 is button-only. The module's internal pull-up gives a normal boot.
- IO3 (SDA) is high through R23. It only matters if the STRAP_JTAG_SEL
  eFuse is burned.
- IO45 and IO46 are NC.

No strap hazards.

## I2C bus (DP_I2C, 400 kHz, 10k pull-ups)

| Device | Ref | Strap | 7-bit address | Notes |
|---|---|---|---|---|
| FUSB302BMPX | U10 | part suffix (B = base) | **0x22** | -B01 would be 0x23, -B10 0x24, -B11 0x25 |
| TUSB546A-DCI | U8 | I2C_EN = R44 1k to 3V3 (I2C mode); A0 (pin 11) and A1 (pin 14) **NC** | **0x12** expected | Same floating-strap situation as the a2mega's TUSB1046A, which answers at 0x12. The firmware probes 0x12 and falls back to scanning 0x10–0x17 (`tusb_detect_addr`). |
| SN75DP130 | U7 | ADDR_EQ (pin 3) = GND | **0x2C** (design doc) | The firmware probes 0x2C, then 0x2D–0x2F. |

Run `i2cscan` (CLI) or `i` (telnet) to confirm on first power-up. All
three parts are on the same bus. The FPGA is not on it.

**TUSB546A vs TUSB1046A:**

- The pinout is identical: same WQFN-40 footprint, and every pin name
  matches the a2mega usage.
- The firmware uses the same register map: General `0x0A` (CTLSEL, FLIPSEL,
  HPDIN_OVRRIDE, EQ_OVERRIDE), DPEQ `0x10`/`0x11`, DPCTL3 `0x13` (snoop
  disable + AUX_SBU_OVR).
- Board strapping matches the a2mega too: CTL1/HPDIN (pin 23) and
  HPDIN/DCI_CLK (pin 32) are NC, and HPDIN_OVRRIDE is set as on the a2mega.
  The DPEQ0/A1, SSEQ0/A0, DPEQ1, SSEQ1, EQ0 and EQ1 pins all float. The
  firmware sets EQ_OVERRIDE plus register EQ (setting 0) before enabling
  lanes, exactly as on the a2mega.
- **Not verified locally** (no TUSB546A datasheet on disk):
  - whether the DP EQ step table matches the 1046A ladder that the telnet
    `+`/`-` labels assume (the dB labels may be off);
  - whether any 546A-specific register bit differs.
- The main delta is USB3 Gen1 vs Gen2, which is unused here.

**SN75DP130 wiring:**

- ADDR_EQ (pin 3) = GND.
- EN (pin 26) is NC; per the design doc it has an internal 200k pull-up.
- RSTN (pin 35) has only C29 100 nF to GND (internal pull-up plus a
  power-on delay). **No ESP32 control**: the only reset lever is a power
  cycle, or I2C if the datasheet exposes a soft reset.
- HPD_SNK (pin 11) is R39 10k to 3V3 (always awake). HPD_SRC and CAD_SRC
  are NC.
- CAD_SNK (pin 10) is R40 100k to GND (DP mode).
- DDC pins are NC.
- AUX_SNK goes to TUSB AUX with R41 (100k to GND on P) and R42 (100k to
  3V3 on N), the source-side bias.
- All of this matches DP_ALTMODE_DPHY_DESIGN.md §4.

## What is compiled out or changed for 225

| Feature | a2mega 103 | a2p25 225 | Mechanism |
|---|---|---|---|
| SD card | none (LittleFS at /sdcard) | none (LittleFS at /sdcard) | `A2MEGA_HAS_SD 0` |
| PD + DP mux | yes | yes | `A2MEGA_HAS_USBC_PD 1` |
| SN75DP130 driver | n/a | probe + raw dump/write | `A2MEGA_HAS_DP130 1` (`sn75dp130.c`) |
| FPGA debug UART | IO44 RX / IO43 TX | dp_test only: RX on IO11, no TX | `A2MEGA_HAS_FPGA_UART` |
| OSPI link + menu/disk/W5100 tasks | yes | DP_TEST=0 only | `A2MEGA_HAS_OSPI_LINK` |
| HPD wire to FPGA | IO33 (ESP_GPIO0) | dp_test: IO10; otherwise none | `PIN_DP_HPD_OUT` (−1 = record only) |
| Apple /RES driver | FPGA | ESP32 IO33; production builds hold /RES from boot until the disk task reports the mounts done or a 15 s backstop (`a2_reset_hold_release`, 10-12); dp_test releases at once | `PIN_A2_RESET_OUT` |
| USB host on the module's USB-C (USB1) | same hardware (1.0a3) — untested there | `usbhost.cpp`: device-first role policy (5 s window, BOOT held = device), then OTG host: XInput pads, HID keyboards/remotes → OSD menu buttons | `A2MEGA_HAS_OSPI_LINK` (production builds only) |
| PPO bus, ESP_GPIO spares | IO5–10, IO33–38 | n/a | not defined for 225 |
| LEDs | n/a | LED0 heartbeat, LED1 = HPD | `PIN_LED0/1` |

## dp_test mode (`A2P25_DP_TEST=1`, the default)

The DP bring-up bitstream (`boards/a2p25/hdl/dp_test/a2p25_dp_test_top.sv`
and its `.cst`) has no OSPI service. It repurposes two ESP32-link balls:

- **HPD:** ball B2 (ESP32_INT_N) is the bitstream's `dp_hpd` input, with
  PULL_MODE=DOWN. The firmware drives **IO10** with the PD-derived HPD
  level and the 0.75 ms IRQ_HPD low pulses. This is the same code path as
  the a2mega (`hal_set_fpga_hpd` and `hal_pulse_fpga_hpd_irq`). Telnet `r`
  pulses HPD low for 250 ms to restart the training ladder. LED1 mirrors
  HPD.
- **Telemetry:** ball C2 (ESP32_OPI_D0) is the bitstream's `uart_tx`,
  115200 8N1. The P1–P6 status lines repeat every ~0.34 s. The firmware
  runs `Serial1.begin(115200, SERIAL_8N1, 11, -1)`, which routes UART1 RX
  to IO11 through the GPIO matrix with no TX pin. Each line goes to three
  consumers, exactly as on the a2mega:
  - USB CDC (`Serial`);
  - the telnet console tee (`telnetd_console_tee`);
  - `wedge_watch_line()`, the auto virtual-replug policy, toggled with
    telnet `w`.
- **OSPI is never initialized** in this mode. `start_subsystems()` returns
  immediately, and the CLI's spi* commands report "not supported". Bringing
  up SPI2 would claim IO11 away from UART1. The OSD console, gamepad menu
  and disk serving do not exist with this bitstream anyway. Use telnet or
  USB CDC.
- ~8 s after boot, a one-shot `UARTDIAG: RX11 EDGES=… LOW=…` line reports
  whether the telemetry pad is toggling. A healthy line idles high with
  edge bursts.

⚠ **Do not run a DP_TEST=1 firmware against a production (OSPI) core.** In
production the FPGA drives B2 as INT_N, so both ends would drive IO10.
DP_TEST=0 leaves IO10 as an input. HPD for a production core must then
travel as an OSPI register write, which is not implemented yet: a
production displayport1 core and its register don't exist yet. In that
build `hal_set_fpga_hpd` only records the level.

## Telnet / CLI additions

- **Telnet `i`, CLI `i2cscan`:** I2C bus scan. Expect `12 22 2C`.
- **Telnet `n`:** SN75DP130 raw register dump, 0x00–0x3F, 8 per line,
  through osd_log and the telnet tee. Unreadable registers print as `--`.
- **CLI `dp130`:** dump 0x00–0x3F.
- **CLI `dp130 r <reg> [n]`:** read registers.
- **CLI `dp130 w <reg> <val>`:** write a register, with readback. This is a
  debug override.
- **CLI `dp130 probe`:** re-run the address probe.
- **CLI `a2reset`:** pulse Apple II /RES for 200 ms.
- **CLI `reconfig`:** pulse FPGA RECONFIG_N low for 1 ms, then wait for
  DONE. This reloads the bitstream from flash. Telnet `g` does the same
  over JTAG.
- **`pins` and `pd`:** now show the board, the dp_test state, the mux
  address and whether the HPD wire exists.

**DP130 policy:** the firmware **never writes the DP130 on its own**. It
stays in its power-up auto mode, which snoops link-training AUX writes and
sets its own VOD, pre-emphasis and EQ. The design doc expects this to work;
I2C is only for debug overrides.

**No DP130 register map is encoded.** The SN75DP130 datasheet (SLLSE57)
was not found locally: not in `/Volumes/Storage/Downloads`, `docs/`,
`boards/*/docs` or the a2-p25 repo, and `/Volumes/Public/Datasheets` was
not accessible. So the driver is probe plus raw access only. The design
doc cites reg 0x05 bit 7 = EQ_I2C_ENABLE; nothing in the code relies on
it. Once the datasheet is at hand, decode the status and ID registers in
`sn75dp130.c`.

The full existing a2mega command set still works unchanged: telnet
`p d x e + - l v f r g u t w`.

## Apple II /RES (IO33): behaviour to know

**Wiring:**

- IO33 drives the 1A input of U1 (74LVC2G06, an **inverting open-drain**
  buffer). 1Y drives slot /RES.
- R1 (4.7k) pulls IO33 **up**.

**Consequences:**

- **The Apple II is held in reset whenever the ESP32 is not actively
  driving IO33 low.** That covers power-up before firmware runs, the S1/EN
  reset, download mode during flashing, a crashed or blank ESP32, and
  `pinMode(INPUT)`.
- The firmware drives IO33 low as the very first thing in `setup()`, about
  300 ms after power-on including the ROM bootloader. The bring-up
  bitstream has no Apple-bus logic, so the card is passive and the Apple
  II then boots normally.
- A future "hold reset until the core is ready" policy (the Enhanced
  model) is a firmware decision on top of this.

## Board observations (possible problems)

1. **U1 74LVC2G06 runs on +5V (U1.5 = +5V), but both of its inputs are
   3.3 V signals:**
   - 1A = IO33, pulled up to 3V3;
   - 2A = FPGA_BUS_~OE, pulled up to 3V3 by R3.

   At VCC = 4.5–5.5 V the datasheet VIH is 0.7 × VCC (≈3.5 V at 5.0 V), so
   a 3.3 V "high" is **below the guaranteed VIH**. It will very likely work
   at room temperature (typical threshold is ~VCC/2), but it is out of spec
   and burns some shoot-through current in the input stage.

   The open-drain outputs are 5.5 V-tolerant regardless of VCC, so U1 could
   be powered from +3V3 with no loss of function. The outputs only pull
   slot /RES and the LSF0108 EN/VREF_B net (R2 200k to +5V) low. Consider
   this for the next spin; verify on the bench that /RES releases and
   asserts cleanly.
2. **The Apple II is held in /RES whenever the ESP32 is not running
   firmware** (see the /RES section above). This may be intentional, but it
   makes ESP32 flashing in-slot reset the host, and it means a bricked
   ESP32 bricks the Apple boot. A weak pull-*down* on IO33 instead of the
   R1 pull-up would invert the default to "released".
3. **No ESP32 control of DP130 RSTN or EN.** The only recovery is a power
   cycle (or I2C, if the part has a soft reset). The design doc listed an
   optional ESP32 GPIO here; IO7, IO8 and IO9 are free if a respin wants
   it.
4. **ESP32_INT_N (B2) is the only FPGA-to-ESP32 sideband line.** The
   dp_test bitstream reuses it as HPD-in, which is fine for bring-up, but in
   production HPD must go over OSPI. Free ESP32 pads (IO7–9, IO34–37) have
   no FPGA connection.
5. The title block of the root sheet still says "For Tang Primer 60K/138K
   SOM". This is cosmetic.

No pin-level errors were found in the ESP32 section. Every net goes where
the design doc says.

## Open questions

- **TUSB546A I2C address with A0/A1 floating:** 0x12 is assumed. The
  firmware auto-detects in 0x10–0x17 and logs `USBC: DP MUX AT 0xNN (NOT
  0x12)` if the mux answers elsewhere.
- **SN75DP130 address:** 0x2C is from the design doc and is unverified
  against the datasheet. The firmware probes 0x2C–0x2F.
- **DP130 register map:** needed to decode the dump. Get SLLSE57.
- **TUSB546A EQ ladder:** does it match the TUSB1046A's, so the dB labels
  on `+`/`-` are right?
- **FLIPSEL and AUX_SBU_OVR on the a2p25 SBU routing:** the a2mega
  convention is reused, and telnet `f` flips it live if AUX is crossed.
- **Production HPD path:** the OSPI register still needs to be defined
  together with the displayport1 production core.

## Files

All firmware changes are under `boards/a2mega/src/a2fpga_esp32/`:

- `board_pins.h`: the rev-225 block, with JTAG and UART moved per
  revision. New feature flags: `A2MEGA_HAS_FPGA_UART`,
  `A2MEGA_HAS_OSPI_LINK`, `A2MEGA_HAS_DP130`, `PIN_A2_RESET_OUT`, LEDs.
- `Makefile`: `BOARD_REV=225`, `DP_TEST=`.
- `a2fpga_esp32.ino`:
  - OSPI gating, the dp_test UART on IO11, early /RES release, LEDs;
  - new CLI commands `i2cscan`, `dp130`, `a2reset`, `reconfig`;
  - the UARTDIAG pin now follows `PIN_RXD`.
- `usbc_glue.cpp/.h`:
  - mux address auto-detect;
  - HPD write helper (no-wire safe, LED1 mirror);
  - exported locked I2C helpers plus a bus scan;
  - the I2C mutex is created before first use.
- `sn75dp130.c/.h` (new): probe plus raw dump, read and write.
- `telnetd.c`: `i` and `n` keys; the banner shows the board name.
- `tests/host/mock_fusb302.c`: added the missing `fusb302_pd_reset` stub.
  The host test had stopped linking after the PD-reset work; it now passes
  14/14.

There is one known issue outside this work: `BOARD_REV=102` (a2mega 1.0a2x)
fails to link at HEAD with an undefined `usbc_virtual_replug_fast`. The
cause is that `wedge_watch.c` calls the USB-C glue, which 102 does not
build. That failure was already there before these changes.

## Bench traps (10-12)

- **Mac-side DTR/RTS and the S3's auto-download logic.** The USB-Serial-JTAG
  peripheral maps the host's DTR/RTS onto IO0/EN: a port opened (or left)
  with DTR asserted and RTS released holds IO0 low, so the next reset — an
  esptool hard reset, a console open, even a manual EN tap — lands in ROM
  download mode (`rst:0x15 USB_UART_CHIP_RESET, boot:0x20 DOWNLOAD`). Seen
  repeatedly on 10-12 after flashing; the only reliable recovery was to
  unplug the Mac cable and power-cycle. Use telnet (WiFi) as the console
  whenever possible and keep serial for flashing; `scratchpad/console.py`
  parks both lines deasserted.
- Once the firmware is in USB host mode the Mac sees no device at all; to
  flash, reboot with the Mac attached (device-first window) or hold BOOT.
- With a Mac on USB1 the board is back-powered through PTC F1: an IIgs
  power cycle does not reboot the ESP32.

## Updating the firmware without the download-mode dance (10-12)

Builds on an OTA partition scheme with two app slots (`PartitionScheme=
min_spiffs` since 2026-11-19: 1,966,080-byte slots and a 128 KB LittleFS;
`default` before that: 1,310,720-byte slots and a 1.25 MB LittleFS). Put
`build/a2fpga_esp32.ino.bin` on the image volume — copy it to
the USB stick, or FTP it to the board (`curl -T build/a2fpga_esp32.ino.bin
ftp://<board-ip>/`, which lands on whatever is mounted at /sdcard) — then
FIRMWARE menu → `UPDATE MCU (.BIN ON VOLUME)` → pick the file → `INSTALL
MCU FIRMWARE NOW`; or over the serial/telnet CLI `fwupdate <file>` then
`fwupdate go`. The board restarts into the other slot (`MCU SLOT: ota_x`
on the FIRMWARE screen). `make upload` over USB1 still works for the
bench and is required once to install the OTA partition table.

**Partition change 2026-11-19 (`default` → `min_spiffs`):** the BLE HID host
(`ble_hid.c`, [BLE_HID_FEASIBILITY.md](../../a2mega/docs/BLE_HID_FEASIBILITY.md))
adds ~180 KB and no longer fits the 1,310,720-byte `default` slots. A card
still on the `default` table refuses the new image over OTA ("FILE LARGER
THAN OTA SLOT" from `fwupdate.c`), so each card gets **one USB `make
BOARD_REV=225 upload`** with the Apple II off; that rewrites the partition
table and boots `ota_0`. `nvs`, `otadata` and `coredump` sit at the same
offsets in both tables, so WiFi credentials, settings and Bluetooth bonds
survive. The LittleFS "local volume" shrinks to 128 KB: it is only the
stickless fallback now — disk images, FTP drops and OTA `.bin` files live on
the USB stick, which is assumed present (Ed, 2026-11-18).
