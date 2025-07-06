module debounce #(
    parameter DEBOUNCE_TIME = 100000,  // Adjust for debounce period
    parameter COUNTER_WIDTH = $clog2(DEBOUNCE_TIME)  // Compute the required bit width
)(
    input  wire clk,           // System clock
    input  wire rst,           // Active-high reset
    input  wire i,  // Input signal with noise
    output reg  o  // Debounced stable output
);

    reg [COUNTER_WIDTH-1:0] counter = 0;
    reg stable = 0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            counter <= 0;
            stable <= 0;
            o <= 0;
        end else if (i == stable) begin
            counter <= 0; // Reset counter if input remains stable
        end else begin
            counter <= COUNTER_WIDTH'(counter + 1);
            if (counter == DEBOUNCE_TIME - 1) begin
                stable <= i;
                o <= i;
                counter <= 0; // Reset counter after update
            end
        end
    end
endmodule