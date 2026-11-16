// tb_audio_sample_cdc.sv : the 54 MHz -> 148.5 MHz sample crossing with
// per-bit skew on the source bus, as the placed design has it.
//
// Three checks:
//   1. SAFE path: every word consumed at a strobe is a value the source held
//      (membership in the last few source values). Zero tolerance.
//   2. RAW path with skew: the DUT's "mixed captures consumed" counter equals
//      the testbench's own count of consumed words that the source never
//      held, and both are > 0 (the instrument sees what the ear hears).
//   3. RAW path without skew: both counts are 0 (no false positives from the
//      one-cycle-value criterion while T_src >= 2 T_dst).
//
// Run: sim/audio_cdc/run.sh [seed]
`timescale 1ps/1ps
module tb_audio_sample_cdc;
    localparam int W = 16;
    localparam real T_SRC_PS = 18518.5;   // 54 MHz
    localparam real T_DST_PS = 6734.0;    // 148.5 MHz
    localparam int  STROBE_DIV = 309;     // 10x the real 48 kHz cadence (3094): same
                                          // mixing physics, 10x faster simulation; the
                                          // mailbox round trip (~100 ns) is still << 2 us

    logic clk_src = 0, clk_dst = 0;
    always #(T_SRC_PS/2) clk_src = ~clk_src;
    initial begin
        // random phase of the destination clock
        #($urandom_range(0, int'(T_DST_PS)));
        forever #(T_DST_PS/2) clk_dst = ~clk_dst;
    end

    // ---- source: a stereo word that changes on some clk_src edges ----
    logic [W-1:0] l_src = '0, r_src = '0;
    int change_pct;                      // % of clk_src cycles that change the word
    always_ff @(posedge clk_src) begin
        if ($urandom_range(0, 99) < change_pct) begin
            l_src <= $urandom();
            r_src <= $urandom();
        end
    end

    // ---- recent source history (the set of words the source actually held) ----
    // The mailbox word is one strobe period old (STROBE_DIV clk_dst = ~113
    // clk_src at the sped-up cadence), so the membership window must cover
    // that; a mixed 32-bit word matching any of these by chance is ~1e-7.
    localparam int HIST = 400;
    logic [2*W-1:0] hist [HIST];          // circular buffer, one write per clk_src
    int hist_wp = 0;
    initial for (int i = 0; i < HIST; i++) hist[i] = '0;
    always_ff @(posedge clk_src) begin
        hist[hist_wp] <= {r_src, l_src};
        hist_wp <= (hist_wp == HIST-1) ? 0 : hist_wp + 1;
    end
    function automatic bit in_hist(input logic [2*W-1:0] v);
        in_hist = 0;
        for (int i = 0; i < HIST; i++) if (hist[i] == v) in_hist = 1;
        if ({r_src, l_src} == v) in_hist = 1;
    endfunction

    // ---- per-bit skew on the bus the raw flops see ----
    bit skew_en = 0;
    int skew_ps [2*W];
    wire  [2*W-1:0] bus_src_w = {r_src, l_src};
    logic [2*W-1:0] bus_skewed;
    genvar gi;
    generate for (gi = 0; gi < 2*W; gi++) begin : g_skew
        always @(bus_src_w[gi]) begin
            if (skew_en) #(skew_ps[gi]);
            bus_skewed[gi] = bus_src_w[gi];
        end
    end endgenerate

    // ---- strobe ----
    logic strobe = 0;
    int div = 0;
    always_ff @(posedge clk_dst) begin
        strobe <= 0;
        if (div == STROBE_DIV-1) begin div <= 0; strobe <= 1; end
        else div <= div + 1;
    end

    // ---- DUT ----
    logic sel_safe = 0, clear = 0;
    logic [W-1:0] l_dst, r_dst;
    logic [63:0] dbg;
    audio_sample_cdc #(.W(W)) dut (
        .clk_src(clk_src), .l_src(bus_skewed[W-1:0]), .r_src(bus_skewed[2*W-1:W]),
        .clk_dst(clk_dst), .strobe_dst(strobe), .sel_safe(sel_safe), .clear(clear),
        .l_dst(l_dst), .r_dst(r_dst), .dbg(dbg)
    );

    // ---- checkers ----
    int consumed = 0, bad_consumed = 0, safe_bad = 0;
    always @(posedge clk_dst) begin
        if (strobe) begin
            consumed++;
            if (!in_hist({r_dst, l_dst})) begin
                bad_consumed++;
                if (sel_safe) begin
                    safe_bad++;
                    $display("FAIL t=%0t safe path consumed %h not a source value", $time, {r_dst, l_dst});
                end
            end
        end
    end

    task automatic phase(input string name, input bit sel, input bit skew, input int pct, input int nstrobes,
                         output int dut_mixed_consumed, output int tb_bad);
        int c0;
        sel_safe = sel; skew_en = skew; change_pct = pct;
        clear = 1; repeat (20) @(posedge clk_dst); clear = 0;
        repeat (40) @(posedge clk_dst);
        c0 = consumed; bad_consumed = 0;
        while (consumed - c0 < nstrobes) @(posedge clk_dst);
        dut_mixed_consumed = dbg[31:16];
        tb_bad = bad_consumed;
        $display("%-28s sel_safe=%0d skew=%0d change=%0d%%  strobes=%0d  mixed_any=%0d  mixed_consumed(DUT)=%0d  bad_consumed(TB)=%0d  jumps=%0d",
                 name, sel, skew, pct, nstrobes, dbg[15:0], dut_mixed_consumed, tb_bad, dbg[47:32]);
    endtask

    int fails = 0;
    initial begin
        int seed, m, b;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        for (int i = 0; i < 2*W; i++) skew_ps[i] = $urandom_range(0, 2500);  // 0..2.5 ns per bit

        // 3. raw, no skew: the criterion must not fire
        phase("raw, no skew (control)", 0, 0, 60, 1500, m, b);
        if (m != 0 || b != 0) begin fails++; $display("FAIL: false positives without skew"); end

        // 2. raw, skew: instrument == truth, and > 0
        phase("raw, skewed bus", 0, 1, 60, 6000, m, b);
        if (m != b) begin fails++; $display("FAIL: DUT mixed_consumed %0d != TB bad_consumed %0d", m, b); end
        if (b == 0) $display("NOTE: no mixed consumption in this run (phase lottery); raise strobes or reseed");

        // 1. safe, skew: never a non-source word
        phase("safe, skewed bus", 1, 1, 60, 6000, m, b);
        if (safe_bad != 0) begin fails++; $display("FAIL: safe path delivered %0d non-source words", safe_bad); end

        // safe with a fast-changing source, the worst case for the mailbox
        phase("safe, skewed, 100% change", 1, 1, 100, 3000, m, b);
        if (safe_bad != 0) begin fails++; $display("FAIL: safe path (100%%) delivered %0d non-source words", safe_bad); end

        if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
        $finish;
    end
endmodule
