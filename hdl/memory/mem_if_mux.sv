//
// Memory port mux
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
// Multiplexes two memory ports to a single controller port
//

module mem_if_mux (
    input switch,
    mem_port_if.client controller,
    mem_port_if.controller client_0,
    mem_port_if.controller client_1
);

    always @* begin : mux
        if (!switch) begin
            controller.addr = client_0.addr;
            controller.data = client_0.data;
            controller.byte_en = client_0.byte_en;
            client_0.q = controller.q;
            controller.wr = client_0.wr;
            controller.rd = client_0.rd;
            controller.burst = client_0.burst;
            client_0.available = controller.available;
            client_0.ready = controller.ready;

            client_1.q = '0;
            client_1.available = 1'b0;
            client_1.ready = 1'b0;
        end else begin
            controller.addr = client_1.addr;
            controller.data = client_1.data;
            controller.byte_en = client_1.byte_en;
            client_1.q = controller.q;
            controller.wr = client_1.wr;
            controller.rd = client_1.rd;
            controller.burst = client_1.burst;
            client_1.available = controller.available;
            client_1.ready = controller.ready;

            client_0.q = '0;
            client_0.available = 1'b0;
            client_0.ready = 1'b0;
        end
    end

endmodule
