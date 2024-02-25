module pulse_crossing
#(
    parameter N = 3   // Stretch factor, default value set to 3 (2X clock diff + 1)
)
(
    input reset,
    input wire clk_src,     // Source clock
    input wire clk_dst,     // Destination clock
    input wire pulse_src,   // Pulse in source domain
    output reg pulse_dst   // Pulse in destination domain
);

    reg pulse_stretched;
    reg [N-1:0] pulse_fifo = 0;
    always @(posedge clk_src) begin
        if (reset)
            pulse_fifo <= 0;
        else begin
            pulse_fifo <= {pulse_fifo[N-2:0], pulse_src};  // Load the LSB
            pulse_stretched <= pulse_src | |pulse_fifo;  // register the stretched pulse
        end
    end

    // Stage 2: Synchronize the stretched pulse into the destination domain
    reg [2:0] sync_fifo = 3'b0;
    
    always @(posedge clk_dst) begin
        if (reset)
            sync_fifo <= 3'b0;
        else begin
            sync_fifo <= {sync_fifo[1:0], pulse_stretched};
            pulse_dst <= sync_fifo[2:1] == 2'b01;
        end
    end

    // Stage 3: Edge detection in the destination domain
    //assign pulse_dst = (sync_fifo[2:1] == 2'b01);

endmodule
