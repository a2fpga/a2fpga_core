
module sdpram32 #(
        parameter ADDR_WIDTH = 10
) (
        input clk,
        input [ADDR_WIDTH-1:0] write_addr,
        input [31:0] write_data,
        input write_enable,
        input [3:0] byte_enable,
        input [ADDR_WIDTH-1:0] read_addr,
        input read_enable,
        output reg [31:0] read_data
);

    reg [31:0] mem [2**ADDR_WIDTH-1:0];

    // force pipeline read mode, per GowinSynthesis Coding Templates
    // Necessary to avoid potential glitches in read data if
    // write address and read address are the same
    reg [31:0] read_data_r;

    always_ff @(posedge clk) begin
            // Keep write and read paths independent so scan reads can continue
            // during CPU writes (critical for VGC animation stability).
            if (write_enable) begin
                if (byte_enable[0])
                    mem[write_addr][7:0] <= write_data[7:0];
                if (byte_enable[1])
                    mem[write_addr][15:8] <= write_data[15:8];
                if (byte_enable[2])
                    mem[write_addr][23:16] <= write_data[23:16];
                if (byte_enable[3])
                    mem[write_addr][31:24] <= write_data[31:24];
            end
            if (read_enable) begin
                    read_data_r <= mem[read_addr];
            end
            read_data <= read_data_r;
    end

endmodule
