`timescale 1ns / 1ps

module pulse_generator #(
    parameter COUNT = 10,  // Default value of COUNT is 10
    parameter WIDTH = $clog2((COUNT > 0 ? COUNT : 1) + 1),  // Width of cnt is calculated based on COUNT
    parameter ONE = WIDTH'(1)
) (
    input  wire clk,
    input  wire reset_n,
    input  wire trigger,
    output reg  pulse
);

    reg [WIDTH-1:0] cnt;
    reg trigger_d;  // delayed version of trigger

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pulse <= 1'b0;
            cnt <= 'b0;
            trigger_d <= 1'b0;
        end else begin
            trigger_d <= trigger;
            if (cnt > 0) begin
                cnt <= cnt - ONE;
                pulse <= 1'b1;
            end else if (!trigger_d && trigger) begin  // low to high transition
                cnt <= COUNT;
                pulse <= 1'b1;
            end else begin
                pulse <= 1'b0;
            end
        end
    end

endmodule
