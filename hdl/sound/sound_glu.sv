//
// IIgs GLU
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
// The GLU interfaces the Ensoniq DOC5503 sound chip to the Apple II bus
//

module sound_glu #(
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,
    output rd_en_o,

    output [15:0] audio_l_o,
    output [15:0] audio_r_o,

    output [7:0] debug_osc_en_o,  // Debug output for oscillator enable register
    output [1:0] debug_osc_mode_o[8], // Debug output for oscillator mode register;
    output [7:0] debug_osc_halt_o, // Debug output for oscillator halt register

    sdram_port_if.client glu_mem_if,
    sdram_port_if.client doc_mem_if
    
);

    reg [7:0] sound_control_r;      // Sound Control Register
    reg [7:0] sound_data_r;         // Sound Data Register 
    reg [7:0] sound_ptr_lo_r;       // Sound Pointer Lo Register
    reg [7:0] sound_ptr_hi_r;       // Sound Pointer Hi Register

    localparam [15:0] SOUND_CONTROL_ADDR = 16'hC03C;
    localparam [15:0] SOUND_DATA_ADDR = 16'hC03D;
    localparam [15:0] SOUND_PTR_LO_ADDR = 16'hC03E;
    localparam [15:0] SOUND_PTR_HI_ADDR = 16'hC03F;

    // address in GLU range, $C03C-$C03F, during phi0 and m2sel_n asserted
    wire glu_sel_w = ENABLE & a2bus_if.phi0 & (a2bus_if.addr[15:2] == SOUND_CONTROL_ADDR[15:2]) & !a2bus_if.m2sel_n;
    // sound control register is at $C03C
    wire sc_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b00);
    // sound data register is at $C03D
    wire sd_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b01);
    // address pointer lo register is at $C03E
    wire spl_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b10);
    // address pointer hi register is at $C03F
    wire sph_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b11);

    // all accesses are to the dedicated 64K sound RAM
    wire access_ram_w = sound_control_r[6];
    // all accesses are to the DOC
    wire access_doc_w = ~access_ram_w;
    // auto increment address pointer
    wire auto_inc_w = sound_control_r[5];
    // volume control, 0 is lowest, 15 is highest
    wire [3:0] volume_w = sound_control_r[3:0];

    //assign rd_en_o = glu_sel_w & a2bus_if.rw_n;
    assign rd_en_o = 1'b0;

    logic [7:0] doc_data_o_w;

    assign data_o = a2bus_if.addr[1:0] == 2'b00 ? sound_control_r :
        (a2bus_if.addr[1:0] == 2'b01) & access_ram_w ? sound_data_r :
        (a2bus_if.addr[1:0] == 2'b01) & access_doc_w ? doc_data_o_w :
        a2bus_if.addr[1:0] == 2'b10 ? sound_ptr_lo_r :
        sound_ptr_hi_r;

    // write only for a2fpga, will need to implement reads at alternate address
    // and for future standalone IIgs core
    assign glu_mem_if.rd = '0;
    // DOC memory is at 0x4_0000/8 or 0x1_0000/32
    reg [20:0] glu_mem_addr_r;
    assign glu_mem_if.addr = glu_mem_addr_r;
    reg glu_mem_wr_r;
    assign glu_mem_if.wr = glu_mem_wr_r;
    reg [3:0] glu_mem_byte_en_r;
    assign glu_mem_if.byte_en = glu_mem_byte_en_r;
    assign glu_mem_if.data = {a2bus_if.data, a2bus_if.data, a2bus_if.data, a2bus_if.data};

    reg doc_wr_r;
    reg [7:0] doc_addr_r;

    always_ff @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.system_reset_n) begin
            glu_mem_wr_r <= 1'b0;
            glu_mem_addr_r <= 21'h0;
            glu_mem_byte_en_r <= 4'b1111;
            sound_control_r <= 8'h0F;
            sound_data_r <= 8'h00;
            sound_ptr_lo_r <= 8'h00;
            sound_ptr_hi_r <= 8'h00;
        end else begin
            glu_mem_wr_r <= 1'b0;
            doc_wr_r <= 1'b0;
            if (ENABLE && glu_sel_w && a2bus_if.data_in_strobe) begin
                if (!a2bus_if.rw_n) begin
                    case (a2bus_if.addr[1:0])
                        2'b00: sound_control_r <= a2bus_if.data;
                        2'b01: begin
                            sound_data_r <= a2bus_if.data;
                            if (access_ram_w) begin
                                // write to sound RAM
                                glu_mem_wr_r <= 1'b1;
                                glu_mem_addr_r <= {4'b0, 1'b1, 2'b0, sound_ptr_hi_r, sound_ptr_lo_r[7:2]};
                                glu_mem_byte_en_r <= 1'b1 << sound_ptr_lo_r[1:0];
                            end else if (access_doc_w) begin
                                // write to DOC
                                doc_wr_r <= 1'b1;
                                doc_addr_r <= sound_ptr_lo_r;
                            end
                            if (auto_inc_w) begin
                                {sound_ptr_hi_r, sound_ptr_lo_r} <= {sound_ptr_hi_r, sound_ptr_lo_r} + 1'd1;
                            end
                        end
                        2'b10: sound_ptr_lo_r <= a2bus_if.data;
                        2'b11: sound_ptr_hi_r <= a2bus_if.data;
                    endcase
                end else begin
                    if (a2bus_if.addr[1:0] == 2'b01) begin
                        if (auto_inc_w) begin
                            {sound_ptr_hi_r, sound_ptr_lo_r} <= {sound_ptr_hi_r, sound_ptr_lo_r} + 1'd1;
                        end
                    end
                end
            end

        end

    end

    // DOC Memory Interface
    // All DOC logic in the sound module is clocked by clk_logic

    wire [15:0] wave_addr_w;
    wire doc_mem_rd_w;

    assign doc_mem_if.wr = '0;
    assign doc_mem_if.data = '0;
    assign doc_mem_if.byte_en = 4'b1111;
    assign doc_mem_if.addr = {4'b0, 1'b1, 2'b0, wave_addr_w[15:2]};
    assign doc_mem_if.rd = ENABLE && doc_mem_rd_w;

    reg [1:0] doc_mem_offset_r;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (doc_mem_rd_w) begin
            doc_mem_offset_r <= wave_addr_w[1:0];
        end
    end

    reg [7:0] wave_data_r;
    reg wave_data_ready_r;
    always_ff @(posedge a2bus_if.clk_logic) begin
        wave_data_ready_r <= 1'b0;
        if (doc_mem_if.ready) begin
            wave_data_r <= doc_mem_if.q[8*doc_mem_offset_r +: 8];
            wave_data_ready_r <= 1'b1;
        end
    end

    //wire signed [15:0] mono_mix_w;
    wire signed [15:0] left_mix_w;
    wire signed [15:0] right_mix_w;
    //wire signed [15:0] channel_w[15:0]; 

    // Debug: Capture and expose the oscillator enable register
    wire [7:0] debug_doc_osc_en_w;
    assign debug_osc_en_o = debug_doc_osc_en_w;

    wire [1:0] debug_osc_mode_w[8];
    assign debug_osc_mode_o = debug_osc_mode_w;
    wire [7:0] debug_osc_halt_w;
    assign debug_osc_halt_o = debug_osc_halt_w;

    doc5503 #(
    ) doc5503 (
        .clk_i(a2bus_if.clk_logic),
        .reset_n_i(a2bus_if.system_reset_n),
        .clk_en_i(a2bus_if.clk_7m_posedge),
        .cs_n_i(~doc_wr_r),
        .we_n_i(1'b0),
        .addr_i(doc_addr_r),
        .data_i(a2bus_if.data),
        .data_o(doc_data_o_w),
        .wave_address_o(wave_addr_w),
        .wave_rd_o(doc_mem_rd_w),
        .wave_data_ready_i(wave_data_ready_r),
        .wave_data_i(wave_data_r),
        .left_mix_o(left_mix_w),
        .right_mix_o(right_mix_w),
        .mono_mix_o(),
        .channel_o(),
        .ready_o(),
        .debug_osc_en_o(debug_doc_osc_en_w),
        .debug_osc_mode_o(debug_osc_mode_w),
        .debug_osc_halt_o(debug_osc_halt_w)
    );

    // Volume is inverted for right shift (0 is min volume, 15 is max volume)
    // IIgs volume control ranges from 0-15, invert for right shift (0=lots of shift, 15=no shift)
    logic [3:0] volume_shift_w = volume_w < 12 ? 4'd4 - {2'b0, volume_w[3:2]} : 4'd0;
    
    // Output registers for audio with zero-centering preserved
    reg signed [15:0] audio_l_reg;
    reg signed [15:0] audio_r_reg;
    
    // Assign outputs from registers
    assign audio_l_o = audio_l_reg;
    assign audio_r_o = audio_r_reg;
    
    always_ff @(posedge a2bus_if.clk_logic) begin
        // Apply volume control by right shifting the mix values
        //audio_l_reg <= left_mix_w >>> volume_shift_w;
        //audio_r_reg <= right_mix_w >>> volume_shift_w;
        audio_l_reg <= left_mix_w;
        audio_r_reg <= right_mix_w;
    end
    //assign audio_l_o = channel_w[0] >>> (4'd15 - volume_w);
    //assign audio_r_o = channel_w[0] >>> (4'd15 - volume_w);
    //assign audio_l_o = channel_w[1] >>> (4'd15 - volume_w);
    //assign audio_r_o = channel_w[2] >>> (4'd15 - volume_w);

endmodule