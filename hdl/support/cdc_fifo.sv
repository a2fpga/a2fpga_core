module cdc_fifo 
#(
    parameter WIDTH = 8
)
(
    input  clk,
    input  [WIDTH-1:0] i,
    output [WIDTH-1:0] o
);

    reg [WIDTH-1:0] fifo[3] /*synthesis syn_keep=1*/;

    always @(posedge clk) begin
        fifo[0] <= i;
        fifo[1] <= fifo[0];
        fifo[2] <= fifo[1];
    end

    assign o   = fifo[2];

endmodule
