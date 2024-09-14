//
// PicoSoC peripheral to interface the PicoSoC to the A2FPGA core
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
// Exposes the A2FPGA core to the PicoSoC as memory-mapped I/O
//


module picosoc_a2slots (
	input clk,
	input resetn,

	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output reg [31:0] iomem_rdata,
	output reg iomem_ready,
	input [31:0] iomem_wdata,

    a2bus_if.slave a2bus_if,
    slotmaker_config_if.controller slotmaker_config_if
);

    wire slotmaker_ready = iomem_valid && !iomem_ready;

    always @(posedge clk)
		iomem_ready <= slotmaker_ready;

    assign slotmaker_config_if.slot <= iomem_addr[2:0];
    assign slotmaker_config_if.card_i <= iomem_wdata[7:0];
    assign slotmaker_config_if.wr = slotmaker_ready && |iomem_wstrb;

    always @(posedge clk)
        iomem_rdata <= {24'b0, slotmaker_config_if.card_o};

endmodule
