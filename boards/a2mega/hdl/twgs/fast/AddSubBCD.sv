//============================================================================
//  65C816 CPU core — fast variant (S7 accelerator exploration)
//
//  Binary/BCD add-subtract.  Rung 1 replaced the gate-level ripple with a
//  behavioral add; rung 2d:
//    * the byte carry from a parallel low-byte chain (native, no XOR level);
//    * decimal-add carries by a flat generate/propagate lookahead
//      (two LUT levels after the nibble sums instead of a 4-deep chain);
//    * (S7) each decimal digit formed for both values of its carry in.
//  Bit-exact with P65C816_AddSubBCD for every input (tb_addsub_eq.sv).
//
//  Original per-nibble semantics (T = A + B2 + cin, B2 = ADD ? B : ~B):
//    binary (BCD=0):     S = T mod 16,            cout = T >= 16
//    BCD add (ADD=1):    cout = T >= 10,           S = (T + 6*cout) mod 16
//    BCD sub (ADD=0):    cout = T >= 16 (binary),  S = (T - 6*~cout) mod 16
//  VO is the two's-complement overflow of the UNCORRECTED nibble sum at
//  bit 7 / bit 15 with that nibble's actual carry-in.  CO = carry out of
//  nibble 1 (8-bit) or nibble 3 (16-bit).
//
//  Copyright (c) srg320 -- original VHDL implementation
//  Copyright (c) 2026 Alan Steremberg -- Verilog conversion and IIgs changes
//  GPL-3.0 (see README.md in hdl/twgs/65C816).
//============================================================================
module F65C816_AddSubBCD
  (
   input [15:0]  A,
   input [15:0]  B,
   input         CI,
   input         ADD,
   input         BCD,
   input         w16,
   output [15:0] S,
   output        CO,
   output        VO
   );

   // ---- binary path.  One unbroken 17-bit carry chain for the sum and the
   // word carry; the byte carry comes from a short parallel chain over the low
   // byte (co8 native, no XOR recovery, no extra level).  The two nibble
   // carries the decimal-subtract correction needs are recovered by XOR —
   // that path is off the critical cone.  (A guard-bit-per-nibble version was
   // tried: GowinSynthesis splits the chain at every guard, ~1 ns of routing
   // per split, 23 levels — see the exploration log, rung 2d.)
   wire [15:0] B2  = B ^ {16{~ADD}};
   wire [16:0] bin17 = {1'b0, A} + {1'b0, B2} + {16'd0, CI};
   wire [8:0]  lo9   = {1'b0, A[7:0]} + {1'b0, B2[7:0]} + {8'd0, CI};
   wire [3:0]  s0 = bin17[3:0], s1 = bin17[7:4], s2 = bin17[11:8], s3 = bin17[15:12];
   wire        bc1 = bin17[4] ^ A[4] ^ B2[4];      // carry into nibble 1
   wire        bc2 = lo9[8];                        // carry out of the low byte
   wire        bc3 = bin17[12] ^ A[12] ^ B2[12];   // carry into nibble 3
   wire        bc4 = bin17[16];
   wire [15:0] bin = bin17[15:0];

   // ---- BCD subtract: binary result, -6 on every nibble whose carry out is 0
   wire [15:0] sub_s = { s3 + (bc4 ? 4'd0 : 4'd10),
                         s2 + (bc3 ? 4'd0 : 4'd10),
                         s1 + (bc2 ? 4'd0 : 4'd10),
                         s0 + (bc1 ? 4'd0 : 4'd10) };

   // ---- BCD add: flat decimal carry lookahead; each digit is formed for both values
   // of its carry in, from the digit sum alone, and the carry selects (S7: the stock
   // order - add the carry, then add 6 - was two more adders behind the lookahead)
   wire [4:0] t0 = {1'b0, A[3:0]}   + {1'b0, B[3:0]};
   wire [4:0] t1 = {1'b0, A[7:4]}   + {1'b0, B[7:4]};
   wire [4:0] t2 = {1'b0, A[11:8]}  + {1'b0, B[11:8]};
   wire [4:0] t3 = {1'b0, A[15:12]} + {1'b0, B[15:12]};
   wire g0 = (t0 >= 5'd10), p0 = (t0 == 5'd9);
   wire g1 = (t1 >= 5'd10), p1 = (t1 == 5'd9);
   wire g2 = (t2 >= 5'd10), p2 = (t2 == 5'd9);
   wire g3 = (t3 >= 5'd10), p3 = (t3 == 5'd9);
   wire dc1 = g0 | (p0 & CI);
   wire dc2 = g1 | (p1 & g0) | (p1 & p0 & CI);
   wire dc3 = g2 | (p2 & g1) | (p2 & p1 & g0) | (p2 & p1 & p0 & CI);
   wire dc4 = g3 | (p3 & g2) | (p3 & p2 & g1) | (p3 & p2 & p1 & g0) | (p3 & p2 & p1 & p0 & CI);
   // {bit 3 of the uncorrected digit (t + c) mod 16, the digit: + 6 when t + c >= 10}
   function automatic [4:0] dig(input [4:0] t, input c);
      logic [5:0] w;
      logic [3:0] u;
      begin
         w = {1'b0, t} + {5'd0, c};
         u = w[3:0];
         dig = {u[3], (w >= 6'd10) ? (u + 4'd6) : u};
      end
   endfunction
   wire [4:0] d0 = CI  ? dig(t0, 1'b1) : dig(t0, 1'b0);
   wire [4:0] d1 = dc1 ? dig(t1, 1'b1) : dig(t1, 1'b0);
   wire [4:0] d2 = dc2 ? dig(t2, 1'b1) : dig(t2, 1'b0);
   wire [4:0] d3 = dc3 ? dig(t3, 1'b1) : dig(t3, 1'b0);
   wire [15:0] add_s = {d3[3:0], d2[3:0], d1[3:0], d0[3:0]};

   // ---- select
   wire bcd_add = BCD & ADD;
   wire bcd_sub = BCD & ~ADD;
   assign S = bcd_add ? add_s : bcd_sub ? sub_s : bin;

   wire co8  = bcd_add ? dc2 : bc2;
   wire co16 = bcd_add ? dc4 : bc4;
   assign CO = w16 ? co16 : co8;

   wire s7  = bcd_add ? d1[4] : s1[3];
   wire s15 = bcd_add ? d3[4] : s3[3];
   wire vo8  = ~(A[7]  ^ B2[7])  & (A[7]  ^ s7);
   wire vo16 = ~(A[15] ^ B2[15]) & (A[15] ^ s15);
   assign VO = w16 ? vo16 : vo8;

endmodule
