module a2bus_timing #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,                      // 18.52 ns
    parameter int APPLE_HZ = 14_318_181,
    parameter bit ENABLE_DENOISE = 0                                // 0 = use cdc, 1 = use cdc_denoise
) (
    input  clk_logic_i,
    input  a2_phi1_i,
    input  a2_q3_i,
    input  a2_7M_i,

    output phi0_o,
    output phi0_posedge_o,
    output phi0_negedge_o,

    output phi1_o,
    output phi1_posedge_o,
    output phi1_negedge_o,

    output q3_o,
    output q3_posedge_o,
    output q3_negedge_o,

    output clk_7M_o,
    output clk_7M_posedge_o,
    output clk_7M_negedge_o,

    output clk_14M_posedge_o
);

    generate
        if (ENABLE_DENOISE) begin : gen_denoise
            // Use cdc_denoise for systems that need additional noise filtering
            // This adds latency but improves signal stability
            cdc_denoise cdc_phi0 (
                .clk(clk_logic_i),
                .i(~a2_phi1_i),
                .o(phi0_o),
                .o_n(),
                .o_posedge(phi0_posedge_o),
                .o_negedge(phi0_negedge_o)
            );

            cdc_denoise cdc_phi1 (
                .clk(clk_logic_i),
                .i(a2_phi1_i),
                .o(phi1_o),
                .o_n(),
                .o_posedge(phi1_posedge_o),
                .o_negedge(phi1_negedge_o)
            );

            cdc_denoise cdc_q3 (
                .clk(clk_logic_i),
                .i(a2_q3_i),
                .o(q3_o),
                .o_n(),
                .o_posedge(q3_posedge_o),
                .o_negedge(q3_negedge_o)
            );

            cdc_denoise cdc_7M (
                .clk(clk_logic_i),
                .i(a2_7M_i),
                .o(clk_7M_o),
                .o_n(),
                .o_posedge(clk_7M_posedge_o),
                .o_negedge(clk_7M_negedge_o)
            );
        end else begin : gen_no_denoise
            // Use basic cdc for lower latency
            cdc cdc_phi0 (
                .clk(clk_logic_i),
                .i(~a2_phi1_i),
                .o(phi0_o),
                .o_n(),
                .o_posedge(phi0_posedge_o),
                .o_negedge(phi0_negedge_o)
            );

            cdc cdc_phi1 (
                .clk(clk_logic_i),
                .i(a2_phi1_i),
                .o(phi1_o),
                .o_n(),
                .o_posedge(phi1_posedge_o),
                .o_negedge(phi1_negedge_o)
            );

            cdc cdc_q3 (
                .clk(clk_logic_i),
                .i(a2_q3_i),
                .o(q3_o),
                .o_n(),
                .o_posedge(q3_posedge_o),
                .o_negedge(q3_negedge_o)
            );

            cdc cdc_7M (
                .clk(clk_logic_i),
                .i(a2_7M_i),
                .o(clk_7M_o),
                .o_n(),
                .o_posedge(clk_7M_posedge_o),
                .o_negedge(clk_7M_negedge_o)
            );
        end
    endgenerate

    assign clk_14M_posedge_o = clk_7M_posedge_o | clk_7M_negedge_o;

endmodule
