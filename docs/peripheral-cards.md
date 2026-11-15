# Peripheral Card Emulation

> Status (2026-10-25): catalog re-read from the board tops and `hdl/slots/slots.hex`. Disk II,
> the ProDOS hard disk and Uthernet II ship on the coprocessor boards; CardROM is excised.

The catalog of virtual Apple II cards the core provides — what each emulates, the upstream cores it
reuses, and where the HDL lives. How cards attach to the bus and how to add one is in
[bus-interface.md](bus-interface.md); the sound mixing is in [audio.md](audio.md). This page is the
per-card reference.

Each card is a slave on [`a2bus_if`](../hdl/bus/a2bus_if.sv) + [`slot_if`](../hdl/slots/slot_if.sv)
with an 8-bit card **ID**, assigned to a slot by [`slots.hex`](../hdl/slots/slots.hex) (and
reconfigurable at runtime by the coprocessor). Default assignment:

| Card | ID | Default slot | Emulates | Boards |
|---|---|---|---|---|
| SuperSprite | 1 | 7 | Synetix SuperSprite (TMS9918A VDP + AY-3-8910) | Tang Nano 20K boards, a2mega 138K |
| Mockingboard | 2 | 4 | Sweet Micro Systems Mockingboard (2× AY-3-8910 + 2× 6522) | all but a2mega 60K and a2p25 |
| Super Serial Card | 3 | 2 | Apple Super Serial Card (6551 ACIA) | all but a2mega 60K and a2p25 |
| Disk II | 4 | 5 | Apple Disk II controller, images served track-on-demand by the coprocessor | a2n20v2-Enhanced, a2mega, a2p25 |
| Uthernet II | 5 | 3 | a2RetroSystems Uthernet II (WIZnet W5100), network engine on the coprocessor | a2n20v2-Enhanced (USB Ethernet), a2mega (WiFi) |
| ProDOS HDD | 6 | 6 | AppleWin-style ProDOS hard-disk card, two block-device units served by the coprocessor | a2n20v2-Enhanced, a2mega, a2p25 |

The per-board set is decided in `boards/<board>/hdl/<board>_profile.vh` (and per die on the
a2mega); the exact table is in [boards.md](boards.md#which-cards-each-board-carries).

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

## Disk II — [`apple_disk.sv`](../hdl/disk/apple_disk.sv) (`DiskII`) + [`drive_ii.sv`](../hdl/disk/drive_ii.sv)

A Disk II controller (the Apple-II_MiSTer / Edwards `drive_ii` lineage) serving two drives
**track-on-demand**: on a seek, `drive_ii` raises a request on the drive side of
[`drive_volume_if`](../hdl/disk/drive_volume_if.sv) (`lba`/`blk_cnt`/`rd`), the coprocessor
streams the requested nibblized track (6656 bytes) into the card's memory window (an SDRAM /
DDR3 / HyperRAM port, or a BSRAM buffer inside the ESP32 connector) and pulses `ack`; writes go
back the same way. `.nib` images are served as-is; `.dsk`/`.do`/`.po`/`.2mg` are nibblized on the
fly in the coprocessor firmware (6-and-2 GCR, read-write with decode-on-flush). Design record:
[boards/a2n20v2-Enhanced/docs/disk_image_serving_design.md](../boards/a2n20v2-Enhanced/docs/disk_image_serving_design.md).
The "WORK IN PROGRESS / requires PicoSoC" header comments in the two source files predate this
and are stale.

Timing trap: the nibble register advances on the **rising** `phi0` edge (the start of the read
window), never on `phi1_posedge`; the wrong edge races the 6502's latch and produces boot hangs
and I/O errors.

## ProDOS hard disk — [`hdd.sv`](../hdl/disk/hdd.sv)

An AppleWin-style ProDOS HDD interface card with its own driver ROM
([`hdd_rom.a65`](../hdl/disk/hdd_rom.a65), assembled to `hdd_rom.hex`). Because the 6502 cannot be
halted on a real bus, commands are asynchronous: reading EXECUTE (`$C0s0`) latches the command
and sets the busy bit, the driver ROM polls STATUS until the coprocessor has served the 512-byte
block over the unit's `drive_volume_if`, then streams it through the NEXTBYTE port. Two units
(`.hdv`/`.po`/`.2mg` images, LBA 1:1 into the file), each with a 512-byte BSRAM sector buffer and
a block window in the board's memory. Code traps are recorded in the module header (an
`STA abs,X` false read, the Gowin DPB write mode, `data_out_en`). Until 2026-11-13 the WRITE
drain stored every word of a block one word late (word 0 stale), which corrupted ProDOS
directory blocks on every board that let the card write; root cause, fix and bench
(`sim/disk/run.sh`): [HDD_BLOCK_WRITE_SHIFT.md](../boards/a2p25/docs/HDD_BLOCK_WRITE_SHIFT.md).

## Uthernet II — [`uthernet2.sv`](../hdl/uthernet2/uthernet2.sv)

Emulates the register/memory front end of an a2RetroSystems Uthernet II: the WIZnet **W5100** in
indirect bus mode, four `$C0nX` registers over an on-chip dual-port copy of the W5100 address
space (9 BSRAM blocks on the Tang Nano 20K). The socket engine and the network bridge run on the
coprocessor, which reaches the backing store through the connector's memory SPACE 3 and is
notified of socket commands by a per-socket doorbell. MACRAW mode is implemented (IP65, ADTPro,
Contiki, Marinetti); the hardware TCP/UDP socket modes are not. On the Enhanced the frames go
out a USB-Ethernet adapter (CDC-ECM, RTL8153 class); on the a2mega the ESP32 bridges them to
WiFi with MAC NAT. Design and the FPGA-to-firmware contract:
[UTHERNET2.md](../boards/a2n20v2-Enhanced/docs/UTHERNET2.md) and
[UTHERNET2_PROTOCOL.md](../boards/a2n20v2-Enhanced/docs/UTHERNET2_PROTOCOL.md). Off on the a2p25
(BSRAM budget).

## CardROM — [`cardrom.s`](../boards/a2n20v2-Enhanced/src/cardrom/cardrom.s) (excised)

CardROM was the A2FPGA's own **$F000–$FFFF ROM presence**, not a slotted peripheral: at power-up
it asserted the Apple **INH** line to inhibit the internal monitor ROM and hold the machine until
the FPGA was ready, releasing INH once readiness was signalled **and** the Apple fetched the
reset vector at `$FFFC`. The 6502 source and `cardrom.hex` remain under
`boards/a2n20v2-Enhanced/src/cardrom/`, but no board top instantiates the HDL any more (the
Enhanced top ties `cardrom_active_i` to 0, "CardROM excised"): the reset hold that keeps an
Apple from booting before the coprocessor has mounted its volumes is now done directly on the
reset line itself: `apple_bus` holds `/RES` until the coprocessor releases it (BL616 register
0x2E; on the a2mega the FPGA's `a2_res_out_n` through a 74LVC2G06; on the a2p25 that output has
no pin and the ESP32 drives `/RES` from its own GPIO). See [bus-interface.md](bus-interface.md) for the a2bridge power-on-reset hold.

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

Each card has an `*_ENABLE` (and `*_ID`) parameter in `top.sv` whose default comes from the
board's `*_profile.vh` (`A2_FEATURE_SUPERSPRITE`, `A2_FEATURE_MOCKINGBOARD`, … see
[build_profiles.md](build_profiles.md)); on the a2mega the three classic cards are per die
(`dp_test_die_pkg`: off on the 60K, on on the 138K). Resource-limited boards drop cards: **a2n9**
omits SuperSprite (the F18A VDP doesn't fit), the **a2p25** carries only Disk II and the HDD
(logic at 97%, BSRAM 52/56). An `ENABLE=0` card is removed from the build but keeps its slot ID
reserved. Slot assignment is via [`slots.hex`](../hdl/slots/slots.hex) at build time and the
coprocessor's `slotmaker_config_if` at runtime (the Enhanced and ESP32 menus apply it before the
Apple's reset is released).

> Adding a new card (the `a2bus_if`/`slot_if` slave pattern, the data/IRQ mux, registering it in
> `slots.hex`) is covered in [bus-interface.md](bus-interface.md#adding-a-new-virtual-card).

## See also

- [bus-interface.md](bus-interface.md) — how cards attach to the bus and how to add one.
- [audio.md](audio.md) — how the Mockingboard / SuperSprite / Ensoniq audio is mixed.
- [coprocessor-interface.md](coprocessor-interface.md) — disk volume I/O and runtime slot config.
- [boards.md](boards.md#which-cards-each-board-carries) — which board carries which card.
- [README.md](../README.md) — the cards as user-facing features, and the full open-core credits.
