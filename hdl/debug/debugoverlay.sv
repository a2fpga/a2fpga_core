module DebugOverlay #(
    parameter [8*14-1:0] VERSION = "00000000000000", // 14 ASCII characters
    parameter bit ENABLE = 1'b1,
    parameter NUM_HEX_BYTES = 8         // Number of hex bytes to display
)(
    input  wire        clk_i,
    input  wire        reset_n,

    input wire enable_i,

    input  wire [9:0]  screen_x_i,
    input  wire [9:0]  screen_y_i,

    // 8 hex bytes to display
    input wire [7:0] hex_values[NUM_HEX_BYTES],
    
    // 2 bit fields to display
    input  wire [7:0]  debug_bits_0_i,
    input  wire [7:0]  debug_bits_1_i,

    // RGB input and output
    input  wire [7:0]  r_i,
    input  wire [7:0]  g_i,
    input  wire [7:0]  b_i,

    output wire [7:0]  r_o,
    output wire [7:0]  g_o,
    output wire [7:0]  b_o
);

    // Constants
    localparam CHAR_WIDTH  = 8;
    localparam CHAR_HEIGHT = 8;
    localparam NUM_CHARS   = 14;          // Number of characters in VERSION string
    localparam NUM_BITS_FIELDS = 2;       // Number of bit fields
    localparam NUM_BITS_PER_FIELD = 8;    // Number of bits per field
    localparam X_OFFSET    = 16;
    localparam Y_OFFSET    = 24;
    localparam DEBUG_SPACE = 8;           // Space between debug values
    
    // Character ROM: 16 hex digits (0-9, A-F) × 8 rows
    // Digits 0-9 extracted from video.hex starting at byte 1408 (character code 176*8)
    // Letters A-F extracted from video.hex starting at byte 1032 (character code 129*8)
    reg [7:0] char_rom [128] = '{
        // Digit 0 (Line 177, first 8 bytes)
        8'b00011100, // 1C - Original hex: 1C 22 32 2A 26 22 1C 00
        8'b00100010,
        8'b00110010,
        8'b00101010,
        8'b00100110,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Digit 1 (Line 177, next 8 bytes)
        8'b00001000, // 08 - Original hex: 08 0C 08 08 08 08 1C 00
        8'b00001100,
        8'b00001000,
        8'b00001000,
        8'b00001000,
        8'b00001000,
        8'b00011100,
        8'b00000000,
        
        // Digit 2 (Line 178, first 8 bytes)
        8'b00111100, // 1C - Original hex: 1C 22 20 18 04 02 3E 00
        8'b00100010,
        8'b00100000,
        8'b00011000,
        8'b00000100,
        8'b00000010,
        8'b00111110,
        8'b00000000,
        
        // Digit 3 (Line 178, next 8 bytes)
        8'b00111110, // 3E - Original hex: 3E 20 10 18 20 22 1C 00
        8'b00100000,
        8'b00010000,
        8'b00011000,
        8'b00100000,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Digit 4 (Line 179, first 8 bytes)
        8'b00010000, // 10 - Original hex: 10 18 14 12 3E 10 10 00
        8'b00011000,
        8'b00010100,
        8'b00010010,
        8'b00111110,
        8'b00010000,
        8'b00010000,
        8'b00000000,
        
        // Digit 5 (Line 179, next 8 bytes)
        8'b00111110, // 3E - Original hex: 3E 02 1E 20 20 22 1C 00
        8'b00000010,
        8'b00011110,
        8'b00100000,
        8'b00100000,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Digit 6 (Line 180, first 8 bytes)
        8'b00111000, // 38 - Original hex: 38 04 02 1E 22 22 1C 00
        8'b00000100,
        8'b00000010,
        8'b00011110,
        8'b00100010,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Digit 7 (Line 180, next 8 bytes)
        8'b00111110, // 3E - Original hex: 3E 20 10 08 04 04 04 00
        8'b00100000,
        8'b00010000,
        8'b00001000,
        8'b00000100,
        8'b00000100,
        8'b00000100,
        8'b00000000,
        
        // Digit 8 (Line 181, first 8 bytes)
        8'b00011100, // 1C - Original hex: 1C 22 22 1C 22 22 1C 00
        8'b00100010,
        8'b00100010,
        8'b00011100,
        8'b00100010,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Digit 9 (Line 181, next 8 bytes)
        8'b00011100, // 1C - Original hex: 1C 22 22 3C 20 10 0E 00
        8'b00100010,
        8'b00100010,
        8'b00111100,
        8'b00100000,
        8'b00010000,
        8'b00001110,
        8'b00000000,
        
        // Letter A (Line 1, second 8 bytes)
        8'b00001000, // 08 - Original hex from video.hex: 08 14 22 22 3E 22 22 00
        8'b00010100, // 14
        8'b00100010, // 22
        8'b00100010, // 22
        8'b00111110, // 3E
        8'b00100010, // 22
        8'b00100010, // 22
        8'b00000000, // 00
        
        // Letter B (Line 1, next 8 bytes)
        8'b00011110, // 1E - Original hex: 1E 22 22 1E 22 22 1E 00
        8'b00100010,
        8'b00100010,
        8'b00111110,
        8'b00100010,
        8'b00100010,
        8'b00011110,
        8'b00000000,
        
        // Letter C (Line 2, first 8 bytes)
        8'b00011100, // 1C - Original hex: 1C 22 02 02 02 22 1C 00
        8'b00100010,
        8'b00000010,
        8'b00000010,
        8'b00000010,
        8'b00100010,
        8'b00011100,
        8'b00000000,
        
        // Letter D (Line 2, next 8 bytes)
        8'b00011110, // 1E - Original hex: 1E 22 22 22 22 22 1E 00
        8'b00100010,
        8'b00100010,
        8'b00100010,
        8'b00100010,
        8'b00100010,
        8'b00011110,
        8'b00000000,
        
        // Letter E (Line 3, first 8 bytes)
        8'b00111110, // 3E - Original hex: 3E 02 02 1E 02 02 3E 00
        8'b00000010,
        8'b00000010,
        8'b00111110,
        8'b00000010,
        8'b00000010,
        8'b00111110,
        8'b00000000,
        
        // Letter F (Line 3, next 8 bytes)
        8'b00111110, // 3E - Original hex: 3E 02 02 1E 02 02 02 00
        8'b00000010,
        8'b00000010,
        8'b00111110,
        8'b00000010,
        8'b00000010,
        8'b00000010,
        8'b00000000
    };

    // Position calculations
    wire [9:0] rel_x = 10'(screen_x_i - X_OFFSET);
    wire [9:0] rel_y = 10'(screen_y_i - Y_OFFSET);
    
    // Fixed-width bit slicing to avoid division/modulo
    wire [3:0] char_pos = rel_x[6:3]; // Which character (0-13) in version string
    
    // Bit position within character
    reg [2:0] x_bit;
    wire [2:0] y_bit = rel_y[2:0];    // Which row within character (0-7)
    
    // For boundary checking
    // Version string region
    wire [9:0] version_end = 10'(NUM_CHARS * CHAR_WIDTH);
    wire x_version_in_range = (screen_x_i >= X_OFFSET) && (rel_x < version_end);
    
    // Start of debug region (after version string + space)
    wire [9:0] debug_start = 10'(version_end + DEBUG_SPACE);
    
    // Define the boundaries for each hex byte display region (2 chars each)
    wire [9:0] hex_width = 10'(2 * CHAR_WIDTH);  // 16 pixels for 2 hex chars
    wire [9:0] hex_region_width = 10'(hex_width + DEBUG_SPACE);  // Width including spacing
    
    // Calculate start and end positions for each hex byte region
    wire [9:0] hex_region_starts[NUM_HEX_BYTES];
    wire [9:0] hex_region_ends[NUM_HEX_BYTES];
    
    // Generate positions for all hex bytes
    generate
        for (genvar i = 0; i < NUM_HEX_BYTES; i++) begin : hex_regions
            assign hex_region_starts[i] = 10'(debug_start + i * hex_region_width);
            assign hex_region_ends[i] = 10'(hex_region_starts[i] + hex_width);
        end
    endgenerate
    
    // Start of bit display regions (after all hex bytes + space)
    wire [9:0] bits_start = 10'(hex_region_starts[NUM_HEX_BYTES-1] + hex_width + DEBUG_SPACE);
    
    // Width of each bit field display
    wire [9:0] bits_field_width = 10'(NUM_BITS_PER_FIELD * CHAR_WIDTH);
    wire [9:0] bits_region_width = 10'(bits_field_width + DEBUG_SPACE);
    
    // Calculate start and end positions for each bit field region
    wire [9:0] bits_region_starts[NUM_BITS_FIELDS];
    wire [9:0] bits_region_ends[NUM_BITS_FIELDS];
    
    generate
        for (genvar i = 0; i < NUM_BITS_FIELDS; i++) begin : bits_regions
            assign bits_region_starts[i] = 10'(bits_start + i * bits_region_width);
            assign bits_region_ends[i] = 10'(bits_region_starts[i] + bits_field_width);
        end
    endgenerate
    
    // End of all display regions
    wire [9:0] debug_end = bits_region_ends[NUM_BITS_FIELDS-1];
    
    // Combined x-range check
    wire x_debug_in_range = (rel_x >= debug_start) && (rel_x < debug_end);
    wire x_in_range = x_version_in_range || x_debug_in_range;
    
    // Y-range is the same for all regions
    wire y_in_range = (screen_y_i >= Y_OFFSET) && (rel_y < CHAR_HEIGHT);
    wire in_bounds = x_in_range && y_in_range;

    // Region detection and character generation logic
    wire debug_region = (rel_x >= debug_start);
    
    // Calculate relative positions for each hex byte region
    reg [9:0] rel_hex_pos[NUM_HEX_BYTES];
    
    always_comb begin
        for (int i = 0; i < NUM_HEX_BYTES; i++) begin
            rel_hex_pos[i] = rel_x - hex_region_starts[i];
        end
    end
    
    // Calculate relative positions for each bit field region
    reg [9:0] rel_bits_pos[NUM_BITS_FIELDS];
    
    always_comb begin
        for (int i = 0; i < NUM_BITS_FIELDS; i++) begin
            rel_bits_pos[i] = rel_x - bits_region_starts[i];
        end
    end
    
    // Determine which hex byte region we're in (returns 0-7), or -1 if none
    reg signed [4:0] current_hex_byte;
    reg is_in_hex_region;
    
    // Determine which bit field region we're in (returns 0-1), or -1 if none
    reg [0:0] current_bit_field;
    reg is_in_bits_region;
    
    // Determine if we're in a space between display regions
    reg in_space;
    
    always_comb begin
        // Default values
        current_hex_byte = -1;
        is_in_hex_region = 1'b0;
        current_bit_field = 0;
        is_in_bits_region = 1'b0;
        in_space = 1'b0;
        
        if (debug_region) begin
            // Check if we're in any hex byte region
            for (int i = 0; i < NUM_HEX_BYTES; i++) begin
                if (rel_x >= hex_region_starts[i] && rel_x < hex_region_ends[i]) begin
                    current_hex_byte = 4'(i);  // Explicit 4-bit cast
                    is_in_hex_region = 1'b1;
                end
            end
            
            // Check if we're in any bit field region
            for (int i = 0; i < NUM_BITS_FIELDS; i++) begin
                if (rel_x >= bits_region_starts[i] && rel_x < bits_region_ends[i]) begin
                    current_bit_field = i;
                    is_in_bits_region = 1'b1;
                end
            end
            
            // Check if we're in any space between regions
            if (debug_region && !(is_in_hex_region || is_in_bits_region) && (rel_x < debug_end)) begin
                in_space = 1'b1;
            end
        end
    end
    
    // Determine if we're displaying the high or low nibble for hex values
    reg nibble_select;
    
    always_comb begin
        nibble_select = 1'b0;
        
        if (is_in_hex_region) begin
            // High nibble is first char, low nibble is second char
            // Each hex byte takes 2 characters (16 pixels)
            nibble_select = rel_hex_pos[current_hex_byte] >= CHAR_WIDTH;
        end
    end
    
    // Determine bit position and value for bit fields
    reg [2:0] bit_position;
    reg bit_value;
    
    always_comb begin
        bit_position = 3'd0;
        bit_value = 1'b0;
        
        if (is_in_bits_region) begin
            // Calculate bit position (0-7)
            bit_position = 3'(rel_bits_pos[current_bit_field] / 10'(CHAR_WIDTH));
            
            // Get bit value (MSB first)
            case (current_bit_field)
                1'b0: bit_value = debug_bits_0_i[7-bit_position];
                1'b1: bit_value = debug_bits_1_i[7-bit_position];
            endcase
        end
    end
    
    // Calculate display character and x_bit
    // x_bit is the bit position (0-7) within the character
    always_comb begin
        // Default value to avoid latch inference
        x_bit = 3'd0;
        
        if (debug_region) begin
            if (is_in_bits_region) begin
                // For bit display regions, use position within bit character
                x_bit = rel_bits_pos[current_bit_field][2:0];
            end else if (is_in_hex_region) begin
                // For hex display regions, calculate based on high/low nibble
                x_bit = nibble_select ? 
                    rel_hex_pos[current_hex_byte][2:0] : // Low nibble
                    rel_hex_pos[current_hex_byte][2:0];  // High nibble
            end
        end else begin
            // For version string, just use the low 3 bits of rel_x
            x_bit = rel_x[2:0];
        end
    end
    
    wire [7:0] current_hex_value = is_in_hex_region ? hex_values[current_hex_byte] : 8'h00;
    
    // Get the correct nibble from the hex value
    wire [3:0] hex_nibble = nibble_select ? current_hex_value[3:0] : current_hex_value[7:4];
    
    // Convert nibble to ASCII character code
    wire [7:0] hex_char = (hex_nibble < 4'hA) ? 
                         {4'h3, hex_nibble} :     // 0-9 -> ASCII '0'-'9'
                         {4'h4, 4'(hex_nibble - 4'h9)}; // A-F -> ASCII 'A'-'F'
    
    // Select the character to display
    wire [7:0] char_data;
    
    assign char_data = !debug_region ? VERSION[(NUM_CHARS-1-char_pos)*8 +: 8] :
                       in_space ? 8'h20 :         // Space character
                       is_in_bits_region ? (bit_value ? 8'h31 : 8'h30) : // '1' or '0'
                       hex_char;                  // Hex character
    
    // Character rendering logic
    logic [7:0] font_row;
    logic pixel_on;
    
    always_comb begin
        // Default values
        font_row = 8'd0;
        pixel_on = 1'b0;
        
        if (ENABLE && enable_i && in_bounds) begin
            // Handle spaces specially - should be blank
            if (debug_region && in_space) begin
                pixel_on = 1'b0;
            end
            // Handle both version string region and debug region
            else if ((!debug_region && (char_pos < 4'd14)) || debug_region) begin
                // Handle both digits 0-9 and hex letters A-F
                if (char_data >= 8'h30 && char_data <= 8'h39) begin
                    // Convert ASCII to digit value (0-9)                
                    // Get the font row for this digit
                    font_row = char_rom[{char_data[3:0], y_bit}];
                    
                    // Get the specific pixel from the font row
                    // MSB = leftmost pixel
                    pixel_on = font_row[x_bit];
                end else if (char_data >= 8'h41 && char_data <= 8'h46) begin
                    // Handle uppercase hex digits A-F
                    // Convert ASCII to array index (A=10, B=11, etc.)
                    // A is 0x41, so 0x41-0x41+10 = 10
                    font_row = char_rom[{4'd10 + (char_data[3:0] - 4'd1), y_bit}];
                    
                    // Get the specific pixel from the font row
                    // MSB = leftmost pixel
                    pixel_on = font_row[x_bit];
                end else if (char_data >= 8'h61 && char_data <= 8'h66) begin
                    // Handle lowercase hex digits a-f (display as uppercase)
                    // Convert ASCII to array index (a=10, b=11, etc.)
                    // a is 0x61, so 0x61-0x61+10 = 10
                    font_row = char_rom[{4'd10 + (char_data[3:0] - 4'd1), y_bit}];
                    
                    // Get the specific pixel from the font row
                    // MSB = leftmost pixel
                    pixel_on = font_row[x_bit];
                end else begin
                    // Non-hex characters show as solid blocks for debugging
                    pixel_on = 1'b1;
                end
            end // end of version/debug region condition
        end
    end
    
    // Output coloring
    assign r_o = pixel_on ? 8'hFF : r_i;
    assign g_o = pixel_on ? 8'hFF : g_i;
    assign b_o = pixel_on ? 8'hFF : b_i;

endmodule