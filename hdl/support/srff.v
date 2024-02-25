module srff (
    input wire clk,
    input wire s,
    input wire r,
    output wire q
);

    reg prev_s_r;
    reg prev_r_r;
    reg q_r;
    wire edge_s_w = s & ~prev_s_r;
    wire edge_r_w = r & ~prev_r_r;

    assign q = (edge_s_w & !edge_r_w) | q_r;

    always @(posedge clk) begin
        prev_s_r <= s;
        prev_r_r <= r;
        if (edge_r_w)
            q_r <= 0;
        else if (edge_s_w)
            q_r <= 1;
    end

endmodule