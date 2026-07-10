//
// Top module for Tang Nano 20K and A2N20v2 Apple II card
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

`include "datetime.svh"

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,   // Logic clock
    parameter int SDRAM_SPEED_HZ = 108_000_000,  // SDRAM clock
    parameter int MEM_MHZ = SDRAM_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 0,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter bit [7:0] SUPERSPRITE_ID = 1,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    parameter bit SUPERSERIAL_ENABLE = 1,
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter bit ENSONIQ_ENABLE = 1,
    parameter bit ENSONIQ_MONO_MIX = 0, // If true, mono mix is used instead of stereo

    parameter bit SHOW_OVERLAY_ON_STARTUP = 1,  // Show DebugOverlay on startup until a button is pressed
    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit HDMI_SLEEP_ENABLE = 1,        // Sleep HDMI output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1,      // Allow driving data to Apple bus

    // Debug: override VRAM data with fixed characters (0=normal)
    parameter bit FORCE_VRAM = 0,

    parameter bit USE_DIRECT_DISPLAY = 0        // 0=framebuffer, 1=direct to HDMI (ghost isolation)

) (
    // fpga clocks
    input clk,

    // fpga buttons
    input s1,
    input s2,

    // A2 signals
    input a2_reset_n,
    input a2_phi1,
    input a2_7M,

    // A2Bridge signals
    output [2:0] a2_bridge_sel,
    output a2_bridge_bus_a_oe_n,
    output a2_bridge_bus_d_oe_n,
    output a2_bridge_rd_n,
    output a2_bridge_wr_n,
    inout [7:0] a2_bridge_d,

    // hdmi ports
    output tmds_clk_p,
    output tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n,

    // leds
    output reg [4:0] led,

    // uart
    output  uart_tx,
    input  uart_rx,

    // "Magic" port names that the gowin compiler connects to the on-chip SDRAM
    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,   // chip select
    output        O_sdram_cas_n,  // columns address select
    output        O_sdram_ras_n,  // row address select
    output        O_sdram_wen_n,  // write enable
    inout  [31:0] IO_sdram_dq,    // 32 bit bidirectional data bus
    output [10:0] O_sdram_addr,   // 11 bit multiplexed address bus
    output [ 1:0] O_sdram_ba,     // two banks
    output [ 3:0] O_sdram_dqm     // 32/4

);

    wire rst_n = ~s1;

    // Clocks

    wire clk_sdram_w;      // 108 MHz from PLL
    wire clk_sdram_p_w;    // 108 MHz phase-shifted (SDRAM data capture)
    wire clk_logic_w;      // 54 MHz from CLKDIV2
    wire clk_logic_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_hdmi_lock_w;
    wire hdmi_rst_n_w;
    wire a2_2M;

    // PLL - 108MHz from 27
    clk_logic clk_logic_inst (
        .clkout(clk_sdram_w),  //output clkout (108 MHz)
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_sdram_p_w),  //output clkoutp (108 MHz phase-shifted)
        .clkoutd(clk_pixel_w),  //output clkoutd (27 MHz)
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    // 108 MHz → 54 MHz logic clock
    CLKDIV clkdiv2_inst(
        .CLKOUT(clk_logic_w),
        .HCLKIN(clk_sdram_w),
        .RESETN(rst_n),
        .CALIB(1'b0)
    );
    defparam clkdiv2_inst.DIV_MODE = "2";
    defparam clkdiv2_inst.GSREN = "false";

    // PLL - 135Mhz from 27
    clk_hdmi clk_hdmi_inst (
        .clkout(clk_hdmi_w),  //output clkout
        .lock(clk_hdmi_lock_w),  //output lock
        .reset(~clk_logic_lock_w),  //input reset
        .clkin(clk_pixel_w)  //input clkin
    );

    // Reset

    wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;

    wire a2_reset_cdc_w;
    cdc_fifo #(
        .WIDTH(1)
    ) cdc_a2reset (
        .clk(clk_logic_w),
        .i(a2_reset_n),
        .o(a2_reset_cdc_w)
    );

    wire system_reset_n_w = device_reset_n_w & a2_reset_cdc_w;

    // SDRAM Controller

    // SDRAM ports: lower number = higher priority
    localparam FB_READ_PORT      = 0;   // Framebuffer line reads (highest priority)
    localparam FB_WRITE_PORT     = 1;   // Framebuffer pixel writes
    localparam SHADOW_READ_PORT  = 2;   // Video gen reads from shadow memory
    localparam SHADOW_WRITE_PORT = 3;   // CPU writes to shadow memory
    localparam DOC_MEM_PORT      = 4;   // Ensoniq DOC read from sound memory
    localparam GLU_MEM_PORT      = 5;   // GLU write to sound memory
    localparam NUM_PORTS         = 6;

    localparam PORT_ADDR_WIDTH = 21;
    localparam DATA_WIDTH = 32;
    localparam DQM_WIDTH = 4;
    localparam PORT_OUTPUT_WIDTH = 32;

    // SDRAM memory map — word address offsets (32-bit word addressing)
    // Applied per-port inside sdram_ports via PORT_BASE_ADDR parameter.
    localparam [PORT_ADDR_WIDTH-1:0] SHADOW_WORD_BASE  = 21'h000000;  // 0MB
    localparam [PORT_ADDR_WIDTH-1:0] ENSONIQ_WORD_BASE = 21'h010000;  // 128KB
    localparam [PORT_ADDR_WIDTH-1:0] FB_WORD_BASE      = 21'h180000;  // 1.5MB (above shadow+ensoniq)

    // Client-side port interfaces (54 MHz logic domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports[NUM_PORTS-1:0]();

    // SDRAM-side port interfaces (108 MHz SDRAM domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports_sdram[NUM_PORTS-1:0]();

    wire sdram_init_complete_raw;  // from sdram_ports (108 MHz domain)

    sdram_ports #(
        .CLOCK_SPEED_MHZ(MEM_MHZ),
        .NUM_PORTS(NUM_PORTS),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
        .PORT_BASE_ADDR('{
            FB_WORD_BASE,       // [0] FB read
            FB_WORD_BASE,       // [1] FB write
            SHADOW_WORD_BASE,   // [2] Shadow read
            SHADOW_WORD_BASE,   // [3] Shadow write
            ENSONIQ_WORD_BASE,  // [4] DOC read
            ENSONIQ_WORD_BASE   // [5] GLU write
        }),
        .CAS_LATENCY(2),
        .SETTING_REFRESH_TIMER_NANO_SEC(15000),
        .SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC(16),
        .SETTING_USE_FAST_INPUT_REGISTER(1),
        .BURST_LENGTH(2),
        .READ_BURST_LENGTH(8),
        .PORT_BURST_LENGTH(1),
        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(11),
        .COL_WIDTH(8),
        .PRECHARGE_BIT(10),
        .DQM_WIDTH(DQM_WIDTH)
    ) sdram_ports (
        .clk(clk_sdram_w),            // 108 MHz
        .sdram_clk(clk_sdram_p_w),    // 108 MHz phase-shifted
        .reset(!device_reset_n_w),
        .init_complete(sdram_init_complete_raw),

        .ports(mem_ports_sdram),       // 108 MHz side

        .SDRAM_DQ(IO_sdram_dq),
        .SDRAM_A(O_sdram_addr),
        .SDRAM_DQM(O_sdram_dqm),
        .SDRAM_BA(O_sdram_ba),
        .SDRAM_nCS(O_sdram_cs_n),
        .SDRAM_nWE(O_sdram_wen_n),
        .SDRAM_nRAS(O_sdram_ras_n),
        .SDRAM_nCAS(O_sdram_cas_n),
        .SDRAM_CKE(O_sdram_cke),
        .SDRAM_CLK(O_sdram_clk)
    );

    // CDC wrappers: 54 MHz clients ↔ 108 MHz SDRAM
    generate
        for (genvar i = 0; i < NUM_PORTS; i++) begin : mem_cdc
            mem_port_cdc #(
                .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .DQM_WIDTH(DQM_WIDTH),
                .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
            ) cdc_inst (
                .clk_client(clk_logic_w),   // 54 MHz
                .clk_sdram(clk_sdram_w),    // 108 MHz
                .rst_n(device_reset_n_w),
                .client(mem_ports[i]),
                .sdram(mem_ports_sdram[i])
            );
        end
    endgenerate

    // Sync sdram_init_complete from 108 MHz → 54 MHz (2FF synchronizer)
    reg sdram_init_sync1, sdram_init_sync2;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            {sdram_init_sync1, sdram_init_sync2} <= 2'b0;
        end else begin
            sdram_init_sync1 <= sdram_init_complete_raw;
            sdram_init_sync2 <= sdram_init_sync1;
        end
    end
    wire sdram_init_complete = sdram_init_sync2;

    // Interface to Apple II

    // data and address latches on input

    a2bus_if a2bus_if ();

    wire sleep_w;
    wire data_in_strobe_w;

    wire irq_n_w;

    wire data_out_en_w;
    wire [7:0] data_out_w;

    wire [7:0] a2_bridge_d_buf_w;
    wire [7:0] a2_bridge_d_o_w;
    wire a2_bridge_d_oe_w;

    wire [3:0] dip_switches_n_w;
    wire sw_scanlines_w = !dip_switches_n_w[0];
    wire sw_apple_speaker_w = !dip_switches_n_w[1];
    wire sw_slot_7_w = !dip_switches_n_w[2];
    wire sw_gs_w = !dip_switches_n_w[3];

    IOBUF a2_bridge_d_iobuf[7:0] (
        .O  (a2_bridge_d_buf_w),
        .IO (a2_bridge_d),
        .I  (a2_bridge_d_o_w),
        .OEN(!a2_bridge_d_oe_w)
    );

    // No onboard MCU in this build — stub the bus control interface so the
    // shared apple_bus starts immediately and never holds the Apple II reset.
    a2bus_control_if a2bus_control_if();
    assign a2bus_control_if.ready = 1'b1;
    assign a2bus_control_if.reset_hold = 1'b0;

    apple_bus #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .BUS_DATA_OUT_ENABLE(BUS_DATA_OUT_ENABLE),
        .IRQ_OUT_ENABLE(IRQ_OUT_ENABLE),
        .INH_OUT_ENABLE(1'b0)
    ) apple_bus (
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_logic_w),    // F18A runs on clk_logic (54 MHz) — no separate pixel clock
        .system_reset_n_i(system_reset_n_w),
        .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1),
        .a2_q3_i(1'b0),
        .a2_7M_i(a2_7M),

        .a2bus_if(a2bus_if),
        .a2bus_control_if(a2bus_control_if),

        .a2_bridge_sel_o(a2_bridge_sel),
        .a2_bridge_bus_a_oe_n_o(a2_bridge_bus_a_oe_n),
        .a2_bridge_bus_d_oe_n_o(a2_bridge_bus_d_oe_n),
        .a2_bridge_rd_n_o(a2_bridge_rd_n),
        .a2_bridge_wr_n_o(a2_bridge_wr_n),
        .a2_bridge_d_i(a2_bridge_d_buf_w),
        .a2_bridge_d_o(a2_bridge_d_o_w),
        .a2_bridge_d_oe_o(a2_bridge_d_oe_w),

        .data_out_en_i(data_out_en_w),
        .data_out_i(data_out_w),

        .irq_n_i(irq_n_w),
        .inh_n_i(1'b1),

        .dip_switches_n_o(dip_switches_n_w),

        .sleep_o(sleep_w)
    );

    // Memory

    a2mem_if a2mem_if();

    wire [15:0] video_address_w;
    wire video_bank_w;
    wire video_rd_w;
    wire [31:0] video_data_w;
    wire video_ready_w;

    wire vgc_active_w;
    wire [12:0] vgc_address_w;
    wire vgc_rd_w;
    wire [31:0] vgc_data_w;

    apple_memory_sdram #(
        .VGC_MEMORY(1)
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(mem_ports[SHADOW_WRITE_PORT]),
        .video_mem_if(mem_ports[SHADOW_READ_PORT]),

        .video_address_i(video_address_w),
        .video_bank_i(video_bank_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),
        .video_ready_o(video_ready_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w),
        .vgc_ready_o()
    );

    // Slots

    slot_if slot_if();
    slotmaker_config_if slotmaker_config_if();

    slotmaker slotmaker (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .cfg_if(slotmaker_config_if),

        .slot_if(slot_if)
    );

    assign slotmaker_config_if.slot = 3'b0;
    assign slotmaker_config_if.wr = 1'b0;
    assign slotmaker_config_if.card_i = 8'b0;
    assign slotmaker_config_if.reconfig = 1'b0;

    // Video

    video_control_if video_control_if();
    assign video_control_if.enable = 1'b0;
    assign video_control_if.TEXT_MODE = 1'b0;
    assign video_control_if.MIXED_MODE = 1'b0;
    assign video_control_if.PAGE2 = 1'b0;
    assign video_control_if.HIRES_MODE = 1'b0;
    assign video_control_if.AN3 = 1'b0;
    assign video_control_if.STORE80 = 1'b0;
    assign video_control_if.COL80 = 1'b0;
    assign video_control_if.ALTCHAR = 1'b0;
    assign video_control_if.TEXT_COLOR = 4'b0;
    assign video_control_if.BACKGROUND_COLOR = 4'b0;
    assign video_control_if.BORDER_COLOR = 4'b0;
    assign video_control_if.MONOCHROME_MODE = 1'b0;
    assign video_control_if.MONOCHROME_DHIRES_MODE = 1'b0;
    assign video_control_if.SHRG_MODE = 1'b0;

    // HDMI raster position (from HDMI encoder, pixel clock domain)
    wire [9:0] hdmi_x;
    wire [9:0] hdmi_y;

    // CDC HDMI raster counters to clk_logic domain (synchronous 2:1 clocks)
    reg [9:0] hdmi_x_logic_r;
    reg [9:0] hdmi_y_logic_r;
    always @(posedge clk_logic_w) begin
        hdmi_x_logic_r <= hdmi_x;
        hdmi_y_logic_r <= hdmi_y;
    end

    // Scan timer — generates scanline/hsync/vsync from Apple II bus timing
    wire [8:0] scanline_w;
    wire hsync_w;
    wire vsync_w;
    wire [9:0] pixel_w;

    // Scan timer debug outputs for DebugOverlay
    wire [8:0] scan_dbg_delta_w;
    wire [8:0] scan_dbg_expected_w;
    wire [8:0] scan_dbg_actual_w;
    wire [7:0] scan_dbg_raw_data_w;
    wire [7:0] scan_dbg_vbl_correct_w;
    wire [7:0] scan_dbg_vertcnt_correct_w;
    wire [7:0] scan_dbg_c02e_cnt_w;
    wire [7:0] scan_dbg_c019_cnt_w;

    scan_timer #(
        .VGC_VERTCNT_LOCK(1),
        .VGC_VBL_LOCK(1),
        .RESYNC_THRESHOLD(2)
    ) scan_timer (
        .a2bus_if(a2bus_if),
        .scanline_o(scanline_w),
        .hsync_o(hsync_w),
        .vsync_o(vsync_w),
        .pixel_o(pixel_w),
        .dbg_last_delta_o(scan_dbg_delta_w),
        .dbg_last_expected_o(scan_dbg_expected_w),
        .dbg_last_actual_o(scan_dbg_actual_w),
        .dbg_last_raw_data_o(scan_dbg_raw_data_w),
        .dbg_vbl_correct_o(scan_dbg_vbl_correct_w),
        .dbg_vertcnt_correct_o(scan_dbg_vertcnt_correct_w),
        .dbg_c02e_count_o(scan_dbg_c02e_cnt_w),
        .dbg_c019_count_o(scan_dbg_c019_cnt_w)
    );

    // =========================================================================
    // Video Generators — pixel stream path
    // =========================================================================

    wire        fb_we_w;
    wire [17:0] fb_data_w;
    wire        fb_vsync_w;
    wire [7:0]  apple_fb_r_w;
    wire [7:0]  apple_fb_g_w;
    wire [7:0]  apple_fb_b_w;
    wire        apple_fb_active_w;
    wire        vgc_fb_we_w;
    wire [17:0] vgc_fb_data_w;
    wire        vgc_fb_vsync_w;

    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;

    // Direct display output wires (clk_logic domain)
    wire [7:0] dd_r_w;
    wire [7:0] dd_g_w;
    wire [7:0] dd_b_w;

    // --- Apple II generator ---
    pixel_stream_if apple_ps();

    apple_video_gen #(
        .VRAM_READ_LATENCY(16),      // SDRAM via mem_port_cdc
        .PIXEL_START_TICK(10)        // Fixed delay for deterministic SSP overlay timing
    ) apple_video_gen (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),
        .sw_gs_i(sw_gs_w),

        .pixel_stream(apple_ps),

        .video_address_o(video_address_w),
        .video_bank_o(video_bank_w),
        .video_rd_o(video_rd_w),
        .video_data_i(FORCE_VRAM ? 32'hC1_00_C1_00 : video_data_w),
        .video_ready_i(video_ready_w)
    );

    generate if (USE_DIRECT_DISPLAY) begin : gen_apple_direct
        // Direct display: bypass framebuffer, output to HDMI
        direct_display #(
            .PIX_CLK_DIV(2)
        ) apple_direct (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),
            .pixel_stream(apple_ps),
            .cx_i(hdmi_x_logic_r),
            .cy_i(hdmi_y_logic_r),
            .border_r_i({border_rgb444_w[11:8], border_rgb444_w[11:8]}),
            .border_g_i({border_rgb444_w[7:4], border_rgb444_w[7:4]}),
            .border_b_i({border_rgb444_w[3:0], border_rgb444_w[3:0]}),
            .video_r_o(dd_r_w),
            .video_g_o(dd_g_w),
            .video_b_o(dd_b_w)
        );

        // Tie off framebuffer write signals
        assign fb_we_w = 1'b0;
        assign fb_data_w = 18'd0;
        assign fb_vsync_w = 1'b0;
        assign apple_fb_r_w = 8'd0;
        assign apple_fb_g_w = 8'd0;
        assign apple_fb_b_w = 8'd0;
        assign apple_fb_active_w = 1'b0;
    end else begin : gen_apple_fb
        framebuffer_writer #(
            .GAP_CYCLES(4)
        ) apple_fb_writer (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),

            .pixel_stream(apple_ps),

            .scanline_i(scanline_w),
            .hsync_i(hsync_w),
            .vsync_i(vsync_w),

            .fb_we_o(fb_we_w),
            .fb_data_o(fb_data_w),
            .fb_vsync_o(fb_vsync_w),

            .apple_r_o(apple_fb_r_w),
            .apple_g_o(apple_fb_g_w),
            .apple_b_o(apple_fb_b_w),
            .apple_active_o(apple_fb_active_w),

            .ssp_r_i(rgb_r_w),
            .ssp_g_i(rgb_g_w),
            .ssp_b_i(rgb_b_w),
            .ssp_active_i(1'b1)
        );

        // Tie off direct display output
        assign dd_r_w = 8'd0;
        assign dd_g_w = 8'd0;
        assign dd_b_w = 8'd0;
    end endgenerate

    // --- VGC generator ---
    pixel_stream_if vgc_ps();

    vgc_gen vgc_gen (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),

        .pixel_stream(vgc_ps),

        .vgc_active_o(vgc_active_w),
        .vgc_address_o(vgc_address_w),
        .vgc_rd_o(vgc_rd_w),
        .vgc_data_i(vgc_data_w)
    );

    framebuffer_writer #(
        .GAP_CYCLES(4)
    ) vgc_fb_writer (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .pixel_stream(vgc_ps),

        .scanline_i(scanline_w),
        .hsync_i(hsync_w),
        .vsync_i(vsync_w),

        .fb_we_o(vgc_fb_we_w),
        .fb_data_o(vgc_fb_data_w),
        .fb_vsync_o(vgc_fb_vsync_w),

        .apple_r_o(),
        .apple_g_o(),
        .apple_b_o(),
        .apple_active_o(),
        .ssp_r_i(8'd0),
        .ssp_g_i(8'd0),
        .ssp_b_i(8'd0),
        .ssp_active_i(1'b0)
    );

    // Framebuffer output mux — select apple or vgc based on SHRG_MODE
    // Latched at frame boundary for clean transitions
    reg use_vgc_r;
    always @(posedge clk_logic_w) begin
        if (vsync_w) use_vgc_r <= a2mem_if.SHRG_MODE;
    end

    wire fb_we_mux_w          = use_vgc_r ? vgc_fb_we_w    : fb_we_w;
    wire [17:0] fb_data_mux_w = use_vgc_r ? vgc_fb_data_w  : fb_data_w;
    wire fb_vsync_mux_w       = use_vgc_r ? vgc_fb_vsync_w : fb_vsync_w;

    wire [10:0] fb_width_w  = use_vgc_r ? 11'd640 : 11'd560;
    wire [9:0]  fb_height_w = use_vgc_r ? 10'd200 : 10'd192;

    // SuperSprite

    wire [0:7] ssp_d_w;
    wire ssp_rd;
    wire vdp_ext_video;
    wire [3:0] vdp_border_r_w, vdp_border_g_w, vdp_border_b_w;
    wire vdp_border_active_w;
    wire vdp_irq_n;
    wire [9:0] ssp_audio_w;
    wire vdp_unlocked_w;
    wire [3:0] vdp_gmode_w;
    wire scanlines_w;

    f18a_gpu_if f18a_gpu_if();
    assign f18a_gpu_if.running = 1'b0;
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = 1'b0;
    assign f18a_gpu_if.vaddr = 14'b0;
    assign f18a_gpu_if.vdout = 8'b0;
    assign f18a_gpu_if.pwe = 1'b0;
    assign f18a_gpu_if.paddr = 6'b0;
    assign f18a_gpu_if.pdout = 12'b0;
    assign f18a_gpu_if.rwe = 1'b0;
    assign f18a_gpu_if.raddr = 13'b0;
    assign f18a_gpu_if.gstatus = 7'b0;

    // VDP Raster Counter — synced to Apple II scan_timer (clk_logic domain)
    // vdp_cx: horizontal counter advancing once per 4 clk_logic cycles
    // vdp_cy: uses scanline_w directly from scan_timer (0–261)
    localparam VDP_HMAX = 10'd856;  // matches custom f18a_vga_cont_fb HMAX=856

    reg [9:0] vdp_cx;
    reg [1:0] vdp_div;

    reg hsync_prev_r;
    always @(posedge a2bus_if.clk_logic) begin
        hsync_prev_r <= hsync_w;
    end

    always @(posedge a2bus_if.clk_logic) begin
        if (hsync_w) begin
            vdp_cx <= 10'd0;
            vdp_div <= 2'd0;
        end else begin
            vdp_div <= vdp_div + 2'd1;
            if (vdp_div == 2'd3 && vdp_cx < VDP_HMAX) begin
                vdp_cx <= vdp_cx + 10'd1;
            end
        end
    end

    SuperSprite #(
        .ENABLE(SUPERSPRITE_ENABLE),
        .ID(SUPERSPRITE_ID),
        .FORCE_VDP_OVERLAY(SUPERSPRITE_FORCE_VDP_OVERLAY)
    ) supersprite (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),

        .data_o(ssp_d_w),
        .rd_en_o(ssp_rd),
        .irq_n_o(vdp_irq_n),

        .screen_x_i(vdp_cx),
        .screen_y_i({1'b0, scanline_w}),
        .apple_vga_r_i(apple_fb_r_w),
        .apple_vga_g_i(apple_fb_g_w),
        .apple_vga_b_i(apple_fb_b_w),
        .apple_vga_active_i(apple_fb_active_w),

        .scanlines_i(SCANLINES_ENABLE | sw_scanlines_w),

        .ssp_r_o(rgb_r_w),
        .ssp_g_o(rgb_g_w),
        .ssp_b_o(rgb_b_w),

        .scanlines_o(scanlines_w),

        .vdp_ext_video_o(vdp_ext_video),
        .vdp_unlocked_o(vdp_unlocked_w),
        .vdp_gmode_o(vdp_gmode_w),

        .vdp_border_r_o(vdp_border_r_w),
        .vdp_border_g_o(vdp_border_g_w),
        .vdp_border_b_o(vdp_border_b_w),
        .vdp_border_active_o(vdp_border_active_w),

        .f18a_gpu_if(f18a_gpu_if),

        .ssp_audio_o(ssp_audio_w)
    );

    // Mockingboard

    wire [7:0] mb_d_w;
    wire mb_rd;
    wire mb_irq_n;
    wire [9:0] mb_audio_l;
    wire [9:0] mb_audio_r;

    Mockingboard #(
        .ENABLE(MOCKINGBOARD_ENABLE),
        .ID(MOCKINGBOARD_ID)
    ) mockingboard (
        .a2bus_if(a2bus_if),  // use system_reset_n
        .slot_if(slot_if),

        .data_o(mb_d_w),
        .rd_en_o(mb_rd),
        .irq_n_o(mb_irq_n),

        .audio_l_o(mb_audio_l),
        .audio_r_o(mb_audio_r)
    );

    // SuperSerial Card

    wire [7:0] ssc_d_w;
    wire ssc_rd;
    wire ssc_irq_n;
    wire ssc_rom_en;

    wire ssc_uart_rx;
    wire ssc_uart_tx;
    assign ssc_uart_rx = uart_rx;
    assign uart_tx = ssc_uart_tx;

    SuperSerial #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE(SUPERSERIAL_ENABLE),
        .IRQ_ENABLE(SUPERSERIAL_IRQ_ENABLE),
        .ID(SUPERSERIAL_ID)
    ) superserial (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .slot_if(slot_if),

        .data_o(ssc_d_w),
        .rd_en_o(ssc_rd),
        .irq_n_o(ssc_irq_n),

        .rom_en_o(ssc_rom_en),
        .uart_rx_i(ssc_uart_rx),
        .uart_tx_o(ssc_uart_tx)
    );

    // Data output

    assign data_out_en_w = ssp_rd || mb_rd || ssc_rd;

    assign data_out_w = ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w : 
        mb_rd ? mb_d_w : 
        a2bus_if.data;

    // Interrupts

    assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n;

    // Audio

    wire speaker_audio_w;

    apple_speaker apple_speaker (
        .a2bus_if(a2bus_if),
        .enable(APPLE_SPEAKER_ENABLE | sw_apple_speaker_w),
        .speaker_o(speaker_audio_w)
    );

    // Ensoniq DOC5503 Sound

    wire [15:0] sg_audio_l;
    wire [15:0] sg_audio_r;
    wire [7:0] sg_d_w;
    wire sg_rd_w;
    wire [7:0] doc_osc_en_w;
    wire [1:0] doc_osc_mode_w[8];
    wire [7:0] doc_osc_halt_w;

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE),
        .MONO_MIX(ENSONIQ_MONO_MIX)
    ) sg (
        .a2bus_if(a2bus_if),
        .data_o(sg_d_w),
        .rd_en_o(sg_rd_w),

        .audio_l_o(sg_audio_l),
        .audio_r_o(sg_audio_r),

        .debug_osc_en_o(doc_osc_en_w),
        .debug_osc_mode_o(doc_osc_mode_w),
        .debug_osc_halt_o(doc_osc_halt_w),

        .glu_mem_if(mem_ports[GLU_MEM_PORT]),
        .doc_mem_if(mem_ports[DOC_MEM_PORT])
    );

    // Extend all the unsigned audio signals to 13 bits
    wire [12:0] speaker_audio_ext_w = {speaker_audio_w, 12'b0};
    wire [12:0] ssp_audio_ext_w = {ssp_audio_w, 3'b0};
    wire [12:0] mb_audio_l_ext_w = {mb_audio_l, 3'b0};
    wire [12:0] mb_audio_r_ext_w = {mb_audio_r, 3'b0};

    // Combine all the audio sources into a single 16-bit signed audio signal
    // Registered to break timing path through 4-input addition chain
    reg signed [15:0] core_audio_l_r;
    reg signed [15:0] core_audio_r_r;
    always @(posedge clk_logic_w) begin
        core_audio_l_r <= sg_audio_l + ssp_audio_ext_w + mb_audio_l_ext_w + speaker_audio_ext_w;
        core_audio_r_r <= sg_audio_r + ssp_audio_ext_w + mb_audio_r_ext_w + speaker_audio_ext_w;
    end

    // Audio CDC: 54 MHz (CLKDIV2) → 108 MHz (PLL CLKOUT) → 27 MHz (PLL CLKOUTD)
    //
    // Stage 1: 54→108 MHz is safe because CLKDIV2 guarantees every 54 MHz edge
    //          IS a 108 MHz edge. The 108 MHz register captures stable data.
    // Stage 2: 108→27 MHz is safe because both come from the same PLL
    //          (CLKOUT and CLKOUTD), with PLL-guaranteed phase alignment.
    //
    // The old cdc_sampling approach (54→27 MHz direct) was broken because
    // CLKDIV2 output (54 MHz) and PLL CLKOUTD (27 MHz) don't have a
    // PLL-guaranteed phase relationship — their alignment depends on the
    // asynchronous CLKDIV2 RESETN timing.

    // Stage 1: 54 MHz → 108 MHz (CLKDIV2 alignment guarantee)
    reg signed [15:0] audio_l_sdram_r, audio_r_sdram_r;
    always @(posedge clk_sdram_w) begin
        audio_l_sdram_r <= core_audio_l_r;
        audio_r_sdram_r <= core_audio_r_r;
    end

    // Stage 2: 108 MHz → 27 MHz (PLL CLKOUT/CLKOUTD phase guarantee)
    reg [15:0] cdc_audio_l, cdc_audio_r;
    always @(posedge clk_pixel_w) begin
        cdc_audio_l <= audio_l_sdram_r;
        cdc_audio_r <= audio_r_sdram_r;
    end

    localparam [31:0] aflt_rate = 7_056_000;
    localparam [39:0] acx  = 4258969;
    localparam  [7:0] acx0 = 3;
    localparam  [7:0] acx1 = 3;
    localparam  [7:0] acx2 = 1;
    localparam [23:0] acy0 = -24'd6216759;
    localparam [23:0] acy1 =  24'd6143386;
    localparam [23:0] acy2 = -24'd2023767;

    localparam AUDIO_RATE = 44100;
    localparam AUDIO_BIT_WIDTH = 16;
    wire clk_audio_w;
    audio_timing #(
        .CLK_RATE(27_000_000),
        .AUDIO_RATE(AUDIO_RATE)
    ) audio_timing (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),
        .audio_clk(clk_audio_w),
        .i2s_bclk(),
        .i2s_lrclk(),
        .i2s_data_shift_strobe(),
        .i2s_data_load_strobe()
    );

    wire [15:0] audio_sample_word[1:0];
    audio_out #(
        .CLK_RATE(27_000_000),
        .AUDIO_RATE(AUDIO_RATE)
    ) audio_out
    (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),

        .flt_rate(aflt_rate),
        .cx(acx),
        .cx0(acx0),
        .cx1(acx1),
        .cx2(acx2),
        .cy0(acy0),
        .cy1(acy1),
        .cy2(acy2),

        .is_signed(1'b1),
        .core_l(cdc_audio_l),
        .core_r(cdc_audio_r),

        .audio_clk(clk_audio_w),
        .audio_l(audio_sample_word[0]),
        .audio_r(audio_sample_word[1])
    );

    // Border color: convert 4-bit palette index to RGB666
    wire border_gsp_w = a2bus_if.sw_gs;
    wire [4:0] border_idx_w = {border_gsp_w, a2mem_if.BORDER_COLOR};
    wire [11:0] border_palette_w [0:31];
    assign border_palette_w = '{
        12'h000, 12'h924, 12'h42a, 12'hd4e,   // Apple II  0-3
        12'h064, 12'h888, 12'h39e, 12'hcbf,   //           4-7
        12'h450, 12'hc73, 12'h888, 12'hfac,   //           8-11
        12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,   //          12-15
        12'h000, 12'hd03, 12'h009, 12'hd2d,   // IIgs      0-3
        12'h072, 12'h555, 12'h22f, 12'h6af,   //           4-7
        12'h850, 12'hf60, 12'haaa, 12'hf98,   //           8-11
        12'h1d0, 12'hff0, 12'h4f9, 12'hfff    //          12-15
    };
    wire [11:0] border_rgb444_w = border_palette_w[border_idx_w];
    wire [17:0] apple_border_rgb666_w = {
        border_rgb444_w[11:8], 2'b00,
        border_rgb444_w[7:4],  2'b00,
        border_rgb444_w[3:0],  2'b00
    };

    // VDP border color: when the SuperSprite overlay is active, use the VDP
    // backdrop color for the display border. Uses the same overlay logic as
    // active pixels (non-black VDP backdrop overrides Apple II border).
    // Match active area path: SSP outputs {vdp_r, 4'b0}, framebuffer_writer
    // truncates to [7:2] = {vdp_r, 2'b00}. Use same expansion here.
    wire [17:0] vdp_border_rgb666_w = {vdp_border_r_w, 2'b00,
                                        vdp_border_g_w, 2'b00,
                                        vdp_border_b_w, 2'b00};
    wire [17:0] border_rgb666_w = vdp_border_active_w ? vdp_border_rgb666_w : apple_border_rgb666_w;

    // SDRAM Framebuffer
    wire [7:0] fb_r_w;
    wire [7:0] fb_g_w;
    wire [7:0] fb_b_w;
    wire [7:0] fb_dbg_fifo_level_w;
    wire [7:0] fb_dbg_fifo_highwater_w;
    wire [7:0] fb_dbg_fifo_overflow_w;
    wire [7:0] fb_dbg_fetch_start_w;
    wire [7:0] fb_dbg_fetch_done_w;
    wire [7:0] fb_dbg_read_blocked_w;
    wire [7:0] fb_dbg_yield_busy_w;
    wire [7:0] fb_dbg_late_line_w;
    wire [7:0] fb_dbg_line_not_ready_w;
    wire [7:0] fb_dbg_line_lag_max_w;
    wire [7:0] fb_dbg_ready_phase_err_w;
    wire [7:0] fb_dbg_vsync_raw_w;
    wire [7:0] fb_dbg_frame_start_accept_w;
    wire [7:0] fb_dbg_frame_start_reject_w;
    wire [7:0] fb_dbg_flags_w;

    sdram_framebuffer #(
        .TEST_PATTERN(0),  // 0=normal operation
        .THRESHOLD_DIAG(0) // EXP 22: 0=normal colors, 1=binary threshold
    ) sdram_framebuffer (
        .clk(clk_logic_w),
        .clk_pixel(clk_pixel_w),
        .rst_n(device_reset_n_w),

        .fb_vsync(fb_vsync_mux_w),
        .fb_we(fb_we_mux_w),
        .fb_data(fb_data_mux_w),
        .fb_width(fb_width_w),
        .fb_height(fb_height_w),

        .fb_write_port(mem_ports[FB_WRITE_PORT]),
        .fb_read_port(mem_ports[FB_READ_PORT]),

        .hdmi_cx({1'b0, hdmi_x}),
        .hdmi_cy(hdmi_y),

        .r_o(fb_r_w),
        .g_o(fb_g_w),
        .b_o(fb_b_w),

        .border_color(border_rgb666_w),
        .scanline_en(scanlines_w),
        .sleep_i(sleep_w),

        .dbg_fifo_level_o(fb_dbg_fifo_level_w),
        .dbg_fifo_highwater_o(fb_dbg_fifo_highwater_w),
        .dbg_fifo_overflow_o(fb_dbg_fifo_overflow_w),
        .dbg_fetch_start_o(fb_dbg_fetch_start_w),
        .dbg_fetch_done_o(fb_dbg_fetch_done_w),
        .dbg_read_blocked_o(fb_dbg_read_blocked_w),
        .dbg_yield_busy_o(fb_dbg_yield_busy_w),
        .dbg_late_line_o(fb_dbg_late_line_w),
        .dbg_line_not_ready_o(fb_dbg_line_not_ready_w),
        .dbg_line_lag_max_o(fb_dbg_line_lag_max_w),
        .dbg_ready_phase_err_o(fb_dbg_ready_phase_err_w),
        .dbg_vsync_raw_o(fb_dbg_vsync_raw_w),
        .dbg_frame_start_accept_o(fb_dbg_frame_start_accept_w),
        .dbg_frame_start_reject_o(fb_dbg_frame_start_reject_w),
        .dbg_flags_o(fb_dbg_flags_w)
    );

    // Direct display CDC: clk_logic → clk_pixel (synchronous 2:1 clocks)
    reg [7:0] dd_r_pixel_r;
    reg [7:0] dd_g_pixel_r;
    reg [7:0] dd_b_pixel_r;
    always @(posedge clk_pixel_w) begin
        dd_r_pixel_r <= dd_r_w;
        dd_g_pixel_r <= dd_g_w;
        dd_b_pixel_r <= dd_b_w;
    end

    // Select display source: direct display or framebuffer
    wire [7:0] display_r_w = USE_DIRECT_DISPLAY ? dd_r_pixel_r : fb_r_w;
    wire [7:0] display_g_w = USE_DIRECT_DISPLAY ? dd_g_pixel_r : fb_g_w;
    wire [7:0] display_b_w = USE_DIRECT_DISPLAY ? dd_b_pixel_r : fb_b_w;

    // HDMI

    reg show_debug_overlay_r = SHOW_OVERLAY_ON_STARTUP;

    wire [7:0] debug_r_w;
    wire [7:0] debug_g_w;
    wire [7:0] debug_b_w;
    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),  // 14-digit timestamp version
        .ENABLE(1'b1)
    ) debug_overlay (
        .clk_i          (clk_pixel_w),
        .reset_n (device_reset_n_w),
        .enable_i(show_debug_overlay_r),

        .hex_values ({
            fb_dbg_fifo_level_w,
            fb_dbg_fifo_highwater_w,
            fb_dbg_fifo_overflow_w,
            fb_dbg_line_not_ready_w,
            fb_dbg_line_lag_max_w,
            fb_dbg_vsync_raw_w,
            fb_dbg_frame_start_accept_w,
            fb_dbg_frame_start_reject_w
        }),

        .debug_bits_0_i (fb_dbg_flags_w),
        .debug_bits_1_i ({
            1'b0,
            scanlines_w,
            use_vgc_r,
            a2mem_if.SHRG_MODE,
            a2mem_if.HIRES_MODE,
            a2mem_if.TEXT_MODE,
            sdram_init_complete,
            sleep_w
        }),

        .screen_x_i     (hdmi_x),
        .screen_y_i     (hdmi_y),

        .r_i            (display_r_w),
        .g_i            (display_g_w),
        .b_i            (display_b_w),

        .r_o            (debug_r_w),
        .g_o            (debug_g_w),
        .b_o            (debug_b_w)
    );  

    logic [2:0] tmds;
    wire tmdsClk;

    hdmi #(
        .VIDEO_ID_CODE(2),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(59.94),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .VENDOR_NAME({"Unknown", 8'd0}),  // Must be 8 bytes null-padded 7-bit ASCII
        .PRODUCT_DESCRIPTION({"FPGA", 96'd0}),  // Must be 16 bytes null-padded 7-bit ASCII
        .SOURCE_DEVICE_INFORMATION(8'h00), // See README.md or CTA-861-G for the list of valid codes
        .START_X(0),
        .START_Y(0)
    ) hdmi (
        .clk_pixel_x5(clk_hdmi_w),
        .clk_pixel(clk_pixel_w),
        .clk_audio(clk_audio_w),
        .rgb({
            debug_r_w,
            debug_g_w,
            debug_b_w
        }),
        .reset(~device_reset_n_w),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds),
        .tmds_clock(tmdsClk),
        .cx(hdmi_x),
        .cy(hdmi_y),
        .frame_width(),
        .frame_height(),
        .screen_width(),
        .screen_height()
    );

    // Gowin LVDS output buffer
    ELVDS_TBUF tmds_bufds[3:0] (
        .I({clk_pixel_w, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n}),
        .OEN(sleep_w && HDMI_SLEEP_ENABLE)
    );

    wire s2_debounced_w;
    debounce #(
        .DEBOUNCE_TIME(10000)
    ) debounce_a2reset (
        .clk(clk_logic_w),
        .rst(~device_reset_n_w),
        .i(s2),
        .o(s2_debounced_w)
    );

    reg prev_button_s2 = 1'b0;
    wire button_s2_posedge_w = s2_debounced_w && !prev_button_s2;
    always @(posedge clk_logic_w) begin 
        prev_button_s2 <= s2_debounced_w;
        if (button_s2_posedge_w) begin
            show_debug_overlay_r <= !show_debug_overlay_r;
        end
        //led <= {4'b1111, !picosoc_led};
        //if (!s2) 
        led <= {!a2mem_if.TEXT_MODE, !a2mem_if.SHRG_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        //else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end


endmodule
