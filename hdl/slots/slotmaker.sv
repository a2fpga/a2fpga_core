//
// Virtual slot controller for the A2FPGA
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// Enables the configuration and switching of virtual card slots in the A2FPGA
//

module slotmaker (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,

    slotmaker_config_if.slotmaker cfg_if,

    slot_if.slotmaker slot_if
);

    //reg [7:0] slot_cards[0:7] = '{8'd0, 8'd3, 8'd0, 8'd0, 8'd2, 8'd0, 8'd0, 8'd5};

    reg [7:0] slot_cards[0:7];
	initial $readmemh("slots.hex", slot_cards);

    //assign cfg_if.card_o = 8'd0;

    reg [7:0] card_o;
	always @(posedge a2bus_if.clk_logic) begin
		if (cfg_if.wr) begin 
            slot_cards[cfg_if.slot] <= cfg_if.card_i;
            card_o <= cfg_if.card_i;
        end else begin
            card_o <= slot_cards[cfg_if.slot];
        end 
	end
    /*
    reg [7:0] card_o;
	always @(posedge a2bus_if.clk_logic) begin
        card_o <= slot_cards[cfg_if.slot];
		if (cfg_if.wr) begin 
            slot_cards[cfg_if.slot] <= cfg_if.card_i;
        end 
	end
    */

    assign cfg_if.card_o = card_o;

    // 1111 1100 0000 0000
    // 5432 1098 7654 3210

    // 1100 0000 1XXX ---- 
    // 1100 0000 1000 0000  $C080
    // 1100 0000 1111 1111  $C0FF

    localparam bit [8:0] SLOT_DEVICE_SPACE = 9'b1100_0000_1;

    // 1100 0XXX ---- ----
    // 1100 0001 0000 0000  $C100
    // 1100 0010 0000 0000  $C200
    // 1100 0111 1111 1111  $C7FF

    localparam bit [4:0] SLOT_IO_SPACE = 5'b1100_0;

    // 1100 1--- ---- ----
    // 1100 1000 0000 0000  $C800
    // 1100 1001 0000 0000  $C900
    // 1100 1111 1111 1111  $CFFF

    localparam bit [4:0] SLOT_C8_SPACE = 5'b1100_1;

    logic [2:0] slot_sel;
    logic dev_sel;
    logic io_sel;
    logic c8_sel;

    always_comb begin
        slot_sel = 3'd0;
        dev_sel = 1'b0;
        io_sel = 1'b0;
        c8_sel = 1'b0;
        if ((a2bus_if.addr[15:7] == SLOT_DEVICE_SPACE) & !a2bus_if.m2sel_n) begin  // 0xC080 - 0xC0FF
            slot_sel = a2bus_if.addr[6:4];
            dev_sel = 1'b1;
        end else if ((a2bus_if.addr[15:11] == SLOT_IO_SPACE) & !a2bus_if.m2sel_n) begin // 0xC100 - 0xC7FF
            slot_sel = a2bus_if.addr[10:8];
            io_sel = 1'b1;
        end else if ((a2bus_if.addr[15:11] == SLOT_C8_SPACE) & !a2bus_if.m2sel_n) begin // 0xC800 - 0xCFFF
            c8_sel = 1'b1;
        end 
    end

    reg [7:0] slot_card;
    always @(posedge a2bus_if.clk_logic) begin
        slot_card <= slot_cards[slot_sel];
    end

    logic disabled;
    logic slot_ioselect_n;
    logic slot_devselect_n;
    logic slot_iostrobe_n;

    always_comb begin
        disabled = slot_card == 8'd0;
        slot_devselect_n = disabled | !dev_sel;
        slot_ioselect_n = disabled | a2mem_if.INTCXROM | !io_sel;
        slot_iostrobe_n = a2mem_if.INTCXROM | a2mem_if.INTC8ROM | !c8_sel;
    end

    assign slot_if.slot = slot_sel;
    assign slot_if.card_id = slot_card;
    assign slot_if.ioselect_n = slot_ioselect_n;
    assign slot_if.devselect_n = slot_devselect_n;
    assign slot_if.iostrobe_n = slot_iostrobe_n;

endmodule

