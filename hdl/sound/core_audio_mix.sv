// core_audio_mix.sv : one channel of the board's audio mix, saturating
//
// Sums the DOC (signed 16-bit), the SuperSprite/SSP, the Mockingboard and
// the Apple speaker into one signed 16-bit sample. Until 2026-11-17 every
// top did this inline as a plain 16-bit add with the Mockingboard at << 3,
// which put its peak (three 8-bit AY channels summed to 10 bits) at 6,120 of
// 32,767, -14.6 dB, next to a full-scale DOC; on a IIgs board that is quiet
// (Nox Archaist beside Arkanoid, ed). The sum is 19 bits wide and clamped,
// so a loud DOC under a speaker click or a Mockingboard chord can clip but
// never wrap.
//
// The Mockingboard gain is a live 2-bit select, mb_gain_i: shift = 3 + gain,
// so 0 = the historical << 3, 1 = << 4, 2 = << 5 (full chord 24,480, 75 % FS;
// the power-up default on boards with the control), 3 = << 6 (a full chord
// at volume 15 on all three channels clips, the sum saturates). The AY's
// logarithmic DAC puts ordinary music 8-20 dB under the channel peak, which
// a real card's amplifier makes up; the capture of Nox Archaist at << 4
// peaked at -31 dBFS against DOC titles at 0 dBFS (2026-11-17), hence the
// select, picked by ear on one bitstream instead of a build per guess.
//
// Peak levels at gain 2: DOC +-32,767; Mockingboard 24,480; SSP 8,184;
// speaker 4,096. The three unsigned sources add a positive offset, as before.
//
module core_audio_mix #(
    parameter int SSP_SHIFT = 3,     // SuperSprite / SSP: 10-bit
    parameter int SPK_BIT   = 12     // Apple speaker: one bit, toggles this value
) (
    input  logic signed [15:0] sg_i,   // DOC 5503 (signed)
    input  logic        [9:0]  ssp_i,
    input  logic        [9:0]  mb_i,   // Mockingboard: 10-bit sum of three AY channels
    input  logic        [1:0]  mb_gain_i,  // Mockingboard shift = 3 + mb_gain_i
    input  logic               spk_i,
    output logic signed [15:0] out_o
);
    logic signed [18:0] s_sg, s_ssp, s_mb, s_spk, sum;
    always_comb begin
        s_sg  = {{3{sg_i[15]}}, sg_i};
        s_ssp = $signed({9'b0, ssp_i}) <<< SSP_SHIFT;
        s_mb  = $signed({9'b0, mb_i})  <<< (3 + {3'b0, mb_gain_i});
        s_spk = spk_i ? (19'sd1 <<< SPK_BIT) : 19'sd0;
        sum   = s_sg + s_ssp + s_mb + s_spk;
        if (sum > 19'sd32767)       out_o = 16'sd32767;
        else if (sum < -19'sd32768) out_o = -16'sd32768;
        else                        out_o = sum[15:0];
    end
endmodule
