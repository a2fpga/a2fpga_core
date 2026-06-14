// Testbench for cam_serializer - LCD_CAM compatible 4-bit parallel output
`timescale 1ps/1ps

module test_cam_serializer;
    parameter CLK_PERIOD = 18.5; // 54MHz clock period in ps
    
    // Test signals
    reg clk = 0;
    reg rst_n = 0;
    reg wr = 0;
    reg [31:0] data = 0;
    
    wire cam_pclk, cam_sync, busy;
    wire [3:0] cam_data;
    
    // Instantiate DUT with slower clock for easier analysis
    cam_serializer #(4) dut (
        .clk_i(clk),
        .rst_n(rst_n),
        .wr_i(wr),
        .data_i(data),
        .cam_pclk(cam_pclk),
        .cam_sync(cam_sync),
        .cam_data(cam_data),
        .busy(busy)
    );
    
    // Clock generation
    always #(CLK_PERIOD/2) clk = ~clk;
    
    // Edge detection for analysis
    reg cam_pclk_prev = 0, cam_sync_prev = 0;
    wire cam_pclk_rising = cam_pclk && !cam_pclk_prev;
    wire cam_pclk_falling = !cam_pclk && cam_pclk_prev;
    wire sync_rising = cam_sync && !cam_sync_prev;
    wire sync_falling = !cam_sync && cam_sync_prev;
    
    always @(posedge clk) begin
        cam_pclk_prev <= cam_pclk;
        cam_sync_prev <= cam_sync;
    end
    
    // Track captured data for verification
    reg [31:0] captured_data = 0;
    integer nibble_count = 0;
    integer packet_count = 0;
    
    // Capture data on PCLK rising edges during active sync (DE=LOW on ESP32 side)
    // cam_sync=HIGH on FPGA side means DE=LOW on ESP32 side (inverted)
    always @(posedge clk) begin
        if (sync_rising) begin
            $display("Time %0t: Frame %0d START (DE active)", $time, packet_count);
            captured_data = 0;
            nibble_count = 0;
        end
        
        if (cam_pclk_rising && cam_sync) begin  // Only capture when sync is active
            captured_data = {cam_data, captured_data[31:4]}; // Shift nibble into MSB position
            nibble_count = nibble_count + 1;
            $display("Time %0t: Nibble %0d: 0x%X (sync=%b, data_so_far=0x%08X)", 
                    $time, nibble_count-1, cam_data, cam_sync, captured_data);
                    
            // Check if we completed 8 nibbles (a full packet)
            if (nibble_count == 8) begin
                $display("Time %0t: Frame %0d COMPLETE - 8 nibbles captured: 0x%08X", 
                        $time, packet_count, captured_data);
                
                // Verify against expected data
                if (captured_data == data) begin
                    $display("✓ PASS: Packet matches expected 0x%08X", data);
                end else begin
                    $display("✗ FAIL: Expected 0x%08X, got 0x%08X", data, captured_data);
                end
                
                packet_count = packet_count + 1;
                $display("");
                
                // Reset for next packet
                captured_data = 0;
                nibble_count = 0;
            end
        end
    end
    
    // Test task
    task send_data(input [31:0] test_data);
        begin
            data = test_data;
            $display("=== Sending 0x%08X ===", test_data);
            @(posedge clk);
            wr = 1;
            @(posedge clk);
            wr = 0;
            
            // Wait for at least one complete packet (8 nibbles + some margin)
            repeat(500) @(posedge clk);
        end
    endtask
    
    // Measure PCLK timing
    real cam_pclk_freq;
    real cam_pclk_period;
    reg [63:0] last_pclk_rising = 0;
    reg [63:0] current_pclk_rising = 0;
    
    always @(posedge clk) begin
        if (cam_pclk_rising) begin
            current_pclk_rising = $time;
            if (last_pclk_rising != 0) begin
                cam_pclk_period = current_pclk_rising - last_pclk_rising;
                cam_pclk_freq = 1.0e12 / cam_pclk_period; // Hz (period in ps)
                $display("PCLK: %.1f Hz (period: %.0f ps)", cam_pclk_freq, cam_pclk_period);
            end
            last_pclk_rising = current_pclk_rising;
        end
    end
    
    initial begin
        $dumpfile("cam_serializer.vcd");
        $dumpvars(0, test_cam_serializer);
        
        $display("=== CAM Serializer Test ===");
        $display("Clock Period: %.1f ps", CLK_PERIOD);
        $display("COUNT_WIDTH = 4 (16x clock divider for PCLK)");
        
        // Reset
        #(10 * CLK_PERIOD);
        rst_n = 1;
        #(10 * CLK_PERIOD);
        
        // Test the expected pattern from FPGA
        send_data(32'h12345678);
        
        // Test other patterns
        send_data(32'hABCDEF01);  
        send_data(32'hFFFFFFFF);
        send_data(32'h00000000);
        send_data(32'hA5A5A5A5);
        
        // Test rapid back-to-back transactions
        $display("=== Testing Back-to-Back Transactions ===");
        send_data(32'h11111111);
        send_data(32'h22222222);
        
        // Test continuous streaming (multiple writes)
        $display("=== Testing Continuous Stream ===");
        data = 32'h33333333;
        @(posedge clk);
        wr = 1;
        @(posedge clk);
        wr = 0;
        
        repeat(50) @(posedge clk); // Let first packet start
        
        data = 32'h44444444;
        @(posedge clk);
        wr = 1;
        @(posedge clk);
        wr = 0;
        
        repeat(200) @(posedge clk); // Watch continuous stream
        
        $display("=== Test Complete ===");
        $display("Total packets captured: %0d", packet_count);
        $finish;
    end
    
endmodule