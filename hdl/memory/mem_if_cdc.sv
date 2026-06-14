module mem_if_cdc #(
    parameter N = 3   // Stretch factor, default value set to 3 (2X clock diff + 1)
)
(
    input clk_controller,
    input clk_client,
    mem_port_if.client controller,
    mem_port_if.controller client
);

    pulse_crossing #(.N(N)) mem_ready_pulse (
        .clk_src(clk_controller),
        .clk_dst(clk_client),
        .pulse_src(controller.ready),
        .pulse_dst(client.ready)
    );

    assign controller.addr = client.addr;
    assign controller.data = client.data;
    assign controller.byte_en = client.byte_en;
    assign client.q = controller.q;
    assign controller.wr = client.wr;
    assign controller.rd = client.rd;
    assign controller.burst = client.burst;
    assign client.available = controller.available;

endmodule
