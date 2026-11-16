// audio_sample_cdc.sv : stereo sample word, clk_src -> clk_dst, two ways
//
// The board tops used to carry the 16-bit left/right sample bus from the
// core clock (54 MHz) into the DP pixel clock (148.5 MHz) through a plain
// pair of flops per bit. The two clocks come from different PLLs and the
// SDC declares them asynchronous, so nothing times that path: when the
// source changes within the per-bit skew window of a pixel-clock edge, some
// bits capture the new value and others the old. A sample taken from such a
// cycle is a word the source never produced. Consumed at the 48 kHz strobe
// it is a pop; with high bits involved, a loud one. The rate depends on the
// placement's skew and on the PLL phase, not on logic, which is why it
// differs build to build and card to card. (a2p25 Arkanoid, 2026-11-16.)
//
// This module keeps the RAW path (so the behaviour can be measured) and adds
// a SAFE path (request/acknowledge mailbox), selectable at run time, plus the
// instrumentation that tells them apart:
//
//   raw  : raw0 <= src; raw1 <= raw0 (the original double flop)
//   safe : the strobe toggles a request; synchronised into clk_src it latches
//          {r,l} into a mailbox register and toggles an acknowledge; that,
//          synchronised back into clk_dst, copies the mailbox into `safe`.
//          Round trip ~100 ns against a 20.8 us sample period, so `safe`
//          is the sample from the previous strobe, stable at this one.
//
// Detector (raw path): a clean source value lasts one clk_src period,
// 18.5 ns, and is therefore captured by at least two consecutive clk_dst
// edges (6.7 ns). A captured value that differs from BOTH its neighbours
// lasted one cycle only and cannot be a source value: it is a mixed capture.
// No parity or reference copy needed, and no false positives while
// T_src >= 2 T_dst.
//
// dbg (all clk_dst, all saturating, cleared while `clear` is high):
//   [15:0]  mixed captures on the raw path, any cycle
//   [31:16] mixed captures that landed on a strobe = pops the raw path
//           produced (or would have, when the safe path is selected)
//   [47:32] consumed samples whose |delta| vs the previous consumed sample
//           exceeded JUMP_THRESH on L or R (the selected path, i.e. what the
//           sink hears): the symptom counter
//   [55:48] max |delta| seen on the consumed stream, high byte
//   [63:56] {6'b0, clear, sel_safe} as seen in clk_dst
//
module audio_sample_cdc #(
    parameter int W           = 16,
    parameter int JUMP_THRESH = 2048
) (
    input  logic          clk_src,
    input  logic [W-1:0]  l_src,
    input  logic [W-1:0]  r_src,

    input  logic          clk_dst,
    input  logic          strobe_dst,   // one-clk_dst sample strobe (clk_audio)
    input  logic          sel_safe,     // 1 = feed the mailbox word; quasi-static, any domain
    input  logic          clear,        // hold the counters at zero; quasi-static, any domain

    output logic [W-1:0]  l_dst,        // valid when strobe_dst is high
    output logic [W-1:0]  r_dst,
    output logic [63:0]   dbg
);
    localparam int WW = 2 * W;

    // ---------------- control, into clk_dst ----------------
    logic sel_m = 1'b0, sel_s = 1'b0, clr_m = 1'b0, clr_s = 1'b0;
    always_ff @(posedge clk_dst) begin
        sel_m <= sel_safe;  sel_s <= sel_m;
        clr_m <= clear;     clr_s <= clr_m;
    end

    // ---------------- raw path (the original double flop) ----------------
    logic [WW-1:0] raw0 = '0, raw1 = '0, raw2 = '0;
    always_ff @(posedge clk_dst) begin
        raw0 <= {r_src, l_src};
        raw1 <= raw0;
        raw2 <= raw1;
    end
    // raw1 is the word the consumer sees this cycle; its neighbours are raw2
    // (the capture before) and raw0 (the capture after).
    wire mixed_w = (raw1 != raw2) && (raw1 != raw0);

    // ---------------- safe path (request / acknowledge mailbox) ----------------
    logic req_t = 1'b0;                      // clk_dst
    always_ff @(posedge clk_dst) if (strobe_dst) req_t <= ~req_t;

    logic req_m = 1'b0, req_s = 1'b0, req_last = 1'b0;   // clk_src
    logic [WW-1:0] mbox = '0;
    logic ack_t = 1'b0;
    always_ff @(posedge clk_src) begin
        req_m    <= req_t;
        req_s    <= req_m;
        req_last <= req_s;
        if (req_s != req_last) begin
            mbox  <= {r_src, l_src};
            ack_t <= ~ack_t;
        end
    end

    logic ack_m = 1'b0, ack_s = 1'b0, ack_last = 1'b0;   // clk_dst
    logic [WW-1:0] safe = '0;
    always_ff @(posedge clk_dst) begin
        ack_m    <= ack_t;
        ack_s    <= ack_m;
        ack_last <= ack_s;
        if (ack_s != ack_last) safe <= mbox;   // mbox stable since ack toggled
    end

    // ---------------- selection ----------------
    wire [WW-1:0] sel_word_w = sel_s ? safe : raw1;
    assign l_dst = sel_word_w[W-1:0];
    assign r_dst = sel_word_w[WW-1:W];

    // ---------------- instrumentation ----------------
    logic [15:0] mixed_cnt = '0, mixed_consumed_cnt = '0, jump_cnt = '0;
    logic [W-1:0] max_delta = '0;
    logic [WW-1:0] prev_consumed = '0;

    function automatic logic [W-1:0] absdiff(input logic [W-1:0] a, input logic [W-1:0] b);
        logic signed [W:0] d;
        d = $signed({a[W-1], a}) - $signed({b[W-1], b});
        if (d < 0) d = -d;
        // |d| <= 2^W - 1 fits W bits after the sign is dropped
        absdiff = d[W-1:0];
    endfunction

    wire [W-1:0] dl_w = absdiff(sel_word_w[W-1:0],  prev_consumed[W-1:0]);
    wire [W-1:0] dr_w = absdiff(sel_word_w[WW-1:W], prev_consumed[WW-1:W]);
    wire [W-1:0] dmax_w = (dl_w > dr_w) ? dl_w : dr_w;

    always_ff @(posedge clk_dst) begin
        if (clr_s) begin
            mixed_cnt          <= '0;
            mixed_consumed_cnt <= '0;
            jump_cnt           <= '0;
            max_delta          <= '0;
        end else begin
            if (mixed_w && mixed_cnt != 16'hFFFF)
                mixed_cnt <= mixed_cnt + 16'd1;
            if (mixed_w && strobe_dst && mixed_consumed_cnt != 16'hFFFF)
                mixed_consumed_cnt <= mixed_consumed_cnt + 16'd1;
            if (strobe_dst) begin
                if (dmax_w > W'(JUMP_THRESH) && jump_cnt != 16'hFFFF)
                    jump_cnt <= jump_cnt + 16'd1;
                if (dmax_w > max_delta)
                    max_delta <= dmax_w;
            end
        end
        if (strobe_dst) prev_consumed <= sel_word_w;
    end

    assign dbg = {6'b0, clr_s, sel_s,            // [63:56]
                  max_delta[W-1 -: 8],           // [55:48]
                  jump_cnt,                      // [47:32]
                  mixed_consumed_cnt,            // [31:16]
                  mixed_cnt};                    // [15:0]
endmodule
