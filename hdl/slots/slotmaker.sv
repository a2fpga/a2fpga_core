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

module slotmaker #(
    parameter [7:0] SLOT_CARDS [7:0] = {8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0}
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,

    input [2:0] cfg_slot_i,
    input cfg_wr_i,
    input [7:0] cfg_card_i,
    output [7:0] cfg_card_o,

    output [2:0] slot_sel_o,
    output [7:0] slot_card_o,
    output slot_ioselect_n_o,
    output slot_devselect_n_o,
    output slot_iostrobe_n_o
);

    reg [7:0] slot_cards[0:7] = SLOT_CARDS;

	always @(posedge a2bus_if.clk_logic) begin
		cfg_card_o <= slot_cards[cfg_slot_i];
		if (cfg_wr_i) slot_cards[cfg_slot_i] <= cfg_card_i;
	end

    logic [2:0] slot_sel;

    always_comb begin
        slot_sel = 3'd0;
        if (a2bus_if.phi0 & (a2bus_if.addr >= 16'hC100) & (a2bus_if.addr < 16'hC800) & !a2bus_if.m2sel_n) begin
            slot_sel = a2bus_if.addr[15:8] >> 5;
        end
    end

    logic [7:0] slot_card;
    logic slot_ioselect_n;
    logic slot_devselect_n;
    logic slot_iostrobe_n;

    always_comb begin
        slot_card = slot_sel != 2'd0 ? slot_cards[slot_sel] : 8'd0;
        bit [15:0] IO_ADDRESS = 16'hC000 + (slot_sel << 8);
        bit [15:0] DEVICE_ADDRESS = 16'hC080 + (slot_sel << 4);
        logic enable = slot_card != 8'd0;
        slot_ioselect_n = ~(enable & a2bus_if.phi0 & (a2bus_if.addr[15:8] == IO_ADDRESS[15:8]) & !a2bus_if.m2sel_n) | a2mem_if.INTCXROM;
        slot_devselect_n = ~(enable & a2bus_if.phi0 & (a2bus_if.addr[15:4] == DEVICE_ADDRESS[15:4]) & !a2bus_if.m2sel_n);
        slot_iostrobe_n = ~(enable & a2bus_if.phi0 & (a2bus_if.addr[15:11] == 5'b11001) & !a2bus_if.m2sel_n) | a2mem_if.INTCXROM | a2mem_if.INTC8ROM;
    end

    assign slot_sel_o = slot_sel;
    assign slot_card_o = slot_card;
    assign slot_ioselect_n_o = slot_ioselect_n;
    assign slot_devselect_n_o = slot_devselect_n;
    assign slot_iostrobe_n_o = slot_iostrobe_n;

endmodule

