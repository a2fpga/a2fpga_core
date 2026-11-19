# BLE HID (HOGP) on the a2mega / a2p25 ESP32-S3 — feasibility and plan

> Date: 2026-11-18 (research); implemented 2026-11-19 — see "Status" below.
> Decision (Ed, 2026-11-18 evening): assume the `min_spiffs` partition scheme
> and assume a USB stick is present; the shrunken LittleFS fallback volume
> (§3.1) is accepted, not a trade-off to weigh.
> Firmware tree: `boards/a2mega/src/a2fpga_esp32/` (shared by the a2mega 1.0a3
> and the a2p25 displayport1). Build measurements below are from throwaway
> variants that were built and discarded; the exact sources are described in
> the appendix so they can be recreated.

## Status (2026-11-19)

Phases 0–2 of §7 are written and build; **nothing has run on hardware yet**
(no card flashed from this branch). What landed, all in
`boards/a2mega/src/a2fpga_esp32/`:

- `Makefile`: `PartitionScheme=min_spiffs` for BOARD_REV 225 and 103
  (migration note in `boards/a2p25/docs/ESP32_FW_A2P25.md`).
- `hid_map.c/.h`: the usage tables and consumer-layout parser hoisted out of
  `usbhost.cpp` (which now calls them), plus a general report-map parser
  (keyboard array, consumer array/bitmap, button bitmap, hat, X/Y axes) and a
  gamepad button table (Linux-gamepad order for ≥ 15-button pads: Xbox BLE,
  Stadia, Steam).
- `ble_hid.c/.h`: HOGP central on raw esp-nimble exactly as §2.3 describes:
  Just Works bonding, `ble_store_config_init()` bonds in NVS, GAP name read,
  HID service → characteristics → descriptors (one Find Information pass over
  the service, CCCD/Report Reference assigned by handle order) → Report
  References → `ble_gattc_read_long` of the Report Map → CCCD writes on every
  input report (Boot Keyboard Input only when the map yields nothing) →
  `NOTIFY_RX` decode into the A2PAD word. One peer, record in NVS
  `blehid/peer`; reconnect = `ble_gap_connect(..., BLE_HS_FOREVER)` to the
  bonded address at a 1 s / 50 ms initiating scan (5 % duty). Encryption
  failure (device lost its bond) deletes ours and re-pairs once on the same
  link; `REPEAT_PAIRING` lets the device re-pair.
- `menu.c`: a top-level **BLUETOOTH** entry (STATUS / DEVICE / ADDRESS,
  PAIR NEW DEVICE, FORGET DEVICE) and a **PAIR BLUETOOTH DEVICE** screen: a
  60 s active scan lists HID advertisers by RSSI; A on one connects, or
  "CONNECT STRONGEST" fires by itself 15 s after the first device appears
  (a BLE-only user has no other input); B cancels. Both screens repaint on
  host events. SYSTEM STATUS shows the BLE state; `menu_tick()` ORs
  `ble_hid_buttons()` in.
- Console: `ble [pair|cancel|list|connect <n>|forget]` on the serial CLI and
  in telnet line mode (`ESP32_CONSOLE.md`).

**First hardware pass, a2p25 (2026-11-19 evening, commit abff4cd3 + the OSD
line fix):** one USB `make BOARD_REV=225 upload` rewrote the table; the card
came back on `app0` with its WiFi credentials and slot map intact (NVS
survived), FPGA link up, DDR3 calibrated, `BLE: READY, NO DEVICE PAIRED`.
`ble pair` scanned and `ble cancel` returned to idle with no heap movement.
Gate 0 numbers (`meminfo`, steady state after boot, Mac on USB1 so no stick):

| | internal free | internal total |
|---|---|---|
| before (Nov 18 firmware) | 111,660 B | 256,684 B |
| after (BLE host up) | 32,860 B | 242,628 B |
| follow-up build 820c11e3 (BLE up, ~31 KB moved to PSRAM) | 64,268 B | 274,068 B |

So the BLE host costs ~79 KB of internal RAM: ~14 KB taken statically by the
controller plus ~55 KB allocated at `ble_hid_start()` (OSD line `BLE UP: INT
HEAP 109812 -> 5xxxx`). 32 KB free internal was **too tight**: with the hub +
stick back on USB1 the hub enumerated but the stick behind it never did (USB
DEVICES / `usb` showed only the hub; no volumes mounted, Apple II booted to
no media). Changes in the follow-up build the same evening:

- the BLE host now starts from `loop()` only after the disk task has
  released the Apple II reset (media mounted or its 10 s deadline), so the
  stick's enumeration takes its internal-RAM allocations first;
- BLUETOOTH → `BLUETOOTH RADIO ON/OFF` (setting `ble_off`, console `ble radio
  on|off`): OFF skips the host at boot, for A/B tests without reflashing;
- first slice of the heap diet: the menu item table (9 KB), the two
  directory listings (2 × 8 KB) and the FTP sessions (5.5 KB) moved from
  `.bss` to PSRAM — ~31 KB of internal RAM back. Candidates left (DMA
  buffers excluded): `s_rx` 12 KB, fpgastream/fpgaupdate header scans 2 ×
  4 KB, fwupdate chunk 4 KB; task stacks (56 KB) can go to PSRAM for the
  tasks that never hand stack buffers to SPI/USB DMA
  (`CONFIG_SPIRAM_ALLOW_STACK_EXTERNAL_MEMORY=y`); WiFi dynamic buffers in
  `wifi_init_config_t`;
- telnet `meminfo` (free / largest block / minimum ever) and a top-level
  **USB DEVICES** screen + `usb` command listing every enumerated device,
  so the stick question is answered at a glance.

The follow-up build went onto the a2p25 over USB the same night (Mac on
USB1): BLE host up after the disk release, internal free 64,268 B (total
274,068 B, the PSRAM moves also shrank `.bss`), PSRAM 2,021,640 B free.
Whether the stick behind the hub now enumerates is checked next, with the
hub back on USB1.

Still owed: confirm the stick enumerates with that build, pair an actual
device, WiFi-bridge throughput with BLE connected, passkey display for
MITM-only keyboards.

## 1. Why

The ESP32-S3 OTG core has 8 host channels and the IDF `usb_host` library pins
one channel per pipe for the life of a device. On USB1 (behind the USB-C dock
hub) that is hub 2 + USB stick 3 + USB-Ethernet adapter 3 = 8: the USB HID
remote dongle (VID 4842 PID 0001, keyboard + consumer interfaces) cannot
coexist with the stick and the Ethernet uplink. See the USB-Ethernet notes in
[ESP32_ENHANCED_PORT.md](ESP32_ENHANCED_PORT.md). A Bluetooth LE remote,
keyboard or gamepad talks to the ESP32-S3's own radio and uses no USB channel,
so it is the obvious way to keep "remote + stick + Ethernet" without an FPGA
side USB port (rejected) or a firmware time-share of HID vs storage pipes
(accepted as the other path).

**Verdict:** feasible, with one prerequisite: the firmware has to move to the
`min_spiffs` partition scheme for bigger OTA slots (one-time USB flash per
card; decided 2026-11-18, stick assumed present). The
BLE stack adds about 180 KB of flash, and the a2p25 build is already at 86 %
of the 1.25 MB `default` slot. Everything else (host stack, HID-over-GATT,
bonding, menu pairing without text input) is ordinary work on APIs that are
already compiled into the Arduino core's IDF libraries.

## 2. Stack: what the precompiled libs allow

arduino-esp32 3.3.5 ships prebuilt IDF 5.5 libraries
(`esp32-arduino-libs/idf-release_v5.5-9bb7aa84-v2/esp32s3`). The `sdkconfig`
is fixed; nothing below can be changed without rebuilding the libs:

| option | value | meaning for us |
|---|---|---|
| `CONFIG_BT_ENABLED`, `CONFIG_BT_CONTROLLER_ENABLED` | y | BLE controller is in `libbtdm_app.a` |
| `CONFIG_BT_NIMBLE_ENABLED` | y | NimBLE is the host; `CONFIG_BT_BLUEDROID_ENABLED` is **not set**, so Bluedroid is not an option |
| `CONFIG_BT_NIMBLE_ROLE_CENTRAL`, `_OBSERVER`, `_GATT_CLIENT` | y | scanning + connecting + GATT client (what a HID host needs) |
| `CONFIG_BT_NIMBLE_SECURITY_ENABLE`, `_SM_LEGACY`, `_SM_SC` | y | pairing with legacy and LE Secure Connections |
| `CONFIG_BT_NIMBLE_NVS_PERSIST` | y | bonds persist in NVS across reboots |
| `CONFIG_BT_NIMBLE_MAX_CONNECTIONS` / `_MAX_BONDS` | 3 / 3 | enough for one remote + one keyboard + one pad |
| `CONFIG_BT_NIMBLE_MEM_ALLOC_MODE_INTERNAL` | y | host allocations come from **internal** DRAM, never PSRAM |
| `CONFIG_BT_NIMBLE_PINNED_TO_CORE_0`, `CONFIG_BT_CTRL_PINNED_TO_CORE_0` | y | host and controller tasks run on core 0 |
| `CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE` | 5120 | host task stack |
| `CONFIG_BT_CTRL_BLE_MAX_ACT` | 6 | controller activities (828 B each per the Kconfig help) |
| `CONFIG_BT_NIMBLE_HID_SERVICE` | **not set** | see below: the IDF HID host component is compiled out |
| `CONFIG_ESP_COEX_ENABLED`, `CONFIG_ESP_COEX_SW_COEXIST_ENABLE` | y | Wi-Fi/BLE software coexistence is on |
| `CONFIG_ESP_WIFI_TASK_PINNED_TO_CORE_0`, `CONFIG_LWIP_TCPIP_TASK_AFFINITY_CPU0` | y | Wi-Fi and lwIP also run on core 0 |

### 2.1 The IDF `esp_hid` host component is not usable

`libesp_hid.a` is present and has `esp_hidh_init()`, but its NimBLE transport
object `nimble_hidh.c.obj` is 3,396 bytes: the whole file is wrapped in
`#if CONFIG_BT_NIMBLE_HID_SERVICE`, which is off in the Arduino `sdkconfig`.
`esp_hidh.c.obj` references `esp_ble_hidh_init`, `esp_ble_hidh_dev_open` and
`esp_ble_hidh_deinit` as undefined symbols, so calling `esp_hidh_init()` with
the BLE transport would fail to link. (It also contains no security call: the
IDF HID host leaves pairing to the application anyway.) The HID-over-GATT
client has to be written on the GATT client API.

### 2.2 Three ways to get a GATT client, two of them measured

| path | what it is | flash delta (a2p25, `BOARD_REV=225 DP_TEST=0`) |
|---|---|---|
| **raw esp-nimble host API** (`ble_gap_*`, `ble_gattc_*`, `ble_store_config`), plain C | what `usbhost.cpp` does for USB: no wrapper, full control of security and discovery order | **+178,840 B** (1,130,107 → 1,308,947) |
| Arduino core `BLE` library (`BLEDevice`/`BLEClient`/`BLESecurity`, NimBLE backend), C++ | bundled, `std::map`/`String` based; handles `ENC_CHANGE`, passkey events, `secureConnection()` | +229,520 B (→ 1,359,627) |
| h2zero NimBLE-Arduino (third-party library) | its own copy of the NimBLE host compiled from source | not measured: not installed, and it duplicates a host that is already in `libbt.a` |

Both measured variants link; the Arduino-library one fails the size check
against the `default` slot ("text section exceeds available space"), and the
raw one passes it by 1,773 bytes, which is no headroom at all (see §3).

Where the 178,840 bytes go (link-map diff, raw-NimBLE variant vs baseline):

| output section | baseline | with BLE | delta | main contributors |
|---|---|---|---|---|
| `.flash.text` | 822,067 | 963,420 | +141,353 | `libbt.a` (NimBLE host + glue) +72.5 KB, `libbtdm_app.a` (controller) +61.0 KB, `libbtbb.a` +3.1 KB, `libmbedcrypto.a` +2.4 KB (SC pairing), `ble_hid.c` +1.0 KB |
| `.flash.rodata` | 344,020 | 369,661 | +25,641 | controller +8.4 KB, host +8.4 KB, sketch strings +8.6 KB |
| `.iram0.text` | 79,751 | 97,867 | +18,116 | controller +17.0 KB (IRAM, separate budget: fine) |
| `.dram0.bss` + `.data` | 129,830 | 137,324 | +7,494 | host tables +6.1 KB, controller +1.2 KB |

`libcoexist.a` does not appear in the diff: the Wi-Fi driver already links it,
coexistence costs no extra flash.

**Recommendation: the raw esp-nimble API in C** (`ble_hid.c` next to
`usbhost.cpp`): 50 KB smaller than the Arduino library, no third-party
dependency, same style as the existing USB host code, and the security
initiation order that HOGP needs is explicit rather than hidden in a wrapper.

### 2.3 HID over GATT (HOGP) as a central, in NimBLE terms

1. Scan (active, so scan responses carry the device name): accept
   advertisements that list service UUID `0x1812` or an HID appearance
   (`0x03C0`–`0x03C4` generic HID / keyboard / mouse / joystick / gamepad,
   `0x0180` remote control; some remotes advertise only the appearance).
2. `ble_gap_connect()`, then **`ble_gap_security_initiate()` immediately**.
   HOGP requires an encrypted, bonded link (security mode 1 level 2 or 3);
   reading the Report Map before encryption returns ATT "insufficient
   authentication". Pair as Just Works: `sm_io_cap = NO_INPUT_OUTPUT`,
   `sm_bonding = 1`, `sm_sc = 1`, distribute ENC + ID keys both ways (the IRK
   is what lets the host resolve a remote that advertises with a resolvable
   private address on the next boot).
3. On `BLE_GAP_EVENT_ENC_CHANGE` (status 0): `ble_gattc_disc_svc_by_uuid`
   for `0x1812`, `ble_gattc_disc_all_chrs` in it, `ble_gattc_disc_all_dscs`
   per characteristic.
4. Read the **Report Map** (`0x2A4B`): a standard HID report descriptor, the
   same bytes `parse_consumer_layout()` in `usbhost.cpp` already parses.
5. For every **Report** (`0x2A4D`) read its **Report Reference** descriptor
   (`0x2908`: report ID + type); for input reports write `0x0001` to the CCCD
   (`0x2902`). Notifications arrive in `BLE_GAP_EVENT_NOTIFY_RX` keyed by
   characteristic handle, so the report ID comes from the Report Reference,
   not from a leading byte as on USB. **Boot Keyboard Input Report**
   (`0x2A22`) is the fallback if a keyboard exposes no report-mode keyboard
   report; leave **Protocol Mode** (`0x2A4E`) at Report mode (default).
6. `BLE_GAP_EVENT_REPEAT_PAIRING`: delete the stale bond and return
   `BLE_GAP_REPEAT_PAIRING_RETRY` (the user re-paired the remote elsewhere).
   `ENC_CHANGE` with `BLE_ERR_PINKEY_MISSING`: same, then require PAIR again.

Bond storage: `ble_store_config_init()` with `CONFIG_BT_NIMBLE_NVS_PERSIST=y`
writes peer/our security records and CCCDs to NVS (namespace `nimble_bond`).
The `nvs` partition is 20 KB (0x5000) in every 4 MB scheme and today holds
only the `a2fpga` namespace (`settings.c` blob, `wedge_watch.c` counters);
Wi-Fi config is kept in RAM (`WIFI_STORAGE_RAM`). Three bonds fit easily.

### 2.4 Coexistence and RAM

- Wi-Fi STA and BLE share the one 2.4 GHz radio by time division; Espressif
  rates "BLE + Wi-Fi STA connected/scan/connecting" as stable, and nothing
  has to be called: coexistence switches automatically (the only API is for
  BLE Mesh). `esp_wifi_set_ps(WIFI_PS_NONE)` in `wifi_bridge.c` stays.
- Espressif's advice to put the BT host/controller on one core and Wi-Fi on
  the other is **not available**: the precompiled config pins BT, Wi-Fi and
  lwIP all to core 0, where our `usbh_lib`/`usbh_work`/`usbh_cli` tasks also
  live (`disk`, `menu`, `ftpd`, `telnetd` are on core 1). Expect more core-0
  contention; the HID event rate is tiny, the cost is the scan phase.
- RAM is the real unknown. Static DRAM grows by 7.5 KB (measured). Dynamic:
  Espressif publishes no total; the controller takes 6 × 828 B for its
  activity table plus its own buffers, the NimBLE host preallocates msys
  pools (12 × 256 + 24 × 320 = 10.8 KB) and ACL buffers (24 × 255 = 6.1 KB),
  plus a 5 KB host task stack. Community measurements of NimBLE + controller
  on an ESP32-C3 under IDF 5.5 land around 66 KB of heap; the classic ESP32
  with defaults was reported at 88 KB. Plan for **50–70 KB of internal heap**,
  and it cannot go to PSRAM (`MEM_ALLOC_MODE_INTERNAL` is fixed).
  **Gate 0 is a `meminfo` reading on the running card** (ESP32 console)
  before and after `ble_hid_start()`; the firmware must keep enough internal
  heap for lwIP, the USB transfers and FatFS after that.

## 3. Flash budget and the partition change

Measured on 2026-11-18 (arduino-cli 1.2.2, esp32 core 3.3.5, clean build
dirs; `.bin` = sketch + 149–153 bytes of image trailer):

| build | sketch bytes | `default` slot 1,310,720 | `min_spiffs` slot 1,966,080 | `no_fs` slot 2,031,616 |
|---|---|---|---|---|
| a2p25 baseline (`BOARD_REV=225 DP_TEST=0`), `.bin` sha256 `940028bc…adb07` | 1,130,107 | 86.2 % | 57.5 % | 55.6 % |
| a2mega baseline (`BOARD_REV=103`) | 1,136,951 | 86.7 % | 57.8 % | 56.0 % |
| a2p25 + raw NimBLE HOGP probe | 1,308,947 | 99.9 % (1,773 B spare) | **66.6 %** | 64.4 % |
| a2p25 + Arduino BLE library probe | 1,359,627 | 103.7 % (does not fit) | 69.2 % | 66.9 % |

Trimming 180 KB out of the current firmware instead is not realistic: the big
consumers are the Wi-Fi driver, lwIP, the USB host stack, FatFS and the OSD
code, all in use.

### 3.1 Partition schemes (Arduino `tools/partitions/*.csv`, 4 MB)

| scheme | nvs | otadata | app0 | app1 | spiffs | coredump |
|---|---|---|---|---|---|---|
| `default` (today) | 0x9000 / 20 KB | 0xE000 / 8 KB | 0x10000 / 1,310,720 | 0x150000 / 1,310,720 | 0x290000 / 1,441,792 | 0x3F0000 / 64 KB |
| **`min_spiffs`** (decided) | same | same | 0x10000 / 1,966,080 | 0x1F0000 / 1,966,080 | 0x3D0000 / 131,072 | same |
| `no_fs` | same | same | 0x10000 / 2,031,616 | 0x200000 / 2,031,616 | none | same |

`nvs`, `otadata` and `coredump` are at the same offsets and sizes in all
three, so **settings, wedge-watch counters and (later) BLE bonds survive the
change**, and `CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH` keeps its partition.

What lives in `spiffs` today: the LittleFS "local volume" that `mount_sd()`
in the sketch mounts at `/sdcard` when no USB stick is present (both boards
have `A2MEGA_HAS_SD` off). With `min_spiffs` it shrinks to 128 KB: still
mountable, but it cannot hold a 140 KB `.dsk` or an FTP'd firmware `.bin`
(1.3 MB). **Decision: the USB stick is assumed present**, so the stick is the
file store for disk images and for FTP + FIRMWARE-menu OTA, and the 128 KB
LittleFS is only what keeps the stickless boot path from failing. Both cards
already boot from the stick (a2mega dock gate 2026-11-02, a2p25 stick path).
`min_spiffs` is chosen over `no_fs` because `LittleFS.begin(..., "spiffs")`
keeps working unchanged; `no_fs` would need a code path for "no local volume
at all" and buys only 64 KB more per slot.

### 3.2 Migration (one-time, per card)

OTA (`fwupdate.c`: `esp_ota_begin/write/end` into
`esp_ota_get_next_update_partition()`) rewrites only an app slot; the
partition table at 0x8000 can only be changed over USB. `make upload` flashes
exactly that set: bootloader @0x0, `partitions.bin` @0x8000, `boot_app0.bin`
@0xE000, app @0x10000 (platform.txt `flash_args`).

1. Change the FQBN in the `Makefile` for `BOARD_REV=225` **and** `103` to
   `PartitionScheme=min_spiffs` (the a2mega build is at the same 86 %).
2. With the Apple II off, put the ESP32 in download mode (hold S2/BOOT, tap
   S1/EN; the Apple II is held in reset meanwhile, see
   [ESP32_FW_A2P25.md](../../a2p25/docs/ESP32_FW_A2P25.md)) and
   `make upload BOARD_REV=225 DP_TEST=0` (resp. `BOARD_REV=103`) over the
   module's USB-C. `boot_app0.bin` resets `otadata` so the card boots `app0`.
3. Verify: `fwupdate_running_slot()` on the FIRMWARE screen says `app0`;
   `meminfo`; settings still present (SETTINGS SOURCE = SAVED).
4. From then on OTA via FTP + the FIRMWARE menu works as before with a
   1,966,080-byte slot. `do_check()` compares the file against the *actual*
   target partition size, so a card that was **not** migrated refuses a BLE
   build with "FILE LARGER THAN OTA SLOT" instead of bricking; conversely an
   image compiled with the `min_spiffs` FQBN that still fits 1.25 MB installs
   fine on an old table (app images do not embed the partition table), so
   the Makefile change can land before the cards are reflashed.

## 4. Device classes and how their reports map

The ESP32-S3 has **no Bluetooth Classic (BR/EDR)**. That rules out every
device that only speaks classic HID, and per Bluepad32's compatibility table
that includes **all listed 8BitDo models** (Ultimate, SN30 Pro, Pro 2, Lite,
Lite 2, M30, Arcade Stick, Zero 2, NES30: BR/EDR in every mode), the Wii
remote and the 1st-gen Fire TV remote. So "8BitDo-style" is not a BLE
category; check a specific model's spec sheet for "Bluetooth LE / HOGP"
before counting on it.

| class | protocol | typical report | maps onto |
|---|---|---|---|
| **BLE TV remotes / air-mouse remotes without dongle** (Android TV / Google TV remotes, newer Fire TV remotes, generic "BLE 5.0 remote for TV box") | HOGP, usually a keyboard report + a consumer-control report (+ mouse) | boot-layout keyboard `[mods, res, k1..k6]` with a report ID; consumer page as a usage array or a bitmap | **existing** `map_kbd_usage()` and `map_consumer_usage()` + `parse_consumer_layout()` in `usbhost.cpp`, unchanged: arrows/OK/Back/Home/Menu → A2PAD_U/D/L/R/A/B/SELECT exactly as the USB dongle today |
| **BLE keyboards** (Logitech K380-class, most "Bluetooth keyboard" products) | HOGP, report mode (boot keyboard as fallback) | 8-byte keyboard report; some NKRO bitmaps | `map_kbd_usage()`; NKRO bitmap needs a small Report-Map-driven variant |
| **BLE gamepads** | HOGP: Xbox Wireless model 1708 fw ≥5.15, model 1914, Xbox Adaptive; Stadia (after its BT firmware update); Steam Controller (BT firmware); generic Android BLE pads. **Not HOGP:** Switch 2 Pro / Joy-Con 2 (Nintendo vendor GATT service) | Generic Desktop gamepad report: X/Y/Z/Rz axes, Hat Switch (usage `0x39`), Button-page bits; Xbox also sends the Xbox button on a separate consumer report (`0x223`) | **new** generic gamepad parser: hat and left stick → U/D/L/R, buttons 1–4 → A/B/X/Y, the two centre buttons → SELECT/START. `xinput_to_a2pad()` does not apply (XInput is a USB vendor protocol) |

Integration points that already exist:

- `menu_tick()` ORs `usbhost_buttons()` into the FPGA pad word; a third
  `ble_hid_buttons()` term is the whole change there (the throwaway variants
  did exactly this).
- The STATUS screen line `GAMEPAD` / `USB PORT` gets a `BLUETOOTH` line
  (`BLE REMOTE <name>` / `NONE`).
- Hoist `map_kbd_usage`, `map_consumer_usage`, `parse_consumer_layout` and
  the boot-keyboard decode out of `usbhost.cpp` into a `hid_map.c/.h` used by
  both the USB and the BLE path, and add the gamepad-page parser there.

## 5. Pairing without text input

Menu additions on the SETTINGS screen (`settings_build()`), same patterns
as the FPGA/firmware update items (`MI_ACTION` + an `MI_INFO` status line
polled every tick, like `fwupdate_message()`):

```
BLUETOOTH DEVICE        <name> | NONE
PAIR BLUETOOTH DEVICE          (action)
FORGET BLUETOOTH DEVICE        (action, only when one is stored)
```

PAIR: active scan for ~10 s, accept the first advertiser with service
`0x1812` or an HID/remote appearance, status line `SCANNING...` →
`FOUND <name>, PAIRING...` → `PAIRED <name>` or `NO HID DEVICE FOUND`. The
user puts the remote in pairing mode first (its own button combo), as with a
TV. Just Works needs no digits. Keyboards that insist on authenticated
pairing (MITM) can be handled in a later phase with `io_cap = DISPLAY_ONLY`:
the ESP32 shows a 6-digit passkey on the OSD and the user types it on the
keyboard; the OSD is a display, so Passkey Entry is available without any
text input on our side.

FORGET: `ble_store_util_delete_peer()` + clear the stored peer record.

Peer record: store `{addr_type, addr[6], name[20]}` in its own NVS namespace
(`blehid`, like `wedge_watch.c` uses `a2fpga`) rather than in the settings
blob, so `SETTINGS_VERSION` does not bump (a version bump resets the whole
blob, Wi-Fi credentials included).

Reconnect on boot: if a peer record exists, run a **low-duty passive scan**
(interval 1.28 s, window 30 ms: cheap for Wi-Fi coexistence) and connect
when that address (or its resolved RPA, via the bonded IRK) is seen; HID
devices advertise when a key is pressed, so the first press after power-up
wakes the link. `ble_gap_security_initiate()` then re-encrypts with the
stored LTK with no user interaction, and the HOGP subscription is redone
(CCCDs are also restored from the bond store). Stop scanning while
connected; without a peer record do not scan at all (PAIR starts it).

## 6. Latency, throughput, risks

- **Menu latency:** HID peripherals ask for 7.5–15 ms connection intervals
  and wake on input, so key-to-notification is one interval; the menu polls
  at 50 Hz (20 ms). The USB dongle path is no faster. Hold-to-repeat works
  as today because report-mode devices send a release report.
- **Wi-Fi throughput for the Uthernet II bridge:** one BLE connection at a
  15 ms interval takes a ~2 ms slice per event; Espressif does not quantify
  the loss. The expensive phase is active scanning (PAIR, 10 s) and the
  reconnect scan, hence the low duty above. Measure with the existing
  bridge throughput checks before/after, with a remote connected and during
  a PAIR scan.
- **Heap:** the main risk (§2.4). Gate 0 = `meminfo` before/after BLE init;
  if internal heap drops below what lwIP + USB need under load, the fallback
  is to trim elsewhere (the Wi-Fi RX/TX buffer counts are fixed in the
  precompiled config, so trimming has to come from our own tasks and
  buffers) or to make BLE opt-in from the menu (controller only enabled when
  a peer is stored or PAIR is pressed).
- **Core-0 contention:** BT host + controller + Wi-Fi + lwIP + usbh tasks all
  on core 0. Watch the USB MSC throughput (disk-image serving) while a pad
  streams reports at 125 Hz.
- **Device variance:** report layouts differ per remote; the Report-Map
  driven parser handles the common cases, odd remotes need a per-device
  fix-up table (by name/appearance) the way USB remotes did.
- **Antenna:** same module antenna, same band and placement as the Wi-Fi
  that already works from inside the Apple II case.
- **Security:** Just Works gives encryption without MITM protection; fine for
  a remote/pad, and the passkey-on-OSD option exists for keyboards.
- **No change to the USB path:** the USB dongle keeps working when the stick
  or Ethernet adapter is absent; both sources OR into one button word.

## 7. Plan and effort

| phase | work | effort |
|---|---|---|
| 0. Partition migration + heap baseline | Makefile → `min_spiffs` for 225 and 103; doc the step in `ESP32_FW_A2P25.md`; one-time USB `make upload` of both cards (Apple II off); verify settings kept and FTP + FIRMWARE OTA still works from the stick; record `meminfo` | ½ day + the two reflashes |
| 1. HOGP core | `ble_hid.c/.h` on raw esp-nimble: init, Just Works bonding, scan filter, connect → security → discovery → Report Map + Report Reference → CCCD subscribe, NOTIFY_RX decode; `hid_map.c` hoisted from `usbhost.cpp`; `ble_hid_buttons()` into `menu_tick()`; SETTINGS PAIR/FORGET + status; NVS peer record; reconnect scan; telnet `ble status|scan|bonds|forget` for diagnostics; test with one BLE remote and one BLE keyboard; `meminfo` after init | 3 days |
| 2. Pads + polish | Generic gamepad-page parser (Xbox BLE as the reference device), passkey-on-OSD for MITM keyboards, repeat-pairing/key-missing recovery, Wi-Fi bridge throughput check with BLE connected and during PAIR, heap soak with stick + Ethernet + BLE all active | 2 days |
| 3. Later | a2n20v2-Enhanced: the BL616 has its own BLE 5.3 radio, same design applies on a different SDK (not part of this estimate) | — |

Roughly one to one-and-a-half weeks including hardware testing, with the
partition migration as the only step that needs a USB cable at each card.

## Appendix: how the numbers were measured

- Baselines: `make compile BOARD_REV=225 DP_TEST=0` and `make compile
  BOARD_REV=103` from clean `build/` directories in a copy of
  `boards/a2mega/src/a2fpga_esp32/` at commit `c48649e3`.
- Throwaway variants (not committed; recreate if needed): a copy of the same
  folder plus `ble_hid.h` (`ble_hid_start()`, `ble_hid_buttons()`), one line
  `ble_hid_start();` after `usbhost_start();` in the sketch, and
  `| ble_hid_buttons()` in `menu_tick()`. Variant "raw": `ble_hid.c` (~150
  lines) with `nimble_port_init`, `ble_hs_cfg` set for Just Works bonding,
  `ble_store_config_init`, `nimble_port_freertos_init`, a `ble_gap_disc`
  filter on UUID `0x1812`, `ble_gap_connect`, `ble_gap_security_initiate` on
  connect, `ble_gattc_disc_svc_by_uuid` + `ble_gattc_disc_all_chrs`, CCCD
  write, Report Map read, `NOTIFY_RX` decode with the two usage maps.
  Variant "arduino": `ble_hid.cpp` doing the same with `BLEDevice`,
  `BLEScan`, `BLEClient`, `BLESecurity`, `Preferences`. The raw variant was
  built with `PartitionScheme=min_spiffs` to confirm the FQBN works; the
  sketch-size numbers do not depend on the scheme.
- Section breakdown: diff of the two `a2fpga_esp32.ino.map` files, summing
  input sections per archive for `.flash.text`, `.flash.rodata`,
  `.iram0.text`, `.dram0.*`.
- `esp_hid` finding: `xtensa-esp32s3-elf-ar t libesp_hid.a` lists
  `nimble_hidh.c.obj`; extracted, it is 3,396 bytes with no `T` symbols,
  while `esp_hidh.c.obj` has `U esp_ble_hidh_init`. The guard is visible in
  `components/esp_hid/src/nimble_hidh.c` of ESP-IDF v5.5.

Sources: ESP-IDF v5.5 `components/bt/controller/esp32c3/Kconfig.in` and
`components/bt/host/nimble/Kconfig.in` (memory help texts, defaults); ESP-IDF
v5.5 ESP32-S3 "RF Coexistence" guide (stability table, core-pinning advice,
no throughput numbers); Bluepad32 "Supported gamepads" (BLE vs BR/EDR per
controller, 8BitDo = BR/EDR, Xbox fw ≥5.15 = BLE); Bluetooth SIG HOGP
(bonding requirement); arduino-esp32 3.3.5 `libraries/BLE/src` (NimBLE
backend behaviour); the Arduino core's `tools/partitions/*.csv` and
`boards.txt` (slot sizes).
