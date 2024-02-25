// DOC 5503 register ram module
//
// The DOC 5503 is configured through a set of 7 register groups,
// each of which has 32 8-bit registers. In addition to this, there
// are additional internal register groups for mainting the state of
// the 24-bit address accumulator and the 16-bit scaled sample output.
// The total of this accounts for too large an amount of memory to be
// efficiently implemented as normal Verilog registers in gate logic.
// So, the goal of this module is to provide access logic that enables
// the registers to be inferred into block RAMs or distributed RAMs
// during synthesis.
//
// - This module is a register array with priority write and read ports
//
// - The priority write and read ports are edge triggered except
//   for the first priority write port which can be level triggered
//
// - It is designed to be inferred as a single or semi-dual port RAM
//   by most synthesis tools although this has only been tested with
//   the Gowin IDE. On other tools, be sure to check the inferred
//   RAM type and ensure it is appropriate for the target device.
//

module doc5503_register_ram  #(
    parameter int PRIORITY_WRITE_PORTS = 0,
    parameter int PRIORITY_READ_PORTS = 0,
    parameter int FIRST_PRIORITY_WRITE_PORT_LEVEL_TRIGGERED = 0,
    parameter int LAST_PRIORITY_WRITE_PORT_INHIBITABLE = 0,
    parameter int PORT_A_ENABLE = 1,
    parameter int PORT_B_ENABLE = 0,
    parameter int ADDR_WIDTH = 5,
    parameter int DATA_WIDTH = 8
) (
        input clk_i,

        input inhibit_i,

        input priority_write_req_i[PRIORITY_WRITE_PORTS > 0 ? PRIORITY_WRITE_PORTS : 1],
        input [ADDR_WIDTH-1:0] priority_write_addr_i[PRIORITY_WRITE_PORTS > 0 ? PRIORITY_WRITE_PORTS : 1],
        input [DATA_WIDTH-1:0] priority_write_data_i[PRIORITY_WRITE_PORTS > 0 ? PRIORITY_WRITE_PORTS : 1],

        input priority_read_req_i[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1],
        input [ADDR_WIDTH-1:0] priority_read_addr_i[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1],
        output wire [DATA_WIDTH-1:0] priority_read_data_o[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1],

        input [ADDR_WIDTH-1:0] addr_a_i,
        output wire [DATA_WIDTH-1:0] data_a_o,

        input [ADDR_WIDTH-1:0] addr_b_i,
        output wire [DATA_WIDTH-1:0] data_b_o
);

    wire priority_write_w[PRIORITY_WRITE_PORTS > 0 ? PRIORITY_WRITE_PORTS : 1];
    reg priority_write_ack_r[PRIORITY_WRITE_PORTS > 0 ? PRIORITY_WRITE_PORTS : 1];

    generate
        for (genvar i = 0; i < PRIORITY_WRITE_PORTS; i++) begin : priority_write_port_loop
            if (i == 0 && FIRST_PRIORITY_WRITE_PORT_LEVEL_TRIGGERED) begin
                assign priority_write_w[i] = priority_write_req_i[i];
            end else begin
                srff write_ff (.clk(clk_i), .s(priority_write_req_i[i]), .r(priority_write_ack_r[i]), .q(priority_write_w[i]));
            end
        end
    endgenerate

    wire priority_read_w[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1];
    reg priority_read_ack_r[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1];
    reg [DATA_WIDTH-1:0] priority_read_data_r[PRIORITY_READ_PORTS > 0 ? PRIORITY_READ_PORTS : 1];

    generate
        if (PRIORITY_READ_PORTS > 0) begin
            for (genvar i = 0; i < PRIORITY_READ_PORTS; i++) begin : priority_read_port_loop
                srff read_ff (.clk(clk_i), .s(priority_read_req_i[i]), .r(priority_read_ack_r[i]), .q(priority_read_w[i]));
                assign priority_read_data_o[i] = priority_read_data_r[i];
            end
        end else begin
            assign priority_read_data_o[0] = '0;
        end
    endgenerate

    reg [DATA_WIDTH-1:0] data_r[31:0];

    reg priority_write_en_r;
    int priority_write_index;
    reg [ADDR_WIDTH-1:0] priority_write_addr_r;

    always @(*) begin: priority_write_ctrl
        automatic reg found = 0;
        priority_write_en_r = 0;
        priority_write_index = 0;
        priority_write_addr_r = 0;
        for (int i = 0; i < PRIORITY_WRITE_PORTS; i++) begin
            automatic logic inhibit_en = LAST_PRIORITY_WRITE_PORT_INHIBITABLE && (i == (PRIORITY_WRITE_PORTS - 1)) ? inhibit_i : 0;
            if (priority_write_w[i] && !found && !inhibit_en) begin
                priority_write_en_r = 1;
                priority_write_index = i;
                priority_write_addr_r = priority_write_addr_i[i];
                found = 1;
            end
        end
    end

    reg priority_read_en_r;
    int priority_read_index;
    reg [ADDR_WIDTH-1:0] priority_read_addr_r;

    always @(*) begin: priority_read_ctrl
        automatic reg found = 0;
        priority_read_en_r = 0;
        priority_read_index = 0;
        priority_read_addr_r = addr_a_i;
        for (int i = 0; i < PRIORITY_READ_PORTS; i++) begin
            if (priority_read_w[i] && !found) begin
                priority_read_en_r = 1;
                priority_read_index = i;
                priority_read_addr_r = priority_read_addr_i[i];
                found = 1;
            end
        end
    end

    localparam SP_READ_ENABLE = (PRIORITY_READ_PORTS > 0) || PORT_A_ENABLE;

    reg [DATA_WIDTH-1:0] data_a_r;
    assign data_a_o = PORT_A_ENABLE ? data_a_r : '0;

    always @(posedge clk_i) begin
        for (int i = 0; i < PRIORITY_WRITE_PORTS; i++) priority_write_ack_r[i] <= 0;
        for (int i = 0; i < PRIORITY_READ_PORTS; i++) priority_read_ack_r[i] <= 0;
        if (priority_write_en_r) begin
            data_r[priority_write_addr_r] <= priority_write_data_i[priority_write_index];
            priority_write_ack_r[priority_write_index] <= 1;
        end else if (SP_READ_ENABLE) begin
            automatic reg [DATA_WIDTH-1:0] data_r = data_r[priority_read_addr_r];
            if (priority_read_en_r) begin
                priority_read_data_r[priority_read_index] <= data_r;
                priority_read_ack_r[priority_read_index] <= 1;
            end else if (PORT_A_ENABLE) begin
                data_a_r <= data_r;
            end
        end
    end

    reg [DATA_WIDTH-1:0] data_b_r;
    assign data_b_o = PORT_B_ENABLE ? data_b_r : '0;

    always @(posedge clk_i) begin
        if (PORT_B_ENABLE) begin
            data_b_r <= data_r[addr_b_i];
        end
    end

endmodule



