module dual_set_reg #(
    parameter SIZE = 8
) (
    input clk,
    input a_set,
    input [SIZE-1:0] a,
    input b_set,
    input [SIZE-1:0] b,
    output reg [SIZE-1:0] q
);

reg a_set_prev, b_set_prev;

always @(posedge clk) begin
    a_set_prev <= a_set;
    b_set_prev <= b_set;

    if (!a_set_prev && a_set) begin
        q <= a;
    end

    if (!b_set_prev && b_set) begin
        q <= b;
    end
end

endmodule
