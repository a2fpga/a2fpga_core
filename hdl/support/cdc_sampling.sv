module cdc_sampling #(
    parameter WIDTH = 8
)(
    input  clk_fast,
    input  clk_slow,
    input  rst_n,
    input  [WIDTH-1:0] data_in,
    output reg [WIDTH-1:0] data_out
);

    // Register in fast domain to avoid metastability on data
    reg [WIDTH-1:0] data_reg;
    always @(posedge clk_fast or negedge rst_n) begin
        if (!rst_n)
            data_reg <= {WIDTH{1'b0}};
        else
            data_reg <= data_in;
    end

    // Two-FF synchronizer in slow domain
    reg [WIDTH-1:0] sync_ff1, sync_ff2;
    always @(posedge clk_slow or negedge rst_n) begin
        if (!rst_n) begin
            sync_ff1 <= {WIDTH{1'b0}};
            sync_ff2 <= {WIDTH{1'b0}};
        end else begin
            sync_ff1 <= data_reg;  // May be metastable
            sync_ff2 <= sync_ff1;  // Stable after this stage
        end
    end

    assign data_out = sync_ff2;

endmodule