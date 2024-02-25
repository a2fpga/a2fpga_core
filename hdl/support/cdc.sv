module cdc (
    input  clk,
    input  i,
    output o,
    output o_n,
    output o_posedge,   // o_posedge is asserted on the first posedge of i, o is still 0
    output o_negedge    // o_negedge is asserted on the first negedge of i, o is still 1
);

    reg [2:0] fifo = 3'b0  /*synthesis syn_keep=1*/;

    always @(posedge clk) fifo <= {fifo[1:0], i};

    assign o   = fifo[2];
    assign o_n = !fifo[2];
    assign o_posedge   = (fifo[2:1] == 2'b01);
    assign o_negedge = (fifo[2:1] == 2'b10);

endmodule
