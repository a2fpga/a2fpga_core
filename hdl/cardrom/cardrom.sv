module CardROM #(
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,
    output rd_en_o,
    output inh_n_o,
    input req_rom_release_i
);

    wire cardrom_sel = ENABLE && a2bus_if.phi0 && (a2bus_if.addr[15:12] == 4'b1111) & !a2bus_if.m2sel_n;
    wire cardrom_f8_sel = cardrom_sel && a2bus_if.addr[11];

    reg rom_inh_r;
    assign inh_n_o = ~(rom_inh_r && cardrom_sel);
    
    reg fpga_done_r;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            rom_inh_r <= 1'b1;
            fpga_done_r <= 1'b0;
        end else if (rom_inh_r) begin
            if (req_rom_release_i) fpga_done_r <= 1'b1;
            if (fpga_done_r & (a2bus_if.addr == 16'hFFFC)) begin
                rom_inh_r <= 1'b0;
            end
        end
    end

    reg[7:0] cardrom[2047:0];
    initial $readmemh("cardrom.hex", cardrom, 0);
    reg [7:0] rom_out;

    always @(posedge a2bus_if.clk_logic) rom_out <= cardrom[a2bus_if.addr[10:0]];

    assign data_o = cardrom_f8_sel ? rom_out : {7'b0, fpga_done_r};

    assign rd_en_o = cardrom_sel && rom_inh_r && a2bus_if.rw_n;


endmodule
