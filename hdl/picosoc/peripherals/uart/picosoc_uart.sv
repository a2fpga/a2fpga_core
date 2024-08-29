module picosoc_uart #(
	parameter int CLOCK_SPEED_HZ = 50_000_000,
	parameter int BAUD_RATE = 115200
)
(
	input resetn,
	input clk,
	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output [31:0] iomem_rdata,
	output iomem_ready,
	input [31:0] iomem_wdata,
	input  uart_rx_i,
    output uart_tx_o
);

	wire        simpleuart_reg_div_sel = iomem_valid && (iomem_addr == 32'h 0200_0004);
	wire [31:0] simpleuart_reg_div_do;

	wire        simpleuart_reg_dat_sel = iomem_valid && (iomem_addr == 32'h 0200_0008);
	wire [31:0] simpleuart_reg_dat_do;
	wire        simpleuart_reg_dat_wait;

	assign iomem_ready = simpleuart_reg_div_sel || (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait);

	assign iomem_rdata = simpleuart_reg_div_sel ? simpleuart_reg_div_do :
			simpleuart_reg_dat_sel ? simpleuart_reg_dat_do : 
			32'h 0000_0000;

	simpleuart #( 
		.DEFAULT_DIV(CLOCK_SPEED_HZ / BAUD_RATE)
	) simpleuart (
		.clk(clk),
		.resetn(resetn),

		.ser_tx(uart_tx_o),
		.ser_rx(uart_rx_i),

		.reg_div_we(simpleuart_reg_div_sel ? iomem_wstrb : 4'b 0000),
		.reg_div_di(iomem_wdata),
		.reg_div_do(simpleuart_reg_div_do),

		.reg_dat_we(simpleuart_reg_dat_sel ? iomem_wstrb[0] : 1'b 0),
		.reg_dat_re(simpleuart_reg_dat_sel && !iomem_wstrb),
		.reg_dat_di(iomem_wdata),
		.reg_dat_do(simpleuart_reg_dat_do),
		.reg_dat_wait(simpleuart_reg_dat_wait)
	);

endmodule
