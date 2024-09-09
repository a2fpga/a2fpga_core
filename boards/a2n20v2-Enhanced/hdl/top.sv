//
// Top module for Tang Nano 20K and A2N20v2 Apple II card
//
// This version uses the Tang Nano 20K SDRAM for extended functionality
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

// Using the Gowin IDE
`define GW_IDE

// Ensoniq, PicoSoC, and DiskII are included via defines in the top module
// Disk II requires PicoSoC

`undef ENSONIQ
`define PICOSOC
`undef DISKII

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 0,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter SUPERSPRITE_SLOT = 7,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter MOCKINGBOARD_SLOT = 4,

    parameter bit SUPERSERIAL_ENABLE = 0,
    parameter SUPERSERIAL_SLOT = 2,

    parameter bit DISK_II_ENABLE = 1,
    parameter DISK_II_SLOT = 5,

    parameter bit ENSONIQ_ENABLE = 1,

    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit SHADOW_ALL_MEMORY = 0,        // Shadoow all memory in SDRAM, not just video ram
    parameter bit HDMI_SLEEP_ENABLE = 1,        // Sleep HDMI output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1       // Allow driving data to Apple bus

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
    output uart_tx,
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

    wire clk_logic_w;
    wire clk_logic_p_w;
    wire clk_logic_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_hdmi_lock_w;
    wire hdmi_rst_n_w;
    wire a2_2M;

    // PLL - 100Mhz from 27
    clk_logic clk_logic_inst (
        .clkout(clk_logic_w),  //output clkout
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_logic_p_w),  //output clkoutp
        .clkoutd(clk_pixel_w),  //output clkoutd
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    // PLL - 125Mhz from 25
    clk_hdmi clk_hdmi_inst (
        .clkout(clk_hdmi_w),  //output clkout
        .lock(clk_hdmi_lock_w),  //output lock
        .reset(~clk_logic_lock_w),  //input reset
        .clkin(clk_pixel_w)  //input clkin
    );

    // Reset

    wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;

    wire system_reset_n_w = device_reset_n_w & a2_reset_n;

    // Translate Phi1 into the clk_logic clock domain and derive Phi0 and edges
    // delays Phi1 by 2 cycles = 40ns
    wire phi1;
    wire phi0;
    wire phi1_posedge;
    wire phi1_negedge;
    wire clk_2m_posedge_w = phi1_posedge | phi1_negedge;
    cdc cdc_phi1 (
        .clk(clk_logic_w),
        .i(a2_phi1),
        .o(phi1),
        .o_n(phi0),
        .o_posedge(phi1_posedge),
        .o_negedge(phi1_negedge)
    );

    wire clk_7m_w;
    wire clk_7m_posedge_w;
    wire clk_7m_negedge_w;
    wire clk_14m_posedge_w = clk_7m_posedge_w | clk_7m_negedge_w;
    cdc cdc_7m (
        .clk(clk_logic_w),
        .i(a2_7M),
        .o(clk_7m_w),
        .o_n(),
        .o_posedge(clk_7m_posedge_w),
        .o_negedge(clk_7m_negedge_w)
    );

    // SDRAM Controller signals
    wire sdram_init_complete;

    // SDRAM ports, lower number is higher priority
    localparam VIDEO_MEM_PORT = 0;
    localparam MAIN_MEM_PORT = 1;
`ifdef ENSONIQ
    localparam GLU_MEM_PORT = 2;
    localparam DOC_MEM_PORT = 3;
    `ifdef PICOSOC
    localparam SOC_MEM_PORT = 4;
        `ifdef DISKII
    localparam RAMDISK_MEM_PORT = 5;
    localparam NUM_PORTS = 6;
        `else
    localparam NUM_PORTS = 5;
        `endif
    `else
    localparam NUM_PORTS = 4;
    `endif
`else
    `ifdef PICOSOC
    localparam SOC_MEM_PORT = 2;
        `ifdef DISKII
    localparam RAMDISK_MEM_PORT = 3;
    localparam NUM_PORTS = 4;
        `else
    localparam NUM_PORTS = 3;
        `endif
    `else
    localparam NUM_PORTS = 2;
    `endif
`endif

    localparam PORT_ADDR_WIDTH = 21;
    localparam DATA_WIDTH = 32;
    localparam DQM_WIDTH = 4;
    localparam PORT_OUTPUT_WIDTH = 32;

    // Signals for the multiple ports
    sdram_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports[NUM_PORTS-1:0]();

    sdram_ports #(
        .CLOCK_SPEED_MHZ(MEM_MHZ),
        .NUM_PORTS(NUM_PORTS),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
        .CAS_LATENCY(2),
        .SETTING_REFRESH_TIMER_NANO_SEC(15000),
        .SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC(16),
        .BURST_LENGTH(1),
        .PORT_BURST_LENGTH(1),
        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(11),
        .COL_WIDTH(8),
        .PRECHARGE_BIT(10),
        .DQM_WIDTH(DQM_WIDTH)
    ) sdram_ports (
        .clk(clk_logic_w),
        .sdram_clk(clk_logic_p_w),
        .reset(!device_reset_n_w),
        .init_complete(sdram_init_complete),

        .ports(mem_ports),

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

    // Interface to Apple II

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

    apple_bus #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .BUS_DATA_OUT_ENABLE(BUS_DATA_OUT_ENABLE),
        .IRQ_OUT_ENABLE(IRQ_OUT_ENABLE)
    ) apple_bus (
        .a2bus_if(a2bus_if),

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

        .dip_switches_n_o(dip_switches_n_w),

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

    apple_memory apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(mem_ports[MAIN_MEM_PORT]),
        .video_mem_if(mem_ports[VIDEO_MEM_PORT]),

        .video_address_i(video_address_w),
        .video_bank_i(video_bank_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w)
    );

`ifdef PICOSOC

    // PicoSOC

    wire picosoc_irq_n;
    wire [0:7] picosoc_d_w;
    wire picosoc_rd_w;
    wire picosoc_uart_rx_w;
    wire picosoc_uart_tx_w;

    assign uart_tx = picosoc_uart_tx_w;
    assign picosoc_uart_rx_w = uart_rx;

    wire picosoc_led;

    video_control_if video_control_if();

    f18a_gpu_if f18a_gpu_if();

    drive_volume_if volumes[2]();

    picosoc #(
        .ENABLE(1'b1),  // Enable the soc
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) picosoc (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .data_o (picosoc_d_w),
        .rd_en_o(picosoc_rd_w),
        .irq_n_o(picosoc_irq_n),

        .uart_rx_i(picosoc_uart_rx_w),
        .uart_tx_o(picosoc_uart_tx_w),

        .sd_mosi_o(sd_cmd),
        .sd_sclk_o(sd_clk),
        .sd_cs_o  (sd_dat3),
        .sd_miso_i(sd_dat0),

        .button_i(s2),
        .led_o(picosoc_led),

        .f18a_gpu_if(f18a_gpu_if),
        .video_control_if(video_control_if),
        .mem_if(mem_ports[SOC_MEM_PORT]),
        .volumes(volumes)
    );

    // PicoSoC is required for the Disk II controller

    wire [7:0] diskii_d_w;
    wire diskii_rd;

    `ifdef DISKII

    DiskII #(
        .ENABLE(DISK_II_ENABLE),
        .SLOT(DISK_II_SLOT)
    ) diskii (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .data_o(diskii_d_w),
        .rd_en_o(diskii_rd),

        .ram_disk_if(mem_ports[RAMDISK_MEM_PORT]),

        .volumes(volumes)
    );
    `else
    assign diskii_d_w = 8'b0;
    assign diskii_rd = 1'b0;

    assign volumes[0].active = 1'b0;
    assign volumes[0].lba = 32'd0;
    assign volumes[0].blk_cnt = 6'd0;
    assign volumes[0].rd = 1'b0;
    assign volumes[0].wr = 1'b0;


    assign volumes[1].active = 1'b0;
    assign volumes[1].lba = 32'd0;
    assign volumes[1].blk_cnt = 6'd0;
    assign volumes[1].rd = 1'b0;
    assign volumes[1].wr = 1'b0;
    
    `endif


`else

    // Stub out the external interfaces if not using PicoSOC

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


    wire [7:0] diskii_d_w = 8'b0;
    wire diskii_rd = 1'b0;

`endif

    // Video

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

    wire [15:0] sg_audio_l;
    wire [15:0] sg_audio_r;
`ifdef ENSONIQ
    wire [7:0] sg_d_w;
    wire sg_rd_w;

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE)  
    ) sg (
        .a2bus_if(a2bus_if),
        .data_o(sg_d_w),                 
        .rd_en_o(sg_rd_w),
        .irq_n_o(),

        .audio_l_o(sg_audio_l),               
        .audio_r_o(sg_audio_r),
        .glu_mem_if(mem_ports[GLU_MEM_PORT]),
        .doc_mem_if(mem_ports[DOC_MEM_PORT])
    );
`else
    assign sg_audio_l = 16'b0;
    assign sg_audio_r = 16'b0;
`endif

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

    SuperSprite #(
        .ENABLE(SUPERSPRITE_ENABLE),
        .SLOT(SUPERSPRITE_SLOT),
        .FORCE_VDP_OVERLAY(SUPERSPRITE_FORCE_VDP_OVERLAY)
    ) supersprite (
        .a2bus_if(a2bus_if),

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
        .SLOT(MOCKINGBOARD_SLOT)
    ) mockingboard (
        .a2bus_if(a2bus_if),  // use system_reset_n
        .a2mem_if(a2mem_if),

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
    `ifndef PICOSOC
    assign ssc_uart_rx = uart_rx;
    assign uart_tx = ssc_uart_tx;
    `endif

    SuperSerial #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE(SUPERSERIAL_ENABLE),
        .SLOT(SUPERSERIAL_SLOT)
    ) superserial (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .data_o(ssc_d_w),
        .rd_en_o(ssc_rd),
        .irq_n_o(ssc_irq_n),

        .rom_en_o(ssc_rom_en),
        .uart_rx_i(ssc_uart_rx),
        .uart_tx_o(ssc_uart_tx)
    );

    // Data output

    assign data_out_en_w = ssp_rd || mb_rd || ssc_rd || diskii_rd;

    assign data_out_w = ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w : 
        mb_rd ? mb_d_w : 
        diskii_rd ? diskii_d_w :
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

    always @(posedge clk_logic_w) begin 
        if (!s2) led <= {4'b1111, !picosoc_led};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.SHRG_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end


endmodule
