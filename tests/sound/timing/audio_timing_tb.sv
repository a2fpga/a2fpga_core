`timescale 1ns / 1ps

module audio_timing_tb;

    // Parameters
    //parameter CLK_RATE = 24576000;
    //parameter AUDIO_RATE = 48000;
    parameter CLK_RATE = 27000000;
    parameter AUDIO_RATE = 44100;
    parameter CLK_PERIOD = 1000000000.0 / CLK_RATE; // Period in ns
    
    // Calculate expected counts
    localparam I2S_BCLK_COUNT = CLK_RATE / (AUDIO_RATE * 16 * 2) / 2; // Should be 8
    localparam I2S_LRCLK_COUNT = I2S_BCLK_COUNT * 32; // Should be 256
    localparam AUDIO_CLK_COUNT = I2S_LRCLK_COUNT * 2; // Should be 512

    // Testbench signals
    reg clk = 0;
    reg reset = 1;
    
    // DUT outputs
    wire audio_clk;
    wire i2s_bclk;
    wire i2s_lrclk;
    wire i2s_data_shift_strobe;
    wire i2s_data_load_strobe;

    // Clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // DUT instantiation
    audio_timing #(
        .CLK_RATE(CLK_RATE),
        .AUDIO_RATE(AUDIO_RATE)
    ) dut (
        .reset(reset),
        .clk(clk),
        .audio_clk(audio_clk),
        .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),
        .i2s_data_shift_strobe(i2s_data_shift_strobe),
        .i2s_data_load_strobe(i2s_data_load_strobe)
    );

    reg [31:0] data_buf = 32'hCAFEBABE;
    reg data_bit = 0;
    reg [15:0] data_shift  = 16'h0000;
    reg [15:0] data_word = 16'h0000;

    always @(posedge i2s_bclk) begin
        data_bit <= data_buf[31];
        data_buf <= {data_buf[30:0], 1'b0};
    end

    always @(posedge clk) begin
        if (i2s_data_shift_strobe) begin
            data_shift <= {data_shift[14:0], data_bit};
        end
    end

    always @(posedge clk) begin
        if (i2s_data_load_strobe) begin
            data_word <= data_shift;
        end
    end

    // Counters for verification
    integer bclk_toggle_count = 0;
    integer lrclk_toggle_count = 0;
    integer audio_clk_count = 0;
    integer shift_strobe_count = 0;
    integer load_strobe_count = 0;
    
    reg prev_i2s_bclk = 0;
    reg prev_i2s_lrclk = 0;
    reg prev_audio_clk = 0;

    // Monitor toggles and strobes
    always @(posedge clk) begin
        prev_i2s_bclk <= i2s_bclk;
        prev_i2s_lrclk <= i2s_lrclk;
        prev_audio_clk <= audio_clk;
        
        if (!reset) begin
            if (i2s_bclk != prev_i2s_bclk) 
                bclk_toggle_count <= bclk_toggle_count + 1;
            
            if (i2s_lrclk != prev_i2s_lrclk)
                lrclk_toggle_count <= lrclk_toggle_count + 1;
                
            if (audio_clk && !prev_audio_clk)
                audio_clk_count <= audio_clk_count + 1;
                
            if (i2s_data_shift_strobe)
                shift_strobe_count <= shift_strobe_count + 1;
                
            if (i2s_data_load_strobe)
                load_strobe_count <= load_strobe_count + 1;
        end
    end

    // Test sequence
    initial begin
        // Setup VCD dump
        $dumpfile("audio_timing_tb.vcd");
        $dumpvars(0, audio_timing_tb);
        
        $display("=== Audio Timing Testbench ===");
        $display("CLK_RATE: %d Hz", CLK_RATE);
        $display("AUDIO_RATE: %d Hz", AUDIO_RATE);
        $display("Expected I2S_BCLK_COUNT: %d", I2S_BCLK_COUNT);
        $display("Expected I2S_LRCLK_COUNT: %d", I2S_LRCLK_COUNT); 
        $display("Expected AUDIO_CLK_COUNT: %d", AUDIO_CLK_COUNT);
        $display("Clock period: %f ns", CLK_PERIOD);
        
        // Hold reset for a few cycles
        #(CLK_PERIOD * 10);
        reset = 0;
        $display("Reset released at time %t", $time);
        
        // Run for multiple complete audio periods
        // One audio period = AUDIO_CLK_COUNT * CLK_PERIOD ns
        // Run for ~4 audio periods to see multiple cycles
        #(CLK_PERIOD * AUDIO_CLK_COUNT * 4);
        
        // Display results
        $display("\n=== Results after 4 audio periods ===");
        $display("BCLK toggles: %d (expected ~%d)", bclk_toggle_count, (32 * 4)); // 32 toggles per audio period
        $display("LRCLK toggles: %d (expected ~%d)", lrclk_toggle_count, (2 * 4)); // 2 toggles per audio period  
        $display("Audio clock pulses: %d (expected ~%d)", audio_clk_count, 4);
        $display("Shift strobes: %d", shift_strobe_count);
        $display("Load strobes: %d", load_strobe_count);
        
        // Check timing relationships
        if (bclk_toggle_count > 0 && lrclk_toggle_count > 0) begin
            real bclk_to_lrclk_ratio = real'(bclk_toggle_count) / real'(lrclk_toggle_count);
            $display("BCLK:LRCLK ratio: %f (expected 16.0)", bclk_to_lrclk_ratio);
            
            if (bclk_to_lrclk_ratio >= 15.5 && bclk_to_lrclk_ratio <= 16.5)
                $display("✓ BCLK:LRCLK ratio PASS");
            else
                $display("✗ BCLK:LRCLK ratio FAIL");
        end
        
        $display("\nSimulation completed at time %t", $time);
        $finish;
    end

    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * AUDIO_CLK_COUNT * 10); // 10 audio periods max
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule