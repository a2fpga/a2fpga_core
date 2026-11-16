# HDD image corruption: block writes shifted by one word

> Status (2026-11-13): root-caused and fixed in `hdl/disk/hdd.sv`; bench `sim/disk/run.sh`
> reproduces the failure on the old card and passes on the fix. Hardware confirmation on the
> a2p25 and a2mega is pending (see "What to flash and test").

## Symptom

Ed's a2p25 (displayport1, ESP32 firmware BOARD_REV=225, FAT32 USB stick on USB1) kept
losing the mounted ProDOS image. It looked like power-down corruption: the IIgs ran fine,
was switched off, and on the next boot the volume was unreadable until the image was
recopied from the Mac. The a2n20v2-Enhanced saw the same class of damage in 2025 ("a
game's high-score save destroyed the volume directory blocks with shifted/interleaved
words") and has served HDD units read-only ever since (`firmware_host/disk.c`,
`CONTAINMENT`). The a2p25 TODO carried it as "HDD image corruption seen around installs".

## Evidence

Corrupted `BENCHMARKv5.2mg` kept on the stick after one such power cycle, compared block by
block (512 B, after the 64-byte 2IMG header) against a fresh copy. Two blocks differ, both
ProDOS directory blocks that GS/OS legitimately rewrote (their modification-time fields
carry new values): block 2 (volume directory key block) and block 12 (the `SYSTEM`
subdirectory). In each, the stored data is the correct new block **shifted right by one
32-bit word**:

```
word 0        01 00 00 00            stale (not written)
words 1..126  = correct words 0..125  (each landed one word late)
word 127      = correct word 127      (the last word is addressed correctly)
```

Block 2, first 16 bytes: good `00 00 03 00 fb 53 59 53 54 45 4d 2e 44 49 53 4b` ("SYSTEM.DISK"),
corrupted `01 00 00 00 00 00 03 00 fb 53 59 53 54 45 4d 2e`. No FAT damage, no torn sectors, no
random data. GS/OS keeps directory blocks in its cache, so the shifted blocks were only read
back after the reboot, which is why the damage appeared to happen at power-down.

`tools/image_blkdiff.py good.2mg bad.2mg` prints this classification for any pair of images.

## Root cause

`hdd.sv`, block service FSM, WRITE path. `ST_DRAIN_ISSUE` registers the memory-port write
strobe (`ram_wr_r <= 1`) and in the same cycle advances `word_cnt_r`. The port address was
`{req_unit_r, word_cnt_r}` combinationally, so when the strobe was visible to the port, one
cycle later, the address already pointed at the next word: word k was stored at k+1, word 0
was never written and kept whatever the window held, and word 127 was correct because the FSM
leaves `ST_DRAIN_ISSUE` for `ST_WR_ACK` without incrementing. The READ path
(`ST_FILL_ISSUE`) does not touch `word_cnt_r` in the strobe cycle, which is why reads were
always byte-faithful and the read-only containment on the Enhanced worked.

The window port is the connector's SPACE 5 BSRAM on the a2p25 and a2mega
(`esp32_ospi_connector.sv`, `hdd_port_card`: `addr`/`data` sampled in the `wr` cycle) and the
SDRAM `mem_port` on the Enhanced, with the same sampling, so all three boards had the defect.

## Fix

`hdd.sv`: a registered `wr_word_r` latched from `word_cnt_r` in `ST_DRAIN_ISSUE`; the port
address uses it while `ram_wr_r` is high. One 7-bit register and a mux; no protocol, ROM or
firmware change.

Bench: `sim/disk/tb_hdd_block.sv` drives the card the way `hdd_rom.a65` does (COMMAND, UNIT,
MEMBLOCK, BLOCK, 512 NEXTBYTE stores, EXECUTE, STATUS poll) against a memory-window model and a
volume model, for a write, a read and a second write with a different pattern:

```
sim/disk/run.sh
```

Old card: `WRITE PATH: FAIL (127 words wrong)`, every wrong word equal to the expected word of
i-1. Fixed card: all three phases PASS.

Firmware (`boards/a2mega/src/a2fpga_esp32/disk.c`): the write path now checks the window read,
`fwrite`, `fflush` and `fsync` results and logs `WRITE FAILED` with the block/track when any of
them fail. Behaviour on success is unchanged. The volume protocol has no error channel back to
the card, so the Apple still sees the block as written; the log is the evidence.

## Boards

| Board | Gateware | Firmware | Status |
|---|---|---|---|
| a2p25 displayport1 | `hdd.sv` fix (full core `a2p25.gprj`) | ESP32 225, logging only | built and flashed 2026-11-13; IIgs power-cycle after writes OK (see below) |
| a2mega 1.0a3 | same `hdd.sv` | ESP32 103, logging only | not built here; a2mega timing is knife-edge, build when a bench slot opens |
| a2n20v2-Enhanced | same `hdd.sv` + drain write-completion wait (see below) | BL616 `firmware_host/disk.c` containment lifted | `_fb` write-tested on hardware 2026-11-15 (ProDOS 2.4.3 on a ][+): clean |

### a2p25 build and hardware result (2026-11-13)

Built on the edanuff fork together with a hyperram_ctrl timing closure the full core needed at the
time (edanuff/a2fpga_core PR 35): three placements, each 0 setup / 0 hold, every clock above its
constraint, no `top/hdd` path among the worst 25. The card costs +12 LUT / +7 REG, no BSRAM. That
bitstream was flashed to an a2p25 on 2026-11-13; the IIgs was power-cycled after writing to the
HDD volume and came back and booted, which is the case that used to fail. The block diff of the
written image against its original is still to be run.

### a2n20v2-Enhanced: second write bug, every other word dropped (2026-11-15)

The first write test on the Enhanced `_fb` (this fix in, containment lifted for a test image only)
still corrupted the volume, in a different pattern: in every written block the even words were
right and every odd word held the previously written block's word (a new directory entry's name
came out as `TE`, the bitmap held directory-header words). `mem_port_arb` keeps one pending
request per client and a newer request overwrites one not yet granted. The drain issued a word
write every 5 cycles without waiting for `ready`; on the Enhanced storage port (shared by MCU XFER,
Disk II and HDD) a write takes longer than that, so word k+2 overwrote pending word k+1. Reads were
never affected because `ST_FILL_WAIT` waits for each word. The `sim/disk` bench memory completes a
write in one cycle, so it cannot show this.

Fix: `ST_DRAIN_WAIT` holds each word until its write completes (`fsm_addr_r` steps on the exit
cycle so the buffer read stays aligned), which also guarantees word 127 has landed before `vol_wr`
asks the MCU to flush the block. Retest on hardware: `CREATE`/`SAVE` in the root and a
subdirectory, `PREFIX`/`CAT`, power cycles, `LOAD`/`RUN` all clean; the image changed only in the
expected blocks (directory, bitmap, new directory key block, two file blocks) with a consistent
bitmap and no stale words. The fix is in the shared `hdd.sv`, so a2p25 and a2mega pick it up too
(not rebuilt here).

## What to flash and test (Ed)

1. Flash the a2p25 full-core bitstream built from this branch (`boards/a2p25/impl/pnr/a2p25.fs`),
   with the `/flash` skill. The firmware change is optional for the test.
2. Copy a fresh `BENCHMARKv5.2mg` to the stick. Boot, run the benchmark (it writes
   `RESULT.DAT`, which rewrites directory blocks 2 and 12). Power the IIgs off and on; the
   volume must boot and `RESULT.DAT` must be present.
3. On the Mac: `tools/image_blkdiff.py <original> /Volumes/<stick>/BENCHMARKv5.2mg`. Expected:
   the changed blocks are plain rewrites (`shifted=False`, no stale copies); before the fix the
   same test shows `shifted=True` on every rewritten block.
4. A direct check without the benchmark: from BASIC.SYSTEM on the image, `SAVE` a new file,
   power cycle, `CAT`. The file must be there and the volume readable.

## Not the cause (checked on the way)

- The ESP32 firmware calls `fsync` after every block, which rewrites the stick's directory
  sector each time (FatFs `f_sync` updates the timestamp). That is a real exposure to a torn
  metadata write if power drops mid-write, but the kept image showed no FAT damage. Left as is.
- The FatFs `CTRL_SYNC` ioctl sends nothing to the stick. Sticks are write-through at the
  SCSI level; not implicated.
- Spurious bus activity while the IIgs rail collapses: nothing gates disk requests on the
  Apple being alive, and slot /RES does not assert at IIgs power-down (the ADB micro drives it
  as a port pin). Still possible in principle; the kept image showed no such write. The next
  a2-p25 board turn adds a `BUS_PWR_ACTIVE` rail sense to the FPGA (a2-p25 repo
  `displayport2`, same design as `boards/a2mega/docs/apple_off_backfeed_level_shifters.md` §5a),
  which is the right place for a hard gate.
