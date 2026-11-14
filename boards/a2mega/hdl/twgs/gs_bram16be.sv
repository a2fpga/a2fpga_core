// A2MEGA - IIgs CPU socket accelerator: a block RAM of 1K x 16 with a write
// enable for each byte
//
// (c) 2026 Ed Anuff <ed@a2fpga.com>
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description
// -----------
// gs_accel's memories of sixteen-byte lines (NEAR_LINE) are made of these: one
// block for each 16-bit word of a line, a write of the core's being one byte
// of one of them.  Written as an array with two write enables, GowinSynthesis
// makes TWO blocks of it, one for each byte (318 of the 138K's 340 on the
// first build); the primitive has the byte enables - the low address bits of
// its write port - and is one block.  So the primitive is instantiated, and
// simulation has the array.  Semi-dual port: a write port, a read port whose
// output register is loaded when re_i is high and holds otherwise; the
// memory powers up all zeros.  A read in the clk of a write to the same word
// is not defined (nothing that uses these makes one it relies on).
//   The read port is the word's (ra_i[10:1]; q_o), or with RD8 a byte's: the
// primitive's two ports need not be of one width, and its read port as 2K x 8
// gives byte ra_i[0] of word ra_i[10:1] in q_o[7:0] with no mux behind it.
//
module gs_bram16be #(
    parameter bit RD8 = 1'b0
) (
    input  logic        clk,
    input  logic [9:0]  wa_i,
    input  logic [1:0]  we_i,            // per byte
    input  logic [15:0] wd_i,
    input  logic        re_i,
    input  logic [10:0] ra_i,
    output logic [15:0] q_o
);
`ifdef VERILATOR
    logic [15:0] mem [0:1023];
    initial begin for (int i = 0; i < 1024; i++) mem[i] = 16'h0000; q_o = 16'h0000; end
    always_ff @(posedge clk) begin
        if (we_i[0]) mem[wa_i][7:0]  <= wd_i[7:0];
        if (we_i[1]) mem[wa_i][15:8] <= wd_i[15:8];
    end
    always_ff @(posedge clk) if (re_i) q_o <= RD8 ? {8'h00, mem[ra_i[10:1]][8*ra_i[0] +: 8]} : mem[ra_i[10:1]];
`else
    wire [31:0] do_w;
    assign q_o = do_w[15:0];
    // (a 16-bit port: the word is AD[13:4], and a write's AD[1:0] are its byte enables;
    // an 8-bit read port: the byte is AD[13:3])
    SDPB #(.READ_MODE(1'b0), .BIT_WIDTH_0(16), .BIT_WIDTH_1(RD8 ? 8 : 16), .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
           .RESET_MODE("SYNC")) bram (
        .DO(do_w), .DI({16'h0000, wd_i}), .BLKSELA(3'b000), .BLKSELB(3'b000),
        .ADA({wa_i, 2'b00, we_i}), .ADB(RD8 ? {ra_i, 3'b000} : {ra_i[10:1], 4'b0000}),
        .CLKA(clk), .CEA(|we_i), .CLKB(clk), .CEB(re_i), .OCE(1'b1), .RESET(1'b0)
    );
`endif
endmodule
