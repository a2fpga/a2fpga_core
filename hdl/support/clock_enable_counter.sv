module clock_enable_counter #(
    parameter SIZE = 8
) (
    input clk,
    input ce,
    output reg [SIZE-1:0] q
);

    always @(posedge clk) begin
        if (ce) begin
            q <= q + 1'b1;
        end
    end

endmodule
