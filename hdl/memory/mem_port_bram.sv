//
// Blockram-backed memory port adapter
//
// (c) 2023,2024,2025 Ed Anuff <ed@a2fpga.com>
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
// Provides a mem_port_if interface backed by inferred blockram using
// sdpram32. One port is dedicated for writes, one for reads.
//

module mem_port_bram #(
    parameter ADDR_WIDTH = 14  // 16K words x 4 bytes = 64KB
) (
    input clk,
    mem_port_if.controller write_port,
    mem_port_if.controller read_port
);

    // Internal signals from sdpram32
    wire [31:0] read_data_w;

    // Instantiate the blockram
    sdpram32 #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) bram (
        .clk(clk),
        .write_addr(write_port.addr[ADDR_WIDTH-1:0]),
        .write_data(write_port.data),
        .write_enable(write_port.wr),
        .byte_enable(write_port.byte_en),
        .read_addr(read_port.addr[ADDR_WIDTH-1:0]),
        .read_enable(read_port.rd),
        .read_data(read_data_w)
    );

    // Write port: generate ready 1 cycle after wr
    reg write_ready_r;
    always_ff @(posedge clk) begin
        write_ready_r <= write_port.wr;
    end

    assign write_port.ready = write_ready_r;
    assign write_port.available = 1'b1;
    assign write_port.q = '0;

    // Read port: generate ready 2 cycles after rd (matching sdpram32 pipeline)
    reg read_pending_r;
    reg read_ready_r;
    always_ff @(posedge clk) begin
        read_pending_r <= read_port.rd;
        read_ready_r <= read_pending_r;
    end

    assign read_port.ready = read_ready_r;
    assign read_port.available = 1'b1;
    assign read_port.q = read_data_w;

endmodule
