module picosoc_sram #(
	parameter integer MEM_WORDS = 256
) 
(
	input resetn,
	input clk,
	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output reg [31:0] iomem_rdata,
	output reg iomem_ready,
	input [31:0] iomem_wdata
);

    wire ram_ready = iomem_valid && !iomem_ready && (iomem_addr < 4 * MEM_WORDS);

	always @(posedge clk)
		iomem_ready <= ram_ready;

    wire [3:0] wen = ram_ready ? iomem_wstrb : 4'b0;
    wire [21:0] addr = iomem_addr[23:2];

	reg [31:0] mem [0:MEM_WORDS-1];

	initial $readmemh("firmware.hex", mem);
	always @(posedge clk) begin
		iomem_rdata <= mem[addr];
		if (wen[0]) mem[addr][ 7: 0] <= iomem_wdata[ 7: 0];
		if (wen[1]) mem[addr][15: 8] <= iomem_wdata[15: 8];
		if (wen[2]) mem[addr][23:16] <= iomem_wdata[23:16];
		if (wen[3]) mem[addr][31:24] <= iomem_wdata[31:24];
	end


endmodule
