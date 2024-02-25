module fast_cache #(
	parameter DATA_WIDTH = 32,
	parameter ADDR_WIDTH = 24,
	parameter OFFSET_BITS = 2,
	parameter INDEX_BITS = 10,  // 2^10 = 1024 lines
	parameter TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS,
	parameter CACHE_DEPTH = 1 << INDEX_BITS  // 1024 lines
) (
    input clk,
    input we,
    input [ADDR_WIDTH-1:0] addr_i,  
    output [DATA_WIDTH-1:0] data_o,
	input [DATA_WIDTH-1:0] data_i,
    output hit
);

    // Cache storage
    reg [DATA_WIDTH+TAG_BITS:0] cache_data[CACHE_DEPTH-1:0];
    reg [DATA_WIDTH+TAG_BITS:0] current_line;

    // Address decomposition
    wire [TAG_BITS-1:0] tag = addr_i[ADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];
    wire [INDEX_BITS-1:0] index = addr_i[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    // Offset not used in this simple example

    // Read operation
    always @(posedge clk) begin
        if (we) begin
            cache_data[index] <= {1'b1, tag, data_i};
            current_line <= {1'b1, tag, data_i};
        end else begin
            current_line <= cache_data[index];
        end
    end

    assign hit = current_line[DATA_WIDTH+TAG_BITS:DATA_WIDTH] == {1'b1, tag};
    assign data_o = current_line[DATA_WIDTH-1:0];

endmodule
