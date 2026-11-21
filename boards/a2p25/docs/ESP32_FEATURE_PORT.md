# ESP32 firmware: porting the a2n20v2-Enhanced (BL616) feature set

Target: the shared ESP32-S3 firmware in `boards/a2mega/src/a2fpga_esp32/`
(a2mega 1.0a3 = `BOARD_REV=103`, a2p25 = `BOARD_REV=225`). Both boards use
the same ESP32-S3-MINI-1-N4R2, have **no SD card**, **no USB host port**
and **no wired Ethernet**; everything below is done once, behind the
existing `BOARD_REV` / `A2MEGA_HAS_*` switches, so the a2mega gets it too.

Status: P1–P4 hardware-verified (2026-10-12 evening); P5 next. Gap analysis by file-level comparison of
`boards/a2n20v2-Enhanced/src/a2n20_bl616/` (BL616, `firmware_host/`) with
the ESP32 tree; see `boards/a2mega/docs/ESP32_ENHANCED_PORT.md` for the
first slice that was already ported.

## 1. Hardware facts that shape the port (a2p25, from the netlist)

| Item | a2p25 | Consequence |
|---|---|---|
| ESP32 USB (IO19/IO20) | USB1: D+/D− on the S3's OTG pins; VBUS ↔ board +5 V through PTC F1 (a plugged-in device is powered from the slot); CC1/CC2 5.1 k to GND | **Identical to the BL616's port on the Tang Nano 20K: USB host works here** (hubs, XInput pads, HID remotes, mass storage, with the same C-to-A adapters). USB1 is also the Mac CDC/JTAG port → runtime OTG role policy needed. |
| Video port USB2 D+/D− | not connected (A6/A7/B6/B7 NC) | No USB data on the video port (DP only). |
| Storage | LittleFS 1.875 MB at `/sdcard` (`no_ota`: 2 MB app + 1.9 MB FS) | Image volume = **USB mass storage on USB1** as on the BL616; LittleFS/FTP stays for small images and config. |
| Networking | WiFi STA (`wifi_bridge.c`), FTP, telnet, port-2323 bitstream streaming | — |
| Apple /RES | ESP32 IO33 → 74LVC2G06 → slot pin 31 (HIGH asserts) | The FPGA's reset-hold output has no pin; the hold policy lives in the firmware (P1, done 10-12). |
| FPGA-side peripherals compiled out of the a2p25 top | `UTHERNET2_ENABLE=0`, `SUPERSERIAL_ENABLE=0`, `MOCKINGBOARD_ENABLE=0`, `SUPERSPRITE_ENABLE=0` (BSRAM/CLS budget); `usb_hid_host` absent, pad/key regs 0x16–0x1B tied to 0 | W5100 bridge has nothing to talk to; SSC bridge impossible as-is; pad/key regs are the input path's sink. |

## 2. Gap table (BL616 feature → ESP32 status → plan)

| Feature | ESP32 today | Plan |
|---|---|---|
| Disk II .dsk/.do/.po/.2mg/.nib serving, GCR, write-back | present (`disk.c`, `gcr_dsk.c`) | keep; storage strategy below |
| ProDOS HDD .hdv/.po/.2mg, 2 units | present (`disk.c`, SPACE 5) | keep; images need network/flash strategy |
| **Reset hold until media mounted** | partial: writes reg 0x2E once; on a2p25 /RES is IO33 and released early in `setup()` | **P1** — hold IO33 from boot, release on mount-done or deadline (same 7 s / 15 s contract as the BL616), read-back + retry of 0x2E where the FPGA owns reset (a2mega) |
| Gamepad menu + settings + slot map | present (`menu.c`, `settings.c`) | keep; needs an input source (P2) |
| **XInput gamepad / HID keyboard / media remote input** | missing — ESP32 USB OTG only used in device mode | **P2 — ESP32-S3 USB host on USB1** (esp-idf `usb_host` / TinyUSB host): port the BL616's `usbh_xinput.c` + `usbh_hidinput.c` logic (XInput init/EP1, boot keyboard, consumer-page remotes incl. the two known dongles) → write pad regs 0x16–0x18 / key regs 0x19–0x1B as `usb_hid_host` did. OTG role policy: boot in device mode; if no host enumerates us within ~2 s, switch to host mode; BOOT held or telnet/CLI command forces device mode (programming). BLE HID stays a possible later addition. |
| USB mass storage image volume | replaced by LittleFS | **P3 — USB MSC on USB1** as the image volume (FatFS over `usb_host` MSC, the BL616's `diskio_host.c` role), with the BL616's hub-adopt/VBUS-cycle supervisor where applicable; LittleFS/FTP remains the fallback for small images and config. A network image server stays an option for HDD images on a stick-less setup. |
| W5100 / Uthernet II bridge | present (`w5100.c` + WiFi MAC-NAT) | blocked by `UTHERNET2_ENABLE=0` on a2p25 — **P5** win back the core (BSRAM: 10 blocks; candidates: framebuffer line buffer, DOC) |
| Telnet console / menu mirror | present; lacks bus-event capture, scope, boot timeline | P6 (debug): add SYSTIME-based boot timeline (regs 0x08–0x0B exist); bus FIFO needs an OSPI SPACE 2 — defer |
| FTP server | present | keep |
| FPGA self-flash from storage | present (`fpgaupdate.c`), bitstream does not fit LittleFS → network streaming (`fpgastream.c`) | keep; P3(a) does not change this |
| **MCU firmware self-update + warm restart** | missing (`no_ota` partitions; reflash over USB1) | **P4** — switch to an OTA scheme (2 × 1.5 MB app + ~0.9 MB FS, or 2 × 1.25 + 1.4) and port `fwupdate.c` to `esp_ota`; weigh against P3(a) — the two compete for flash. Alternative: keep `no_ota`, rely on USB1 reflash (bench) and network streaming for the FPGA only |
| SSC → TCP Hayes modem | missing; SSC core off, no UART pins | P7 — only after an SSC core that talks over the OSPI link exists (new HDL); defer |
| WS2812 MCU-liveness LED | n/a (LED0 heartbeat, LED1 = HPD) | drop |
| Standalone fallback (no MCU) | present in the connector | keep |
| USB enumeration supervisor, SD tunnel | n/a (no SD) | drop |
| RTL8152/CDC-ECM/ASIX USB-Ethernet uplink | **generic CDC-ECM/NCM host driver** (`usbeth.c`, 2026-11-17) on USB1 as a second Uthernet II uplink beside WiFi; built 11-17, RTL8152B running on the a2p25 11-18 | see `../../a2mega/docs/ESP32_ENHANCED_PORT.md` § USB-Ethernet uplink **Hardware 2026-11-18: RTL8152B (0BDA:8152) runs as CDC-ECM on its configuration 2 (`usbeth_attach_alt`), wired DHCP lease, telnet/FTP over the wire; needs 3 of the ESP32-S3's 8 host channels, so stick + Ethernet leaves no room for a HID dongle.** |

## 3. Proposed order

1. **P1 reset hold on IO33** — DONE: `a2_reset_hold_release()` (.ino),
   called from disk.c's release path; 15 s backstop in loop(); dp_test
   builds release at once. Verified: ESP32 reboot → IIgs reset beep →
   `A2: /RES RELEASED (NO MEDIA)` ~7 s later. Caveat: with a Mac on USB1
   the board is back-powered through the PTC, so an IIgs power cycle does
   not reboot the ESP32 and the hold does not re-engage (the FPGA stays
   configured; the Apple simply boots).
2. **P2 USB host on USB1** — DONE: `usbhost.cpp` (IDF usb_host + usb_phy,
   XInput / boot keyboard / consumer-page remotes with the BL616 maps,
   attach/detach on a worker task — doing it in the client callback
   deadlocked the event pump and watchdog-reset the chip = Apple reset
   loop). Role policy: device mode for 5 s after boot; a PC enumerating
   us or BOOT (S2) held keeps device mode, otherwise the PHY moves to the
   OTG controller in host mode (CDC console gone, telnet stays). Verified:
   XInput pad on USB1 via C-to-A adapter drives the OSD menu. Every
   supported interface of a device is serviced (composite remotes =
   keyboard + consumer-page interfaces; the first version claimed only
   one): the XING WEI remote dongle (1915:1025, audio + 2 HID
   interfaces) navigates the menu on a hub. Attach logs `VID:PID
   [class/sub/proto …]` per device for diagnosis over telnet.
   Not done: feeding the FPGA's Apple-side joystick (needs ESP32-writable
   pad regs in the OSPI connector — the 0x16-0x1B regs are fabric→ESP32).
3. **P3 USB mass storage** — DONE: MSC bulk-only/SCSI in `usbhost.cpp`
   (INQUIRY, TEST UNIT READY spin-up, READ CAPACITY, READ/WRITE(10), 4 KB
   per command, IN transfers rounded to the packet size — the host library
   rejects anything else); `usbstorage.cpp` = FatFS diskio glue + VFS mount
   of the stick at `/sdcard`; the backend switch runs in the disk task
   (`disk_poll`: unmount images → `storage_activate(usb)` swaps what sits
   at `/sdcard` → remount), release deadline 7 → 10 s. One-root model as
   on the BL616: stick when present, flash otherwise. Verified: 32 GB
   FAT32 stick on a hub with a keyboard — `STORAGE 30145 MB`, mounted,
   disk1/disk2.dsk + hdd1.hdv mounted RW, `/RES RELEASED (MEDIA MOUNTED)`,
   Apple boots from the stick. Not ported: the BL616 hub supervisor
   (stalled-hub adopt / VBUS cycle), `boot_pref`.
   **Stick compatibility (bench 2026-11-19, Ed, firmware 62153cbf, hub
   05E3:0610 + remote dongle 1915:1025):** USB 3.x sticks fail before the
   firmware sees them — PNY 64 GB Elite-X Fit USB 3.0 and Verbatim 32 GB
   Store 'n' Stay Nano USB 3.2 Gen 1 both die at enumeration (`ENUM: BAD
   TRANSFER STATUS 1: CHECK_SHORT_DEV_DESC`, the IDF's transaction-error
   status on the first 8-byte device-descriptor read, then `EXT_PORT: [1:3]
   PORT DISABLED, RESET ATTEMPTS=1`; replugging repeats it). A K&ZZ 32 GB
   USB 2.0 stick enumerates (090C:1000), mounts and serves. The S3 host is
   full-speed only and a hub whose upstream runs at full speed holds the
   stick at full speed too; some USB 3.x controllers answer that with
   errors. The single reset attempt is the Arduino core's prebuilt ESP-IDF
   setting and cannot be raised from this tree. **Recommend USB 2.0 sticks.**
   With no stick the disk task falls back to the empty flash volume,
   releases /RES with `(NO MEDIA)` and leaves the OSD console on screen by
   design (`disk.c`), which reads as a hang although the Apple is running
   (status register 0x07 = 0x87: clock alive, reset released).
   **Hub-port retry (firmware, 2026-11-20):** the IDF hub
   driver gives a downstream port one reset and then logs `EXT_PORT:
   [hub:port] Port disabled, reset attempts=1`; nothing re-enumerates the
   port until its connection changes. `usbhost.cpp` now manufactures that
   change: `idf_log_tee.c` hands every mirrored error line to a hook,
   `usbhub_retry.c` (pure, host-tested in `tests/host/`) parses the line
   and runs a bounded ladder, and the worker task opens the hub from our
   own `usb_host` client (allowed: the driver opens hubs through
   `usbh_devs_open`, no client owns them, and the USB DEVICES screen
   already opens them), reads the hub descriptor and the port status, and
   power-cycles the one port over EP0 (ClearPortFeature PORT_POWER, 200 /
   400 / 600 ms off, SetPortFeature PORT_POWER) after a 0.5 / 1 / 2 s
   settle. The hub reports a fresh connection and the driver debounces,
   resets and enumerates again. At most 3 cycles per plug; the next
   failure line inside an 8 s window is the cycle's verdict, one outside
   it is a new plug; after the third failure one give-up (`HUB 1 PORT 3
   FAILED TO ENUMERATE, PLUG THE STICK DIRECTLY`) and a 3 s quiet period,
   so only a human replug restarts the ladder. Guards: a port whose status
   shows PORT_ENABLE (its device enumerated) or no connection is never
   touched; a hub that advertises ganged power switching is refused (one
   ClearPortFeature would cut the dongle and the Ethernet adapter too); a
   hub that answers the request but leaves PORT_POWER and PORT_CONNECTION
   set did nothing and is reported once (`IGNORED PORT POWER OFF`); the
   hub handle is closed after every cycle; no channels are added. A
   recovered stick is announced by matching the new device's parent
   handle (`usb_device_info_t.parent`) to the hub: `HUB 1 PORT 3 RECOVERED
   AFTER n PORT POWER CYCLE(S)`. Console lines all start `USB HOST:`.
   **Limits:** the cycle is electrically a replug, so a stick that fails
   every physical replug may fail every cycle too; what it buys is 3 more
   attempts per plug without a hand on the stick, and timing that differs
   from a human plug. The 30 ms reset recovery and the single attempt
   stay the prebuilt library's. The "delay before our client's first
   activity" idea cannot help: the failing transfer is the driver's first
   8-byte descriptor read, before any client hears of the device, so no
   such knob was added. Hub:port in the log is parent address and 1-based
   port, as the driver prints it; a misread only makes the port-status
   check decline. **Hardware test plan** (Ed, a2p25, remote dongle
   1915:1025 on the 05E3:0610 hub, telnet console open): (1) PNY
   13FE:6700 into a hub port — expect `ENUM FAILED, POWER CYCLING PORT
   (TRY 1/3)`, then either `RECOVERED` + `STORAGE n MB` + images mounted,
   or TRY 2/3, TRY 3/3 and the give-up line, never more than 3 cycles;
   note which; (2) the Verbatim stick, same; (3) unplug the stick during a
   ladder — expect `IS EMPTY NOW` and silence; (4) replug after a give-up
   — a fresh TRY 1/3 (bounded again); (5) regression: the K&ZZ USB 2.0
   stick, the HID dongle and the RTL8152B adapter behind the hub still
   enumerate and work, the dongle keeps working through a stick ladder
   (ganged-power guard: if the console says `SWITCHES PORT POWER GANGED`
   the hub cannot be used for this and nothing was touched); (6) `usb`
   console command still lists everything. If a retry succeeds, record the
   attempt number here; if the hub says `IGNORED PORT POWER OFF`, that hub
   has no per-port power state and the fallback is a hub that does.
   **Hardware result 2026-11-20 (Ed, firmware 3ffd5108 flashed OTA, PNY
   13FE:6700 swapped in behind the 05E3:0610 hub with the dongle):** the
   chain fired end to end — `ENUM: [1:3] CHECK_SHORT_DEV_DESC FAILED`,
   `EXT_PORT: [1:3] PORT DISABLED`, `USB HOST: HUB 1 PORT 3 ENUM FAILED,
   POWER CYCLING PORT (TRY 1/3)` — and stopped at the ganged-power guard:
   `HUB 1 SWITCHES PORT POWER GANGED (ALL PORTS), NO PORT RETRY: PLUG THE
   STICK DIRECTLY`. The 05E3:0610 (Genesys GL85x) advertises ganged power
   switching in its hub descriptor, so a per-port cycle is not available on
   it; one ClearPortFeature(PORT_POWER) would drop every port, dongle
   included. Nothing was touched: USB DEVICES still lists hub + dongle,
   the dongle works, the PNY never got an address. The retry as specified
   (per-port, never disturb an enumerated device) therefore cannot help on
   this hub. **Setting added the same day (Ed): SETTINGS → `USB HUB PORT
   RETRY` = `ALL PORTS` (a ganged hub is cycled anyway: every device on it
   re-enumerates, under a second, still at most 3 cycles per plug; console
   adds `GANGED HUB: ALL ITS PORTS WERE CYCLED`) / `PER-PORT` (the refusal
   above). Stored in the settings blob (`usb_hub_retry_perport`, one
   reserved byte, no version bump); telnet `usb retry on|off` sets and saves
   it. The first build (18bfd578) defaulted to PER-PORT; after the result
   below Ed flipped the default to ALL PORTS, so the stored byte's sense
   inverted (0 = ALL PORTS) to keep saved blobs loading unchanged — a card
   that had saved `ALL PORTS` under 18bfd578 reads back as `PER-PORT` once
   and needs `usb retry on` (or the toggle) again.**
   **Hardware result, ALL PORTS mode, 2026-11-20 (Ed, firmware 18bfd578
   flashed OTA, `usb retry on` saved, K&ZZ swapped for the PNY behind the
   05E3:0610 hub with the dongle on it):** the ladder ran to a recovery.
   `HUB 1 PORT 3 ENUM FAILED, POWER CYCLING PORT (TRY 1/3)` / `GANGED HUB:
   ALL ITS PORTS WERE CYCLED`; the driver failed the stick again (`ENUM:
   [1:3] CHECK_SHORT_DEV_DESC FAILED`, `EXT_PORT: [1:3] PORT DISABLED`);
   `TRY 2/3`, all ports cycled again; then `USB HOST: HUB 1 PORT 3
   RECOVERED AFTER 2 PORT POWER CYCLES`, `13FE:6700 [08/06/50]`, `STORAGE
   59153 MB`, stick mounted at /SDCARD, DOS33.NIB mounted RW, `DISK II:
   READY - STARTING APPLE II`. Afterwards `usb` lists hub (addr 1), dongle
   1915:1025 KEYBOARD at addr 2 in use, and the PNY as STORAGE at addr 4 in
   use. So on this hub the all-ports cycle is what makes the PNY usable:
   two automatic replugs did what a human replug never did, i.e. the
   different timing (0.5 s / 1 s settle, 200 / 400 ms off) matters, not
   only the repetition. Cost per attempt: every device on the hub
   re-enumerated (the dongle came back by itself, same address). Not yet
   checked: a keypress on the remote after the ladder, the Verbatim stick,
   steps (3) and (4) of the plan, the RTL8152B uplink through a ladder (it
   would re-enumerate and re-DHCP). Default still PER-PORT; given this
   result the case for ALL PORTS as the default is that cheap hubs gang
   their port power, so PER-PORT refuses on exactly the hubs people have,
   while the only cost is a sub-second blink of the hub's other devices,
   paid only when a stick has already failed. **Ed's call the same morning:
   default = ALL PORTS.** Re-run on the shipped-default build (bee90d1a,
   `MCU NOV 20 2026 18:02:30`, PNY swapped in for the K&ZZ behind the hub):
   identical — TRY 1/3, TRY 2/3, `RECOVERED AFTER 2 PORT POWER CYCLES`,
   STORAGE 59153 MB, DOS33.NIB served, dongle back at addr 2 in use. Two
   for two on this hub, both at the second cycle. Ed the same evening: the
   Verbatim Store 'n' Stay Nano behind the hub comes up as well, and the
   remote (1915:1025 dongle) works after a ladder completes — so plan steps
   (2) and the dongle half of (5) pass. **Write check (same evening, Ed's
   question: if these sticks cannot be written to, bringing them online is
   moot):** Verbatim 18A5:0250 "STORE N GO" behind the hub, recovered by
   the ladder at cycle 2 — FTP `STOR` of 64 KB random and of the 1.3 MB
   firmware image (11 s) both read back byte-exact over FTP, files deleted
   afterwards. So the Verbatim is fully usable behind the hub. The PNY
   13FE:6700 is the odd one: reads serve, FTP writes break at a 0-byte file
   (3/3, see ESP32_FW_A2P25.md). That is a PNY-specific write-path problem,
   not a property of sticks that need the ladder; the MSC write error is not
   logged today, so the next step there is an `osd_log` on the failing
   `fwrite`/SCSI WRITE(10) status to see what the stick returns. **Resolved
   the same night (probe firmware, ESP32_FW_A2P25.md):** the PNY's FIRST
   WRITE(10) after power-up takes ~1.9 s to return its CSW (`usb probe 2048`:
   write 1940 ms); every later write is 17–47 ms at any address, 1 MB in or
   59 GB in. The firmware's 1.5 s wait cut that first write off, and — the
   real bug — `bulk_xfer` then freed the still-in-flight transfer (this
   IDF's `timeout_ms` is unimplemented), which broke the FTP session and,
   once, rebooted the card. With the cancel fix and an 8 s write CSW wait
   (98ff773e) the PNY takes the 1.3 MB upload (69 s vs 11 s on the Verbatim)
   with byte-exact read-back. So: the PNY is writable; it is slow to wake
   and slower than the 32 GB sticks, nothing more. Caveat for Disk II
   write-back: the first track flush to a freshly plugged PNY will hold the
   MSC lock ~2 s. Still unexercised: unplug during a ladder, replug after a
   give-up, the RTL8152B through a ladder.
4. **P4 MCU self-update** — DONE (code): `fwupdate.c` on ESP-IDF OTA
   (`esp_ota_begin/write/end`, boot partition switch, restart in 2 s);
   the image is any `*.bin` on the volume (stick, or FTP-dropped onto
   whatever is mounted at `/sdcard`), checked for the ESP image magic +
   ESP32-S3 chip id and the OTA slot size. FIRMWARE menu: `MCU SLOT`,
   `UPDATE MCU (.BIN ON VOLUME)` → picker → `INSTALL MCU FIRMWARE NOW`;
   CLI `fwupdate <file> | go | cancel`. Partition scheme for the 4 MB
   boards (225 and 103) is now Arduino `default`: 2 × 1.25 MB OTA app
   slots + 1.4 MB LittleFS (firmware is 1.11 MB = 84 %; `min_spiffs`
   gives 1.9 MB slots if it grows). The first install of this scheme is
   one more download-mode flash; afterwards updates are a file drop.
   The Arduino core marks the running app valid at init, so there is no
   automatic rollback — the install validates the image before switching.
   Verified: image FTP'd onto the stick, installed from the FIRMWARE menu
   driven over telnet, board rebooted into `MCU SLOT: APP1` with the
   stick and images remounted.
5. **P5 Uthernet2 core back on the a2p25** (HDL, BSRAM budget).
6. P6 boot timeline / debug; P7 SSC bridge (needs HDL).

Open decisions (ed): the OTG role policy for USB1 (auto device→host
with a timeout, vs a strap/command); P4 flash split (OTA pair vs bigger
LittleFS) once the stick carries the images.

## 4. Transport notes

Same request/XFER/ACK handshake as the BL616 link; only space numbers and
window offsets differ (OSPI: SPACE 1 OSD VRAM, 3 W5100, 4 Disk II tracks,
5 HDD blocks; regs STATUS 0x07, SYSTIME 0x08–0x0B, pad/key 0x16–0x1B, HDD
0x26–0x2D, reset release 0x2E, VOL ACKs 0x4E/0x5E, doorbell 0x7A). No
SPACE 2 bus FIFO, no 0x2F SSC baud, no WS2812/CardROM/SD-tunnel ports.
