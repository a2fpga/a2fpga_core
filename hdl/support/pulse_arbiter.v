module PulseArbiter (
    input wire clk,
    input wire rst_n,
    input wire pulseA,
    input wire pulseB,
    output reg pulseA_out,
    output reg pulseB_out
);

    reg prev_pulseA;
    reg prev_pulseB;

    always @(posedge clk) begin
        prev_pulseA <= pulseA;
        prev_pulseB <= pulseB;
    end
    wire pulseA_posedge = pulseA & ~prev_pulseA;
    wire pulseB_posedge = pulseB & ~prev_pulseB;

    reg [2:0] fifoA = 3'b00;
    reg [1:0] fifoB = 2'b00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifoA <= 3'b00;
            fifoB <= 2'b00;
            pulseA_out <= 0;
            pulseB_out <= 0;
        end else begin
            // Default output states
            pulseA_out <= 0;
            pulseB_out <= 0;

            fifoA = {fifoA[1], fifoA[0], 1'b0};
            fifoB = {fifoB[0], 1'b0};

            if (pulseA_posedge & (pulseB_out | pulseB_posedge) ) begin
                if (pulseB_out) fifoA <= 3'b010;
                else fifoA <= 3'b001;
                if (pulseB_posedge) pulseB_out <= 1;
            end else if (pulseA_posedge) begin
                pulseA_out <= 1;
            end else if (pulseB_posedge & pulseA_out) begin
                fifoB <= 2'b01;
            end else if (pulseB_posedge) begin
                pulseB_out <= 1;
            end else if (fifoA[2]) begin
                pulseA_out <= 1;
            end else if (fifoB[1]) begin
                pulseB_out <= 1;
            end

        end
    end
endmodule
