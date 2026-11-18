//  3-tap IIR filter for 2 channels -- Arora V (GW5A) arithmetic.
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
//  Same filter as hdl/support/iir_filter.v: structure, coefficients, ports and
//  module names are identical, so hdl/sound/audio_out.v instantiates IIR_filter
//  and DC_blocker from whichever of the two files the project lists (the GW2A
//  Tang Nano projects list iir_filter.v, the GW5A projects list this one). What
//  differs is how the two wide products are written.
//
//  The GW2A file writes a 16 x 40 and a 37 x 24 signed multiply and leaves the
//  mapping to synthesis. The Arora V DSP block offers MULT12X12 and MULT27X36
//  only, both with signed operands (UG305 4.1), and GowinSynthesis did not turn
//  those oversize products into a working filter on the GW5A (a2p25, 2025-09;
//  a hand-split copy then lived under boards/a2mega and boards/a2p25 until
//  2026-11-18 -- it sign-extended the low ten bits of y, a sub-LSB error, and
//  was built but never carried by a shipped top). Here every product is a
//  signed <= 27 x <= 36 piece, so each one is a single MULT27X36 (two DSP
//  blocks) or folds away as a constant, and the result is bit-exact with the
//  GW2A file -- proven by sim/audio_out/run.sh, which runs both under
//  audio_out side by side:
//
//      inp(16) * cx(40) = inp * s(cx[35:0])
//                       + ( inp * s(cx[39:36]) + (cx[35] ? inp : 0) ) << 36
//          s() reads the bits as signed; the carry term undoes the sign the
//          low 36 bits were given. For the coefficients the tops pass
//          (cx < 2^23) the whole second line is a constant zero.
//      y(37) * cy(24)   = ( y[36:10] * cy ) << 10  +  {1'b0, y[9:0]} * cy
//          the low ten bits are unsigned, hence the zero sign bit.
//
//  Can be converted to 2-tap (coeff_x2 = 0, coeff_y2 = 0) or 1-tap (coeff_x1,2 = 0, coeff_y1,2 = 0)
//
module IIR_filter
#(
	parameter use_params = 1,                     // set to 1 to use following parameters, 0 for input port variables.
	parameter stereo   =  1,                      // 0 for mono (input_l)

	parameter coeff_x  =  0.00000774701983513660, // Base gain value for X. Float. Range: 0.0 ... 0.999(9)
	parameter coeff_x0 =  3,                      // Gain scale factor for X0. Integer. Range -7 ... +7
	parameter coeff_x1 =  3,                      // Gain scale factor for X1. Integer. Range -7 ... +7
	parameter coeff_x2 =  1,                      // Gain scale factor for X2. Integer. Range -7 ... +7
	parameter coeff_y0 = -2.96438150626551080000, // Coefficient for Y0. Float. Range -3.999(9) ... 3.999(9)
	parameter coeff_y1 =  2.92939452735121100000, // Coefficient for Y1. Float. Range -3.999(9) ... 3.999(9)
	parameter coeff_y2 = -0.96500747158831091000  // Coefficient for Y2. Float. Range -3.999(9) ... 3.999(9)
)
(
	input         clk,
	input         reset,

	input         ce,        // must be double of calculated rate for stereo!
	input         sample_ce, // desired output sample rate

	input  [39:0] cx,
	input   [7:0] cx0,
	input   [7:0] cx1,
	input   [7:0] cx2,
	input  [23:0] cy0,
	input  [23:0] cy1,
	input  [23:0] cy2,

	input  [15:0] input_l,  input_r,  // signed samples
	output [15:0] output_l, output_r  // signed samples
);

localparam  [39:0] pcoeff_x  = 40'($realtobits(coeff_x  * 40'h8000000000));
localparam  [31:0] pcoeff_y0 = 32'($realtobits(coeff_y0 * 24'h200000));
localparam  [31:0] pcoeff_y1 = 32'($realtobits(coeff_y1 * 24'h200000));
localparam  [31:0] pcoeff_y2 = 32'($realtobits(coeff_y2 * 24'h200000));

wire [39:0] vcoeff    = use_params ? pcoeff_x        : cx;
wire [23:0] vcoeff_y0 = use_params ? pcoeff_y0[23:0] : cy0;
wire [23:0] vcoeff_y1 = use_params ? pcoeff_y1[23:0] : cy1;
wire [23:0] vcoeff_y2 = use_params ? pcoeff_y2[23:0] : cy2;

reg [15:0] inp, inp_m;

// inp * vcoeff in Arora V pieces (see the header): one MULT27X36 plus a
// 16 x 4 correction that is a constant for the tops' coefficients.
wire signed [26:0] mx_a = {{11{inp[15]}}, inp};
wire signed [35:0] mx_b = vcoeff[35:0];
wire signed [62:0] mx_p /* synthesis syn_use_dsp = 1 */ = mx_a * mx_b;
wire signed [3:0]  mx_hi4 = vcoeff[39:36];
wire signed [20:0] mx_hi  = $signed(inp) * mx_hi4 + (vcoeff[35] ? $signed({{5{inp[15]}}, inp}) : 21'sd0);
wire        [59:0] inp_mul = mx_p[59:0] + {{3{mx_hi[20]}}, mx_hi, 36'd0};

wire [39:0] x = inp_mul[59:20];
wire [39:0] y = x + tap0;

wire [39:0] tap0;
wire [39:0] tap1;
wire [39:0] tap2;
reg        ch = 0;

iir_filter_tap iir_tap_0
(
	.clk(clk),
	.reset(reset),
	.ce(ce),
	.ch(ch),
	.cx(use_params ? coeff_x0[7:0] : cx0),
	.cy(vcoeff_y0),
	.x(x),
	.y(y),
	.z(tap1),
	.tap(tap0)
);

iir_filter_tap iir_tap_1
(
	.clk(clk),
	.reset(reset),
	.ce(ce),
	.ch(ch),
	.cx(use_params ? coeff_x1[7:0] : cx1),
	.cy(vcoeff_y1),
	.x(x),
	.y(y),
	.z(tap2),
	.tap(tap1)
);

iir_filter_tap iir_tap_2
(
	.clk(clk),
	.reset(reset),
	.ce(ce),
	.ch(ch),
	.cx(use_params ? coeff_x2[7:0] : cx2),
	.cy(vcoeff_y2),
	.x(x),
	.y(y),
	.z(40'd0),
	.tap(tap2)
);

wire [15:0] y_clamp = (~y[39] & |y[38:35]) ? 16'h7FFF : (y[39] & ~&y[38:35]) ? 16'h8000 : y[35:20];

reg [15:0] out_l, out_r, out_m;
always @(posedge clk) if (ce) begin
	if(!stereo) begin
		ch    <= 0;
		inp   <= input_l;
		out_l <= y_clamp;
		out_r <= y_clamp;
	end
	else begin
		ch <= ~ch;
		if(ch) begin
			out_m <= y_clamp;
			inp   <= inp_m;
		end
		else begin
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

module iir_filter_tap
(
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

// y[36:0] * cy in Arora V pieces (see the header): the high 27 bits and the
// low 10 bits (unsigned, hence the zero sign bit) each against the 24-bit
// coefficient; two MULT27X36.
wire signed [26:0] my_hi = y[36:10];
wire signed [10:0] my_lo = {1'b0, y[9:0]};
wire signed [23:0] my_c  = cy;
wire signed [50:0] p_hi /* synthesis syn_use_dsp = 1 */ = my_hi * my_c;
wire signed [34:0] p_lo /* synthesis syn_use_dsp = 1 */ = my_lo * my_c;
wire        [60:0] y_mul = {p_hi, 10'd0} + {{26{p_lo[34]}}, p_lo};

function [39:0] x_mul;
	input [39:0] x;
begin
	x_mul = 0;
	if(cx[0]) x_mul =  x_mul + {{4{x[39]}}, x[39:4]};
	if(cx[1]) x_mul =  x_mul + {{3{x[39]}}, x[39:3]};
	if(cx[2]) x_mul =  x_mul + {{2{x[39]}}, x[39:2]};
	if(cx[7]) x_mul = ~x_mul; //cheap NEG
end
endfunction

// Gowin syntax
reg [39:0] intreg[2] /* synthesis syn_ramstyle="registers" */;
always @(posedge clk, posedge reset) begin
	if(reset) {intreg[0],intreg[1]} <= 80'd0;
	else if(ce) intreg[ch] <= x_mul(x) - y_mul[60:21] + z;
end

assign tap = intreg[ch];

endmodule

// simplified IIR 1-tap.
module DC_blocker
(
	input         clk,
	input         ce, // 48/96 KHz
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
