//  3-tap IIR filter for 2 channels. 
//  Copyright (C) 2020 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//  Can be converted to 2-tap (coeff_x2 = 0, coeff_y2 = 0) or 1-tap (coeff_x1,2 = 0, coeff_y1,2 = 0)

module IIR_filter
#(
    parameter use_params = 1,
    parameter stereo   = 1,

    parameter coeff_x  =  0.00000774701983513660,
    parameter coeff_x0 =  3,
    parameter coeff_x1 =  3,
    parameter coeff_x2 =  1,
    parameter coeff_y0 = -2.96438150626551080000,
    parameter coeff_y1 =  2.92939452735121100000,
    parameter coeff_y2 = -0.96500747158831091000
)
(
    input         clk,
    input         reset,

    input         ce,
    input         sample_ce,

    input  [39:0] cx,
    input   [7:0] cx0,
    input   [7:0] cx1,
    input   [7:0] cx2,
    input  [23:0] cy0,
    input  [23:0] cy1,
    input  [23:0] cy2,

    input  [15:0] input_l,  input_r,
    output [15:0] output_l, output_r
);

localparam  [39:0] pcoeff_x  = 40'($realtobits(coeff_x  * 40'h8000000000));
localparam  [31:0] pcoeff_y0 = 32'($realtobits(coeff_y0 * 24'h200000));
localparam  [31:0] pcoeff_y1 = 32'($realtobits(coeff_y1 * 24'h200000));
localparam  [31:0] pcoeff_y2 = 32'($realtobits(coeff_y2 * 24'h200000));

wire [39:0] vcoeff    = use_params ? pcoeff_x        : cx;
wire [23:0] vcoeff_y0 = use_params ? pcoeff_y0[23:0] : cy0;
wire [23:0] vcoeff_y1 = use_params ? pcoeff_y1[23:0] : cy1;
wire [23:0] vcoeff_y2 = use_params ? pcoeff_y2[23:0] : cy2;

// ----- DSP-friendly input multiply: (signed 16) * (signed 40) -> 60 bits
reg  signed [15:0] inp;

wire signed [26:0] A27 = { {11{inp[15]}}, inp };     // 27-bit signed (fits MULT27*)
wire signed [35:0] B36 = { {16{vcoeff[35]}}, vcoeff[35:0] }; // lower 36 of coeff
wire signed [59:0] P0  /* synthesis syn_use_dsp = 1 */ = $signed(A27) * $signed(B36); // infer MULT27X36

// Upper nibble (bits 39:36) of coeff.
// Use a 12x12 where possible: split as 2x components (inp[11:0] * coeff_hi[11:0]) and (inp[15:12] * coeff_hi[11:0])
wire signed [3:0]  coeff_hi4 = vcoeff[39:36];
wire signed [11:0] coeff_hi12 = { {8{coeff_hi4[3]}}, coeff_hi4 }; // extend 4 -> 12

wire signed [11:0] inp_lo12 = { { (12-16){inp[15]} }, inp }[11:0];
wire signed [3:0]  inp_hi4  = inp[15:12];
wire signed [11:0] inp_hi12 = { {8{inp_hi4[3]}}, inp_hi4 };

wire signed [23:0] P1_lo12 /* synthesis syn_use_dsp = 1 */ = $signed(inp_lo12) * $signed(coeff_hi12); // infer MULT12X12
wire signed [23:0] P1_hi12 /* synthesis syn_use_dsp = 1 */ = $signed(inp_hi12)  * $signed(coeff_hi12); // infer MULT12X12

// Align: high nibble contributes at bit position 36 of B, so overall shift by 36
// P1_lo12 is 12x12 at bit 0 of A low 12; P1_hi12 multiplies the upper 4 of A -> shift by 12
wire signed [59:0] P1 = ( { { (60-24-36){P1_lo12[23]} }, P1_lo12, {36{1'b0}} } ) +
                        ( { { (60-24-36-12){P1_hi12[23]} }, P1_hi12, {36+12{1'b0}} } );

wire signed [59:0] inp_mul = P0 + P1;

wire [39:0] x = inp_mul[59:20];
wire [39:0] y = x + tap0;

wire [39:0] tap0;
wire [39:0] tap1;
wire [39:0] tap2;
reg        ch = 0;

iir_filter_tap iir_tap_0(
    .clk(clk), .reset(reset), .ce(ce), .ch(ch),
    .cx(use_params ? coeff_x0[7:0] : cx0),
    .cy(vcoeff_y0),
    .x(x), .y(y), .z(tap1), .tap(tap0)
);

iir_filter_tap iir_tap_1(
    .clk(clk), .reset(reset), .ce(ce), .ch(ch),
    .cx(use_params ? coeff_x1[7:0] : cx1),
    .cy(vcoeff_y1),
    .x(x), .y(y), .z(tap2), .tap(tap1)
);

iir_filter_tap iir_tap_2(
    .clk(clk), .reset(reset), .ce(ce), .ch(ch),
    .cx(use_params ? coeff_x2[7:0] : cx2),
    .cy(vcoeff_y2),
    .x(x), .y(y), .z(40'd0), .tap(tap2)
);

wire [15:0] y_clamp = (~y[39] & |y[38:35]) ? 16'h7FFF :
                      (y[39] & ~&y[38:35]) ? 16'h8000 : y[35:20];

reg [15:0] out_l, out_r, out_m;
reg [15:0] inp_m;
always @(posedge clk) if (ce) begin
    if(!stereo) begin
        ch    <= 0;
        inp   <= input_l;
        out_l <= y_clamp;
        out_r <= y_clamp;
    end else begin
        ch <= ~ch;
        if(ch) begin
            out_m <= y_clamp;
            inp   <= inp_m;
        end else begin
            out_l <= out_m;
            out_r <= y_clamp;
            inp   <= input_l;
            inp_m <= input_r;
        end
    end
end

reg [31:0] out;
always @(posedge clk) if (sample_ce) out <= {out_l, out_r};

assign {output_l, output_r} = out;

endmodule


module iir_filter_tap(
    input         clk,
    input         reset,
    input         ce,
    input         ch,
    input   [7:0] cx,
    input  [23:0] cy,
    input  [39:0] x,
    input  [39:0] y,
    input  [39:0] z,
    output [39:0] tap
);

// ----- DSP-friendly 37x24 multiply: y[36:0] * cy[23:0]
wire signed [36:0] y_s  = y[36:0];
wire signed [23:0] cy_s = cy;

// Part 1: 27x36 using y[36:10] (27 bits) * sign-extended cy to 36 bits
wire signed [26:0] y_hi27 = y_s[36:10];
wire signed [35:0] cy_36  = { {12{cy_s[23]}}, cy_s }; // 36-bit signed
wire signed [62:0] P_hi   /* synthesis syn_use_dsp = 1 */ = $signed({y_hi27}) * $signed(cy_36); // infer MULT27X36
// Align P_hi to the full 61-bit product domain: y_hi27 sits at bit<<10 in y
wire signed [60:0] P_hi_aligned = P_hi[60:0] <<< 10;

// Part 2: 10x24 using two 12x12: (y_lo10 * cy_lo12) + ((y_lo10 * cy_hi12) << 12)
wire signed [9:0]  y_lo10   = y_s[9:0];
wire signed [11:0] y_lo12   = { {2{y_lo10[9]}}, y_lo10 };
wire signed [11:0] cy_lo12  = cy_s[11:0];
wire signed [11:0] cy_hi12  = cy_s[23:12];

wire signed [23:0] P_lo0 /* synthesis syn_use_dsp = 1 */ = $signed(y_lo12) * $signed(cy_lo12); // MULT12X12
wire signed [23:0] P_lo1 /* synthesis syn_use_dsp = 1 */ = $signed(y_lo12) * $signed(cy_hi12); // MULT12X12

wire signed [36:0] P_lo_comb = {{13{P_lo1[23]}}, P_lo1, 12'd0} + {{13{P_lo0[23]}}, P_lo0};

// Align Part 2 by <<0 (since y_lo is at bit 0)
wire signed [60:0] P_lo_aligned = {{24{P_lo_comb[36]}}, P_lo_comb};

// Final exact 61-bit product
wire signed [60:0] y_mul = P_hi_aligned + P_lo_aligned;

// ----- x_mul stays as in original (shift-add by cx bits)
function [39:0] x_mul;
    input [39:0] x;
begin
    x_mul = 0;
    if(cx[0]) x_mul =  x_mul + {{4{x[39]}}, x[39:4]};
    if(cx[1]) x_mul =  x_mul + {{3{x[39]}}, x[39:3]};
    if(cx[2]) x_mul =  x_mul + {{2{x[39]}}, x[39:2]};
    if(cx[7]) x_mul = ~x_mul;
end
endfunction

reg [39:0] intreg[2] /* synthesis syn_ramstyle="registers" */;
always @(posedge clk, posedge reset) begin
    if(reset) {intreg[0],intreg[1]} <= 80'd0;
    else if(ce) intreg[ch] <= x_mul(x) - y_mul[60:21] + z;
end

assign tap = intreg[ch];

endmodule


module DC_blocker(
    input         clk,
    input         ce,
    input         mute,
    input  [15:0] din,
    output [15:0] dout
);

wire [39:0] x  = {din[15], din, 23'd0};
wire [39:0] x0 = x - {{10{x[39]}}, x[39:10]};
wire [39:0] y1 = y - {{09{y[39]}}, y[39:09]};
wire [39:0] y0 = x0 - x1 + y1;

reg  [39:0] x1, y;
always @(posedge clk) if(ce) begin
    x1 <= x0;
    y  <= ^y0[39:38] ? {{2{y0[39]}},{38{y0[38]}}} : y0;
end

assign dout = mute ? 16'd0 : y[38:23];

endmodule
