// tb_audio_out_gw5a.sv : the GW5A IIR filter against the GW2A one, both under
// audio_out, and the a2p25 configuration's response beside the Tang Nano one.
// Run: sim/audio_out/run.sh [+long]   (+long adds a 200 ms run through the
// DC blocker's start-up mute so the whole output path is compared too)
`timescale 1ns/1ps
module tb_audio_out_gw5a;
    localparam int  CLK_P = 54_000_000;          // a2p25 clk_logic
    localparam int  CLK_E = 27_000_000;          // Tang Nano clk_pixel
    localparam real TP = 1.0e9 / CLK_P;
    localparam real TE = 1.0e9 / CLK_E;
    logic clk = 0, clk_e = 0, reset = 1;
    always #(TP / 2.0) clk   = ~clk;
    always #(TE / 2.0) clk_e = ~clk_e;

    // the tops' tuning (boards/a2n20v2-Enhanced/hdl/top.sv; a2p25 flt_rate per its top)
    logic [31:0] frate_p = 32'd5_594_066, frate_e = 32'd7_056_000;
    logic [39:0] cx  = 40'd4258969;
    logic [7:0]  cx0 = 8'd3, cx1 = 8'd3, cx2 = 8'd1;
    logic [23:0] cy0 = -24'd6216759, cy1 = 24'd6143386, cy2 = -24'd2023767;

    // sample strobes: 54 MHz / 1125 = 48.000 kHz; 27 MHz / 612 = 44.118 kHz
    logic [15:0] core_l = 0, core_r = 0, core_e = 0;
    logic aud_p = 0, aud_e = 0;
    int   acc_p = 0, acc_e = 0;
    always @(posedge clk)   begin aud_p <= 0; if (acc_p == 1124) begin acc_p <= 0; aud_p <= 1; end else acc_p <= acc_p + 1; end
    always @(posedge clk_e) begin aud_e <= 0; if (acc_e == 611)  begin acc_e <= 0; aud_e <= 1; end else acc_e <= acc_e + 1; end

    logic [15:0] dut_l, dut_r, ref_l, ref_r, tn_l, tn_r;
    audio_out #(.CLK_RATE(CLK_P), .AUDIO_RATE(48000)) dut (
        .reset(reset), .clk(clk), .flt_rate(frate_p), .cx(cx), .cx0(cx0), .cx1(cx1), .cx2(cx2),
        .cy0(cy0), .cy1(cy1), .cy2(cy2), .is_signed(1'b1), .core_l(core_l), .core_r(core_r),
        .audio_clk(aud_p), .audio_l(dut_l), .audio_r(dut_r));
    audio_out_ref #(.CLK_RATE(CLK_P), .AUDIO_RATE(48000)) rf (
        .reset(reset), .clk(clk), .flt_rate(frate_p), .cx(cx), .cx0(cx0), .cx1(cx1), .cx2(cx2),
        .cy0(cy0), .cy1(cy1), .cy2(cy2), .is_signed(1'b1), .core_l(core_l), .core_r(core_r),
        .audio_clk(aud_p), .audio_l(ref_l), .audio_r(ref_r));
    audio_out_ref #(.CLK_RATE(CLK_E), .AUDIO_RATE(44100)) tn (
        .reset(reset), .clk(clk_e), .flt_rate(frate_e), .cx(cx), .cx0(cx0), .cx1(cx1), .cx2(cx2),
        .cy0(cy0), .cy1(cy1), .cy2(cy2), .is_signed(1'b1), .core_l(core_e), .core_r(core_e),
        .audio_clk(aud_e), .audio_l(tn_l), .audio_r(tn_r));

    // cycle-for-cycle comparison: the IIR outputs (before the DC blocker and
    // its start-up mute) and the module outputs
    int errors = 0, checks = 0;
    logic checking = 0;
    always @(posedge clk) if (checking) begin
        checks++;
        if (dut.acl !== rf.acl || dut.acr !== rf.acr || dut_l !== ref_l || dut_r !== ref_r) begin
            errors++;
            if (errors <= 10) $display("MISMATCH t=%0t iir %h/%h vs %h/%h  out %h/%h vs %h/%h",
                                       $time, dut.acl, dut.acr, rf.acl, rf.acr, dut_l, dut_r, ref_l, ref_r);
        end
    end

    // stimulus: random words held for random spans (1-bit speaker clicks,
    // AY steps and DOC samples all look like this to the filter)
    task automatic random_words(int cycles);
        int hold = 0;
        repeat (cycles) begin
            @(negedge clk);
            if (hold == 0) begin
                core_l = $urandom(); core_r = $urandom();
                hold = $urandom_range(0, 200);
            end else hold--;
        end
    endtask

    // stimulus: a tone on both configurations' inputs, held for 1 us per
    // sample the way the sources are (audio_out's input deglitcher wants a
    // value on two consecutive clocks; a sine moving every clock never gives
    // it one)
    real  tone_f = 1000.0;
    logic tone_on = 0;
    int   tone_div_p = 0, tone_div_e = 0;
    always @(negedge clk) if (tone_on) begin
        if (tone_div_p == 53) begin tone_div_p = 0; core_l = 16'($rtoi(20000.0 * $sin(6.283185307179586 * tone_f * $realtime * 1.0e-9))); core_r = core_l; end
        else tone_div_p++;
    end
    always @(negedge clk_e) if (tone_on) begin
        if (tone_div_e == 26) begin tone_div_e = 0; core_e = 16'($rtoi(20000.0 * $sin(6.283185307179586 * tone_f * $realtime * 1.0e-9))); end
        else tone_div_e++;
    end

    // peak of the IIR's own ce-rate output (out_l, before the sample-rate
    // register: 12 kHz is a quarter of 48 kHz and its sampled peak is phase-bound)
    task automatic measure(real f, output real gp, output real ge);
        int pk_p = 0, pk_e = 0, vp, ve;
        tone_f = f; tone_on = 1;
        repeat (int'(CLK_P * 0.004)) @(posedge clk);           // settle 4 ms
        fork
            begin repeat (int'(CLK_P * 0.003)) begin @(posedge clk);   vp = $signed(dut.IIR_filter.out_l); if (vp < 0) vp = -vp; if (vp > pk_p) pk_p = vp; end end
            begin repeat (int'(CLK_E * 0.003)) begin @(posedge clk_e); ve = $signed(tn.IIR_filter_ref.out_l); if (ve < 0) ve = -ve; if (ve > pk_e) pk_e = ve; end end
        join
        gp = 20.0 * $log10(pk_p / 20000.0);
        ge = 20.0 * $log10(pk_e / 20000.0);
    endtask

    // filter ce rate of each configuration over 10 ms
    int ce_p = 0, ce_e = 0;
    always @(posedge clk)   if (dut.flt_ce) ce_p++;
    always @(posedge clk_e) if (tn.flt_ce)  ce_e++;

    function automatic real freq_at(int k);
        case (k)
            0: return 1000.0;  1: return 2000.0;  2: return 5000.0;  3: return 8000.0;  4: return 10000.0;
            5: return 12000.0; 6: return 15000.0; 7: return 20000.0; 8: return 30000.0; default: return 50000.0;
        endcase
    endfunction
    real gp, ge, gp_prev, gp_1k, f;
    real rate_p, rate_e;
    int  i, fails = 0;
    initial begin
        repeat (20) @(posedge clk);
        reset = 0;
        repeat (20) @(posedge clk);

        // 1. equality, the tops' coefficients, 60 ms of random words
        checking = 1;
        random_words(int'(CLK_P * 0.060));
        $display("equality (tops' coefficients): %0d cycles, %0d mismatches", checks, errors);

        // 2. equality with coefficients that exercise the hi-nibble and bit-35
        //    terms of the input product and random tap coefficients (the filter
        //    itself may be unstable; only the agreement matters)
        checking = 0; @(negedge clk);
        cx = {4'b1011, 1'b1, 35'($urandom())}; cy0 = $urandom(); cy1 = $urandom(); cy2 = $urandom();
        cx0 = 8'h85; cx1 = 8'h03; cx2 = 8'h81;
        @(negedge clk); checking = 1;
        random_words(int'(CLK_P * 0.010));
        cx = {4'b0111, 1'b0, 35'($urandom())}; cy0 = $urandom(); cy1 = $urandom(); cy2 = $urandom();
        random_words(int'(CLK_P * 0.010));
        $display("equality (hi-nibble / bit-35 / random cy): %0d cycles, %0d mismatches", checks, errors);
        checking = 0; @(negedge clk);
        cx = 40'd4258969; cx0 = 8'd3; cx1 = 8'd3; cx2 = 8'd1;
        cy0 = -24'd6216759; cy1 = 24'd6143386; cy2 = -24'd2023767;
        // the unstable coefficients leave the 40-bit taps wrapped, a state the
        // stable filter cannot unwind (it would never arise with constants):
        // reset, as power-up does
        reset = 1; repeat (4) @(posedge clk); reset = 0;

        // 3. ce rate of each configuration
        core_l = 0; core_r = 0;
        repeat (int'(CLK_P * 0.002)) @(posedge clk);
        ce_p = 0; ce_e = 0;
        repeat (int'(CLK_P * 0.010)) @(posedge clk);
        rate_p = ce_p / 0.010; rate_e = ce_e / 0.010;
        $display("filter ce: a2p25 %0.4f MHz  Tang Nano %0.4f MHz  (ratio %0.4f)", rate_p / 1e6, rate_e / 1e6, rate_p / rate_e);
        if (rate_p / rate_e < 0.997 || rate_p / rate_e > 1.003) begin fails++; $display("FAIL: ce rates differ"); end

        // 4. frequency response, both configurations
        $display("   f (Hz)   a2p25 (dB)   Tang Nano (dB)");
        gp_prev = 100.0;
        for (i = 0; i < 10; i++) begin
            f = freq_at(i);
            measure(f, gp, ge);
            $display("  %7.0f   %8.2f     %8.2f", f, gp, ge);
            if (gp - ge > 0.5 || ge - gp > 0.5) begin fails++; $display("FAIL: configurations differ at %0.0f Hz", f); end
            if (gp > gp_prev + 0.3) begin fails++; $display("FAIL: not a low-pass at %0.0f Hz", f); end
            gp_prev = gp;
            if (i == 0) gp_1k = gp;
        end
        if (gp_1k < -1.5 || gp_1k > 1.5) begin fails++; $display("FAIL: 1 kHz gain %0.2f dB", gp_1k); end
        if (gp > gp_1k - 20.0) begin fails++; $display("FAIL: 50 kHz only %0.2f dB under 1 kHz", gp_1k - gp); end
        tone_on = 0;

        // 5. optional: through the DC blocker's start-up mute (8192 strobes = 171 ms)
        if ($test$plusargs("long")) begin
            tone_f = 1000.0; tone_on = 1; checking = 1;
            repeat (int'(CLK_P * 0.200)) @(posedge clk);
            $display("long run: %0d cycles, %0d mismatches, out %0d (ref %0d)", checks, errors, $signed(dut_l), $signed(ref_l));
            tone_on = 0; checking = 0;
        end

        if (errors == 0 && fails == 0) $display("AUDIO OUT RESULT: PASS");
        else $display("AUDIO OUT RESULT: FAIL (%0d mismatches, %0d checks failed)", errors, fails);
        $finish;
    end
endmodule
