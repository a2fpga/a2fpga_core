// Extended Octal SPI Connector for ESP32-S3 to FPGA communication
//
// Port of the a2n20v2-Enhanced BL616 co-processor contract to the a2mega's
// Octal SPI link. Provides:
//
// - 127 registers for configuration and status
// - Video control interface (video_control_if) — OSD overlay enable
// - Slot configuration (slotmaker_config_if)
// - Disk II drive volumes (drive_volume_if x2, regs 0x40-0x5F)
// - ProDOS HDD volumes (drive_volume_if x2, compact regs 0x26-0x2D)
// - Apple II reset hold/release policy (a2bus_control_if, reg 0x2E)
// - USB HID gamepad/keyboard readback (regs 0x16-0x1B, fed by the on-FPGA
//   usb_hid_host core so the ESP32 can drive the menu UI)
// - Uthernet2 (W5100) backing-store host link (XFER SPACE 3, doorbell 0x7A)
// - Disk track / HDD block BSRAM buffers (XFER SPACE 4 / 5) exposed to the
//   DiskII / HDD cards over mem_port_if
// - OSD text page (XFER SPACE 1, write-only) with a clk_pixel read port for
//   the osd_text_overlay renderer
// - F18A GPU interface (f18a_gpu_if)
//
// See boards/a2mega/docs/ESP32_OSPI_DESIGN.md and ESP32_ENHANCED_PORT.md for
// the register map and protocol details.
//
module esp32_ospi_connector #(
    parameter USE_SYNC    = 1,
    parameter USE_CRC     = 0,
    parameter IDLE_TO_CYC = 5_400_000,
    parameter CLOCK_SPEED_HZ = 54_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Octal SPI physical interface
    input  wire        sclk,
    input  wire [7:0]  data_i,
    output wire [7:0]  data_o,
    output wire        data_oe,

    // A2FPGA control interfaces
    slotmaker_config_if.controller slotmaker_config_if,
    f18a_gpu_if.slave f18a_gpu_if,
    video_control_if.control video_control_if,
    drive_volume_if.volume volumes[2],
    drive_volume_if.volume hdd_volumes[2],
    a2bus_control_if.control a2bus_control_if,

    // Disk II track window (SPACE 4) and HDD block window (SPACE 5), served
    // from internal BSRAM to the cards' mem_port_if clients
    mem_port_if.controller disk_ram_if,
    mem_port_if.controller hdd_ram_if,

    // System status inputs (clk domain)
    input  wire        ddr3_ready_i,
    input  wire        a2_reset_n_i,

    // USB HID readback (already synchronized into clk domain)
    input  wire [1:0]  pad_typ_i,        // 0 none, 1 kbd, 2 mouse, 3 gamepad
    input  wire        pad_connerr_i,
    input  wire [3:0]  pad_report_cnt_i, // increments on each full report
    input  wire [7:0]  pad_btns0_i,      // {Y,X,B,A,R,L,D,U}
    input  wire [7:0]  pad_btns1_i,      // {extra[3:0],2'b0,START,SELECT}
    input  wire [7:0]  key_mod_i,

    // Video-pipeline debug readback (regs 0x70-0x77). Quasi-static bytes,
    // sampled asynchronously — good enough for CLI inspection, not for
    // control flow.
    input  wire [7:0]  dbg_video_ss_i,      // soft-switch/mux snapshot
    input  wire [7:0]  dbg_c029_cnt_i,      // count of $C029 writes seen
    input  wire [7:0]  dbg_c029_last_i,     // last data written to $C029
    input  wire [7:0]  dbg_vgc_hsync_i,     // vgc_gen missed-hsync (per frame)
    input  wire [7:0]  dbg_shadow_drop_i,   // shadow write FIFO drops (sticky)
    input  wire [7:0]  dbg_fb_flags_i,      // framebuffer live status flags
    input  wire [7:0]  dbg_resp_ovfl_i,     // per-port CDC resp overflow (sticky)
    input  wire [7:0]  dbg_shadow_rd_i,     // apple_memory read FSM snapshot
    input  wire [7:0]  dbg_vgc_starved_i,   // vgc_gen stale-word swaps per frame

    // DDR3 debug read window (ddr3_debug_reader on idle port 4)
    output wire [20:0] dbg_mem_addr_o,
    output wire        dbg_mem_go_o,
    input  wire        dbg_mem_busy_i,
    input  wire [31:0] dbg_mem_data_i,
    input  wire [7:0]  key0_i,
    input  wire [7:0]  key1_i,

    // Uthernet2 (W5100) backing store — XFER SPACE 3 (port B of the card)
    output wire        w5100_host_wr,
    output wire [15:0] w5100_host_addr,
    output wire [7:0]  w5100_host_wdata,
    input  wire [7:0]  w5100_host_rdata,
    input  wire [3:0]  w5100_cmd_pending,  // doorbell bits from the card (reg 0x7A)
    output wire [3:0]  w5100_cmd_clr,      // write-1-to-clear (reg 0x7A write)

    // Misc
    output wire [39:0] scratch_o,          // {scratch4..scratch1, scratch0}
    output wire        mcu_ready_o,

    // OSD text page read port (osd_clk domain, quasi-static content)
    input  wire        osd_clk_i,
    input  wire [10:0] osd_addr_i,
    output reg  [7:0]  osd_data_o
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam [7:0] DEVICE_ID0 = "A";
    localparam [7:0] DEVICE_ID1 = "2";
    localparam [7:0] DEVICE_ID2 = "F";
    localparam [7:0] DEVICE_ID3 = "P";
    localparam [7:0] PROTO_VER  = 8'h01;
    wire [7:0] CAP0 = {6'b0, USE_CRC[0], 1'b1};

    // =========================================================================
    // Register Address Map
    // =========================================================================
    // System registers (0x00-0x0F)
    localparam REG_DEVICE_ID0   = 7'h00;
    localparam REG_DEVICE_ID1   = 7'h01;
    localparam REG_DEVICE_ID2   = 7'h02;
    localparam REG_DEVICE_ID3   = 7'h03;
    localparam REG_PROTO_VER    = 7'h04;
    localparam REG_CAPABILITIES = 7'h05;
    localparam REG_SCRATCH      = 7'h06;
    localparam REG_STATUS       = 7'h07;
    localparam REG_SYSTIME_0    = 7'h08;
    localparam REG_SYSTIME_1    = 7'h09;
    localparam REG_SYSTIME_2    = 7'h0A;
    localparam REG_SYSTIME_3    = 7'h0B;
    localparam REG_SCRATCH1     = 7'h0C;
    localparam REG_SCRATCH2     = 7'h0D;
    localparam REG_SCRATCH3     = 7'h0E;
    localparam REG_SCRATCH4     = 7'h0F;

    // Video control (0x10-0x15)
    localparam REG_VIDEO_ENABLE = 7'h10;
    localparam REG_VIDEO_MODE   = 7'h11;
    localparam REG_TEXT_COLOR   = 7'h12;
    localparam REG_BG_COLOR     = 7'h13;
    localparam REG_BORDER_COLOR = 7'h14;
    localparam REG_VIDEO_FLAGS  = 7'h15;

    // USB HID readback (0x16-0x1B)
    localparam REG_PAD_STATUS   = 7'h16;
    localparam REG_PAD_BTNS0    = 7'h17;
    localparam REG_PAD_BTNS1    = 7'h18;
    localparam REG_KEY_MOD      = 7'h19;
    localparam REG_KEY_0        = 7'h1A;
    localparam REG_KEY_1        = 7'h1B;

    // ProDOS HDD compact bank (0x26-0x2D) + reset release (0x2E) — same
    // addresses as the a2n20v2-Enhanced BL616 map
    localparam REG_HDD0_REQ_CTL = 7'h26;   // R: {wr,rd}  W: {readonly,mounted,ready}
    localparam REG_HDD0_LBA_L   = 7'h27;   // R: lba[7:0]   W: size[7:0]
    localparam REG_HDD0_LBA_H   = 7'h28;   // R: lba[15:8]  W: size[15:8]
    localparam REG_HDD0_ACK     = 7'h29;   // W: ack strobe (write-any)
    localparam REG_HDD1_REQ_CTL = 7'h2A;
    localparam REG_HDD1_LBA_L   = 7'h2B;
    localparam REG_HDD1_LBA_H   = 7'h2C;
    localparam REG_HDD1_ACK     = 7'h2D;
    localparam REG_A2_RST_RELEASE = 7'h2E;

    // Slot configuration (0x30-0x3F)
    localparam REG_SLOT_SELECT  = 7'h30;
    localparam REG_SLOT_CARD    = 7'h31;
    localparam REG_SLOT_STATUS  = 7'h32;
    localparam REG_SLOT_RECONFIG= 7'h33;

    // DDR3 debug read window (idle port 4, absolute word addresses)
    localparam REG_DBG_MEM_A0   = 7'h34;  // W/R addr[7:0]
    localparam REG_DBG_MEM_A1   = 7'h35;  // W/R addr[15:8]
    localparam REG_DBG_MEM_A2   = 7'h36;  // W/R addr[20:16]
    localparam REG_DBG_MEM_GO   = 7'h37;  // W: strobe read; R: {7'b0, busy}
    localparam REG_DBG_MEM_D0   = 7'h38;  // R data[7:0]
    localparam REG_DBG_MEM_D1   = 7'h39;  // R data[15:8]
    localparam REG_DBG_MEM_D2   = 7'h3A;  // R data[23:16]
    localparam REG_DBG_MEM_D3   = 7'h3B;  // R data[31:24]; addr auto-incs
                                          // when each read completes

    // Drive 0 (0x40-0x4F)
    localparam REG_VOL0_READY   = 7'h40;
    localparam REG_VOL0_ACTIVE  = 7'h41;
    localparam REG_VOL0_MOUNTED = 7'h42;
    localparam REG_VOL0_READONLY= 7'h43;
    localparam REG_VOL0_SIZE_0  = 7'h44;
    localparam REG_VOL0_SIZE_1  = 7'h45;
    localparam REG_VOL0_SIZE_2  = 7'h46;
    localparam REG_VOL0_SIZE_3  = 7'h47;
    localparam REG_VOL0_LBA_0   = 7'h48;
    localparam REG_VOL0_LBA_1   = 7'h49;
    localparam REG_VOL0_LBA_2   = 7'h4A;
    localparam REG_VOL0_LBA_3   = 7'h4B;
    localparam REG_VOL0_BLK_CNT = 7'h4C;
    localparam REG_VOL0_CMD     = 7'h4D;
    localparam REG_VOL0_ACK     = 7'h4E;

    // Drive 1 (0x50-0x5F)
    localparam REG_VOL1_READY   = 7'h50;
    localparam REG_VOL1_ACTIVE  = 7'h51;
    localparam REG_VOL1_MOUNTED = 7'h52;
    localparam REG_VOL1_READONLY= 7'h53;
    localparam REG_VOL1_SIZE_0  = 7'h54;
    localparam REG_VOL1_SIZE_1  = 7'h55;
    localparam REG_VOL1_SIZE_2  = 7'h56;
    localparam REG_VOL1_SIZE_3  = 7'h57;
    localparam REG_VOL1_LBA_0   = 7'h58;
    localparam REG_VOL1_LBA_1   = 7'h59;
    localparam REG_VOL1_LBA_2   = 7'h5A;
    localparam REG_VOL1_LBA_3   = 7'h5B;
    localparam REG_VOL1_BLK_CNT = 7'h5C;
    localparam REG_VOL1_CMD     = 7'h5D;
    localparam REG_VOL1_ACK     = 7'h5E;

    // F18A GPU (0x60-0x6F)
    localparam REG_GPU_CONTROL  = 7'h60;
    localparam REG_GPU_STATUS   = 7'h61;
    localparam REG_GPU_PC_L     = 7'h62;
    localparam REG_GPU_PC_H     = 7'h63;
    localparam REG_GPU_VADDR_L  = 7'h64;
    localparam REG_GPU_VADDR_H  = 7'h65;
    localparam REG_GPU_VDATA    = 7'h66;
    localparam REG_GPU_PADDR    = 7'h67;
    localparam REG_GPU_PDATA_L  = 7'h68;
    localparam REG_GPU_PDATA_H  = 7'h69;
    localparam REG_GPU_RADDR_L  = 7'h6A;
    localparam REG_GPU_RADDR_H  = 7'h6B;
    localparam REG_GPU_RDATA    = 7'h6C;
    localparam REG_GPU_SCANLINE = 7'h6D;
    localparam REG_GPU_BLANK    = 7'h6E;
    localparam REG_GPU_GSTATUS  = 7'h6F;

    // Uthernet2 (0x7A)
    // Video-pipeline debug readback (read-only)
    localparam REG_DBG_VIDEO_SS   = 7'h70;  // {use_vgc,SHRG,LINEAR,STORE80,PAGE2,MIXED,HIRES,TEXT}
    localparam REG_DBG_C029_CNT   = 7'h71;
    localparam REG_DBG_C029_LAST  = 7'h72;
    localparam REG_DBG_VGC_HSYNC  = 7'h73;
    localparam REG_DBG_SHADOW_DROP= 7'h74;
    localparam REG_DBG_FB_FLAGS   = 7'h75;
    localparam REG_DBG_RESP_OVFL  = 7'h76;  // bit n = DDR3 port n resp-FIFO overflow
    localparam REG_DBG_SHADOW_RD  = 7'h77;  // {vid_req,is_vgc,cache_valid,vgc_req,0,rd_state}
    localparam REG_DBG_VGC_STARVED= 7'h78;  // vgc stale-word swaps per frame

    localparam REG_U2_DOORBELL  = 7'h7A;

    // Memory spaces (XFER via reg 0x7F)
    localparam SPACE_TEST  = 3'd0;
    localparam SPACE_OSD   = 3'd1;   // OSD text page (write-only from ESP32)
    localparam SPACE_VRAM1 = 3'd2;
    localparam SPACE_W5100 = 3'd3;
    localparam SPACE_DISK  = 3'd4;   // Disk II track buffers, addr[13]=drive
    localparam SPACE_HDD   = 3'd5;   // HDD block buffers, addr[9]=unit

    // =========================================================================
    // Protocol Processor Interface
    // =========================================================================
    wire        reg_wr_req;
    wire        reg_rd_req;
    wire [6:0]  reg_idx;
    wire [7:0]  reg_wdata;
    reg  [7:0]  reg_rdata;

    wire        mem_wr_en;
    wire [2:0]  mem_space;
    wire [23:0] mem_wr_addr;
    wire [7:0]  mem_wr_data;

    wire        mem_rd_req;
    wire [2:0]  mem_rd_space;
    wire [23:0] mem_rd_addr;
    reg         mem_rd_valid;
    reg  [7:0]  mem_rd_data;

    // =========================================================================
    // Internal Registers
    // =========================================================================

    // System
    reg [7:0] scratch_r;
    reg [7:0] scratch1_r, scratch2_r, scratch3_r, scratch4_r;
    reg [31:0] sys_time_r;

    // Video control
    reg        video_enable_r;
    reg [7:0]  video_mode_r;      // TEXT,MIXED,PAGE2,HIRES,AN3,STORE80,COL80,ALTCHAR
    reg [3:0]  text_color_r;
    reg [3:0]  bg_color_r;
    reg [3:0]  border_color_r;
    reg [7:0]  video_flags_r;     // MONO,MONO_DHIRES,SHRG

    // Slot configuration
    reg [2:0]  slot_select_r;
    reg [7:0]  slot_card_r;
    reg        slot_wr_r;         // one-shot: latch card_r into slot_select_r
    reg        slot_reconfig_r;   // one-shot: re-run the slotmaker config sweep

    // Disk II drive volumes
    reg        vol_ready_r[2];
    reg        vol_mounted_r[2];
    reg        vol_readonly_r[2];
    reg [31:0] vol_size_r[2];
    reg        vol_ack_r[2];      // one-shot strobe

    // DDR3 debug read window
    reg [20:0] dbg_mem_addr_r;
    reg        dbg_mem_go_r;       // one-shot strobe to ddr3_debug_reader
    reg        dbg_mem_busy_d_r;   // busy edge detect for addr auto-inc
    assign dbg_mem_addr_o = dbg_mem_addr_r;
    assign dbg_mem_go_o   = dbg_mem_go_r;

    // ProDOS HDD volumes
    reg        hdd_ready_r[2];
    reg        hdd_mounted_r[2];
    reg        hdd_readonly_r[2];
    reg [15:0] hdd_size_r[2];
    reg        hdd_ack_r[2];      // one-shot strobe

    // Apple II reset release
    reg        a2_rst_release_r;

    // W5100 doorbell clear
    reg [3:0]  w5100_cmd_clr_r;

    // F18A GPU
    reg        gpu_trigger_r;
    reg        gpu_pause_r;
    reg [15:0] gpu_load_pc_r;
    reg [13:0] gpu_vaddr_r;
    reg [7:0]  gpu_vdata_r;
    reg        gpu_vwe_r;
    reg [5:0]  gpu_paddr_r;
    reg [11:0] gpu_pdata_r;
    reg        gpu_pwe_r;
    reg [13:0] gpu_raddr_r;
    reg [7:0]  gpu_rdata_r;
    reg        gpu_rwe_r;

    assign scratch_o = {scratch4_r, scratch3_r, scratch2_r, scratch1_r, scratch_r};

    // =========================================================================
    // System timer
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sys_time_r <= 32'd0;
        else        sys_time_r <= sys_time_r + 32'd1;
    end

    // =========================================================================
    // MCU ready detection — latches on first STATUS register read
    // =========================================================================
    reg mcu_ready_r;
    assign mcu_ready_o = mcu_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mcu_ready_r <= 1'b0;
        else if (reg_rd_req && reg_idx == REG_STATUS)
            mcu_ready_r <= 1'b1;
    end

    // =========================================================================
    // Apple II reset hold/release policy (from bl616_spi_connector)
    // =========================================================================
    // Hold the Apple II in RESET from power-on so the ESP32 can bring up SD
    // storage before the autoboot slot scan runs. Release when:
    //   - the ESP32 writes A2_RST_RELEASE (0x2E) after its mounts complete, or
    //   - no ESP32 shows up on the link within RST_MCU_ALIVE_WAIT, or
    //   - the absolute backstop expires (ESP32 alive but never released).
    localparam RST_MCU_ALIVE_WAIT = CLOCK_SPEED_HZ * 3;   // MCU first link contact
    localparam RST_HOLD_BACKSTOP  = CLOCK_SPEED_HZ * 15;  // never hold forever
    localparam RST_CW = $clog2(RST_HOLD_BACKSTOP + 1);
    reg [RST_CW-1:0]  rst_hold_cnt_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_hold_cnt_r <= '0;
        else if (rst_hold_cnt_r < RST_HOLD_BACKSTOP[RST_CW-1:0])
            rst_hold_cnt_r <= rst_hold_cnt_r + 1'b1;
    end
    wire rst_mcu_absent_w = !mcu_ready_r &&
                            (rst_hold_cnt_r >= RST_MCU_ALIVE_WAIT[RST_CW-1:0]);
    assign a2bus_control_if.reset_hold =
        !(a2_rst_release_r || rst_mcu_absent_w ||
          rst_hold_cnt_r >= RST_HOLD_BACKSTOP[RST_CW-1:0]);
    assign a2bus_control_if.ready = 1'b1;

    // =========================================================================
    // Memory Spaces — using Gowin BSRAM inference pattern
    // =========================================================================

    // Space 0: Test memory (64B, FF-based — kept tiny so it does not spend a
    // BSRAM; the device is close to its BSRAM limit)
    reg [7:0] mem0 [0:63];

    // Space 1: OSD text page (2KB, 40x24 Apple II screen codes at y*40+x).
    // Port A: ESP32 XFER writes (write-only — XFER reads of SPACE 1 return
    // 0xFF because port B is dedicated to the clk_pixel OSD renderer).
    reg [7:0] osd_vram [0:2047] /* synthesis syn_ramstyle = "block_ram" */;

    // Space 2 (text VRAM bank 1) is unimplemented — reads return 0xFF.

    // =========================================================================
    // Video Control Interface Outputs
    // =========================================================================
    assign video_control_if.enable = video_enable_r;
    assign video_control_if.TEXT_MODE = video_mode_r[0];
    assign video_control_if.MIXED_MODE = video_mode_r[1];
    assign video_control_if.PAGE2 = video_mode_r[2];
    assign video_control_if.HIRES_MODE = video_mode_r[3];
    assign video_control_if.AN3 = video_mode_r[4];
    assign video_control_if.STORE80 = video_mode_r[5];
    assign video_control_if.COL80 = video_mode_r[6];
    assign video_control_if.ALTCHAR = video_mode_r[7];
    assign video_control_if.TEXT_COLOR = text_color_r;
    assign video_control_if.BACKGROUND_COLOR = bg_color_r;
    assign video_control_if.BORDER_COLOR = border_color_r;
    assign video_control_if.MONOCHROME_MODE = video_flags_r[0];
    assign video_control_if.MONOCHROME_DHIRES_MODE = video_flags_r[1];
    assign video_control_if.SHRG_MODE = video_flags_r[2];

    // =========================================================================
    // Slotmaker Interface Outputs
    // =========================================================================
    assign slotmaker_config_if.slot = slot_select_r;
    assign slotmaker_config_if.card_i = slot_card_r;
    assign slotmaker_config_if.wr = slot_wr_r;
    assign slotmaker_config_if.reconfig = slot_reconfig_r;

    // =========================================================================
    // Drive Volume Interface Outputs
    // =========================================================================
    assign volumes[0].ready = vol_ready_r[0];
    assign volumes[0].mounted = vol_mounted_r[0];
    assign volumes[0].readonly = vol_readonly_r[0];
    assign volumes[0].size = vol_size_r[0];
    assign volumes[0].ack = vol_ack_r[0];

    assign volumes[1].ready = vol_ready_r[1];
    assign volumes[1].mounted = vol_mounted_r[1];
    assign volumes[1].readonly = vol_readonly_r[1];
    assign volumes[1].size = vol_size_r[1];
    assign volumes[1].ack = vol_ack_r[1];

    assign hdd_volumes[0].ready = hdd_ready_r[0];
    assign hdd_volumes[0].mounted = hdd_mounted_r[0];
    assign hdd_volumes[0].readonly = hdd_readonly_r[0];
    assign hdd_volumes[0].size = {16'b0, hdd_size_r[0]};
    assign hdd_volumes[0].ack = hdd_ack_r[0];

    assign hdd_volumes[1].ready = hdd_ready_r[1];
    assign hdd_volumes[1].mounted = hdd_mounted_r[1];
    assign hdd_volumes[1].readonly = hdd_readonly_r[1];
    assign hdd_volumes[1].size = {16'b0, hdd_size_r[1]};
    assign hdd_volumes[1].ack = hdd_ack_r[1];

    // =========================================================================
    // F18A GPU Interface Outputs
    // =========================================================================
    assign f18a_gpu_if.running = 1'b0;  // We don't run the GPU, just access its memory
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = gpu_vwe_r;
    assign f18a_gpu_if.vaddr = gpu_vaddr_r;
    assign f18a_gpu_if.vdout = gpu_vdata_r;
    assign f18a_gpu_if.pwe = gpu_pwe_r;
    assign f18a_gpu_if.paddr = gpu_paddr_r;
    assign f18a_gpu_if.pdout = gpu_pdata_r;
    assign f18a_gpu_if.rwe = gpu_rwe_r;
    assign f18a_gpu_if.raddr = gpu_raddr_r;
    assign f18a_gpu_if.gstatus = 7'b0;

    // =========================================================================
    // System status byte
    // =========================================================================
    wire vol_pending_w = volumes[0].rd | volumes[0].wr | volumes[1].rd | volumes[1].wr;
    wire hdd_pending_w = hdd_volumes[0].rd | hdd_volumes[0].wr |
                         hdd_volumes[1].rd | hdd_volumes[1].wr;
    wire [7:0] status_w = {
        1'b0,
        pad_typ_i != 2'd0,          // [6] HID device present
        |w5100_cmd_pending,         // [5] W5100 doorbell pending
        hdd_pending_w,              // [4] HDD request pending
        vol_pending_w,              // [3] floppy request pending
        a2_reset_n_i,               // [2] Apple II RESET line (1 = running)
        ddr3_ready_i,               // [1] DDR3 calibration complete
        1'b1                        // [0] ready
    };

    // =========================================================================
    // Register Read Multiplexer
    // =========================================================================
    always @* begin
        case (reg_idx)
            // System registers
            REG_DEVICE_ID0:   reg_rdata = DEVICE_ID0;
            REG_DEVICE_ID1:   reg_rdata = DEVICE_ID1;
            REG_DEVICE_ID2:   reg_rdata = DEVICE_ID2;
            REG_DEVICE_ID3:   reg_rdata = DEVICE_ID3;
            REG_PROTO_VER:    reg_rdata = PROTO_VER;
            REG_CAPABILITIES: reg_rdata = CAP0;
            REG_SCRATCH:      reg_rdata = scratch_r;
            REG_STATUS:       reg_rdata = status_w;
            REG_SYSTIME_0:    reg_rdata = sys_time_r[7:0];
            REG_SYSTIME_1:    reg_rdata = sys_time_r[15:8];
            REG_SYSTIME_2:    reg_rdata = sys_time_r[23:16];
            REG_SYSTIME_3:    reg_rdata = sys_time_r[31:24];
            REG_SCRATCH1:     reg_rdata = scratch1_r;
            REG_SCRATCH2:     reg_rdata = scratch2_r;
            REG_SCRATCH3:     reg_rdata = scratch3_r;
            REG_SCRATCH4:     reg_rdata = scratch4_r;

            // Video control
            REG_VIDEO_ENABLE: reg_rdata = {7'b0, video_enable_r};
            REG_VIDEO_MODE:   reg_rdata = video_mode_r;
            REG_TEXT_COLOR:   reg_rdata = {4'b0, text_color_r};
            REG_BG_COLOR:     reg_rdata = {4'b0, bg_color_r};
            REG_BORDER_COLOR: reg_rdata = {4'b0, border_color_r};
            REG_VIDEO_FLAGS:  reg_rdata = video_flags_r;

            // USB HID readback
            REG_PAD_STATUS:   reg_rdata = {pad_report_cnt_i, 1'b0, pad_connerr_i, pad_typ_i};
            REG_PAD_BTNS0:    reg_rdata = pad_btns0_i;
            REG_PAD_BTNS1:    reg_rdata = pad_btns1_i;
            REG_KEY_MOD:      reg_rdata = key_mod_i;
            REG_KEY_0:        reg_rdata = key0_i;
            REG_KEY_1:        reg_rdata = key1_i;

            // DDR3 debug read window
            REG_DBG_MEM_A0:   reg_rdata = dbg_mem_addr_r[7:0];
            REG_DBG_MEM_A1:   reg_rdata = dbg_mem_addr_r[15:8];
            REG_DBG_MEM_A2:   reg_rdata = {3'b0, dbg_mem_addr_r[20:16]};
            REG_DBG_MEM_GO:   reg_rdata = {7'b0, dbg_mem_busy_i};
            REG_DBG_MEM_D0:   reg_rdata = dbg_mem_data_i[7:0];
            REG_DBG_MEM_D1:   reg_rdata = dbg_mem_data_i[15:8];
            REG_DBG_MEM_D2:   reg_rdata = dbg_mem_data_i[23:16];
            REG_DBG_MEM_D3:   reg_rdata = dbg_mem_data_i[31:24];

            // Video-pipeline debug readback
            REG_DBG_VIDEO_SS:   reg_rdata = dbg_video_ss_i;
            REG_DBG_C029_CNT:   reg_rdata = dbg_c029_cnt_i;
            REG_DBG_C029_LAST:  reg_rdata = dbg_c029_last_i;
            REG_DBG_VGC_HSYNC:  reg_rdata = dbg_vgc_hsync_i;
            REG_DBG_SHADOW_DROP:reg_rdata = dbg_shadow_drop_i;
            REG_DBG_FB_FLAGS:   reg_rdata = dbg_fb_flags_i;
            REG_DBG_RESP_OVFL:  reg_rdata = dbg_resp_ovfl_i;
            REG_DBG_SHADOW_RD:  reg_rdata = dbg_shadow_rd_i;
            REG_DBG_VGC_STARVED: reg_rdata = dbg_vgc_starved_i;

            // ProDOS HDD compact bank
            REG_HDD0_REQ_CTL: reg_rdata = {6'b0, hdd_volumes[0].wr, hdd_volumes[0].rd};
            REG_HDD0_LBA_L:   reg_rdata = hdd_volumes[0].lba[7:0];
            REG_HDD0_LBA_H:   reg_rdata = hdd_volumes[0].lba[15:8];
            REG_HDD1_REQ_CTL: reg_rdata = {6'b0, hdd_volumes[1].wr, hdd_volumes[1].rd};
            REG_HDD1_LBA_L:   reg_rdata = hdd_volumes[1].lba[7:0];
            REG_HDD1_LBA_H:   reg_rdata = hdd_volumes[1].lba[15:8];

            REG_A2_RST_RELEASE: reg_rdata = {7'b0, a2_rst_release_r};

            // Slot configuration
            REG_SLOT_SELECT:  reg_rdata = {5'b0, slot_select_r};
            REG_SLOT_CARD:    reg_rdata = slot_card_r;
            REG_SLOT_STATUS:  reg_rdata = slotmaker_config_if.card_o;
            REG_SLOT_RECONFIG:reg_rdata = {7'b0, slot_reconfig_r};

            // Drive 0
            REG_VOL0_READY:   reg_rdata = {7'b0, vol_ready_r[0]};
            REG_VOL0_ACTIVE:  reg_rdata = {7'b0, volumes[0].active};
            REG_VOL0_MOUNTED: reg_rdata = {7'b0, vol_mounted_r[0]};
            REG_VOL0_READONLY:reg_rdata = {7'b0, vol_readonly_r[0]};
            REG_VOL0_SIZE_0:  reg_rdata = vol_size_r[0][7:0];
            REG_VOL0_SIZE_1:  reg_rdata = vol_size_r[0][15:8];
            REG_VOL0_SIZE_2:  reg_rdata = vol_size_r[0][23:16];
            REG_VOL0_SIZE_3:  reg_rdata = vol_size_r[0][31:24];
            REG_VOL0_LBA_0:   reg_rdata = volumes[0].lba[7:0];
            REG_VOL0_LBA_1:   reg_rdata = volumes[0].lba[15:8];
            REG_VOL0_LBA_2:   reg_rdata = volumes[0].lba[23:16];
            REG_VOL0_LBA_3:   reg_rdata = volumes[0].lba[31:24];
            REG_VOL0_BLK_CNT: reg_rdata = {2'b0, volumes[0].blk_cnt};
            REG_VOL0_CMD:     reg_rdata = {6'b0, volumes[0].wr, volumes[0].rd};
            REG_VOL0_ACK:     reg_rdata = 8'h00;

            // Drive 1
            REG_VOL1_READY:   reg_rdata = {7'b0, vol_ready_r[1]};
            REG_VOL1_ACTIVE:  reg_rdata = {7'b0, volumes[1].active};
            REG_VOL1_MOUNTED: reg_rdata = {7'b0, vol_mounted_r[1]};
            REG_VOL1_READONLY:reg_rdata = {7'b0, vol_readonly_r[1]};
            REG_VOL1_SIZE_0:  reg_rdata = vol_size_r[1][7:0];
            REG_VOL1_SIZE_1:  reg_rdata = vol_size_r[1][15:8];
            REG_VOL1_SIZE_2:  reg_rdata = vol_size_r[1][23:16];
            REG_VOL1_SIZE_3:  reg_rdata = vol_size_r[1][31:24];
            REG_VOL1_LBA_0:   reg_rdata = volumes[1].lba[7:0];
            REG_VOL1_LBA_1:   reg_rdata = volumes[1].lba[15:8];
            REG_VOL1_LBA_2:   reg_rdata = volumes[1].lba[23:16];
            REG_VOL1_LBA_3:   reg_rdata = volumes[1].lba[31:24];
            REG_VOL1_BLK_CNT: reg_rdata = {2'b0, volumes[1].blk_cnt};
            REG_VOL1_CMD:     reg_rdata = {6'b0, volumes[1].wr, volumes[1].rd};
            REG_VOL1_ACK:     reg_rdata = 8'h00;

            // F18A GPU
            REG_GPU_CONTROL:  reg_rdata = {6'b0, gpu_pause_r, gpu_trigger_r};
            REG_GPU_STATUS:   reg_rdata = {6'b0, f18a_gpu_if.pause_ack, f18a_gpu_if.running};
            REG_GPU_PC_L:     reg_rdata = gpu_load_pc_r[7:0];
            REG_GPU_PC_H:     reg_rdata = gpu_load_pc_r[15:8];
            REG_GPU_VADDR_L:  reg_rdata = gpu_vaddr_r[7:0];
            REG_GPU_VADDR_H:  reg_rdata = {2'b0, gpu_vaddr_r[13:8]};
            REG_GPU_VDATA:    reg_rdata = f18a_gpu_if.vdin;
            REG_GPU_PADDR:    reg_rdata = {2'b0, gpu_paddr_r};
            REG_GPU_PDATA_L:  reg_rdata = gpu_pdata_r[7:0];
            REG_GPU_PDATA_H:  reg_rdata = {4'b0, gpu_pdata_r[11:8]};
            REG_GPU_RADDR_L:  reg_rdata = gpu_raddr_r[7:0];
            REG_GPU_RADDR_H:  reg_rdata = {2'b0, gpu_raddr_r[13:8]};
            REG_GPU_RDATA:    reg_rdata = f18a_gpu_if.rdin;
            REG_GPU_SCANLINE: reg_rdata = f18a_gpu_if.scanline;
            REG_GPU_BLANK:    reg_rdata = {7'b0, f18a_gpu_if.blank};
            REG_GPU_GSTATUS:  reg_rdata = {1'b0, f18a_gpu_if.gstatus};

            // Uthernet2
            REG_U2_DOORBELL:  reg_rdata = {4'b0, w5100_cmd_pending};

            default: reg_rdata = 8'hFF;
        endcase
    end

    // =========================================================================
    // Register Write Logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch_r <= 8'h00;
            scratch1_r <= 8'h00;
            scratch2_r <= 8'h00;
            scratch3_r <= 8'h00;
            scratch4_r <= 8'h00;
            video_enable_r <= 1'b0;
            video_mode_r <= 8'b00010001;  // TEXT_MODE=1, AN3=1
            text_color_r <= 4'd15;
            bg_color_r <= 4'd2;
            border_color_r <= 4'd2;
            video_flags_r <= 8'h00;
            slot_select_r <= 3'd0;
            slot_card_r <= 8'h00;
            slot_wr_r <= 1'b0;
            slot_reconfig_r <= 1'b0;
            vol_ready_r[0] <= 1'b0;
            vol_ready_r[1] <= 1'b0;
            vol_mounted_r[0] <= 1'b0;
            vol_mounted_r[1] <= 1'b0;
            vol_readonly_r[0] <= 1'b0;
            vol_readonly_r[1] <= 1'b0;
            vol_size_r[0] <= 32'h0;
            vol_size_r[1] <= 32'h0;
            vol_ack_r[0] <= 1'b0;
            vol_ack_r[1] <= 1'b0;
            hdd_ready_r[0] <= 1'b0;
            hdd_ready_r[1] <= 1'b0;
            hdd_mounted_r[0] <= 1'b0;
            hdd_mounted_r[1] <= 1'b0;
            hdd_readonly_r[0] <= 1'b0;
            hdd_readonly_r[1] <= 1'b0;
            hdd_size_r[0] <= 16'h0;
            hdd_size_r[1] <= 16'h0;
            hdd_ack_r[0] <= 1'b0;
            hdd_ack_r[1] <= 1'b0;
            a2_rst_release_r <= 1'b0;
            w5100_cmd_clr_r <= 4'b0;
            gpu_trigger_r <= 1'b0;
            gpu_pause_r <= 1'b0;
            gpu_load_pc_r <= 16'h0;
            gpu_vaddr_r <= 14'h0;
            gpu_vdata_r <= 8'h0;
            gpu_vwe_r <= 1'b0;
            gpu_paddr_r <= 6'h0;
            gpu_pdata_r <= 12'h0;
            gpu_pwe_r <= 1'b0;
            gpu_raddr_r <= 14'h0;
            gpu_rdata_r <= 8'h0;
            gpu_rwe_r <= 1'b0;
            dbg_mem_addr_r <= 21'h0;
            dbg_mem_go_r <= 1'b0;
            dbg_mem_busy_d_r <= 1'b0;
        end else begin
            // Clear one-shot registers
            slot_wr_r <= 1'b0;
            slot_reconfig_r <= 1'b0;
            dbg_mem_go_r <= 1'b0;

            // DDR3 debug window: auto-increment the address when a read
            // completes (busy falling edge) so streaming needs no re-address
            dbg_mem_busy_d_r <= dbg_mem_busy_i;
            if (dbg_mem_busy_d_r && !dbg_mem_busy_i)
                dbg_mem_addr_r <= dbg_mem_addr_r + 21'd1;
            vol_ack_r[0] <= 1'b0;
            vol_ack_r[1] <= 1'b0;
            hdd_ack_r[0] <= 1'b0;
            hdd_ack_r[1] <= 1'b0;
            w5100_cmd_clr_r <= 4'b0;
            gpu_vwe_r <= 1'b0;
            gpu_pwe_r <= 1'b0;
            gpu_rwe_r <= 1'b0;

            if (reg_wr_req) begin
                case (reg_idx)
                    REG_SCRATCH:      scratch_r <= reg_wdata;
                    REG_SCRATCH1:     scratch1_r <= reg_wdata;
                    REG_SCRATCH2:     scratch2_r <= reg_wdata;
                    REG_SCRATCH3:     scratch3_r <= reg_wdata;
                    REG_SCRATCH4:     scratch4_r <= reg_wdata;

                    REG_VIDEO_ENABLE: video_enable_r <= reg_wdata[0];
                    REG_VIDEO_MODE:   video_mode_r <= reg_wdata;
                    REG_TEXT_COLOR:   text_color_r <= reg_wdata[3:0];
                    REG_BG_COLOR:     bg_color_r <= reg_wdata[3:0];
                    REG_BORDER_COLOR: border_color_r <= reg_wdata[3:0];
                    REG_VIDEO_FLAGS:  video_flags_r <= reg_wdata;

                    REG_HDD0_REQ_CTL: begin
                        hdd_ready_r[0]    <= reg_wdata[0];
                        hdd_mounted_r[0]  <= reg_wdata[1];
                        hdd_readonly_r[0] <= reg_wdata[2];
                    end
                    REG_HDD0_LBA_L:   hdd_size_r[0][7:0]  <= reg_wdata;
                    REG_HDD0_LBA_H:   hdd_size_r[0][15:8] <= reg_wdata;
                    REG_HDD0_ACK:     hdd_ack_r[0] <= 1'b1;
                    REG_HDD1_REQ_CTL: begin
                        hdd_ready_r[1]    <= reg_wdata[0];
                        hdd_mounted_r[1]  <= reg_wdata[1];
                        hdd_readonly_r[1] <= reg_wdata[2];
                    end
                    REG_HDD1_LBA_L:   hdd_size_r[1][7:0]  <= reg_wdata;
                    REG_HDD1_LBA_H:   hdd_size_r[1][15:8] <= reg_wdata;
                    REG_HDD1_ACK:     hdd_ack_r[1] <= 1'b1;

                    REG_A2_RST_RELEASE: a2_rst_release_r <= reg_wdata[0];

                    REG_SLOT_SELECT:  slot_select_r <= reg_wdata[2:0];
                    REG_SLOT_CARD: begin
                        slot_card_r <= reg_wdata;
                        slot_wr_r <= 1'b1;   // latch into the slot table now
                    end
                    REG_SLOT_RECONFIG:slot_reconfig_r <= reg_wdata[0];

                    REG_DBG_MEM_A0:   dbg_mem_addr_r[7:0]   <= reg_wdata;
                    REG_DBG_MEM_A1:   dbg_mem_addr_r[15:8]  <= reg_wdata;
                    REG_DBG_MEM_A2:   dbg_mem_addr_r[20:16] <= reg_wdata[4:0];
                    REG_DBG_MEM_GO:   dbg_mem_go_r <= 1'b1;

                    REG_VOL0_READY:   vol_ready_r[0] <= reg_wdata[0];
                    REG_VOL0_MOUNTED: vol_mounted_r[0] <= reg_wdata[0];
                    REG_VOL0_READONLY:vol_readonly_r[0] <= reg_wdata[0];
                    REG_VOL0_SIZE_0:  vol_size_r[0][7:0] <= reg_wdata;
                    REG_VOL0_SIZE_1:  vol_size_r[0][15:8] <= reg_wdata;
                    REG_VOL0_SIZE_2:  vol_size_r[0][23:16] <= reg_wdata;
                    REG_VOL0_SIZE_3:  vol_size_r[0][31:24] <= reg_wdata;
                    REG_VOL0_ACK:     vol_ack_r[0] <= 1'b1;   // one-shot strobe

                    REG_VOL1_READY:   vol_ready_r[1] <= reg_wdata[0];
                    REG_VOL1_MOUNTED: vol_mounted_r[1] <= reg_wdata[0];
                    REG_VOL1_READONLY:vol_readonly_r[1] <= reg_wdata[0];
                    REG_VOL1_SIZE_0:  vol_size_r[1][7:0] <= reg_wdata;
                    REG_VOL1_SIZE_1:  vol_size_r[1][15:8] <= reg_wdata;
                    REG_VOL1_SIZE_2:  vol_size_r[1][23:16] <= reg_wdata;
                    REG_VOL1_SIZE_3:  vol_size_r[1][31:24] <= reg_wdata;
                    REG_VOL1_ACK:     vol_ack_r[1] <= 1'b1;   // one-shot strobe

                    REG_U2_DOORBELL:  w5100_cmd_clr_r <= reg_wdata[3:0];

                    REG_GPU_CONTROL: begin
                        gpu_trigger_r <= reg_wdata[0];
                        gpu_pause_r <= reg_wdata[1];
                    end
                    REG_GPU_PC_L:     gpu_load_pc_r[7:0] <= reg_wdata;
                    REG_GPU_PC_H:     gpu_load_pc_r[15:8] <= reg_wdata;
                    REG_GPU_VADDR_L:  gpu_vaddr_r[7:0] <= reg_wdata;
                    REG_GPU_VADDR_H:  gpu_vaddr_r[13:8] <= reg_wdata[5:0];
                    REG_GPU_VDATA: begin
                        gpu_vdata_r <= reg_wdata;
                        gpu_vwe_r <= 1'b1;
                    end
                    REG_GPU_PADDR:    gpu_paddr_r <= reg_wdata[5:0];
                    REG_GPU_PDATA_L:  gpu_pdata_r[7:0] <= reg_wdata;
                    REG_GPU_PDATA_H: begin
                        gpu_pdata_r[11:8] <= reg_wdata[3:0];
                        gpu_pwe_r <= 1'b1;
                    end
                    REG_GPU_RADDR_L:  gpu_raddr_r[7:0] <= reg_wdata;
                    REG_GPU_RADDR_H:  gpu_raddr_r[13:8] <= reg_wdata[5:0];
                    REG_GPU_RDATA: begin
                        gpu_rdata_r <= reg_wdata;
                        gpu_rwe_r <= 1'b1;
                    end

                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // W5100 (SPACE 3) host link — the card holds the memory (port B).
    // Registered read on the card side: address presented at T, rdata valid
    // during T+1, sampled by the output mux at the end of T+1 (same latency
    // as the BSRAM spaces).
    // =========================================================================
    assign w5100_host_wr    = mem_wr_en && (mem_space == SPACE_W5100);
    assign w5100_host_wdata = mem_wr_data;
    assign w5100_host_addr  = w5100_host_wr ? mem_wr_addr[15:0] : mem_rd_addr[15:0];
    assign w5100_cmd_clr    = w5100_cmd_clr_r;

    // =========================================================================
    // Disk II track buffers (SPACE 4) — 16KB as 4 byte lanes x 4096 words.
    // Port A: ESP32 XFER byte access. Port B: DiskII card 32-bit access with
    // byte enables (word address, drive select at addr bit 11).
    // NORMAL write mode (q holds during a write): Gowin DPB does not support
    // read-before-write, and neither port needs the read value while writing.
    // =========================================================================
    reg [7:0] disk_esp_q [4];
    reg [7:0] disk_card_q [4];

    // One address per physical port: the ESP32 side muxes its write/read
    // address by direction (XFER is half-duplex, so a write and a read never
    // land in the same cycle). Using separate write/read addresses inside one
    // port would need a third address port and forces the array into LUTs.
    wire disk_esp_wr_w = mem_wr_en && (mem_space == SPACE_DISK);
    wire [11:0] disk_esp_addr_w = disk_esp_wr_w ? mem_wr_addr[13:2] : mem_rd_addr[13:2];

    genvar dl;
    generate
        for (dl = 0; dl < 4; dl = dl + 1) begin : disk_lane
            reg [7:0] lane_mem [0:4095] /* synthesis syn_ramstyle = "block_ram" */;

            always @(posedge clk) begin : port_esp
                if (disk_esp_wr_w && (mem_wr_addr[1:0] == dl[1:0]))
                    lane_mem[disk_esp_addr_w] <= mem_wr_data;
                else
                    disk_esp_q[dl] <= lane_mem[disk_esp_addr_w];
            end

            always @(posedge clk) begin : port_card
                if (disk_ram_if.wr && disk_ram_if.byte_en[dl])
                    lane_mem[disk_ram_if.addr[11:0]] <= disk_ram_if.data[dl*8 +: 8];
                else
                    disk_card_q[dl] <= lane_mem[disk_ram_if.addr[11:0]];
            end
        end
    endgenerate

    assign disk_ram_if.q = {disk_card_q[3], disk_card_q[2], disk_card_q[1], disk_card_q[0]};
    assign disk_ram_if.available = 1'b1;
    reg disk_ram_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) disk_ram_ready_r <= 1'b0;
        else        disk_ram_ready_r <= disk_ram_if.rd | disk_ram_if.wr;
    end
    assign disk_ram_if.ready = disk_ram_ready_r;

    // =========================================================================
    // HDD block buffers (SPACE 5) — 1KB as a single 32-bit BSRAM (512 words
    // declared for a natural BSRAM shape; the low 256 = 2 units x 128 words
    // are used). The HDD card is a pure 32-bit port (its byte_en is
    // hardwired to 4'b1111), so no byte lanes are needed. The ESP32's byte
    // writes are accumulated into words — SPACE 5 writes must be sequential
    // and 4-byte aligned, which the 512-byte block streams are.
    // =========================================================================
    reg [31:0] hdd_mem [0:511] /* synthesis syn_ramstyle = "block_ram" */;
    reg [23:0] hdd_acc_r;
    reg [31:0] hdd_esp_q32;
    reg [31:0] hdd_card_q32;

    wire hdd_esp_wr_w = mem_wr_en && (mem_space == SPACE_HDD);
    wire hdd_esp_word_wr_w = hdd_esp_wr_w && (mem_wr_addr[1:0] == 2'd3);
    wire [8:0] hdd_esp_addr_w = hdd_esp_wr_w ? {1'b0, mem_wr_addr[9:2]}
                                             : {1'b0, mem_rd_addr[9:2]};

    always @(posedge clk) begin
        if (hdd_esp_wr_w && mem_wr_addr[1:0] != 2'd3)
            hdd_acc_r[mem_wr_addr[1:0]*8 +: 8] <= mem_wr_data;
    end

    always @(posedge clk) begin : hdd_port_esp
        if (hdd_esp_word_wr_w)
            hdd_mem[hdd_esp_addr_w] <= {mem_wr_data, hdd_acc_r};
        else
            hdd_esp_q32 <= hdd_mem[hdd_esp_addr_w];
    end

    always @(posedge clk) begin : hdd_port_card
        if (hdd_ram_if.wr)
            hdd_mem[{1'b0, hdd_ram_if.addr[7:0]}] <= hdd_ram_if.data;
        else
            hdd_card_q32 <= hdd_mem[{1'b0, hdd_ram_if.addr[7:0]}];
    end

    assign hdd_ram_if.q = hdd_card_q32;
    assign hdd_ram_if.available = 1'b1;
    reg hdd_ram_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hdd_ram_ready_r <= 1'b0;
        else        hdd_ram_ready_r <= hdd_ram_if.rd | hdd_ram_if.wr;
    end
    assign hdd_ram_if.ready = hdd_ram_ready_r;

    // =========================================================================
    // Memory Write Logic — separate always blocks for BRAM inference
    // =========================================================================
    wire mem0_wr_en = mem_wr_en && (mem_space == SPACE_TEST);
    wire osd_wr_en  = mem_wr_en && (mem_space == SPACE_OSD);

    always @(posedge clk) begin
        if (mem0_wr_en)
            mem0[mem_wr_addr[5:0]] <= mem_wr_data;
    end

    // OSD text page port A: ESP32 writes only (reads come back 0xFF; port B
    // belongs to the clk_pixel OSD renderer)
    always @(posedge clk) begin
        if (osd_wr_en)
            osd_vram[mem_wr_addr[10:0]] <= mem_wr_data;
    end

    // OSD text page port B: registered read for the OSD renderer
    always @(posedge osd_clk_i) begin
        osd_data_o <= osd_vram[osd_addr_i];
    end

    // =========================================================================
    // Memory Read Logic — separate registered reads for BRAM inference
    // =========================================================================
    reg [7:0] mem0_rd_data;
    reg [2:0] mem_rd_space_r;
    reg [1:0] mem_rd_lane_r;

    always @(posedge clk) begin
        mem0_rd_data <= mem0[mem_rd_addr[5:0]];
    end

    // Pipeline the request, space and byte lane to match BRAM latency
    reg mem_rd_req_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_req_r <= 1'b0;
            mem_rd_space_r <= 3'd0;
            mem_rd_lane_r <= 2'd0;
        end else begin
            mem_rd_req_r <= mem_rd_req;
            mem_rd_space_r <= mem_rd_space;
            mem_rd_lane_r <= mem_rd_addr[1:0];
        end
    end

    // Output mux (after BRAM read latency)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_valid <= 1'b0;
            mem_rd_data <= 8'hFF;
        end else begin
            mem_rd_valid <= mem_rd_req_r;
            case (mem_rd_space_r)
                SPACE_TEST:  mem_rd_data <= mem0_rd_data;
                SPACE_W5100: mem_rd_data <= w5100_host_rdata;
                SPACE_DISK:  mem_rd_data <= disk_esp_q[mem_rd_lane_r];
                SPACE_HDD:   mem_rd_data <= hdd_esp_q32[mem_rd_lane_r*8 +: 8];
                default:     mem_rd_data <= 8'hFF;
            endcase
        end
    end

    // =========================================================================
    // Protocol Processor Instance
    // =========================================================================
    esp32_ospi_proto_proc #(
        .USE_SYNC(USE_SYNC),
        .USE_CRC(USE_CRC),
        .IDLE_TO_CYC(IDLE_TO_CYC)
    ) proto (
        .clk(clk),
        .rst_n(rst_n),
        .sclk(sclk),
        .data_in(data_i),
        .data_out(data_o),
        .data_oe(data_oe),
        .reg_wr_req(reg_wr_req),
        .reg_rd_req(reg_rd_req),
        .reg_idx(reg_idx),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .mem_wr_en(mem_wr_en),
        .mem_space(mem_space),
        .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data),
        .mem_rd_req(mem_rd_req),
        .mem_rd_space(mem_rd_space),
        .mem_rd_addr(mem_rd_addr),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_data(mem_rd_data)
    );

endmodule
