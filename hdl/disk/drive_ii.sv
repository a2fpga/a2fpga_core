
// WORK IN PROGRESS
//
// Drive II
//
// Adapted from:
// https://github.com/alanswx/Apple-II-Verilog_MiSTer/blob/master/rtl/drive_ii.v
// https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/drive_ii.vhd
//
// Adapted for use with A2FPGA multicard bus interface
//
// Uses A2FPGA SDRAM controller for disk storage and requires the use
// of the PicoSoC core to provide the FAT32 file system interface
//
// Current status: Functional with hardcoded disk images
//

module drive_ii (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,

    drive_volume_if.drive volume_if,

    input drive_id_i,
    input drive_active,
    input [3:0] motor_phase_i,
    input write_mode_i,
    input read_disk_i,
    input write_reg_i,

    sdram_port_if.client ram_disk_if
);

    assign volume_if.active = drive_active;
    assign volume_if.lba = '0;
    assign volume_if.blk_cnt = '0;
    assign volume_if.rd = 1'b0;
    assign volume_if.wr = 1'b0;


    logic [5:0] track_w;  // output to ramdisk
    logic [12:0] track_addr_w;  // output to ramdisk
    logic [7:0] track_di_w;  // output to ramdisk
    logic [7:0] track_do_w;  // input from ramdisk
    reg track_we_r;  // output to ramdisk
    reg track_rd_r;  // output to ramdisk
    logic track_busy_w;  // input from ramdisk

    assign track_busy_w = 1'b0;

    reg [7:0] phase_r;

    reg [12:0] track_byte_addr_r;
    reg [7:0] data_r;
    reg reset_data_r;


    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : update_phase
        automatic integer phase_change_temp;
        automatic integer new_phase_temp;
        automatic logic [3:0] rel_phase_temp;
        if (!a2bus_if.system_reset_n) phase_r <= 70;
        else begin
            if (a2bus_if.clk_14m_posedge) begin
                if (drive_active) begin
                    phase_change_temp = 0;
                    new_phase_temp = phase_r;
                    rel_phase_temp = motor_phase_i;
                    case (phase_r[2:1])
                        2'b00:   rel_phase_temp = {rel_phase_temp[1:0], rel_phase_temp[3:2]};
                        2'b01:   rel_phase_temp = {rel_phase_temp[2:0], rel_phase_temp[3]};
                        2'b10:   ;
                        2'b11:   rel_phase_temp = {rel_phase_temp[0], rel_phase_temp[3:1]};
                        default: ;
                    endcase

                    if (phase_r[0] == 1'b1)
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -3;
                            4'b0010: phase_change_temp = -1;
                            4'b0011: phase_change_temp = -2;
                            4'b0100: phase_change_temp = 1;
                            4'b0101: phase_change_temp = -1;
                            4'b0110: phase_change_temp = 0;
                            4'b0111: phase_change_temp = -1;
                            4'b1000: phase_change_temp = 3;
                            4'b1001: phase_change_temp = 0;
                            4'b1010: phase_change_temp = 1;
                            4'b1011: phase_change_temp = -3;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase
                    else
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -2;
                            4'b0010: phase_change_temp = 0;
                            4'b0011: phase_change_temp = -1;
                            4'b0100: phase_change_temp = 2;
                            4'b0101: phase_change_temp = 0;
                            4'b0110: phase_change_temp = 1;
                            4'b0111: phase_change_temp = 0;
                            4'b1000: phase_change_temp = 0;
                            4'b1001: phase_change_temp = 1;
                            4'b1010: phase_change_temp = 2;
                            4'b1011: phase_change_temp = -2;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase

                    if (new_phase_temp + phase_change_temp <= 0) new_phase_temp = 0;
                    else if (new_phase_temp + phase_change_temp > 139) new_phase_temp = 139;
                    else new_phase_temp = new_phase_temp + phase_change_temp;
                    phase_r <= 8'(new_phase_temp);
                end
            end
        end
    end

    assign track_w = phase_r[7:2];

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : read_head
        static reg [5:0] byte_delay_r;
        if (!a2bus_if.system_reset_n) begin
            track_byte_addr_r <= 13'b0;
            byte_delay_r = 6'b0;
            reset_data_r <= 1'b0;
        end else begin
            track_we_r <= 1'b0;
            track_rd_r <= 1'b0;

            if (a2bus_if.clk_2m_posedge & volume_if.ready & drive_active) begin
                byte_delay_r = 6'(byte_delay_r - 1);

                if (!write_mode_i) begin
                    if (reset_data_r) begin
                        data_r <= 8'b0;
                        reset_data_r <= 1'b0;
                    end

                    if (byte_delay_r == 0) begin
                        data_r <= track_do_w;
                        if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                        else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                        track_rd_r <= 1'b1;
                    end
                    if (read_disk_i & a2bus_if.phi0) reset_data_r <= 1'b1;
                end else begin
                    if (write_reg_i) data_r <= a2bus_if.data;
                    if (read_disk_i & a2bus_if.phi0) begin
                        track_we_r <= (~track_busy_w);
                        if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                        else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                    end
                end
            end
        end
    end

    assign data_o = data_r;
    assign track_addr_w = track_byte_addr_r;
    assign track_di_w = data_r;

    wire [19:0] ramdisk_addr_w = ((track_w * 8'h1a) << 8) + track_byte_addr_r;

    assign ram_disk_if.addr = {3'b0, 1'b1, drive_id_i, ramdisk_addr_w[17:2]};
    assign ram_disk_if.rd = track_rd_r;
    assign ram_disk_if.data = 32'b0;
    assign ram_disk_if.byte_en = 4'b1111;
    assign ram_disk_if.wr = 1'b0;
    //assign track_do_w = ram_disk_if.q >> ((ramdisk_addr_w[1:0] ^ 2'b11) << 3); // 0,1,2,3 -> 3,2,1,0
    //assign track_do_w = 8'(ram_disk_if.q >> (ramdisk_addr_w[1:0] << 3));
    assign track_do_w = ram_disk_if.q[ramdisk_addr_w[1:0]*8+:8];

endmodule
