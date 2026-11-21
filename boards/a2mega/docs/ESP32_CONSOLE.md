# ESP32 consoles: serial CLI, telnet, FTP, bitstream port

Status (2026-11-16): documents the shared a2mega/a2p25 ESP32-S3 firmware in
[`src/a2fpga_esp32/`](../src/a2fpga_esp32/). Written after a scripted
`help` / `spireg …` paste into the telnet console was read as single
keystrokes and reloaded the FPGA four times under a running game. **Read the
telnet section before sending anything to port 23.**

The firmware exposes four network/serial surfaces:

| Surface | Where | Input model | Source |
|---|---|---|---|
| Serial CLI | USB1 (ESP32's own USB-C), CDC | **line** commands after `+++` | `a2fpga_esp32.ino` |
| Telnet console | TCP port 23 | **single keystrokes**; `:` opens a line mode | `telnetd.c` |
| FTP | TCP port 21 | standard | `ftpd.c` |
| Bitstream stream | TCP port 2323 | raw `.fs` bytes from `tools/fpga_stream.py` | `fpga_stream.c` |

Find the card's IP from the OSD console log, the serial CLI's `net`, or the
on-screen menu.

## Telnet console (port 23): a key-driven console

Connecting prints the current OSD console log (the "tee") and then forwards
every new log line. Since 2026-11-18 the tee also carries every **ESP-IDF
error-level log line** (`idf_log_tee.c`: `E (ts) TAG: msg` → `TAG: MSG`, in
40-column pieces), so `usb_host` failures such as `HCD DWC: NO MORE HCD
CHANNELS AVAILABLE` or `ENUM: STAGE ... FAILED` are readable here; the serial
console is USB1, the host port, and is unreachable whenever a dock is attached.
The same tee feeds one hook: `EXT_PORT: [h:p] Port disabled` starts the
hub-port power-cycle retry in `usbhost.cpp` (`USB HOST: HUB h PORT p ENUM
FAILED, POWER CYCLING PORT (TRY n/3)` ... `RECOVERED` or `FAILED TO
ENUMERATE, PLUG THE STICK DIRECTLY`; a2p25 ESP32_FEATURE_PORT.md P3). **Every byte you type is a hotkey**, dispatched
immediately, no Enter needed. There is no `help` command in key mode; the
banner lists the keys:

```
keys: c=console m=menu p=pd d=census x=regs z=viddbg e=eq +/-=eqstep l=lanes
      v=replug f=flip r=retrain g=fpgareload u=fusb t=trace i=i2cscan n=dp130
      :=cmdline q=quit
```

### Read-only keys (safe at any time)

| Key | Prints |
|---|---|
| `p` | USB-C PD / DP Alt Mode status (CC orientation, HPD, SRC/DFP, mux enable) |
| `d` | Adapter lane census: pin-assignment decode of the last Discover Modes ACK |
| `x` | TUSB1046 mux register dump (the AUX snooper view) |
| `z` | **Video/DOC debug block**: FPGA regs 0x70–0x78 plus the indexed DOC window. Serviced by the main loop, so the printout follows a moment later. Output: `VIDDBG MODE/FB/OVFL/RD`, on the a2p25 `DOC TIMEOUTS … LATMAX …` and `DOC/FRAME REQ … MEMRD … LATE …`, then `VGC HSYNC … STALE …  SHADOW DROPS …` |
| `u` | Raw FUSB302B status snapshot |
| `t` | PD event trace |
| `i` | Responders on the DP I2C bus (mux, PD PHY, DP130) |
| `n` | SN75DP130 register dump (a2p25 only) |
| `q` | Disconnect |

### Keys that change the running board

| Key | Effect | Recovery |
|---|---|---|
| `g` | **Reconfigure the FPGA from flash.** 2–3 s dark, the Apple II loses the card mid-cycle (in practice a reset). Bench tooling only. | power-cycle to be sure of a clean state |
| `r` | HPD pulse: restarts the DP training ladder. Display drops and re-trains. | self-recovers |
| `e` | Cycle the mux DP receiver EQ preset | `v` or power-cycle restores the ladder's choice |
| `+` `-` | Step the mux EQ one of 16 settings | as above |
| `l` | Toggle the unused mux DP2/DP3 inputs on/off (thermal A/B) | press again |
| `f` | Flip the mux FLIPSEL orientation live | press again |
| `v` | Virtual replug: CC-open detach and reattach | self-recovers |
| `w` | Toggle the wedge auto-recovery watch, and print its status | press again |
| `m` | Enter **menu mode**: the on-screen MCU menu is mirrored and arrows, Enter/`a`, Esc/Backspace/`b`, `y`, `s`/Tab are injected as gamepad buttons into the running board. `c` returns to the console view. | `c` |

### Line mode (`:`)

Typing `:` opens a prompt; **only in this mode is input line-oriented.** An
empty line **or ESC** returns to key mode. **Terminate each command with a
single `\r` (or a single `\n`), never `\r\n`:** the parser executes the line
on the `\r` and then sees the `\n` as an *empty line*, which leaves line mode,
so everything after it is dispatched as hotkeys (2026-11-16, second incident:
a `spireg …\r\n` loop became `p i r e g` = PD dump, I2C scan, retrain, EQ
step, **FPGA reload**, repeated). Commands:

```
spireg <reg 0..126> [val]    read or write an FPGA OSPI register (hex ok: 0x75)
gs | gs set <idx> <val> | gs arm|listen|off|auto|mode <0-3>|hold <ms>
   |autotrig on|off|clear|freeze|run|trig|untrig | gs trace | gs events|evclear
                             IIgs CPU-socket module (a2mega 138B only)
ble [pair|cancel|list|connect <n>|forget|radio on|off|map|raw on|off]
                             Bluetooth HID device (ble_hid.c): status, start
                             the 60 s pairing scan, list what it found, connect
                             to entry n (-1/none = strongest), drop the bond;
                             `radio off` keeps the BLE host from starting at
                             the next boot (`radio on` starts it at once).
                             `map` dumps the parsed report map (fields + input
                             characteristics); `raw on` logs every input report
                             as `RX<rid> <bytes> ><bits>` (pointer reports only
                             when their decoded bits change) — the way to find
                             out what a new remote's keys send.
                             Works without the FPGA link (2026-11-19).
usb [retry on|off]           every device the USB host has enumerated on USB1
                             (with `retry on|off`: first set USB HUB PORT RETRY =
                             ALL PORTS (default) / PER-PORT, the SETTINGS toggle,
                             and save; also prints storage read/write failure
                             totals and the last failure's SCSI stage/CSW/sense)
usb probe <lba> [read]       storage sector test at <lba>: READ(10) of one
                             sector with its time; then, unless `read` is given
                             and only if the sector is all zeros, a WRITE(10) of
                             the same zeros and a read-back (PASS/FAIL). A failed
                             step names the SCSI stage, CSW status and sense.
                             For bisecting a stick that fails above some address
                             (2026-11-20, the 64 GB PNY). Non-zero sectors are
                             refused for writing.
                             (address, VID:PID, kind, speed, product string,
                             [in use] when this firmware claimed it); hubs and
                             unclaimed devices included. Device mode = nothing.
meminfo                      internal and PSRAM heap: free, largest block,
                             minimum ever (internal). The BLE host costs ~79 KB
                             internal; watch this after plugging things in.
```

Anything else in key mode is dispatched as hotkeys: a pasted `spireg 0x75`
is **s p i r e g** = select, PD status, I2C scan, retrain, EQ cycle, **FPGA
reload**. The only safe way to script the console is to send `:` first and
one command per line, or to use the serial CLI instead.

### Scripting from a shell

```bash
# read-only: DOC/video counters, then disconnect
(printf 'z'; sleep 3; printf 'q') | nc -w 5 192.168.x.y 23
```

```bash
# line mode: one register read, ESC back to keys, disconnect. Single \r per command.
(printf ':'; sleep 1; printf 'spireg 0x75\r'; sleep 1; printf '\033'; sleep 1; printf 'q') | nc -w 8 192.168.x.y 23
```

```bash
# several commands: stay in line mode the whole time, leave with ESC
(printf ':'; sleep 1; for i in 0 1 2; do printf 'spireg 0x7E %d\r' $i; sleep 0.5; printf 'spireg 0x7E\r'; sleep 0.5; done; printf '\033'; sleep 1; printf 'q') | nc -w 20 192.168.x.y 23
```

Never pipe a file or a multi-line heredoc into port 23 without the leading `:`,
and never use `\r\n` line endings (`printf`, not `echo`; no heredocs, whose
lines end in `\n` after a `\r` would).

## Serial CLI (USB1, `+++`)

The ESP32's own USB-C port enumerates as a CDC serial device. By default it
forwards the FPGA's serial stream; type `+++` to enter the CLI and `exit` to
leave it. Line commands, from `help`:

| Command | Purpose |
|---|---|
| `status` | system status |
| `spiinit`, `spitest` | bring up the OSPI link, loopback test |
| `spireg <reg> [val]` | read or write FPGA register 0..126 |
| `viddbg` | the same 0x70–0x77 debug block as telnet `z` |
| `spir <space> <addr> <len> [inc]`, `spiw <space> <addr> <inc> <b0> …` | raw OSPI space read/write |
| `meminfo`, `pins` | ESP32 heap, pin map |
| `wifi [<ssid> [psk]]`, `net` | WiFi credentials in NVS; `net` = Uthernet uplink (WiFi / USB-Ethernet), adapter state, IP status |
| `ble [pair\|cancel\|list\|connect <n>\|forget\|radio on\|off\|map\|raw on\|off]` | Bluetooth HID remote/keyboard/gamepad: status, pairing scan, candidates, connect, forget, radio on/off; `map` = parsed report map, `raw on` = log every input report with its decoded bits (2026-11-19) |
| `usb` | enumerated USB devices on USB1 (host mode only; in device mode the Mac is on that port, so there is nothing to list) |
| `pd`, `i2cscan` | PD status, DP I2C scan (PD boards) |
| `dp130 r <reg> [n] \| w <reg> <val> \| probe` | SN75DP130 registers (a2p25) |
| `a2reset` | pulse the Apple II /RES line 200 ms (boards with the reset pin) |
| `reconfig` | pulse FPGA RECONFIG_N: reload from flash (a2p25, rev 225) |
| `fwupdate [<file>\|go\|cancel]` | ESP32 self-update from a `.bin` on the volume (a2p25) |
| `restart` | reboot the ESP32 (asserts Apple II /RES while down) |

## FTP (port 21) and the bitstream port (2323)

- FTP: disk images and `wifi.txt` go to the ESP32's filesystem (a2mega) or
  the mounted USB stick (a2p25 with USB host). Any USER/PASS is accepted (LAN threat
  model).
- Port 2323: `tools/fpga_stream.py <ip> <image.bin>` writes a Gowin `.bin`
  into the FPGA's **config flash** through the ESP32's SPI-over-JTAG driver
  (erase, write, page verify, then FPGA reload and ESP32 restart; ~100 s for
  the a2p25's 0.9 MB image). The image **persists** across power cycles: a
  power-cycle after a stream boots the streamed image, not the previous one.
  The Mac's USB JTAG must be detached while streaming. Full notes:
  [bringup_1_0a3_log.md](bringup_1_0a3_log.md).

## What the registers can and cannot show (a2p25, 2026-11-16)

Readable over `z` / `viddbg`: video mode, FB flags, shadow drops, VGC
hsync misses and stale swaps, DOC fetch timeouts, DOC max fetch latency,
and the per-frame DOC request / memory-read / late counts.

The indexed debug window (select register 0x5F, data register 0x4F) holds
the DOC telemetry; `z` reads it for you, or by hand in `:` mode:

| Index | Value |
|---|---|
| 40, 41 | DOC wavetable requests last frame, lo/hi |
| 42, 43 | DOC memory reads (cache misses) last frame, lo/hi |
| 44, 45 | DOC fetches past the slot deadline last frame, lo/hi |
| 46 | **GLU sound-RAM write-queue drops**, sticky. Nonzero = wavetable bytes lost on the way into memory: the DOC then plays wrong-but-plausible samples (distortion, pops) with every DOC-side counter clean |
| 47 | DOC fetch requests dropped, FIFO full, sticky. Design invariant: 0 |
| 48, 49 | **Audio CDC: mixed captures** on the raw sample path, any pixel-clock cycle, lo/hi, saturating. A clean sample lasts 18.5 ns and is captured ≥ 2 times by the 148.5 MHz pixel clock; a captured word that lasts one cycle is a mix of old and new bits |
| 50, 51 | Audio CDC: mixed captures that landed on the 48 kHz strobe = **pops the raw path produced** (or would have, with the mailbox path selected), lo/hi |
| 52, 53 | Audio CDC: consumed samples whose step vs the previous sample exceeded 2048 on L or R, on the path actually feeding the DP (symptom counter), lo/hi |
| 54 | Audio CDC: largest consumed step, high byte |
| 55 | Audio control read-back: bit 0 = mailbox path selected (a2p25 from the 2026-11-18 filter build: mailbox always, bit 0 read back but ignored, 48-51 read 0), bit 1 = counters held clear, bits 3:2 = Mockingboard gain select (shift 3 + value; power-up 2 = << 5). **Writing** this index sets the control byte (see below) |

```
: spireg 0x5F 46
: spireg 0x4F
```

Indices 46 and 47 exist from the 2026-11-16 build onward (cores before it
return 0 there); 48–55 from the audio-CDC instrument build of the same day.

**Audio CDC control (a2p25; a2mega once its top is rebuilt from 2026-11-16 source): a WRITE to window index 55.** Bit 0 = 1 feeds
the DP with the request/acknowledge mailbox word instead of the raw
double-flop word; bit 1 = 1 holds counters 48–54 at zero (pulse it to clear).
**Power-up value is 0x09 (mailbox, Mockingboard gain 2 = << 5) from the 2026-11-17 mixer build (0x01 on the 11-16 build);** bits 3:2 pick the Mockingboard level live: write 0x01 / 0x05 / 0x09 / 0x0D for << 3 / << 4 / << 5 / << 6 (keep bit 0 set). **From the 2026-11-18 firmware the ESP32 owns this byte:** SETTINGS → MOCKINGBOARD VOLUME (LOW/MEDIUM/HIGH/MAX = << 3..6, default MAX = << 6 after the ear pick) is written at boot with the slot map and live on change (`audio_ctl.c`), so a hand write here lasts until the next ESP32 boot; a telnet `g` reload without an ESP32 restart leaves the core at its power-up << 5 until then. the
instrument build of the same morning powered up on the raw path (0x00). Write 0
only to reproduce the pops for measurement.
Live, no reload. Not a scratch register: `w5100.c` rewrites scratch1–4
(regs 0x0C–0x0F) with bridge telemetry on every poll, which silently undid the
first version of this switch (2026-11-16).

```
: spireg 0x5F 55
: spireg 0x4F 1      mailbox path on, counters running
: spireg 0x4F 3      ... and clear the counters
: spireg 0x4F 1      release the clear
: spireg 0x4F 0      raw path (the pre-2026-11-16 behaviour; pops)
: spireg 0x4F        readback = {clear, sel_safe} as the module sees them
``` Until then they only fed the on-screen `DebugOverlay`, which
`A2_INSTR_DEBUG_OVERLAY` compiles out on the a2p25.

## Related

- [ESP32_ENHANCED_PORT.md](ESP32_ENHANCED_PORT.md): the OSPI register map
  the `spireg` numbers refer to.
- [ESP32_OSPI_DESIGN.md](ESP32_OSPI_DESIGN.md): the link itself.
- [../../a2p25/docs/ESP32_FW_A2P25.md](../../a2p25/docs/ESP32_FW_A2P25.md):
  building and flashing the firmware for the a2p25.
- [jtag_flash_reliability.md](jtag_flash_reliability.md): why `g` and
  `reconfig` are bench tools, not features.
