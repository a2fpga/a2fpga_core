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

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
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

    output ESP32_GPIO_0,

    // uart
    output  uart_tx,
    input  uart_rx

);


    reg led_r;
    reg [25:0] led_counter_r;

    always @(posedge clk) begin
        if (led_counter_r == 26'd24_999_999) begin
            led_counter_r <= 0;
            led_r <= ~led_r;  // Toggle LED every 0.5s, so full blink is 1s
        end else begin
            led_counter_r <= led_counter_r + 1;
        end
    end

    assign ESP32_GPIO_0 = !led_r;


    // Clocks

    wire clk_lock_w;
    wire clk_pixel_w;
    wire clk_logic_w;
    wire clk_hdmi_w;

    Gowin_PLL your_instance_name(
        .clkin(clk), //input  clkin
        .clkout0(clk_pixel_w), //output  clkout0
        .clkout1(clk_logic_w), //output  clkout1
        .clkout2(clk_hdmi_w), //output  clkout2
        .lock(clk_lock_w), //output  lock
        .mdclk(clk), //input  mdclk
        .reset(1'b0) //input  reset
    );

    // Reset

    wire device_reset_n_w;
    Reset_Sync u_Reset_Sync (
		.resetn(device_reset_n_w),
		.ext_reset(clk_lock_w),
		.clk(clk_logic_w)
	);

    //wire device_reset_n_w = ~rst;

    wire system_reset_n_w = device_reset_n_w;

    // Translate Phi1 into the clk_logic clock domain and derive Phi0 and edges
    // delays Phi1 by 2 cycles = 40ns
    wire phi1;
    wire phi0;
    wire phi1_posedge;
    wire phi1_negedge;
    cdc_denoise cdc_phi1 (
        .clk(clk_logic_w),
        .i(a2_phi1),
        .o(phi1),
        .o_n(phi0),
        .o_posedge(phi1_posedge),
        .o_negedge(phi1_negedge)
    );

    wire clk_2m_w;
    wire clk_2m_posedge_w;
    wire clk_2m_negedge_w;
    cdc_denoise cdc_2m (
        .clk(clk_logic_w),
        .i(a2_q3),
        .o(clk_2m_w),
        .o_n(),
        .o_posedge(clk_2m_posedge_w),
        .o_negedge(clk_2m_negedge_w)
    );

    wire clk_7m_w;
    wire clk_7m_posedge_w;
    wire clk_7m_negedge_w;
    wire clk_14m_posedge_w = clk_7m_posedge_w | clk_7m_negedge_w;
    cdc_denoise cdc_7m (
        .clk(clk_logic_w),
        .i(a2_7M),
        .o(clk_7m_w),
        .o_n(),
        .o_posedge(clk_7m_posedge_w),
        .o_negedge(clk_7m_negedge_w)
    );

    // Interface to Apple II

    // Buffer/level shifters are held in tri-state
    // during FPGA configuration to ensure no interference
    // with the Apple II bus.
    assign a2_bus_oe = 1'b1;

    // Address bus is input-only unless performing DMA
    // 0 = from Apple II bus to FPGA, 1 = from FPGA to Apple II bus
    assign a2_a_dir  = 1'b0;

    // data and address latches on input

    a2bus_if a2bus_if (
        .clk_logic(clk_logic_w),
        .clk_pixel(clk_pixel_w),
        .system_reset_n(system_reset_n_w),
        .device_reset_n(device_reset_n_w),
        .phi0(phi0),
        .phi1(phi1),
        .phi1_posedge(phi1_posedge),
        .phi1_negedge(phi1_negedge),
        .clk_2m_posedge(clk_2m_posedge_w),
        .clk_7m(clk_7m_w),
        .clk_7m_posedge(clk_7m_posedge_w),
        .clk_7m_negedge(clk_7m_negedge_w),
        .clk_14m_posedge(clk_14m_posedge_w)
    );

    wire sleep_w;

    wire irq_n_w;
    assign a2_irq_n = IRQ_OUT_ENABLE ? irq_n_w : 1'b1;

    wire sw_scanlines_w = '1;
    wire sw_apple_speaker_w = '1;
    wire sw_slot_7_w = '0;
    wire sw_gs_w = '0;

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
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) apple_bus (
        .a2bus_if(a2bus_if),

        .a2_a_i(a2_a),
        .a2_d_i(a2_d_buf_w),
        .a2_rw_n_i(a2_rw_n),

        .clk_2m_negedge_i(clk_2m_negedge_w),
        
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
    wire [15:0] ssp_audio_w;
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
    wire [15:0] audio_sample_word[1:0];
    audio_out #(
        .CLK_RATE(CLOCK_SPEED_HZ / 2),
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

        .is_signed(1'b0),
        .core_l(ssp_audio_w + {mb_audio_l, 5'b00} + {speaker_audio_w, 13'b0}),
        .core_r(ssp_audio_w + {mb_audio_r, 5'b00} + {speaker_audio_w, 13'b0}),

        .audio_clk(clk_audio_w),
        .audio_l(audio_sample_word[0]),
        .audio_r(audio_sample_word[1])
    );

    // HDMI

    logic [2:0] tmds;
    wire tmdsClk;

    wire scanline_en = scanlines_w && hdmi_y[0];

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
            scanline_en ? {1'b0, rgb_r_w[7:1]} : rgb_r_w,
            scanline_en ? {1'b0, rgb_g_w[7:1]} : rgb_g_w,
            scanline_en ? {1'b0, rgb_b_w[7:1]} : rgb_b_w
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

module Reset_Sync (
    input clk,
    input ext_reset,
    output resetn
);

    reg [3:0] reset_cnt = 0;

    always @(posedge clk or negedge ext_reset) begin
        if (~ext_reset)
            reset_cnt <= 4'b0;
        else
            reset_cnt <= reset_cnt + !resetn;
    end

    assign resetn = &reset_cnt;

endmodule