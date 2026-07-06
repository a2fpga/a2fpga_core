//
// Top module for Tang Mega 60K and A2Mega Apple II card
//
// (c) 2023,2024,2025 Ed Anuff <ed@a2fpga.com> 
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
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int PIXEL_SPEED_HZ = CLOCK_SPEED_HZ / 2,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 1,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter bit [7:0] SUPERSPRITE_ID = 1,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    parameter bit SUPERSERIAL_ENABLE = 1,
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter bit DISK_II_ENABLE = 1,
    parameter bit [7:0] DISK_II_ID = 4,

    parameter bit UTHERNET2_ENABLE = 1,
    parameter bit [7:0] UTHERNET2_ID = 5,

    parameter bit HDD_ENABLE = 1,
    parameter bit [7:0] HDD_ID = 6,

    parameter bit ENSONIQ_ENABLE = 1,
    parameter bit ENSONIQ_MONO_MIX = 0, // If true, mono mix is used instead of stereo

    parameter int GS = 0,                       // Apple IIgs mode
    parameter int ENABLE_FILTER = 0,            // Enable audio filtering
    parameter int ENABLE_DENOISE = 0,           // Enable denoise of clocks
    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit HDMI_SLEEP_ENABLE = 0,        // Sleep HDMI output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1        // Allow driving data to Apple bus

) (
    // fpga clocks
    input clk,
    input resetn,
    input rst,

    // A2 signals
    output a2_bus_oe,

    input  a2_rw_n,
    input  a2_inh_n,
    input  a2_reset_n,
    input  a2_rdy_n,
    output a2_irq_n,
    input  a2_dma_n,
    input  a2_nmi_n,
    input  a2_mb20,
    input  a2_sync_n,
    input  a2_m2sel_n,
    output  a2_res_out_n,
    output a2_int_out_n,
    input  a2_int_in_n,
    output a2_dma_out_n,
    input a2_dma_in_n,
    input  a2_phi1,
    input  a2_q3,
    input  a2_7M,

    output a2_a_dir,
    input [15:0] a2_a,

    output a2_d_dir,
    inout [7:0] a2_d,

    // hdmi ports
    output tmds_clk_p,
    output tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n,

    input hdmi_hpd,
    output hdmi_scl,
    output hdmi_sda,
    output hdmi_cec,

    // leds
    output [1:0] led,

    input button,  // 0 when pressed

    input [3:0] dip_switches_n,

    // uart
    output  uart_tx,
    input  uart_rx,

    // ddr3 interface
    output [15:0] ddr_addr, //ROW_WIDTH=16
	output [2:0] ddr_bank, //BANK_WIDTH=3
	output ddr_cs,
	output ddr_ras,
	output ddr_cas,
	output ddr_we,
	output ddr_ck,
	output ddr_ck_n,
	output ddr_cke,
	output ddr_odt,
	output ddr_reset_n,
	output [1:0] ddr_dm, //DM_WIDTH=4
	inout  [15:0] ddr_dq, //DQ_WIDTH=32
	inout  [1:0] ddr_dqs, //DQS_WIDTH=4
	inout  [1:0] ddr_dqs_n, //DQS_WIDTH=4

    // ESP32 Octal SPI interface
    input         esp_sclk,
    inout  [7:0]  esp_data,

    // USB-A host port (direct GPIO, BANK3)
    inout usb_dp,
    inout usb_dm

);

    assign hdmi_scl = 1'b1;
    assign hdmi_sda = 1'b1;
    assign hdmi_cec = 1'b0;

    // Clocks

    wire clk_logic_pll_w;           // 54 MHz from board PLL CLKOUT2 (independent of DDR3)
    wire clk_logic_w = clk_logic_pll_w;  // logic runs on independent PLL
    wire clk_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_27M_w;

    clk_pll clocks_pll (
        .lock(clk_lock_w), //output lock
        .clkout0(clk_pixel_w), //output clkout0 (27 MHz pixel clock)
        .clkout1(clk_hdmi_w), //output clkout1 (135 MHz TMDS)
        .clkout2(clk_logic_pll_w), //output clkout2 (54 MHz logic — independent of DDR3)
        .clkin(clk) //input clkin
    );

    // Dedicated USB host clock — usb_hid_host needs crystal-accurate 60 MHz
    wire clk_usb_w;
    wire usb_pll_lock_w;

    pll_usb pll_usb_inst (
        .lock(usb_pll_lock_w),
        .clkout0(clk_usb_w), //output clkout0 (60 MHz USB host clock)
        .clkin(clk) //input clkin
    );

    /*
    CLKDIV clkdiv_inst (
        .HCLKIN(clk_hdmi_w),
        .RESETN(clk_lock_w),
        .CALIB(1'b0),
        .CLKOUT(clk_pixel_w)
    );
    defparam clkdiv_inst.DIV_MODE="5";
    */

    // LED blinking logic with ES5503 counter indication
    reg led_r = 1'b0;
    reg [25:0] led_counter_r = 26'd0;

    always @(posedge clk_logic_w) begin

        
        if (led_counter_r == 26'd09_999_999) begin
            led_counter_r <= 0;

            led_r <= ~led_r;  // Normal heartbeat every 0.5s
        end else begin
            led_counter_r <= led_counter_r + 1;
        end
    end
    assign led[0] = !led_r;

    // Power-on reset generation
    localparam RESET_CYCLES = 100;  // Number of clock cycles to hold reset
    
    reg rstn_r = 1'b0;
    reg [$clog2(RESET_CYCLES+1)-1:0] reset_counter_r = '0;

    always @(posedge clk_logic_w) begin
        if (reset_counter_r == RESET_CYCLES) begin
            rstn_r <= 1'b1;  // Release reset after RESET_CYCLES clocks
        end else begin
            reset_counter_r <= reset_counter_r + 1;
        end
    end

    // Reset

    wire device_reset_n_w = rstn_r; // Use reset signal from power-on reset logic

    //wire device_reset_n_w = ~rst;

    wire system_reset_n_w = device_reset_n_w & a2_reset_n;

    // Interface to Apple II

    // Buffer/level shifters are held in tri-state
    // during FPGA configuration to ensure no interference
    // with the Apple II bus.
    assign a2_bus_oe = 1'b0;

    // Address bus is input-only unless performing DMA
    // 0 = from Apple II bus to FPGA, 1 = from FPGA to Apple II bus
    assign a2_a_dir  = 1'b0;

    // data and address latches on input

    a2bus_if a2bus_if ();

    // Apple II bus control (reset hold/release) — driven by the ESP32 OSPI
    // connector so the Apple II waits in RESET until disk mounts are ready.
    a2bus_control_if a2bus_control_if();

    wire sleep_w;

    wire irq_n_w;
    assign a2_irq_n = IRQ_OUT_ENABLE && !irq_n_w ? 1'b0 : 1'bz;

    wire sw_scanlines_w = !dip_switches_n[0];
    wire sw_apple_speaker_w = !dip_switches_n[1];
    wire sw_slot_7_w = !dip_switches_n[2];
    wire sw_gs_w = !dip_switches_n[3];

    wire [7:0] a2_d_buf_w;
    wire data_out_en_w;
    wire [7:0] data_out_w;
    assign a2_d_dir = data_out_en_w && BUS_DATA_OUT_ENABLE;

    IOBUF a2_d_iobuf[7:0] (
        .O  (a2_d_buf_w),
        .IO (a2_d),
        .I  (data_out_w),
        .OEN(!a2_d_dir)
    );

    apple_bus #(
        .GS(GS),
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE_DENOISE(ENABLE_DENOISE)
    ) apple_bus (
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_logic_w),    // F18A runs on clk_logic (54 MHz) — no separate pixel clock
        .system_reset_n_i(system_reset_n_w),
        .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1),
        .a2_q3_i(a2_q3),
        .a2_7M_i(a2_7M),

        .sw_gs_i(!dip_switches_n[3]),

        .a2bus_if(a2bus_if),

        .a2_a_i(a2_a),
        .a2_d_i(a2_d_buf_w),
        .a2_rw_n_i(a2_rw_n),
        
        .a2_inh_n(a2_inh_n),
        .a2_rdy_n(a2_rdy_n),
        .a2_dma_n(a2_dma_n),
        .a2_nmi_n(a2_nmi_n),
        .a2_reset_n(a2_reset_n),
        .a2_mb20(a2_mb20),
        .a2_sync_n(a2_sync_n),
        .a2_m2sel_n(a2_m2sel_n),
        .a2_res_out_n(a2_res_out_n),
        .a2_int_out_n(a2_int_out_n),
        .a2_int_in_n(a2_int_in_n),
        .a2_dma_out_n(a2_dma_out_n),
        .a2_dma_in_n(a2_dma_in_n),
        .irq_n_i(1'b1),

        .reset_hold_i(a2bus_control_if.reset_hold),

        .sleep_o(sleep_w)
    );

    // LED indicators for phi1 and 2M clock
    
    wire led_phi1_w;
    reg [10:0]led_phi1_ctr_r;
    always @(posedge clk_logic_w) begin
        if (a2bus_if.phi1_posedge) led_phi1_ctr_r <= led_phi1_ctr_r + 1;
    end
    assign led_phi1_w = led_phi1_ctr_r[10];

    wire led_2m_w;
    reg [10:0]led_2m_ctr_r;
    always @(posedge clk_logic_w) begin
        if (a2bus_if.clk_q3_posedge) led_2m_ctr_r <= led_2m_ctr_r + 1;
    end
    assign led_2m_w = led_2m_ctr_r[10];


    // Memory

    a2mem_if a2mem_if();

    wire [15:0] video_address_w;
    wire video_bank_w;
    wire video_rd_w;
    wire [31:0] video_data_w;
    wire video_ready_w;

    // Diagnostic: capture first shadow memory read response
    reg [31:0] shadow_read_capture_r;
    reg shadow_read_captured_r;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            shadow_read_capture_r <= 32'hDEADBEEF;
            shadow_read_captured_r <= 1'b0;
        end else if (video_ready_w && !shadow_read_captured_r) begin
            shadow_read_capture_r <= video_data_w;
            shadow_read_captured_r <= 1'b1;
        end
    end

    wire vgc_active_w;
    wire [12:0] vgc_address_w;
    wire vgc_rd_w;
    wire [31:0] vgc_data_w;
    wire vgc_ready_w;

    // DDR3 memory port allocation (single unified array for all clients):
    //   0 = FB write (highest priority — prevents FIFO overflow/pixel drops)
    //   1 = FB read  (scanline prefetch, line-buffer absorbs latency)
    //   2 = Shadow read  (apple_video_gen)
    //   3 = Shadow write (CPU)
    //   4 = DOC (Ensoniq wavetable read)
    //   5 = GLU (Ensoniq write)
    localparam FB_WRITE_PORT   = 0;
    localparam FB_READ_PORT    = 1;
    localparam SHADOW_READ_PORT  = 2;
    localparam SHADOW_WRITE_PORT = 3;
    localparam DOC_MEM_PORT      = 4;
    localparam GLU_MEM_PORT      = 5;
    localparam NUM_DDR3_PORTS    = 6;

    // DDR3 memory map — word address offsets (32-bit word addressing)
    // Applied per-port inside ddr3_ports via PORT_BASE_ADDR parameter.
    localparam [20:0] FB_WORD_BASE      = 21'h000000;  // 0MB (double-buffered: buf0 0x000000-0x025800, buf1 0x025800-0x04B000)
    localparam [20:0] SHADOW_WORD_BASE  = 21'h050000;  // 1.25MB — after double-buffered FB (was 0x040000)
    localparam [20:0] ENSONIQ_WORD_BASE = 21'h080000;  // 2MB (28'h0200000 >> 2)

    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32))
        ddr3_mem_ports[0:NUM_DDR3_PORTS-1]();

    apple_memory #(
        .VGC_MEMORY(1)
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(ddr3_mem_ports[SHADOW_WRITE_PORT]),
        .video_mem_if(ddr3_mem_ports[SHADOW_READ_PORT]),

        .video_address_i(video_address_w),
        .video_bank_i(video_bank_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),
        .video_ready_o(video_ready_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w),
        .vgc_ready_o(vgc_ready_w),

        .dbg_shadow_drop_o(shadow_dbg_drop_w),
        .dbg_rd_state_o(shadow_dbg_rd_state_w)
    );

    wire [7:0] shadow_dbg_rd_state_w;

    // Slots

    slot_if slot_if();
    slotmaker_config_if slotmaker_config_if();

    slotmaker slotmaker (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .cfg_if(slotmaker_config_if),

        .slot_if(slot_if)
    );

    // Slot configuration is driven by the ESP32 OSPI connector (regs
    // 0x30-0x33); the slotmaker keeps its slots.hex defaults until the ESP32
    // reconfigures it.

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
    wire [7:0]  vgc_dbg_missed_hsync_w;
    wire [7:0]  shadow_dbg_drop_w;

    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;

    // --- Apple II generator ---
    pixel_stream_if apple_ps();

    apple_video_gen #(
        .VRAM_READ_LATENCY(20),
        .PIXEL_START_TICK(10)
    ) apple_video_gen (
        .clk_i(clk_logic_w),
        .reset_n_i(system_reset_n_w),

        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),
        .sw_gs_i(!dip_switches_n[3]),

        .pixel_stream(apple_ps),

        .video_address_o(video_address_w),
        .video_bank_o(video_bank_w),
        .video_rd_o(video_rd_w),
        .video_data_i(video_data_w),
        .video_ready_i(video_ready_w)
    );

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
        .vgc_data_i(vgc_data_w),
        .vgc_ready_i(vgc_ready_w),

        .dbg_missed_hsync_o(vgc_dbg_missed_hsync_w)
    );

    framebuffer_writer #(
        .GAP_CYCLES(2)
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

    // Ensoniq DOC5503 Sound

    wire [15:0] sg_audio_l;
    wire [15:0] sg_audio_r;

    wire [7:0] sg_d_w;
    wire sg_rd_w;
    wire [7:0] doc_osc_en_w;
    wire [1:0] doc_osc_mode_w[8];
    wire [7:0] doc_osc_halt_w;

    // 64KB sound RAM backed by BSRAM (DDR3 ports kept but idle)

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE),
        .MONO_MIX(ENSONIQ_MONO_MIX),
        .USE_BSRAM(1)
    ) sg (
        .a2bus_if(a2bus_if),
        .data_o(sg_d_w),
        .rd_en_o(sg_rd_w),

        .audio_l_o(sg_audio_l),
        .audio_r_o(sg_audio_r),

        .debug_osc_en_o(doc_osc_en_w),
        .debug_osc_mode_o(doc_osc_mode_w),
        .debug_osc_halt_o(doc_osc_halt_w),

        .glu_mem_if(ddr3_mem_ports[GLU_MEM_PORT]),
        .doc_mem_if(ddr3_mem_ports[DOC_MEM_PORT])
    );

    // SuperSprite

    wire VDP_OVERLAY_SW;
    wire APPLE_VIDEO_SW;
    // =========================================================================
    // VDP Raster Counter — synced to Apple II scan_timer (clk_logic domain)
    // =========================================================================
    // vdp_cx: horizontal counter advancing once per 4 clk_logic cycles (pixel rate)
    // to match apple_video_fb's gap_cnt_r. Clamped at VDP_HMAX to prevent wrap.
    //
    // vdp_cy: uses scanline_w directly from scan_timer (0–261) to guarantee exact
    // alignment with apple_video_fb. This ensures the F18A sees the correct scanline
    // numbers (including 260/261 for scanline_reset during blanking) and that VDP
    // line 0 corresponds to framebuffer line 0.
    //
    // At 54 MHz with ~63.5 µs scanline: ~3,429 clk_logic cycles / 4 = ~857 ticks/line.
    // VDP_HMAX=856 ensures y_tick fires near end of each scanline.
    localparam VDP_HMAX = 10'd856;

    reg [9:0] vdp_cx;   // 0–856 (VDP_HMAX)
    reg [1:0] vdp_div;  // 2-bit divider: vdp_cx advances when vdp_div wraps

    reg hsync_prev_r;
    always @(posedge a2bus_if.clk_logic) begin
        hsync_prev_r <= hsync_w;
    end
    wire hsync_edge_w = hsync_w && !hsync_prev_r;

    always @(posedge a2bus_if.clk_logic) begin
        if (hsync_w) begin
            // Reset horizontal counter on hsync (same cycle as scan_timer scanline change)
            vdp_cx <= 10'd0;
            vdp_div <= 2'd0;
        end else begin
            vdp_div <= vdp_div + 2'd1;
            if (vdp_div == 2'd3 && vdp_cx < VDP_HMAX) begin
                vdp_cx <= vdp_cx + 10'd1;
            end
        end
    end

    // =========================================================================
    // SuperSprite / VDP
    // =========================================================================

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

        .screen_x_i(vdp_cx),              // VDP raster X (10-bit, 0–856)
        .screen_y_i({1'b0, scanline_w}),  // VDP raster Y from scan_timer (9-bit→10-bit, 0–261)
        .apple_vga_r_i(apple_fb_r_w),     // Apple II RGB from apple_video_fb
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

    // Disk II controller (track-on-demand). drive_ii drives the drive side of
    // volumes[] (lba/blk_cnt/rd) on a seek; the ESP32 (esp32_ospi_connector
    // volume regs 0x40-0x5F) streams the requested track into the SPACE 4
    // BSRAM window via XFER, then pulses ack.

    drive_volume_if volumes[2]();

    mem_port_if #(
        .PORT_ADDR_WIDTH(21),
        .DATA_WIDTH(32),
        .DQM_WIDTH(4),
        .PORT_OUTPUT_WIDTH(32)
    ) disk_ram_if ();

    wire [7:0] diskii_d_w;
    wire diskii_rd;

    DiskII #(
        .ENABLE(DISK_II_ENABLE),
        .ID(DISK_II_ID)
    ) diskii (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(diskii_d_w),
        .rd_en_o(diskii_rd),
        .ram_disk_if(disk_ram_if),
        .volumes(volumes)
    );

    // ProDOS hard disk (block device). The card requests one 512-byte block
    // at a time over hdd_volumes[] (compact regs 0x26-0x2D); the ESP32 serves
    // it from a .hdv/.po image into the SPACE 5 BSRAM window via XFER, then
    // pulses ack and the card streams it to the 6502 through its sector
    // buffer.

    drive_volume_if hdd_volumes[2]();

    mem_port_if #(
        .PORT_ADDR_WIDTH(21),
        .DATA_WIDTH(32),
        .DQM_WIDTH(4),
        .PORT_OUTPUT_WIDTH(32)
    ) hdd_ram_if ();

    wire [7:0] hdd_d_w;
    wire hdd_rd;

    HDD #(
        .ENABLE(HDD_ENABLE),
        .ID(HDD_ID)
    ) hdd (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(hdd_d_w),
        .rd_en_o(hdd_rd),
        .ram_hdd_if(hdd_ram_if),
        .volumes(hdd_volumes)
    );

    // Uthernet II (W5100) Ethernet card. The ESP32 services the MACRAW
    // bridge over XFER SPACE 3 + doorbell reg 0x7A, forwarding frames to
    // WiFi.

    wire [7:0] u2_d_w;
    wire u2_rd;
    wire u2_irq_n;

    wire        u2_host_wr_w;
    wire [15:0] u2_host_addr_w;
    wire [7:0]  u2_host_wdata_w;
    wire [7:0]  u2_host_rdata_w;
    wire [3:0]  u2_cmd_pending_w;
    wire [3:0]  u2_cmd_clr_w;

    Uthernet2 #(
        .ENABLE(UTHERNET2_ENABLE),
        .ID(UTHERNET2_ID)
    ) uthernet2 (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),

        .data_o(u2_d_w),
        .rd_en_o(u2_rd),
        .irq_n_o(u2_irq_n),

        .w5100_host_wr(u2_host_wr_w),
        .w5100_host_addr(u2_host_addr_w),
        .w5100_host_wdata(u2_host_wdata_w),
        .w5100_host_rdata(u2_host_rdata_w),
        .cmd_pending_o(u2_cmd_pending_w),
        .cmd_pending_clr(u2_cmd_clr_w),
        .dbg_portb_wr_count(),
        .dbg_portb_last_addr(),
        .dbg_portb_last_wdata()
    );

    // Data output

    assign data_out_en_w = ssp_rd || mb_rd || ssc_rd || u2_rd || diskii_rd || hdd_rd;

    assign data_out_w = ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w :
        mb_rd ? mb_d_w :
        u2_rd ? u2_d_w :
        diskii_rd ? diskii_d_w :
        hdd_rd ? hdd_d_w :
        a2bus_if.data;

    // Interrupts

    assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n && u2_irq_n;

    // Audio

    wire speaker_audio_w;

    apple_speaker apple_speaker (
        .a2bus_if(a2bus_if),
        .enable(APPLE_SPEAKER_ENABLE | sw_apple_speaker_w),
        .speaker_o(speaker_audio_w)
    );

    // Extend all the unsigned audio signals to 13 bits
    wire [12:0] speaker_audio_ext_w = {speaker_audio_w, 12'b0};
    wire [12:0] ssp_audio_ext_w = {ssp_audio_w, 3'b0};
    wire [12:0] mb_audio_l_ext_w = {mb_audio_l, 3'b0};
    wire [12:0] mb_audio_r_ext_w = {mb_audio_r, 3'b0};

    wire signed [15:0] core_audio_l_w;
    wire signed [15:0] core_audio_r_w;
    // Combine all the audio sources into a single 16-bit signed audio signal
    // This could theoretically overflow by 1 bit and clip, but unlikely
    assign core_audio_l_w = sg_audio_l + ssp_audio_ext_w + mb_audio_l_ext_w + speaker_audio_ext_w;
    assign core_audio_r_w = sg_audio_r + ssp_audio_ext_w + mb_audio_r_ext_w + speaker_audio_ext_w;

    // =========================================================================
    // DDR3 + Framebuffer + HDMI Output (480p)
    // =========================================================================
    //
    // Decomposed architecture:
    //   1. DDR3 PLL + DDR3_Memory_Interface_Top (memory controller)
    //   2. ddr3_ports — multi-port arbiter (mem_port_if → DDR3 IP)
    //   3. framebuffer_480p — shared framebuffer (2 × mem_port_if)
    //   4. HDMI encoder + TMDS output (480p 59.94Hz)
    //
    // Board PLL provides clk_pixel (27 MHz) and clk_pixel_x5 (135 MHz) directly.

    // Scan timer — authoritative Apple II scanline timing

    scan_timer #(
        .VGC_VERTCNT_LOCK(1),
        .VGC_VBL_LOCK(1),
        .RESYNC_THRESHOLD(2)     // VBL polarity auto-detected via a2bus_if.sw_gs
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

    // Framebuffer dynamic dimensions — switch at frame boundary
    localparam [10:0] APPLE_FB_WIDTH  = 11'd560;
    localparam [9:0]  APPLE_FB_HEIGHT = 10'd192;
    localparam [10:0] VGC_FB_WIDTH    = 11'd640;
    localparam [9:0]  VGC_FB_HEIGHT   = 10'd200;
    wire [10:0] fb_width_w  = use_vgc_r ? VGC_FB_WIDTH  : APPLE_FB_WIDTH;
    wire [9:0]  fb_height_w = use_vgc_r ? VGC_FB_HEIGHT : APPLE_FB_HEIGHT;

    // Border color: convert 4-bit palette index to RGB666
    // Uses {GSP, BORDER_COLOR} as 5-bit index into 32-entry palette,
    // same as apple_video_fb.sv: entries 0-15 = Apple II, 16-31 = IIgs
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
    wire [17:0] vdp_border_rgb666_w = {vdp_border_r_w, 2'b00,
                                        vdp_border_g_w, 2'b00,
                                        vdp_border_b_w, 2'b00};
    wire [17:0] border_rgb666_w = vdp_border_active_w ? vdp_border_rgb666_w : apple_border_rgb666_w;

    wire init_calib_complete_w;
    wire ddr_rst_w;
    wire clk_x1_w;              // 81 MHz from DDR3 controller (324/4)
    wire [10:0] hdmi_cx_w;      // HDMI raster X (0–857)
    wire [9:0]  hdmi_cy_w;      // HDMI raster Y (0–524)
    wire [23:0] fb_rgb_w;       // Current framebuffer RGB output
    wire [23:0] overlay_rgb_w;  // DebugOverlay RGB output
    wire        overlay_en_w;   // DebugOverlay enable

    // -----------------------------------------------------------------
    // DDR3 PLL — 324 MHz memory clock from 27 MHz input
    // Uses pll_ddr3 wrapper with PLL_INIT for VCO calibration
    // No pll_mDRP_intf needed — bypass permanently disabled
    // -----------------------------------------------------------------
    wire memory_clk_w;
    wire pll_lock_w;
    wire pll_stop_w;

    pll_ddr3 pll_ddr3_inst (
        .clkin(clk_pixel_w),           // 27 MHz from board PLL
        .clkout0(),                    // unused
        .clkout2(memory_clk_w),        // 324 MHz to DDR3
        .lock(pll_lock_w),
        .mdopc(2'b00),                 // external MDRP unused
        .mdainc(1'b0),
        .mdwdi(8'b0),
        .mdrdo(),                      // unused output
        .pll_init_bypass(1'b0),        // PLL_INIT always controls calibration
        .mdclk(clk),                   // 50 MHz board crystal for MDRP clock
        .reset(~clk_lock_w)
    );

    // -----------------------------------------------------------------
    // DDR3 Memory Controller (Gowin IP)
    // -----------------------------------------------------------------
    wire        ddr3_cmd_ready_w;
    wire [2:0]  ddr3_cmd_w;
    wire        ddr3_cmd_en_w;
    wire [28:0] ddr3_addr_w;

    wire        ddr3_wr_data_rdy_w;
    wire [127:0] ddr3_wr_data_w;
    wire        ddr3_wr_data_en_w;
    wire        ddr3_wr_data_end_w;
    wire [15:0] ddr3_wr_data_mask_w;

    wire        ddr3_rd_data_valid_w;
    wire        ddr3_rd_data_end_w;
    wire [127:0] ddr3_rd_data_w;

    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk      (memory_clk_w),
        .pll_stop        (pll_stop_w),
        .clk             (clk),                 // 50 MHz board crystal
        .rst_n           (1'b1),
        .cmd_ready       (ddr3_cmd_ready_w),
        .cmd             (ddr3_cmd_w),
        .cmd_en          (ddr3_cmd_en_w),
        .addr            (ddr3_addr_w),
        .wr_data_rdy     (ddr3_wr_data_rdy_w),
        .wr_data         (ddr3_wr_data_w),
        .wr_data_en      (ddr3_wr_data_en_w),
        .wr_data_end     (ddr3_wr_data_end_w),
        .wr_data_mask    (ddr3_wr_data_mask_w),
        .rd_data         (ddr3_rd_data_w),
        .rd_data_valid   (ddr3_rd_data_valid_w),
        .rd_data_end     (ddr3_rd_data_end_w),
        .sr_req          (1'b0),
        .ref_req         (1'b0),
        .sr_ack          (),
        .ref_ack         (),
        .init_calib_complete(init_calib_complete_w),
        .clk_out         (clk_x1_w),            // 81 MHz DDR3 app clock (324/4)
        .pll_lock        (pll_lock_w),
        .burst           (1'b1),
        .ddr_rst         (ddr_rst_w),
        .O_ddr_addr      (ddr_addr[14:0]),
        .O_ddr_ba        (ddr_bank),
        .O_ddr_cs_n      (ddr_cs),
        .O_ddr_ras_n     (ddr_ras),
        .O_ddr_cas_n     (ddr_cas),
        .O_ddr_we_n      (ddr_we),
        .O_ddr_clk       (ddr_ck),
        .O_ddr_clk_n     (ddr_ck_n),
        .O_ddr_cke       (ddr_cke),
        .O_ddr_odt       (ddr_odt),
        .O_ddr_reset_n   (ddr_reset_n),
        .O_ddr_dqm       (ddr_dm),
        .IO_ddr_dq       (ddr_dq),
        .IO_ddr_dqs      (ddr_dqs),
        .IO_ddr_dqs_n    (ddr_dqs_n)
    );

    assign ddr_addr[15] = 1'b0;

    // -----------------------------------------------------------------
    // DDR3 Multi-Port Arbiter
    // -----------------------------------------------------------------

    wire [95:0] fb_wide_data_hi_w;

    ddr3_ports #(
        .NUM_PORTS(NUM_DDR3_PORTS),
        .DDR_ADDR_WIDTH(29),
        .PORT_BASE_ADDR('{
            FB_WORD_BASE,       // [0] FB write (highest priority)
            FB_WORD_BASE,       // [1] FB read
            SHADOW_WORD_BASE,   // [2] Shadow read
            SHADOW_WORD_BASE,   // [3] Shadow write
            ENSONIQ_WORD_BASE,  // [4] DOC read
            ENSONIQ_WORD_BASE   // [5] GLU write
        }),
        .WIDE_WR_PORT(FB_WRITE_PORT),
        .READ_BURST8_PORT(FB_READ_PORT)
    ) u_ddr3_ports (
        .clk_client      (clk_logic_w),     // 54 MHz from board PLL (async to DDR3)
        .clk_ddr          (clk_x1_w),       // 81 MHz from DDR3 IP
        .rst              (ddr_rst_w),
        .init_complete    (init_calib_complete_w),

        .ports            (ddr3_mem_ports),
        .wide_wr_data_hi  (fb_wide_data_hi_w),

        .cmd_ready        (ddr3_cmd_ready_w),
        .cmd              (ddr3_cmd_w),
        .cmd_en           (ddr3_cmd_en_w),
        .addr             (ddr3_addr_w),

        .wr_data_rdy      (ddr3_wr_data_rdy_w),
        .wr_data          (ddr3_wr_data_w),
        .wr_data_en       (ddr3_wr_data_en_w),
        .wr_data_end      (ddr3_wr_data_end_w),
        .wr_data_mask     (ddr3_wr_data_mask_w),

        .rd_data_valid    (ddr3_rd_data_valid_w),
        .rd_data          (ddr3_rd_data_w),
        .rd_data_end      (ddr3_rd_data_end_w),

        .dbg_req_pending  (ddr3_dbg_req_pending_w),
        .dbg_arb_state    (ddr3_dbg_arb_state_w),
        .dbg_resp_overflow(ddr3_dbg_resp_ovfl_w),
        .dbg_test_result  (ddr3_dbg_test_result_w),
        .dbg_test_done    (ddr3_dbg_test_done_w)
    );

    wire [NUM_DDR3_PORTS-1:0] ddr3_dbg_resp_ovfl_w;
    wire [NUM_DDR3_PORTS-1:0] ddr3_dbg_req_pending_w;
    wire [7:0] ddr3_dbg_arb_state_w;
    wire [31:0] ddr3_dbg_test_result_w;
    wire ddr3_dbg_test_done_w;

    // -----------------------------------------------------------------
    // Shared Framebuffer (480p via mem_port_if)
    // -----------------------------------------------------------------

    wire [7:0] fb_dbg_fifo_highwater_w;
    wire [7:0] fb_dbg_fifo_overflow_w;
    wire [7:0] fb_dbg_read_blocked_w;
    wire [7:0] fb_dbg_yield_busy_w;
    wire [7:0] fb_dbg_fifo_pop_w;
    wire [7:0] fb_dbg_fifo_push_w;
    wire [7:0] fb_dbg_late_line_w;
    wire [7:0] fb_dbg_flags_w;
    wire [7:0] fb_dbg_line_not_ready_w;
    wire [7:0] fb_dbg_line_lag_max_w;
    wire [7:0] fb_dbg_ready_phase_err_w;
    wire [7:0] fb_dbg_fetch_done_w;
    wire [7:0] fb_dbg_fetch_start_w;
    wire [7:0] fb_dbg_rd_fifo_max_w;
    wire [7:0] fb_dbg_rd_fifo_drop_w;
    wire [7:0] fb_dbg_line_not_ready_total_w;
    wire [7:0] fb_dbg_beat_extra_w;
    wire [7:0] fb_dbg_beat_timeout_w;
    framebuffer_480p #(
        .COLOR_BITS(18),
        .FB_READ_BURST_WORDS(8),
        .TEST_PATTERN(0)
    ) u_framebuffer (
        .clk              (clk_logic_w),
        .clk_pixel        (clk_pixel_w),
        .rst_n            (~ddr_rst_w),

        .fb_vsync         (fb_vsync_mux_w),
        .fb_we            (fb_we_mux_w),
        .fb_data          (fb_data_mux_w),
        .fb_width         (fb_width_w),
        .fb_height        (fb_height_w),

        .fb_write_port    (ddr3_mem_ports[FB_WRITE_PORT]),
        .fb_read_port     (ddr3_mem_ports[FB_READ_PORT]),
        .fb_wr_wide_data_hi_o (fb_wide_data_hi_w),

        .hdmi_cx          (hdmi_cx_w),
        .hdmi_cy          (hdmi_cy_w),

        .r_o              (fb_rgb_w[23:16]),
        .g_o              (fb_rgb_w[15:8]),
        .b_o              (fb_rgb_w[7:0]),

        .border_color     (border_rgb666_w),
        .scanline_en      (1'b1),
        .sleep_i          (sleep_w),

        // Debug outputs
        .dbg_fifo_level_o        (),
        .dbg_fifo_highwater_o    (fb_dbg_fifo_highwater_w),
        .dbg_fifo_overflow_o     (fb_dbg_fifo_overflow_w),
        .dbg_fetch_start_o       (fb_dbg_fetch_start_w),
        .dbg_fetch_done_o        (fb_dbg_fetch_done_w),
        .dbg_read_blocked_o      (fb_dbg_read_blocked_w),
        .dbg_yield_busy_o        (fb_dbg_yield_busy_w),
        .dbg_fifo_pop_o          (fb_dbg_fifo_pop_w),
        .dbg_fifo_push_o         (fb_dbg_fifo_push_w),
        .dbg_late_line_o         (fb_dbg_late_line_w),
        .dbg_flags_o             (fb_dbg_flags_w),
        .dbg_line_not_ready_o    (fb_dbg_line_not_ready_w),
        .dbg_line_lag_max_o      (fb_dbg_line_lag_max_w),
        .dbg_ready_phase_err_o   (fb_dbg_ready_phase_err_w),
        .dbg_vsync_raw_o         (),
        .dbg_frame_start_accept_o(),
        .dbg_frame_start_reject_o(),
        .dbg_rd_fifo_max_o       (fb_dbg_rd_fifo_max_w),
        .dbg_rd_fifo_drop_o      (fb_dbg_rd_fifo_drop_w),
        .dbg_line_not_ready_total_o (fb_dbg_line_not_ready_total_w),
        .dbg_beat_extra_o        (fb_dbg_beat_extra_w),
        .dbg_beat_timeout_o      (fb_dbg_beat_timeout_w)
    );

    // -----------------------------------------------------------------
    // Audio clock generation (27 MHz pixel clock domain)
    // -----------------------------------------------------------------

    localparam AUDIO_RATE = 48000;
    localparam AUDIO_CLK_DELAY = 27000000 / AUDIO_RATE;  // 562 (27M/48k = 562.5)
    logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
    logic clk_audio;
    reg audio_frac;

    always_ff @(posedge clk_pixel_w) begin
        clk_audio <= 1'b0;
        if (audio_divider >= (audio_frac ? AUDIO_CLK_DELAY : AUDIO_CLK_DELAY - 1)) begin
            clk_audio <= 1'b1;
            audio_divider <= 0;
            audio_frac <= ~audio_frac;
        end else begin
            audio_divider <= audio_divider + 1;
        end
    end

    // Audio CDC: clk_logic (54 MHz) -> clk_pixel (27 MHz) via double-flop
    reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
    always @(posedge clk_pixel_w) begin
        audio_sample_word0[0] <= core_audio_l_w;
        audio_sample_word[0]  <= audio_sample_word0[0];
        audio_sample_word0[1] <= core_audio_r_w;
        audio_sample_word[1]  <= audio_sample_word0[1];
    end

    // -----------------------------------------------------------------
    // HDMI TX — 480p 59.94Hz
    // -----------------------------------------------------------------

    wire [9:0] hdmi_cx_raw_w;
    wire [9:0] hdmi_cy_raw_w;
    reg [23:0] hdmi_rgb_r;

    assign hdmi_cx_w = {1'b0, hdmi_cx_raw_w};
    assign hdmi_cy_w = hdmi_cy_raw_w;

    wire [2:0] tmds_w;

    hdmi #(
        .VIDEO_ID_CODE(2),          // 720x480p 59.94Hz
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(59.94),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(16),
        .START_X(0),
        .START_Y(0)
    ) hdmi_inst (
        .clk_pixel_x5    (clk_hdmi_w),
        .clk_pixel        (clk_pixel_w),
        .clk_audio        (clk_audio),
        .rgb              (overlay_en_w ? overlay_rgb_w : hdmi_rgb_r),
        .reset            (ddr_rst_w),
        .audio_sample_word(audio_sample_word),
        .tmds             (tmds_w),
        .tmds_clock       (),
        .cx               (hdmi_cx_raw_w),
        .cy               (hdmi_cy_raw_w),
        .frame_width      (),
        .frame_height     ()
    );

    // Register framebuffer RGB output for HDMI
    always @(posedge clk_pixel_w) begin
        hdmi_rgb_r <= fb_rgb_w;
    end

    // Gowin LVDS output buffer
    ELVDS_OBUF tmds_bufds [3:0] (
        .I({clk_pixel_w, tmds_w}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

    // DDR3 calibration status on LED[1]
    assign led[1] = !init_calib_complete_w;

    // =========================================================================
    // USB HID host — runs in clk_usb (60 MHz) domain
    // =========================================================================
    // Full-speed host for mouse/keyboard/gamepad on the USB-A port. The board
    // wires D+/D- straight to BANK3 GPIO with external 15k pulldowns (host
    // topology); no PHY, no series resistors on this board spin, so keep
    // cables short during bring-up.

    wire usb_reset_w;

    reset_sync usb_reset_sync (
        .clk (clk_usb_w),
        .arst(~(device_reset_n_w & usb_pll_lock_w)),
        .srst(usb_reset_w)
    );

    wire usb_dp_i_w, usb_dm_i_w;
    wire usb_dp_o_w, usb_dm_o_w;
    wire usb_oe_w;

    IOBUF usb_dp_iobuf (
        .O  (usb_dp_i_w),
        .IO (usb_dp),
        .I  (usb_dp_o_w),
        .OEN(!usb_oe_w)
    );

    IOBUF usb_dm_iobuf (
        .O  (usb_dm_i_w),
        .IO (usb_dm),
        .I  (usb_dm_o_w),
        .OEN(!usb_oe_w)
    );

    // UKP microcode ROM is external to the core in the m1nl fork
    wire [9:0] usb_rom_addr_w;
    wire [3:0] usb_rom_dout_w;
    wire       usb_rom_en_w;

    usb_hid_host_rom usb_rom (
        .clk (clk_usb_w),
        .addr(usb_rom_addr_w),
        .dout(usb_rom_dout_w),
        .en  (usb_rom_en_w)
    );

    wire [1:0] usb_typ_w;          // 0: none, 1: keyboard, 2: mouse, 3: gamepad
    wire       usb_report_w;
    wire       usb_connerr_w;
    wire [7:0] usb_key_modifiers_w;
    wire [7:0] usb_key_w [6];
    wire [2:0] usb_mouse_btn_w;
    wire signed [7:0] usb_mouse_dx_w, usb_mouse_dy_w;
    wire usb_game_l_w, usb_game_r_w, usb_game_u_w, usb_game_d_w;
    wire usb_game_a_w, usb_game_b_w, usb_game_x_w, usb_game_y_w;
    wire usb_game_sel_w, usb_game_sta_w;
    wire [3:0] usb_game_extra_w;

    usb_hid_host #(
        .FULL_SPEED(1)
    ) usb_hid_host (
        .clk          (clk_usb_w),
        .reset        (usb_reset_w),
        .cs           (1'b1),

        .usb_dm_i     (usb_dm_i_w),
        .usb_dp_i     (usb_dp_i_w),
        .usb_dm_o     (usb_dm_o_w),
        .usb_dp_o     (usb_dp_o_w),
        .usb_oe       (usb_oe_w),

        .typ          (usb_typ_w),
        .full_report  (usb_report_w),
        .connerr      (usb_connerr_w),
        .busy         (),

        .key_modifiers(usb_key_modifiers_w),
        .key_0        (usb_key_w[0]),
        .key_1        (usb_key_w[1]),
        .key_2        (usb_key_w[2]),
        .key_3        (usb_key_w[3]),
        .key_4        (usb_key_w[4]),
        .key_5        (usb_key_w[5]),

        .mouse_btn    (usb_mouse_btn_w),
        .mouse_dx     (usb_mouse_dx_w),
        .mouse_dy     (usb_mouse_dy_w),

        .game_l       (usb_game_l_w),
        .game_r       (usb_game_r_w),
        .game_u       (usb_game_u_w),
        .game_d       (usb_game_d_w),
        .game_a       (usb_game_a_w),
        .game_b       (usb_game_b_w),
        .game_x       (usb_game_x_w),
        .game_y       (usb_game_y_w),
        .game_sel     (usb_game_sel_w),
        .game_sta     (usb_game_sta_w),
        .game_extra   (usb_game_extra_w),

        .dbg_hid_report(),
        .dbg_hid_regs (),

        .rom_addr     (usb_rom_addr_w),
        .rom_dout     (usb_rom_dout_w),
        .rom_en       (usb_rom_en_w)
    );

    // -----------------------------------------------------------------
    // HID report capture (clk_usb) + CDC into clk_logic for the ESP32
    // readback registers (0x16-0x1B). Values are latched per full report
    // and quasi-static between reports, so double-flop synchronizers are
    // sufficient.
    // -----------------------------------------------------------------
    reg [1:0] hid_typ_usb_r;
    reg [3:0] hid_report_cnt_usb_r;
    reg [7:0] pad_btns0_usb_r;   // {Y,X,B,A,R,L,D,U}
    reg [7:0] pad_btns1_usb_r;   // {extra[3:0],2'b0,START,SELECT}
    reg [7:0] key_mod_usb_r;
    reg [7:0] key0_usb_r, key1_usb_r;

    always @(posedge clk_usb_w) begin
        if (usb_reset_w) begin
            hid_typ_usb_r <= 2'd0;
            hid_report_cnt_usb_r <= 4'd0;
            pad_btns0_usb_r <= 8'd0;
            pad_btns1_usb_r <= 8'd0;
            key_mod_usb_r <= 8'd0;
            key0_usb_r <= 8'd0;
            key1_usb_r <= 8'd0;
        end else if (usb_report_w) begin
            hid_typ_usb_r <= usb_typ_w;
            hid_report_cnt_usb_r <= hid_report_cnt_usb_r + 4'd1;
            if (usb_typ_w == 2'd3) begin
                pad_btns0_usb_r <= {usb_game_y_w, usb_game_x_w, usb_game_b_w, usb_game_a_w,
                                    usb_game_r_w, usb_game_l_w, usb_game_d_w, usb_game_u_w};
                pad_btns1_usb_r <= {usb_game_extra_w, 2'b00, usb_game_sta_w, usb_game_sel_w};
            end
            if (usb_typ_w == 2'd1) begin
                key_mod_usb_r <= usb_key_modifiers_w;
                key0_usb_r <= usb_key_w[0];
                key1_usb_r <= usb_key_w[1];
            end
        end
    end

    reg [1:0] hid_typ_sync0, hid_typ_sync1;
    reg       hid_connerr_sync0, hid_connerr_sync1;
    reg [3:0] hid_cnt_sync0, hid_cnt_sync1;
    reg [7:0] pad_btns0_sync0, pad_btns0_sync1;
    reg [7:0] pad_btns1_sync0, pad_btns1_sync1;
    reg [7:0] key_mod_sync0, key_mod_sync1;
    reg [7:0] key0_sync0, key0_sync1;
    reg [7:0] key1_sync0, key1_sync1;

    always @(posedge clk_logic_w) begin
        hid_typ_sync0 <= hid_typ_usb_r;         hid_typ_sync1 <= hid_typ_sync0;
        hid_connerr_sync0 <= usb_connerr_w;     hid_connerr_sync1 <= hid_connerr_sync0;
        hid_cnt_sync0 <= hid_report_cnt_usb_r;  hid_cnt_sync1 <= hid_cnt_sync0;
        pad_btns0_sync0 <= pad_btns0_usb_r;     pad_btns0_sync1 <= pad_btns0_sync0;
        pad_btns1_sync0 <= pad_btns1_usb_r;     pad_btns1_sync1 <= pad_btns1_sync0;
        key_mod_sync0 <= key_mod_usb_r;         key_mod_sync1 <= key_mod_sync0;
        key0_sync0 <= key0_usb_r;               key0_sync1 <= key0_sync0;
        key1_sync0 <= key1_usb_r;               key1_sync1 <= key1_sync0;
    end

    // =========================================================================
    // OSD text overlay — ESP32 menu/console text page (clk_pixel domain)
    // =========================================================================
    // Painted over the framebuffer output (opaque when enabled), upstream of
    // the DebugOverlay. The text page BSRAM lives in the ESP32 OSPI connector
    // (XFER SPACE 1); its port B is clocked here in clk_pixel.

    wire [10:0] osd_vram_addr_w;
    wire [7:0]  osd_vram_data_w;
    wire [23:0] osd_rgb_w;

    // ESP32-controlled video interface (declared here because the OSD enable
    // is consumed in this section; driven by esp32_ospi_connector below)
    video_control_if esp_video_control_if();

    // OSD enable: quasi-static, CDC from clk_logic to clk_pixel
    reg osd_en_sync0, osd_en_sync1;
    always @(posedge clk_pixel_w) begin
        osd_en_sync0 <= esp_video_control_if.enable;
        osd_en_sync1 <= osd_en_sync0;
    end

    osd_text_overlay #(
        .X_OFFSET(80),
        .Y_OFFSET(48)
    ) osd_overlay (
        .clk_i      (clk_pixel_w),
        .reset_n    (device_reset_n_w),
        .enable_i   (osd_en_sync1),

        .screen_x_i (hdmi_cx_w),
        .screen_y_i (hdmi_cy_w),

        .vram_addr_o(osd_vram_addr_w),
        .vram_data_i(osd_vram_data_w),

        .r_i        (fb_rgb_w[23:16]),
        .g_i        (fb_rgb_w[15:8]),
        .b_i        (fb_rgb_w[7:0]),

        .r_o        (osd_rgb_w[23:16]),
        .g_o        (osd_rgb_w[15:8]),
        .b_o        (osd_rgb_w[7:0])
    );

    // =========================================================================
    // Debug Overlay — runs in clk_pixel (27 MHz) domain
    // =========================================================================
    // The 480p framebuffer's overlay interface (hdmi_cx, hdmi_cy, fb_rgb_o,
    // overlay_rgb_i, overlay_en_i) is in the clk_pixel domain, so DebugOverlay
    // must also run in clk_pixel.

    // CDC for debug hex values: double-flop from clk_logic to clk_pixel
    // These are quasi-static values, so double-flop is sufficient
    reg [7:0] dbg_hex_sync0 [8], dbg_hex_sync1 [8];
    reg [7:0] dbg_bits0_sync0, dbg_bits0_sync1;
    reg [7:0] dbg_bits1_sync0, dbg_bits1_sync1;
    always @(posedge clk_pixel_w) begin
        // Hex 0: DDR3 arbiter state {state[2:0], init, cmd_rdy, rd_valid, pending[1:0]}
        dbg_hex_sync0[0] <= ddr3_dbg_arb_state_w;
                                                dbg_hex_sync1[0] <= dbg_hex_sync0[0];
        // Hex 1: req_pending bitmask for all 6 ports
        dbg_hex_sync0[1] <= {2'b0, ddr3_dbg_req_pending_w};
                                                dbg_hex_sync1[1] <= dbg_hex_sync0[1];
        // Hex 2: BEAT EXTRA (sticky) — read beats that arrived when none
        // were expected. Nonzero = arbiter/CDC duplicated a request.
        // (Was VGC missed-hsync, confirmed 00 — repurposed for the
        // multi-outstanding read experiment.)
        dbg_hex_sync0[2] <= fb_dbg_beat_extra_w;
                                                dbg_hex_sync1[2] <= dbg_hex_sync0[2];
        // Hex 3: LINE NOT READY TOTAL — cumulative since reset (sticky,
        // saturates at FF). Nonzero = display read a line-buffer bank that
        // held the wrong line at least once since power-up. Catches rare
        // events the per-frame counters flash too briefly to read.
        dbg_hex_sync0[3] <= fb_dbg_line_not_ready_total_w;
                                                dbg_hex_sync1[3] <= dbg_hex_sync0[3];
        // Hex 4: SHADOW WRITE DROPS (sticky) — CPU shadow writes lost
        // because the 8-deep shadow write FIFO was full. Should stay 00;
        // nonzero = port 3 is being starved longer than ~8 CPU writes.
        dbg_hex_sync0[4] <= shadow_dbg_drop_w;
                                                dbg_hex_sync1[4] <= dbg_hex_sync0[4];
        // Hex 5: RD FIFO DROP — read beats dropped because rd_fifo was full.
        // Nonzero = data loss in the read response path (corruption source).
        dbg_hex_sync0[5] <= fb_dbg_rd_fifo_drop_w;
                                                dbg_hex_sync1[5] <= dbg_hex_sync0[5];
        // Hex 6: LINE LAG MAX — peak display-vs-completed-line lag in lines.
        // 0 = fetcher always ahead of display. Nonzero = fetcher falling
        // behind; higher = worse. Clamped to 0xFF.
        dbg_hex_sync0[6] <= fb_dbg_line_lag_max_w;
                                                dbg_hex_sync1[6] <= dbg_hex_sync0[6];
        // Hex 7: LINE NOT READY — primary symptom counter. Display-line
        // advances where the expected line had not yet been fetched.
        dbg_hex_sync0[7] <= fb_dbg_line_not_ready_w;
                                                dbg_hex_sync1[7] <= dbg_hex_sync0[7];
        // Bits 0: framebuffer status flags
        dbg_bits0_sync0 <= fb_dbg_flags_w;
        dbg_bits0_sync1 <= dbg_bits0_sync0;
        // Bits 1: video mode flags
        dbg_bits1_sync0 <= {pll_lock_w, init_calib_complete_w, a2mem_if.MIXED_MODE,
                            a2mem_if.HIRES_MODE, a2mem_if.RAMWRT, a2mem_if.STORE80,
                            a2bus_if.system_reset_n, a2bus_if.device_reset_n};
        dbg_bits1_sync1 <= dbg_bits1_sync0;
    end

    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),
        .ENABLE(1'b1),
        .X_OFFSET(16),
        .Y_OFFSET(24)
    ) debug_overlay (
        .clk_i          (clk_pixel_w),
        .reset_n        (device_reset_n_w),
        .enable_i       (1'b1),

        .hex_values     ('{dbg_hex_sync1[0], dbg_hex_sync1[1], dbg_hex_sync1[2], dbg_hex_sync1[3],
                           dbg_hex_sync1[4], dbg_hex_sync1[5], dbg_hex_sync1[6], dbg_hex_sync1[7]}),

        .debug_bits_0_i (dbg_bits0_sync1),
        .debug_bits_1_i (dbg_bits1_sync1),

        .screen_x_i     (hdmi_cx_w),
        .screen_y_i     (hdmi_cy_w),

        .r_i            (osd_rgb_w[23:16]),
        .g_i            (osd_rgb_w[15:8]),
        .b_i            (osd_rgb_w[7:0]),

        .r_o            (overlay_rgb_w[23:16]),
        .g_o            (overlay_rgb_w[15:8]),
        .b_o            (overlay_rgb_w[7:0])
    );

    assign overlay_en_w = 1'b1;

    // =========================================================================
    // ESP32 Octal SPI Interface
    // =========================================================================

    wire [7:0] esp_data_i;
    wire [7:0] esp_data_o;
    wire       esp_data_oe;

    // Bidirectional I/O buffers for Octal SPI data lines
    IOBUF esp_data_iobuf[7:0] (
        .O  (esp_data_i),       // Input from pads
        .IO (esp_data),         // Bidirectional pads
        .I  (esp_data_o),       // Output to pads
        .OEN(!esp_data_oe)      // Output enable (active low for IOBUF)
    );

    // SCLK goes to the connector RAW: the protocol processor has its own
    // 2FF synchronizer, and stacking cdc_denoise on top skewed the byte
    // sample point 55-110 ns past the SCLK edge — beyond the master's
    // data-change edge at 10+ MHz, which made the FPGA deaf to the link
    // (live-debugged failure). Matched 2FF-vs-2FF paths sample mid-window.

    // ESP32 control interfaces. The F18A GPU interface is a placeholder (the
    // SuperSprite has its own tied-off instance); esp_video_control_if.enable
    // gates the OSD text overlay.
    f18a_gpu_if esp_f18a_gpu_if();

    // =========================================================================
    // Video-pipeline debug readback (OSPI regs 0x70-0x77)
    // =========================================================================
    // $C029 (NEWVIDEO) write tap — counts every write the FPGA's bus decode
    // sees and keeps the last data byte. Distinguishes "the SHR-clear write
    // never reached us" from "captured but the display didn't follow" when
    // the screen sticks in SHR after the TransWarp GS splash.
    reg [7:0] dbg_c029_cnt_r  = 8'd0;
    reg [7:0] dbg_c029_last_r = 8'd0;
    always @(posedge clk_logic_w) begin
        if (!a2bus_if.rw_n && a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC029)) begin
            dbg_c029_cnt_r  <= dbg_c029_cnt_r + 8'd1;
            dbg_c029_last_r <= a2bus_if.data;
        end
    end

    // Live mode snapshot: captured soft switches + the actual framebuffer mux
    wire [7:0] dbg_video_ss_w = {use_vgc_r, a2mem_if.SHRG_MODE,
                                 a2mem_if.LINEARIZE_MODE, a2mem_if.STORE80,
                                 a2mem_if.PAGE2, a2mem_if.MIXED_MODE,
                                 a2mem_if.HIRES_MODE, a2mem_if.TEXT_MODE};

    // Per-port CDC response-FIFO overflow stickies (clk_ddr → clk_logic 2FF;
    // sticky, so multi-bit skew is harmless)
    reg [7:0] dbg_resp_ovfl_sync0, dbg_resp_ovfl_sync1;
    always @(posedge clk_logic_w) begin
        dbg_resp_ovfl_sync0 <= {2'b00, ddr3_dbg_resp_ovfl_w};
        dbg_resp_ovfl_sync1 <= dbg_resp_ovfl_sync0;
    end

    // Octal SPI connector instance
    esp32_ospi_connector #(
        .USE_SYNC(1),
        .USE_CRC(0),
        .IDLE_TO_CYC(5_400_000),  // ~100ms at 54MHz
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) esp32_ospi (
        .clk(clk_logic_w),
        .rst_n(device_reset_n_w),
        .sclk(esp_sclk),
        .data_i(esp_data_i),
        .data_o(esp_data_o),
        .data_oe(esp_data_oe),

        .slotmaker_config_if(slotmaker_config_if),
        .f18a_gpu_if(esp_f18a_gpu_if),
        .video_control_if(esp_video_control_if),
        .volumes(volumes),
        .hdd_volumes(hdd_volumes),
        .a2bus_control_if(a2bus_control_if),

        .disk_ram_if(disk_ram_if),
        .hdd_ram_if(hdd_ram_if),

        .ddr3_ready_i(init_calib_complete_w),
        .a2_reset_n_i(a2_reset_n),

        .pad_typ_i(hid_typ_sync1),
        .pad_connerr_i(hid_connerr_sync1),
        .pad_report_cnt_i(hid_cnt_sync1),
        .pad_btns0_i(pad_btns0_sync1),
        .pad_btns1_i(pad_btns1_sync1),
        .key_mod_i(key_mod_sync1),
        .key0_i(key0_sync1),
        .key1_i(key1_sync1),

        .dbg_video_ss_i(dbg_video_ss_w),
        .dbg_c029_cnt_i(dbg_c029_cnt_r),
        .dbg_c029_last_i(dbg_c029_last_r),
        .dbg_vgc_hsync_i(vgc_dbg_missed_hsync_w),
        .dbg_shadow_drop_i(shadow_dbg_drop_w),
        .dbg_fb_flags_i(fb_dbg_flags_w),
        .dbg_resp_ovfl_i(dbg_resp_ovfl_sync1),
        .dbg_shadow_rd_i(shadow_dbg_rd_state_w),

        .w5100_host_wr(u2_host_wr_w),
        .w5100_host_addr(u2_host_addr_w),
        .w5100_host_wdata(u2_host_wdata_w),
        .w5100_host_rdata(u2_host_rdata_w),
        .w5100_cmd_pending(u2_cmd_pending_w),
        .w5100_cmd_clr(u2_cmd_clr_w),

        .scratch_o(),
        .mcu_ready_o(),

        .osd_clk_i(clk_pixel_w),
        .osd_addr_i(osd_vram_addr_w),
        .osd_data_o(osd_vram_data_w)
    );

    /*
    // Data bus IOBUF instantiation
    wire [7:0] cpu_data_in;
    wire [7:0] cpu_data_out;
    wire       cpu_data_oe;
    
    // Gowin IOBUF primitive - adjust to match your library
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : data_iobuf
            IOBUF data_buf (
                .O  (cpu_data_in[i]),
                .IO (DATA[i]),
                .I  (cpu_data_out[i]),
                .OEN(~cpu_data_oe)      // Gowin OEN is active low
            );
        end
    endgenerate
    */

endmodule

module reset_sync (
  input  wire clk,
  input  wire arst,   // async reset in, active-high
  output wire srst    // sync reset out, active-high
);
  reg [1:0] ff;

  always @(posedge clk or posedge arst) begin
    if (arst)
      ff <= 2'b11;          // assert immediately (async)
    else
      ff <= {ff[0], 1'b0};  // deassert cleanly (sync)
  end

  assign srst = ff[1];
endmodule