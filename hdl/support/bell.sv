module bell (
    input clk_50_i,
    input reset_n_i,
    input trigger_i,
    output reg speaker_o,
    output wire done_o
);

    localparam CYCLE_COUNT = 192;
    logic [7:0] cycle_counter;
    localparam CYCLE_WAIT = 26791;
    logic [14:0] wait_counter;
    reg prev_trigger_r;
    reg playing_r;
    assign done_o = !playing_r;

    always @(posedge clk_50_i) begin
        prev_trigger_r <= trigger_i;
    end

    always @(posedge clk_50_i) begin
        if (reset_n_i == 1'b0) begin
            playing_r <= 1'b0;
            cycle_counter <= 0;
            wait_counter <= 0;
            speaker_o <= 1'b0;
        end else begin
            if (!playing_r && !prev_trigger_r && trigger_i) begin
                cycle_counter <= CYCLE_COUNT;
                wait_counter <= CYCLE_WAIT;
                playing_r <= 1'b1;
            end else if (playing_r) begin
                if (wait_counter > 0) begin
                    wait_counter <= wait_counter - 15'd1;
                end else begin
                    speaker_o <= !speaker_o;
                    wait_counter <= CYCLE_WAIT;
                    if (cycle_counter > 0) begin
                        cycle_counter <= cycle_counter - 8'd1;
                    end else begin
                        playing_r <= 1'b0;
                        cycle_counter <= 0;
                        wait_counter <= 0;
                    end
                end
            end else begin
                speaker_o <= 1'b0;
            end
        end
    end


endmodule


