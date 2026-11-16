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
empty line returns to key mode. Commands:

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
# line mode: one register read, back to keys, disconnect
(printf ':'; sleep 1; printf 'spireg 0x75\r\n'; sleep 1; printf '\r\n'; sleep 1; printf 'q') | nc -w 8 192.168.x.y 23
```

Never pipe a file or a multi-line heredoc into port 23 without the leading `:`.

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
- Port 2323: `tools/fpga_stream.py <ip> <image.bin>` streams a Gowin `.bin` into
  the FPGA's SRAM through the ESP32 JTAG bridge (volatile; `g` or a
  power-cycle returns to the flash image). The Mac's USB JTAG must be
  detached while streaming. Full notes:
  [bringup_1_0a3_log.md](bringup_1_0a3_log.md).

## What the registers can and cannot show (a2p25, 2026-11-16)

Readable over `z` / `viddbg`: video mode, FB flags, shadow drops, VGC
hsync misses and stale swaps, DOC fetch timeouts, DOC max fetch latency,
and the per-frame DOC request / memory-read / late counts.

**Not readable** on the current a2p25 core: the GLU sound-RAM write-queue
drop counter and the DOC fetch-drop counter. Both only feed the on-screen
`DebugOverlay`, and `A2_INSTR_DEBUG_OVERLAY` is 0 in
[`a2p25_profile.vh`](../../a2p25/hdl/a2p25_profile.vh). Exposing them means
adding two connector debug registers (0x7F is free; 0x76 is hard-wired zero
on the a2p25) and a rebuild. See
[../../a2p25/docs/RESOURCE_AUDIT.md](../../a2p25/docs/RESOURCE_AUDIT.md) §8.4.

## Related

- [ESP32_ENHANCED_PORT.md](ESP32_ENHANCED_PORT.md): the OSPI register map
  the `spireg` numbers refer to.
- [ESP32_OSPI_DESIGN.md](ESP32_OSPI_DESIGN.md): the link itself.
- [../../a2p25/docs/ESP32_FW_A2P25.md](../../a2p25/docs/ESP32_FW_A2P25.md):
  building and flashing the firmware for the a2p25.
- [jtag_flash_reliability.md](jtag_flash_reliability.md): why `g` and
  `reconfig` are bench tools, not features.
