//
// Top module for Tang Primer 25K and A2P25 Apple II card
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
    parameter bit APPLE_SPEAKER_ENABLE = 0,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter bit [7:0] SUPERSPRITE_ID = 1,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    parameter bit SUPERSERIAL_ENABLE = 1,
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter int GS = 1,                       // Apple IIgs mode
    parameter int ENABLE_ESP32_AUDIO = 1,       // Enable audio input from ESP32
    parameter int ENABLE_FILTER = 0,            // Enable audio filtering
    parameter int ENABLE_BUS_STREAM = 1,        // Enable bus streaming to ESP32
    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit HDMI_SLEEP_ENABLE = 0,        // Sleep HDMI output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1       // Allow driving data to Apple bus

) (
    // fpga clocks
    input clk,

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

    input esp32_spi_sclk,
    input esp32_spi_mosi,
    output esp32_spi_miso,

    output esp32_parl_frame,
    output esp32_parl_clk,
    output [3:0] esp32_parl_d,

    output esp32_i2s_bclk,
    output esp32_i2s_lrclk,
    input esp32_i2s_data,

    // uart
    output  uart_tx,
    input  uart_rx

);

    // Clocks

    wire clk_logic_w;
    wire clk_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_27M_w;

    Gowin_PLL clocks_pll (
        .lock(clk_lock_w), //output  lock
        .clkout0(clk_27M_w), //output  clkout0
        .clkout1(clk_hdmi_w), //output  clkout1
        .clkout2(clk_logic_w), //output  clkout2
        .clkin(clk), //input  clkin
        .mdclk(clk) //input  mdclk
    );

    CLKDIV clkdiv_inst (
        .HCLKIN(clk_hdmi_w),
        .RESETN(clk_lock_w),
        .CALIB(1'b0),
        .CLKOUT(clk_pixel_w)
    );
    defparam clkdiv_inst.DIV_MODE="5";

    // LED blinking logic with ES5503 counter indication
    reg led_r = 1'b0;
    reg [25:0] led_counter_r = 26'd0;
    reg [15:0] prev_es5503_counter_r = 16'd0;
    reg        es5503_activity_r = 1'b0;

    always @(posedge clk_logic_w) begin
        // Track ES5503 counter changes for activity indication
        prev_es5503_counter_r <= es5503_counter_w;
        if (es5503_counter_w != prev_es5503_counter_r) begin
            es5503_activity_r <= 1'b1;
        end
        
        if (led_counter_r == 26'd09_999_999) begin
            led_counter_r <= 0;
            // If ES5503 is active, use fast blink (counter value dependent)
            // Otherwise use slow heartbeat blink
            if (es5503_activity_r) begin
                led_r <= es5503_counter_w[8];  // Blink based on counter bit 8 for ES5503 activity
                es5503_activity_r <= 1'b0;    // Clear activity flag
            end else begin
                led_r <= ~led_r;  // Normal heartbeat every 0.5s
            end
        end else begin
            led_counter_r <= led_counter_r + 1;
        end
    end

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

    wire sleep_w;

    wire irq_n_w;
    assign a2_irq_n = IRQ_OUT_ENABLE && !irq_n_w ? 1'b0 : 1'bz;

    wire sw_scanlines_w = '1;
    wire sw_apple_speaker_w = '1;

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
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) apple_bus (
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_pixel_w),
        .system_reset_n_i(system_reset_n_w),
        .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1),
        .a2_q3_i(a2_q3),
        .a2_7M_i(a2_7M),

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

    // Reset and TEXT_COLOR diagnostics
    reg reset_occurred_r = 1'b0;
    reg device_reset_occurred_r = 1'b0;
    always @(posedge clk_logic_w) begin
        if (!system_reset_n_w) begin
            reset_occurred_r <= 1'b1;  // Latch that system reset occurred
        end
        if (!device_reset_n_w) begin
            device_reset_occurred_r <= 1'b1;  // Latch that device reset occurred
        end
    end

    // Memory

    a2mem_if a2mem_if();

    wire [15:0] video_address_w;
    wire video_bank_w;
    wire video_rd_w;
    wire [31:0] video_data_w;

    wire vgc_active_w;
    wire [12:0] vgc_address_w;
    wire vgc_rd_w;
    wire [31:0] vgc_data_w;

    apple_memory #(
        .VGC_MEMORY(1)
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_address_i(video_address_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w)
    );

    // Apple II Bus Stream to ESP32 CAM Interface

    wire [3:0] cam_data_w;
    wire cam_sync_w;
    wire cam_pclk_w;
    wire activity_led_w;
    wire overflow_led_w;
    wire [7:0] debug_status_w;
    wire [15:0] es5503_counter_w;
    wire [15:0] es5503_access_counter_w;
    wire [15:0] packets_dropped_counter_w;
    wire        cam_overwrite_flag_w;

    // Heartbeat generator for testing when Apple II bus is inactive
    reg [23:0] heartbeat_counter_r;  
    wire heartbeat_pulse_w = (heartbeat_counter_r == 24'd0);
    always @(posedge clk_logic_w) begin
        if (!system_reset_n_w) begin
            heartbeat_counter_r <= 24'd0;
        end else begin
            heartbeat_counter_r <= heartbeat_counter_r + 1;
        end
    end

    a2bus_stream #(
        .ENABLE(ENABLE_BUS_STREAM)
    ) a2bus_stream (
        .a2bus_if(a2bus_if),
        
        .cam_pclk(cam_pclk_w),
        .cam_sync(cam_sync_w),
        .cam_data(cam_data_w),
        
        .capture_enable(1'b1),           // Always enabled
        .capture_mode(3'b111),           // ES5503 only (changed from speaker)
        .heartbeat_pulse(heartbeat_pulse_w),
        .activity_led(activity_led_w),
        .overflow_led(overflow_led_w),
        .debug_status(debug_status_w),
        .es5503_counter(es5503_counter_w),
        .es5503_access_counter(es5503_access_counter_w),
        .packets_dropped_counter(packets_dropped_counter_w),
        .cam_overwrite_flag(cam_overwrite_flag_w)
    );

    // Connect CAM interface signals to ESP32 pins
    assign esp32_parl_clk = cam_pclk_w;      // CAM PCLK
    assign esp32_parl_frame = cam_sync_w;    // CAM SYNC 
    assign esp32_parl_d = cam_data_w;        // CAM 4-bit parallel data


    esp32_spi_connector esp32_spi_connector (
        .clk(clk_logic_w),
        .rst_n(system_reset_n_w),
        .miso(esp32_spi_miso),
        .mosi(esp32_spi_mosi),
        .sclk(esp32_spi_sclk),
        .i2s_sample_l(i2s_sample_l),
        .i2s_sample_r(i2s_sample_r),
        .es5503_access_counter(es5503_access_counter_w),
        .es5503_tx_counter(es5503_counter_w),
        .cam_overwrite_flag(cam_overwrite_flag_w)
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

    wire [9:0] hdmi_x;
    wire [9:0] hdmi_y;
    wire apple_vga_active;
    wire [7:0] apple_vga_r;
    wire [7:0] apple_vga_g;
    wire [7:0] apple_vga_b;

    apple_video apple_video (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_control_if(video_control_if),

        .screen_x_i(hdmi_x),
        .screen_y_i(hdmi_y),

        .video_address_o(video_address_w),
        .video_bank_o(video_bank_w),
        .video_rd_o(video_rd_w),
        .video_data_i(video_data_w),

        .video_active_o(apple_vga_active),
        .video_r_o(apple_vga_r),
        .video_g_o(apple_vga_g),
        .video_b_o(apple_vga_b)
    );

    wire [7:0] vgc_vga_r;
    wire [7:0] vgc_vga_g;
    wire [7:0] vgc_vga_b;

    vgc vgc (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_control_if(video_control_if),

        .cx_i(hdmi_x),
        .cy_i(hdmi_y),

        .apple_vga_r_i(apple_vga_r),
        .apple_vga_g_i(apple_vga_g),
        .apple_vga_b_i(apple_vga_b),

        .vgc_vga_r_o(vgc_vga_r),
        .vgc_vga_g_o(vgc_vga_g),
        .vgc_vga_b_o(vgc_vga_b),

        .R_o(),
        .G_o(),
        .B_o(),

        .vgc_active_o(vgc_active_w),
        .vgc_address_o(vgc_address_w),
        .vgc_rd_o(vgc_rd_w),
        .vgc_data_i(vgc_data_w)
    );

    // SuperSprite

    wire VDP_OVERLAY_SW;
    wire APPLE_VIDEO_SW;
    wire [0:7] ssp_d_w;
    wire ssp_rd;
    wire [3:0] vdp_r;
    wire [3:0] vdp_g;
    wire [3:0] vdp_b;
    wire vdp_transparent;
    wire vdp_ext_video;
    wire vdp_irq_n;
    wire [9:0] ssp_audio_w;
    wire vdp_unlocked_w;
    wire [3:0] vdp_gmode_w;
    wire scanlines_w;

    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;

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

        .screen_x_i(hdmi_x),
        .screen_y_i(hdmi_y),
        .apple_vga_r_i(vgc_vga_r),
        .apple_vga_g_i(vgc_vga_g),
        .apple_vga_b_i(vgc_vga_b),
        .apple_vga_active_i(apple_vga_active),

        .scanlines_i(SCANLINES_ENABLE | sw_scanlines_w),

        .ssp_r_o(rgb_r_w),
        .ssp_g_o(rgb_g_w),
        .ssp_b_o(rgb_b_w),

        .scanlines_o(scanlines_w),

        .vdp_ext_video_o(vdp_ext_video),
        .vdp_unlocked_o(vdp_unlocked_w),
        .vdp_gmode_o(vdp_gmode_w),

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

    // Extend all the unsigned audio signals to 13 bits
    wire [12:0] speaker_audio_ext_w = {speaker_audio_w, 12'b0};
    wire [12:0] ssp_audio_ext_w = {ssp_audio_w, 3'b0};
    wire [12:0] mb_audio_l_ext_w = {mb_audio_l, 3'b0};
    wire [12:0] mb_audio_r_ext_w = {mb_audio_r, 3'b0};

    wire signed [15:0] core_audio_l_w;
    wire signed [15:0] core_audio_r_w;
    // Combine all the audio sources into a single 16-bit signed audio signal
    assign core_audio_l_w = ssp_audio_ext_w + mb_audio_l_ext_w + speaker_audio_ext_w;
    assign core_audio_r_w = ssp_audio_ext_w + mb_audio_r_ext_w + speaker_audio_ext_w;

    // CDC FIFO to shift audio to the pixel clock domain from the logic clock domain

    wire [15:0] cdc_audio_l;
    wire [15:0] cdc_audio_r;

    cdc_sampling #(
        .WIDTH(16)
    ) audio_cdc_left (
        .rst_n(device_reset_n_w),
        .clk_fast(clk_logic_w),
        .clk_slow(clk_pixel_w),
        .data_in(core_audio_l_w),
        .data_out(cdc_audio_l)
    );

    cdc_sampling #(
        .WIDTH(16)
    ) audio_cdc_right (
        .rst_n(device_reset_n_w),
        .clk_fast(clk_logic_w),
        .clk_slow(clk_pixel_w),
        .data_in(core_audio_r_w),
        .data_out(cdc_audio_r)
    );

    localparam [31:0] aflt_rate = 7_056_000;
    localparam [39:0] acx  = 4258969;
    localparam  [7:0] acx0 = 3;
    localparam  [7:0] acx1 = 3;
    localparam  [7:0] acx2 = 1;
    localparam [23:0] acy0 = -24'd6216759;
    localparam [23:0] acy1 =  24'd6143386;
    localparam [23:0] acy2 = -24'd2023767;

    localparam AUDIO_RATE = 44100;  // Match MP3 stream sample rate
    localparam AUDIO_BIT_WIDTH = 16;
    // I2S format: 0=left-justified, 1=standard I2S (1-bit delay)
    localparam I2S_FORMAT = 1'b0;  // Use left-justified (simpler timing)
    wire clk_audio_w;
	wire i2s_data_shift_strobe;
	wire i2s_data_load_strobe;
    audio_timing #(
        .CLK_RATE(PIXEL_SPEED_HZ),
        .AUDIO_RATE(AUDIO_RATE),
        .I2S_STANDARD(I2S_FORMAT)
    ) audio_timing (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),
        .audio_clk(clk_audio_w),
        .i2s_bclk(esp32_i2s_bclk),
        .i2s_lrclk(esp32_i2s_lrclk),
        .i2s_data_shift_strobe(i2s_data_shift_strobe),
        .i2s_data_load_strobe(i2s_data_load_strobe)
    );

    wire signed [15:0] i2s_sample_l;
    wire signed [15:0] i2s_sample_r;
    i2s_receiver i2s_receiver (
        .reset(~device_reset_n_w),
        .clk(clk_pixel_w),

        .i2s_bclk(esp32_i2s_bclk),
        .i2s_lrclk(esp32_i2s_lrclk),
        .i2s_data(esp32_i2s_data),
        .i2s_data_shift_strobe(i2s_data_shift_strobe),
        .i2s_data_load_strobe(i2s_data_load_strobe),
        .i2s_sample_l(i2s_sample_l),
        .i2s_sample_r(i2s_sample_r)
    );

    wire signed [15:0] out_audio_l_w = $signed(cdc_audio_l) + (ENABLE_ESP32_AUDIO ? i2s_sample_l : 0);
    wire signed [15:0] out_audio_r_w = $signed(cdc_audio_r) + (ENABLE_ESP32_AUDIO ? i2s_sample_r : 0);

    wire [15:0] audio_sample_word[1:0];

    audio_out #(
        .CLK_RATE(PIXEL_SPEED_HZ),
        .AUDIO_RATE(AUDIO_RATE),
        .ENABLE(ENABLE_FILTER)
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
        .core_l(out_audio_l_w),
        .core_r(out_audio_r_w),
        .audio_clk(clk_audio_w),
        .audio_l(audio_sample_word[0]),
        .audio_r(audio_sample_word[1])
    );
    
    //assign audio_sample_word[0] = cdc_audio_l;
    //assign audio_sample_word[1] = cdc_audio_r;

    // HDMI

    wire scanline_en = scanlines_w && hdmi_y[0];

    wire show_debug_overlay_r = 1'b1;

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
            es5503_access_counter_w[15:8], // ES5503 access counter high byte (detected)
            es5503_access_counter_w[7:0],  // ES5503 access counter low byte (detected)
            es5503_counter_w[15:8],        // ES5503 transmission counter high byte (sent)
            es5503_counter_w[7:0],         // ES5503 transmission counter low byte (sent)
            packets_dropped_counter_w[15:8], // Packets dropped counter high byte
            packets_dropped_counter_w[7:0],  // Packets dropped counter low byte
            {7'b0, cam_overwrite_flag_w}, // CAM overwrite flag (should be 0 if no overwrites)
            {4'b0, a2mem_if.BACKGROUND_COLOR} // Current BACKGROUND_COLOR value     
        }), 

        .debug_bits_0_i ({a2mem_if.SHRG_MODE, a2mem_if.TEXT_MODE, a2mem_if.MIXED_MODE, a2mem_if.HIRES_MODE, a2mem_if.RAMWRT, a2mem_if.STORE80, a2bus_if.system_reset_n, a2bus_if.device_reset_n}),
        .debug_bits_1_i ({1'b0, 1'b0, 1'b0, 1'b0, 1'b0, led_2m_w, led_phi1_w, led_r}),

        .screen_x_i     (hdmi_x),
        .screen_y_i     (hdmi_y),

        .r_i            (scanline_en ? {1'b0, rgb_r_w[7:1]} : rgb_r_w),
        .g_i            (scanline_en ? {1'b0, rgb_g_w[7:1]} : rgb_g_w),
        .b_i            (scanline_en ? {1'b0, rgb_b_w[7:1]} : rgb_b_w),

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
        /*
        .rgb({
            8'hFF,
            8'h00,
            8'h00
        }),
        */
        .reset(!device_reset_n_w),
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
    /*
    ELVDS_TBUF tmds_bufds[3:0] (
        .I({clk_pixel_w, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n}),
        .OEN(sleep_w && HDMI_SLEEP_ENABLE)
    );
    */

    ELVDS_OBUF tmds_bufds[3:0] (
        .I({clk_pixel_w, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

    /*
    ELVDS_OBUF tmds_bufds[3:0] (
        .I({clk_pixel_w, tmds}),
        .O({tmds_clk_p, tmds_d_n}),
        .OB({tmds_clk_n, tmds_d_p})
    );
    */

    /*
    always @(posedge clk_logic_w) begin 
        if (!button) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.SHRG_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end
    */


endmodule
