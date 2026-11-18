// core_audio_mix.sv : one channel of the board's audio mix, saturating
//
// Sums the DOC (signed 16-bit), the SuperSprite/SSP, the Mockingboard and
// the Apple speaker into one signed 16-bit sample. Until 2026-11-17 every
// top did this inline as a plain 16-bit add with the Mockingboard at << 3,
// which put its peak (three 8-bit AY channels summed to 10 bits) at 6,120 of
// 32,767, -14.6 dB, next to a full-scale DOC; on a IIgs board that is quiet
// (Nox Archaist beside Arkanoid, ed). The shift is now a parameter, default
// << 4 (peak 12,240, 37 % FS, +6 dB), and the sum is 19 bits wide and
// clamped, so a loud DOC under a speaker click or a Mockingboard chord can
// clip but never wrap.
//
// Peak levels with the defaults: DOC +-32,767; Mockingboard 12,240; SSP
// 8,184; speaker 4,096. The three unsigned sources add a positive offset
// (24,520 at their joint peak), as before.
//
module core_audio_mix #(
    parameter int MB_SHIFT  = 4,     // Mockingboard: 10-bit sum of three AY channels
    parameter int SSP_SHIFT = 3,     // SuperSprite / SSP: 10-bit
    parameter int SPK_BIT   = 12     // Apple speaker: one bit, toggles this value
) (
    input  logic signed [15:0] sg_i,   // DOC 5503 (signed)
    input  logic        [9:0]  ssp_i,
    input  logic        [9:0]  mb_i,
    input  logic               spk_i,
    output logic signed [15:0] out_o
);
    logic signed [18:0] s_sg, s_ssp, s_mb, s_spk, sum;
    always_comb begin
        s_sg  = {{3{sg_i[15]}}, sg_i};
        s_ssp = $signed({9'b0, ssp_i}) <<< SSP_SHIFT;
        s_mb  = $signed({9'b0, mb_i})  <<< MB_SHIFT;
        s_spk = spk_i ? (19'sd1 <<< SPK_BIT) : 19'sd0;
        sum   = s_sg + s_ssp + s_mb + s_spk;
        if (sum > 19'sd32767)       out_o = 16'sd32767;
        else if (sum < -19'sd32768) out_o = -16'sd32768;
        else                        out_o = sum[15:0];
    end
endmodule
