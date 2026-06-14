// Apple II Bus Event FIFO
// Adapted from a2bus_stream.sv -- replaces CAM serializer with BSRAM FIFO
// Captures bus transactions and stores them in a 512x32 FIFO for SPI readout
module a2bus_event_fifo #(
    parameter bit ENABLE = 1'b1,
    parameter FIFO_DEPTH = 512
)(
    a2bus_if.slave a2bus_if,

    // FIFO read interface (directly to connector registers)
    output wire        fifo_empty,
    output wire        fifo_full,
    output wire [8:0]  fifo_count,
    output wire [31:0] fifo_rdata,
    input  wire        fifo_pop,

    // Control
    input  wire        capture_enable,
    input  wire [2:0]  capture_mode
);

    // Bus capture timing
    wire bus_cycle_w = ENABLE & capture_enable & a2bus_if.data_in_strobe & !a2bus_if.m2sel_n;

    // Address-based selection for filtering
    wire is_io_access_w   = (a2bus_if.addr[15:12] == 4'hC);
    wire is_zero_page_w   = (a2bus_if.addr[15:8] == 8'h00);
    wire is_stack_page_w  = (a2bus_if.addr[15:8] == 8'h01);
    wire is_text_page_w   = (a2bus_if.addr[15:11] == 5'b00100);
    wire is_hires_page_w  = (a2bus_if.addr[15:13] == 3'b001);
    wire is_rom_access_w  = (a2bus_if.addr[15:12] >= 4'hD);
    wire is_es5503_w      = (a2bus_if.addr[15:2] == 14'b1100_0000_0011_11);

    // Capture mode filtering
    reg capture_this_cycle;
    always @(*) begin
        case (capture_mode)
            3'b000: capture_this_cycle = 1'b1;                               // Everything
            3'b001: capture_this_cycle = is_io_access_w;                     // I/O only
            3'b010: capture_this_cycle = is_zero_page_w | is_stack_page_w;   // System pages
            3'b011: capture_this_cycle = is_text_page_w | is_hires_page_w;   // Graphics pages
            3'b100: capture_this_cycle = is_rom_access_w;                    // ROM access
            3'b101: capture_this_cycle = !a2bus_if.rw_n;                    // Writes only
            3'b110: capture_this_cycle = a2bus_if.rw_n;                     // Reads only
            3'b111: capture_this_cycle = is_es5503_w;                       // ES5503 only
        endcase
    end

    wire capture_trigger_w = bus_cycle_w & capture_this_cycle;

    // Packet formation: [ADDR:16][DATA:8][FLAGS:8]
    wire [31:0] packet_data_w = {
        a2bus_if.addr,
        a2bus_if.data,
        a2bus_if.rw_n,
        a2bus_if.m2sel_n,
        a2bus_if.m2b0,
        a2bus_if.sw_gs,
        3'b000,
        1'b0
    };

    // -------------------------------------------------------
    // FIFO (512 x 32-bit) using BSRAM inferred as SDP RAM
    // -------------------------------------------------------
    localparam ADDR_W = $clog2(FIFO_DEPTH); // 9

    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [ADDR_W:0] wr_ptr_r;  // Extra bit for full/empty detection
    reg [ADDR_W:0] rd_ptr_r;

    wire [ADDR_W-1:0] wr_addr = wr_ptr_r[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_ptr_r[ADDR_W-1:0];

    wire [ADDR_W:0] count_w = wr_ptr_r - rd_ptr_r;

    assign fifo_empty = (wr_ptr_r == rd_ptr_r);
    assign fifo_full  = (wr_ptr_r[ADDR_W] != rd_ptr_r[ADDR_W]) &&
                        (wr_ptr_r[ADDR_W-1:0] == rd_ptr_r[ADDR_W-1:0]);
    assign fifo_count = count_w[ADDR_W-1:0];

    // Read port -- registered for BSRAM inference
    reg [31:0] fifo_rdata_r;
    always @(posedge a2bus_if.clk_logic) begin
        fifo_rdata_r <= fifo_mem[rd_addr];
    end
    assign fifo_rdata = fifo_rdata_r;

    // Write port
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            wr_ptr_r <= 0;
        end else if (capture_trigger_w && !fifo_full) begin
            fifo_mem[wr_addr] <= packet_data_w;
            wr_ptr_r <= wr_ptr_r + 1;
        end
    end

    // Read port (pop)
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            rd_ptr_r <= 0;
        end else if (fifo_pop && !fifo_empty) begin
            rd_ptr_r <= rd_ptr_r + 1;
        end
    end

endmodule
