// DDR3 debug read window — ESP32-driven single-word reads on an otherwise
// idle DDR3 port (port 4; the Ensoniq runs from BSRAM). Gives the ESP32 a
// window into the whole DDR3 word-address map (port base 0): framebuffer,
// shadow, unified graphics region. Built to settle the SHR shape-garble
// question (dump the shadow region the VGC renders from and decode it
// offline), kept as a general-purpose inspection instrument.
//
// Protocol (all clk_logic, same domain as the OSPI connector):
//   req_i pulses with addr_i valid; busy_o rises until the word is captured
//   in data_o. The connector auto-increments its address register on the
//   busy_o falling edge, so streaming = GO, poll busy, read 4 data bytes.
//
// Discrete ports, NOT a mem_port_if port: passing an interface-array
// element into a module port triggers Gowin's interface-array flattening
// bug (see the explicit-wire workaround note in ddr3_ports.sv) — the
// first build of this module with an interface port killed the OSPI link
// wholesale. The member wiring happens with continuous assigns in top.sv.

module ddr3_debug_reader (
    input  wire        clk,
    input  wire        rst_n,

    // mem_port_if members, wired individually in top.sv
    output wire        mem_rd_o,
    output wire [20:0] mem_addr_o,
    input  wire        mem_available_i,
    input  wire        mem_ready_i,
    input  wire [31:0] mem_q_i,

    input  wire [20:0] addr_i,
    input  wire        req_i,
    output reg         busy_o,
    output reg  [31:0] data_o
);

    reg issued_r;

    assign mem_addr_o = addr_i;
    assign mem_rd_o   = busy_o && !issued_r && mem_available_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_o   <= 1'b0;
            issued_r <= 1'b0;
            data_o   <= 32'd0;
        end else begin
            if (!busy_o) begin
                if (req_i) begin
                    busy_o   <= 1'b1;
                    issued_r <= 1'b0;
                end
            end else begin
                if (!issued_r && mem_available_i)
                    issued_r <= 1'b1;   // rd fires this cycle
                if (issued_r && mem_ready_i) begin
                    data_o   <= mem_q_i;
                    busy_o   <= 1'b0;
                    issued_r <= 1'b0;
                end
            end
        end
    end

endmodule
