// Super Serial Card
//
// The Super Serial Card is a serial card for the Apple II. It has a 6551 UART and a 2k ROM.
// The 6551 is a serial chip that can be used for RS232 communication.
// The 2k ROM contains the firmware for the card.
//
// Adapted from:
// https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/ssc/super_serial_card.v
// 
// Adapted for use with A2FPGA multicard bus interface
//
// Using the Gary Becker 6551 UART core
//


module SuperSerial #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter bit IRQ_ENABLE = 1'b1,
    parameter bit [7:0] ID = 3,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,

    output rom_en_o,

    input  uart_rx_i,
    output uart_tx_o

);

    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0) begin  // disable all cards when slot 0 is selected for configuration
                card_enable <= 1'b0;
            end else if (slot_if.card_id == ID) begin // enable this card
                card_enable <= slot_if.card_enable && ENABLE;
            end
        end
    end

    wire card_sel = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel = card_sel && !slot_if.dev_select_n;
    wire card_io_sel = card_sel && !slot_if.io_select_n;
    wire card_io_strobe = !slot_if.io_strobe_n && a2bus_if.phi0;

    wire UART51_RTS;
    wire UART51_DTR;

    //  The Super Serial Card has 
    //  a 2k rom.
    //  The 256byte section actually starts at address 0x700
    //  The full 2k rom is mapped in when the card is selected (into a shared
    //  address space)
    //
    //  All cards unamp their 2k rom when they see CFFF1
    //  

    //
    // Super Serial Rom
    //
    wire [7:0] DOA_C8S;
    wire [7:0] DATA_SERIAL_OUT;
    wire [7:0] SSC;

    // NOT SURE WHAT THIS IS DOING - are there dips on the card? Check manual. Maybe move this to the framework.

    // DATA_SERIAL_OUT can contain Data, Status, command or control - because a2bus_if.addr[1:0] is passed to the serial chip - and it has a mux in the chip.
    // we need to HANDLE C081 - DIPSW1 and  C082 - DIPSW2 

    // Addr = 0h01           
    // 7 - SW1-1 = OFF=1
    // 6 - SW1-2 = OFF=1
    // 5 - SW1-3 = OFF=1
    // 4 - SW1-4 = ON=0
    // 3 - X     = 1
    // 2 - X     = 1
    // 1 - SW1-5 = ON=0
    // 0 - SW1-6 = ON=0
    localparam [7:0] SW1_CONFIG = 8'b11101100;

    // Addr = 0h02
    // 7 - SW2-1 = ON=0
    // 6 - X     = 1
    // 5 - SW2-2 = ON=0
    // 4 - X     = 1
    // 3 - SW2-3 = ON=0
    // 2 - SW2-4 = ON=0
    // 1 - SW2-5 = ON=0
    // 0 - CTS
    localparam [6:0] SW2_CONFIG = 7'b0101000;

    assign SSC =(a2bus_if.addr[3:0] == 4'h1) ? SW1_CONFIG:
        (a2bus_if.addr[3:0]  == 4'h2) ? {SW2_CONFIG, UART51_RTS}:
        (a2bus_if.addr[3]    == 1'b1) ? DATA_SERIAL_OUT:
        8'b11111111;

    /*
        Map and Unmap the ROM - setup rom_en_o and ENA_C8S
    */

    wire ENA_C8S;
    reg  C8S2;
    wire APPLE_C0;

    assign APPLE_C0 = a2bus_if.addr[15:8] == 8'b11000000;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            C8S2 <= 1'b0;
        end else begin
            case (a2bus_if.addr[15:8])
                8'hC2: begin
                    if (!a2mem_if.INTCXROM)  // SSC ROM
                        C8S2 <= 1'b1;
                end
                8'hCF: begin
                    if (!a2mem_if.INTCXROM) begin
                        if (a2bus_if.addr[7:0] == 8'hFF) C8S2 <= 1'b0;
                    end
                end
            endcase
        end
    end

    assign ENA_C8S  = {(C8S2 & !a2mem_if.INTCXROM), a2bus_if.addr[15:11]} == 6'b111001;
    assign rom_en_o = ENA_C8S;
    //assign data_o2 = ENA_C8S ? DOA_C8S : SSC;

    wire [10:0] ROM_ADDR = rom_en_o ? a2bus_if.addr[10:0] : {3'b111, a2bus_if.addr[7:0]};
    assign data_o = card_io_sel ? DOA_C8S : (rom_en_o && card_io_strobe) ? DOA_C8S : SSC;
    assign rd_en_o = card_enable && a2bus_if.rw_n && (card_io_sel || (rom_en_o && card_io_strobe) || card_dev_sel);

    ssc_rom rom (
        .clk (a2bus_if.clk_logic),
        .addr(ROM_ADDR),
        .data(DOA_C8S)
    );

    //
    //  Serial Port
    //

    assign irq_n_o = SER_IRQ || !card_enable || !IRQ_ENABLE;
    wire SER_IRQ;

    glb6551 #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) COM2 (
        .clk_logic_i(a2bus_if.clk_logic),
        .RESET_N(a2bus_if.system_reset_n),
        .PH_2(a2bus_if.phi1_posedge),
        .DI(a2bus_if.data),
        .DO(DATA_SERIAL_OUT),
        .IRQ(SER_IRQ),
        // IS THIS DEVICE SELECT OR IO_SELECT?
        .CS({
            !a2bus_if.addr[3], card_dev_sel
        }),  // C0A8-C0AF // we should be able to use IO_SELECT_N and it should reference our slot - and make it movable i think
        .RW_N(a2bus_if.rw_n),
        .RS(a2bus_if.addr[1:0]),
        .TXDATA_OUT(uart_tx_o),
        .RXDATA_IN(uart_rx_i),
        .RTS(UART51_RTS),
        .CTS(UART51_RTS),
        .DCD(UART51_DTR),
        .DTR(UART51_DTR),
        .DSR(UART51_DTR)
    );


endmodule

