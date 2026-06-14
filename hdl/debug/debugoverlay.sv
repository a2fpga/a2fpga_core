module DebugOverlay #(
    parameter [8*14-1:0] VERSION = "00000000000000", // 14 ASCII characters
    parameter bit ENABLE = 1'b1,
    parameter NUM_HEX_BYTES = 8,        // Number of hex bytes to display
    parameter X_OFFSET = 16,
    parameter Y_OFFSET = 24
)(
    input  wire        clk_i,
    input  wire        reset_n,

    input wire enable_i,

    input  wire [10:0] screen_x_i,
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

    output reg  [7:0]  r_o,
    output reg  [7:0]  g_o,
    output reg  [7:0]  b_o
);

    // Constants
    localparam CHAR_WIDTH  = 8;
    localparam CHAR_HEIGHT = 8;
    localparam NUM_CHARS   = 14;          // Number of characters in VERSION string
    localparam NUM_BITS_FIELDS = 2;       // Number of bit fields
    localparam NUM_BITS_PER_FIELD = 8;    // Number of bits per field
    localparam DEBUG_SPACE = 8;           // Space between debug values

    // Character ROM: 16 hex digits (0-9, A-F) x 8 rows
    reg [7:0] char_rom [128] = '{
        // Digit 0
        8'b00011100, 8'b00100010, 8'b00110010, 8'b00101010,
        8'b00100110, 8'b00100010, 8'b00011100, 8'b00000000,
        // Digit 1
        8'b00001000, 8'b00001100, 8'b00001000, 8'b00001000,
        8'b00001000, 8'b00001000, 8'b00011100, 8'b00000000,
        // Digit 2
        8'b00111100, 8'b00100010, 8'b00100000, 8'b00011000,
        8'b00000100, 8'b00000010, 8'b00111110, 8'b00000000,
        // Digit 3
        8'b00111110, 8'b00100000, 8'b00010000, 8'b00011000,
        8'b00100000, 8'b00100010, 8'b00011100, 8'b00000000,
        // Digit 4
        8'b00010000, 8'b00011000, 8'b00010100, 8'b00010010,
        8'b00111110, 8'b00010000, 8'b00010000, 8'b00000000,
        // Digit 5
        8'b00111110, 8'b00000010, 8'b00011110, 8'b00100000,
        8'b00100000, 8'b00100010, 8'b00011100, 8'b00000000,
        // Digit 6
        8'b00111000, 8'b00000100, 8'b00000010, 8'b00011110,
        8'b00100010, 8'b00100010, 8'b00011100, 8'b00000000,
        // Digit 7
        8'b00111110, 8'b00100000, 8'b00010000, 8'b00001000,
        8'b00000100, 8'b00000100, 8'b00000100, 8'b00000000,
        // Digit 8
        8'b00011100, 8'b00100010, 8'b00100010, 8'b00011100,
        8'b00100010, 8'b00100010, 8'b00011100, 8'b00000000,
        // Digit 9
        8'b00011100, 8'b00100010, 8'b00100010, 8'b00111100,
        8'b00100000, 8'b00010000, 8'b00001110, 8'b00000000,
        // Letter A
        8'b00001000, 8'b00010100, 8'b00100010, 8'b00100010,
        8'b00111110, 8'b00100010, 8'b00100010, 8'b00000000,
        // Letter B
        8'b00011110, 8'b00100010, 8'b00100010, 8'b00111110,
        8'b00100010, 8'b00100010, 8'b00011110, 8'b00000000,
        // Letter C
        8'b00011100, 8'b00100010, 8'b00000010, 8'b00000010,
        8'b00000010, 8'b00100010, 8'b00011100, 8'b00000000,
        // Letter D
        8'b00011110, 8'b00100010, 8'b00100010, 8'b00100010,
        8'b00100010, 8'b00100010, 8'b00011110, 8'b00000000,
        // Letter E
        8'b00111110, 8'b00000010, 8'b00000010, 8'b00111110,
        8'b00000010, 8'b00000010, 8'b00111110, 8'b00000000,
        // Letter F
        8'b00111110, 8'b00000010, 8'b00000010, 8'b00111110,
        8'b00000010, 8'b00000010, 8'b00000010, 8'b00000000
    };

    //=========================================================================
    // PIPELINE STAGE 1: Position calculation, region detection, ROM address
    //=========================================================================

    // --- Combinational: Stage 1 inputs ---
    wire [10:0] rel_x = 11'(screen_x_i - X_OFFSET);
    wire [9:0]  rel_y = 10'(screen_y_i - Y_OFFSET);
    wire [3:0]  char_pos = rel_x[6:3];
    wire [2:0]  y_bit = rel_y[2:0];

    // Version string region
    localparam [10:0] VERSION_END = 11'(NUM_CHARS * CHAR_WIDTH);
    wire x_version_in_range = (screen_x_i >= X_OFFSET) && (rel_x < VERSION_END);

    // Debug region start
    localparam [10:0] DEBUG_START = 11'(VERSION_END + DEBUG_SPACE);
    localparam [10:0] HEX_WIDTH = 11'(2 * CHAR_WIDTH);
    localparam [10:0] HEX_REGION_WIDTH = 11'(HEX_WIDTH + DEBUG_SPACE);

    // Hex region starts/ends (compile-time constants)
    wire [10:0] hex_region_starts[NUM_HEX_BYTES];
    wire [10:0] hex_region_ends[NUM_HEX_BYTES];
    generate
        for (genvar i = 0; i < NUM_HEX_BYTES; i++) begin : hex_regions
            assign hex_region_starts[i] = 11'(DEBUG_START + i * HEX_REGION_WIDTH);
            assign hex_region_ends[i] = 11'(hex_region_starts[i] + HEX_WIDTH);
        end
    endgenerate

    // Bit field region starts/ends
    localparam [10:0] BITS_START = 11'(DEBUG_START + NUM_HEX_BYTES * HEX_REGION_WIDTH);
    localparam [10:0] BITS_FIELD_WIDTH = 11'(NUM_BITS_PER_FIELD * CHAR_WIDTH);
    localparam [10:0] BITS_REGION_WIDTH = 11'(BITS_FIELD_WIDTH + DEBUG_SPACE);

    wire [10:0] bits_region_starts[NUM_BITS_FIELDS];
    wire [10:0] bits_region_ends[NUM_BITS_FIELDS];
    generate
        for (genvar i = 0; i < NUM_BITS_FIELDS; i++) begin : bits_regions
            assign bits_region_starts[i] = 11'(BITS_START + i * BITS_REGION_WIDTH);
            assign bits_region_ends[i] = 11'(bits_region_starts[i] + BITS_FIELD_WIDTH);
        end
    endgenerate

    localparam [10:0] DEBUG_END = 11'(BITS_START + NUM_BITS_FIELDS * BITS_REGION_WIDTH);

    wire debug_region = (rel_x >= DEBUG_START);
    wire y_in_range = (screen_y_i >= Y_OFFSET) && (rel_y < CHAR_HEIGHT);

    // Region detection (combinational)
    reg signed [4:0] comb_hex_byte;
    reg comb_is_hex;
    reg [0:0] comb_bit_field;
    reg comb_is_bits;
    reg comb_in_space;
    reg [10:0] comb_rel_hex_pos;
    reg [10:0] comb_rel_bits_pos;

    always_comb begin
        comb_hex_byte = -1;
        comb_is_hex = 1'b0;
        comb_bit_field = 0;
        comb_is_bits = 1'b0;
        comb_in_space = 1'b0;
        comb_rel_hex_pos = 11'd0;
        comb_rel_bits_pos = 11'd0;

        if (debug_region) begin
            for (int i = 0; i < NUM_HEX_BYTES; i++) begin
                if (rel_x >= hex_region_starts[i] && rel_x < hex_region_ends[i]) begin
                    comb_hex_byte = 4'(i);
                    comb_is_hex = 1'b1;
                    comb_rel_hex_pos = rel_x - hex_region_starts[i];
                end
            end
            for (int i = 0; i < NUM_BITS_FIELDS; i++) begin
                if (rel_x >= bits_region_starts[i] && rel_x < bits_region_ends[i]) begin
                    comb_bit_field = i;
                    comb_is_bits = 1'b1;
                    comb_rel_bits_pos = rel_x - bits_region_starts[i];
                end
            end
            if (!(comb_is_hex || comb_is_bits) && (rel_x < DEBUG_END)) begin
                comb_in_space = 1'b1;
            end
        end
    end

    // Pre-compute intermediate values to avoid local reg inside always_comb
    wire [2:0] bits_bp = 3'(comb_rel_bits_pos / 11'(CHAR_WIDTH));
    wire bits_bv = (comb_bit_field == 1'b0) ? debug_bits_0_i[7-bits_bp] : debug_bits_1_i[7-bits_bp];

    wire hex_nibble_sel = comb_rel_hex_pos >= 11'(CHAR_WIDTH);
    wire [7:0] hex_hval = comb_is_hex ? hex_values[comb_hex_byte] : 8'h00;
    wire [3:0] hex_nibble = hex_nibble_sel ? hex_hval[3:0] : hex_hval[7:4];

    wire [7:0] ver_ch = VERSION[(NUM_CHARS-1-char_pos)*8 +: 8];

    // Compute ROM address and x_bit in stage 1
    reg [6:0] comb_rom_addr;
    reg [2:0] comb_x_bit;
    reg comb_in_bounds;
    reg comb_is_space;
    reg comb_is_solid;

    always_comb begin
        comb_rom_addr = 7'd0;
        comb_x_bit = 3'd0;
        comb_in_bounds = 1'b0;
        comb_is_space = 1'b0;
        comb_is_solid = 1'b0;

        if (ENABLE && enable_i && y_in_range) begin
            if (debug_region) begin
                if (comb_in_space) begin
                    comb_in_bounds = 1'b1;
                    comb_is_space = 1'b1;
                end else if (comb_is_bits && rel_x < DEBUG_END) begin
                    comb_in_bounds = 1'b1;
                    comb_x_bit = comb_rel_bits_pos[2:0];
                    comb_rom_addr = {4'(bits_bv ? 4'd1 : 4'd0), y_bit};
                end else if (comb_is_hex && rel_x < DEBUG_END) begin
                    comb_in_bounds = 1'b1;
                    comb_x_bit = comb_rel_hex_pos[2:0];
                    comb_rom_addr = {hex_nibble, y_bit};
                end
            end else begin
                if (x_version_in_range) begin
                    comb_in_bounds = 1'b1;
                    comb_x_bit = rel_x[2:0];
                    if (ver_ch >= 8'h30 && ver_ch <= 8'h39)
                        comb_rom_addr = {ver_ch[3:0], y_bit};
                    else if (ver_ch >= 8'h41 && ver_ch <= 8'h46)
                        comb_rom_addr = {4'd10 + (ver_ch[3:0] - 4'd1), y_bit};
                    else if (ver_ch >= 8'h61 && ver_ch <= 8'h66)
                        comb_rom_addr = {4'd10 + (ver_ch[3:0] - 4'd1), y_bit};
                    else
                        comb_is_solid = 1'b1;
                end
            end
        end
    end

    // --- Stage 1 registers ---
    reg [6:0] s1_rom_addr;
    reg [2:0] s1_x_bit;
    reg       s1_in_bounds;
    reg       s1_is_space;
    reg       s1_is_solid;
    reg [7:0] s1_r, s1_g, s1_b;

    always @(posedge clk_i) begin
        s1_rom_addr  <= comb_rom_addr;
        s1_x_bit     <= comb_x_bit;
        s1_in_bounds <= comb_in_bounds;
        s1_is_space  <= comb_is_space;
        s1_is_solid  <= comb_is_solid;
        // Delay RGB passthrough by 1 cycle to align with pipeline
        s1_r <= r_i;
        s1_g <= g_i;
        s1_b <= b_i;
    end

    //=========================================================================
    // PIPELINE STAGE 2: ROM lookup, pixel test, output mux
    //=========================================================================

    wire [7:0] font_row = char_rom[s1_rom_addr];
    wire pixel_on = s1_in_bounds && !s1_is_space && (s1_is_solid || font_row[s1_x_bit]);

    always @(posedge clk_i) begin
        r_o <= pixel_on ? 8'hFF : s1_r;
        g_o <= pixel_on ? 8'hFF : s1_g;
        b_o <= pixel_on ? 8'hFF : s1_b;
    end

endmodule
