# USB stick directory destroyed by a junk track write (2026-11-17)

> Status (2026-11-17): root cause found in the ESP32 firmware's disk-serving path and fixed
> in `boards/a2mega/src/a2fpga_esp32/` (shared by the a2p25 and the a2mega): request
> registers are now validated against the OSPI frame status and a device-ID probe, every
> seek is bounded by the image size measured at mount, and the restart and reload paths
> close the images and unmount the stick first. Firmware built (BOARD_REV=225, DP_TEST=0),
> **not flashed**; see "Build" at the end. The stick itself must be reformatted and the
> images recopied: the damage to its directory is not repairable from the firmware side.

Companion to [HDD_BLOCK_WRITE_SHIFT.md](HDD_BLOCK_WRITE_SHIFT.md) (the 11-13 block-write
defect in `hdd.sv`, unrelated to this one) and to the 10-15 notes in
[RESOURCE_AUDIT.md](RESOURCE_AUDIT.md) ("the image was corrupted a second time by the
hold-build install alone"), which already named the mechanism found here as a suspect:
"the telnet `g` reload and `fpgastream` paths DO leave `disk_poll` running while the fabric
reconfigures (garbage `HDD_REQ` reads → garbage block writes) — a quiesce is warranted
there regardless."

## What happened

Ed's a2p25 (displayport1, ESP32 firmware BOARD_REV=225, FAT32 USB stick on the ESP32's
USB port) lost its stick directory during an evening session: Disk II image writes (Nox
Archaist saving to a `.nib` in drive 1), ProDOS HDD images, heavy Uthernet II traffic,
and three gateware reloads over WiFi with `tools/fpga_stream.py`. Each stream ends in
`fpgastream.c` with `fpga_jtag_reload()`, a 2 s wait, then `esp_restart()`, with every
image file still open and the disk task still polling.

After the session the stick's root directory listed `disk1.nib` as a 4 GB file and the
entries for the other images were gone.

## Evidence (first-hand, from the 2 GB image of the stick's start)

Image: `/Users/edanuff/a2p25_stick_2026-11-17.img` (first 2 GB of the 32 GB stick, MBR
at 0, FAT32 partition at sector 8192 = byte 0x400000). Read with a small Python FAT32
parser on 11-17; every number below comes from that read.

| Item | Value |
|---|---|
| Volume | FAT32, 512 B sectors, 64 sectors/cluster (32 KiB clusters), 2 FATs of 7,534 sectors, 964,256 clusters, root directory = cluster 2 at byte 0xC00000 (12 MiB) |
| `DISK1.NIB` directory entry | start cluster 183, size **0xFDFE1600 = 4,261,287,424**, write time **1980-01-01 00:43** (the ESP32 has no clock; FatFS stamps its boot-relative time, i.e. this was written 43 min after an ESP32 boot) |
| `DISK1.NIB` cluster chain | **130,045 clusters = 4,261,314,560 B** in both FATs, in two contiguous runs: 183–190 (the original 8 clusters, 232,960 B of nibbles) then 67168–197204. The extension completed; it is not a torn chain |
| Size vs chain | size = 4,261,287,424 = **8,322,827 × 512** exactly: the recorded size is the seek position of a block-number-8,322,827 write-back, not seek + data (the 6,656-byte track never landed, or its `f_sync` never ran) |
| FAT1 vs FAT2 | 27 entries differ, all in 46692–46918: FAT2 holds a 26-cluster chain from 46692 that FAT1 ends at 46692 (EOC). A FAT update in flight at a restart |
| Allocated but unreachable | FAT1 marks 297,216 clusters (9.74 GB) allocated; 131,429 are reachable from the directory tree; **165,787 clusters = 5.43 GB are orphaned**, in 229 runs (largest 197205–297429) |
| Root directory, second sector | entries 16–21 intact (`816PAI~9.2MG` and its `._` companion), then **128 bytes of Apple-side data at bytes 704–831**, then zeros to the end of the cluster. The other image entries (Nox Archaist and the rest) are gone, not deletion-marked; the five deletion-marked entries are macOS `._` companions of 4,096 B |
| The 128 bytes | `08 6c 7b b0 aa 10 0c 8b b0 aa 20 c0 20 00 a9 08 c0 20 00 a8 08 b1 bf fe 0c 4d b0 aa …` — 70 of 128 bytes have the high bit set, 37 distinct values, `a9 08` / `b1 bf` / `88 0a` / `c0 20`: 6502 code or de-nibblized sector data, **not** GCR nibbles (a `.nib` track is all ≥ 0x96 with the high bit set) |

Arithmetic on the block number: 8,322,827 = 0x7EFF0B is **not a multiple of 13**
(8,322,827 = 13 × 640,217 + 6). A `.nib` is served in 13-block tracks, so no track request
has an lba that is not a multiple of 13.

## Where the block number came from

The FPGA side cannot produce it. `hdl/disk/drive_ii.sv`:

```systemverilog
assign volume_if.lba = 32'd13 * (save_req_r ? cur_track_r : req_track_r);
```

`cur_track_r` and `req_track_r` are 6-bit registers, so the lba a configured fabric
presents is at most 13 × 63 = 819 (0x333): bytes 2 and 3 of the 32-bit register are
always zero. `req_track_r` is latched in the same cycle `load_req_r` rises and
`cur_track_r` is held while `save_req_r` is up; both only change on the firmware's ack.
The four lba bytes are read as four separate OSPI transactions (`fpga_reg_read32`), but
nothing on the FPGA side can move between them while a request is pending, so there is no
stale-high-byte/fresh-low-byte race on a live fabric. The HDD path (`hdd.sv`) presents a
16-bit block number latched from the card's registers before the request rises, with the
same property. `esp32_ospi_connector.sv` exposes both combinationally (regs 0x48–0x4B and
0x58–0x5B for the floppies, 0x27/0x28 and 0x2B/0x2C for the HDD units); no register latch
is involved, and none is needed.

`0x7EFF0B` with a `write pending` bit set is what the ESP32 reads when **the FPGA is not
configured**. During `fpga_jtag_reload()` (and for the whole stream when the SRAM-erasing
flash entry is used) the OSPI data lines are not driven by the connector; the ESP32 clocks
in whatever the lines float to. The link layer does check the response frame (status byte
OK bit and protocol version 1, `ospi_reg_read` in `a2fpga_ospi_link.c`), but after its one
retry it **returns `ESP_OK` regardless**, and `fpga_reg_read()` hands the junk data byte to
the caller. `disk.c` had no check of its own: `serve_drive()` read `VOL_CMD`, saw a write
bit, read a junk lba and block count, and ran

```c
fseek(g_img[v], g_base[v] + lba * SECTOR_BYTES, SEEK_SET);   /* 4 GB past EOF */
fwrite(g_trackbuf, 1, nbyte, g_img[v]);
image_sync(g_img[v]);                                          /* fflush + fsync */
```

FatFS, asked to seek past the end of a file opened for writing, extends the file: it
allocated 130,037 new 32 KiB clusters (writing both FATs on the way, which is where the
seconds went), set the file size to the seek position and, at `fsync`, wrote the directory
entry — size 0xFDFE1600, timestamp 1980-01-01 00:43. The disk task runs this every 2 ms for
each mounted, writable drive, so the 2 s reload window alone offers ~1,000 junk requests per
drive; the three reloads of the evening and the long allocation explain the orphaned 5.4 GB
(allocations whose directory update never ran) and the FAT1/FAT2 split (a mirror write cut
by `esp_restart()`).

The sequence in `fpgastream.c` before this fix, from the point the stream is accepted:

1. `fpga_jtag_flash_enter_keepsram()` (fabric alive) or `fpga_jtag_flash_enter()` (fabric
   erased: junk from here on), erase, program, verify — minutes, disk task polling throughout.
2. `fpga_jtag_reload()` — fabric dies, then comes back after ~1–3 s with its registers reset
   (`VOL_MOUNTED` = 0, so even the new fabric does not request anything).
3. `vTaskDelay(2000)` — disk task reads junk at 2 ms cadence and acts on it.
4. `esp_restart()` — with the images open and FatFS mid-write.

`fpgaupdate.c` (menu/CLI install) runs *inside* the disk task, so its reload window does
not poll; but it also restarts with the images open, and so do `fwupdate.c` and the CLI
`restart`. The telnet `g` reload and the CLI `reconfig` reconfigure the fabric with the
disk task running and never re-register the volumes afterwards.

What this does **not** pin: the 128 bytes of de-nibblized Apple data inside the root
directory cluster followed by zeros. It is the size and shape of a FatFS directory-sector
write whose source buffer no longer held the directory, and an HDD block or a decoded
sector is the only Apple-side data of that kind the firmware holds (`g_blockbuf`,
`g_secbuf`). A plausible route is a second junk request (HDD unit, `lba < 65535` passes
the HDD path's existing bound) landing a 512 B block write on a cluster that a junk-extended
chain shared with the directory, or a torn directory-sector update at the restart; neither
is demonstrated. The fixes below remove every junk request and every open file at restart,
which closes both routes.

## Fixes (firmware, commit on this branch)

`fpga_link.c/.h`:

- `fpga_reg_read_checked()` / `fpga_reg_read32_checked()`: register reads that **fail**
  when the response frame is invalid (status OK bit clear or protocol version ≠ 1), after
  the same one retry `ospi_reg_read` makes; the value is 0 on failure.
- `fpga_link_probe()`: the four `DEVICE_ID` registers must read `A2FP` through valid
  frames. Junk has a 1-in-32 chance per byte of passing the frame check; the probe makes
  acting on junk a 2⁻³² event.

`disk.c`:

- `serve_drive()` / `serve_hdd()` read `VOL_CMD` / `HDD_REQ`, the lba and the block count
  with the checked reads and, when a request is pending, require `fpga_link_probe()`. A
  request that fails any of this is **left pending** (no ack, no seek); the first failure
  logs `FPGA LINK INVALID - REQUEST IGNORED` to the OSD console, the first good request
  afterwards logs `FPGA LINK BACK`.
- Every seek is bounded by the image as mounted: `g_bytes[v]` (payload length, after any
  2IMG header) is recorded in `mount_drive()`, and the file position is computed in 64 bits.
  A floppy request must have `lba % 13 == 0`; a **write** must fit entirely
  (`pos + len <= base + bytes`) so the file is never extended; a **read** must start inside
  the image (a truncated `.nib` keeps its zero-fill-and-log behaviour). An out-of-range
  request logs `DISK II: Dn WR LBA <lba> OUT OF RANGE (IMG <bytes> B) - NOT WRITTEN` (or
  `RD … - ZERO TRACK`, with a zero track delivered), is never seeked, and is acknowledged so
  the drive is released (the protocol has no error channel; the Apple sees what it saw
  before when a write failed). The HDD path already had `lba < g_hdd_blocks[u]` on both
  reads and writes; it now logs the rejection the same way. Repeats of the same bad lba
  are logged once.
- `disk_quiesce()`: close every image and serve nothing until `disk_request_remount()`.
  From the disk task (where `fpgaupdate` and `fwupdate` run) it closes inline; from
  another task it hands the close to `disk_poll()` and waits up to ~500 ms, then closes
  itself if the disk task is not running (and says so).
- `disk_release_storage()`: `disk_quiesce()` plus `usbstorage_unmount()` — nothing of
  FatFS is left dirty for a restart to cut.

Call sites:

| Path | Before the fabric goes away | Before `esp_restart()` | On failure |
|---|---|---|---|
| `fpgastream.c` (port 2323) | `disk_quiesce()` before the JTAG entry loop | `disk_release_storage()` after the 2 s reload wait | `disk_request_remount()` on the entry/erase/program failures (a keepsram fabric may still be alive) |
| `fpgaupdate.c` (menu / CLI `fpgaflash`) | `disk_quiesce()` before `fpga_jtag_init_pins()` (the bitstream file itself stays open, read-only, and is closed before the reload as before) | `disk_release_storage()` | `disk_request_remount()` on IDCODE mismatch / entry failure |
| `fwupdate.c` (MCU OTA from the volume) | — | `disk_release_storage()` in the 2 s restart timer | — |
| `telnetd.c` key `g` (reload from flash) | `disk_quiesce()` | — | `disk_request_remount()` after `fpga_jtag_release_pins()` so the new fabric gets its volumes registered |
| `a2fpga_esp32.ino` CLI `reconfig` | `disk_quiesce()` | — | `disk_request_remount()` after DONE |
| `a2fpga_esp32.ino` CLI `restart` | — | `disk_release_storage()` | — |

Not changed: `ftpd.c` can still have an upload open on the stick when any of these restart
paths runs (the 10-15 rule "no FTP writes to the stick while an image is mounted" stands),
and `ospi_reg_read()` itself still returns `ESP_OK` after a failed retry, so other callers
of `fpga_reg_read()` (menu, W5100 bridge, status) still see junk on a dead fabric; none of
them writes a file. Nothing in the gateware needed changing for this; the request
registers are sound.

## How to tell it is fixed

- Stream a bitstream over port 2323 with a writable `.nib` in drive 1 and an HDD image
  mounted: the OSD console shows `DISK: IMAGES CLOSED, STORAGE RELEASED` before the
  restart; afterwards `ls -l` on the stick shows the images at their original sizes with
  their original timestamps, and `fsck_msdos` (macOS) / `dosfsck -n` reports no lost
  clusters and identical FATs.
- Telnet `g` with disks mounted: `FPGA LINK INVALID - REQUEST IGNORED` must **not** appear
  (the quiesce precedes the reload), the drives come back after the remount, and the
  images are unchanged.
- Negative test of the bound without hardware: a `.nib` shorter than 35 tracks (or a
  `.dsk` of 34 tracks) mounted in drive 1 and a `CATALOG` of track 34: the OSD logs
  `OUT OF RANGE … ZERO TRACK`, the Apple reports an I/O error, and the file size is unchanged.

## Build

`make BOARD_REV=225 DP_TEST=0 compile` in `boards/a2mega/src/a2fpga_esp32/` (arduino-cli
1.2.2, esp32 core 3.3.5), from a clean `build/`:

| | |
|---|---|
| Source | this commit (branch `claude/strange-heisenberg-ca020e`, parent `d13e70b7`) |
| Artifact | `build/a2fpga_esp32.ino.bin`, 1,127,776 B (sketch 1,127,635 B = 86 % of the 1.25 MB app slot, globals 125,424 B) |
| sha256 | `e9a7dee743c0d39d54490db958cb483df4ac7e3081c597ea18f41b2082673b0e` |
| Warnings | none in the changed files |
| Flashed | **no** |

Install per [ESP32_FW_A2P25.md](ESP32_FW_A2P25.md) ("Updating the firmware without the
download-mode dance"): copy the `.bin` to a freshly formatted stick (or FTP it), FIRMWARE
menu → UPDATE MCU, or `fwupdate <file>` / `fwupdate go` on the CLI. Reformat the damaged
stick and recopy the images before using it again; the forensic image stays at
`/Users/edanuff/a2p25_stick_2026-11-17.img`.
