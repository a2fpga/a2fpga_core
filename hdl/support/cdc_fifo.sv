module cdc_fifo 
#(
    parameter WIDTH = 8,
    parameter DEPTH = 3
)
(
    input  clk,
    input  [WIDTH-1:0] i,
    output [WIDTH-1:0] o
);

    reg [WIDTH-1:0] fifo[DEPTH-1:0] /*synthesis syn_keep=1*/;

    always @(posedge clk) begin
        // Shift the FIFO contents
        fifo <= {fifo[DEPTH-2:0], i};
    end

    // Output the last element in the FIFO
    assign o   = fifo[DEPTH-1];

endmodule
