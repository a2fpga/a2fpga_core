//
// PicoSoC SDRAM Interface
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
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
// Exposes the SDRAM to the PicoSoC as a memory-mapped device
//

module picosoc_sdram
(
    a2bus_if.slave a2bus_if,
	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output wire [31:0] iomem_rdata,
	output wire iomem_ready,
	input [31:0] iomem_wdata,
    input iomem_instr,
	input [31:0] iomem_la_addr,
    sdram_port_if.client mem_if
);

    wire cache_hit;
    wire [31:0] cache_data;

    wire mem_wr = iomem_valid & (iomem_wstrb != 4'h0);
    wire mem_rd = iomem_valid & (iomem_wstrb == 4'h0) & ~(iomem_instr & cache_hit);
    assign mem_if.addr = iomem_addr[22:2];
    assign mem_if.data = iomem_wdata;
    assign mem_if.wr = mem_wr;
    assign mem_if.rd = mem_rd;
    assign mem_if.byte_en = iomem_wstrb;
    assign iomem_rdata = iomem_instr ? cache_data : mem_if.q;
    assign iomem_ready = iomem_instr ? iomem_valid & cache_hit : mem_if.ready;

    fast_cache #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(21),
        .OFFSET_BITS(0),
        .INDEX_BITS(6)
    ) instr_cache (
        .clk(a2bus_if.clk_logic),
        .we(iomem_instr & mem_if.ready),
        .addr_i(iomem_la_addr[22:2]),
        .data_o(cache_data),
        .data_i(mem_if.q),
        .hit(cache_hit)
    );

endmodule
