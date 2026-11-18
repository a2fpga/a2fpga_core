///////////////////////////////////////////////////////////////////////////////
// dp_transmitter.sv : Self-contained DisplayPort transmitter with audio
//
// Part of the DisplayPort_Verilog project - an open implementation of the
// DisplayPort protocol for FPGA boards.
//
// Ergonomics modelled on the hdl-util HDMI module: the consumer feeds RGB
// pixels (pull-style: this module outputs cx/cy, the consumer supplies the
// pixel for that coordinate) plus an audio-sample-rate strobe and stereo PCM,
// and receives DP main-link lanes.
//
// Clocking is DP synchronous-clock mode: clk_pixel is an OUTPUT, generated
// from the link symbol clock, so Mvid/Nvid are exact constants.
//
// Vendor selection (same pattern as hdl-util hdmi's serializer.sv):
//   `define DP_VENDOR_XILINX_GTP  - Artix-7 GTPE2 (original hamster target)
//   `define DP_VENDOR_GOWIN       - Gowin GW5AT Arora-V SERDES (in progress)
//   (neither)                     - behavioural stub for simulation/lint
//
// Status: simulation-verified. Generic video front-end (pull-style rgb via
// cx/cy), audio SDP subsystem (Audio_TimeStamp / Audio_Stream / Audio
// InfoFrame with RS(15,13) ECC), fabric 8b/10b for the Gowin raw-mode
// SERDES, and RBR link training are all covered by the test_benches/
// suite with independent C-model checkers (misc/). Hardware bring-up has
// not been attempted yet; see examples/tang_mega/README.md.
//
// MIT License - derived from work Copyright (c) 2019 Mike Field
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module dp_transmitter #(
    parameter int LANE_COUNT     = 2,      // 1 or 2 (4 once a 4-lane PHY bank exists)
    parameter int LINK_RATE_MBPS = 1620,   // 1620 (RBR); plumbing for 2700 later
    // Video timing - defaults are 1280x720p60, which fits RBR x2
    parameter int H_VISIBLE = 1280, H_TOTAL = 1650, H_SYNC_WIDTH = 40, H_START = 260,
    parameter int V_VISIBLE = 720,  V_TOTAL = 750,  V_SYNC_WIDTH = 5,  V_START = 25,
    parameter bit H_SYNC_ACTIVE_HIGH = 1'b1,
    parameter bit V_SYNC_ACTIVE_HIGH = 1'b1,
    parameter int TU_SIZE = 64,
    // Packer schedule ROM (see video_stream_packer.v): 1 = the per-line
    // walk decisions come from a BSRAM table; SCHED_HEX must match the
    // geometry (gen_packer_sched.py)
    parameter int SCHED_ROM = 0,
    parameter SCHED_HEX = "video_sched_720p_2l.hex",
    // rgb pull-contract latency (see dp_video_timing.v): 1 = classic
    // next-cycle answer; 2 = consumer gets an extra pipeline cycle
    parameter int RGB_LATENCY = 1,
    parameter int FIFO_LINES    = 3,   // pixel CDC FIFO depth, in video lines (see FIFO_ADDR_BITS)
    parameter int PREFILL_WORDS = 0,   // 0 = one line (WORDS_PER_LINE)
    // Bits per pixel stored in the pixel CDC FIFO: 24 (RGB888, the default)
    // or 16 (RGB565). With 16 the FIFO word is 4x16+1 = 65 bits instead of
    // 97 and takes 4 GW5A BSRAM blocks instead of 6 at 4 lanes
    // (RESOURCE_AUDIT B4). The pixel is quantised to 565 going in and
    // expanded going out with the same bit replication the framebuffer
    // uses for its own RGB565 store, so framebuffer pixels are bit-exact;
    // only pixels composed after the framebuffer (OSD text, scanline dim)
    // lose their low bits.
    parameter int PIXEL_BITS    = 24,
    parameter bit AUDIO_ENABLE = 1,  // 0: bypass SDP engine entirely (no
                                     // secondary packets on the wire) —
                                     // video-restart-bug discriminator

    // F_pixel = F_symbol_clk * PIXEL_CLK_MULT / PIXEL_CLK_DIV (81 MHz * 11/12 = 74.25 MHz)
    parameter int PIXEL_CLK_MULT = 11,
    parameter int PIXEL_CLK_DIV  = 12,
    // Pixel PLL divider triple (Gowin builds): clk_pixel =
    // f_symbol * MDIV / IDIV / ODIV0, and it must equal
    // f_symbol * PIXEL_CLK_MULT / PIXEL_CLK_DIV (checked at elaboration).
    parameter int PIXEL_PLL_IDIV  = 5,
    parameter int PIXEL_PLL_MDIV  = 44,
    parameter int PIXEL_PLL_ODIV0 = 8,
    parameter     PIXEL_PLL_FCLKIN = "135",
    // Audio - HDMI-style contract
    parameter int AUDIO_RATE      = 48000, // 44100 | 48000
    parameter int AUDIO_BIT_WIDTH = 16,
    // Open-loop link policy for boards whose AUX receive path is dead
    // (a2mega 1.0a3). DPCD writes still transmit; replies are not awaited.
    // See aux_channel.v for the full contract. 0 = spec-compliant flow.
    parameter int BLIND_SINK      = 0,
    // Closed-loop: restart the ladder when HPD drops >=2 ms (see aux_channel.v).
    // DEFAULT OFF (row 72): hubs flap HPD while their monitor sleeps -> reset storm.
    parameter int HPD_DISCONNECT_RESETS = 0,
    // Bring-up lane probe: force the SERDES powered and transmit a raw
    // ~4.2 MHz square on both lanes (scope-visible). See transceiver bank.
    parameter int TX_PROBE        = 0,
    // M5: honor the sink's ADJUST_REQUEST — apply swing/pre-emphasis via
    // the SERDES DRP during training (afe_adjust_seq; m5_runtime_afe.md).
    parameter int ENABLE_AFE_ADJUST = 0,
    parameter [23:0] AFE_LANE_BASE0 = 24'h808300,  // 138B die lane 1 —
    parameter [23:0] AFE_LANE_BASE1 = 24'h808400,  //  re-verify per die!
    parameter [1:0]  AFE_INIT_VS    = 2'd2,        // VS2 = 804 mV baseline
    parameter [1:0]  AFE_INIT_PE    = 2'd0,
    parameter [1:0]  AFE_MAX_VS     = 2'd2,        // declared swing ceiling (row 75)
    parameter [1:0]  AFE_MAX_PE     = 2'd3,
    // 1 = re-apply INIT via DRP at every training start (row 76: the
    // strobe + FFE auto->manual switch perturbs the PHY mid-training;
    // Ugreen battled Y:77-99 at the SAME levels production catches
    // clean). 0 = trust the boot csr; apply only on a real sink change.
    parameter int    AFE_APPLY_ON_START = 1,
    // Row 84 isolation switch: 0 = never assert phase_done (pre-gate
    // decision), 1 = the protocol gate of design-doc §14.
    parameter bit    ENABLE_PHASE_DONE_GATE = 1,
    // Gate grace period (08-24, hardware-evidenced): failing periodic
    // link checks within GATE_GRACE_CLKS of establishing are recorded,
    // not acted on — rides out the DP->HDMI converter's ~7 s status
    // settling (during which the picture is provably stable) instead of
    // teardown-storming. Bounded: after the window, the load-bearing
    // teardown->retrain behavior applies unchanged. 0 = legacy.
    parameter bit    GATE_GRACE = 0,
    parameter        GATE_GRACE_CLKS = 30'd800_000_000,
    // Dark-state kick (08-24): established + sink not-streaming for
    // KICK_CLKS -> ladder teardown/retrain, budgeted. The deliberate
    // replacement for the accidental stray-byte rescue the drain removed
    // (A/B: darks 2/4 with drain alone vs 0/8 with the accident present);
    // the watchdog's PHY cold restart is hardware-refuted for this state.
    parameter bit    GATE_KICK = 0,
    parameter        KICK_CLKS = 30'd250_000_000,
    // Sink-IRQ servicing (08-26 conformance fix — see aux_channel.v):
    // react to HPD IRQ with an immediate status read and acknowledge
    // DEVICE_SERVICE_IRQ_VECTOR by write-back. The dangling-input /
    // discarded-0x201 gap is the leading induced-wedge suspect.
    // NOT `bit`: mode 2 = ESI servicing (a 1-bit type would truncate it)
    parameter int    IRQ_SERVICE = 0,
    parameter bit    LATE_REPLY_DRAIN = 0,
    parameter bit    POLITE_ATTACH = 0,
    parameter [5:0]  EDID_DEFER_CAP = 6'd40,
    parameter [28:0] RETRY_WATCHDOG_CLKS = 29'd49999999,
    parameter [5:0]  EQ_WAIT_MULT = 6'd1,
    parameter        TRAIN_ERRCNT = 0,
    parameter        TRAIN_RECOVER = 1,
    parameter        ERRCNT_READ = 0,
    parameter        LINK_CHECK = 1,   // see auxch/aux_channel.v
    parameter [26:0] LINK_CHECK_CLKS = 27'd99999999, // see auxch/aux_channel.v
    // ECHO_SINK_ADJUST (AFE sequencer off only): declare the sink's last
    // ADJUST_REQUEST in TRAINING_LANEx_SET instead of the constant
    // IDLE_SET_BYTE. For a PHY whose swing/PE are set by a downstream
    // redriver that snoops those writes (a2p25: SN75DP130 auto mode) this
    // is what makes the sink's request take effect. MAX_*_REACHED bits set
    // at level 3. Until the first request of a training the legacy byte
    // (VS2 + MAX_SWING) is declared. Default 0 = byte-identical legacy.
    parameter        ECHO_SINK_ADJUST = 0,
    parameter        WEDGE_BIT = 30,
    parameter [31:0] WEDGE_PRELOAD = 32'h1000_0000,
    parameter int BIT_WIDTH  = $clog2(H_TOTAL),
    parameter int BIT_HEIGHT = $clog2(V_TOTAL)
)(
    input  logic clk100,          // 100 MHz management clock (AUX bit timing depends on it)
    input  logic refclk0,         // SERDES/transceiver reference clock(s); buffers live
    input  logic refclk1,         //   in the board top (IBUFDS_GTE2 / Gowin equivalent)
    input  logic sim_clk_pixel,   // no-vendor sim builds only: externally generated pixel
                                  //   clock (F_symbol * PIXEL_CLK_MULT/PIXEL_CLK_DIV);
                                  //   vendor builds generate clk_pixel from a fabric PLL
    input  logic reset,

    // Audio in: clk_audio is a one-clk_pixel-wide strobe at AUDIO_RATE;
    // audio_sample_word must be valid when the strobe fires. (Phase 3)
    input  logic clk_audio,
    input  logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    // Pull-style video (Phase 2): module owns clk_pixel and coordinates
    output logic clk_pixel,
    input  logic [23:0] rgb,
    output logic [BIT_WIDTH-1:0]  cx,
    output logic [BIT_HEIGHT-1:0] cy,
    output logic [BIT_WIDTH-1:0]  frame_width,
    output logic [BIT_WIDTH-1:0]  screen_width,
    output logic [BIT_HEIGHT-1:0] frame_height,
    output logic [BIT_HEIGHT-1:0] screen_height,

    // DP main link
    output logic [LANE_COUNT-1:0] dp_tx_lane_p,
    output logic [LANE_COUNT-1:0] dp_tx_lane_n,

    // AUX / HPD - raw digital; the analog bidirectional buffer (IOBUFDS /
    // ELVDS_IOBUF / pseudo-differential pair) is instantiated in the board top
    input  logic hpd,
    input  logic auxch_in,
    output logic auxch_out,
    output logic auxch_tri,

    // Status
    output logic link_established,
    output logic video_live,
    output logic [7:0] debug,
    output logic [15:0] debug_rx,  // AUX RX: {last byte, sync hits, accepted bytes}
    output logic [3:0]  debug_locks, // {clock,equ,symbol,align}_locked
    output logic [7:0]  debug_gate,  // latched-at-gate locks + fail/timeout ctrs
    output logic [7:0]  debug_sink,  // DPCD 0x205 SINK_STATUS
    output logic [15:0] debug_adjust, // raw sink ADJUST_REQUEST (0x206/0x207)
    output logic [23:0] debug_chstate, // raw DPCD {0x204, 0x203, 0x202}
    output logic [23:0] debug_aux_err,  // {short, nack, other, obs, kicks, irq_services}
    output logic [15:0] debug_esi,      // sticky OR {0x2003, 0x2005} vector reads
    output logic [6:0]  debug_defer,    // {edid_giveup, defer_cnt}
    output logic        wedge_suspect,  // advisory quiet-frozen detector
    output logic        debug_drp_clk,  // cm_life/DRP clock (freq-meter diag tap)
    output logic [15:0] debug_errcnt0,  // SYMBOL_ERROR_COUNT lane0 (raw, bit15=valid)
    output logic [15:0] debug_errcnt1,  // SYMBOL_ERROR_COUNT lane1
    output logic [27:0] debug_err_detail, // first teardown {reason, state, expected, rx_cnt}
    output logic [103:0] debug_obs,     // LINK_CHECK==2 observe counters (auxch/aux_channel.v)
    output logic [23:0]  debug_auxif,   // AUX interface liveness (auxch/aux_channel.v)
    output logic [31:0] debug_snapshot, // first-gate-failure {chstate24, seq4, tsl4}
    output logic [7:0]  debug_caps,    // sink capability profile
    // raw {DPCD 0x001 MAX_LINK_RATE, DPCD 0x002 MAX_LANE_COUNT byte};
    // 0x0000 until the caps read completes, cleared on HPD-presence loss
    output logic [15:0] debug_sink_caps,
    output logic [3:0]  debug_wdog,  // {cold-restart forcing, attempts[2:0]}
    // Teardown attribution (08-24): saturating 4-bit counts of the two
    // paths that tear down an ESTABLISHED link — the check_wait gate and
    // AUX transaction timeouts. The debug_gate twins are 2-bit and wrap.
    output logic [15:0]  debug_teardown,  // {first_mask, fail_mask, gate_fail_sat, timeout_sat}
    output logic [9:0]  debug_wrusewd, // TX FIFO fill {word-lane0's, word-lane1's}
    output logic [5:0]  debug_afe,     // M5 applied AFE lane 0: {seq_err, known, pe[1:0], vs[1:0]}
    output logic [3:0]  debug_afe1,    // M5 applied AFE lane 1: {pe[1:0], vs[1:0]}
    // M5 bench instrumentation: {all-zero requests seen, requests dropped
    // by the phase_done gate, DRP sequences applied} — saturating 4-bit
    output logic [11:0] debug_evt,
    // GTR12 TX word clock (line-rate/20) for board-level diagnostics —
    // e.g. an in-fabric line-rate check against a known crystal.
    output logic clk_symbol_out,
    // SERDES bring-up status {pll_lock, lane_ready[1:0], tx_out_of_reset,
    // tx_running[1:0]}; ties to all-ones on non-Gowin/sim builds.
    output logic [7:0] serdes_status,
    output logic hpd_present_out,
    // Packer health (tx_symbol_clk domain, quasi-static): saturating count
    // of pixel-FIFO underruns since the link was last established, and the
    // current FIFO read level. A non-zero count while video_live means the
    // pixel clock is not exactly locked to the symbol clock (or the FIFO
    // pre-fill is short) — the stream content is then garbage even though
    // the link trains perfectly.
    output logic [7:0]  debug_underrun_cnt,
    output logic [15:0] debug_fifo_level,
`ifdef DP_VENDOR_DPHY
    // External PHY (a2p25: hardened MIPI D-PHY as a raw serializer). The
    // board top hosts the serializer (boards/a2p25/hdl/dp/
    // transceiver_bank_dphy.sv) because its pads are inout macro ports;
    // this module hands it the pre-8b/10b symbol stream and takes back
    // the symbol clock it derives from the D-PHY PLL.
    input  logic        ext_symbol_clk,
    input  logic [3:0]  ext_tx_running,
    output logic [79:0] ext_tx_symbols,
    output logic [3:0]  ext_powerup_channel,
`endif
    // DRP register-dump readback (Gowin only; zeros elsewhere) — see
    // transceiver_bank_gowin dbg_* ports.
    input  logic [4:0]  drp_dbg_idx,
    output logic [31:0] drp_dbg_data,
    output logic [23:0] drp_dbg_addr,
    output logic        drp_dbg_done
);

    // ------------------------------------------------------------------
    // Elaboration-time bandwidth check: visible payload must fit in the
    // link's data capacity with margin for blanking overhead + SDPs.
    // Payload bytes/s = Fpix * 3; capacity = LANE_COUNT * rate/10 bytes/s.
    // Using the 0.9 factor from the plan.
    // ------------------------------------------------------------------
    localparam longint F_SYMBOL_HZ = longint'(LINK_RATE_MBPS) * 1_000_000 / 20; // 73-bit word clock
    localparam longint F_PIXEL_HZ  = F_SYMBOL_HZ * PIXEL_CLK_MULT / PIXEL_CLK_DIV;
    initial begin
        if (F_PIXEL_HZ * 3 * 10 > longint'(LANE_COUNT) * LINK_RATE_MBPS * 100_000 * 9)
            $error("dp_transmitter: video bandwidth (%0d B/s) exceeds 90%% of %0dx RBR/HBR lane capacity",
                   F_PIXEL_HZ * 3, LANE_COUNT);
    end

    // ------------------------------------------------------------------
    // Link-layer control signals
    // ------------------------------------------------------------------
    logic  [3:0] tx_powerup_channel;
    logic        preemp_0p0, preemp_3p5, preemp_6p0;
    logic        swing_0p4,  swing_0p6,  swing_0p8;
    logic  [3:0] tx_running;
    logic        tx_symbol_clk;
    assign clk_symbol_out = tx_symbol_clk;
    logic [79:0] tx_symbols;
    logic        tx_align_train, tx_clock_train, tx_link_established;
    logic  [2:0] stream_channel_count;
    logic  [2:0] source_channel_count;
    logic [72:0] msa_merged_data;
    logic        test_signal_ready;

    assign source_channel_count = 3'(LANE_COUNT);
    assign link_established     = tx_link_established;
    assign video_live           = tx_link_established & test_signal_ready;
    assign stream_channel_count = 3'(LANE_COUNT);

    assign frame_width   = BIT_WIDTH'(H_TOTAL);
    assign screen_width  = BIT_WIDTH'(H_VISIBLE);
    assign frame_height  = BIT_HEIGHT'(V_TOTAL);
    assign screen_height = BIT_HEIGHT'(V_VISIBLE);

    // ------------------------------------------------------------------
    // Sync-clocking M/N: Mvid/Nvid = Fpixel/Fsymbol_lane = MULT/(2*DIV),
    // scaled to Nvid = 2^19 with rounding (exact small rationals are
    // rejected by some sinks - see README's M/N discussion)
    // ------------------------------------------------------------------
    localparam int N_VALUE = 24'h080000;
    localparam int M_VALUE = (PIXEL_CLK_MULT * 262144 + PIXEL_CLK_DIV/2) / PIXEL_CLK_DIV;

    // Link symbols per lane per video line; must divide out exactly
    localparam int SYMS_PER_LINE = H_TOTAL * 2 * PIXEL_CLK_DIV / PIXEL_CLK_MULT;
    localparam int VALID_NUM     = TU_SIZE * 3 * PIXEL_CLK_MULT;
    localparam int VALID_DEN     = 2 * PIXEL_CLK_DIV * LANE_COUNT;
    localparam int WORDS_PER_LINE = H_VISIBLE / LANE_COUNT;
    // Pixel CDC FIFO depth in video lines and the prefill before a frame
    // starts (defaults = the shipped sizing: 3 lines, prime at 1 line).
    // The GW5A-25 build uses 1 line / half a line: the level only swings
    // ~+-60 words around the prefill point at 1080p x4 (a2p25 bench), and
    // 97 x 2048 bits was 11 of its 56 BSRAM blocks.
    localparam int FIFO_ADDR_BITS = $clog2(FIFO_LINES * WORDS_PER_LINE);
    localparam int FIFO_PREFILL   = (PREFILL_WORDS > 0) ? PREFILL_WORDS : WORDS_PER_LINE;

    initial begin
        if (H_TOTAL * 2 * PIXEL_CLK_DIV % PIXEL_CLK_MULT != 0)
            $error("dp_transmitter: H_TOTAL*2*PIXEL_CLK_DIV must be divisible by PIXEL_CLK_MULT");
        if (H_VISIBLE % LANE_COUNT != 0)
            $error("dp_transmitter: H_VISIBLE must be a multiple of LANE_COUNT");
        if (SYMS_PER_LINE % 2 != 0)
            $error("dp_transmitter: SYMS_PER_LINE must be even (two symbols per lane per clock)");
    end

    // ------------------------------------------------------------------
    // Pixel clock (synchronous clocking: generated from the symbol clock)
    // ------------------------------------------------------------------
`ifdef DP_VENDOR_DPHY
 `define DP_GOWIN_PIXEL_PLL
`elsif DP_VENDOR_GOWIN
 `define DP_GOWIN_PIXEL_PLL
`endif
`ifdef DP_GOWIN_PIXEL_PLL
 `ifdef GOWIN_PLL_IP
    // IDE-generated PLLA wrapper: clk_pixel = tx_symbol_clk * MULT / DIV,
    // realized as VCO = f_symbol * PIXEL_PLL_MDIV / PIXEL_PLL_IDIV and
    // clk_pixel = VCO / PIXEL_PLL_ODIV0. DP synchronous-clock mode needs
    // the pixel clock locked to the symbol clock, so this PLL always
    // takes tx_symbol_clk - only the ratio changes with the link rate:
    //   2-lane HBR: 135 MHz in, 5/44/8   -> VCO 1188, 148.5 MHz out
    //   4-lane RBR:  81 MHz in, 1/11/6   -> VCO  891, 148.5 MHz out
    // The elaboration check below is the guard: it recomputes the output
    // from the divider triple and fails if it misses MULT/DIV.
    initial begin
        if (F_SYMBOL_HZ * PIXEL_PLL_MDIV / PIXEL_PLL_IDIV / PIXEL_PLL_ODIV0
            != F_PIXEL_HZ)
            $error("dp_transmitter: PIXEL_PLL_IDIV/MDIV/ODIV0 do not yield F_PIXEL_HZ from F_SYMBOL_HZ");
    end
    gowin_pixel_pll #(.ODIV0(PIXEL_PLL_ODIV0),
                      .IDIV (PIXEL_PLL_IDIV),
                      .MDIV (PIXEL_PLL_MDIV),
                      .FCLKIN(PIXEL_PLL_FCLKIN)) i_pixel_pll (
        .clkin  (tx_symbol_clk),
        .clkout (clk_pixel)
    );
 `else
    assign clk_pixel = sim_clk_pixel;   // simulation of the Gowin config
 `endif
`elsif DP_VENDOR_XILINX_GTP
    // A MMCM instantiation belongs here when the generic front-end is
    // used on Xilinx; the legacy example tops still use test_source.
    initial $error("dp_transmitter: Xilinx pixel MMCM not wired (use legacy example top)");
`else
    assign clk_pixel = sim_clk_pixel;
`endif

    // ------------------------------------------------------------------
    // Generic video front-end: timing generator (pixel domain) -> CDC
    // FIFO -> symbol-domain stream packer -> MSA insertion
    // ------------------------------------------------------------------
    logic capture_arm, capture_arm_m, capture_arm_px;
    always_ff @(posedge clk_pixel) begin
        capture_arm_m  <= capture_arm;
        capture_arm_px <= capture_arm_m;
    end

    logic [24*LANE_COUNT-1:0] fifo_wdata, fifo_rpix;
    logic [PIXEL_BITS*LANE_COUNT-1:0] fifo_wdata_q, fifo_rpix_q;   // as stored
    logic fifo_wsof, fifo_wen, fifo_rsof, fifo_rvalid, fifo_rd;
    logic [FIFO_ADDR_BITS:0] fifo_rlevel;

    dp_video_timing #(
        .LANE_COUNT (LANE_COUNT),
        .H_VISIBLE  (H_VISIBLE),
        .H_TOTAL    (H_TOTAL),
        .V_VISIBLE  (V_VISIBLE),
        .V_TOTAL    (V_TOTAL),
        .BIT_WIDTH  (BIT_WIDTH),
        .BIT_HEIGHT (BIT_HEIGHT),
        .RGB_LATENCY (RGB_LATENCY)
    ) i_dp_video_timing (
        .clk_pixel   (clk_pixel),
        .reset       (reset),
        .capture_arm (capture_arm_px),
        .rgb         (rgb),
        .cx          (cx),
        .cy          (cy),
        .fifo_wdata  (fifo_wdata),
        .fifo_wsof   (fifo_wsof),
        .fifo_wen    (fifo_wen)
    );

    // Pixel width conversion at the FIFO boundary (PIXEL_BITS): pure
    // wiring on both sides — bit selects into the BSRAM data input on the
    // pixel clock, bit replication out of the head register on the symbol
    // clock — so neither timing cone gains logic.
    generate
        if (PIXEL_BITS == 24) begin : g_pix24
            assign fifo_wdata_q = fifo_wdata;
            assign fifo_rpix    = fifo_rpix_q;
        end else if (PIXEL_BITS == 16) begin : g_pix16
            for (genvar pl = 0; pl < LANE_COUNT; pl++) begin : g_lane
                wire [23:0] w888 = fifo_wdata[pl*24 +: 24];
                // RGB888 -> RGB565
                assign fifo_wdata_q[pl*16 +: 16] = {w888[23:19], w888[15:10], w888[7:3]};
                // RGB565 -> RGB888, the framebuffer's chain (rgb565_to_666
                // then torgb): R6 = {r5, r5[4]}, R8 = {R6, R6[5:4]}
                wire [15:0] r565 = fifo_rpix_q[pl*16 +: 16];
                wire [4:0]  r5 = r565[15:11];
                wire [5:0]  g6 = r565[10:5];
                wire [4:0]  b5 = r565[4:0];
                assign fifo_rpix[pl*24 +: 24] = {r5, r5[4], r5[4], r5[3],
                                                 g6, g6[5:4],
                                                 b5, b5[4], b5[4], b5[3]};
            end
        end else begin : g_pix_bad
            initial $error("dp_transmitter: PIXEL_BITS must be 24 or 16");
        end
    endgenerate

    pixel_cdc_fifo #(
        .WIDTH     (PIXEL_BITS*LANE_COUNT + 1),
        .ADDR_BITS (FIFO_ADDR_BITS)
    ) i_pixel_cdc_fifo (
        .wclk   (clk_pixel),
        .wreset (reset),
        .wdata  ({fifo_wsof, fifo_wdata_q}),
        .wen    (fifo_wen),
        .wfull  (),
        .rclk   (tx_symbol_clk),
        .rreset (reset),
        .rdata  ({fifo_rsof, fifo_rpix_q}),
        .rvalid (fifo_rvalid),
        .rd_en  (fifo_rd),
        .rlevel (fifo_rlevel)
    );

    logic [72:0] packed_data, sdp_merged_data, sdp_engine_out;
    assign sdp_merged_data = AUDIO_ENABLE ? sdp_engine_out : packed_data;
    logic        sdp_gap, frame_pulse, fifo_underrun;
    logic        link_est_d = 1'b0;
    always_ff @(posedge tx_symbol_clk) begin
        link_est_d <= tx_link_established;
        if (tx_link_established && !link_est_d)
            debug_underrun_cnt <= 8'd0;
        else if (fifo_underrun && debug_underrun_cnt != 8'hFF)
            debug_underrun_cnt <= debug_underrun_cnt + 8'd1;
        debug_fifo_level <= 16'(fifo_rlevel);
    end
    logic        audio_strobe_sym, audio_buffer_ready, audio_buffer_take;
    logic        audio_mute;
    logic [4*2*AUDIO_BIT_WIDTH-1:0] audio_buffer_flat;
    logic [23:0] maud;
    logic  [7:0] maud_byte;

    video_stream_packer #(
        .LANE_COUNT    (LANE_COUNT),
        .H_VISIBLE     (H_VISIBLE),
        .V_VISIBLE     (V_VISIBLE),
        .V_TOTAL       (V_TOTAL),
        .TU_SIZE       (TU_SIZE),
        .SYMS_PER_LINE (SYMS_PER_LINE),
        .VALID_NUM     (VALID_NUM),
        .VALID_DEN     (VALID_DEN),
        .PREFILL       (FIFO_PREFILL),
        .SCHED_ROM     (SCHED_ROM),
        .SCHED_HEX     (SCHED_HEX)
    ) i_video_stream_packer (
        .clk         (tx_symbol_clk),
        .reset       (reset),
        .mvid_byte   (8'(M_VALUE & 8'hFF)),
        .maud_byte   (maud_byte),
        .audio_mute  (audio_mute),
        .fifo_rdata  (fifo_rpix),
        .fifo_rsof   (fifo_rsof),
        .fifo_rvalid (fifo_rvalid),
        .fifo_rd     (fifo_rd),
        .fifo_rlevel (16'(fifo_rlevel)),
        .capture_arm (capture_arm),
        .ready       (test_signal_ready),
        .data        (packed_data),
        .sdp_gap     (sdp_gap),
        .frame_pulse (frame_pulse),
        .underrun    (fifo_underrun)
    );

    // ------------------------------------------------------------------
    // Audio: strobe CDC + sample buffering, Maud measurement, SDP engine
    // ------------------------------------------------------------------
    audio_sample_buffer #(
        .AUDIO_BIT_WIDTH (AUDIO_BIT_WIDTH)
    ) i_audio_sample_buffer (
        .clk_pixel    (clk_pixel),
        .clk_audio    (clk_audio),
        .sample_l     (audio_sample_word[0]),
        .sample_r     (audio_sample_word[1]),
        .clk_sym      (tx_symbol_clk),
        .reset        (reset),
        .strobe_sym   (audio_strobe_sym),
        .buffer       (audio_buffer_flat),
        .buffer_count (),
        .buffer_ready (audio_buffer_ready),
        .buffer_take  (audio_buffer_take)
    );

    maud_measure #(
        .AUDIO_RATE     (AUDIO_RATE),
        .LINK_RATE_MBPS (LINK_RATE_MBPS)
    ) i_maud_measure (
        .clk_sym    (tx_symbol_clk),
        .reset      (reset),
        .strobe_sym (audio_strobe_sym),
        .maud       (maud),
        .maud_byte  (maud_byte)
    );

    sdp_engine #(
        .LANE_COUNT      (LANE_COUNT),
        .AUDIO_BIT_WIDTH (AUDIO_BIT_WIDTH),
        .AUDIO_RATE      (AUDIO_RATE)
    ) i_sdp_engine (
        .clk          (tx_symbol_clk),
        .reset        (reset),
        .in_data      (packed_data),
        .sdp_gap      (sdp_gap),
        .frame_pulse  (frame_pulse),
        .out_data     (sdp_engine_out),
        .buffer       (audio_buffer_flat),
        .buffer_ready (audio_buffer_ready),
        .buffer_take  (audio_buffer_take),
        .maud         (maud),
        .audio_mute   (audio_mute)
    );

    // ------------------------------------------------------------------
    // MSA (main stream attributes) secondary packet insertion
    // ------------------------------------------------------------------
    generate
    if (LANE_COUNT == 4) begin : g_msa4
        msa_inserter_4ch i_msa(
            .clk                 (tx_symbol_clk),
            .active              (1'b1),
            .M_value             (24'(M_VALUE)),
            .N_value             (24'(N_VALUE)),
            .H_visible           (12'(H_VISIBLE)),
            .V_visible           (12'(V_VISIBLE)),
            .H_total             (12'(H_TOTAL)),
            .V_total             (12'(V_TOTAL)),
            .H_sync_width        (12'(H_SYNC_WIDTH)),
            .V_sync_width        (12'(V_SYNC_WIDTH)),
            .H_start             (12'(H_START)),
            .V_start             (12'(V_START)),
            .H_vsync_active_high (H_SYNC_ACTIVE_HIGH),
            .V_vsync_active_high (V_SYNC_ACTIVE_HIGH),
            .flag_sync_clock     (1'b1),
            .flag_YCCnRGB        (1'b0),
            .flag_422n444        (1'b0),
            .flag_range_reduced  (1'b0),
            .flag_interlaced_even(1'b0),
            .flag_YCC_colour_709 (1'b0),
            .flags_3d_Indicators (2'b00),
            .bits_per_colour     (5'b01000),
            .in_data             (sdp_merged_data),
            .out_data            (msa_merged_data)
        );
    end else if (LANE_COUNT == 1) begin : g_msa1
        msa_inserter_1ch i_msa(
            .clk                 (tx_symbol_clk),
            .active              (1'b1),
            .M_value             (24'(M_VALUE)),
            .N_value             (24'(N_VALUE)),
            .H_visible           (12'(H_VISIBLE)),
            .V_visible           (12'(V_VISIBLE)),
            .H_total             (12'(H_TOTAL)),
            .V_total             (12'(V_TOTAL)),
            .H_sync_width        (12'(H_SYNC_WIDTH)),
            .V_sync_width        (12'(V_SYNC_WIDTH)),
            .H_start             (12'(H_START)),
            .V_start             (12'(V_START)),
            .H_vsync_active_high (H_SYNC_ACTIVE_HIGH),
            .V_vsync_active_high (V_SYNC_ACTIVE_HIGH),
            .flag_sync_clock     (1'b1),
            .flag_YCCnRGB        (1'b0),
            .flag_422n444        (1'b0),
            .flag_range_reduced  (1'b0),
            .flag_interlaced_even(1'b0),
            .flag_YCC_colour_709 (1'b0),
            .flags_3d_Indicators (2'b00),
            .bits_per_colour     (5'b01000),
            .in_data             (sdp_merged_data),
            .out_data            (msa_merged_data)
        );
    end else begin : g_msa2
        msa_inserter_2ch i_msa(
            .clk                 (tx_symbol_clk),
            .active              (1'b1),
            .M_value             (24'(M_VALUE)),
            .N_value             (24'(N_VALUE)),
            .H_visible           (12'(H_VISIBLE)),
            .V_visible           (12'(V_VISIBLE)),
            .H_total             (12'(H_TOTAL)),
            .V_total             (12'(V_TOTAL)),
            .H_sync_width        (12'(H_SYNC_WIDTH)),
            .V_sync_width        (12'(V_SYNC_WIDTH)),
            .H_start             (12'(H_START)),
            .V_start             (12'(V_START)),
            .H_vsync_active_high (H_SYNC_ACTIVE_HIGH),
            .V_vsync_active_high (V_SYNC_ACTIVE_HIGH),
            .flag_sync_clock     (1'b1),
            .flag_YCCnRGB        (1'b0),
            .flag_422n444        (1'b0),
            .flag_range_reduced  (1'b0),
            .flag_interlaced_even(1'b0),
            .flag_YCC_colour_709 (1'b0),
            .flags_3d_Indicators (2'b00),
            .bits_per_colour     (5'b01000),
            .in_data             (sdp_merged_data),
            .out_data            (msa_merged_data)
        );
    end
    endgenerate

    // ------------------------------------------------------------------
    // Main link datapath: idle insertion, scrambling, training patterns
    // ------------------------------------------------------------------
    main_stream_processing i_main_stream_processing(
        .symbol_clk          (tx_symbol_clk),
        .tx_link_established (tx_link_established),
        .source_ready        (test_signal_ready),
        .tx_clock_train      (tx_clock_train),
        .tx_align_train      (tx_align_train),
        .in_data             (msa_merged_data),
        .tx_symbols          (tx_symbols)
    );

    // ------------------------------------------------------------------
    // Link policy: AUX channel, EDID/DPCD, link training
    // ------------------------------------------------------------------
    // M5 runtime AFE adjust: ADJUST_REQUEST -> DRP sequence -> truthful
    // TRAINING_LANE_SET. Tied off (byte-identical legacy) when disabled.
    // per lane: [7:0] = lane 0 (DPCD 0x103), [15:8] = lane 1 (0x104)
    logic [15:0] train_set_byte, train_set_byte_afe;
    logic        adjust_evt;
    // ECHO_SINK_ADJUST: per-lane {00, PE_MAX, PE[1:0], VS_MAX, VS[1:0]}
    // from the raw request nibbles; falls back to 0x06 until the sink has
    // asked for something in this training (adjust_seen clears with the
    // link powerup, i.e. on every teardown).
    logic        adjust_seen = 1'b0;
    always_ff @(posedge clk100) begin
        if (tx_powerup_channel == 4'b0000) adjust_seen <= 1'b0;
        else if (adjust_evt)  adjust_seen <= 1'b1;
    end
    function automatic [7:0] echo_byte(input [1:0] vs, input [1:0] pe);
        echo_byte = {2'b00, (pe == 2'd3), pe, (vs == 2'd3), vs};
    endfunction
    wire [15:0] train_set_byte_echo = adjust_seen
        ? {echo_byte(debug_adjust[5:4], debug_adjust[7:6]),
           echo_byte(debug_adjust[1:0], debug_adjust[3:2])}
        : 16'h0606;
    assign train_set_byte = (ECHO_SINK_ADJUST != 0 && ENABLE_AFE_ADJUST == 0)
                          ? train_set_byte_echo : train_set_byte_afe;
    logic        afe_busy_w, afe_phy_reinit;
    logic        afe_drp_clk, afe_drp_req, afe_drp_gnt;
    assign debug_drp_clk = afe_drp_clk;
    logic        afe_drp_wren, afe_drp_ready;
    logic [23:0] afe_drp_addr;
    logic [31:0] afe_drp_wrdata;

    afe_adjust_seq #(
        .ENABLE_AFE_ADJUST (ENABLE_AFE_ADJUST),
        .NUM_LANES         (2),                 // matches the 2-lane bank
        .LANE_BASE0        (AFE_LANE_BASE0),
        .LANE_BASE1        (AFE_LANE_BASE1),
        .INIT_VS           (AFE_INIT_VS),
        .INIT_PE           (AFE_INIT_PE),
        .MAX_VS            (AFE_MAX_VS),
        .MAX_PE            (AFE_MAX_PE),
        .APPLY_ON_TRAINING_START (AFE_APPLY_ON_START)
    ) i_afe_adjust (
        .mgmt_clk        (clk100),
        // per-lane ADJUST_REQUEST nibbles of DPCD 0x206 as captured by
        // link_signal_mgmt.channel_adjust (= debug_adjust[7:0]):
        //   lane 0: VS [1:0], PE [3:2];  lane 1: VS [5:4], PE [7:6]
        .vs_request      ({debug_adjust[5:4], debug_adjust[1:0]}),
        .pe_request      ({debug_adjust[7:6], debug_adjust[3:2]}),
        .adjust_de       (adjust_evt),
        .training_active (tx_clock_train | tx_align_train),
        // Protocol gate: the phase that is currently being trained already
        // reports success -> the ladder advances, so the accompanying
        // ADJUST_REQUEST must NOT be applied. debug_locks =
        // {clock, equ, symbol, align}_locked (registered in channel_managemnt).
        // ISOLATION BUILD (row 84): gate decision disabled, everything else
        // (ports, counters, placement pressure) retained. Restores the
        // pre-gate DECISION while keeping the pre-gate logic present, so a
        // blink-count comparison attributes the regression to the gate's
        // decision or to placement. Restore the expression below to ship.
        .phase_done      (ENABLE_PHASE_DONE_GATE ?
                            (tx_clock_train ? debug_locks[3]
                                            : (tx_align_train ? (&debug_locks[2:0])
                                                              : 1'b0))
                          : 1'b0),
        // PHY (re)initialising: PLL unlocked, PCS TX in reset, or the
        // watchdog replaying the boot CSR — all return the AFE to boot
        // state, so the sequencer must forget what it applied.
        .phy_reinit      (afe_phy_reinit),
        .train_set_byte  (train_set_byte_afe),
        .afe_busy        (afe_busy_w),
        .dbg_afe         (debug_afe),
        .dbg_afe1        (debug_afe1),
        .dbg_evt         (debug_evt),
        .drp_clk         (afe_drp_clk),
        .drp_req         (afe_drp_req),
        .drp_gnt         (afe_drp_gnt),
        .drp_addr        (afe_drp_addr),
        .drp_wrdata      (afe_drp_wrdata),
        .drp_wren        (afe_drp_wren),
        .drp_ready       (afe_drp_ready)
    );
    // serdes_status = {fifo_afull, fifo_full, pll_lock, lane_ready[1:0],
    // ~pcs_tx_rst, tx_running[1:0]} (Gowin bank; 8'h3F on stubs).
    assign afe_phy_reinit = ~serdes_status[5] | ~serdes_status[2] | wdog_replay_req;


    channel_management #(.LINK_RATE_MBPS(LINK_RATE_MBPS),
                         .BLIND_SINK(BLIND_SINK),
                         .HPD_DISCONNECT_RESETS(HPD_DISCONNECT_RESETS),
                         .AFE_ADJUST(ENABLE_AFE_ADJUST),
                         .GATE_GRACE(GATE_GRACE),
                         .GATE_GRACE_CLKS(GATE_GRACE_CLKS),
                         .GATE_KICK(GATE_KICK),
                         .KICK_CLKS(KICK_CLKS),
                         .IRQ_SERVICE(IRQ_SERVICE),
                         .LATE_REPLY_DRAIN(LATE_REPLY_DRAIN),
                         .POLITE_ATTACH(POLITE_ATTACH),
                         .EDID_DEFER_CAP(EDID_DEFER_CAP),
                         .RETRY_WATCHDOG_CLKS(RETRY_WATCHDOG_CLKS),
                         .EQ_WAIT_MULT(EQ_WAIT_MULT),
                         .TRAIN_ERRCNT(TRAIN_ERRCNT),
                         .TRAIN_RECOVER(TRAIN_RECOVER),
                         .ERRCNT_READ(ERRCNT_READ),
                         .LINK_CHECK(LINK_CHECK),
                         .LINK_CHECK_CLKS(LINK_CHECK_CLKS),
                         .WEDGE_BIT(WEDGE_BIT), .WEDGE_PRELOAD(WEDGE_PRELOAD)) i_channel_management(
        .clk100               (clk100),
        .train_set_byte       (train_set_byte),
        .afe_busy             (afe_busy_w),
        .adjust_evt           (adjust_evt),
        .debug                (debug),
        .debug_rx             (debug_rx),
        .debug_locks          (debug_locks),
        .debug_gate           (debug_gate),
        .debug_teardown       (debug_teardown),
        .debug_sink           (debug_sink),
        .debug_adjust         (debug_adjust),
        .debug_chstate        (debug_chstate),
        .debug_aux_err        (debug_aux_err),
        .debug_esi            (debug_esi),
        .debug_defer          (debug_defer),
        .wedge_suspect        (wedge_suspect),
        .errcnt0              (debug_errcnt0),
        .errcnt1              (debug_errcnt1),
        .debug_err_detail     (debug_err_detail),
        .debug_obs            (debug_obs),
        .debug_auxif          (debug_auxif),
        .debug_snapshot       (debug_snapshot),
        .debug_caps           (debug_caps),
        .debug_sink_caps      (debug_sink_caps),
        .hpd                  (hpd),
        .auxch_in             (auxch_in),
        .auxch_out            (auxch_out),
        .auxch_tri            (auxch_tri),
        .stream_channel_count (stream_channel_count),
        .source_channel_count (source_channel_count),
        .tx_clock_train       (tx_clock_train),
        .tx_align_train       (tx_align_train),
        .tx_powerup_channel   (tx_powerup_channel),
        .tx_preemp_0p0        (preemp_0p0),
        .tx_preemp_3p5        (preemp_3p5),
        .tx_preemp_6p0        (preemp_6p0),
        .tx_swing_0p4         (swing_0p4),
        .tx_swing_0p6         (swing_0p6),
        .tx_swing_0p8         (swing_0p8),
        .tx_running           (tx_running),
        .tx_link_established  (tx_link_established),
        .hpd_present_out      (hpd_present_out)
    );

    // ------------------------------------------------------------------
    // AUTO-RECOVERY WATCHDOG (2026-08-16). The GTR12 quad common block
    // (CMU/QPLL) takes a per-powered-session init draw; a bad roll leaves
    // the link trained-and-stable but the sink reporting SINK_STATUS=0
    // (DPCD 0x205 bits[1:0]) - no valid stream, dark screen. Ladder
    // retrains, PMA/PCS resets, mux/hub bounces never re-roll it (proven
    // on hw); the CMU resets are tied to por_n inside the generated
    // wrapper, and por_n follows powerup_channel - but the ladder's own
    // retrain path only blips powerup for a few states. This watchdog
    // performs a GENUINE cold restart: if the link is established and
    // the sink still reports no stream after WDOG_GRACE, force the PHY
    // powerup low for WDOG_DWELL (por_n low -> CMU0/1 reset held), then
    // release and let the ladder retrain. Budget WDOG_CAP attempts,
    // re-armed on success. debug_wdog = {forcing, attempts[2:0]}.
    // ------------------------------------------------------------------
    // Grace accumulates whenever the PHY is powered but the sink is not
    // streaming, and is NOT reset by link drops - a bad draw can express
    // as stable-dark (established, K=0) OR as endless flap (teardown
    // every few seconds); only genuine streaming clears the timer.
    //
    // v3 recovery action (v1/v2's bare por_n pulses were proven placebo
    // on hw - the common-block draw is config-time state): each attempt
    // is reset-pulse -> full CSR-sequence replay over the DRP (the same
    // writes device configuration performs; see csr_replay_rom) ->
    // reset-pulse -> normal bring-up. ~10 ms per attempt.
    localparam int WDOG_GRACE = 800_000_000;  // 8 s   @ clk100
    localparam int WDOG_PULSE = 200_000;      // 2 ms  @ clk100
    localparam int WDOG_RTIME = 5_000_000;    // 50 ms replay timeout
    localparam int WDOG_CAP   = 7;
    logic        wdog_force = 1'b0;
    logic        wdog_replay_req = 1'b0;
    logic        wdog_replay_ack;
    logic        wdog_ack_m = 1'b0, wdog_ack_s = 1'b0;
    logic [2:0]  wdog_count = 3'd0;
    // Timer = 1 ms prescaler + millisecond counter (timing campaign round
    // 2, 138B follow-up). The single 31-bit counter put a 31-bit
    // magnitude compare in series with its own increment/reset mux
    // (+0.06 ns at 100 MHz on the 138B die). All three thresholds are
    // exact multiples of 100 000 cycles, so "ms >= K/100000" trips on
    // precisely the same cycle "timer >= K" did; the ms counter saturates
    // (the old counter wrapped after 21 s, only reachable with the retry
    // budget exhausted, where nothing fires either way).
    localparam int WDOG_MS_CYCLES = 100_000;
    localparam int WDOG_GRACE_MS  = WDOG_GRACE / WDOG_MS_CYCLES;   // 8000
    localparam int WDOG_PULSE_MS  = WDOG_PULSE / WDOG_MS_CYCLES;   // 2
    localparam int WDOG_RTIME_MS  = WDOG_RTIME / WDOG_MS_CYCLES;   // 50
    logic [16:0] wdog_pre = 17'd0;
    logic [13:0] wdog_ms  = 14'd0;
    logic [1:0]  wdog_st = 2'd0;  // 0 idle, 1 pulse1, 2 replay, 3 pulse2
    task automatic wdog_tick();
        if (wdog_pre == 17'(WDOG_MS_CYCLES - 1)) begin
            wdog_pre <= 17'd0;
            if (wdog_ms != 14'h3FFF) wdog_ms <= wdog_ms + 14'd1;
        end else begin
            wdog_pre <= wdog_pre + 17'd1;
        end
    endtask
    // Blind sinks (monitor path) never yield a readable SINK_STATUS, so
    // "streaming" can never be observed - without this gate the watchdog
    // would tear down a healthy blind link every WDOG_GRACE forever
    // (observed on hw 2026-08-16: W cycling on the blind-monitor build).
    // Same for LINK_CHECK=0: no status reads once established, so K stays
    // 0 and a healthy held link would be pulsed off every WDOG_GRACE.
    wire wdog_streaming = (BLIND_SINK != 0 || LINK_CHECK != 1)
                        ? tx_link_established
                        : tx_link_established && (debug_sink[1:0] != 2'b00);
    always_ff @(posedge clk100) begin
        wdog_ack_m <= wdog_replay_ack;
        wdog_ack_s <= wdog_ack_m;
        case (wdog_st)
            2'd0: begin
                wdog_force      <= 1'b0;
                wdog_replay_req <= 1'b0;
                if (wdog_streaming) begin
                    begin wdog_pre <= 17'd0; wdog_ms <= 14'd0; end
                    wdog_count <= 3'd0;      // streaming - re-arm budget
                end else if (tx_powerup_channel != 4'b0000) begin
                    wdog_tick();
                    if (wdog_ms >= 14'(WDOG_GRACE_MS)
                        && wdog_count != 3'(WDOG_CAP)) begin
                        wdog_st    <= 2'd1;
                        begin wdog_pre <= 17'd0; wdog_ms <= 14'd0; end
                        wdog_count <= wdog_count + 3'd1;
                    end
                end
                // PHY unpowered (no partner): timer holds; nothing fires
            end
            2'd1: begin                      // reset pulse 1
                wdog_force <= 1'b1;
                wdog_tick();
                if (wdog_ms >= 14'(WDOG_PULSE_MS)) begin
                    wdog_st    <= 2'd2;
                    begin wdog_pre <= 17'd0; wdog_ms <= 14'd0; end
                end
            end
            2'd2: begin                      // PHY back up; CSR replay
                wdog_force      <= 1'b0;
                wdog_replay_req <= 1'b1;
                wdog_tick();
                if (wdog_ack_s || wdog_ms >= 14'(WDOG_RTIME_MS)) begin
                    wdog_st    <= 2'd3;
                    begin wdog_pre <= 17'd0; wdog_ms <= 14'd0; end
                end
            end
            default: begin                   // reset pulse 2, then re-arm
                wdog_replay_req <= 1'b0;
                wdog_force      <= 1'b1;
                wdog_tick();
                if (wdog_ms >= 14'(WDOG_PULSE_MS)) begin
                    wdog_st    <= 2'd0;
                    begin wdog_pre <= 17'd0; wdog_ms <= 14'd0; end
                end
            end
        endcase
    end
    logic [1:0] bank_powerup;
    assign bank_powerup = wdog_force ? 2'b00 : tx_powerup_channel[1:0];
    assign debug_wdog   = {(wdog_st != 2'd0), wdog_count};

    // ------------------------------------------------------------------
    // Vendor PHY
    // ------------------------------------------------------------------
`ifdef DP_VENDOR_XILINX_GTP
    transceiver_bank i_transceiver_bank(
        .mgmt_clk        (clk100),
        .powerup_channel (bank_powerup),
        .preemp_0p0      (preemp_0p0),
        .preemp_3p5      (preemp_3p5),
        .preemp_6p0      (preemp_6p0),
        .swing_0p4       (swing_0p4),
        .swing_0p6       (swing_0p6),
        .swing_0p8       (swing_0p8),
        .tx_running      (tx_running[1:0]),
        .refclk0         (refclk0),
        .refclk1         (refclk1),
        .tx_symbol_clk   (tx_symbol_clk),
        .tx_symbols      (tx_symbols),
        .gtptx_p         (dp_tx_lane_p),
        .gtptx_n         (dp_tx_lane_n)
    );
    assign tx_running[3:2] = 2'b00;
    assign serdes_status = 8'h3F;
    assign drp_dbg_data = 32'd0;
    assign drp_dbg_addr = 24'd0;
    assign drp_dbg_done = 1'b0;
    assign wdog_replay_ack = wdog_replay_req;  // no DRP on this PHY
    assign debug_wrusewd = 10'd0;
    assign afe_drp_clk = clk100; assign afe_drp_gnt = afe_drp_req; assign afe_drp_ready = 1'b1;
`elsif DP_VENDOR_GOWIN
    transceiver_bank_gowin #(.TX_PROBE(TX_PROBE),
                             // dump idx 24-29 read the die's own AFE
                             // registers, logical lane order
                             .AFE_DUMP_BASE0(AFE_LANE_BASE0),
                             .AFE_DUMP_BASE1(AFE_LANE_BASE1)) i_transceiver_bank(
        .mgmt_clk        (clk100),
        .powerup_channel (bank_powerup),
        .preemp_0p0      (preemp_0p0),
        .preemp_3p5      (preemp_3p5),
        .preemp_6p0      (preemp_6p0),
        .swing_0p4       (swing_0p4),
        .swing_0p6       (swing_0p6),
        .swing_0p8       (swing_0p8),
        .tx_running      (tx_running[1:0]),
        .refclk0         (refclk0),
        .refclk1         (refclk1),
        .tx_symbol_clk   (tx_symbol_clk),
        .tx_symbols      (tx_symbols),
        .gtptx_p         (dp_tx_lane_p),
        .gtptx_n         (dp_tx_lane_n),
        .serdes_status   (serdes_status),
        .dbg_idx         (drp_dbg_idx),
        .dbg_data        (drp_dbg_data),
        .dbg_addr        (drp_dbg_addr),
        .dbg_done        (drp_dbg_done),
        .replay_req      (wdog_replay_req),
        .replay_ack      (wdog_replay_ack),
        .afe_drp_clk     (afe_drp_clk),
        .afe_drp_req     (afe_drp_req),
        .afe_drp_gnt     (afe_drp_gnt),
        .afe_drp_addr    (afe_drp_addr),
        .afe_drp_wrdata  (afe_drp_wrdata),
        .afe_drp_wren    (afe_drp_wren),
        .afe_drp_ready   (afe_drp_ready),
        .dbg_wrusewd     (debug_wrusewd)
    );
    assign tx_running[3:2] = 2'b00;
`elsif DP_VENDOR_DPHY
    // External serializer (see port comment). All four lanes are handed
    // over; the board PHY owns 8b/10b, lane mapping and the D-PHY.
    assign tx_symbol_clk       = ext_symbol_clk;
    assign ext_tx_symbols      = tx_symbols;
    assign ext_powerup_channel = wdog_force ? 4'b0000 : tx_powerup_channel;
    assign tx_running          = ext_tx_running;
    assign dp_tx_lane_p  = '0;
    assign dp_tx_lane_n  = '1;
    assign serdes_status = {4'b0000, ext_tx_running};
    assign wdog_replay_ack = wdog_replay_req;  // no DRP on this PHY
    assign debug_wrusewd = 10'd0;
    assign afe_drp_clk = clk100; assign afe_drp_gnt = afe_drp_req; assign afe_drp_ready = 1'b1;
    assign drp_dbg_data = 32'd0;
    assign drp_dbg_addr = 24'd0;
    assign drp_dbg_done = 1'b0;
`else
    // Behavioural stub for simulation and lint: refclk0 stands in for the
    // recovered symbol clock, lanes are tied off, all channels report running
    // once powered.
    assign tx_symbol_clk = refclk0;
    assign tx_running    = tx_powerup_channel;
    assign dp_tx_lane_p  = '0;
    assign dp_tx_lane_n  = '1;
    assign serdes_status = 8'h3F;
    assign wdog_replay_ack = wdog_replay_req;  // no DRP in the sim stub
    assign debug_wrusewd = 10'd0;
    assign afe_drp_clk = clk100; assign afe_drp_gnt = afe_drp_req; assign afe_drp_ready = 1'b1;
    assign drp_dbg_data = 32'd0;
    assign drp_dbg_addr = 24'd0;
    assign drp_dbg_done = 1'b0;
`endif

endmodule
