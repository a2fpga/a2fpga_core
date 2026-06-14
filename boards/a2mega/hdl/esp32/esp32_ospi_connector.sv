// Extended Octal SPI Connector for ESP32-S3 to FPGA communication
// Provides control interfaces similar to PicoSoC module
//
// Features:
// - 127 registers for configuration and status
// - Video control interface (video_control_if)
// - Slot configuration (slotmaker_config_if)
// - Drive volume control (drive_volume_if x2)
// - F18A GPU interface (f18a_gpu_if)
// - Text VRAM block RAM (2KB x 2 banks)
//
// See boards/a2mega/docs/ESP32_OSPI_DESIGN.md for register map and protocol details
//
module esp32_ospi_connector #(
    parameter USE_SYNC    = 1,
    parameter USE_CRC     = 0,
    parameter IDLE_TO_CYC = 5_400_000
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
    drive_volume_if.volume volumes[2]
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

    // Video control (0x10-0x1F)
    localparam REG_VIDEO_ENABLE = 7'h10;
    localparam REG_VIDEO_MODE   = 7'h11;
    localparam REG_TEXT_COLOR   = 7'h12;
    localparam REG_BG_COLOR     = 7'h13;
    localparam REG_BORDER_COLOR = 7'h14;
    localparam REG_VIDEO_FLAGS  = 7'h15;

    // Slot configuration (0x30-0x3F)
    localparam REG_SLOT_SELECT  = 7'h30;
    localparam REG_SLOT_CARD    = 7'h31;
    localparam REG_SLOT_STATUS  = 7'h32;
    localparam REG_SLOT_RECONFIG= 7'h33;

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

    // =========================================================================
    // Protocol Processor Interface
    // =========================================================================
    wire        reg_wr_req;
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
    reg        slot_reconfig_r;

    // Drive volumes
    reg        vol_ready_r[2];
    reg        vol_mounted_r[2];
    reg        vol_readonly_r[2];
    reg [31:0] vol_size_r[2];
    reg        vol_ack_r[2];

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

    // =========================================================================
    // Memory Spaces - using Gowin BSRAM inference pattern
    // =========================================================================

    // Space 0: Test memory (2KB)
    reg [7:0] mem0 [0:2047] /* synthesis syn_ramstyle = "block_ram" */;

    // Space 1: Text VRAM Bank 0 (2KB)
    reg [7:0] text_vram0 [0:2047] /* synthesis syn_ramstyle = "block_ram" */;

    // Space 2: Text VRAM Bank 1 (2KB)
    reg [7:0] text_vram1 [0:2047] /* synthesis syn_ramstyle = "block_ram" */;

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
    assign slotmaker_config_if.wr = slot_reconfig_r;
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
            REG_STATUS:       reg_rdata = 8'h01;  // Always ready

            // Video control
            REG_VIDEO_ENABLE: reg_rdata = {7'b0, video_enable_r};
            REG_VIDEO_MODE:   reg_rdata = video_mode_r;
            REG_TEXT_COLOR:   reg_rdata = {4'b0, text_color_r};
            REG_BG_COLOR:     reg_rdata = {4'b0, bg_color_r};
            REG_BORDER_COLOR: reg_rdata = {4'b0, border_color_r};
            REG_VIDEO_FLAGS:  reg_rdata = video_flags_r;

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
            REG_VOL0_ACK:     reg_rdata = {7'b0, vol_ack_r[0]};

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
            REG_VOL1_ACK:     reg_rdata = {7'b0, vol_ack_r[1]};

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

            default: reg_rdata = 8'hFF;
        endcase
    end

    // =========================================================================
    // Register Write Logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch_r <= 8'h00;
            video_enable_r <= 1'b0;
            video_mode_r <= 8'b00010001;  // TEXT_MODE=1, AN3=1
            text_color_r <= 4'd15;
            bg_color_r <= 4'd2;
            border_color_r <= 4'd2;
            video_flags_r <= 8'h00;
            slot_select_r <= 3'd0;
            slot_card_r <= 8'h00;
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
        end else begin
            // Clear one-shot registers
            slot_reconfig_r <= 1'b0;
            gpu_vwe_r <= 1'b0;
            gpu_pwe_r <= 1'b0;
            gpu_rwe_r <= 1'b0;

            if (reg_wr_req) begin
                case (reg_idx)
                    REG_SCRATCH:      scratch_r <= reg_wdata;

                    REG_VIDEO_ENABLE: video_enable_r <= reg_wdata[0];
                    REG_VIDEO_MODE:   video_mode_r <= reg_wdata;
                    REG_TEXT_COLOR:   text_color_r <= reg_wdata[3:0];
                    REG_BG_COLOR:     bg_color_r <= reg_wdata[3:0];
                    REG_BORDER_COLOR: border_color_r <= reg_wdata[3:0];
                    REG_VIDEO_FLAGS:  video_flags_r <= reg_wdata;

                    REG_SLOT_SELECT:  slot_select_r <= reg_wdata[2:0];
                    REG_SLOT_CARD:    slot_card_r <= reg_wdata;
                    REG_SLOT_RECONFIG:slot_reconfig_r <= reg_wdata[0];

                    REG_VOL0_READY:   vol_ready_r[0] <= reg_wdata[0];
                    REG_VOL0_MOUNTED: vol_mounted_r[0] <= reg_wdata[0];
                    REG_VOL0_READONLY:vol_readonly_r[0] <= reg_wdata[0];
                    REG_VOL0_SIZE_0:  vol_size_r[0][7:0] <= reg_wdata;
                    REG_VOL0_SIZE_1:  vol_size_r[0][15:8] <= reg_wdata;
                    REG_VOL0_SIZE_2:  vol_size_r[0][23:16] <= reg_wdata;
                    REG_VOL0_SIZE_3:  vol_size_r[0][31:24] <= reg_wdata;
                    REG_VOL0_ACK:     vol_ack_r[0] <= reg_wdata[0];

                    REG_VOL1_READY:   vol_ready_r[1] <= reg_wdata[0];
                    REG_VOL1_MOUNTED: vol_mounted_r[1] <= reg_wdata[0];
                    REG_VOL1_READONLY:vol_readonly_r[1] <= reg_wdata[0];
                    REG_VOL1_SIZE_0:  vol_size_r[1][7:0] <= reg_wdata;
                    REG_VOL1_SIZE_1:  vol_size_r[1][15:8] <= reg_wdata;
                    REG_VOL1_SIZE_2:  vol_size_r[1][23:16] <= reg_wdata;
                    REG_VOL1_SIZE_3:  vol_size_r[1][31:24] <= reg_wdata;
                    REG_VOL1_ACK:     vol_ack_r[1] <= reg_wdata[0];

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
    // Memory Write Logic - separate always blocks for BRAM inference
    // =========================================================================
    wire mem0_wr_en = mem_wr_en && (mem_space == 3'd0);
    wire vram0_wr_en = mem_wr_en && (mem_space == 3'd1);
    wire vram1_wr_en = mem_wr_en && (mem_space == 3'd2);

    always @(posedge clk) begin
        if (mem0_wr_en)
            mem0[mem_wr_addr[10:0]] <= mem_wr_data;
    end

    always @(posedge clk) begin
        if (vram0_wr_en)
            text_vram0[mem_wr_addr[10:0]] <= mem_wr_data;
    end

    always @(posedge clk) begin
        if (vram1_wr_en)
            text_vram1[mem_wr_addr[10:0]] <= mem_wr_data;
    end

    // =========================================================================
    // Memory Read Logic - separate registered reads for BRAM inference
    // =========================================================================
    reg [7:0] mem0_rd_data;
    reg [7:0] vram0_rd_data;
    reg [7:0] vram1_rd_data;
    reg [2:0] mem_rd_space_r;

    always @(posedge clk) begin
        mem0_rd_data <= mem0[mem_rd_addr[10:0]];
    end

    always @(posedge clk) begin
        vram0_rd_data <= text_vram0[mem_rd_addr[10:0]];
    end

    always @(posedge clk) begin
        vram1_rd_data <= text_vram1[mem_rd_addr[10:0]];
    end

    // Pipeline the request and space selection to match BRAM latency
    reg mem_rd_req_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_req_r <= 1'b0;
            mem_rd_space_r <= 3'd0;
        end else begin
            mem_rd_req_r <= mem_rd_req;
            mem_rd_space_r <= mem_rd_space;
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
                3'd0: mem_rd_data <= mem0_rd_data;
                3'd1: mem_rd_data <= vram0_rd_data;
                3'd2: mem_rd_data <= vram1_rd_data;
                default: mem_rd_data <= 8'hFF;
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
