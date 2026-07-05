// a2fpga_regs.h
// Register map and XFER memory spaces of the a2mega esp32_ospi_connector.
// Must match boards/a2mega/hdl/esp32/esp32_ospi_connector.sv — see
// boards/a2mega/docs/ESP32_ENHANCED_PORT.md for the protocol description.
#pragma once

// ---------------------------------------------------------------------------
// System registers (0x00-0x0F)
// ---------------------------------------------------------------------------
#define A2REG_DEVICE_ID0    0x00  // 'A'
#define A2REG_DEVICE_ID1    0x01  // '2'
#define A2REG_DEVICE_ID2    0x02  // 'F'
#define A2REG_DEVICE_ID3    0x03  // 'P'
#define A2REG_PROTO_VER     0x04
#define A2REG_CAPABILITIES  0x05
#define A2REG_SCRATCH0      0x06
#define A2REG_STATUS        0x07  // first read also latches "MCU alive" in the FPGA
#define A2REG_SYSTIME0      0x08  // 32-bit LE free-running cycle counter
#define A2REG_SCRATCH1      0x0C
#define A2REG_SCRATCH2      0x0D
#define A2REG_SCRATCH3      0x0E
#define A2REG_SCRATCH4      0x0F

// STATUS bits
#define A2STAT_READY        0x01
#define A2STAT_DDR3_READY   0x02
#define A2STAT_A2_RESET_N   0x04  // 1 = Apple II running (not held in reset)
#define A2STAT_VOL_PENDING  0x08  // floppy track request pending
#define A2STAT_HDD_PENDING  0x10  // HDD block request pending
#define A2STAT_U2_PENDING   0x20  // W5100 doorbell pending
#define A2STAT_PAD_PRESENT  0x40  // USB HID device present

// ---------------------------------------------------------------------------
// Video control (0x10-0x15)
// ---------------------------------------------------------------------------
#define A2REG_VIDEO_ENABLE  0x10  // [0] 1 = show OSD text overlay (menu/console)
#define A2REG_VIDEO_MODE    0x11
#define A2REG_TEXT_COLOR    0x12
#define A2REG_BG_COLOR      0x13
#define A2REG_BORDER_COLOR  0x14
#define A2REG_VIDEO_FLAGS   0x15

// ---------------------------------------------------------------------------
// USB HID readback (0x16-0x1B) — fed by the FPGA-fabric usb_hid_host
// ---------------------------------------------------------------------------
#define A2REG_PAD_STATUS    0x16  // [1:0] type (0/1/2/3 = none/kbd/mouse/pad),
                                  // [2] connerr, [7:4] report counter
#define A2REG_PAD_BTNS0     0x17  // bit0..7 = U,D,L,R,A,B,X,Y
#define A2REG_PAD_BTNS1     0x18  // bit0 SELECT, bit1 START, bits4-7 extra
#define A2REG_KEY_MOD       0x19
#define A2REG_KEY_0         0x1A
#define A2REG_KEY_1         0x1B

#define A2PAD_TYPE_NONE     0
#define A2PAD_TYPE_KBD      1
#define A2PAD_TYPE_MOUSE    2
#define A2PAD_TYPE_PAD      3

#define A2PAD_U             0x0001
#define A2PAD_D             0x0002
#define A2PAD_L             0x0004
#define A2PAD_R             0x0008
#define A2PAD_A             0x0010
#define A2PAD_B             0x0020
#define A2PAD_X             0x0040
#define A2PAD_Y             0x0080
#define A2PAD_SELECT        0x0100  // PAD_BTNS1 bit 0 << 8
#define A2PAD_START         0x0200  // PAD_BTNS1 bit 1 << 8

// ---------------------------------------------------------------------------
// ProDOS HDD compact bank (0x26-0x2D) — same layout as a2n20v2-Enhanced
// Reads:  REQ = {wr,rd}, LBA_L/H = requested ProDOS block
// Writes: CTL = {readonly,mounted,ready}, SIZE_L/H = volume size in blocks,
//         ACK = write-any strobe
// ---------------------------------------------------------------------------
#define A2REG_HDD_REQ(u)    ((u) ? 0x2A : 0x26)
#define A2REG_HDD_CTL(u)    ((u) ? 0x2A : 0x26)
#define A2REG_HDD_LBA_L(u)  ((u) ? 0x2B : 0x27)
#define A2REG_HDD_LBA_H(u)  ((u) ? 0x2C : 0x28)
#define A2REG_HDD_SIZE_L(u) ((u) ? 0x2B : 0x27)
#define A2REG_HDD_SIZE_H(u) ((u) ? 0x2C : 0x28)
#define A2REG_HDD_ACK(u)    ((u) ? 0x2D : 0x29)

#define A2HDD_CTL_READY     0x01
#define A2HDD_CTL_MOUNTED   0x02
#define A2HDD_CTL_READONLY  0x04
#define A2HDD_REQ_RD        0x01
#define A2HDD_REQ_WR        0x02

// Apple II reset release: write 1 after mounts are ready
#define A2REG_A2_RST_RELEASE 0x2E

// ---------------------------------------------------------------------------
// Slot configuration (0x30-0x33)
// ---------------------------------------------------------------------------
#define A2REG_SLOT_SELECT   0x30
#define A2REG_SLOT_CARD     0x31
#define A2REG_SLOT_STATUS   0x32
#define A2REG_SLOT_RECONFIG 0x33

// Card IDs (see slots.hex / top.sv parameters)
#define A2CARD_NONE         0
#define A2CARD_SUPERSPRITE  1
#define A2CARD_MOCKINGBOARD 2
#define A2CARD_SUPERSERIAL  3
#define A2CARD_DISK_II      4
#define A2CARD_UTHERNET2    5
#define A2CARD_HDD          6

// ---------------------------------------------------------------------------
// Disk II drive volumes (0x40-0x4F drive 0, 0x50-0x5F drive 1)
// ---------------------------------------------------------------------------
#define A2REG_VOL_BASE(d)   ((d) ? 0x50 : 0x40)
#define A2REG_VOL_READY(d)    (A2REG_VOL_BASE(d) + 0x0)
#define A2REG_VOL_ACTIVE(d)   (A2REG_VOL_BASE(d) + 0x1)
#define A2REG_VOL_MOUNTED(d)  (A2REG_VOL_BASE(d) + 0x2)
#define A2REG_VOL_READONLY(d) (A2REG_VOL_BASE(d) + 0x3)
#define A2REG_VOL_SIZE0(d)    (A2REG_VOL_BASE(d) + 0x4)   // 32-bit LE
#define A2REG_VOL_LBA0(d)     (A2REG_VOL_BASE(d) + 0x8)   // 32-bit LE (read)
#define A2REG_VOL_BLK_CNT(d)  (A2REG_VOL_BASE(d) + 0xC)
#define A2REG_VOL_CMD(d)      (A2REG_VOL_BASE(d) + 0xD)   // [0]=rd [1]=wr (read)
#define A2REG_VOL_ACK(d)      (A2REG_VOL_BASE(d) + 0xE)   // write-any strobe

#define A2VOL_CMD_RD        0x01
#define A2VOL_CMD_WR        0x02

// ---------------------------------------------------------------------------
// Uthernet2 (W5100) doorbell
// ---------------------------------------------------------------------------
#define A2REG_U2_DOORBELL   0x7A  // [3:0] per-socket Sn_CR pending; write-1-to-clear

// ---------------------------------------------------------------------------
// XFER memory spaces (reg 0x7F portal)
// ---------------------------------------------------------------------------
#define A2SPACE_TEST        0   // 2KB test memory
#define A2SPACE_OSD         1   // 2KB OSD text page, 40x24 screen codes at y*40+x
                                // (write-only from the ESP32 side)
#define A2SPACE_VRAM1       2   // 2KB reserved
#define A2SPACE_W5100       3   // 32KB W5100 address space (0x0000-0x7FFF)
#define A2SPACE_DISK        4   // 16KB: 2 x 8KB Disk II track windows
#define A2SPACE_HDD         5   // 1KB: 2 x 512B HDD block buffers

// SPACE 4/5 window geometry
#define A2DISK_WINDOW(d)    ((d) ? 0x2000u : 0x0000u)  // 8KB per drive
#define A2DISK_TRACK_BYTES  6656u                       // GCR nibbles per track
#define A2HDD_WINDOW(u)     ((u) ? 0x200u : 0x000u)     // 512B per unit
#define A2HDD_BLOCK_BYTES   512u
