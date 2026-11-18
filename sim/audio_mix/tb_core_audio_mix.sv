// tb_core_audio_mix.sv : the saturating audio mix against a reference model.
// Run: sim/audio_mix/run.sh
`timescale 1ns/1ps
module tb_core_audio_mix;
    logic signed [15:0] sg; logic [9:0] ssp, mb; logic spk; logic [1:0] g;
    logic signed [15:0] out;
    core_audio_mix dut (.sg_i(sg), .ssp_i(ssp), .mb_i(mb), .mb_gain_i(g), .spk_i(spk), .out_o(out));

    function automatic int ref_mix(int s, int p, int m, int k, int gg);
        int v = s + p * 8 + m * (8 << gg) + (k ? 4096 : 0);
        if (v > 32767) v = 32767; if (v < -32768) v = -32768;
        return v;
    endfunction

    int errors = 0, i, exp, clipped = 0;
    task automatic check(string what);
        begin
            #1 exp = ref_mix(sg, ssp, mb, spk, g);
            if (out !== 16'(exp)) begin
                errors++; if (errors < 10) $display("FAIL %s: sg=%0d ssp=%0d mb=%0d spk=%0d -> %0d, expected %0d", what, sg, ssp, mb, spk, out, exp);
            end
            if (exp == 32767 || exp == -32768) clipped++;
        end
    endtask

    initial begin
        // Mockingboard alone, all three AY channels at full volume, each gain step
        sg = 0; ssp = 0; mb = 10'd765; spk = 0;
        g = 0; check("MB peak g0"); if (out !== 16'sd6120)  begin errors++; $display("FAIL: g0 peak = %0d", out); end
        g = 1; check("MB peak g1"); if (out !== 16'sd12240) begin errors++; $display("FAIL: g1 peak = %0d", out); end
        g = 2; check("MB peak g2"); if (out !== 16'sd24480) begin errors++; $display("FAIL: g2 peak = %0d", out); end
        g = 3; check("MB peak g3"); if (out !== 16'sd32767) begin errors++; $display("FAIL: g3 peak = %0d (should clip)", out); end
        g = 2;
        // the old wrap case: full-scale DOC plus a Mockingboard chord and a speaker click
        sg = 16'sd32767; ssp = 0; mb = 10'd765; spk = 1; check("DOC+MB+spk clamp");
        if (out !== 16'sd32767) begin errors++; $display("FAIL: did not clamp high (%0d)", out); end
        sg = -16'sd32768; ssp = 0; mb = 0; spk = 0; check("DOC floor");
        sg = -16'sd32768; ssp = 10'd1023; mb = 10'd1023; spk = 1; check("floor + all offsets");
        sg = 16'sd20000; ssp = 10'd1023; mb = 10'd1023; spk = 1; check("sum just over");
        for (i = 0; i < 200000; i++) begin
            sg = $urandom(); ssp = $urandom(); mb = $urandom(); spk = $urandom(); g = $urandom();
            check("random");
        end
        $display("random cases 200000, clipped %0d", clipped);
        if (errors == 0) $display("AUDIO MIX RESULT: PASS"); else $display("AUDIO MIX RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
