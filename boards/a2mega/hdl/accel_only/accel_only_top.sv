// A2MEGA 1.0a3 / GW5AST-138B - accelerator-only build
//
// (c) 2026 Ed Anuff <ed@a2fpga.com>
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
// Description
// -----------
// The card as a CPU accelerator and nothing else (docs/
// gs_socket_s7_fast_core_exploration.md 2d, "Testing the split on today's
// boards"): the S7 accelerator domain (hdl/twgs/gs_accel.sv) on the GS-socket
// pins, and the ESP32 connector for control and telemetry.  No framebuffer,
// no DDR3, no DisplayPort, no slot cards, no slot ROM or I/O decode, no OSD:
// video, audio, disks and peripherals are another card's (an a2p25 in
// another slot).
//
// Slot side: PASSIVE.  The level shifters are enabled as inputs, as in the
// full build; this top never turns the data bus round, never drives an
// address, never asserts /IRQ, /INH, /DMA or /RDY, and passes the interrupt
// and DMA daisy chains straight through.  The one slot line it can drive is
// /RESET, through the ESP32's reset hold, exactly as the full build does
// (the firmware's storage-ready release and the S6 arm sequence depend on
// it).  The slot inputs it uses are /RESET and PHI1 (machine alive).
//
// The DDR3 and DisplayPort balls are not ports of this top: they are left
// to the bitstream's unused-pin default, as in the DP test builds.
//
// Clocks: the 50 MHz crystal; clk_logic (54 MHz, the board PLL, as in the
// full build) for the connector; clk_gs (110 MHz, gowin_gs_pll - the S6
// socket PLL, unchanged) for the accelerator: 55 MHz steps.
//
// Control, through the connector's GS window (the registers the S6 firmware
// already has: `gs`, `gs set <idx> <val>`, `gs trace`):
//
//   CTRL (0)     bit 0 arm, bit 2 listen, bit 7 clear - as S6; the firmware's
//                auto-arm drives it.  The other bits do nothing here.
//   2            PHY address-delay sweep, as S6.
//   29, 30, 31   (S6: trace trigger address) the accelerator's requests.
//                31 must hold A5 or 29 is ignored (`gs trig` writes FF FF FF).
//                29: bit 0 FAST     local steps at 55 MHz (needs bit 1)
//                    bit 1 CARDMEM  the card's memory is the memory of record;
//                                   in native mode its byte goes to the core and
//                                   is compared with the socket's (verify count)
//                    bit 2 CXROM    internal $C100-$CFFF firmware from the image
//                    bit 3 COPY     0 -> 1: read the ROM image through the socket
//                                   (core held about 46 ms)
//                Bits 0-2 take effect only once an image has been copied.
//                With 29 = 00 the card is S6 on the new core: every step a
//                socket cycle, every byte from the socket.
//
// Telemetry: the S6 window, with two fields carrying something else -
//   hold mismatches = verify count; hold samples = {mode, 8'h5A}
//   (mode: 7 ROM image valid, 6 copy busy, 5 core held, 4 fast, 3 card
//   memory, 2 cxrom).  `gs trace` shows 64 words, index = line number:
//   see gs_accel.sv tele_word_o (bank:addr data = one 32-bit word).
//
`include "../datetime.svh"
module top (
    input clk,
    input rst,

    // slot (inputs only, except the reset hold)
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
    output a2_res_out_n,
    output a2_int_out_n,
    input  a2_int_in_n,
    output a2_dma_out_n,
    input  a2_dma_in_n,
    input  a2_phi1,
    input  a2_q3,
    input  a2_7M,
    output a2_a_dir,
    input  [15:0] a2_a,
    output a2_d_dir,
    inout  [7:0] a2_d,

    output [3:0] led,
    input  button,
    input  [3:0] dip_switches_n,
    output uart_tx,
    input  uart_rx,

    // ESP32 Octal SPI interface
    input         esp_sclk,
    inout  [7:0]  esp_data,

    // DDR3: the card's copy of the expansion banks
    output [14:0] ddr_addr,
    output [2:0]  ddr_bank,
    output        ddr_cs,
    output        ddr_ras,
    output        ddr_cas,
    output        ddr_we,
    output        ddr_ck,
    output        ddr_ck_n,
    output        ddr_cke,
    output        ddr_odt,
    output        ddr_reset_n,
    output [1:0]  ddr_dm,
    inout  [15:0] ddr_dq,
    inout  [1:0]  ddr_dqs,
    inout  [1:0]  ddr_dqs_n,

    // IIgs CPU socket
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
);
    localparam int CLOCK_SPEED_HZ = 54_000_000;

    // ---- clocks: clk_logic from the board PLL (the full build's recipe), clk_gs
    // from the socket PLL
    // (board_plls: the full build's block - the DDR3's clock chain exactly as there)
    wire clk_logic_w, clk_lock_w;
    wire memory_clk_w, ddr3_pll_lock_w, pll_stop_w;
    board_plls u_board_plls (
        .clk(clk), .pll_stop(pll_stop_w),
        .clk_pixel(), .clk_hdmi(), .clk_logic(clk_logic_w), .clk_lock(clk_lock_w),
        .clk_usb(), .usb_pll_lock(),
        .memory_clk(memory_clk_w), .ddr3_pll_lock(ddr3_pll_lock_w)
    );
    wire clk_gs_w, gs_pll_lock_w;
`ifdef ACC_CLK_100
    gowin_acc_pll #(.MDIV(20)) i_gs_pll (.lock(gs_pll_lock_w), .clkout(clk_gs_w), .clkin(clk));   // 100 MHz
`elsif ACC_CLK_105
    gowin_acc_pll i_gs_pll (.lock(gs_pll_lock_w), .clkout(clk_gs_w), .clkin(clk));   // 105 MHz
`else
    gowin_gs_pll i_gs_pll (.lock(gs_pll_lock_w), .clkout(clk_gs_w), .clkin(clk));    // 110 MHz
`endif

    // ---- expansion memory: the DDR3, alone on its arbiter (the full build's
    // controller, reset sequencer and clock crossing; port 1 is unused)
    wire        init_calib_complete_w, ddr_rst_w, clk_x1_w;
    localparam DDR3_SETTLE_CYC   = 50_000;     // 1 ms @ 50 MHz
    localparam DDR3_CALIB_CYC    = 5_000_000;  // 100 ms watchdog
    localparam DDR3_RSTPULSE_CYC = 5_000;      // 100 us reset pulse
    reg        ddr3_rst_n_r = 1'b0;
    reg [1:0]  ddr3_seq_state_r = 2'd0;        // 0 wait for lock, 1 settle, 2 watch, 3 pulse
    reg [22:0] ddr3_seq_timer_r = '0;
    reg [7:0]  ddr3_retry_cnt_r = '0;          // saturating; nonzero = the watchdog fired
    reg        calib_s0 = 1'b0, calib_s1 = 1'b0;
    always @(posedge clk) begin
        calib_s0 <= init_calib_complete_w; calib_s1 <= calib_s0;
        if (!ddr3_pll_lock_w) begin
            ddr3_rst_n_r <= 1'b0; ddr3_seq_state_r <= 2'd0; ddr3_seq_timer_r <= '0;
        end else begin
            case (ddr3_seq_state_r)
                2'd0: begin ddr3_seq_timer_r <= '0; ddr3_seq_state_r <= 2'd1; end
                2'd1: begin
                    ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                    if (ddr3_seq_timer_r >= DDR3_SETTLE_CYC) begin
                        ddr3_rst_n_r <= 1'b1; ddr3_seq_timer_r <= '0; ddr3_seq_state_r <= 2'd2;
                    end
                end
                2'd2: begin
                    if (!calib_s1 && ddr3_seq_timer_r >= DDR3_CALIB_CYC) begin
                        ddr3_rst_n_r <= 1'b0; ddr3_seq_timer_r <= '0;
                        if (!(&ddr3_retry_cnt_r)) ddr3_retry_cnt_r <= ddr3_retry_cnt_r + 1'b1;
                        ddr3_seq_state_r <= 2'd3;
                    end else if (calib_s1) ddr3_seq_timer_r <= '0;
                    else                   ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                end
                2'd3: begin
                    ddr3_seq_timer_r <= ddr3_seq_timer_r + 1'b1;
                    if (ddr3_seq_timer_r >= DDR3_RSTPULSE_CYC) begin ddr3_seq_timer_r <= '0; ddr3_seq_state_r <= 2'd1; end
                end
            endcase
        end
    end

    wire         ddr3_cmd_ready_w, ddr3_cmd_en_w, ddr3_wr_data_rdy_w, ddr3_wr_data_en_w, ddr3_wr_data_end_w;
    wire         ddr3_rd_data_valid_w, ddr3_rd_data_end_w;
    wire [2:0]   ddr3_cmd_w;
    wire [28:0]  ddr3_addr_w;
    wire [127:0] ddr3_wr_data_w, ddr3_rd_data_w;
    wire [15:0]  ddr3_wr_data_mask_w;
    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk(memory_clk_w), .pll_stop(pll_stop_w), .clk(clk), .rst_n(ddr3_rst_n_r),
        .cmd_ready(ddr3_cmd_ready_w), .cmd(ddr3_cmd_w), .cmd_en(ddr3_cmd_en_w), .addr(ddr3_addr_w),
        .wr_data_rdy(ddr3_wr_data_rdy_w), .wr_data(ddr3_wr_data_w), .wr_data_en(ddr3_wr_data_en_w),
        .wr_data_end(ddr3_wr_data_end_w), .wr_data_mask(ddr3_wr_data_mask_w),
        .rd_data(ddr3_rd_data_w), .rd_data_valid(ddr3_rd_data_valid_w), .rd_data_end(ddr3_rd_data_end_w),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(),
        .init_calib_complete(init_calib_complete_w), .clk_out(clk_x1_w), .pll_lock(ddr3_pll_lock_w),
        .burst(1'b1), .ddr_rst(ddr_rst_w),
        .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank), .O_ddr_cs_n(ddr_cs), .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we), .O_ddr_clk(ddr_ck), .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke), .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs), .IO_ddr_dqs_n(ddr_dqs_n)
    );

    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) ddr3_mem_ports[0:1]();
    ddr3_ports #(.NUM_PORTS(2), .DDR_ADDR_WIDTH(29), .PORT_BASE_ADDR('{21'h000000, 21'h000000})) u_ddr3_ports (
        .clk_client(clk_gs_w), .clk_ddr(clk_x1_w), .rst(ddr_rst_w), .init_complete(init_calib_complete_w),
        .ports(ddr3_mem_ports), .wide_wr_data_hi(96'd0),
        .cmd_ready(ddr3_cmd_ready_w), .cmd(ddr3_cmd_w), .cmd_en(ddr3_cmd_en_w), .addr(ddr3_addr_w),
        .wr_data_rdy(ddr3_wr_data_rdy_w), .wr_data(ddr3_wr_data_w), .wr_data_en(ddr3_wr_data_en_w),
        .wr_data_end(ddr3_wr_data_end_w), .wr_data_mask(ddr3_wr_data_mask_w),
        .rd_data_valid(ddr3_rd_data_valid_w), .rd_data(ddr3_rd_data_w), .rd_data_end(ddr3_rd_data_end_w),
        .dbg_req_pending(), .dbg_arb_state(), .dbg_resp_overflow(), .dbg_test_result(), .dbg_test_done()
    );
    assign ddr3_mem_ports[1].rd = 1'b0; assign ddr3_mem_ports[1].wr = 1'b0; assign ddr3_mem_ports[1].addr = '0;
    assign ddr3_mem_ports[1].data = '0; assign ddr3_mem_ports[1].byte_en = '0; assign ddr3_mem_ports[1].burst = 1'b0;

    // (its status for the firmware's register window: quasi-static, two flops into clk_logic)
    reg [7:0] ddr3_retry_l0 = '0, ddr3_retry_l1 = '0;
    reg [4:0] ddr3_seq_l0 = '0, ddr3_seq_l1 = '0;
    always @(posedge clk_logic_w) begin
        ddr3_retry_l0 <= ddr3_retry_cnt_r; ddr3_retry_l1 <= ddr3_retry_l0;
        ddr3_seq_l0 <= {ddr3_rst_n_r, ddr3_pll_lock_w, calib_s1, ddr3_seq_state_r}; ddr3_seq_l1 <= ddr3_seq_l0;
    end


    // ---- power-on reset (as the full build)
    localparam RESET_CYCLES = 100;
    reg rstn_r = 1'b0;
    reg [$clog2(RESET_CYCLES+1)-1:0] reset_counter_r = '0;
    always @(posedge clk_logic_w) begin
        if (reset_counter_r == RESET_CYCLES) rstn_r <= 1'b1;
        else                                 reset_counter_r <= reset_counter_r + 1'b1;
    end
    wire device_reset_n_w = rstn_r;
    wire system_reset_n_w = device_reset_n_w & a2_reset_n;

    // ---- slot side: shifters on, everything an input
    assign a2_bus_oe = 1'b0;        // level shifters enabled (active low), as the full build
    assign a2_a_dir  = 1'b0;        // address: bus -> FPGA, always
    assign a2_d_dir  = 1'b0;        // data: bus -> FPGA, always
    assign a2_irq_n  = 1'bz;        // never asserted
    wire [7:0] a2_d_buf_w;
    IOBUF a2_d_iobuf[7:0] (.O(a2_d_buf_w), .IO(a2_d), .I(8'h00), .OEN(1'b1));

    a2bus_if a2bus_if ();
    a2bus_control_if a2bus_control_if ();
    wire sleep_w;
    apple_bus #(.GS(0), .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ), .ENABLE_DENOISE(0)) apple_bus (
        .clk_logic_i(clk_logic_w), .clk_pixel_i(clk_logic_w),
        .system_reset_n_i(system_reset_n_w), .device_reset_n_i(device_reset_n_w),
        .a2_phi1_i(a2_phi1), .a2_q3_i(a2_q3), .a2_7M_i(a2_7M),
        .sw_gs_i(!dip_switches_n[3]), .gs_status_o(),
        .a2bus_if(a2bus_if),
        .a2_a_i(a2_a), .a2_d_i(a2_d_buf_w), .a2_rw_n_i(a2_rw_n),
        .a2_inh_n(a2_inh_n), .a2_rdy_n(a2_rdy_n), .a2_dma_n(a2_dma_n), .a2_nmi_n(a2_nmi_n),
        .a2_reset_n(a2_reset_n), .a2_mb20(a2_mb20), .a2_sync_n(a2_sync_n), .a2_m2sel_n(a2_m2sel_n),
        .a2_res_out_n(a2_res_out_n),            // the ESP32's reset hold, as the full build
        .a2_int_out_n(a2_int_out_n), .a2_int_in_n(a2_int_in_n),     // daisy chains straight through
        .a2_dma_out_n(a2_dma_out_n), .a2_dma_in_n(a2_dma_in_n),
        .irq_n_i(1'b1),
        .reset_hold_i(a2bus_control_if.reset_hold),
        .sleep_o(sleep_w)
    );

    // ---- heartbeat
    reg led_r = 1'b0;
    reg [25:0] led_counter_r = 26'd0;
    always @(posedge clk_logic_w) begin
        if (led_counter_r == 26'd09_999_999) begin led_counter_r <= 0; led_r <= ~led_r; end
        else led_counter_r <= led_counter_r + 1'b1;
    end
    assign uart_tx = 1'b1;

    // ---- ESP32 connector: the control plane.  Everything it serves in the full build
    // that is not here is tied off: no slot cards, no volumes, no video, no DDR3.
    wire [7:0] esp_data_i, esp_data_o;
    wire       esp_data_oe;
    IOBUF esp_data_iobuf[7:0] (.O(esp_data_i), .IO(esp_data), .I(esp_data_o), .OEN(!esp_data_oe));

    slotmaker_config_if slotmaker_config_if ();
    assign slotmaker_config_if.card_o = 8'h00;
    f18a_gpu_if esp_f18a_gpu_if ();
    assign esp_f18a_gpu_if.trigger = 1'b0;
    assign esp_f18a_gpu_if.pause   = 1'b0;
    assign esp_f18a_gpu_if.load_pc = 16'h0;
    assign esp_f18a_gpu_if.vdin = 8'h0;
    assign esp_f18a_gpu_if.pdin = 12'h0;
    assign esp_f18a_gpu_if.rdin = 8'h0;
    assign esp_f18a_gpu_if.scanline = 8'h0;
    assign esp_f18a_gpu_if.blank = 1'b0;
    assign esp_f18a_gpu_if.bmlba = 8'h0;
    assign esp_f18a_gpu_if.bml_w = 8'h0;
    assign esp_f18a_gpu_if.pgba = 1'b0;
    video_control_if esp_video_control_if ();
    drive_volume_if volumes[2] ();
    drive_volume_if hdd_volumes[2] ();
    for (genvar v = 0; v < 2; v++) begin : g_vol
        assign volumes[v].active = 1'b0;  assign volumes[v].lba = 32'd0;  assign volumes[v].blk_cnt = 6'd0;
        assign volumes[v].rd = 1'b0;      assign volumes[v].wr = 1'b0;
        assign hdd_volumes[v].active = 1'b0;  assign hdd_volumes[v].lba = 32'd0;  assign hdd_volumes[v].blk_cnt = 6'd0;
        assign hdd_volumes[v].rd = 1'b0;      assign hdd_volumes[v].wr = 1'b0;
    end
    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) disk_ram_if ();
    mem_port_if #(.PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)) hdd_ram_if ();
    assign disk_ram_if.addr = '0;  assign disk_ram_if.data = '0;  assign disk_ram_if.byte_en = '0;
    assign disk_ram_if.wr = 1'b0;  assign disk_ram_if.rd = 1'b0;  assign disk_ram_if.burst = 1'b0;
    assign hdd_ram_if.addr = '0;   assign hdd_ram_if.data = '0;   assign hdd_ram_if.byte_en = '0;
    assign hdd_ram_if.wr = 1'b0;   assign hdd_ram_if.rd = 1'b0;   assign hdd_ram_if.burst = 1'b0;

    wire [7:0]   gs_ctrl_w;        // {clear,0,0,0,0,listen,0,arm}
    wire [3:0]   gs_out_extra_w;
    wire [159:0] gs_tele_w;
    wire [5:0]   gs_trace_idx_w;   // here: index of the telemetry word
    wire [23:0]  gs_trig_addr_w;   // here: the accelerator's requests
    wire [47:0]  gs_trace_w;

    esp32_ospi_connector #(
        .VERSION_STR(`BUILD_DATETIME),
        .USE_SYNC(1),
        .USE_CRC(0),
        .IDLE_TO_CYC(5_400_000),
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .EVT_LOG(1)                       // the socket bring-up event log, as the 138B full build
    ) esp32_ospi (
        .clk(clk_logic_w), .rst_n(device_reset_n_w),
        .sclk(esp_sclk), .data_i(esp_data_i), .data_o(esp_data_o), .data_oe(esp_data_oe),
        .slotmaker_config_if(slotmaker_config_if),
        .f18a_gpu_if(esp_f18a_gpu_if),
        .video_control_if(esp_video_control_if),
        .volumes(volumes), .hdd_volumes(hdd_volumes),
        .a2bus_control_if(a2bus_control_if),
        .disk_ram_if(disk_ram_if), .hdd_ram_if(hdd_ram_if),
        .ddr3_ready_i(1'b1),              // (the firmware waits for no DDR3 here; card memory does: exp_ready_i)
        .a2_reset_n_i(a2_reset_n), .a2_alive_i(~sleep_w), .gs_res_n_i(gs_res_n),
        .storage_settled_o(),
        .pad_typ_i(2'd0), .pad_connerr_i(1'b0), .pad_report_cnt_i(4'd0),
        .pad_btns0_i(8'h00), .pad_btns1_i(8'h00), .key_mod_i(8'h00), .key0_i(8'h00), .key1_i(8'h00),
        .dbg_video_ss_i(8'h00), .dbg_c029_cnt_i(8'h00), .dbg_c029_last_i(8'h00), .dbg_vgc_hsync_i(8'h00),
        .dbg_shadow_drop_i(8'h00), .dbg_fb_flags_i(8'h00), .dbg_resp_ovfl_i(8'h00), .dbg_shadow_rd_i(8'h00),
        .dbg_vgc_starved_i(8'h00), .dbg_usb_line_i(8'h00), .dbg_usb_pc_i(8'h00), .dbg_usb_desc_i(48'h0),
        .dbg_usb_flags_i(8'h00), .dbg_usb_cnt_start_i(8'h00), .dbg_usb_cnt_rdy_i(8'h00),
        .dbg_ddr3_retry_i(ddr3_retry_l1), .dbg_ddr3_seq_i({3'b0, ddr3_seq_l1}),
        .dbg_dp_caps_i(16'h0), .dbg_dp_status_i(8'h00), .dbg_dp_serdes_i(8'h00),
        .dbg_doc_reqf_i(16'h0), .dbg_doc_missf_i(16'h0), .dbg_doc_tof_i(16'h0),
        .ddr3_reinit_tgl_o(),
        .gs_ctrl_o(gs_ctrl_w), .gs_out_extra_o(gs_out_extra_w), .gs_hold_tap_o(),
        .gs_tele_i(gs_tele_w), .gs_trace_idx_o(gs_trace_idx_w), .gs_trig_addr_o(gs_trig_addr_w),
        .gs_trace_i(gs_trace_w),
        .dbg_mem_addr_o(), .dbg_mem_go_o(), .dbg_mem_busy_i(1'b0), .dbg_mem_data_i(32'h0),
        .w5100_host_wr(), .w5100_host_addr(), .w5100_host_wdata(), .w5100_host_rdata(8'h00),
        .w5100_cmd_pending(4'h0), .w5100_cmd_clr(),
        .scratch_o(), .mcu_ready_o(),
        .osd_clk_i(clk_logic_w), .osd_addr_i(11'd0), .osd_data_o()
    );

    // ---- control: connector (clk_logic) -> accelerator domain, quasi-static, two flops
    reg [7:0]  gs_ctrl_s0, gs_ctrl_s1;
    reg [3:0]  gs_oe_s0, gs_oe_s1;
    reg [23:0] gs_rq_s0, gs_rq_s1;
    reg [5:0]  gs_ti_s0, gs_ti_s1;
    always @(posedge clk_gs_w) begin
        gs_ctrl_s0 <= gs_ctrl_w;      gs_ctrl_s1 <= gs_ctrl_s0;
        gs_oe_s0   <= gs_out_extra_w; gs_oe_s1   <= gs_oe_s0;
        gs_rq_s0   <= gs_trig_addr_w; gs_rq_s1   <= gs_rq_s0;
        gs_ti_s0   <= gs_trace_idx_w; gs_ti_s1   <= gs_ti_s0;
    end
    // (a request counts only under the key: `gs trig` writes FF FF FF there)
    wire rq_key_w = (gs_rq_s1[23:16] == 8'hA5);

    // ---- the accelerator
    wire [7:0]  gs_d_o_w;
    wire        gs_d_oe_w;
    assign gs_d = gs_d_oe_w ? gs_d_o_w : 8'bz;
    wire [7:0]  acc_status_w, acc_mode_w;
    wire [31:0] acc_cycle_w, acc_word_w;
    wire [15:0] acc_stall_w, acc_be_w, acc_per_w, acc_high_w, acc_verify_w;
    wire [23:0] acc_last_w;

    // gs_accel's port on the arbiter's 32-bit words: a request is taken in the clk
    // the port is available.  A write is one byte of a word.  A read is of the
    // address's 16-byte line (ACC_LINE: gs_accel's NEAR_LINE) - the arbiter's burst
    // read, which is one read of the DDR3 and comes back as its four words in order;
    // the line is handed over with the fourth.  (Reads come back in the order they
    // were taken, each with all its beats, so the beat count needs no restart.)
    // Without ACC_LINE a read is of one word, of which gs_accel is given the byte
    // it asked for: its lane is remembered until the word comes back.
`ifdef ACC_BYTE_CACHE
    localparam bit ACC_LINE = 1'b0;
`else
    localparam bit ACC_LINE = 1'b1;
`endif
    wire        xm_req_w, xm_we_w;
    wire [22:0] xm_addr_w;
    wire [7:0]  xm_wdata_w;
    wire        xm_take_w = xm_req_w & ddr3_mem_ports[0].available;
    wire        xm_line_w = ACC_LINE & ~xm_we_w;
    assign ddr3_mem_ports[0].rd      = xm_take_w & ~xm_we_w;
    assign ddr3_mem_ports[0].wr      = xm_take_w &  xm_we_w;
    assign ddr3_mem_ports[0].addr    = xm_line_w ? {xm_addr_w[22:4], 2'b00} : xm_addr_w[22:2];
    assign ddr3_mem_ports[0].data    = {4{xm_wdata_w}};
    assign ddr3_mem_ports[0].byte_en = 4'b0001 << xm_addr_w[1:0];
    assign ddr3_mem_ports[0].burst   = xm_line_w;
    wire                           xm_rvalid_w;
    wire [(ACC_LINE ? 128 : 8)-1:0] xm_rdata_w;
    if (ACC_LINE) begin : g_xline
        reg [1:0]   beat_r = '0;
        reg [95:0]  acc_r;
        reg [127:0] line_r;
        reg         rv_r = 1'b0;
        always @(posedge clk_gs_w) begin
            rv_r <= 1'b0;
            if (ddr3_mem_ports[0].ready) begin
                beat_r <= beat_r + 1'b1;
                if (beat_r == 2'd3) begin line_r <= {ddr3_mem_ports[0].q, acc_r}; rv_r <= 1'b1; end
                else                acc_r[32 * beat_r +: 32] <= ddr3_mem_ports[0].q;
            end
        end
        assign xm_rvalid_w = rv_r;
        assign xm_rdata_w  = line_r;
    end else begin : g_xbyte
        reg [1:0] xm_lane_r [0:7];
        reg [2:0] xm_lw_r = '0, xm_lr_r = '0;
        always @(posedge clk_gs_w) begin
            if (xm_take_w & ~xm_we_w) begin xm_lane_r[xm_lw_r] <= xm_addr_w[1:0]; xm_lw_r <= xm_lw_r + 1'b1; end
            if (ddr3_mem_ports[0].ready) xm_lr_r <= xm_lr_r + 1'b1;
        end
        assign xm_rvalid_w = ddr3_mem_ports[0].ready;
        assign xm_rdata_w  = ddr3_mem_ports[0].q[8 * xm_lane_r[xm_lr_r] +: 8];
    end
    // (the memory is ready: two flops into the accelerator's clock, quasi-static)
    reg calib_g0 = 1'b0, calib_g1 = 1'b0;
    always @(posedge clk_gs_w) begin calib_g0 <= init_calib_complete_w; calib_g1 <= calib_g0; end

    gs_accel #(.EXP_DDR(1'b1), .EXP_BANKS(126), .NEAR_KW(9), .NEAR_LINE(ACC_LINE)) u_acc (
        .exp_ready_i(calib_g1), .m_req_o(xm_req_w), .m_ready_i(ddr3_mem_ports[0].available), .m_we_o(xm_we_w),
        .m_addr_o(xm_addr_w), .m_wdata_o(xm_wdata_w), .m_rvalid_i(xm_rvalid_w), .m_rdata_i(xm_rdata_w),
        .clk(clk_gs_w), .rst_n(device_reset_n_w & gs_pll_lock_w),
        .arm_i(gs_ctrl_s1[0]), .listen_i(gs_ctrl_s1[2]), .out_extra_i(gs_oe_s1),
        .cfg_fast_i(rq_key_w & gs_rq_s1[0]), .cfg_cardmem_i(rq_key_w & gs_rq_s1[1]),
        .cfg_cxrom_i(rq_key_w & gs_rq_s1[2]), .cfg_copy_i(rq_key_w & gs_rq_s1[3]),
        .clear_i(gs_ctrl_s1[7]),
        .gs_ph2_i(gs_ph2), .gs_rdy_i(gs_rdy), .gs_irq_n_i(gs_irq_n), .gs_nmi_n_i(gs_nmi_n),
        .gs_res_n_i(gs_res_n), .gs_abort_n_i(gs_abort_n), .gs_be_i(gs_be),
        .gs_d_i(gs_d), .gs_d_o(gs_d_o_w), .gs_d_oe_o(gs_d_oe_w),
        .gs_a_o(gs_a), .gs_rw_o(gs_rw), .gs_vp_o(gs_vp), .gs_rdy_out_o(gs_rdy_out),
        .gs_d_dir_o(gs_d_dir), .gs_data_oe_n_o(gs_data_oe_n), .gs_addr_oe_n_o(gs_addr_oe_n),
        .gs_ctl_oe_n_o(gs_oe_n),
        .status_o(acc_status_w), .mode_o(acc_mode_w),
        .cycle_count_o(acc_cycle_w), .stall_count_o(acc_stall_w), .be_count_o(acc_be_w),
        .ph2_period_o(acc_per_w), .ph2_high_o(acc_high_w), .last_addr_o(acc_last_w),
        .verify_count_o(acc_verify_w),
        .tele_idx_i(gs_ti_s1), .tele_word_o(acc_word_w)
    );

    // ---- telemetry: accelerator domain -> connector domain (two flops per bit; a wide
    // counter may tear between bytes, as the full build's does)
    reg [159:0] gs_tele_s0, gs_tele_s1;
    reg [31:0]  gs_word_s0, gs_word_s1;
    always @(posedge clk_logic_w) begin
        // STATUS bits 1:0 carry the SLOT-side /DMA and /RDY levels, as in the full build
        gs_tele_s0 <= {acc_last_w, acc_high_w, acc_per_w, {acc_mode_w, 8'h5A}, acc_verify_w, acc_be_w, acc_stall_w,
                       acc_cycle_w, acc_status_w[7:2], a2_dma_n, a2_rdy_n};
        gs_tele_s1 <= gs_tele_s0;
        gs_word_s0 <= acc_word_w;
        gs_word_s1 <= gs_word_s0;
    end
    assign gs_tele_w  = gs_tele_s1;
    // the trace window as a table of words: {frozen, not triggered, write pointer 0} and
    // an entry {flags 07 = read, no stall, BE ok; bank:address:data = the word}
    assign gs_trace_w = {8'h80, 8'h07, gs_word_s1};

    // ---- LEDs (active low): heartbeat, socket ours, core running, fast
    reg [2:0] led_s0, led_s1;
    always @(posedge clk_logic_w) begin
        led_s0 <= {acc_mode_w[4], acc_status_w[6], acc_status_w[5]};
        led_s1 <= led_s0;
    end
    assign led = {~led_s1[2], ~led_s1[1], ~led_s1[0], ~led_r};
endmodule
