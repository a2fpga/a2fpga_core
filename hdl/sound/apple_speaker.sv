module apple_speaker (
    a2bus_if.slave a2bus_if,
    input enable,
    output reg speaker_o
);

   reg speaker_bit;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            speaker_bit <= 1'b0;
        end else if (a2bus_if.phi1_posedge && (a2bus_if.addr[15:0] == 16'hC030) && !a2bus_if.m2sel_n) 
            speaker_bit <= !speaker_bit;
    end

    localparam COUNTDOWN_WIDTH = 24;
    reg [COUNTDOWN_WIDTH - 1:0] countdown;
    reg prev_speaker_bit;

    always_ff @(posedge a2bus_if.phi1_posedge) begin
        if (speaker_bit != prev_speaker_bit) begin
            countdown <= '1;
        end else begin
            countdown <= countdown != 0 ? COUNTDOWN_WIDTH'(countdown - 1) : '0;
        end
        prev_speaker_bit <= speaker_bit;

        if ((countdown != 0) && enable) begin
            if (speaker_bit) begin
                speaker_o <= 1;
            end else begin
                speaker_o <= 0;
            end
        end else begin
            speaker_o <= 0;
        end
    end

endmodule