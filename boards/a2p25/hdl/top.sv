//
// Top module for the A2P25 Apple II card (Tang Primer 25K SOM, displayport1
// board revision). Derived from the a2mega 1.0a3 top: same ESP32 OSPI
// architecture and feature set, with HyperRAM instead of DDR3
// (hyperram_ports), the GW5A-25 hardened D-PHY as the DisplayPort PHY
// (4 lanes RBR, 1080p60) and this board's pinout. Port plan and the
// resource scoping decisions: boards/a2p25/docs/TOP_INTEGRATION_PLAN.md.
//
// (c) 2023,2024,2025,2026 Ed Anuff <ed@a2fpga.com>
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
`include "a2p25_profile.vh"

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int PIXEL_SPEED_HZ = CLOCK_SPEED_HZ / 2,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    // No DIP switches on this board: these are build-time until they move
    // to OSD settings over the ESP32 link.
    parameter bit SCANLINES_ENABLE = 0,
    parameter bit APPLE_SPEAKER_ENABLE = 1,
    parameter bit SLOT_7_ENABLE = 0,

    // SuperSprite/F18A deferred on the GW5A-25 (resource budget, see the
    // integration plan). The slot ID stays reserved.
    parameter bit SUPERSPRITE_ENABLE = `A2_FEATURE_SUPERSPRITE,
    parameter bit [7:0] SUPERSPRITE_ID = 1,

    // Mockingboard off for the first fit on the GW5A-25: with it the core was
    // 20.3k/23k logic, 97% CLS, and placement failed (integration plan §3).
    parameter bit MOCKINGBOARD_ENABLE = `A2_FEATURE_MOCKINGBOARD,
    parameter bit [7:0] MOCKINGBOARD_ID = 2,

    // No UART pins on this revision: the SSC can be built but has no wire.
    parameter bit SUPERSERIAL_ENABLE = `A2_FEATURE_SUPERSERIAL,
    parameter bit SUPERSERIAL_IRQ_ENABLE = 1,
    parameter bit [7:0] SUPERSERIAL_ID = 3,

    parameter bit DISK_II_ENABLE = `A2_FEATURE_DISK_II,
    parameter bit [7:0] DISK_II_ID = 4,

    // Uthernet II off on the GW5A-25: its 16 KB W5100 buffer is ~10 of the
    // 56 BSRAM blocks and the first fit check came out at 67 (integration plan §3).
    parameter bit UTHERNET2_ENABLE = `A2_FEATURE_UTHERNET2,
    parameter bit [7:0] UTHERNET2_ID = 5,

    parameter bit HDD_ENABLE = `A2_FEATURE_HDD,
    parameter bit [7:0] HDD_ID = 6,

    parameter bit ENSONIQ_ENABLE = `A2_FEATURE_ENSONIQ,
    parameter bit ENSONIQ_MONO_MIX = 0, // If true, mono mix is used instead of stereo

    parameter int GS = 0,                       // IIgs mode is autodetected (apple_bus); forcing it did not change SHR/DOC (10-11)
    parameter int ENABLE_FILTER = 1,            // audio_out IIR low-pass + DC blocker on clk_logic ahead of the CDC
    parameter int ENABLE_DENOISE = 0,           // Enable denoise of clocks
    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit HDMI_SLEEP_ENABLE = 0,        // Sleep video output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1        // Allow driving data to Apple bus

) (
    // 50 MHz SOM oscillator
    input clk,

    // Apple II bus (through the carrier's level shifters; see
    // PINOUT_DISPLAYPORT1.md section 2). The INT/DMA daisy chain is
    // strapped on the card and /RES is driven by the ESP32: none of those
    // reach the FPGA on this revision.
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
    input  a2_phi1,
    input  a2_q3,
    input  a2_7M,

    output a2_a_dir,
    input [15:0] a2_a,

    output a2_d_dir,
    inout [7:0] a2_d,

    // DisplayPort over USB-C alt mode: AUX pair into the SN75DP130 (bias
    // network on the carrier), HPD from the ESP32 (PD-derived), main link
    // on the MIPI D-PHY M0 quad (dedicated pads, DP lane n = D-PHY lane 3-n).
    inout  dp_aux_p,
    inout  dp_aux_n,
    input  dp_hpd,
    inout  wire  dphy_ck_p,
    inout  wire  dphy_ck_n,
    inout  wire  [3:0] dphy_d_p,
    inout  wire  [3:0] dphy_d_n,

    // FPGA LED (active high)
    output led,

    // HyperRAM U6 (S27KL0642), CK# and RESET# not connected (in spec for
    // the Infineon part at the CR1 default — never write CR1)
    output wire  hr_ck,
    output wire  hr_cs_n,
    inout  wire  hr_rwds,
    inout  wire  [7:0] hr_dq,

    // ESP32-S3 Octal SPI link (ESP32 is the master)
    input         esp_sclk,
    inout  [7:0]  esp_data

);

    // Clocks. 50 MHz SOM oscillator -> Gowin_PLL (54 MHz, also the D-PHY
    // reference) -> hr_clk_pll (54 MHz logic clock + 108 MHz HyperBus CK +
    // its 90-degree copy). ALL core logic runs on the HyperRAM PLL's 54 MHz
    // so the memory clients, the arbiter and the controller share one
    // clock (no CDC in the memory path). The DP management clock (100 MHz)
    // and the pixel clock (148.5 MHz, from the 81 MHz D-PHY symbol clock)
    // are made in the DP section. PLLA budget: 5 of 6.
    wire clk54_pll_w;
    wire clk54_lock_w;
    Gowin_PLL i_sys_pll (
        .clkin   (clk),
        .mdclk   (clk),
        .clkout0 (),                 // 27 MHz (unused)
        .clkout1 (),                 // 135 MHz (unused)
        .clkout2 (clk54_pll_w),
        .lock    (clk54_lock_w)
    );
    wire clk_logic_pll_w, clk_mem_w, clk_mem_90_w, hr_pll_lock_w;
    hr_clk_pll i_hr_pll (
        .lock       (hr_pll_lock_w),
        .clk        (clk_logic_pll_w),
        .clk_mem    (clk_mem_w),
        .clk_mem_90 (clk_mem_90_w),
        .clkin      (clk54_pll_w)
    );
    wire clk_logic_w = clk_logic_pll_w;
    wire clk_lock_w  = clk54_lock_w & hr_pll_lock_w;
    wire clk_pixel_w;               // video pixel clock (from dp_transmitter)

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
    assign led = led_r;

    // Power-on reset generation
    localparam RESET_CYCLES = 100;  // Number of clock cycles to hold reset
    
    reg rstn_r = 1'b0;
    reg [$clog2(RESET_CYCLES+1)-1:0] reset_counter_r = '0;

    always @(posedge clk_logic_w) begin
        if (!clk_lock_w) begin
            rstn_r <= 1'b0;
            reset_counter_r <= '0;
        end else if (reset_counter_r == RESET_CYCLES) begin
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

    // No DIP switches on this board (build parameters; OSD settings later)
    wire sw_scanlines_w = SCANLINES_ENABLE;
    wire sw_apple_speaker_w = APPLE_SPEAKER_ENABLE;
    wire sw_slot_7_w = SLOT_7_ENABLE;
    wire a2_res_out_n_w;          // apple_bus's reset-hold output: no FPGA pin here (ESP32 drives /RES)

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
        .ENABLE_DENOISE(ENABLE_DENOISE),
        // This carrier's level shifters: sample M2B0 the way the rev-0 a2p25
        // bus did (2FF + phase count 12), not at the a2mega's Q3 edge.
        .M2B0_PHASE_SAMPLE(0),
        .M2B0_COUNT(12)
    ) apple_bus (
        .clk_logic_i(clk_logic_w),
        .clk_pixel_i(clk_logic_w),    // F18A runs on clk_logic (54 MHz) — no separate pixel clock
        .system_reset_n_i(system_reset_n_w),
        .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1),
        .a2_q3_i(a2_q3),
        .a2_7M_i(a2_7M),

        .sw_gs_i(1'b0),               // no DIP: IIgs mode comes from the autodetect
        .gs_status_o(gs_status_w),

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
        .a2_res_out_n(a2_res_out_n_w),
        .a2_int_out_n(),              // INT/DMA chain is strapped on the card
        .a2_int_in_n(1'b1),
        .a2_dma_out_n(),
        .a2_dma_in_n(1'b1),
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
    // 2026-10-13: DOC wavetable reads moved to the top-priority port. The
    // baseline DOC has a hard ~840 ns budget per fetch (0x80 substituted and
    // a late response discarded otherwise); at port 2 a fetch could wait
    // behind an in-flight FB burst plus two queued shadow transactions and
    // miss it under SHR load (audible). A DOC read is one word per ~1 us, so
    // the shadow paths lose at most ~170 ns per microsecond to it.
    // 2026-10-14 (Marble Madness): with the DOC at port 0 the VGC's shadow
    // reads starved under SHR + heavy DOC load (stale-word swaps 6-32/frame =
    // visible smear) while DOC late fetches ran ~7/s. A late DOC fetch is now
    // silent (doc5503 holds the previous sample), a late VGC word is visible,
    // so the shadow READ goes back on top and the DOC sits at 1 — still above
    // the shadow write FIFO (16 deep, drop counter) and the framebuffer.
    // 2026-10-15 (Arkanoid pops, RESOURCE_AUDIT §7.21): that swap was the
    // regression. Under SHR the VGC's shadow reads are continuous during the
    // active line, so a static-priority arbiter starves port 1 behind them:
    // 7% of DOC fetches (1 oscillator, no DOC-side contention) missed the
    // 840 ns budget and the hold-last-sample path ran at ~1800/s — audible
    // crackle, vs 0.4/s with the DOC on top. Repeating a sample is only
    // inaudible when it is rare. The DOC goes back to port 0; the word cache
    // (doc_fetch_cache) has since cut DOC traffic 10-16x, so the VGC loses at
    // most one single-word read (~300 ns) per DOC miss, not the 2026-10-14
    // uncached stream that starved it. Verify: VGC STALE 0 on Marble Madness.
    localparam DOC_MEM_PORT      = 0;
    localparam SHADOW_READ_PORT  = 1;
    localparam SHADOW_WRITE_PORT = 2;
    localparam GLU_MEM_PORT      = 3;
    localparam FB_WRITE_PORT   = 4;
    localparam FB_READ_PORT    = 5;
    // The ESP32 memory-peek reader gets a 7th port only when the profile
    // asks for it (A2_INSTR_MEM_PEEK): each port is a 2-slot x 155-bit
    // request queue in flops plus its share of the 7:1 muxes.
    localparam MEM_PEEK          = `A2_INSTR_MEM_PEEK;
    localparam DBG_MEM_PORT      = 6;
    localparam NUM_DDR3_PORTS    = 6 + MEM_PEEK;   // (name kept from the a2mega: the port roles are identical)

    // DDR3 memory map — word address offsets (32-bit word addressing)
    // Applied per-port inside ddr3_ports via PORT_BASE_ADDR parameter.
    localparam [20:0] FB_WORD_BASE      = 21'h000000;  // 0MB (double-buffered: buf0 0x000000-0x025800, buf1 0x025800-0x04B000)
    localparam [20:0] SHADOW_WORD_BASE  = 21'h050000;  // 1.25MB — after double-buffered FB (was 0x040000)
    localparam [20:0] ENSONIQ_WORD_BASE = 21'h080000;  // 2MB (28'h0200000 >> 2)

    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32))
        hr_mem_ports[0:NUM_DDR3_PORTS-1]();

    apple_memory #(
        .VGC_MEMORY(1)
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .main_mem_if(hr_mem_ports[SHADOW_WRITE_PORT]),
        .video_mem_if(hr_mem_ports[SHADOW_READ_PORT]),

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
    wire [15:0] doc_dbg_timeouts_w;
    // per-frame latches of the baseline-DOC fetch telemetry (memory reads = word-cache misses, late fetches)
    reg  [15:0] doc_dbg_miss_prev_r, doc_dbg_miss_frame_r, doc_dbg_to_prev_r, doc_dbg_to_frame_r;
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
        .USE_DDR3_PIPELINED(0),   // RESOURCE AUDIT §7.5 measurement build
        // FF register banks: 0 BSRAM vs ~2k FF. The DPB/packed-record banks
        // (BANKS_IN_BSRAM=1) spend 6 blocks at low fill for state the fabric
        // holds comfortably (regs at 44%); GW5A has no distributed RAM, so
        // FFs are the honest medium for a 320-byte register file. The FF
        // path is baseline-equivalent read timing and is co-validated by
        // every suite run (both modes). See ensoniq_ddr3_pipelined_design.md
        // for the 1-block scheduled-SDPB endpoint if BSRAM pressure returns.
        .DOC_BANKS_IN_BSRAM(1),   // RESOURCE AUDIT §7.5 measurement build: banks in BSRAM
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

        .glu_mem_if(hr_mem_ports[GLU_MEM_PORT]),
        .glu_wq_drops_o(glu_wq_drops_w),
        .doc_mem_if(hr_mem_ports[DOC_MEM_PORT]),
        // Gating disabled: with DOC above the FB ports, deferral is not only
        // unnecessary but harmful (convoy formation — see priority comment).
        // Keep fb_fetch_active_w wired in case a future config re-enables.
        .fb_fetch_active_i(1'b0),

        .dbg_doc_prime_miss_o(doc_dbg_prime_miss_w),
        .dbg_doc_stale_fetch_o(doc_dbg_stale_fetch_w),
        .dbg_doc_fetch_drop_o(doc_dbg_fetch_drop_w),
        .dbg_doc_fetch_count_o(doc_dbg_fetch_count_w),
        .dbg_doc_timeouts_o(doc_dbg_timeouts_w),
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
            doc_dbg_miss_frame_r   <= doc_dbg_fetch_count_w - doc_dbg_miss_prev_r;
            doc_dbg_miss_prev_r    <= doc_dbg_fetch_count_w;
            doc_dbg_to_frame_r     <= doc_dbg_timeouts_w - doc_dbg_to_prev_r;
            doc_dbg_to_prev_r      <= doc_dbg_timeouts_w;
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

    generate if (MEM_PEEK) begin : g_mem_peek
        assign hr_mem_ports[DBG_MEM_PORT].rd      = dbg_mem_rd_w;
        assign hr_mem_ports[DBG_MEM_PORT].wr      = 1'b0;
        assign hr_mem_ports[DBG_MEM_PORT].addr    = dbg_mem_port_addr_w;
        assign hr_mem_ports[DBG_MEM_PORT].data    = 32'd0;
        assign hr_mem_ports[DBG_MEM_PORT].byte_en = 4'b1111;
        assign hr_mem_ports[DBG_MEM_PORT].burst   = 1'b0;

        ddr3_debug_reader u_ddr3_dbg_reader (
            .clk    (clk_logic_w),
            .rst_n  (device_reset_n_w),
            .mem_rd_o        (dbg_mem_rd_w),
            .mem_addr_o      (dbg_mem_port_addr_w),
            .mem_available_i (hr_mem_ports[DBG_MEM_PORT].available),
            .mem_ready_i     (hr_mem_ports[DBG_MEM_PORT].ready),
            .mem_q_i         (hr_mem_ports[DBG_MEM_PORT].q),
            .addr_i (dbg_mem_addr_w),
            .req_i  (dbg_mem_go_w),
            .busy_o (dbg_mem_busy_w),
            .data_o (dbg_mem_data_w)
        );
    end else begin : g_no_mem_peek
        // Window regs 0x34-0x3B still exist in the connector; GO never
        // reports busy and the data reads back as a marker.
        assign dbg_mem_rd_w        = 1'b0;
        assign dbg_mem_port_addr_w = 21'd0;
        assign dbg_mem_busy_w      = 1'b0;
        assign dbg_mem_data_w      = 32'hDEAD_BEEF;
    end endgenerate

    // SuperSprite

    // SuperSprite / F18A: deferred on this board (resource budget). The
    // framebuffer writer's composited input is the plain Apple II video.
    wire [0:7] ssp_d_w = 8'd0;
    wire ssp_rd = 1'b0;
    wire vdp_irq_n = 1'b1;
    wire [9:0] ssp_audio_w = 10'd0;
    wire [3:0] vdp_border_r_w = 4'd0, vdp_border_g_w = 4'd0, vdp_border_b_w = 4'd0;
    wire vdp_border_active_w = 1'b0;
    wire scanlines_w = sw_scanlines_w;
    assign rgb_r_w = apple_fb_r_w;
    assign rgb_g_w = apple_fb_g_w;
    assign rgb_b_w = apple_fb_b_w;

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
    assign ssc_uart_rx = 1'b1;   // no UART pins on this revision

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


    wire signed [15:0] core_audio_l_w;
    wire signed [15:0] core_audio_r_w;
    // Saturating mix (hdl/sound/core_audio_mix.sv): Mockingboard gain is a
    // live select (shift 3 + gain; power-up 2 = << 5 since 2026-11-17, it was
    // quiet beside the DOC), sum clamped.
    core_audio_mix i_audio_mix_l (.sg_i(sg_audio_l), .ssp_i(ssp_audio_w), .mb_i(mb_audio_l), .mb_gain_i(aud_ctl_w[3:2]), .spk_i(speaker_audio_w), .out_o(core_audio_l_w));
    core_audio_mix i_audio_mix_r (.sg_i(sg_audio_r), .ssp_i(ssp_audio_w), .mb_i(mb_audio_r), .mb_gain_i(aud_ctl_w[3:2]), .spk_i(speaker_audio_w), .out_o(core_audio_r_w));

    // -----------------------------------------------------------------
    // Audio output filter (clk_logic domain)
    // -----------------------------------------------------------------
    // The a2n20 tops run audio_out (Sorgelig's 3-tap IIR low-pass with a DC
    // blocker at the sample rate) between the mix and the output; this top
    // fed the mix straight into the CDC because the IIR's 16x40 and 37x24
    // products did not map onto the GW5A DSP (MULT12X12 / MULT27X36 only,
    // signed operands). hdl/support/iir_filter_gw5a.v is the same filter
    // with every product written as a signed <= 27 x <= 36 piece, bit-exact
    // with the GW2A file (sim/audio_out/run.sh); the project lists it in
    // place of hdl/support/iir_filter.v.
    //
    // It runs here on clk_logic, AHEAD of the CDC, so the band-limiting sees
    // the full-rate sources (the 1-bit speaker, the AY square waves, the DOC
    // at ~26 kHz per oscillator) rather than the 48 kHz capture, where their
    // aliases are already folded in. The DC blocker's sample strobe is
    // 54 MHz / 1125 = 48.000 kHz exactly; the pixel-domain strobe below is
    // the same frequency (every clock here descends from the one 50 MHz
    // oscillator), so the mailbox CDC carries one new word per period.
    //
    // flt_rate: audio_out's accumulator drops its increment on the cycle it
    // fires, so the filter ce runs at clk / (CLK_RATE / (2 flt_rate) + 1),
    // not at 2 flt_rate. The Tang Nano tops (27 MHz, 7,056,000) therefore
    // filter at a 9.268 MHz ce = 4.634 MHz per channel; 5,594,066 at 54 MHz
    // gives the same ce rate and so the same cutoff with the same
    // coefficients (the Tang Nano tuning, unchanged; the bench prints both
    // responses). The ce fires at most every fifth clk54; every register in
    // the IIR is ce-enabled, and a2p25.sdc gives their paths three cycles
    // (set_multicycle_path) for the two cascaded MULT27X36 of a tap update.
    localparam AUDIO_RATE = 48000;
    localparam [31:0] aflt_rate = 5_594_066;
    localparam [39:0] acx  = 4258969;
    localparam  [7:0] acx0 = 3;
    localparam  [7:0] acx1 = 3;
    localparam  [7:0] acx2 = 1;
    localparam [23:0] acy0 = -24'd6216759;
    localparam [23:0] acy1 =  24'd6143386;
    localparam [23:0] acy2 = -24'd2023767;
    localparam int AUD_STROBE_DIV = CLOCK_SPEED_HZ / AUDIO_RATE;   // 1125

    reg [$clog2(AUD_STROBE_DIV)-1:0] aud_strobe_cnt_r = '0;
    reg clk_audio_logic_r = 1'b0;
    always_ff @(posedge clk_logic_w) begin
        clk_audio_logic_r <= 1'b0;
        if (aud_strobe_cnt_r == AUD_STROBE_DIV - 1) begin
            aud_strobe_cnt_r  <= '0;
            clk_audio_logic_r <= 1'b1;
        end else begin
            aud_strobe_cnt_r <= aud_strobe_cnt_r + 1'b1;
        end
    end

    wire [15:0] flt_audio_l_w;
    wire [15:0] flt_audio_r_w;
    audio_out #(
        .CLK_RATE   (CLOCK_SPEED_HZ),
        .AUDIO_RATE (AUDIO_RATE),
        .ENABLE     (ENABLE_FILTER)
    ) i_audio_out (
        .reset     (~device_reset_n_w),
        .clk       (clk_logic_w),
        .flt_rate  (aflt_rate),
        .cx        (acx),
        .cx0       (acx0),
        .cx1       (acx1),
        .cx2       (acx2),
        .cy0       (acy0),
        .cy1       (acy1),
        .cy2       (acy2),
        .is_signed (1'b1),
        .core_l    (core_audio_l_w),
        .core_r    (core_audio_r_w),
        .audio_clk (clk_audio_logic_r),
        .audio_l   (flt_audio_l_w),
        .audio_r   (flt_audio_r_w)
    );

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
    // =====================================================================
    // HyperRAM: hyperram_ctrl (108 MHz CK, 2:1 synchronous with clk_logic)
    // behind hyperram_ports_if, the mem_port_if arbiter with the same client
    // contract and port roles as the a2mega's ddr3_ports. Validated on this
    // board by the a2p25_dp_test_fb bench (0 errors under the FB load).
    // =====================================================================
    reg [2:0] hr_rst_sync_r = 3'b000;
    always @(posedge clk_logic_w)
        hr_rst_sync_r <= {hr_rst_sync_r[1:0], clk_lock_w & device_reset_n_w};
    wire hr_rst_n_w = hr_rst_sync_r[2];
    assign ddr_rst_w = !hr_rst_n_w;

    // The ESP32's "re-init memory" request (a2mega: DDR3 reset) re-runs the
    // HyperRAM input-delay calibration here.
    wire ddr3_reinit_tgl_w;
    reg  hr_reinit_s0, hr_reinit_s1, hr_reinit_s2;
    always @(posedge clk_logic_w) begin
        hr_reinit_s0 <= ddr3_reinit_tgl_w;
        hr_reinit_s1 <= hr_reinit_s0;
        hr_reinit_s2 <= hr_reinit_s1;
    end
    wire hr_recal_w = hr_reinit_s1 ^ hr_reinit_s2;

    wire        hr_ready_w, hr_init_done_w, hr_req_w, hr_we_w, hr_rvalid_w, hr_done_w;
    wire        hr_rd_err_w, hr_cal_ok_w, hr_wbuf_we_w;
    wire [20:0] hr_addr_w;
    wire [4:0]  hr_len_w;
    wire [31:0] hr_wdata_w, hr_wbuf_data_w, hr_rdata_w, hr_rd_timeouts_w;
    wire [3:0]  hr_wbe_w, hr_wbuf_idx_w, hr_wbuf_be_w, hr_arb_state_w;
    wire [NUM_DDR3_PORTS-1:0] hr_pending_w;
    wire [95:0] fb_wide_data_hi_w;

    hyperram_ctrl #(
        .CLK_HZ     (CLOCK_SPEED_HZ),
        .ADDR_WIDTH (21),
        .LATENCY    (6)
    ) i_hr_ctrl (
        .clk (clk_logic_w), .clk_mem (clk_mem_w), .clk_mem_90 (clk_mem_90_w), .clk_cap (clk_mem_w),
        .rst_n (hr_rst_n_w),
        .ready (hr_ready_w), .init_done (hr_init_done_w),
        .req (hr_req_w), .we (hr_we_w), .addr (hr_addr_w), .len (hr_len_w),
        .wdata (hr_wdata_w), .wbe (hr_wbe_w),
        .wbuf_we (hr_wbuf_we_w), .wbuf_idx (hr_wbuf_idx_w), .wbuf_data (hr_wbuf_data_w), .wbuf_be (hr_wbuf_be_w),
        .rvalid (hr_rvalid_w), .rdata (hr_rdata_w), .done (hr_done_w),
        .rd_err (hr_rd_err_w), .xfer_lat2x (),
        .recal (hr_recal_w), .cfg_cr0 (16'd0), .cfg_cr0_write (1'b0), .cr0_active (),
        .dly_force (1'b0), .dly_force_code (8'd0), .dly_code (), .cal_tap (), .cal_map (),
        .cal_ok (hr_cal_ok_w), .rd_arrival (),
        .stat_xfers (), .stat_lat2x (), .stat_rd_timeouts (hr_rd_timeouts_w), .stat_lat_mismatch (),
        .hr_ck (hr_ck), .hr_cs_n (hr_cs_n), .hr_rwds (hr_rwds), .hr_dq (hr_dq)
    );

    // packed tables, port 0 in the LOW field (see hyperram_ports.sv); the
    // 7-port tables are sliced to the ports actually built
    localparam [7*21-1:0] HR_PORT_BASES_7 =
                           {21'd0,               // [6] debug reader (absolute, MEM_PEEK only)
                            FB_WORD_BASE,        // [5] FB read
                            FB_WORD_BASE,        // [4] FB write
                            ENSONIQ_WORD_BASE,   // [3] GLU sound-RAM write
                            SHADOW_WORD_BASE,    // [2] shadow write
                            SHADOW_WORD_BASE,    // [1] shadow read
                            ENSONIQ_WORD_BASE};  // [0] DOC wavetable read
    localparam [7*5-1:0]  HR_PORT_BURSTS_7 = {5'd4, 5'd8, 5'd4, 5'd4, 5'd4, 5'd4, 5'd4};

    hyperram_ports_if #(
        .NUM_PORTS        (NUM_DDR3_PORTS),
        .PORT_BASE_ADDR   (HR_PORT_BASES_7[NUM_DDR3_PORTS*21-1:0]),
        .PORT_BURST_WORDS (HR_PORT_BURSTS_7[NUM_DDR3_PORTS*5-1:0]),
        .WIDE_WR_PORT     (FB_WRITE_PORT)
    ) u_hr_ports (
        .clk (clk_logic_w), .rst_n (hr_rst_n_w),
        .ports (hr_mem_ports),
        .wide_wr_data_hi (fb_wide_data_hi_w),
        .hr_ready (hr_ready_w), .hr_init_done (hr_init_done_w),
        .hr_req (hr_req_w), .hr_we (hr_we_w), .hr_addr (hr_addr_w), .hr_len (hr_len_w),
        .hr_wdata (hr_wdata_w), .hr_wbe (hr_wbe_w),
        .hr_wbuf_we (hr_wbuf_we_w), .hr_wbuf_idx (hr_wbuf_idx_w), .hr_wbuf_data (hr_wbuf_data_w), .hr_wbuf_be (hr_wbuf_be_w),
        .hr_rvalid (hr_rvalid_w), .hr_rdata (hr_rdata_w), .hr_done (hr_done_w),
        .dbg_req_pending (hr_pending_w), .dbg_state (hr_arb_state_w)
    );
    assign init_calib_complete_w = hr_init_done_w;

    // DDR3-era status consumers (overlay, ESP32 debug registers) keep their
    // names; the values are the HyperRAM equivalents.
    wire        pll_lock_w = clk_lock_w;
    wire [7:0]  ddr3_retry_cnt_r = hr_rd_timeouts_w[7:0];   // read timeouts (sticky count)
    wire        ddr3_rst_n_r = hr_rst_n_w;
    wire [1:0]  ddr3_seq_state_r = {hr_cal_ok_w, hr_rd_err_w};
    wire [7:0]  ddr3_dbg_arb_state_w = {3'd0, hr_ready_w, hr_arb_state_w};
    wire [NUM_DDR3_PORTS-1:0] ddr3_dbg_req_pending_w = hr_pending_w;
    wire [NUM_DDR3_PORTS-1:0] ddr3_dbg_resp_ovfl_w = '0;
    wire [31:0] ddr3_dbg_test_result_w = 32'd0;
    wire        ddr3_dbg_test_done_w = hr_init_done_w;

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
        .LINE_BANKS(4),            // 4 BSRAM blocks, not 8 (RESOURCE_AUDIT B3)
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

        .fb_write_port    (hr_mem_ports[FB_WRITE_PORT]),
        .fb_read_port     (hr_mem_ports[FB_READ_PORT]),
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

    // AUDIO_RATE is declared with the filter stage above (48 kHz).
    // 48 kHz strobe from the 148.5 MHz pixel clock via a sign-bit phase
    // accumulator (exact for any ratio; 148.5M/48k = 3093.75 is not an
    // integer, so the old divider+frac scheme no longer applies). The
    // constants are reduced by their GCD (12,000): +4 / -12,375 in 15 bits
    // makes the identical sign-test sequence as +48,000 / -148,500,000 in
    // 29 bits, and the 29-bit carry chain was this core's worst clk_pix
    // path (+0.33 ns, 9 logic levels, 2026-11-15) — same form as the a2mega.
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

    // Audio CDC: clk_logic (54 MHz) -> clk_pixel (148.5 MHz). The two clocks
    // come from different PLLs and the SDC declares them asynchronous, so the
    // old double flop per bit captured mixed words when the sample changed
    // near a pixel-clock edge (Arkanoid pops, 2026-11-16). audio_sample_cdc
    // keeps that raw path, adds a request/acknowledge mailbox, and counts
    // mixed captures; a write to debug-window index 55 (select 0x5F = 55,
    // data 0x4F) sets the control byte: bit 0 selects the mailbox word, bit 1
    // clears the counters (readback 48-55). Not a scratch register: the W5100
    // bridge firmware rewrites scratch1-4 on every poll (found 2026-11-16).
    wire [7:0]  aud_ctl_w;              // driven by esp32_ospi_connector below
    wire [63:0] aud_cdc_dbg_w;
    reg  [15:0] audio_sample_word [1:0];
    // RAW_PATH 0 since 2026-11-18: mailbox only (bit 0 of index 55 is read
    // back but ignored, indices 48-51 read 0); the raw flops and the mixed
    // detector went for logic budget once the filter stage took the core to
    // 83 %. The consumed-stream jump / max-step counters (52-54) stay.
    audio_sample_cdc #(.W(16), .JUMP_THRESH(2048), .RAW_PATH(0)) i_audio_cdc (
        .clk_src    (clk_logic_w),
        .l_src      (flt_audio_l_w),
        .r_src      (flt_audio_r_w),
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

    // DisplayPort over the GW5A-25 hardened D-PHY (raw serializer): 4 lanes
    // RBR, 1080p60, pixel clock 148.5 MHz = 81 MHz symbol clock x 11 / 6.
    // Policies as proven on the a2p25_dp_test_4l bench (10-11).
    wire        dp_clk_sym_w;
    wire [3:0]  dp_tx_running_w, dp_powerup_channel_w;
    wire [79:0] dp_tx_symbols_w;
    wire        dp_hpd_present_w;
    wire [7:0]  dp_underrun_cnt_w;    // pixel FIFO underruns (OSD hex 5)
    dp_transmitter #(
        .LANE_COUNT       (4),
        .LINK_RATE_MBPS   (1620),
        .RGB_LATENCY      (2),
        .FIFO_LINES       (1),       // 512 words (was 11 lines); level swings +-60 at prefill
        .PIXEL_BITS       (16),      // RGB565 through the CDC FIFO: 512 x 65 = 4 blocks, not 6 (B4)
        .PREFILL_WORDS    (256),     // half a line
        .BLIND_SINK       (0),
        .HPD_DISCONNECT_RESETS(1),
        .ENABLE_AFE_ADJUST(0),       // swing/pre-emphasis live in the SN75DP130
        .AFE_APPLY_ON_START(0),
        .ENABLE_PHASE_DONE_GATE(1),
        .GATE_GRACE       (0),
        .GATE_KICK        (0),
        .LATE_REPLY_DRAIN (1),   // converter AUX_DEFER replies carry trailing bytes (10-12)
        .IRQ_SERVICE      (2),
        .POLITE_ATTACH    (1),
        .ERRCNT_READ      (1),
        .LINK_CHECK       (1),
        .LINK_CHECK_CLKS  (27'd19999999),   // 200 ms
        .ECHO_SINK_ADJUST (1),
        .TX_PROBE         (0),
        .H_VISIBLE (1920), .H_TOTAL (2200), .H_SYNC_WIDTH (44), .H_START (192),
        .V_VISIBLE (1080), .V_TOTAL (1125), .V_SYNC_WIDTH (5),  .V_START (41),
        .PIXEL_CLK_MULT   (11),
        .PIXEL_CLK_DIV    (6),
        .PIXEL_PLL_IDIV   (1),
        .PIXEL_PLL_MDIV   (11),
        .PIXEL_PLL_ODIV0  (6),
        .PIXEL_PLL_FCLKIN ("81"),
        .AUDIO_RATE       (AUDIO_RATE),
        .AUDIO_BIT_WIDTH  (16)
    ) i_dp (
        .clk100            (clk100_w),
        .refclk0           (1'b0),
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
        .dp_tx_lane_p      (),
        .dp_tx_lane_n      (),
        .hpd               (dp_hpd),
        .auxch_in          (dp_auxch_in_w),
        .auxch_out         (dp_auxch_out_w),
        .auxch_tri         (dp_auxch_tri_w),
        .link_established  (dp_link_established_w),
        .video_live        (dp_video_live_w),
        .debug (dp_dbg_state_w),
        .debug_rx          (),
        .debug_locks (dp_dbg_locks_w),
        .debug_gate        (),
        .debug_sink (dp_dbg_sink_w),
        .debug_adjust      (),
        .debug_chstate (dp_dbg_chstate_w),
        .debug_aux_err     (dp_dbg_aux_err_w),
        .debug_esi         (),
        .debug_defer (dp_dbg_defer_w),
        .wedge_suspect     (dp_wedge_w),
        .debug_drp_clk     (dp_drp_clk_w),
        .debug_errcnt0     (dp_errcnt0_w),
        .debug_errcnt1     (dp_errcnt1_w),
        .debug_err_detail  (),
        .debug_obs         (),
        .debug_auxif       (),
        .debug_snapshot    (),
        .debug_caps (dp_dbg_caps_w),
        .debug_wdog        (),
        .debug_teardown (dp_dbg_teardown_w),
        .debug_wrusewd     (),
        .debug_afe         (),
        .debug_afe1        (),
        .debug_evt         (),
        .clk_symbol_out    (),
        .serdes_status     (dp_serdes_status_w),
        .hpd_present_out   (dp_hpd_present_w),
        .debug_underrun_cnt(dp_underrun_cnt_w),
        .debug_fifo_level  (),
        .ext_symbol_clk    (dp_clk_sym_w),
        .ext_tx_running    (dp_tx_running_w),
        .ext_tx_symbols    (dp_tx_symbols_w),
        .ext_powerup_channel(dp_powerup_channel_w),
        .drp_dbg_idx       (5'd0),
        .drp_dbg_data      (),
        .drp_dbg_addr      (),
        .drp_dbg_done      ()
    );
    transceiver_bank_dphy #(
        .REVERSE_LANES (1),          // DP lane n = D-PHY lane 3-n (netlist, verified)
        .LANE_MAP      (8'h00),
        .POL_INV       (4'h0),
        .PROBE         (0)
    ) i_phy (
        .mgmt_clk        (clk100_w),
        .clk_dphy_ref    (clk54_pll_w),
        .clk_md          (clk),
        .reset           (ddr_rst_w),
        .powerup_channel (dp_powerup_channel_w),
        .tx_running      (dp_tx_running_w),
        .tx_symbol_clk   (dp_clk_sym_w),
        .tx_symbols      (dp_tx_symbols_w),
        .status          (),
        .tx_clk_out      (),
        .dphy_ck_p       (dphy_ck_p),
        .dphy_ck_n       (dphy_ck_n),
        .dphy_d_p        (dphy_d_p),
        .dphy_d_n        (dphy_d_n)
    );

    // Register framebuffer RGB output for the DP pull interface
    always @(posedge clk_pixel_w) begin
        dp_rgb_r <= fb_rgb_w;
    end

    // DDR3 calibration status on LED[1]; DP bring-up ladder on LED[2:3]

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
    // No USB host on this board: the two USB debug registers carry the IIgs
    // detector status and the raw bank-qualifier pins instead.
    wire [7:0]  gs_status_w;
    wire [7:0]  dbg_usb_line_w     = gs_status_w;
    // 0x7B: {M2SEL seen low, M2B0 seen high, M2B0 seen low, /RES seen low,
    //        $C029 READ seen, $C029 WRITE seen, M2SEL now, M2B0 now} — the
    //        "seen" bits are sticky since configuration (M2B0 is a ~140 ns
    //        pulse: a live sample alone says little)
    reg  [7:0]  dbg_usb_pc_w       = 8'd0;
    reg  [1:0]  pin_m2sel_s = 2'b11, pin_m2b0_s = 2'b00, pin_res_s = 2'b11;
    reg         m2sel_low_seen_r = 1'b0, m2b0_high_seen_r = 1'b0, m2b0_low_seen_r = 1'b0, res_low_seen_r = 1'b0;
    reg         c029_rd_seen_r = 1'b0, c029_wr_seen_r = 1'b0;
    always @(posedge clk_logic_w) begin
        pin_m2sel_s <= {pin_m2sel_s[0], a2_m2sel_n};
        pin_m2b0_s  <= {pin_m2b0_s[0],  a2_mb20};
        pin_res_s   <= {pin_res_s[0],   a2_reset_n};
        if (!pin_m2sel_s[1]) m2sel_low_seen_r <= 1'b1;
        if (pin_m2b0_s[1])   m2b0_high_seen_r <= 1'b1;
        if (!pin_m2b0_s[1])  m2b0_low_seen_r  <= 1'b1;
        if (!pin_res_s[1])   res_low_seen_r   <= 1'b1;
        if (a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC029)) begin
            if (a2bus_if.rw_n) c029_rd_seen_r <= 1'b1; else c029_wr_seen_r <= 1'b1;
        end
        dbg_usb_pc_w <= {m2sel_low_seen_r, m2b0_high_seen_r, m2b0_low_seen_r, res_low_seen_r,
                         c029_rd_seen_r, c029_wr_seen_r, pin_m2sel_s[1], pin_m2b0_s[1]};
    end
    // No USB host on this board: the USB debug registers carry DOC/GLU
    // activity instead — flags = oscillator enables (GLU writes landed),
    // cnt_start = wavetable fetches in the last frame, cnt_rdy = sound-RAM
    // write-queue drops (sticky).
    // DP link-state debug taps (10-12, USB-C->HDMI adapter investigation)
    wire [7:0]  dp_dbg_state_w;      // transmitter training-state byte
    wire [23:0] dp_dbg_chstate_w;    // raw DPCD {0x204, 0x203, 0x202}
    wire [7:0]  dp_dbg_caps_w;       // sink capability profile
    wire [7:0]  dp_dbg_sink_w;       // DPCD 0x205 SINK_STATUS
    wire [6:0]  dp_dbg_defer_w;      // {edid_giveup, defer_cnt}
    wire [15:0] dp_dbg_teardown_w;   // {first_mask, fail_mask, gate_fail_sat, timeout_sat}
    wire [3:0]  dp_dbg_locks_w;      // {clock, equ, symbol, align}_locked
    wire [23:0] dp_dbg_aux_err_w;    // {short, nack, other, obs, kicks, irq_services}
    // DP link state on the spare USB debug regs (the DOC counters that
    // lived here are verified; swap back if the DOC needs watching):
    //   0x1C/0x1D/0x1E = DPCD 0x202/0x203/0x204   0x1F = training state
    //   0x7C = sink caps profile   0x7D = SINK_STATUS (0x205)
    //   0x20 = {edid_giveup, defer_cnt[6:0]}      0x21 = teardown[7:0]
    //   0x22 = {locks[3:0], aux_err[7:4] (kicks)}
    wire [47:0] usb_dbg_desc_sync1 = {dp_dbg_sink_w, dp_dbg_caps_w, dp_dbg_state_w, dp_dbg_chstate_w};
    wire [7:0]  usb_dbg_flags_sync1 = {1'b0, dp_dbg_defer_w};
    wire [7:0]  usb_cnt_start_sync1 = dp_dbg_teardown_w[7:0];
    wire [7:0]  usb_cnt_rdy_sync1   = {dp_dbg_locks_w, dp_dbg_aux_err_w[7:4]};   // [7:4] = 'kicks' class (re-roll nudge 10-12)


    // DDR3 sequencer telemetry (clk 50 MHz -> clk_logic; quasi-static)
    reg [7:0] ddr3_retry_sync0, ddr3_retry_sync1;
    reg [4:0] ddr3_seq_sync0, ddr3_seq_sync1;
    always @(posedge clk_logic_w) begin
        ddr3_retry_sync0 <= ddr3_retry_cnt_r;  ddr3_retry_sync1 <= ddr3_retry_sync0;
        ddr3_seq_sync0   <= {ddr3_rst_n_r, pll_lock_w, init_calib_complete_w, ddr3_seq_state_r};
        ddr3_seq_sync1   <= ddr3_seq_sync0;
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
        dbg_hex_sync0[1] <= 8'(ddr3_dbg_req_pending_w);
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
        dbg_hex_sync0[5] <= dp_underrun_cnt_w;   // (a2mega: fb_dbg_rd_fifo_drop_w)
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

    // DebugOverlay off on the GW5A-25 first fit: CLS was 99.4% and its
    // compare cone was the worst setup path (-0.34 ns). The ESP32 OSD text
    // overlay and the debug registers over the OPI link remain.
    DebugOverlay #(
        .VERSION(`BUILD_DATETIME),
        .ENABLE(`A2_INSTR_DEBUG_OVERLAY),
        .X_OFFSET(16),
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

    // The composite (scanline_dim + ESP32 OSD text + DebugOverlay pass-through)
    // is always selected; DebugOverlay's ENABLE=0 makes it transparent.
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
        dbg_resp_ovfl_sync0 <= 8'(ddr3_dbg_resp_ovfl_w);
        dbg_resp_ovfl_sync1 <= dbg_resp_ovfl_sync0;
    end

    // Octal SPI connector instance
    esp32_ospi_connector #(
        .VERSION_STR(`BUILD_DATETIME),
        .USE_SYNC(1),
        .USE_CRC(0),
        .IDLE_TO_CYC(5_400_000),  // ~100ms at 54MHz
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .EVT_LOG(`A2_INSTR_EVENT_LOG),  // a2p25_profile.vh
        .TEST_MEM(`A2_INSTR_TEST_MEM)   // a2p25_profile.vh
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
        // a2p25: viddbg 0x71 "C029 writes" = DOC fetch timeouts (wraps),
        //        viddbg 0x72 "last"        = DOC max fetch latency (clk_logic cycles, 18.5 ns)
        .dbg_c029_cnt_i(doc_dbg_stale_fetch_w),
        .dbg_c029_last_i(doc_dbg_prime_miss_w),
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
        .dbg_doc_reqf_i(doc_dbg_req_frame_r),
        .dbg_doc_missf_i(doc_dbg_miss_frame_r),
        .dbg_doc_tof_i(doc_dbg_to_frame_r),
        .dbg_glu_drops_i(glu_wq_drops_w),
        .dbg_doc_fdrop_i(doc_dbg_fetch_drop_w),
        .dbg_aud_i(aud_cdc_dbg_w),
        .aud_ctl_o(aud_ctl_w),
        // a2mega-only debug sources, tied off (2026-10-22 merge): DP SERDES /
        // link readback and the IIgs CPU-socket window. The a2p25 could
        // feed dbg_dp_caps_i from dp_transmitter's debug_sink_caps (census
        // second gate) the way the a2mega top does — follow-up.
        .dbg_dp_caps_i(16'd0),
        .dbg_dp_status_i(8'd0),
        .dbg_dp_serdes_i(8'd0),
        .gs_ctrl_o(),
        .gs_out_extra_o(),
        .gs_hold_tap_o(),
        .gs_trace_idx_o(),
        .gs_trig_addr_o(),
        .gs_trace_i(48'd0),
        .gs_tele_i(160'd0),
        .a2_alive_i(~sleep_w),       // slot PHI1 running (same as the a2mega)
        .gs_res_n_i(1'b1),           // no CPU socket on the a2p25
        .ddr3_reinit_tgl_o(ddr3_reinit_tgl_w),

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