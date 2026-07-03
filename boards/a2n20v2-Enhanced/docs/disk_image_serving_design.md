# Disk II / ProDOS image serving on a2n20v2-Enhanced (BL616)

Status: **design** (2026-06-23). Backend: SD card (FPGA SPI tunnel) and/or USB Mass Storage
on the BL616 host. Informed by reading the existing A2FPGA HDL/firmware and the
[MiSTle-Dev/NanoApple2](https://github.com/MiSTle-Dev/NanoApple2) core (same GW2AR Tang Nano 20K,
same BL616 companion-MCU lineage, same Edwards `apple2fpga` Disk II core).

## 1. Architecture decision — track-on-demand, not whole-disk SDRAM

A2FPGA's `hdl/disk/drive_ii.sv` and NanoApple2's `src/drive_ii.vhd` are the **same core** with an
identical track-buffer port (`TRACK[5:0]`, `TRACK_ADDR[12:0]`, `TRACK_DI/DO`, `TRACK_WE`,
`TRACK_BUSY`; track = `0x1A00` = 6656 B). They differ only in the backing store:

- **Current A2FPGA:** whole nibblized disk (~466 KB/drive) lives in SDRAM, indexed `track*6656`.
  The `drive_volume_if` block protocol (`lba/blk_cnt/rd/wr/ack`) exists but is **tied to 0** in
  `drive_ii.sv:35-39`; the controller reads SDRAM directly via `ram_disk_if`.
- **NanoApple2 (`src/floppy_track.sv`):** one track (6656 B) in a **dual-port BRAM** per drive,
  filled on demand. On track change it requests `lba = track*13` (13×512 = 6656), streams 13
  sectors into the BRAM, and **flushes the dirty track back** before loading the next.

`drive_volume_if` is already the NanoApple2/MiSTer HPS block interface. The 16384 B transfer cap in
its comment and the 6-bit `blk_cnt` were sized for exactly a 13-block (6656 B) track transfer.

**Decision (locked):** adopt the track-on-demand model, backed by a **small fixed SDRAM window** —
NOT BRAM. The whole-disk-in-SDRAM approach is rejected as unwieldy; the BRAM track-buffer variant is
rejected because **BSRAM is the scarce resource** (recent builds run 42-46/46 BSRAM). SDRAM is cheap
here, so we keep the track buffer in SDRAM but shrink it from the whole disk to one track per drive.

- **Tier B1 — THE approach.** Keep a *tiny* per-drive track window in SDRAM (2 × 8 KB; one
  `0x1A00`-byte track each, 8 KB-aligned). Reuse the existing `bl616_spi_connector` XFER SPACE 1
  (SDRAM) + volume registers (0x40–0x5F). Minimal HDL diff: un-stub `drive_ii` to drive `lba/rd` on
  track change and gate reads on `ready`; address the window track-relative; add the MCU poll loop.
  **Zero added BSRAM, no new SPI space, no new BRAM.** The MCU serves one track (or block range) per
  request instead of pre-loading the whole disk.
- **Tier B2 (NanoApple2 BRAM parity) — NOT pursued.** NanoApple2 uses a BRAM track buffer; we
  deliberately diverge to save BSRAM. Documented only as the alternative we rejected.

Disk formats follow NanoApple2: **`.nib`** for floppies (already nibblized; track→LBA is `track*13`;
no FPGA or firmware GCR work) and **`.hdv`/`.po`** for ProDOS block devices (raw 512 B blocks, LBA
1:1). On-the-fly `.dsk`→`.nib` is done offline (NanoApple2 ships `disk2nib/dsk2nib.c`); the firmware
can optionally run the same conversion at mount time later.

## 2. PART 1 — HDL

### 2.1 Un-stub the Disk II floppy path (`drive_ii.sv` + `apple_disk.sv`)
- `apple_disk.sv` (module `DiskII`) is complete and unchanged: ports `a2bus_if`, `slot_if`,
  `ram_disk_if` (mem_port, 21-bit word / 32-bit data), `volumes[2]` (`drive_volume_if.drive`).
  It already instantiates two `drive_ii` and muxes their `ram_disk_if`.
- `drive_ii.sv` changes (the core of the work):
  - Replace `assign volume_if.lba='0; .blk_cnt='0; .rd=0; .wr=0;` (lines 35-39) with a small
    track-loader FSM mirroring `floppy_track.sv`:
    - track `track_w = phase_r[7:2]`. On `track_w != cur_track` (and motor active), request a load:
      `volume_if.lba = cur_track*13` (raw `.nib`) or board-mapped offset, `volume_if.blk_cnt = 12`,
      pulse `volume_if.rd`; wait for `volume_if.ack`; expose `TRACK_BUSY`/not-`ready` so the read
      datapath stalls until the track is present.
    - Dirty-track writeback (phase 2): track a `dirty` bit set on `track_we`; on track change with
      `dirty`, first assert `volume_if.wr` for `old_track*13`, wait `ack`, then load.
  - Address the SDRAM track window **track-relative**: `ram_disk_if.addr = {drive_id, track_byte_addr[12:2]}`
    into a 2×8 KB region (drop the `track_w*0x1A00` whole-disk offset). The MCU writes the active
    track to this fixed window.
  - Gate `D_OUT`/byte engine on `volume_if.ready & ~busy` so the Apple sees the drive "not ready"
    during a track swap (authentic; software already tolerates seek latency).
- Reference wiring (proven, from `git show 498417a^:boards/a2n20v2-Enhanced/hdl/top.sv`): a dedicated
  `RAMDISK_MEM_PORT` fed `DiskII.ram_disk_if`, and `volumes` connected to the soft-CPU. We keep the
  `DiskII` instantiation; the *provider* of `volumes` becomes the BL616 via `bl616_spi_connector`.

### 2.2 `boards/a2n20v2-Enhanced/hdl/top.sv`
- Remove the stub at ~lines 472-487 (`drive_volume_if volumes[2]()` + zero tie-offs).
- Instantiate `DiskII` wired to `a2bus_if`, `slot_if` (Disk II ID = 5 per `slots.hex`), `data_o`/`rd_en_o`
  into the card data mux, and `volumes` connected to `bl616_spi_connector`'s volume ports (it already
  exposes 0x40–0x5F → `volumes[*]` and drives `ready/mounted/readonly/size/ack`, reads back
  `lba/blk_cnt/rd/wr` — confirmed in `bl616_spi_connector.sv:730-762, 920-928`).
- SDRAM: add the 2×8 KB track window in free space (memory map: FB 0x000000, Ensoniq 0x010000 word
  base; CLAUDE.md notes byte 0x200000–0x7FFFFF free). Either give the disk its own `mem_port` or
  route track writes through the existing MCU XFER SPACE 1 (port 4) at a fixed disk address — the
  latter needs **no new port** and is the B1 default.
- Clocks: `drive_ii` runs on `clk_logic` (54 MHz); `bl616_spi_connector`/XFER already handle the
  SPI↔logic crossing and SDRAM CDC. Mirror NanoApple2's `floppy_track` dual-clock synchronizers
  (`clk` Apple / `clk2` controller) if any volume_if flag crosses domains in `drive_ii`.
- Respect the existing **standalone fallback**: with no BL616, `standalone_w` engages; volumes stay
  unmounted (no disk) but base Apple II still boots. Don't let the disk FSM hang the bus when
  `volume_if.ready==0`.

### 2.3 Optional ProDOS block device (`.hdv`/`.po`) — net-new HDL
- No HDD/SmartPort card exists in A2FPGA today (only `drive_ii`/`apple_disk` touch `drive_volume_if`).
- Port NanoApple2 `src/hdd.vhd` (+ `hdd_rom.vhd`) or write a small ProDOS block card: it drives the
  *same* `drive_volume_if` with `lba` = real ProDOS block, up to 32 blocks/req (16 KB cap). This is
  the cleanest demonstration of the volume protocol — raw 512 B blocks, no nibblization, LBA 1:1 to
  the `.hdv` file. Good early target.

## 3. PART 2 — MCU firmware (host build)

### 3.1 Sector-serving poll loop (model on `firmware_host/w5100.c:316-345`)
Per drive `v` in {0,1}:
```
rd = reg_read(VOL_RD[v]);  wr = reg_read(VOL_WR[v]);
if (rd|wr) {
  lba   = reg_read32(VOL_LBA[v]);          // 0x48-0x4B / 0x58-0x5B
  nblk  = reg_read(VOL_BLKCNT[v]) + 1;     // 0x4C / 0x5C
  if (rd) { f_lseek(&img[v], lba*512); f_read(buf, nblk*512);
            fpga_spi_xfer_write(FPGA_SPACE_SDRAM, TRACK_ADDR[v], buf, nblk*512); }
  if (wr) { fpga_spi_xfer_read (FPGA_SPACE_SDRAM, TRACK_ADDR[v], buf, nblk*512);
            f_lseek(&img[v], lba*512); f_write(buf, nblk*512); }
  reg_write(VOL_ACK[v], 1);                // 0x4F / 0x5F strobe
}
```
APIs already present: `fpga_spi_xfer_write/read(space,addr,data,len)` and `fpga_spi_reg_read/write`
in `firmware/fpga_spi.c:116-233`; `FPGA_SPACE_SDRAM=1` in `fpga_spi.h:18-22`. Run the loop in a
FreeRTOS task like `w5100_thread` (~1 kHz). At mount, write `size`, `mounted`, `readonly`, then
`ready` for each volume.

### 3.2 Dual backend via FatFS multi-volume
- Bump `FF_VOLUMES` 1→2 and set `FF_MULTI_PARTITION`/`FF_STR_VOLUME_ID` as needed in `ffconf.h`.
- `diskio.c` already routes by `pdrv`: `DEV_MMC=1` (implemented via `sdmm.c` over FPGA SPI tunnel,
  regs `SD_REG_CTRL/XFER/STATUS` 0x6C/6D/6E), `DEV_USB=2` (template stub today).
- Implement `USB_disk_*` against CherryUSB `usbh_msc` SCSI (`usbh_msc_scsi_read10/write10`,
  `usbh_msc_scsi_init`) — see `bouffalo_sdk/.../class/msc/usbh_msc.c` and the ready-made FatFS glue
  `bouffalo_sdk/.../fs/fatfs/port/fatfs_usbh.c::fatfs_usbh_driver_register()` which wires exactly
  these into `DEV_USB`.
- Runtime selection: prefer the USB stick if an MSC device is connected, else SD. Mount string
  `"0:"` (SD) or `"1:"` (USB); pick per-volume or via a config/scratch register.

### 3.3 Port device-build files into the host build
`firmware_host/` has **no** FatFS today. Copy from `firmware/`: `ff.c/ff.h/ffconf.h`, `diskio.c`,
`sdmm.c`, `fpga_sd.c/h`, plus `fpga_spi.*` if not shared. Add to `firmware_host/CMakeLists.txt`.

### 3.4 Enable USB host MSC
- `firmware_host/proj.conf`: add `set(CONFIG_CHERRYUSB_HOST_MSC 1)` (currently only XInput/CDC-ECM/
  RTL8152/ASIX are enabled).
- Add a `usbh_msc` connect/disconnect handler mirroring the XInput pattern
  (`firmware_host/main.c:253-268`): override the weak `usbh_msc_run()`/`usbh_msc_stop()` to call
  `fatfs_usbh_driver_register()` and `f_mount`/`f_unmount`, set a "USB present" flag for selection.

## 4. Risks / open items
- **Clock domains:** `drive_ii` on `clk_logic`; volume_if flags that cross into the SPI/controller
  domain need synchronizers (NanoApple2 does this in `floppy_track.sv`). The XFER/SDRAM CDC is
  already solved in `bl616_spi_connector`.
- **SDRAM contention:** track loads are rare (only on seek) and small (6656 B); MCU XFER is port 4.
  Low risk vs. video/Ensoniq.
- **BSRAM budget:** explicitly the reason we keep the track buffer in SDRAM. Target ~0 added BSRAM
  (GW2AR builds already run 42-46/46). The only BSRAM the disk path needs is the existing
  `diskii.hex` boot ROM in `apple_disk.sv`.
- **MCU-not-running gotcha:** when a PC is on the BL616 USB, our firmware may not run; with no MCU,
  volumes stay unmounted. Keep the disk FSM safe when `ready==0` (don't hang the Apple bus); rely on
  the existing `standalone_w` fallback for base boot.
- **FT2232 vs host build:** disk serving belongs in `firmware_host/` (USB host). The FT2232 device
  build can do SD-only serving but can't host a USB stick.
- **Write/seek latency:** assert drive "not ready"/busy during track swap so timing-sensitive copy
  protection still behaves; reads tolerate seek delay.
- **Format scope:** ship `.nib` (floppy) + `.hdv`/`.po` (block) first, matching NanoApple2. Defer
  `.dsk`/`.woz` (need format translation; `.woz` flux is a larger effort the Edwards core doesn't do).

## 5. Suggested phasing
1. **ProDOS `.hdv` block device** (net-new small HDD card + MCU SD serving) — no nibblization, proves
   the volume protocol end-to-end.
2. **`.nib` floppy, read-only** — un-stub `drive_ii` track-load FSM (B1, SDRAM window), MCU serves
   `track*13` from SD.
3. **Floppy writeback** — dirty-track flush.
4. **USB MSC backend** — port FatFS to host build, enable `usbh_msc`, dual SD/USB selection.

(No B2/BRAM phase — track buffer stays in SDRAM to keep BSRAM free.)
