module cdc (
    input  clk,
    input  i,
    output o,
    output o_n,
    output o_posedge,   // o_posedge is asserted on the first posedge of i, o is still 0
    output o_negedge    // o_negedge is asserted on the first negedge of i, o is still 1
);

    reg i_sync1, i_sync2;
    reg [2:0] i_debounce;
    reg i_stable;

    always @(posedge clk) begin
        // Step 1: Synchronize slow clock to fast clock domain
        i_sync1 <= i;
        i_sync2 <= i_sync1;

        // Step 2: Debounce slow clock
        i_debounce <= {i_debounce[1:0], i_sync2};
        if (i_debounce == 3'b111)
            i_stable <= 1'b1;
        else if (i_debounce == 3'b000)
            i_stable <= 1'b0;
    end

    reg [1:0] fifo = 2'b0  /*synthesis syn_keep=1*/;

    always @(posedge clk) fifo <= {fifo[0], i_stable};

    assign o   = fifo[1];
    assign o_n = !fifo[1];
    assign o_posedge   = (fifo == 2'b01);
    assign o_negedge = (fifo == 2'b10);

endmodule
