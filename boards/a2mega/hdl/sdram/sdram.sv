function integer rtoi(input integer x);
    return x;
endfunction

`define CEIL(x) ((rtoi(x) > x) ? rtoi(x) : rtoi(x) + 1)

module sdram #(
    parameter CLOCK_SPEED_MHZ = 54_000_000,

    // Port config
    parameter NUM_PORTS = 2,

    parameter PORT_ADDR_WIDTH = 31,
    parameter DATA_WIDTH = 32,
    parameter DQM_WIDTH = 4,
    parameter PORT_OUTPUT_WIDTH = 32,

    parameter DDR_ADDR_WIDTH = 29,  // Address width for DDR SDRAM
    parameter DDR_DATA_WIDTH = 128  // Data width for DDR SDRAM

) (
    input wire clk,
    input wire reset,  // Used to trigger start of FSM
    output wire init_complete,  // SDRAM is done initializing

    // Ports
    input wire [PORT_ADDR_WIDTH-1:0] port_addr[NUM_PORTS-1:0],
    input wire [DATA_WIDTH-1:0] port_data[NUM_PORTS-1:0],
    input wire [DQM_WIDTH-1:0] port_byte_en[NUM_PORTS-1:0],  // Byte enable for writes
    output reg [PORT_OUTPUT_WIDTH-1:0] port_q[NUM_PORTS-1:0],
    output reg [DDR_DATA_WIDTH-1:0] port_q_burst[NUM_PORTS-1:0],  // Full 128-bit burst data

    input wire port_wr[NUM_PORTS-1:0],
    input wire port_rd[NUM_PORTS-1:0],

    output wire port_available[NUM_PORTS-1:0],  // The port is able to be used
    output reg  port_ready     [NUM_PORTS-1:0],  // The port has finished its task. Will rise for a single cycle

    // DDR SDRAM interface, wired to the controller in the top module
    input init_calib_complete,

    input cmd_ready,
    output reg [2:0] cmd,
    output reg cmd_en,
    output reg [DDR_ADDR_WIDTH-1:0] addr,

    input wr_data_rdy,
    output reg [DDR_DATA_WIDTH-1:0] wr_data,
    output reg wr_data_en,
    output reg wr_data_end,
    output reg [DDR_DATA_WIDTH/8-1:0] wr_data_mask,

    input [DDR_DATA_WIDTH-1:0] rd_data,
    input rd_data_valid,
    input rd_data_end

);

    // DDR3 commands
    localparam CMD_WRITE = 3'b000;
    localparam CMD_READ  = 3'b001;
    localparam CMD_PRECHARGE = 3'b010;
    localparam CMD_ACTIVATE = 3'b011;
    localparam CMD_REFRESH = 3'b100;
    localparam CMD_NOP = 3'b111;

    // State machine
    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_CMD_ISSUE,
        STATE_WRITE_DATA,
        STATE_READ_WAIT,
        STATE_READ_DATA,
        STATE_COMPLETE
    } state_t;

    state_t state;

    // Port management
    localparam PORT_BITS = NUM_PORTS > 1 ? $clog2(NUM_PORTS) : 1;
    reg [PORT_BITS-1:0] active_port;
    reg [NUM_PORTS-1:0] port_request_pending;
    reg [NUM_PORTS-1:0] port_is_write;

    // Request queues
    reg [PORT_ADDR_WIDTH-1:0] port_addr_queue[NUM_PORTS-1:0];
    reg [DATA_WIDTH-1:0] port_data_queue[NUM_PORTS-1:0];
    reg [DQM_WIDTH-1:0] port_byte_en_queue[NUM_PORTS-1:0];

    // Edge detection for port requests
    reg port_wr_prev[NUM_PORTS-1:0];
    reg port_rd_prev[NUM_PORTS-1:0];
    wire port_wr_req[NUM_PORTS-1:0];
    wire port_rd_req[NUM_PORTS-1:0];

    // Data alignment for DDR3 128-bit interface
    reg [DDR_DATA_WIDTH-1:0] write_data_reg;
    reg [DDR_DATA_WIDTH/8-1:0] write_mask_reg;
    
    // Read data handling
    reg [DDR_DATA_WIDTH-1:0] read_data_reg;
    reg read_data_valid_reg;

    // Generate edge detection
    generate
        for (genvar i = 0; i < NUM_PORTS; i++) begin : port_edge_detect
            assign port_wr_req[i] = port_wr[i] && !port_wr_prev[i];
            assign port_rd_req[i] = port_rd[i] && !port_rd_prev[i];
            assign port_available[i] = (state == STATE_IDLE) && !port_request_pending[i] && init_calib_complete;
        end
    endgenerate

    // Priority encoder for port selection
    function automatic [PORT_BITS-1:0] get_next_port();
        logic [PORT_BITS-1:0] result = 0;
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (port_request_pending[i]) begin
                result = i[PORT_BITS-1:0];
                break;
            end
        end
        return result;
    endfunction

    // Address translation: port address to DDR3 address
    function automatic [DDR_ADDR_WIDTH-1:0] translate_address(input [PORT_ADDR_WIDTH-1:0] port_addr);
        // Simple address mapping - may need adjustment based on memory layout
        return port_addr[DDR_ADDR_WIDTH-1:0];
    endfunction

    // Data width conversion: 32-bit port data to 128-bit DDR3 data
    function automatic [DDR_DATA_WIDTH-1:0] expand_write_data(
        input [DATA_WIDTH-1:0] data,
        input [PORT_ADDR_WIDTH-1:0] addr
    );
        logic [DDR_DATA_WIDTH-1:0] result = 0;
        logic [1:0] word_offset = addr[3:2]; // Which 32-bit word in the 128-bit line
        
        case (word_offset)
            2'b00: result[31:0] = data;
            2'b01: result[63:32] = data;
            2'b10: result[95:64] = data;
            2'b11: result[127:96] = data;
        endcase
        return result;
    endfunction

    // Byte mask conversion: 4-bit port mask to 16-bit DDR3 mask
    function automatic [DDR_DATA_WIDTH/8-1:0] expand_write_mask(
        input [DQM_WIDTH-1:0] byte_en,
        input [PORT_ADDR_WIDTH-1:0] addr
    );
        logic [DDR_DATA_WIDTH/8-1:0] result = {(DDR_DATA_WIDTH/8){1'b1}}; // Default: mask all
        logic [1:0] word_offset = addr[3:2];
        
        case (word_offset)
            2'b00: result[3:0] = ~byte_en;   // Active low mask
            2'b01: result[7:4] = ~byte_en;
            2'b10: result[11:8] = ~byte_en;
            2'b11: result[15:12] = ~byte_en;
        endcase
        return result;
    endfunction

    // Extract read data for specific port
    function automatic [PORT_OUTPUT_WIDTH-1:0] extract_read_data(
        input [DDR_DATA_WIDTH-1:0] data,
        input [PORT_ADDR_WIDTH-1:0] addr
    );
        logic [1:0] word_offset = addr[3:2];
        
        case (word_offset)
            2'b00: return data[31:0];
            2'b01: return data[63:32];
            2'b10: return data[95:64];
            2'b11: return data[127:96];
        endcase
    endfunction

    assign init_complete = init_calib_complete;

    always @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            active_port <= 0;
            port_request_pending <= 0;
            port_is_write <= 0;
            
            cmd <= CMD_NOP;
            cmd_en <= 0;
            addr <= 0;
            
            wr_data <= 0;
            wr_data_en <= 0;
            wr_data_end <= 0;
            wr_data_mask <= {(DDR_DATA_WIDTH/8){1'b1}};
            
            read_data_reg <= 0;
            read_data_valid_reg <= 0;
            
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_wr_prev[i] <= 0;
                port_rd_prev[i] <= 0;
                port_ready[i] <= 0;
                port_q[i] <= 0;
                port_q_burst[i] <= 0;
                port_addr_queue[i] <= 0;
                port_data_queue[i] <= 0;
                port_byte_en_queue[i] <= 0;
            end
            
        end else begin
            // Default values
            cmd_en <= 0;
            wr_data_en <= 0;
            wr_data_end <= 0;
            
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_ready[i] <= 0;
            end
            
            // Update previous values for edge detection
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_wr_prev[i] <= port_wr[i];
                port_rd_prev[i] <= port_rd[i];
            end
            
            // Capture new requests
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (port_wr_req[i] && !port_request_pending[i]) begin
                    port_request_pending[i] <= 1;
                    port_is_write[i] <= 1;
                    port_addr_queue[i] <= port_addr[i];
                    port_data_queue[i] <= port_data[i];
                    port_byte_en_queue[i] <= port_byte_en[i];
                end else if (port_rd_req[i] && !port_request_pending[i]) begin
                    port_request_pending[i] <= 1;
                    port_is_write[i] <= 0;
                    port_addr_queue[i] <= port_addr[i];
                end
            end
            
            // Handle read data from DDR3
            if (rd_data_valid) begin
                read_data_reg <= rd_data;
                read_data_valid_reg <= 1;
            end else begin
                read_data_valid_reg <= 0;
            end

            case (state)
                STATE_IDLE: begin
                    if (init_calib_complete && |port_request_pending) begin
                        active_port <= get_next_port();
                        state <= STATE_CMD_ISSUE;
                    end
                end
                
                STATE_CMD_ISSUE: begin
                    if (cmd_ready) begin
                        addr <= translate_address(port_addr_queue[active_port]);
                        cmd_en <= 1;
                        
                        if (port_is_write[active_port]) begin
                            cmd <= CMD_WRITE;
                            
                            // Prepare write data
                            write_data_reg <= expand_write_data(
                                port_data_queue[active_port],
                                port_addr_queue[active_port]
                            );
                            write_mask_reg <= expand_write_mask(
                                port_byte_en_queue[active_port],
                                port_addr_queue[active_port]
                            );
                            
                            state <= STATE_WRITE_DATA;
                        end else begin
                            cmd <= CMD_READ;
                            state <= STATE_READ_WAIT;
                        end
                    end
                end
                
                STATE_WRITE_DATA: begin
                    if (wr_data_rdy) begin
                        wr_data <= write_data_reg;
                        wr_data_mask <= write_mask_reg;
                        wr_data_en <= 1;
                        wr_data_end <= 1; // Single beat write
                        state <= STATE_COMPLETE;
                    end
                end
                
                STATE_READ_WAIT: begin
                    if (rd_data_valid) begin
                        state <= STATE_READ_DATA;
                    end
                end
                
                STATE_READ_DATA: begin
                    // Extract the correct 32-bit word from 128-bit data
                    port_q[active_port] <= extract_read_data(
                        read_data_reg, 
                        port_addr_queue[active_port]
                    );
                    // Also provide the full 128-bit burst data
                    port_q_burst[active_port] <= read_data_reg;
                    state <= STATE_COMPLETE;
                end
                
                STATE_COMPLETE: begin
                    port_ready[active_port] <= 1;
                    port_request_pending[active_port] <= 0;
                    state <= STATE_IDLE;
                end
                
                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule