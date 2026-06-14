module sustained_high #(
    parameter int N = 4
) (
    input  logic clk,
    input  logic i,
    output logic o
);

    logic [N-1:0] sreg /* synthesis syn_keep=1 */;

    always_ff @(posedge clk) begin
        sreg <= {sreg[N-2:0], i};
    end

    assign o = &sreg;

endmodule