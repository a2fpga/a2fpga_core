module rising_edge (
    input clk,
    input i,
    output reg o
);

reg prev;

always @(posedge clk) begin
    prev <= i;

    if (!prev && i) begin
        o <= 1'b1;
    end else begin
        o <= 1'b0;
    end
end

endmodule
