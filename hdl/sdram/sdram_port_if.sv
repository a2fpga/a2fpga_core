//
// SystemVerilog interface for a SDRAM port
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
// SystemVerilog interface for a SDRAM port
//

interface sdram_port_if #(
    parameter PORT_ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 16,
    parameter DQM_WIDTH = 2,
    parameter PORT_OUTPUT_WIDTH = DATA_WIDTH * 2
);

    logic [PORT_ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    logic [DQM_WIDTH-1:0] byte_en;    // Byte enable for writes
    logic [PORT_OUTPUT_WIDTH-1:0] q;

    logic wr;
    logic rd;

    logic available;                 // The port is able to be used
    logic ready;                      // The port has finished its task. Will rise for a single cycle

    modport controller (
        input addr,
        input data,
        input byte_en,
        output q,

        input wr,
        input rd,

        output available,
        output ready
    );

    modport client (
        output addr,
        output data,
        output byte_en,
        input q,

        output wr,
        output rd,

        input available,
        input ready
    );

endinterface: sdram_port_if
