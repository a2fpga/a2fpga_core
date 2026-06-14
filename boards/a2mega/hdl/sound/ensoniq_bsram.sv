//
// 64KB Ensoniq sound RAM using BSRAM
//
// (c) 2025 Ed Anuff <ed@a2fpga.com>
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
// Description:
//
// 64KB Ensoniq sound RAM backed by on-chip BSRAM instead of DDR3.
// Port A: write (from GLU/Apple II bus) - clk_logic domain
// Port B: read (from DOC5503) - clk_logic domain
// 16384 x 32-bit = 64KB = 512 Kbit = ~24 BSRAM18K blocks
//

module ensoniq_bsram (
    input  wire        clk,

    // Write port (GLU)
    input  wire        wr_en,
    input  wire [13:0] wr_addr,    // 16K x 32-bit words
    input  wire [31:0] wr_data,
    input  wire [3:0]  wr_byte_en, // Per-byte write enable

    // Read port (DOC)
    input  wire        rd_en,
    input  wire [13:0] rd_addr,
    output reg  [31:0] rd_data,
    output reg         rd_valid    // 1-cycle delayed read valid
);

    // Inferred BSRAM - Gowin will map to block RAM
    reg [31:0] mem [0:16383];

    // Write port with byte enables
    always @(posedge clk) begin
        if (wr_en) begin
            if (wr_byte_en[0]) mem[wr_addr][7:0]   <= wr_data[7:0];
            if (wr_byte_en[1]) mem[wr_addr][15:8]  <= wr_data[15:8];
            if (wr_byte_en[2]) mem[wr_addr][23:16] <= wr_data[23:16];
            if (wr_byte_en[3]) mem[wr_addr][31:24] <= wr_data[31:24];
        end
    end

    // Read port - registered output for BSRAM inference
    always @(posedge clk) begin
        rd_valid <= rd_en;
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
