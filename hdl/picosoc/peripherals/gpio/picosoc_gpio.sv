
/*
 *
 */
module picosoc_gpio #(
	parameter int CLOCK_SPEED_HZ = 50_000_000
) (
	input resetn,
	input clk,
	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output reg [31:0] iomem_rdata,
	output reg iomem_ready,
	input [31:0] iomem_wdata,
	input button,
	output reg led,
	output ws2812);

    localparam ADDR_LED = 		8'h00;
    localparam ADDR_RGB = 		8'h04;
    localparam ADDR_BUTTON = 	8'h08;

	reg [23:0] rgb;

	always @(posedge clk) begin
      	iomem_ready <= 0;
        iomem_rdata <= 32'b0;
        if (iomem_valid) begin
            if (|iomem_wstrb) begin
                case (iomem_addr[7:2])
                    ADDR_LED[7:2]: led <= iomem_wdata[0];
                    ADDR_RGB[7:2]: rgb <= iomem_wdata[23:0];
                    default: ;
                endcase
            end else begin
                case (iomem_addr[7:2])
                    ADDR_BUTTON[7:2]: iomem_rdata <= {31'b0, button};
                    default: ;
                endcase
            end
            iomem_ready <= 1;
        end
	end

	ws2812 #(.CLK_FRE(CLOCK_SPEED_HZ)) ws2812_inst (
		.clk(clk),
		.rgb(rgb),
		.WS2812(ws2812)
	);
	
endmodule
