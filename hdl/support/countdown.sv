module countdown #(
    parameter CLOCK_FREQ = 54_000_000,  // Default clock frequency
    parameter CLOCK_DIVIDER = 1_000_000      // Default to microseconds
) (
    input clk,                  // Clock input
    input reset,                // Asynchronous reset
    input we,                   // Write enable
    input [31:0] start,         // Number to count down from
    output reg [31:0] counter,  // 32-bit counter
    output done                 // Done flag
);

// Calculate the number of cycles to count based on the clock frequency
localparam CYCLES_PER_COUNT = CLOCK_FREQ / CLOCK_DIVIDER;

// Determine the number of bits required to store CYCLES_PER_COUNT
localparam BITS_FOR_CYCLES = $clog2(CYCLES_PER_COUNT);

// Counter for cycles
reg [BITS_FOR_CYCLES-1:0] cycles = 0;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        // Reset cycles and counter
        cycles <= 0;
        counter <= 0;
    end else begin
        if (we) begin
            // Reset cycles and counter
            cycles <= 0;
            counter <= start;
        end else begin
            if (cycles < CYCLES_PER_COUNT - 1) begin
                // Increment cycles
                cycles <= cycles + 1'b1;
            end else begin
                // Reset cycles and decrement counter if not zero
                cycles <= 0;
                counter <= counter != 0 ? counter - 1'b1 : '0;
            end
        end
    end
end

assign done = counter == 0;

endmodule
