module timer #(
    parameter CLOCK_FREQ = 54_000_000,  // Default clock frequency
    parameter CLOCK_DIVIDER = 1000      // Default to milliseconds
) (
    input clk,            // Clock input
    input reset,          // Asynchronous reset
    output reg [31:0] counter // 32-bit counter
);

// Calculate the number of cycles based on the clock frequency
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
        if (cycles < CYCLES_PER_COUNT - 1) begin
            // Increment cycles
            cycles <= cycles + 1'b1;
        end else begin
            // Reset cycles and increment counter
            cycles <= 0;
            counter <= counter + 1;
        end
    end
end

endmodule
