// -----------------------------------------------------
// Apple II Bus Capture - Proper Interface Usage
// -----------------------------------------------------
module a2bus_stream #(
    parameter bit ENABLE = 1'b1
)(
    a2bus_if.slave a2bus_if,
    
    // CAM Interface  
    output logic        cam_pclk,
    output logic        cam_sync,
    output logic [3:0]  cam_data,
    
    // Control and Status
    input  logic        capture_enable,
    input  logic [2:0]  capture_mode,
    input  logic        heartbeat_pulse,    // NEW: Heartbeat for testing
    output logic        activity_led,
    output logic        overflow_led,
    output logic [7:0]  debug_status,
    output logic [15:0] es5503_counter,     // ES5503 filtered packet counter (transmitted)
    output logic [15:0] es5503_access_counter, // ES5503 access counter (detected)
    output logic [15:0] packets_dropped_counter, // Packets dropped due to cam_busy
    output logic        cam_overwrite_flag      // CAM serializer overwrite detected
);

    // Bus capture timing - use data_in_strobe for single capture per transaction
    // This ensures we only capture once per bus cycle, not repeatedly
    wire bus_cycle_w = ENABLE & capture_enable & a2bus_if.data_in_strobe & !a2bus_if.m2sel_n;
    
    // Address-based selection for filtering
    wire is_io_access_w = (a2bus_if.addr[15:12] == 4'hC);           // $C000-$CFFF
    wire is_zero_page_w = (a2bus_if.addr[15:8] == 8'h00);          // $0000-$00FF  
    wire is_stack_page_w = (a2bus_if.addr[15:8] == 8'h01);         // $0100-$01FF
    wire is_text_page_w = (a2bus_if.addr[15:11] == 5'b00100);      // $0400-$07FF
    wire is_hires_page_w = (a2bus_if.addr[15:13] == 3'b001);       // $2000-$3FFF
    wire is_rom_access_w = (a2bus_if.addr[15:12] >= 4'hD);         // $D000-$FFFF
    wire is_speaker_w = (a2bus_if.addr == 16'hC030);               // Speaker
    wire is_es5503_w = (a2bus_if.addr[15:2] == 14'b1100_0000_0011_11);  // $C03C-$C03F (ES5503)
    
    // Capture mode filtering
    reg capture_this_cycle;
    always @(*) begin
        case (capture_mode)
            3'b000: capture_this_cycle = 1'b1;                                    // Everything
            3'b001: capture_this_cycle = is_io_access_w;                          // I/O only
            3'b010: capture_this_cycle = is_zero_page_w | is_stack_page_w;        // System pages
            3'b011: capture_this_cycle = is_text_page_w | is_hires_page_w;        // Graphics pages
            3'b100: capture_this_cycle = is_rom_access_w;                         // ROM access
            3'b101: capture_this_cycle = !a2bus_if.rw_n;                         // Writes only
            3'b110: capture_this_cycle = a2bus_if.rw_n;                          // Reads only
            3'b111: capture_this_cycle = is_es5503_w;                            // ES5503 only (changed from speaker)
        endcase
    end
    
    // Bus capture trigger
    wire capture_trigger_w = bus_cycle_w & capture_this_cycle;
    
    // Packet formation: [ADDR:16][DATA:8][FLAGS:8]
    // FLAGS: [7]=RW_N, [6]=M2SEL_N, [5]=M2B0, [4]=SW_GS, [3:1]=Reserved, [0]=Reset indicator
    wire [31:0] packet_data_w = {
        a2bus_if.addr,           // [31:16] Address
        a2bus_if.data,           // [15:8]  Data  
        a2bus_if.rw_n,           // [7]     Read/Write
        a2bus_if.m2sel_n,        // [6]     M2SEL
        a2bus_if.m2b0,           // [5]     M2B0
        a2bus_if.sw_gs,          // [4]     IIgs mode
        3'b000,                  // [3:1]   Reserved
        1'b0                     // [0]     Reset indicator (0 = normal packet)
    };
    
    // Reset indicator packet: sent once on system reset
    wire [31:0] reset_packet_w = {
        16'h0000,                // [31:16] Address = 0
        8'h00,                   // [15:8]  Data = 0
        4'b0000,                 // [7:4]   All flags = 0
        3'b000,                  // [3:1]   Reserved = 0
        1'b1                     // [0]     Reset indicator = 1
    };
    
    // Heartbeat packet: sent periodically for testing
    reg [7:0] heartbeat_counter = 8'h0;
    wire [31:0] heartbeat_packet_w = {
        16'hC0FF,                // [31:16] Address = 0xC0FF (I/O page - will be visible)
        heartbeat_counter,       // [15:8]  Data = counter
        4'b1010,                 // [7:4]   Test flags pattern
        3'b101,                  // [3:1]   Test reserved bits
        1'b0                     // [0]     Normal packet (not reset)
    };
    
    // Register the packet on the bus clock edge
    reg [31:0] packet_data_r;
    reg        packet_valid_r;
    reg        reset_packet_sent_r;
    reg        heartbeat_pending_r;
    reg        startup_done_r;
    
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            // Initialize all registers on reset
            packet_data_r <= 32'h0;
            packet_valid_r <= 1'b0;
            reset_packet_sent_r <= 1'b0;
            heartbeat_pending_r <= 1'b0;
            startup_done_r <= 1'b0;
            heartbeat_counter <= 8'h0;
        end else if (!startup_done_r) begin
            // Send reset packet on FPGA startup
            packet_data_r <= reset_packet_w;
            packet_valid_r <= 1'b1;
            reset_packet_sent_r <= 1'b1;
            startup_done_r <= 1'b1;
            heartbeat_pending_r <= 1'b0;
            heartbeat_counter <= 8'h0;
        end else begin
            // Clear packet when accepted by stream serializer
            if (packet_accepted_w) begin
                packet_valid_r <= 1'b0;
                if (heartbeat_pending_r) heartbeat_pending_r <= 1'b0;
            end
            // Handle heartbeat pulse - works without Apple II system
            else if (heartbeat_pulse && !heartbeat_pending_r && !packet_valid_r) begin
                packet_data_r <= heartbeat_packet_w;
                packet_valid_r <= 1'b1;
                heartbeat_pending_r <= 1'b1;
                heartbeat_counter <= heartbeat_counter + 1;
            end
            // Normal bus capture (when Apple II system_reset_n is available)
            else if (a2bus_if.system_reset_n && capture_trigger_w && !packet_valid_r) begin
                packet_data_r <= packet_data_w;
                packet_valid_r <= 1'b1;
            end
        end
    end

    // Direct connection to cam serializer - no FIFO needed!
    // Cam serializer can keep up since: 32 clocks/packet < 47+ clocks/Apple II cycle
    
    wire cam_busy;
    wire cam_overwrite;
    wire packet_accepted_w = packet_valid_r & !cam_busy;
    
    cam_serializer #(
        .SYNC_EVERY_PKTS(409),
        .IDLE_FLUSH_CYCLES(13500),
        .PAD_MODE(1'b0),
        .PAD_COUNT(409)
    ) cam_serializer_inst (
        .clk_i(a2bus_if.clk_logic),
        .rst_n(a2bus_if.system_reset_n),
        .wr_i(packet_accepted_w),
        .data_i(packet_data_r),
        .cam_pclk(cam_pclk),
        .cam_sync(cam_sync),
        .cam_data(cam_data),
        .busy(cam_busy),
        .overwrite_detected(cam_overwrite)
    );

    // Activity detection
    reg bus_active_r;
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            bus_active_r <= 1'b0;
        end else begin
            bus_active_r <= capture_trigger_w;
        end
    end

    // Status outputs with filtering debug info
    assign activity_led = bus_active_r | cam_busy;
    assign overflow_led = packet_valid_r & cam_busy;  // Packet dropped due to busy serializer
    assign debug_status = {
        cam_overwrite,          // [7] CAM serializer overwrite detected
        capture_trigger_w,      // [6] Final capture trigger
        capture_enable,         // [5]
        capture_mode,           // [4:2]
        packet_valid_r,         // [1]
        is_es5503_w             // [0] ES5503 address detected
    };

    // Performance counters for debugging
    reg [15:0] packets_captured_r = 16'h0;
    reg [15:0] packets_dropped_r = 16'h0;
    reg [15:0] es5503_counter_r = 16'h0;
    reg [15:0] es5503_access_counter_r = 16'h0;
    
    // Count ES5503 packets that are actually transmitted (not heartbeat/reset)
    wire es5503_packet_sent_w = packet_accepted_w & 
                                (packet_data_r[31:16] >= 16'hC03C) & 
                                (packet_data_r[31:16] <= 16'hC03F) & 
                                (packet_data_r[0] == 1'b0);
    
    // Count ES5503 accesses when they're detected (before transmission)
    wire es5503_access_detected_w = capture_trigger_w & is_es5503_w;
    
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            packets_captured_r <= 16'h0;
            packets_dropped_r <= 16'h0;
            es5503_counter_r <= 16'h0;
            es5503_access_counter_r <= 16'h0;
        end else begin
            if (packet_accepted_w)
                packets_captured_r <= packets_captured_r + 1;
            if (packet_valid_r & cam_busy)
                packets_dropped_r <= packets_dropped_r + 1;
            if (es5503_packet_sent_w)
                es5503_counter_r <= es5503_counter_r + 1;
            if (a2bus_if.data_in_strobe && !a2bus_if.m2sel_n && a2bus_if.addr[15:2] == 14'b1100_0000_0011_11)
                es5503_access_counter_r <= es5503_access_counter_r + 1;
        end
    end
    
    // Output counters
    assign es5503_counter = es5503_counter_r;
    assign es5503_access_counter = es5503_access_counter_r;
    assign packets_dropped_counter = packets_dropped_r;
    assign cam_overwrite_flag = cam_overwrite;

endmodule
