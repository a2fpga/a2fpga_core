module cdc (
    input  logic clk,
    input  logic i,
    output logic o,
    output logic o_n,
    output logic o_posedge,
    output logic o_negedge
);

    logic [2:0] sync = 3'b0 /* synthesis syn_keep=1 */;

    always_ff @(posedge clk) 
        sync <= {sync[1:0], i};  // Correct: shifts all 3 stages

    assign o         = sync[2];
    assign o_n       = ~sync[2];
    assign o_posedge = (sync[2:1] == 2'b01);
    assign o_negedge = (sync[2:1] == 2'b10);

endmodule