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

// Feature selection via defines. The on-FPGA PicoSoC soft core and its Disk II
// RAMDISK have been removed; the coprocessor is the external BL616 MCU.

`define ENSONIQ
`define BL616_SPI

// DUAL_RATE_SDRAM: run the SDRAM controller at 108 MHz (GS-style split clock,
// PLL 27->108 + CLKDIV2 for the 54 MHz logic clock, mem_port_cdc on every
// port). Prerequisite for the beam-accurate framebuffer. Leave undefined for
// the shipping single 54 MHz domain; the a2n20v2_enhanced_dualrate.gprj
// project defines it via top_dualrate.sv and uses the matching .sdc.
//`define DUAL_RATE_SDRAM

`include "datetime.svh"

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

    parameter bit DISK_II_ENABLE = 1,
    parameter bit [7:0] DISK_II_ID = 4,

    parameter bit UTHERNET2_ENABLE = 1,
    parameter bit [7:0] UTHERNET2_ID = 5,

    parameter bit HDD_ENABLE = 1,
    parameter bit [7:0] HDD_ID = 6,

    parameter bit ENSONIQ_ENABLE = 1,
    parameter bit ENSONIQ_MONO_MIX = 0, // If true, mono mix is used instead of stereo

    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit SHADOW_ALL_MEMORY = 0,        // Shadoow all memory in SDRAM, not just video ram
    parameter bit HDMI_SLEEP_ENABLE = 0,        // Sleep HDMI output on CPU stop
    parameter bit FORCE_DEBUG_OVERLAY = 1,      // Always show the debug overlay on the HDMI output
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1,      // Allow driving data to Apple bus

    // Video generation path:
    //   0 = legacy raster-locked apple_video + vgc (combinational on hdmi_x/y)
    //   1 = pixel_stream_if generators (apple_video_gen + vgc_gen) feeding
    //       direct_display, HDMI-locked but using the new interface
    parameter bit USE_PIXEL_STREAM = 1,

    // direct_display hsync cx offsets used to center each window in the 720px
    // visible area (apple = 560 wide, SHR = 640 wide). The apple value differs
    // from the plain a2n20v2 board because the main video read goes through
    // SDRAM (longer priming latency) here. Tune on hardware against a test
    // pattern until each image is centered.
    parameter [9:0] DD_APPLE_H_START = 58,  // was 66; recentered for PIXEL_START_TICK=20 fixed start
    parameter [9:0] DD_VGC_H_START   = 14

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

    output ws2812,

    // uart
    output uart_tx,
    input  uart_rx,

    // MicroSD
    output sd_clk,
    output sd_cmd,      // MOSI
    input  sd_dat0,     // MISO
    //output sd_dat1,   // 1
    //output sd_dat2,   // 1
    output sd_dat3,     // CS

    // BL616 SPI
    input  spi_cs_n,
    input  spi_sclk,
    input  spi_mosi,
    output spi_miso,

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
    wire clk_logic_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_hdmi_lock_w;
    wire hdmi_rst_n_w;
    wire a2_2M;

    wire clk_sdram_w;      // SDRAM controller clock (== clk_logic_w single-rate)
    wire clk_sdram_p_w;    // phase-shifted SDRAM output clock
    wire clk_pixel_pll_w;  // raw clkoutd from PLL

`ifdef DUAL_RATE_SDRAM
    // PLL - 108 MHz from 27 (split clock: SDRAM at 108, logic at 54)
    clk_logic_108 clk_logic_inst (
        .clkout(clk_sdram_w),  //output clkout (108 MHz)
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_sdram_p_w),  //output clkoutp (108 MHz phase-shifted)
        .clkoutd(clk_pixel_pll_w),  //output clkoutd (27 MHz)
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    // 108 MHz -> 54 MHz logic clock
    CLKDIV clkdiv2_inst(
        .CLKOUT(clk_logic_w),
        .HCLKIN(clk_sdram_w),
        .RESETN(rst_n),
        .CALIB(1'b0)
    );
    defparam clkdiv2_inst.DIV_MODE = "2";
    defparam clkdiv2_inst.GSREN = "false";
`else
    // PLL - 54hz from 27
    wire clk_logic_p_w;
    clk_logic clk_logic_inst (
        .clkout(clk_logic_w),  //output clkout
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_logic_p_w),  //output clkoutp
        .clkoutd(clk_pixel_pll_w),  //output clkoutd
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    assign clk_sdram_w = clk_logic_w;
    assign clk_sdram_p_w = clk_logic_p_w;
`endif

    // Force pixel clock onto global clock network via BUFG.
    // Pin 13 (spi_sclk) is a clock-capable pin whose routing conflicts with
    // clkoutd (PR1014), pushing it to generic routing. BUFG ensures the pixel
    // clock reaches the clk_hdmi PLL and all clock sinks reliably.
    BUFG pixel_bufg (
        .O(clk_pixel_w),
        .I(clk_pixel_pll_w)
    );

    // PLL - 135Mhz from 27
    clk_hdmi clk_hdmi_inst (
        .clkout(clk_hdmi_w),  //output clkout
        .lock(clk_hdmi_lock_w),  //output lock
        .reset(~clk_logic_lock_w),  //input reset
        .clkin(clk_pixel_w)  //input clkin
    );

    // Reset

    wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;

    /*
    wire a2_reset_n_w;
    cdc cdc_a2reset (
        .clk(clk_logic_w),
        .i(a2_reset_n),
        .o(a2_reset_n_w),
        .o_n(),
        .o_posedge(),
        .o_negedge()
    );
    */

    wire a2_reset_cdc_w;
    cdc_fifo #(
        .WIDTH(1)
    ) cdc_a2reset (
        .clk(clk_logic_w),
        .i(a2_reset_n),
        .o(a2_reset_cdc_w)
    );

    wire system_reset_n_w = device_reset_n_w & a2_reset_cdc_w;

    // SDRAM Controller signals
    wire sdram_init_complete;

`ifdef DUAL_RATE_SDRAM
    localparam int MEM_CLOCK_MHZ = 108;
`else
    localparam int MEM_CLOCK_MHZ = MEM_MHZ;
`endif

    // SDRAM ports, lower number is higher priority
    localparam VIDEO_MEM_PORT = 0;
    localparam MAIN_MEM_PORT = 1;
`ifdef ENSONIQ
    localparam GLU_MEM_PORT = 3;
    localparam DOC_MEM_PORT = 2;
    `ifdef BL616_SPI
    localparam MCU_MEM_PORT = 4;
    localparam DISK_MEM_PORT = 5;   // Disk II track-on-demand window (read)
    localparam HDD_MEM_PORT = 6;    // ProDOS HDD block window (read/write)
    localparam NUM_PORTS = 7;
    `else
    localparam NUM_PORTS = 4;
    `endif
`else
    `ifdef BL616_SPI
    localparam MCU_MEM_PORT = 2;
    localparam NUM_PORTS = 3;
    `else
    localparam NUM_PORTS = 2;
    `endif
`endif

    localparam PORT_ADDR_WIDTH = 21;
    localparam DATA_WIDTH = 32;
    localparam DQM_WIDTH = 4;
    localparam PORT_OUTPUT_WIDTH = 32;

    // SDRAM memory map — word address offsets (32-bit word addressing)
    // Applied per-port inside sdram_ports via PORT_BASE_ADDR parameter.
    localparam [PORT_ADDR_WIDTH-1:0] SHADOW_WORD_BASE  = 21'h000000;  // 0MB
`ifdef ENSONIQ
    localparam [PORT_ADDR_WIDTH-1:0] ENSONIQ_WORD_BASE = 21'h010000;  // 128KB
`endif
    // Disk II track windows: 2 drives x 8KB, one resident track each. Lives in
    // free SDRAM at byte 0x200000 (word 0x080000). The MCU streams a track here
    // via XFER SPACE 1; drive d's window is byte 0x200000 + d*0x2000.
    localparam [PORT_ADDR_WIDTH-1:0] DISK_WORD_BASE    = 21'h080000;  // byte 0x200000
    // ProDOS HDD block windows: 2 units x 512 bytes, one block each, right
    // after the Disk II track windows. The MCU streams a block here via XFER
    // SPACE 1; unit u's window is byte 0x204000 + u*0x200.
    localparam [PORT_ADDR_WIDTH-1:0] HDD_WORD_BASE     = 21'h081000;  // byte 0x204000

    // Signals for the multiple ports (client side, 54 MHz logic domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports[NUM_PORTS-1:0]();

`ifdef DUAL_RATE_SDRAM
    // SDRAM-side port interfaces (108 MHz domain)
    mem_port_if #(
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) mem_ports_sdram[NUM_PORTS-1:0]();

    wire sdram_init_complete_raw;  // from sdram_ports (108 MHz domain)
`endif

    sdram_ports #(
        .CLOCK_SPEED_MHZ(MEM_CLOCK_MHZ),
        .NUM_PORTS(NUM_PORTS),
        .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH),
`ifdef ENSONIQ
    `ifdef BL616_SPI
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE,
                          SHADOW_WORD_BASE, DISK_WORD_BASE,
                          HDD_WORD_BASE}),
    `else
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          ENSONIQ_WORD_BASE, ENSONIQ_WORD_BASE}),
    `endif
`else
    `ifdef BL616_SPI
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE,
                          SHADOW_WORD_BASE}),
    `else
        .PORT_BASE_ADDR('{SHADOW_WORD_BASE, SHADOW_WORD_BASE}),
    `endif
`endif
        .CAS_LATENCY(2),
        .SETTING_REFRESH_TIMER_NANO_SEC(15000),
        .SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC(16),
`ifdef DUAL_RATE_SDRAM
        .SETTING_USE_FAST_INPUT_REGISTER(1),
        .BURST_LENGTH(2),
        .READ_BURST_LENGTH(8),
`else
        .BURST_LENGTH(1),
`endif
        .PORT_BURST_LENGTH(1),
        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(11),
        .COL_WIDTH(8),
        .PRECHARGE_BIT(10),
        .DQM_WIDTH(DQM_WIDTH)
    ) sdram_ports (
        .clk(clk_sdram_w),
        .sdram_clk(clk_sdram_p_w),
        .reset(!device_reset_n_w),
`ifdef DUAL_RATE_SDRAM
        .init_complete(sdram_init_complete_raw),

        .ports(mem_ports_sdram),
`else
        .init_complete(sdram_init_complete),

        .ports(mem_ports),
`endif

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

`ifdef DUAL_RATE_SDRAM
    // CDC wrappers: 54 MHz clients <-> 108 MHz SDRAM
    generate
        for (genvar mem_cdc_i = 0; mem_cdc_i < NUM_PORTS; mem_cdc_i++) begin : mem_cdc
            mem_port_cdc #(
                .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .DQM_WIDTH(DQM_WIDTH),
                .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
            ) cdc_inst (
                .clk_client(clk_logic_w),   // 54 MHz
                .clk_sdram(clk_sdram_w),    // 108 MHz
                .rst_n(device_reset_n_w),
                .client(mem_ports[mem_cdc_i]),
                .sdram(mem_ports_sdram[mem_cdc_i])
            );
        end
    endgenerate

    // Sync sdram_init_complete from 108 MHz -> 54 MHz (2FF synchronizer)
    reg sdram_init_sync1, sdram_init_sync2;
    always @(posedge clk_logic_w or negedge device_reset_n_w) begin
        if (!device_reset_n_w) begin
            {sdram_init_sync1, sdram_init_sync2} <= 2'b0;
        end else begin
            sdram_init_sync1 <= sdram_init_complete_raw;
            sdram_init_sync2 <= sdram_init_sync1;
        end
    end
    assign sdram_init_complete = sdram_init_sync2;
`endif

    // Interface to Apple II

    // data and address latches on input

    a2bus_if a2bus_if ();

    a2bus_control_if a2bus_control_if();

    wire sleep_w;
    wire data_in_strobe_w;

    wire irq_n_w;

    wire inh_n_w;

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
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_pixel_w),
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
        .inh_n_i(inh_n_w),

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
    wire vgc_ready_w;

    apple_memory_sdram #(
        .VGC_MEMORY(1),
        .SHADOW_ALL_MEMORY(SHADOW_ALL_MEMORY),
`ifdef DUAL_RATE_SDRAM
        .VGC_IN_SDRAM(1)
`else
        .VGC_IN_SDRAM(0)
`endif
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(mem_ports[MAIN_MEM_PORT]),
        .video_mem_if(mem_ports[VIDEO_MEM_PORT]),

        .video_address_i(video_address_w),
        .video_bank_i(video_bank_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),
        .video_ready_o(video_ready_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w),
        .vgc_ready_o(vgc_ready_w)
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


`ifdef BL616_SPI

    // -------------------------------------------------------
    // BL616 SPI Controller (replaces PicoSOC)
    // -------------------------------------------------------

    wire cardrom_release_w;
    wire [0:7] cardrom_d_w;
    wire cardrom_rd;
    wire cardrom_rd_raw_w;
    wire cardrom_inh_n_raw_w;
    wire standalone_w;   // from bl616_spi_connector: no BL616 detected

    CardROM cardrom (
        .a2bus_if(a2bus_if),
        .data_o(cardrom_d_w),
        .rd_en_o(cardrom_rd_raw_w),
        .inh_n_o(cardrom_inh_n_raw_w),
        .req_rom_release_i(cardrom_release_w)
    );

    // Neutralize the CardROM (force INH inactive, no bus drive) when either:
    //   - standalone_w: no BL616, so no bootstrap handshake exists to release
    //     the card ROM — it would otherwise keep INH asserted and overlay the
    //     Apple monitor ROM at $F8xx, crashing the Apple during disk boot.
    //     standalone_w engages with a2bus_control_if.ready (bridge init), so
    //     INH is forced inactive before the bridge ever drives it.
    //   - sw_gs (Apple IIgs): the INH-based ROM-overlay bootstrap mechanism
    //     does not work on the IIgs, so the card ROM must never activate there.
    wire cardrom_disable_w = standalone_w || a2bus_if.sw_gs;
    assign inh_n_w    = cardrom_disable_w ? 1'b1 : cardrom_inh_n_raw_w;
    assign cardrom_rd = cardrom_disable_w ? 1'b0 : cardrom_rd_raw_w;

    video_control_if video_control_if();
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

    drive_volume_if volumes[2]();

    wire [7:0] diskii_d_w;
    wire diskii_rd;

    // Disk II controller (track-on-demand). drive_ii drives the drive side of
    // volumes[] (lba/blk_cnt/rd) on a seek; the BL616 (bl616_spi_connector
    // volume regs 0x40-0x5F) streams the requested track into the
    // DISK_MEM_PORT SDRAM window via XFER SPACE 1, then pulses ack.
    DiskII #(
        .ENABLE(DISK_II_ENABLE),
        .ID(DISK_II_ID)
    ) diskii (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(diskii_d_w),
        .rd_en_o(diskii_rd),
        .ram_disk_if(mem_ports[DISK_MEM_PORT]),
        .volumes(volumes)
    );

    drive_volume_if hdd_volumes[2]();

    wire [7:0] hdd_d_w;
    wire hdd_rd;

    // ProDOS hard disk (block device). The card requests one 512-byte block
    // at a time over hdd_volumes[] (compact BL616 regs 0x26-0x2D); the BL616
    // serves it from a .hdv/.po image into the HDD_MEM_PORT SDRAM window via
    // XFER SPACE 1, then pulses ack and the card streams it to the 6502
    // through its sector buffer.
    HDD #(
        .ENABLE(HDD_ENABLE),
        .ID(HDD_ID)
    ) hdd (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(hdd_d_w),
        .rd_en_o(hdd_rd),
        .ram_hdd_if(mem_ports[HDD_MEM_PORT]),
        .volumes(hdd_volumes)
    );

    // Bus event FIFO
    wire        fifo_empty_w;
    wire        fifo_full_w;
    wire [8:0]  fifo_count_w;
    wire [31:0] fifo_rdata_w;
    wire        fifo_pop_w;
    wire [2:0]  capture_mode_w;
    wire        capture_enable_w;

    a2bus_event_fifo #(
        .ENABLE(1'b1)
    ) a2bus_event_fifo (
        .a2bus_if(a2bus_if),
        .fifo_empty(fifo_empty_w),
        .fifo_full(fifo_full_w),
        .fifo_count(fifo_count_w),
        .fifo_rdata(fifo_rdata_w),
        .fifo_pop(fifo_pop_w),
        .capture_enable(capture_enable_w),
        .capture_mode(capture_mode_w)
    );

    // BL616 SPI connector -- drives LED and WS2812 internally
    wire [4:0] mcu_led_w;
    wire       mcu_ws2812_w;
    wire       mcu_ready_w;
    wire [39:0] mcu_scratch_w;   // 5 MCU scratch regs {s4,s3,s2,s1,s0} for debug overlay

    // Uthernet2 (W5100) backing-store host link (SPI SPACE 3 <-> card port B)
    wire        u2_host_wr_w;
    wire [15:0] u2_host_addr_w;
    wire [7:0]  u2_host_wdata_w;
    wire [7:0]  u2_host_rdata_w;   // driven by the card
    wire [3:0]  u2_cmd_pending_w;  // driven by the card
    wire [3:0]  u2_cmd_clr_w;
    wire [15:0] u2_dbg_wr_count_w; // DEBUG: port-B write instrumentation (card -> connector)
    wire [15:0] u2_dbg_last_addr_w;
    wire [7:0]  u2_dbg_last_wdata_w;

    bl616_spi_connector #(
        .USE_CRC(0),
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .VERSION_STR(`BUILD_DATETIME)
    ) bl616_spi (
        .ssc_ctl_i(ssc_ctl_w),
        .clk(clk_logic_w),
        .rst_n(device_reset_n_w),
        .spi_cs_n(spi_cs_n),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .a2bus_control_if(a2bus_control_if),
        .video_control_if(video_control_if),
        .slotmaker_config_if(slotmaker_config_if),
        .volumes(volumes),
        .hdd_volumes(hdd_volumes),
        .mem_if(mem_ports[MCU_MEM_PORT]),
        .sdram_init_complete_i(sdram_init_complete),
        .mcu_ready_o(mcu_ready_w),
        .standalone_o(standalone_w),
        .scratch_o(mcu_scratch_w),
        .cardrom_active_i(!inh_n_w),
        .cardrom_release_o(cardrom_release_w),
        .button_i(s2),
        .led_o(mcu_led_w),
        .ws2812_o(mcu_ws2812_w),
        .sd_clk_o(sd_clk),
        .sd_cmd_o(sd_cmd),
        .sd_dat0_i(sd_dat0),
        .sd_dat3_o(sd_dat3),
        .fifo_empty(fifo_empty_w),
        .fifo_full(fifo_full_w),
        .fifo_count(fifo_count_w),
        .fifo_rdata(fifo_rdata_w),
        .fifo_pop(fifo_pop_w),
        .capture_mode_o(capture_mode_w),
        .capture_enable_o(capture_enable_w),
        .w5100_host_wr(u2_host_wr_w),
        .w5100_host_addr(u2_host_addr_w),
        .w5100_host_wdata(u2_host_wdata_w),
        .w5100_host_rdata(u2_host_rdata_w),
        .w5100_cmd_pending(u2_cmd_pending_w),
        .w5100_cmd_clr(u2_cmd_clr_w),
        .w5100_dbg_wr_count(u2_dbg_wr_count_w),
        .w5100_dbg_last_addr(u2_dbg_last_addr_w),
        .w5100_dbg_last_wdata(u2_dbg_last_wdata_w)
    );

    assign ws2812 = mcu_ws2812_w;

`else

    // Stub out the external interfaces if not using PicoSOC or BL616

    assign slotmaker_config_if.slot = 3'b0;
    assign slotmaker_config_if.wr = 1'b0;
    assign slotmaker_config_if.card_i = 8'b0;
    assign slotmaker_config_if.reconfig = 1'b0;

    // No BL616: Uthernet2 backing store has no host -- tie the link idle
    assign u2_host_wr_w    = 1'b0;
    assign u2_host_addr_w  = 16'b0;
    assign u2_host_wdata_w = 8'b0;
    assign u2_cmd_clr_w    = 4'b0;

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

    wire [7:0] hdd_d_w = 8'b0;
    wire hdd_rd = 1'b0;

    assign a2bus_control_if.ready = 1'b1;

    wire [0:7] cardrom_d_w = 8'b0;
    wire cardrom_rd = 1'b0;
    assign inh_n_w = 1'b1;


    assign spi_miso = 1'b1;
    assign ws2812 = 1'b0;
    assign sd_clk  = 1'b0;
    assign sd_cmd  = 1'b1;
    assign sd_dat3 = 1'b1;

`endif


    // Video

    // HDMI raster position (driven by the HDMI encoder, clk_pixel domain)
    wire [9:0] hdmi_x;
    wire [9:0] hdmi_y;

    // Apple-side RGB + active that feed the SuperSprite compositor. Driven by
    // either the legacy raster-locked generators (USE_PIXEL_STREAM=0) or the
    // pixel_stream / direct_display generators (USE_PIXEL_STREAM=1).
    wire [7:0] ssp_apple_r_w;
    wire [7:0] ssp_apple_g_w;
    wire [7:0] ssp_apple_b_w;
    wire       ssp_apple_active_w;

    generate if (!USE_PIXEL_STREAM) begin : gen_legacy_video

        // -----------------------------------------------------------------
        // Legacy path: apple_video -> vgc, combinational on hdmi_x/hdmi_y in
        // the clk_pixel domain (the original A2N20v2-Enhanced pipeline).
        // -----------------------------------------------------------------
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

        assign ssp_apple_r_w      = vgc_vga_r;
        assign ssp_apple_g_w      = vgc_vga_g;
        assign ssp_apple_b_w      = vgc_vga_b;
        assign ssp_apple_active_w = apple_vga_active;

    end else begin : gen_pixel_stream_video

        // -----------------------------------------------------------------
        // Pixel-stream path: apple_video_gen + vgc_gen run on clk_logic
        // (54 MHz) with direct_display supplying pixel_clk_en at the 27 MHz
        // display rate (PIX_CLK_DIV=2), HDMI-locked via cx_i/cy_i. Equivalent
        // to the legacy pipeline but through pixel_stream_if. The composited
        // Apple/SHR RGB is CDC'd back to clk_pixel for the SuperSprite
        // compositor.
        //
        // Unlike the plain a2n20v2 board, the Apple II VRAM read goes through
        // SDRAM (mem_port_if), so apple_video_gen uses a real video_ready_i
        // handshake (video_ready_w) rather than tying it high. The SHR aux
        // memory is BSRAM, so vgc_gen still uses a 2-cycle-delayed ready.
        // -----------------------------------------------------------------

        // CDC HDMI raster counters into clk_logic (synchronous 2:1 clocks)
        reg [9:0] hdmi_x_logic_r;
        reg [9:0] hdmi_y_logic_r;
        always @(posedge clk_logic_w) begin
            hdmi_x_logic_r <= hdmi_x;
            hdmi_y_logic_r <= hdmi_y;
        end

        // Border color: 4-bit palette index -> RGB444 (Apple II + IIgs palettes)
        wire border_gsp_w = a2bus_if.sw_gs;
        wire [4:0] border_idx_w = {border_gsp_w, a2mem_if.BORDER_COLOR};
        wire [11:0] border_palette_w [0:31];
        assign border_palette_w = '{
            12'h000, 12'h924, 12'h42a, 12'hd4e,
            12'h064, 12'h888, 12'h39e, 12'hcbf,
            12'h450, 12'hc73, 12'h888, 12'hfac,
            12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,
            12'h000, 12'hd03, 12'h009, 12'hd2d,
            12'h072, 12'h555, 12'h22f, 12'h6af,
            12'h850, 12'hf60, 12'haaa, 12'hf98,
            12'h1d0, 12'hff0, 12'h4f9, 12'hfff
        };
        wire [11:0] border_rgb444_w = border_palette_w[border_idx_w];
        // Match the generators' RGB888 format ({nibble,4'h0}) so the border
        // shade matches the same palette index inside the active window.
        wire [7:0] border_r_w = {border_rgb444_w[11:8], 4'h0};
        wire [7:0] border_g_w = {border_rgb444_w[7:4],  4'h0};
        wire [7:0] border_b_w = {border_rgb444_w[3:0],  4'h0};

        // --- Apple II generator + direct display ---
        pixel_stream_if apple_ps();

        apple_video_gen #(
            .VRAM_READ_LATENCY(16),  // SDRAM via mem_port_if
            // Fixed raster-locked output start. The SDRAM VRAM read has variable
            // priming latency (refresh/arbitration jitter), so PIXEL_START_TICK=0
            // let the line's first pixel begin "whenever the fetch finished",
            // shifting the whole line by 1 px when a refresh collided with the
            // first-chunk fetch — a 1-px band sweeping vertically as the 15us
            // refresh beat against the scanline rate. Holding output until a fixed
            // tick (> worst-case priming) raster-locks the start and removes the
            // jitter. Plain a2n20v2 keeps 0 (BSRAM = constant latency).
            .PIXEL_START_TICK(20)
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
            .video_data_i(video_data_w),
            .video_ready_i(video_ready_w)   // SDRAM read-data beat
        );

        wire [7:0] dd_apple_r_w, dd_apple_g_w, dd_apple_b_w;
        direct_display #(
            .PIX_CLK_DIV(2),
            .H_GEN_START(DD_APPLE_H_START)
        ) apple_direct (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),
            .pixel_stream(apple_ps),
            .cx_i(hdmi_x_logic_r),
            .cy_i(hdmi_y_logic_r),
            .border_r_i(border_r_w),
            .border_g_i(border_g_w),
            .border_b_i(border_b_w),
            .video_r_o(dd_apple_r_w),
            .video_g_o(dd_apple_g_w),
            .video_b_o(dd_apple_b_w)
        );

        // --- VGC (Super Hi-Res) generator + direct display ---
        pixel_stream_if vgc_ps();

        // Read-ready for vgc_gen comes from apple_memory_sdram: a fixed
        // 2-cycle sdpram32 latency in BSRAM mode, or the real SDRAM port
        // ready when VGC_IN_SDRAM (dual-rate config).

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
            .dbg_missed_hsync_o()
        );

        wire [7:0] dd_vgc_r_w, dd_vgc_g_w, dd_vgc_b_w;
        direct_display #(
            .PIX_CLK_DIV(2),
            .WINDOW_WIDTH(640),
            .WINDOW_HEIGHT(400),     // 200 * 2
            .H_GEN_START(DD_VGC_H_START)
        ) vgc_direct (
            .clk_i(clk_logic_w),
            .reset_n_i(system_reset_n_w),
            .pixel_stream(vgc_ps),
            .cx_i(hdmi_x_logic_r),
            .cy_i(hdmi_y_logic_r),
            .border_r_i(border_r_w),
            .border_g_i(border_g_w),
            .border_b_i(border_b_w),
            .video_r_o(dd_vgc_r_w),
            .video_g_o(dd_vgc_g_w),
            .video_b_o(dd_vgc_b_w)
        );

        // Select Apple II vs Super Hi-Res, latched once per frame.
        reg use_vgc_r;
        always @(posedge clk_logic_w) begin
            if (apple_ps.vsync) use_vgc_r <= a2mem_if.SHRG_MODE;
        end

        wire [7:0] ps_r_w      = use_vgc_r ? dd_vgc_r_w : dd_apple_r_w;
        wire [7:0] ps_g_w      = use_vgc_r ? dd_vgc_g_w : dd_apple_g_w;
        wire [7:0] ps_b_w      = use_vgc_r ? dd_vgc_b_w : dd_apple_b_w;
        wire       ps_active_w = use_vgc_r ? vgc_ps.active : apple_ps.active;

        // Register the composited pixel in clk_logic first, so the clk_pixel
        // sampler below captures a clean single-FF source rather than a deep
        // combinational chain (palette LUT -> active/border mux in
        // direct_display -> Apple/SHR mux here). Collapsing the cross-domain
        // launch path to a flop removes the per-pixel CDC timing hazard that
        // produced faint flicker on high-spatial-frequency content (80-column
        // text); lower-frequency content such as SHR masked it.
        reg [7:0] ps_r_logic_r, ps_g_logic_r, ps_b_logic_r;
        reg       ps_active_logic_r;
        always @(posedge clk_logic_w) begin
            ps_r_logic_r      <= ps_r_w;
            ps_g_logic_r      <= ps_g_w;
            ps_b_logic_r      <= ps_b_w;
            ps_active_logic_r <= ps_active_w;
        end

        // CDC clk_logic -> clk_pixel (synchronous 2:1 clocks)
        reg [7:0] ps_r_pix_r, ps_g_pix_r, ps_b_pix_r;
        reg       ps_active_pix_r;
        always @(posedge clk_pixel_w) begin
            ps_r_pix_r      <= ps_r_logic_r;
            ps_g_pix_r      <= ps_g_logic_r;
            ps_b_pix_r      <= ps_b_logic_r;
            ps_active_pix_r <= ps_active_logic_r;
        end

        assign ssp_apple_r_w      = ps_r_pix_r;
        assign ssp_apple_g_w      = ps_g_pix_r;
        assign ssp_apple_b_w      = ps_b_pix_r;
        assign ssp_apple_active_w = ps_active_pix_r;

    end endgenerate

    wire [15:0] sg_audio_l;
    wire [15:0] sg_audio_r;
`ifdef ENSONIQ
    wire [7:0] sg_d_w;
    wire sg_rd_w;
    wire [7:0] doc_osc_en_w;   // Debug signal for DOC oscillator enable register
    wire [1:0] doc_osc_mode_w[8];
    wire [7:0]  doc_osc_halt_w;

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE),
        .MONO_MIX(ENSONIQ_MONO_MIX) // If true, mono mix is used instead of stereo
    ) sg (
        .a2bus_if(a2bus_if),
        .data_o(sg_d_w),                 
        .rd_en_o(sg_rd_w),

        .audio_l_o(sg_audio_l),               
        .audio_r_o(sg_audio_r),

        .debug_osc_en_o(doc_osc_en_w),   // Capture oscillator enable register value
        .debug_osc_mode_o(doc_osc_mode_w), // Capture oscillator mode register values
        .debug_osc_halt_o(doc_osc_halt_w), // Capture oscillator halt register value
    
        .glu_mem_if(mem_ports[GLU_MEM_PORT]),
        .doc_mem_if(mem_ports[DOC_MEM_PORT])
    );
`else
    assign sg_audio_l = 16'b0;
    assign sg_audio_r = 16'b0;
    wire [7:0] doc_osc_en_w = 8'h00; // Default value when ENSONIQ is disabled
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
    wire [9:0] ssp_audio_w;
    wire vdp_unlocked_w;
    wire [3:0] vdp_gmode_w;
    wire scanlines_w;

    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;

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
        .apple_vga_r_i(ssp_apple_r_w),
        .apple_vga_g_i(ssp_apple_g_w),
        .apple_vga_b_i(ssp_apple_b_w),
        .apple_vga_active_i(ssp_apple_active_w),

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
    wire [7:0] ssc_ctl_w;
    assign uart_tx = ssc_uart_tx;
    assign ssc_uart_rx = uart_rx;

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
        .uart_tx_o(ssc_uart_tx),
        .ssc_ctl_o(ssc_ctl_w)
    );

    // Uthernet II (W5100) Ethernet card

    wire [7:0] u2_d_w;
    wire u2_rd;
    wire u2_irq_n;

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
        .dbg_portb_wr_count(u2_dbg_wr_count_w),
        .dbg_portb_last_addr(u2_dbg_last_addr_w),
        .dbg_portb_last_wdata(u2_dbg_last_wdata_w)
    );

    // Data output

    assign data_out_en_w = ssp_rd || mb_rd || ssc_rd || u2_rd || diskii_rd || hdd_rd || cardrom_rd;

    assign data_out_w = ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w :
        mb_rd ? mb_d_w :
        u2_rd ? u2_d_w :
        diskii_rd ? diskii_d_w :
        hdd_rd ? hdd_d_w :
        cardrom_rd ? cardrom_d_w :
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

    // CDC to shift audio to the pixel clock domain from the logic clock domain

`ifdef DUAL_RATE_SDRAM
    // Audio CDC: 54 MHz (CLKDIV2) -> 108 MHz (PLL CLKOUT) -> 27 MHz (PLL CLKOUTD)
    //
    // Stage 1: 54->108 MHz is safe because CLKDIV2 guarantees every 54 MHz edge
    //          IS a 108 MHz edge. The 108 MHz register captures stable data.
    // Stage 2: 108->27 MHz is safe because both come from the same PLL
    //          (CLKOUT and CLKOUTD), with PLL-guaranteed phase alignment.
    //
    // A direct 54->27 MHz cdc_sampling would be broken here because CLKDIV2
    // output (54 MHz) and PLL CLKOUTD (27 MHz) don't have a PLL-guaranteed
    // phase relationship — their alignment depends on the asynchronous
    // CLKDIV2 RESETN timing. (See the identical structure in the GS board.)

    // Register the 4-input adder result to break the timing path
    reg signed [15:0] core_audio_l_r, core_audio_r_r;
    always @(posedge clk_logic_w) begin
        core_audio_l_r <= core_audio_l_w;
        core_audio_r_r <= core_audio_r_w;
    end

    // Stage 1: 54 MHz -> 108 MHz (CLKDIV2 alignment guarantee)
    reg signed [15:0] audio_l_sdram_r, audio_r_sdram_r;
    always @(posedge clk_sdram_w) begin
        audio_l_sdram_r <= core_audio_l_r;
        audio_r_sdram_r <= core_audio_r_r;
    end

    // Stage 2: 108 MHz -> 27 MHz (PLL CLKOUT/CLKOUTD phase guarantee)
    reg [15:0] cdc_audio_l, cdc_audio_r;
    always @(posedge clk_pixel_w) begin
        cdc_audio_l <= audio_l_sdram_r;
        cdc_audio_r <= audio_r_sdram_r;
    end
`else
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
`endif

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
        .CLK_RATE(CLOCK_SPEED_HZ / 2),
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

        .is_signed(1'b1),
        .core_l(cdc_audio_l),
        .core_r(cdc_audio_r),

        .audio_clk(clk_audio_w),
        .audio_l(audio_sample_word[0]),
        .audio_r(audio_sample_word[1])
    );

    // HDMI

    wire scanline_en = scanlines_w && hdmi_y[0];

    reg show_debug_overlay_r = 1'b0;

    wire [7:0] debug_r_w;
    wire [7:0] debug_g_w;
    wire [7:0] debug_b_w;
    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),  // 14-digit timestamp version
        .ENABLE(1'b1)
    ) debug_overlay (
        .clk_i          (clk_pixel_w),
        .reset_n (device_reset_n_w),
        .enable_i(FORCE_DEBUG_OVERLAY ? 1'b1 : show_debug_overlay_r),

        // MCU/BL616 debug instrumentation: 5 scratch regs (0x07,0x0C-0x0F) the
        // firmware writes over SPI. hex[0]=stage, [1]=btn-lo, [2]=btn-hi,
        // [3]=event counter (heartbeat), [4]=status flags.
        .hex_values ({
            mcu_scratch_w[7:0],     // scratch0: firmware stage code
            mcu_scratch_w[15:8],    // scratch1: XInput button low byte
            mcu_scratch_w[23:16],   // scratch2: XInput button high byte
            mcu_scratch_w[31:24],   // scratch3: event/heartbeat counter
            mcu_scratch_w[39:32],   // scratch4: status flag bits
            8'h0,
            8'h0,
            8'h0
        }),

        // Bit row 0 = what the FPGA + firmware think the MCU is doing:
        //   bit0 = mcu_ready (FPGA saw MCU read STATUS 0x06), bit1 = standalone
        //   (watchdog fired, no MCU), bits2-7 = firmware status flags (scratch4).
        .debug_bits_0_i ({mcu_scratch_w[37:32], standalone_w, mcu_ready_w}),
        // Bit row 1 = live XInput button low byte (each press lights a block).
        .debug_bits_1_i (mcu_scratch_w[15:8]),

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
        //if (!s2) 
        led <= {!a2mem_if.TEXT_MODE, !a2mem_if.SHRG_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.RAMWRT, !a2mem_if.STORE80};
        //if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        //else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end


endmodule
