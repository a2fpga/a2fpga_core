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
`include "a2mega_profile.vh"

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int PIXEL_SPEED_HZ = CLOCK_SPEED_HZ / 2,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 1,

    parameter bit SUPERSPRITE_ENABLE = dp_test_die_pkg::FEATURE_SUPERSPRITE,  // per-die (see die pkg)
    parameter bit [7:0] SUPERSPRITE_ID = 1,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = dp_test_die_pkg::FEATURE_MOCKINGBOARD,  // per-die (see die pkg)
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    parameter bit SUPERSERIAL_ENABLE = dp_test_die_pkg::FEATURE_SUPERSERIAL,  // per-die (see die pkg)
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter bit DISK_II_ENABLE = `A2_FEATURE_DISK_II,
    parameter bit [7:0] DISK_II_ID = 4,

    parameter bit UTHERNET2_ENABLE = `A2_FEATURE_UTHERNET2,
    parameter bit [7:0] UTHERNET2_ID = 5,

    parameter bit HDD_ENABLE = `A2_FEATURE_HDD,
    parameter bit [7:0] HDD_ID = 6,

    parameter bit ENSONIQ_ENABLE = `A2_FEATURE_ENSONIQ,
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

    // DisplayPort (1.0a3 USB-C): AUX pseudo-diff pair to the TUSB1046A
    // (bias/AC coupling on the carrier) and HPD reconstructed by the ESP32
    // from PD VDMs (level + 0.75 ms IRQ low pulses on ESP32_GPIO0). The DP
    // main-link lanes and 135 MHz refclk are dedicated SERDES bumps
    // configured inside the generated PHY IP — no top-level ports.
    inout  dp_aux_p,
    inout  dp_aux_n,
    input  dp_hpd,

    // leds (active low on 1.0a3: anode +3V3 via R23-R26)
    output [3:0] led,

    input button,  // 0 when pressed

    input [3:0] dip_switches_n,

    // uart
    output  uart_tx,
    input  uart_rx,

    // ddr3 interface
    // ROW_WIDTH=15: H5TQ4G63EFR (4Gb x16) has A[14:0]. A 16th bit (ball R1
    // on the 60K pinout) appeared in early references but corresponds to no
    // DDR3 pin — and on the GW5AST-138B die R1 sits in the UART's 3.3V bank,
    // so constraining it at 1.5V breaks the build. Removed on both variants
    // (nand2mario's shipped 60K design also uses [14:0] only).
    output [14:0] ddr_addr,
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
    inout  [7:0]  esp_data

`ifdef GS_SOCKET
    // IIgs CPU socket: 65C816 drop-in through the 1.0a3 level shifters
    // (138B builds only - hdl/twgs/gs_socket_defines.v; see
    // docs/gs_socket_65816_scoping.md and hdl/twgs/gs_socket_phy.sv)
    ,
    input         gs_ph2,
    input         gs_rdy,
    input         gs_irq_n,
    input         gs_nmi_n,
    input         gs_res_n,
    input         gs_abort_n,
    input         gs_be,
    inout  [7:0]  gs_d,
    output [15:0] gs_a,
    output        gs_rw,
    output        gs_vp,
    output        gs_rdy_out,
    output        gs_d_dir,
    output        gs_data_oe_n,
    output        gs_addr_oe_n,
    output        gs_oe_n
`endif
);

    // Clocks — all PLLs live in board_plls, a per-SOM-variant module:
    // clocks_60b.sv (GW5AT-60B: PLLA + mDRP pll_stop glue) or
    // clocks_138b.sv (GW5AST-138B: PLL + PLL_INIT, pll_stop -> enclk2).
    // The .gprj file list selects which variant is built.

    wire clk_logic_pll_w;           // 54 MHz from board PLL (independent of DDR3)
    wire clk_logic_w = clk_logic_pll_w;  // logic runs on independent PLL
    wire clk_lock_w;
    // Board-PLL 27 MHz tap. On 1.0a3 the video pixel clock comes from the
    // DP core instead (clk_pixel_w below, 27 MHz derived from the 135 MHz
    // SERDES symbol clock); this output remains ONLY as pll_ddr3's source
    // inside board_plls — do not remove it, and do not re-source pll_ddr3:
    // DDR3 calibration is fragile and this keeps its clock chain identical
    // to the hardware-proven 1.0a2 configuration.
    wire clk_pixel_pll_w;
    wire clk_pixel_w;               // video pixel clock (from dp_transmitter)
    wire clk_hdmi_w;                // unused on 1.0a3 (was TMDS x5)

    wire clk_usb_w;                 // unused on 1.0a3 (no USB-A host)
    wire usb_pll_lock_w;

    wire memory_clk_w;              // 324 MHz to DDR3 controller
    wire pll_lock_w;                // DDR3 PLL lock
    wire pll_stop_w;                // DDR3 IP clock-stop request

    board_plls u_board_plls (
        .clk           (clk),
        .pll_stop      (pll_stop_w),
        .clk_pixel     (clk_pixel_pll_w),
        .clk_hdmi      (clk_hdmi_w),
        .clk_logic     (clk_logic_pll_w),
        .clk_lock      (clk_lock_w),
        .clk_usb       (clk_usb_w),
        .usb_pll_lock  (usb_pll_lock_w),
        .memory_clk    (memory_clk_w),
        .ddr3_pll_lock (pll_lock_w)
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

    // DDR3 memory port allocation (single unified array for all clients).
    //
    // Priority = latency criticality, NOT bandwidth. apple_video_gen and
    // vgc_gen are hard-real-time: they emit pixels at fixed cadence from a
    // single-word prefetch, so a shadow read that misses its ~500ns slot
    // makes the shifter reuse the previous word — seen on hardware as
    // "sparkle" (occasional misses: moving misplaced pixels on static
    // screens, worst during disk loads) or wholesale shape garble (chronic
    // misses during SHR). No counter fires: the data is correct, merely
    // late. Every other client tolerates latency by construction: the FB
    // writer has a deep accumulator FIFO, the FB reader prefetches whole
    // lines into a line buffer, CPU shadow writes sit in a 16-deep FIFO
    // (drops instrumented at dbg reg 0x74).
    //
    //   0 = Shadow read  (apple_video_gen + vgc_gen — latency-critical)
    //   1 = Shadow write (CPU; FIFO absorbs stalls, drops counted)
    //   2 = FB write     (accumulator FIFO; overflow counted per frame)
    //   3 = FB read      (line-buffered prefetch; line-not-ready counted)
    //   4 = DOC (Ensoniq wavetable read)
    //   5 = GLU (Ensoniq write)
    // DOC sits ABOVE the FB ports: its rev-3 traffic is tiny (~70k grants/s,
    // 4-beat reads) so it costs the FB at most a few short grants per line,
    // while FB-priority + deferral gating caused convoy formation — deferred
    // DOC fetches drained exactly when the next line fetch wanted to start,
    // slipping lines cumulatively toward frame bottom (hardware: 9 late
    // lines/frame, bottom-of-screen corruption).
    // GLU sound-RAM writes sit ABOVE the FB ports. The FB read port has a
    // request pending almost continuously during active display (40
    // back-to-back grants per line), so under static priority a lower GLU
    // port is starved for milliseconds while the Apple II uploads samples
    // at ~1 write/us — overflowing the write queue and silently corrupting
    // the wavetable. Its traffic is rare and short (single word) outside
    // upload bursts. A dropped write is unrecoverable; a delayed FB line
    // is not.
    localparam SHADOW_READ_PORT  = 0;
    localparam SHADOW_WRITE_PORT = 1;
    localparam DOC_MEM_PORT      = 2;
    localparam GLU_MEM_PORT      = 3;
    localparam FB_WRITE_PORT   = 4;
    localparam FB_READ_PORT    = 5;
    localparam DBG_MEM_PORT      = 6;
    localparam NUM_DDR3_PORTS    = 7;

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
    wire [7:0]  vgc_dbg_starved_w;
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
        .sw_gs_i(a2bus_if.sw_gs),

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

        .dbg_missed_hsync_o(vgc_dbg_missed_hsync_w),
        .dbg_starved_o(vgc_dbg_starved_w)
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

    // 64KB sound RAM backed by DDR3 via the pipelined-fetch DOC5503:
    // fetches issue during an oscillator's service slot and are consumed at
    // its next service (deadline >= 3.35 us vs ~1.2 us worst-case DDR3 tail).
    // Differential-sim validated; see
    // boards/a2mega/docs/ensoniq_ddr3_pipelined_design.md. Frees the 32
    // BSRAM blocks previously used by ensoniq_bsram.
    wire [7:0] doc_dbg_prime_miss_w;
    wire [7:0] doc_dbg_stale_fetch_w;
    wire [7:0] doc_dbg_fetch_drop_w;
    wire [15:0] doc_dbg_fetch_count_w;
    wire fb_fetch_active_w;   // from u_framebuffer: line fetch issuing bursts
    // Request instrumentation (declare BEFORE the sg instantiation —
    // referencing these in port connections first creates disconnected
    // implicit nets; Gowin only warns, EX3638, and everything reads zero)
    wire [7:0]  glu_wq_drops_w;   // sound-RAM write-queue overflow drops
    wire [15:0] doc_dbg_req_count_w;
    wire [7:0]  doc_dbg_req_mingap_w;
    reg         doc_dbg_vsync_d_r;
    wire        doc_dbg_frame_tick_w = fb_vsync_mux_w && !doc_dbg_vsync_d_r;

    sound_glu #(
        .ENABLE(ENSONIQ_ENABLE),
        .MONO_MIX(ENSONIQ_MONO_MIX),
        // A/B result 2026-08-02: USE_BSRAM(1) = audibly perfect on the same
        // hardware/title; pipelined DDR3 = distorted with clean memory
        // counters. Distortion is introduced by the pipelined variant, not
        // inherited. Diagnosis in progress (consume-hole 0x80s vs register-
        // bank restructure); prime_miss is on overlay Hex 4 to discriminate.
        // DDR3 build with the GLU write-starvation fix (port priority above
        // FB + 32-deep queue) and the write-drop counter finally visible.
        .USE_BSRAM(0),
        .USE_DDR3_PIPELINED(1),
        // FF register banks: 0 BSRAM vs ~2k FF. The DPB/packed-record banks
        // (BANKS_IN_BSRAM=1) spend 6 blocks at low fill for state the fabric
        // holds comfortably (regs at 44%); GW5A has no distributed RAM, so
        // FFs are the honest medium for a 320-byte register file. The FF
        // path is baseline-equivalent read timing and is co-validated by
        // every suite run (both modes). See ensoniq_ddr3_pipelined_design.md
        // for the 1-block scheduled-SDPB endpoint if BSRAM pressure returns.
        .DOC_BANKS_IN_BSRAM(0),
        .GLU_WR_ACK_AVAIL(1)   // DDR3 CDC never pulses ready on writes
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
        .glu_wq_drops_o(glu_wq_drops_w),
        .doc_mem_if(ddr3_mem_ports[DOC_MEM_PORT]),
        // Gating disabled: with DOC above the FB ports, deferral is not only
        // unnecessary but harmful (convoy formation — see priority comment).
        // Keep fb_fetch_active_w wired in case a future config re-enables.
        .fb_fetch_active_i(1'b0),

        .dbg_doc_prime_miss_o(doc_dbg_prime_miss_w),
        .dbg_doc_stale_fetch_o(doc_dbg_stale_fetch_w),
        .dbg_doc_fetch_drop_o(doc_dbg_fetch_drop_w),
        .dbg_doc_fetch_count_o(doc_dbg_fetch_count_w),
        .dbg_frame_tick_i(doc_dbg_frame_tick_w),
        .dbg_doc_req_count_o(doc_dbg_req_count_w),
        .dbg_doc_req_mingap_o(doc_dbg_req_mingap_w)
    );

    // Per-frame latching for the request instrumentation (clk_logic domain)
    reg [15:0]  doc_dbg_req_prev_r;
    reg [15:0]  doc_dbg_req_frame_r;   // requests in the last full frame
    reg [7:0]   doc_dbg_mingap_frame_r; // min inter-request gap last frame
    always_ff @(posedge clk_logic_w) begin
        doc_dbg_vsync_d_r <= fb_vsync_mux_w;
        if (doc_dbg_frame_tick_w) begin
            doc_dbg_req_frame_r    <= doc_dbg_req_count_w - doc_dbg_req_prev_r;
            doc_dbg_req_prev_r     <= doc_dbg_req_count_w;
            doc_dbg_mingap_frame_r <= doc_dbg_req_mingap_w; // pre-reset value
        end
    end

    wire [20:0] dbg_mem_addr_w;
    wire        dbg_mem_go_w;
    wire        dbg_mem_busy_w;
    wire [31:0] dbg_mem_data_w;

    // Discrete member wiring — passing this array element into the debug
    // reader's interface port hit Gowin's interface-array flattening bug
    // (see ddr3_ports.sv note); the first build attempt with an interface
    // port killed the OSPI link. (sound_glu takes array elements as
    // interface ports without issue — proven on a2n20v2-GS — so the bug is
    // specific to this module's wiring; keep the discrete style here.)
    wire        dbg_mem_rd_w;
    wire [20:0] dbg_mem_port_addr_w;

    assign ddr3_mem_ports[DBG_MEM_PORT].rd      = dbg_mem_rd_w;
    assign ddr3_mem_ports[DBG_MEM_PORT].wr      = 1'b0;
    assign ddr3_mem_ports[DBG_MEM_PORT].addr    = dbg_mem_port_addr_w;
    assign ddr3_mem_ports[DBG_MEM_PORT].data    = 32'd0;
    assign ddr3_mem_ports[DBG_MEM_PORT].byte_en = 4'b1111;
    assign ddr3_mem_ports[DBG_MEM_PORT].burst   = 1'b0;

    ddr3_debug_reader u_ddr3_dbg_reader (
        .clk    (clk_logic_w),
        .rst_n  (device_reset_n_w),
        .mem_rd_o        (dbg_mem_rd_w),
        .mem_addr_o      (dbg_mem_port_addr_w),
        .mem_available_i (ddr3_mem_ports[DBG_MEM_PORT].available),
        .mem_ready_i     (ddr3_mem_ports[DBG_MEM_PORT].ready),
        .mem_q_i         (ddr3_mem_ports[DBG_MEM_PORT].q),
        .addr_i (dbg_mem_addr_w),
        .req_i  (dbg_mem_go_w),
        .busy_o (dbg_mem_busy_w),
        .data_o (dbg_mem_data_w)
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

    wire storage_settled_w;     // from the connector: MCU mount pass over (or no MCU)
    HDD #(
        .ENABLE(HDD_ENABLE),
        .ID(HDD_ID)
    ) hdd (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(hdd_d_w),
        .rd_en_o(hdd_rd),
        .ram_hdd_if(hdd_ram_if),
        .volumes(hdd_volumes),
        .storage_settled_i(storage_settled_w)
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
    //   3. framebuffer_1080p — shared framebuffer (2 × mem_port_if)
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
    wire [11:0] hdmi_cx_w;      // raster X (0–2199, 1080p)
    wire [10:0] hdmi_cy_w;      // raster Y (0–1124, 1080p)
    wire [23:0] fb_rgb_w;       // Current framebuffer RGB output
    wire [2:0]  fb_v_scale_w;   // fb scan-out geometry, for scanline_dim
    wire [10:0] fb_v_border_w;
    wire [23:0] overlay_rgb_w;  // DebugOverlay RGB output
    wire        overlay_en_w;   // DebugOverlay enable

    // -----------------------------------------------------------------
    // DDR3 PLL — 324 MHz memory clock, generated inside board_plls (see
    // clocks_60b.sv / clocks_138b.sv for the per-SOM pll_stop mechanism:
    // mDRP glue on the 60B PLLA, direct enclk2 gating on the 138B PLL).
    // memory_clk_w / pll_lock_w / pll_stop_w are declared in the Clocks
    // section above.
    // -----------------------------------------------------------------
    // DDR3 reset sequencer + calibration watchdog
    // -----------------------------------------------------------------
    // The IP's rst_n was tied high: calibration was a single unsequenced
    // shot racing PLL lock at configuration time, and a miss was permanent
    // (no retry in the IP) — the intermittent dead-DDR3 cold boots.
    // Sequence: hold reset until the DDR3 PLL locks, settle 1 ms, release,
    // then if init_calib_complete fails to assert within 100 ms, pulse
    // reset 100 us and retry. Retry count in debug reg 0x23; observed on
    // hardware with power stable ~30 s before config, so failures here are
    // controller-reset races, not supply ramp.
    // Clocked on the always-on 50 MHz crystal (same domain as the IP's
    // clk port); regs power up to 0 so reset starts ASSERTED.
    localparam DDR3_SETTLE_CYC   = 50_000;     // 1 ms @ 50 MHz
    localparam DDR3_CALIB_CYC    = 5_000_000;  // 100 ms watchdog
    localparam DDR3_RSTPULSE_CYC = 5_000;      // 100 us reset pulse

    reg        ddr3_rst_n_r = 1'b0;
    reg [1:0]  ddr3_seq_state_r = 2'd0;  // 0=wait-lock 1=settle 2=watch 3=pulse
    reg [22:0] ddr3_seq_timer_r = '0;
    reg [7:0]  ddr3_retry_cnt_r = '0;    // saturating; nonzero = watchdog fired

    // Forced re-init test hook: ESP32 write to reg 0x25 toggles a line in
    // clk_logic; edge here fires the watchdog path on demand so the retry
    // mechanism is testable without waiting for a marginal boot.
    wire ddr3_reinit_tgl_w;
    reg  ddr3_reinit_sync0, ddr3_reinit_sync1, ddr3_reinit_sync2;
    always @(posedge clk) begin
        ddr3_reinit_sync0 <= ddr3_reinit_tgl_w;
        ddr3_reinit_sync1 <= ddr3_reinit_sync0;
        ddr3_reinit_sync2 <= ddr3_reinit_sync1;
    end
    wire ddr3_force_reinit_w = ddr3_reinit_sync1 ^ ddr3_reinit_sync2;

    always @(posedge clk) begin
        if (!pll_lock_w) begin
            ddr3_rst_n_r     <= 1'b0;
            ddr3_seq_state_r <= 2'd0;
            ddr3_seq_timer_r <= '0;
        end else begin
            case (ddr3_seq_state_r)
                2'd0: begin
                    ddr3_seq_timer_r <= '0;
                    ddr3_seq_state_r <= 2'd1;
                end
                2'd1: begin  // settle with reset held
                    ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                    if (ddr3_seq_timer_r >= DDR3_SETTLE_CYC) begin
                        ddr3_rst_n_r     <= 1'b1;
                        ddr3_seq_timer_r <= '0;
                        ddr3_seq_state_r <= 2'd2;
                    end
                end
                2'd2: begin  // released — watch calibration
                    if (ddr3_force_reinit_w ||
                        (!init_calib_complete_w && ddr3_seq_timer_r >= DDR3_CALIB_CYC)) begin
                        ddr3_rst_n_r     <= 1'b0;
                        ddr3_seq_timer_r <= '0;
                        if (!(&ddr3_retry_cnt_r))
                            ddr3_retry_cnt_r <= ddr3_retry_cnt_r + 1'b1;
                        ddr3_seq_state_r <= 2'd3;
                    end else if (init_calib_complete_w)
                        ddr3_seq_timer_r <= '0;  // calibrated; park here
                    else
                        ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                end
                2'd3: begin  // reset pulse, then settle+release again
                    ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                    if (ddr3_seq_timer_r >= DDR3_RSTPULSE_CYC) begin
                        ddr3_seq_timer_r <= '0;
                        ddr3_seq_state_r <= 2'd1;
                    end
                end
            endcase
        end
    end

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
        .rst_n           (ddr3_rst_n_r),        // sequencer above (was 1'b1)
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
        .O_ddr_addr      (ddr_addr),
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

    // -----------------------------------------------------------------
    // DDR3 Multi-Port Arbiter
    // -----------------------------------------------------------------

    wire [95:0] fb_wide_data_hi_w;

    ddr3_ports #(
        .NUM_PORTS(NUM_DDR3_PORTS),
        .DDR_ADDR_WIDTH(29),
        .PORT_BASE_ADDR('{
            SHADOW_WORD_BASE,   // [0] Shadow read (highest priority)
            SHADOW_WORD_BASE,   // [1] Shadow write
            ENSONIQ_WORD_BASE,  // [2] DOC wavetable read (above FB: tiny
                                //     traffic, short grants; see localparam
                                //     comment)
            ENSONIQ_WORD_BASE,  // [3] GLU sound-RAM write (above FB: a
                                //     dropped write corrupts the wavetable
                                //     permanently)
            FB_WORD_BASE,       // [4] FB write
            FB_WORD_BASE,       // [5] FB read
            21'h000000          // [6] DDR3 debug reader (absolute addresses,
                                //     manual/rare traffic; lowest priority)
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
    framebuffer_1080p #(
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
        .v_scale_o        (fb_v_scale_w),
        .v_border_o       (fb_v_border_w),
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
        .fetch_active_o          (fb_fetch_active_w),
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
    // 48 kHz strobe from the 148.5 MHz pixel clock via a sign-bit phase
    // accumulator (exact for any ratio; 148.5M/48k = 3093.75 is not an
    // integer, so the old divider+frac scheme no longer applies)
    // Kept in the exact reduced fraction 48 000 / 148 500 000 = 4 / 12 375
    // (timing campaign round 2, 138B durability): a 15-bit signed
    // accumulator produces the identical strobe sequence the 29-bit one
    // did (same arithmetic divided by the common factor 12 000); the
    // 29-bit adder was a clk_pix floor on the 138B (+0.02 ns).
    logic clk_audio;
    logic signed [14:0] aud_acc = -15'sd12_375;
    always_ff @(posedge clk_pixel_w) begin
        clk_audio <= 1'b0;
        if (!aud_acc[14]) begin
            aud_acc   <= aud_acc + 15'sd4 - 15'sd12_375;
            clk_audio <= 1'b1;
        end else begin
            aud_acc <= aud_acc + 15'sd4;
        end
    end

    // Audio CDC: clk_logic (54 MHz) -> clk_pixel (148.5 MHz). The plain
    // double flop per bit that used to sit here is untimed (the SDC puts the
    // two clocks in asynchronous groups) and hands the sink a mixed word when
    // the sample changes near a pixel-clock edge: measured on the a2p25
    // 2026-11-16 as 219 never-produced words in one Arkanoid run (pops),
    // none with the request/acknowledge mailbox (RESOURCE_AUDIT 8.4). Same
    // module here, same control: a write to debug-window index 55 (bit 0 =
    // mailbox, power-up 1; bit 1 = clear), counters at indices 48-55.
    wire [7:0]  aud_ctl_w;              // driven by esp32_ospi_connector below
    wire [63:0] aud_cdc_dbg_w;
    reg  [15:0] audio_sample_word [1:0];
    audio_sample_cdc #(.W(16), .JUMP_THRESH(2048)) i_audio_cdc (
        .clk_src    (clk_logic_w),
        .l_src      (core_audio_l_w),
        .r_src      (core_audio_r_w),
        .clk_dst    (clk_pixel_w),
        .strobe_dst (clk_audio),
        .sel_safe   (aud_ctl_w[0]),
        .clear      (aud_ctl_w[1]),
        .l_dst      (audio_sample_word[0]),
        .r_dst      (audio_sample_word[1]),
        .dbg        (aud_cdc_dbg_w)
    );

    // -----------------------------------------------------------------
    // DisplayPort TX — 1920x1080p 59.94 Hz over 2-lane HBR (Phase 3b)
    // -----------------------------------------------------------------
    // The vendored dp_transmitter (hdl/displayport) replaces the HDMI
    // encoder at the same seam: it owns clk_pixel_w (27.000 MHz = 135 MHz
    // symbol clock x 1/5 from its pixel PLL) and pulls rgb for the
    // previous cycle's (cx, cy) — the identical hdl-util-style contract
    // the hdmi core used, so the framebuffer, the OSD overlay and the
    // DebugOverlay connect unchanged. 1080p CEA timing; the x3/x5
    // scan-out scaler lives in framebuffer_1080p's read side.

    wire [11:0] dp_cx_raw_w;        // $clog2(2200)
    wire [10:0] dp_cy_raw_w;        // $clog2(1125)
    reg  [23:0] dp_rgb_r;

    assign hdmi_cx_w = dp_cx_raw_w;
    assign hdmi_cy_w = dp_cy_raw_w;
    // Registered coordinate feed for the OVERLAYS only (08-30 structural
    // timing): the cx -> osd/debug-overlay compare cones into CE pins
    // were the last clk_pix family (worst -0.34). The framebuffer keeps
    // the raw coordinates (its pipeline is contract-matched); the
    // overlays shift 1 px relative to the base video — imperceptible,
    // same precedent as the registered fb feed below.
    reg [11:0] ovl_cx_q;
    reg [10:0] ovl_cy_q;
    always @(posedge clk_pixel_w) begin
        ovl_cx_q <= dp_cx_raw_w;
        ovl_cy_q <= dp_cy_raw_w;
    end

    // AUX channel analog interface: pseudo-diff pair, tri-stated by the
    // in-fabric AUX engine; carrier provides bias + AC coupling.
    wire dp_auxch_in_w, dp_auxch_out_w, dp_auxch_tri_w;

    // 100 MHz management/AUX-bit-timing clock
    wire clk100_w;
    gowin_mgmt_pll i_mgmt_pll (.lock(), .clkout(clk100_w), .clkin(clk));

    // CLOSED-LOOP AUX (08-30 port from dp_test): the campaign-proven
    // TLVDS pad cell (see dp_aux_pad.sv for the round 6-10 history).
    // CST changed in lockstep: dp_aux_p = LVDS25 pair G15,G16 with
    // PULL_MODE=DOWN; the old two-pin LVCMOS33 pseudo-diff entries and
    // the "AUX receive electrically dead" era are over.
    dp_aux_pad #(.AUX_TLVDS(1)) i_aux_pad (
        .clk100    (clk100_w),
        .dp_aux_p  (dp_aux_p),
        .dp_aux_n  (dp_aux_n),
        .auxch_in  (dp_auxch_in_w),
        .auxch_out (dp_auxch_out_w),
        .auxch_tri (dp_auxch_tri_w)
    );

    wire dp_link_established_w, dp_video_live_w;
    wire        dp_wedge_w;
    wire [15:0] dp_errcnt0_w, dp_errcnt1_w;
    wire        dp_drp_clk_w;   // cm_life/DRP clock tap (freq-meter diag)
    wire [7:0]  dp_serdes_status_w;
    // raw {DPCD 0x001 MAX_LINK_RATE, DPCD 0x002 MAX_LANE_COUNT byte} from
    // the AUX caps read — the adapter census's second gate (telnet 'd')
    wire [15:0] dp_sink_caps_w;

    dp_transmitter #(
        .LANE_COUNT     (2),
        .LINK_RATE_MBPS (2700),
        // The framebuffer answer path gets a full extra clk_pix cycle
        // (matches the framebuffer's new pipeline stage 3)
        .RGB_LATENCY    (2),
        // Packer per-line schedule from BSRAM (PnR campaign: replaces the
        // marginal clk_sym Bresenham walk cone; sim-verified against the
        // shadow walk). Hex generated by gen_packer_sched.py for 1080p/2L.
        .SCHED_ROM      (1),
        .SCHED_HEX      ("video_sched_1080p_2l.hex"),
        // CLOSED-LOOP DP STACK (08-30 port): the exact policy set the
        // campaign validated on dp_test — soak-proven on BOTH dies
        // (SER < 1e-12/1e-13, zero blinks). See the answer-key doc.
        .BLIND_SINK       (0),
        .POLITE_ATTACH    (1),
        .IRQ_SERVICE      (2),          // ESI servicing (wire-proven)
        .TRAIN_RECOVER    (1),          // paced retries, TX held
        .ERRCNT_READ      (1),          // 0x210-0x213 every check
        .HPD_DISCONNECT_RESETS(0),      // flap storms: no HPD teardown
        // a2p25 AUX/training stack port (10-12, c7064c6e..e4f2e056 whole;
        // see bringup_1_0a3_log.md). Every new knob is pinned EXPLICITLY at
        // the value this board ran before, so the only behaviour change in
        // this bitstream is the one the port carries at defaults: the EQ
        // status-read dwell now follows the sink's DPCD 0x00E
        // TRAINING_AUX_RD_INTERVAL (0 -> 400 us as before; n -> n x 4 ms,
        // cap 16 ms) instead of a fixed 4 x 100 us, plus the 16-byte
        // capability read that fetches it and the msg-0x00 engine fix.
        .LINK_CHECK       (1),          // spec flow: periodic/hpd_irq status
                                        // checks tear a failed link down
                                        // (what the a2mega always ran;
                                        // a2p25's 0/2 were AUX-RX bring-up aids)
        .LINK_CHECK_CLKS  (27'd99999999), // ~1 s at 100 MHz, as before
        .RETRY_WATCHDOG_CLKS(29'd49999999), // 0.5 s attach watchdog, as before
        .EQ_WAIT_MULT     (6'd1),       // no extra EQ-dwell floor: the
                                        // 0x00E-derived dwell alone
        .TRAIN_ERRCNT     (0),          // no 0x210 reads inside the EQ loop
        .LATE_REPLY_DRAIN (0),          // a2p25 drains converters' trailing
                                        // DEFER bytes; NOT taken here unless
                                        // an a2mega sink shows the need
        // ECHO_SINK_ADJUST is an AFE-sequencer-OFF feature (a2p25: the
        // SN75DP130 redriver snoops TRAINING_LANEx_SET). The a2mega's AFE
        // policy is the M5 runtime sequencer below (ENABLE_AFE_ADJUST from
        // the die pkg) which already declares the truthful lane-set byte,
        // so the echo path stays off = byte-identical legacy.
        .ECHO_SINK_ADJUST (0),
        // M5 runtime AFE: per-die verified bases from the die pkg
        .ENABLE_AFE_ADJUST(dp_test_die_pkg::ENABLE_AFE_ADJUST),
        .AFE_LANE_BASE0   (dp_test_die_pkg::AFE_LANE_BASE0),
        .AFE_LANE_BASE1   (dp_test_die_pkg::AFE_LANE_BASE1),
        .AFE_APPLY_ON_START(0),         // trust boot csr (804/auto both dies)
        .H_VISIBLE (1920), .H_TOTAL (2200), .H_SYNC_WIDTH (44), .H_START (192),
        .V_VISIBLE (1080), .V_TOTAL (1125), .V_SYNC_WIDTH (5),  .V_START (41),
        .PIXEL_CLK_MULT (11),
        .PIXEL_CLK_DIV  (10),
        .AUDIO_RATE     (AUDIO_RATE),
        .AUDIO_BIT_WIDTH(16)
    ) i_dp (
        .clk100            (clk100_w),
        .refclk0           (1'b0),      // IP mode: refclk = Q0_REFCLK1 pad
        .refclk1           (1'b0),
        .sim_clk_pixel     (1'b0),
        .reset             (ddr_rst_w),
        .clk_audio         (clk_audio),
        .audio_sample_word (audio_sample_word),
        .clk_pixel         (clk_pixel_w),
        .rgb               (overlay_en_w ? overlay_rgb_w : dp_rgb_r),
        .cx                (dp_cx_raw_w),
        .cy                (dp_cy_raw_w),
        .frame_width(), .screen_width(), .frame_height(), .screen_height(),
        .dp_tx_lane_p      (),          // dedicated SERDES bumps, not fabric
        .dp_tx_lane_n      (),
        .hpd               (dp_hpd),
        .auxch_in          (dp_auxch_in_w),
        .auxch_out         (dp_auxch_out_w),
        .auxch_tri         (dp_auxch_tri_w),
        .link_established  (dp_link_established_w),
        .video_live        (dp_video_live_w),
        .clk_symbol_out    (),
        .serdes_status     (dp_serdes_status_w),
        .hpd_present_out   (),
        .debug             (),
        .wedge_suspect     (dp_wedge_w),
        .debug_drp_clk     (dp_drp_clk_w),
        .debug_errcnt0     (dp_errcnt0_w),
        .debug_errcnt1     (dp_errcnt1_w),
        .debug_sink_caps   (dp_sink_caps_w),
        // a2p25-stack observe/liveness outputs (LINK_CHECK==2 counters are
        // zero at LINK_CHECK=1; packer underrun/level unread here — the
        // ESP32 telemetry map has no slot for them yet)
        .debug_obs         (),
        .debug_auxif       (),
        .debug_underrun_cnt(),
        .debug_fifo_level  (),
        // DRP register-readback debug bridge (used interactively by the
        // dp_test bitstream; idle here — index parked, outputs unread)
        .drp_dbg_idx       (5'd0),
        .drp_dbg_data      (),
        .drp_dbg_addr      (),
        .drp_dbg_done      ()
    );

    // Register framebuffer RGB output for the DP pull interface
    always @(posedge clk_pixel_w) begin
        dp_rgb_r <= fb_rgb_w;
    end

    // DDR3 calibration status on LED[1]; DP bring-up ladder on LED[2:3]
    assign led[1] = !init_calib_complete_w;
    assign led[2] = ~dp_link_established_w;
    assign led[3] = ~dp_video_live_w;

    // =========================================================================
    // USB HID host — REMOVED on 1.0a3 (no USB-A port; gamepads/keyboards now
    // come via the ESP32's USB-C or the telnet menu mirror). The ESP32
    // readback registers keep their interface; tie them to "no device".
    // =========================================================================
    wire [1:0]  hid_typ_sync1      = 2'd0;
    wire        hid_connerr_sync1  = 1'b0;
    wire [3:0]  hid_cnt_sync1      = 4'd0;
    wire [7:0]  pad_btns0_sync1    = 8'd0;
    wire [7:0]  pad_btns1_sync1    = 8'd0;
    wire [7:0]  key_mod_sync1      = 8'd0;
    wire [7:0]  key0_sync1         = 8'd0;
    wire [7:0]  key1_sync1         = 8'd0;
    wire [7:0]  dbg_usb_line_w     = 8'd0;
    wire [7:0]  dbg_usb_pc_w       = 8'd0;
    wire [47:0] usb_dbg_desc_sync1 = 48'd0;
    wire [7:0]  usb_dbg_flags_sync1 = 8'd0;
    wire [7:0]  usb_cnt_start_sync1 = 8'd0;
    wire [7:0]  usb_cnt_rdy_sync1   = 8'd0;


    // DDR3 sequencer telemetry (clk 50 MHz -> clk_logic; quasi-static)
    reg [7:0] ddr3_retry_sync0, ddr3_retry_sync1;
    reg [4:0] ddr3_seq_sync0, ddr3_seq_sync1;
    always @(posedge clk_logic_w) begin
        ddr3_retry_sync0 <= ddr3_retry_cnt_r;  ddr3_retry_sync1 <= ddr3_retry_sync0;
        ddr3_seq_sync0   <= {ddr3_rst_n_r, pll_lock_w, init_calib_complete_w, ddr3_seq_state_r};
        ddr3_seq_sync1   <= ddr3_seq_sync0;
    end

    // DP link telemetry for the ESP32 census/debug regs 0x3C-0x3F
    // (clk100 -> clk_logic; all quasi-static — caps latch once per attach,
    // status/serdes bits change on human timescales)
    reg [15:0] dp_caps_sync0, dp_caps_sync1;
    reg [7:0]  dp_serdes_sync0, dp_serdes_sync1;
    reg [2:0]  dp_stat_sync0, dp_stat_sync1;
    always @(posedge clk_logic_w) begin
        dp_caps_sync0   <= dp_sink_caps_w;      dp_caps_sync1   <= dp_caps_sync0;
        dp_serdes_sync0 <= dp_serdes_status_w;  dp_serdes_sync1 <= dp_serdes_sync0;
        dp_stat_sync0   <= {dp_wedge_w, dp_video_live_w, dp_link_established_w};
        dp_stat_sync1   <= dp_stat_sync0;
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

    reg [23:0] fb_rgb_osd_r;
    always @(posedge clk_pixel_w) fb_rgb_osd_r <= fb_rgb_w;

    osd_text_overlay #(
        .X_OFFSET(120),   // Apple-display-matched: 1680x960, the same rectangle
        .Y_OFFSET(60),    // as the framebuffer's x3/x5 scan-out window
        .H_REP(6),        // 3x of the 2x-doubled source, like the Apple fb
        .V_REP(5)
    ) osd_overlay (
        .clk_i      (clk_pixel_w),
        .reset_n    (device_reset_n_w),
        .enable_i   (osd_en_sync1),

        .screen_x_i (ovl_cx_q),
        .screen_y_i (ovl_cy_q),

        .vram_addr_o(osd_vram_addr_w),
        .vram_data_i(osd_vram_data_w),

        // Registered fb feed: the line_buf BSRAM -> mix -> output-reg hop
        // misses setup at 148.5 MHz (module predates the 1080p port; worst
        // -0.28 ns). One register here relaxes it; the base video shifts
        // 1 px under the OSD text — imperceptible.
        .r_i        (fb_rgb_osd_r[23:16]),
        .g_i        (fb_rgb_osd_r[15:8]),
        .b_i        (fb_rgb_osd_r[7:0]),

        .r_o        (osd_rgb_w[23:16]),
        .g_o        (osd_rgb_w[15:8]),
        .b_o        (osd_rgb_w[7:0])
    );

    // =========================================================================
    // Scanline effect — ONE place, on the video+OSD composite, scale-aware
    // via the fb's exported scan-out geometry. Combinational in the pixel
    // path (no RGB_LATENCY change); the DebugOverlay stays undimmed.
    // =========================================================================
    wire [23:0] scanout_rgb_w;

    scanline_dim u_scanline_dim (
        .clk_i       (clk_pixel_w),
        .enable_i    (1'b1),
        .screen_x_i  (ovl_cx_q),
        .screen_y_i  (ovl_cy_q),
        .v_scale_i   (fb_v_scale_w),
        .v_border_i  (fb_v_border_w),
        .rgb_i       (osd_rgb_w),
        .rgb_o       (scanout_rgb_w)
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
        // Hex 2: DOC REQUESTS PER FRAME, high byte (count >> 8). Ground
        // truth of DOC memory demand, comparable across configs. Expected:
        // BSRAM baseline all-32 ≈ 0x3A (1 request/slot, ~14.9k/frame);
        // pipelined rev-3 ≈ 0x04 (~1.2k/frame). ~2x the expected value
        // convicts double-issue.
        dbg_hex_sync0[2] <= doc_dbg_req_frame_r[15:8];
                                                dbg_hex_sync1[2] <= dbg_hex_sync0[2];
        // Hex 3: GLU SOUND-RAM WRITE DROPS (sticky) — sample bytes lost
        // because the write queue overflowed while the port was starved.
        // THE KEY COUNTER: nonzero = the wavetable in DDR3 is corrupt, and
        // the DOC will faithfully play wrong-but-plausible samples
        // (harmonic distortion) with every DOC-side counter reading clean.
        // Never observable before — this port was left unconnected.
        // (Was: DOC STALE FETCH, measured 00 during distortion.)
        dbg_hex_sync0[3] <= glu_wq_drops_w;
                                                dbg_hex_sync1[3] <= dbg_hex_sync0[3];
        // Hex 6: DOC FETCH DROP — fetch request dropped, internal FIFO
        // full. Must stay 00 (design invariant).
        dbg_hex_sync0[6] <= doc_dbg_fetch_drop_w;
                                                dbg_hex_sync1[6] <= dbg_hex_sync0[6];
`ifdef DOC_KEEP_FB_DEBUG_HEX  // original display-debug counters, disabled
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
`endif
        // Hex 4: DOC MIN INTER-REQUEST GAP last frame, in clk_logic cycles
        // (x18.5 ns; 0xFF = no requests). Ground truth of the tightest
        // request spacing the memory path must service. Expected: BSRAM
        // baseline ≈ 0x3C (one request per 60-cycle slot); values well
        // below ~0x30 mean multiple requests per slot (burst issue or
        // double-issue). (Was: DOC PRIME MISS — measured 00 during
        // distortion, hypothesis retired.)
        dbg_hex_sync0[4] <= doc_dbg_mingap_frame_r;
                                                dbg_hex_sync1[4] <= dbg_hex_sync0[4];
        // Hex 5: RD FIFO DROP — read beats dropped because rd_fifo was full.
        // Nonzero = data loss in the read response path (corruption source).
        dbg_hex_sync0[5] <= fb_dbg_rd_fifo_drop_w;
                                                dbg_hex_sync1[5] <= dbg_hex_sync0[5];
`ifdef DOC_KEEP_FB_DEBUG_HEX
        // Hex 6: LINE LAG MAX — peak display-vs-completed-line lag in lines.
        // 0 = fetcher always ahead of display. Nonzero = fetcher falling
        // behind; higher = worse. Clamped to 0xFF.
        dbg_hex_sync0[6] <= fb_dbg_line_lag_max_w;
                                                dbg_hex_sync1[6] <= dbg_hex_sync0[6];
`endif
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

    // ------------------------------------------------------------------
    // cm_life frequency meter (DIAGNOSTIC, CM_LIFE_METER=1 builds only):
    // the 10 ns cm_life SDC constraint has no provenance — this measures
    // the GTR12's actual FABRIC_CM_LIFE_CLK rate on hardware. dp_test
    // freq-checker pattern: 1 s window from the 50 MHz crystal, counted
    // in the drp/cm_life domain (post-unification the fabric tap IS the
    // arbiter's clock net), delta = Hz. Readout: overlay hex slots 4-7
    // show delta[27:0] big-endian (slot4=MSB), displacing the DOC/fb
    // counters for the diag build only. delta is quasi-static (1/s), so
    // the existing 2FF hex sync chain is the CDC.
    // ------------------------------------------------------------------
    localparam CM_LIFE_METER = 0;
    wire [27:0] cml_delta_w;
    wire [3:0]  cml_chan_w;
    generate if (CM_LIFE_METER != 0) begin : g_cmlife_meter
        reg [25:0] cmw_cnt_r = '0;
        reg        cmw_tgl_r = 1'b0;
        always @(posedge clk) begin
            if (cmw_cnt_r == 26'd49_999_999) begin
                cmw_cnt_r <= '0;
                cmw_tgl_r <= ~cmw_tgl_r;
            end else
                cmw_cnt_r <= cmw_cnt_r + 26'd1;
        end
        reg [27:0] cml_cnt_r = '0, cml_last_r = '0, cml_delta_r = '0;
        reg [2:0]  cml_tgl_sync_r = '0;
        always @(posedge dp_drp_clk_w) begin
            cml_cnt_r      <= cml_cnt_r + 28'd1;
            cml_tgl_sync_r <= {cml_tgl_sync_r[1:0], cmw_tgl_r};
            if (cml_tgl_sync_r[2] != cml_tgl_sync_r[1]) begin
                cml_delta_r <= cml_cnt_r - cml_last_r;
                cml_last_r  <= cml_cnt_r;
            end
        end
        // CONTROL CHANNEL: identical meter on the crystal-PLL-locked
        // 100.000 MHz management clock. If the instrument+readout path
        // is sound it must read 05F5E1xx here; any other value convicts
        // the meter, not the measured clock.
        reg [27:0] c1h_cnt_r = '0, c1h_last_r = '0, c1h_delta_r = '0;
        reg [2:0]  c1h_tgl_sync_r = '0;
        always @(posedge clk100_w) begin
            c1h_cnt_r      <= c1h_cnt_r + 28'd1;
            c1h_tgl_sync_r <= {c1h_tgl_sync_r[1:0], cmw_tgl_r};
            if (c1h_tgl_sync_r[2] != c1h_tgl_sync_r[1]) begin
                c1h_delta_r <= c1h_cnt_r - c1h_last_r;
                c1h_last_r  <= c1h_cnt_r;
            end
        end
        // Alternate displayed channel each window: slot4 top nibble =
        // channel id (0 = cm_life, 1 = clk100 control), lower 28 bits =
        // that channel's delta in Hz.
        reg chan_r = 1'b0;
        reg [31:0] disp_r = '0;
        always @(posedge clk) begin
            if (cmw_cnt_r == 26'd0) chan_r <= ~chan_r;
            disp_r <= chan_r ? {4'd1, c1h_delta_r} : {4'd0, cml_delta_r};
        end
        assign cml_delta_w = disp_r[27:0];
        assign cml_chan_w  = disp_r[31:28];
    end else begin : g_no_cmlife_meter
        assign cml_delta_w = 28'd0;
        assign cml_chan_w  = 4'd0;
    end endgenerate

    reg [7:0] cml_hex_sync0 [4], cml_hex_sync1 [4];
    always @(posedge clk_pixel_w) begin
        cml_hex_sync0[0] <= {cml_chan_w, cml_delta_w[27:24]};
        cml_hex_sync0[1] <= cml_delta_w[23:16];
        cml_hex_sync0[2] <= cml_delta_w[15:8];
        cml_hex_sync0[3] <= cml_delta_w[7:0];
        cml_hex_sync1[0] <= cml_hex_sync0[0];
        cml_hex_sync1[1] <= cml_hex_sync0[1];
        cml_hex_sync1[2] <= cml_hex_sync0[2];
        cml_hex_sync1[3] <= cml_hex_sync0[3];
    end

    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),
        .ENABLE(`A2_INSTR_DEBUG_OVERLAY),
        // timing round 2 cones (e)+(k)+(k2): three extra pipeline stages
        // (offset subtracts registered ahead of the region compares; font
        // ROM read split into glyph/row selects; font-row bit select
        // registered before the output muxes); X_OFFSET 16 -> 13
        // compensates their three pixels of shift so the overlay stays
        // where it was
        .OUT_PIPE(1),
        .X_OFFSET(13),
        .Y_OFFSET(24)
    ) debug_overlay (
        .clk_i          (clk_pixel_w),
        .reset_n        (device_reset_n_w),
        .enable_i       (1'b1),

        .hex_values     (CM_LIFE_METER != 0 ?
                         '{dbg_hex_sync1[0], dbg_hex_sync1[1], dbg_hex_sync1[2], dbg_hex_sync1[3],
                           cml_hex_sync1[0], cml_hex_sync1[1], cml_hex_sync1[2], cml_hex_sync1[3]} :
                         '{dbg_hex_sync1[0], dbg_hex_sync1[1], dbg_hex_sync1[2], dbg_hex_sync1[3],
                           dbg_hex_sync1[4], dbg_hex_sync1[5], dbg_hex_sync1[6], dbg_hex_sync1[7]}),

        .debug_bits_0_i (dbg_bits0_sync1),
        .debug_bits_1_i (dbg_bits1_sync1),

        .screen_x_i     (ovl_cx_q),
        .screen_y_i     (ovl_cy_q),

        .r_i            (scanout_rgb_w[23:16]),
        .g_i            (scanout_rgb_w[15:8]),
        .b_i            (scanout_rgb_w[7:0]),

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

    // IIgs CPU-socket control/telemetry window (regs 0x5F index / 0x4F data)
    wire [7:0]   gs_ctrl_w;        // {clear,0,0,0,0,listen,sweep_en,arm}
    wire [3:0]   gs_out_extra_w;   // address-delay sweep
    wire [4:0]   gs_hold_tap_w;    // data-hold sweep
    wire [159:0] gs_tele_w;        // telemetry, connector domain
    wire [5:0]   gs_trace_idx_w;   // bus-trace read index
    wire [23:0]  gs_trig_addr_w;   // trace trigger address
    wire [47:0]  gs_trace_w;       // {frozen, 0, wptr, entry}

    // Octal SPI connector instance
    esp32_ospi_connector #(
        .VERSION_STR(`BUILD_DATETIME),
        .USE_SYNC(1),
        .USE_CRC(0),
        .IDLE_TO_CYC(5_400_000),  // ~100ms at 54MHz
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .EVT_LOG(`A2_INSTR_EVENT_LOG)   // a2mega_profile.vh (1 under GS_SOCKET)
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
        .a2_alive_i(~sleep_w),
        .gs_res_n_i(gs_res_n),
        .storage_settled_o(storage_settled_w),

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
        .dbg_vgc_starved_i(vgc_dbg_starved_w),
        .dbg_usb_line_i(dbg_usb_line_w),
        .dbg_usb_pc_i(dbg_usb_pc_w),
        .dbg_usb_desc_i(usb_dbg_desc_sync1),
        .dbg_usb_flags_i(usb_dbg_flags_sync1),
        .dbg_usb_cnt_start_i(usb_cnt_start_sync1),
        .dbg_usb_cnt_rdy_i(usb_cnt_rdy_sync1),
        .dbg_ddr3_retry_i(ddr3_retry_sync1),
        .dbg_ddr3_seq_i({3'b0, ddr3_seq_sync1}),
        .dbg_dp_caps_i(dp_caps_sync1),
        .dbg_dp_status_i({5'b0, dp_stat_sync1}),
        .dbg_dp_serdes_i(dp_serdes_sync1),
        .dbg_doc_reqf_i(doc_dbg_req_frame_r),
        .dbg_doc_missf_i(16'd0),
        .dbg_doc_tof_i(16'd0),
        .dbg_glu_drops_i(glu_wq_drops_w),
        .dbg_doc_fdrop_i(doc_dbg_fetch_drop_w),
        .dbg_aud_i(aud_cdc_dbg_w),
        .aud_ctl_o(aud_ctl_w),
        .ddr3_reinit_tgl_o(ddr3_reinit_tgl_w),

        .gs_ctrl_o(gs_ctrl_w),
        .gs_out_extra_o(gs_out_extra_w),
        .gs_hold_tap_o(gs_hold_tap_w),
        .gs_tele_i(gs_tele_w),
        .gs_trace_idx_o(gs_trace_idx_w),
        .gs_trig_addr_o(gs_trig_addr_w),
        .gs_trace_i(gs_trace_w),

        .dbg_mem_addr_o(dbg_mem_addr_w),
        .dbg_mem_go_o(dbg_mem_go_w),
        .dbg_mem_busy_i(dbg_mem_busy_w),
        .dbg_mem_data_i(dbg_mem_data_w),

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

    // =========================================================================
    // IIgs CPU-socket 65C816 (drop-in iteration) - 138B builds only
    // =========================================================================
`ifdef GS_SOCKET
    // Sequencer clock: a ~110 MHz PLL of its own (gowin_gs_pll), so the
    // socket adds nothing to clk100, whose AUX ladder sits on the timing
    // knife edge (sharing clk100 cost a roll: AUX at -1.07 ns).  The die's 8
    // PRIMARY clock nets are then all taken and the fabric-routed PHI2 clock
    // lands on a long-wire net; that is acceptable at 2.86 MHz - the routing
    // thrash first blamed on it was the core's inferred latch (see
    // hdl/twgs/65C816/README.md).  The core itself runs on PHI2.
    wire clk_gs_w, gs_pll_lock_w;
    gowin_gs_pll i_gs_pll (.lock(gs_pll_lock_w), .clkout(clk_gs_w), .clkin(clk));

    // control: connector (clk_logic) -> sequencer domain, quasi-static
    reg [7:0] gs_ctrl_s0, gs_ctrl_s1;
    reg [3:0] gs_oe_s0, gs_oe_s1;
    reg [4:0] gs_ht_s0, gs_ht_s1;
    reg [23:0] gs_ta_s0, gs_ta_s1;
    always @(posedge clk_gs_w) begin
        gs_ctrl_s0 <= gs_ctrl_w;      gs_ctrl_s1 <= gs_ctrl_s0;
        gs_oe_s0   <= gs_out_extra_w; gs_oe_s1   <= gs_oe_s0;
        gs_ht_s0   <= gs_hold_tap_w;  gs_ht_s1   <= gs_ht_s0;
        gs_ta_s0   <= gs_trig_addr_w; gs_ta_s1   <= gs_ta_s0;
    end

    wire [7:0]  gs_d_o_w;
    wire        gs_d_oe_w;
    assign gs_d = gs_d_oe_w ? gs_d_o_w : 8'bz;

    wire [7:0]  gs_status_w;
    wire [31:0] gs_cycle_w;
    wire [15:0] gs_stall_w, gs_be_w, gs_hmis_w, gs_hsmp_w, gs_per_w, gs_high_w;
    wire [23:0] gs_last_w;
    wire [39:0] gs_trace_data_w;
    wire [5:0]  gs_trace_wptr_w;
    wire        gs_trace_frozen_w, gs_trace_trigd_w;

    gs_socket_ctl i_gs_socket (
        .clk(clk_gs_w),
        .rst_n(device_reset_n_w & gs_pll_lock_w),
        .arm_i(gs_ctrl_s1[0]),
        .listen_i(gs_ctrl_s1[2]),
        .sweep_en_i(gs_ctrl_s1[1]),
        .out_extra_i(gs_oe_s1),
        .hold_tap_i(gs_ht_s1),
        .clear_i(gs_ctrl_s1[7]),
        .force_slow_i(gs_ctrl_s1[5]),
        .trace_freeze_i(gs_ctrl_s1[3]),
        .trace_trig_en_i(gs_ctrl_s1[4]),
        .trace_trig_mode_i(gs_ctrl_s1[6]), .trace_trig_addr_i(gs_ta_s1),
        .rd_clk(clk_logic_w), .trace_idx_i(gs_trace_idx_w),
        .trace_data_o(gs_trace_data_w), .trace_wptr_o(gs_trace_wptr_w),
        .trace_frozen_o(gs_trace_frozen_w), .trace_trigd_o(gs_trace_trigd_w),
        .gs_ph2_i(gs_ph2), .gs_rdy_i(gs_rdy), .gs_irq_n_i(gs_irq_n), .gs_nmi_n_i(gs_nmi_n),
        .gs_res_n_i(gs_res_n), .gs_abort_n_i(gs_abort_n), .gs_be_i(gs_be),
        .gs_d_i(gs_d), .gs_d_o(gs_d_o_w), .gs_d_oe_o(gs_d_oe_w),
        .gs_a_o(gs_a), .gs_rw_o(gs_rw), .gs_vp_o(gs_vp), .gs_rdy_out_o(gs_rdy_out),
        .gs_d_dir_o(gs_d_dir), .gs_data_oe_n_o(gs_data_oe_n), .gs_addr_oe_n_o(gs_addr_oe_n),
        .gs_ctl_oe_n_o(gs_oe_n),
        .status_o(gs_status_w), .cycle_count_o(gs_cycle_w), .stall_count_o(gs_stall_w),
        .be_count_o(gs_be_w), .hold_mismatch_o(gs_hmis_w), .hold_samples_o(gs_hsmp_w),
        .ph2_period_o(gs_per_w), .ph2_high_o(gs_high_w), .last_addr_o(gs_last_w)
    );

    // telemetry: sequencer domain -> connector domain (two flops per bit;
    // a wide counter may tear between bytes, as the other debug counters do)
    reg [159:0] gs_tele_s0, gs_tele_s1;
    always @(posedge clk_logic_w) begin
        // STATUS bits 1:0 carry the SLOT-side /DMA and /RDY levels so the FPI's
        // BE/RDY handshake can be matched against what the slots are asserting.
        gs_tele_s0 <= {gs_last_w, gs_high_w, gs_per_w, gs_hsmp_w, gs_hmis_w, gs_be_w, gs_stall_w, gs_cycle_w,
                       gs_status_w[7:2], a2_dma_n, a2_rdy_n};
        gs_tele_s1 <= gs_tele_s0;
    end
    assign gs_tele_w = gs_tele_s1;
    // trace: the entry is read in clk_logic already; the write pointer is
    // two-flopped (it is static while the ring is frozen, which is when it
    // is read).
    reg [7:0] gs_twp_s0, gs_twp_s1;
    always @(posedge clk_logic_w) begin
        gs_twp_s0 <= {gs_trace_frozen_w, gs_trace_trigd_w, gs_trace_wptr_w};
        gs_twp_s1 <= gs_twp_s0;
    end
    assign gs_trace_w = {gs_twp_s1, gs_trace_data_w};
`else
    assign gs_tele_w = 160'd0;
    assign gs_trace_w = 48'd0;
`endif

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