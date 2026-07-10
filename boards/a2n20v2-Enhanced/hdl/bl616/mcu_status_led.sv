// MCU liveness watchdog + WS2812 status color for the BL616.
//
// Runs entirely FPGA-side so it survives every MCU failure mode — including a
// wedged firmware self-update, where the screen freezes and (with the
// DebugOverlay off by default) the user otherwise gets no signal at all.
// Liveness is any SPI register transaction: the firmware's disk_poll reads
// registers every ~2 ms in all normal states, and the fwupdate commit loop
// writes a per-chunk beacon, so silence longer than STALE_S means the MCU is
// wedged or never booted (e.g. app region erased by an interrupted update).
//
// The color otherwise follows the boot-stage / fault codes the firmware
// already writes to scratch reg 0 (SPI 0x07) — dbg_stage()/STG_* in
// firmware_host/main.c, the fwupdate.c commit beacon, and the fatal-hook
// markers — so boot progression is visible with no firmware changes:
//
//   blue    steady  power-on, no MCU transaction yet
//   cyan            firmware booting (stage 0x10-0x5F)
//   yellow          USB searching (0xA0-0xBF)
//   green           USB device connected / reports flowing (0xC0-0xDF)
//   magenta         firmware install in progress (0xF1/0xF2 copy/verify)
//   white           install verified, restarting (0xF9)
//   red     steady  MCU-declared fatal (0xED/0xEE/0xEF markers)
//   red     blink   liveness watchdog expired (MCU silent > STALE_S)
//   off             standalone mode (no MCU present — expected, not an error)

module mcu_status_led #(
    parameter int CLK_HZ  = 54_000_000,
    parameter int STALE_S = 10,
    parameter logic [7:0] BRIGHT = 8'h30   // full-scale WS2812 is blinding
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mcu_access_stb_i,   // any SPI register transaction
    input  wire        standalone_i,       // no-MCU fallback engaged
    input  wire [7:0]  stage_i,            // MCU scratch reg 0 (SPI 0x07)
    output reg  [23:0] rgb_o               // {R,G,B} to the ws2812 encoder
);

    // 54 MHz * 10 s = 5.4e8, comfortably inside 32 bits
    localparam [31:0] STALE_LIMIT = CLK_HZ * STALE_S;

    reg [31:0] wd_cnt_r;
    reg        seen_any_r;   // at least one transaction since power-on
    reg        expired_r;
    reg [25:0] blink_cnt_r;  // bit 25 @ 54 MHz ~= 0.8 Hz square wave

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wd_cnt_r    <= 32'd0;
            seen_any_r  <= 1'b0;
            expired_r   <= 1'b0;
            blink_cnt_r <= 26'd0;
        end else begin
            blink_cnt_r <= blink_cnt_r + 1'b1;
            if (mcu_access_stb_i) begin
                wd_cnt_r   <= 32'd0;
                seen_any_r <= 1'b1;
                expired_r  <= 1'b0;
            end else if (wd_cnt_r >= STALE_LIMIT)
                expired_r <= 1'b1;
            else
                wd_cnt_r <= wd_cnt_r + 1'b1;
        end
    end

    wire blink_w = blink_cnt_r[25];

    localparam logic [23:0] C_OFF     = 24'h0;
    wire [23:0] c_red_w     = {BRIGHT, 8'h00,  8'h00};
    wire [23:0] c_blue_w    = {8'h00,  8'h00,  BRIGHT};
    wire [23:0] c_cyan_w    = {8'h00,  BRIGHT, BRIGHT};
    wire [23:0] c_yellow_w  = {BRIGHT, BRIGHT, 8'h00};
    wire [23:0] c_green_w   = {8'h00,  BRIGHT, 8'h00};
    wire [23:0] c_magenta_w = {BRIGHT, 8'h00,  BRIGHT};
    wire [23:0] c_white_w   = {BRIGHT, BRIGHT, BRIGHT};

    always @(*) begin
        if (standalone_i)
            rgb_o = C_OFF;
        else if (seen_any_r && (stage_i == 8'hED || stage_i == 8'hEE ||
                                stage_i == 8'hEF))
            rgb_o = c_red_w;                       // declared fatal: steady red
        else if (expired_r)
            rgb_o = blink_w ? c_red_w : C_OFF;     // silent wedge: blinking red
        else if (!seen_any_r)
            rgb_o = c_blue_w;                      // waiting for first sign of life
        else begin
            casez (stage_i)
                8'hF9:                 rgb_o = c_white_w;    // install verified
                8'hF?:                 rgb_o = c_magenta_w;  // install copy/verify
                8'hC?, 8'hD?:          rgb_o = c_green_w;    // USB connected
                8'hA?, 8'hB?:          rgb_o = c_yellow_w;   // USB searching
                8'h1?, 8'h2?,
                8'h3?, 8'h4?, 8'h5?:   rgb_o = c_cyan_w;     // booting
                default:               rgb_o = c_green_w;    // alive, unmapped code
            endcase
        end
    end

endmodule
