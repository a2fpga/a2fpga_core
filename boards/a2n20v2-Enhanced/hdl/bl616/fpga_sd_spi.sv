// FPGA-side SPI master for SD card access via BL616 register tunnel.
//
// The BL616 MCU writes TX bytes and CS# control to FPGA registers;
// this module clocks them to the SD card and captures the response.
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB-first, 8-bit transfers.
// Two clock speeds: fast (~13.5 MHz = clk/4) and slow (~400 kHz = clk/136).

module fpga_sd_spi #(
    parameter CLOCK_SPEED_HZ = 54_000_000
)(
    input  wire       clk,
    input  wire       rst_n,

    // Control
    input  wire       cs_n_i,       // directly drives SD CS# pin
    input  wire       slow_clk_i,   // 1=slow (~400kHz), 0=fast (~13.5MHz)

    // Transfer interface
    input  wire       tx_start_i,   // pulse to begin 8-bit transfer
    input  wire [7:0] tx_data_i,    // byte to send (latched on tx_start)
    output reg  [7:0] rx_data_o,    // received byte (valid when busy=0)
    output wire       busy_o,       // high during transfer

    // SD card pins
    output wire       sd_clk_o,
    output wire       sd_mosi_o,
    input  wire       sd_miso_i,
    output wire       sd_cs_n_o
);

    // CS# is directly driven from the register
    assign sd_cs_n_o = cs_n_i;

    // Prescaler values
    // Fast: clk/8 = 54MHz/8 = 6.75 MHz (4 clk per half-period)
    // Slow: clk/136 ≈ 397 kHz (68 clk per half-period)
    localparam FAST_DIV_HALF = 4 - 1;   // counter max for fast (0 to 3)
    localparam SLOW_DIV_HALF = 68 - 1;  // counter max for slow (0 to 67)

    reg [6:0] prescale_cnt_r;
    reg [6:0] prescale_max_r;
    reg [3:0] bit_cnt_r;      // counts 0..7 for 8 bits
    reg [7:0] shift_out_r;
    reg [7:0] shift_in_r;
    reg       sclk_r;
    reg       running_r;

    assign busy_o    = running_r;
    assign sd_clk_o  = sclk_r;
    assign sd_mosi_o = shift_out_r[7]; // MSB first

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prescale_cnt_r <= 7'd0;
            prescale_max_r <= FAST_DIV_HALF[6:0];
            bit_cnt_r      <= 4'd0;
            shift_out_r    <= 8'hFF;
            shift_in_r     <= 8'h00;
            rx_data_o      <= 8'hFF;
            sclk_r         <= 1'b0;
            running_r      <= 1'b0;
        end else begin
            if (!running_r) begin
                // Idle — wait for start
                if (tx_start_i) begin
                    shift_out_r    <= tx_data_i;
                    shift_in_r     <= 8'h00;
                    bit_cnt_r      <= 4'd0;
                    sclk_r         <= 1'b0;
                    prescale_cnt_r <= 7'd0;
                    prescale_max_r <= slow_clk_i ? SLOW_DIV_HALF[6:0] : FAST_DIV_HALF[6:0];
                    running_r      <= 1'b1;
                end
            end else begin
                // Running — prescaler tick
                if (prescale_cnt_r == prescale_max_r) begin
                    prescale_cnt_r <= 7'd0;
                    if (!sclk_r) begin
                        // Rising edge: sample MISO
                        sclk_r <= 1'b1;
                        shift_in_r <= {shift_in_r[6:0], sd_miso_i};
                    end else begin
                        // Falling edge: advance bit, update MOSI
                        sclk_r <= 1'b0;
                        if (bit_cnt_r == 4'd7) begin
                            // Done — latch result (shift_in_r has all 8 bits from rising edges)
                            rx_data_o <= shift_in_r;
                            running_r <= 1'b0;
                        end else begin
                            bit_cnt_r   <= bit_cnt_r + 4'd1;
                            shift_out_r <= {shift_out_r[6:0], 1'b1};
                        end
                    end
                end else begin
                    prescale_cnt_r <= prescale_cnt_r + 7'd1;
                end
            end
        end
    end

endmodule
