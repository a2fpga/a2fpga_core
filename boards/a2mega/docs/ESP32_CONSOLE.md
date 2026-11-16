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
every new log line. **Every byte you type is a hotkey**, dispatched
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
| `wifi [<ssid> [psk]]`, `net` | WiFi credentials in NVS, IP status |
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

```
: spireg 0x5F 46
: spireg 0x4F
```

Indices 46 and 47 exist from the 2026-11-16 build onward (cores before it
return 0 there). Until then they only fed the on-screen `DebugOverlay`, which
`A2_INSTR_DEBUG_OVERLAY` compiles out on the a2p25.

## Related

- [ESP32_ENHANCED_PORT.md](ESP32_ENHANCED_PORT.md): the OSPI register map
  the `spireg` numbers refer to.
- [ESP32_OSPI_DESIGN.md](ESP32_OSPI_DESIGN.md): the link itself.
- [../../a2p25/docs/ESP32_FW_A2P25.md](../../a2p25/docs/ESP32_FW_A2P25.md):
  building and flashing the firmware for the a2p25.
- [jtag_flash_reliability.md](jtag_flash_reliability.md): why `g` and
  `reconfig` are bench tools, not features.
