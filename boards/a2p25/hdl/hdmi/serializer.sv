// Using the Gowin OSER10 serializer

module serializer
#(
    parameter int NUM_CHANNELS = 3,
    parameter real VIDEO_RATE = 25.2E6,
    parameter bit POL_INV = 1'b0
)
(
    input logic clk_pixel,
    input logic clk_pixel_x5,
    input logic reset,
    input logic [9:0] tmds_internal [NUM_CHANNELS-1:0],
    output logic [2:0] tmds,
    output logic tmds_clock
);

    wire gwSer0_reset = 1'b0;
    wire gwSer1_reset = 1'b0;
    wire gwSer2_reset = 1'b0;

    wire [9:0] ser0 = tmds_internal[0] ^ {10{POL_INV}};
    wire [9:0] ser1 = tmds_internal[1] ^ {10{POL_INV}};
    wire [9:0] ser2 = tmds_internal[2] ^ {10{POL_INV}}; 

    OSER10 gwSer0( 
        .Q( tmds[ 0 ] ),
        .D0( ser0[ 0 ] ),
        .D1( ser0[ 1 ] ),
        .D2( ser0[ 2 ] ),
        .D3( ser0[ 3 ] ),
        .D4( ser0[ 4 ] ),
        .D5( ser0[ 5 ] ),
        .D6( ser0[ 6 ] ),
        .D7( ser0[ 7 ] ),
        .D8( ser0[ 8 ] ),
        .D9( ser0[ 9 ] ),
        .PCLK( clk_pixel ),
        .FCLK( clk_pixel_x5 ),
        .RESET( gwSer0_reset ) );

    OSER10 gwSer1( 
        .Q( tmds[ 1 ] ),
        .D0( ser1[ 0 ] ),
        .D1( ser1[ 1 ] ),
        .D2( ser1[ 2 ] ),
        .D3( ser1[ 3 ] ),
        .D4( ser1[ 4 ] ),
        .D5( ser1[ 5 ] ),
        .D6( ser1[ 6 ] ),
        .D7( ser1[ 7 ] ),
        .D8( ser1[ 8 ] ),
        .D9( ser1[ 9 ] ),
        .PCLK( clk_pixel ),
        .FCLK( clk_pixel_x5 ),
        .RESET( gwSer1_reset ) );

    OSER10 gwSer2( 
        .Q( tmds[ 2 ] ),
        .D0( ser2[ 0 ] ),
        .D1( ser2[ 1 ] ),
        .D2( ser2[ 2 ] ),
        .D3( ser2[ 3 ] ),
        .D4( ser2[ 4 ] ),
        .D5( ser2[ 5 ] ),
        .D6( ser2[ 6 ] ),
        .D7( ser2[ 7 ] ),
        .D8( ser2[ 8 ] ),
        .D9( ser2[ 9 ] ),
        .PCLK( clk_pixel ),
        .FCLK( clk_pixel_x5 ),
        .RESET( gwSer2_reset ) );
        
    assign tmds_clock = clk_pixel ^ POL_INV;
  
endmodule
