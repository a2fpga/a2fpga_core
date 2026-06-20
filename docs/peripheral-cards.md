# Peripheral Card Emulation

The catalog of virtual Apple II cards the core provides — what each emulates, the upstream cores it
reuses, and where the HDL lives. How cards attach to the bus and how to add one is in
[bus-interface.md](bus-interface.md); the sound mixing is in [audio.md](audio.md). This page is the
per-card reference.

Each card is a slave on [`a2bus_if`](../hdl/bus/a2bus_if.sv) + [`slot_if`](../hdl/slots/slot_if.sv)
with an 8-bit card **ID**, assigned to a slot by [`slots.hex`](../hdl/slots/slots.hex) (and
reconfigurable at runtime by the coprocessor). Default assignment:

| Card | ID | Default slot | Emulates |
|---|---|---|---|
| SuperSprite | 1 | 7 | Synetix SuperSprite (TMS9918A VDP + AY-3-8910) |
| Mockingboard | 2 | 4 | Sweet Micro Systems Mockingboard (2× AY-3-8910 + 2× 6522) |
| Super Serial Card | 3 | 2 | Apple Super Serial Card (6551 ACIA) |
| Disk II | 4 | 5 | Apple Disk II controller (RAMDISK) — **not currently built, see below** |
| Uthernet II | 5 | 3 | a2RetroSystems Uthernet II (WIZnet W5100) — a2n20v2-Enhanced only; FPGA front-end + BL616 MACRAW bridge, see [boards/a2n20v2-Enhanced/docs/UTHERNET2.md](../boards/a2n20v2-Enhanced/docs/UTHERNET2.md) |

## SuperSprite — [`supersprite.sv`](../hdl/supersprite/supersprite.sv)

Emulates the Synetix SuperSprite: a **TMS9918A VDP** plus an **AY-3-8910** PSG (the original's
TMS5220 speech synth is not implemented). The VDP is the **F18A** core ([`hdl/f18a/`](../hdl/f18a/),
`f18a.sv` + the VHDL core), a TMS9918A-compatible implementation. The PSG is the shared
[`YM2149`](../hdl/support/YM2149.sv) core; its three channels sum to a 10-bit mono output that feeds
the [audio mix](audio.md).

The card composites its VDP output **over** the Apple video: it takes the Apple RGB in and emits
`ssp_r/g/b` with the sprite/VDP layer overlaid (transparency or external-video mode), which then
goes to HDMI. The [`f18a_gpu_if`](../hdl/f18a/f18a_gpu_if.sv) (the F18A's on-VDP GPU) is wired but
held idle — present for future use, not driven today.

## Mockingboard — [`mockingboard.sv`](../hdl/mockingboard/mockingboard.sv)

Emulates the Mockingboard: **two AY-3-8910 PSGs** (two [`YM2149`](../hdl/support/YM2149.sv)
instances), each driven by a **6522 VIA** ([`via6522.vhd`](../hdl/support/via6522.vhd)). The left
VIA/PSG and right VIA/PSG are split by `addr[7]`, giving stereo (`audio_l_o`/`audio_r_o`, 10-bit
each → the [audio mix](audio.md)). `irq_n_o` is asserted when either VIA raises an interrupt. The
Votrax SC-01 speech chip is not implemented.

## Super Serial Card — [`super_serial_card.sv`](../hdl/ssc/super_serial_card.sv)

Emulates the Apple Super Serial Card: a **6551 ACIA** ([`uart_6551.v`](../hdl/support/uart_6551.v))
plus the card's **2 KB firmware ROM** ([`ssc_rom.vhd`](../hdl/ssc/ssc_rom.vhd)). The UART occupies
the slot's device register space; the ROM maps into the card's I/O/C8 ROM space when `INTCXROM` is
inactive (it reads `a2mem_if` for that). The UART's TX/RX connect to the board's host serial line
(over USB), giving **ADTPro**-compatible serial — including bootstrapping from it.

## Disk II — [`apple_disk.sv`](../hdl/disk/apple_disk.sv) (not currently built)

A Disk II controller emulation that serves disk images from a **RAMDISK** in SDRAM, with the disk
images supplied by the coprocessor over [`drive_volume_if`](../hdl/disk/drive_volume_if.sv) (block
I/O for two drives). 

**Status: not instantiated on any current board.** It was wired through the on-FPGA PicoSoC
RAMDISK path, which has been removed; the BL616 path currently stubs the disk signals
(`// no DiskII controller yet with BL616`). The `hdl/disk/` modules remain as the basis for
re-enabling Disk II on the BL616/ESP32 coprocessor path — see the
[coprocessor interface](coprocessor-interface.md) (`drive_volume_if`) and the board TODOs.

## CardROM — [`cardrom.sv`](../hdl/cardrom/cardrom.sv) (not a slot card)

CardROM is the A2FPGA's own **$F000–$FFFF ROM presence**, not a slotted peripheral. At power-up it
asserts the Apple **INH** line to inhibit the internal monitor ROM and hold the machine in a known
state until the FPGA is ready. Once the top level signals readiness (`req_rom_release_i` → an
internal `fpga_done` flag) **and** the Apple fetches the reset vector at **`$FFFC`**, it releases
INH and normal operation proceeds. Reads in `$F800–$FFFF` return the card ROM (from the
board-independent `cardrom.hex`); reads below that return the `fpga_done` status bit so monitor
code can poll FPGA readiness. This is the ROM-side counterpart to the a2bridge power-on-reset hold
described in [bus-interface.md](bus-interface.md).

## Reused cores

The card logic is built on established open cores (full attributions in the top-level
[README.md](../README.md) credits):

| Core | File | Used by | Upstream |
|---|---|---|---|
| F18A (TMS9918A VDP) | [`hdl/f18a/`](../hdl/f18a/) | SuperSprite | Matthew Hagerty (dnotq), Tang port by Felipe Antoniosi |
| YM2149 (AY-3-8910 PSG) | [`hdl/support/YM2149.sv`](../hdl/support/YM2149.sv) | SuperSprite, Mockingboard | MikeJ / Sorgelig (MiSTer) |
| 6522 VIA | [`hdl/support/via6522.vhd`](../hdl/support/via6522.vhd) | Mockingboard | Gideon Zweijtzer |
| 6551 UART | [`hdl/support/uart_6551.v`](../hdl/support/uart_6551.v) | Super Serial Card | Gary Becker (CoCo3_MiSTer) |

## Enabling cards & board differences

Each card has an `*_ENABLE` (and `*_ID`) parameter in `top.sv` (`SUPERSPRITE_ENABLE`,
`MOCKINGBOARD_ENABLE`, `SUPERSERIAL_ENABLE`, …). Resource-limited boards drop cards: **a2n9**
(Tang Nano 9K) omits SuperSprite (the F18A VDP doesn't fit). Mockingboard is enabled across the
board family. Slot assignment is via [`slots.hex`](../hdl/slots/slots.hex) at build time and the
coprocessor's `slotmaker_config_if` at runtime.

> Adding a new card (the `a2bus_if`/`slot_if` slave pattern, the data/IRQ mux, registering it in
> `slots.hex`) is covered in [bus-interface.md](bus-interface.md#adding-a-new-virtual-card).

## See also

- [bus-interface.md](bus-interface.md) — how cards attach to the bus and how to add one.
- [audio.md](audio.md) — how the Mockingboard / SuperSprite / Ensoniq audio is mixed.
- [coprocessor-interface.md](coprocessor-interface.md) — disk volume I/O and runtime slot config.
- [README.md](../README.md) — the cards as user-facing features, and the full open-core credits.
