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
| RTL8152/CDC-ECM/ASIX USB-Ethernet uplink | **generic CDC-ECM/NCM host driver** (`usbeth.c`, 2026-11-17) on USB1 as a second Uthernet II uplink beside WiFi; built, hardware test pending | see `../../a2mega/docs/ESP32_ENHANCED_PORT.md` § USB-Ethernet uplink |

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
