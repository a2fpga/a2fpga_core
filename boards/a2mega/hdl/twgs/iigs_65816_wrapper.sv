module iigs_65816_wrapper (
    // FPGA system
    input  logic        clk,           // 54MHz FPGA clock
    input  logic        rst_n,
    
    // IIgs bus interface
    input  logic        phi2_in,
    output logic [15:0] addr_out,
    input  logic [7:0]  data_in,
    output logic [7:0]  data_out,
    output logic        data_oe,
    output logic        rwb,
    output logic        vp_n,
    input  logic        rdy_in,
    input  logic        irq_n_in,
    input  logic        nmi_n_in,
    input  logic        res_n_in,
    input  logic        abort_n_in,
    
    // Debug
    output logic [23:0] dbg_addr,
    output logic [3:0]  dbg_state
);

    //=========================================================================
    // Types
    //=========================================================================
    
    typedef enum logic [3:0] {
        ST_RESET,
        ST_PHI1_SETUP,
        ST_PHI1_HOLD,
        ST_PHI2_SETUP,
        ST_PHI2_DATA,
        ST_PHI2_SAMPLE,
        ST_WAIT
    } state_t;
    
    //=========================================================================
    // CDC - Synchronize IIgs signals into FPGA domain
    //=========================================================================
    
    logic [2:0] phi2_sync;
    logic [1:0] rdy_sync, irq_sync, nmi_sync, res_sync, abort_sync;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phi2_sync  <= '0;
            rdy_sync   <= 2'b11;
            irq_sync   <= 2'b11;
            nmi_sync   <= 2'b11;
            res_sync   <= 2'b00;
            abort_sync <= 2'b11;
        end else begin
            phi2_sync  <= {phi2_sync[1:0], phi2_in};
            rdy_sync   <= {rdy_sync[0], rdy_in};
            irq_sync   <= {irq_sync[0], irq_n_in};
            nmi_sync   <= {nmi_sync[0], nmi_n_in};
            res_sync   <= {res_sync[0], res_n_in};
            abort_sync <= {abort_sync[0], abort_n_in};
        end
    end
    
    logic phi2, phi2_d, phi2_rise, phi2_fall;
    logic rdy, irq_n, nmi_n, res_n, abort_n;
    
    always_comb begin
        phi2      = phi2_sync[2];
        phi2_d    = phi2_sync[1];
        phi2_rise = phi2 && !phi2_d;
        phi2_fall = !phi2 && phi2_d;
        
        rdy     = rdy_sync[1];
        irq_n   = irq_sync[1];
        nmi_n   = nmi_sync[1];
        res_n   = res_sync[1];
        abort_n = abort_sync[1];
    end

    //=========================================================================
    // State Machine
    //=========================================================================
    
    state_t state, next_state;
    
    // CPU core interface
    logic        cpu_ce;
    logic [23:0] cpu_addr;
    logic [7:0]  cpu_dout;
    logic [7:0]  cpu_din;
    logic        cpu_we;
    logic        cpu_vp;
    
    // Latched values for bus cycle
    logic [7:0]  bank_addr;
    logic [7:0]  write_data;
    logic        is_write;
    
    // Next state logic
    always_comb begin
        next_state = state;
        
        unique case (state)
            ST_RESET: begin
                if (res_n)
                    next_state = ST_PHI1_SETUP;
            end
            
            ST_PHI1_SETUP: begin
                next_state = ST_PHI1_HOLD;
            end
            
            ST_PHI1_HOLD: begin
                if (phi2_rise)
                    next_state = ST_PHI2_SETUP;
            end
            
            ST_PHI2_SETUP: begin
                next_state = ST_PHI2_DATA;
            end
            
            ST_PHI2_DATA: begin
                if (phi2_fall)
                    next_state = rdy ? ST_PHI2_SAMPLE : ST_WAIT;
            end
            
            ST_PHI2_SAMPLE: begin
                next_state = ST_PHI1_SETUP;
            end
            
            ST_WAIT: begin
                if (rdy && phi2_fall)
                    next_state = ST_PHI2_SAMPLE;
            end
            
            default: next_state = ST_RESET;
        endcase
        
        // Reset override
        if (!res_n)
            next_state = ST_RESET;
    end
    
    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_RESET;
        else
            state <= next_state;
    end
    
    //=========================================================================
    // Output Logic
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_ce     <= 1'b0;
            cpu_din    <= '0;
            bank_addr  <= '0;
            write_data <= '0;
            is_write   <= 1'b0;
            addr_out   <= '0;
            rwb        <= 1'b1;
            vp_n       <= 1'b1;
            data_oe    <= 1'b0;
            data_out   <= '0;
        end else begin
            // Default
            cpu_ce <= 1'b0;
            
            unique case (state)
                ST_RESET: begin
                    data_oe <= 1'b0;
                    rwb     <= 1'b1;
                    vp_n    <= 1'b1;
                end
                
                ST_PHI1_SETUP: begin
                    // Latch CPU outputs at start of φ1
                    bank_addr  <= cpu_addr[23:16];
                    addr_out   <= cpu_addr[15:0];
                    write_data <= cpu_dout;
                    is_write   <= cpu_we;
                    rwb        <= ~cpu_we;
                    vp_n       <= ~cpu_vp;
                    
                    // Drive bank address during φ1
                    data_oe  <= 1'b1;
                    data_out <= cpu_addr[23:16];
                end
                
                ST_PHI1_HOLD: begin
                    data_oe  <= 1'b1;
                    data_out <= bank_addr;
                end
                
                ST_PHI2_SETUP: begin
                    data_oe  <= is_write;
                    data_out <= write_data;
                end
                
                ST_PHI2_DATA: begin
                    data_oe  <= is_write;
                    data_out <= write_data;
                end
                
                ST_PHI2_SAMPLE: begin
                    cpu_din <= is_write ? write_data : data_in;
                    cpu_ce  <= 1'b1;
                    data_oe <= 1'b0;
                end
                
                ST_WAIT: begin
                    data_oe  <= is_write;
                    data_out <= write_data;
                end
                
                default: begin
                    data_oe <= 1'b0;
                end
            endcase
        end
    end

    //=========================================================================
    // P65C816 Core Instance
    // TODO: Verify port names against actual srg320 VHDL entity
    //=========================================================================
    
    P65C816 cpu_core (
        .CLK     (clk),
        .RST_N   (res_n),
        .CE      (cpu_ce),
        
        .RDY_IN  (1'b1),
        .NMI_N   (nmi_n),
        .IRQ_N   (irq_n),
        .ABORT_N (abort_n),
        
        .D_IN    (cpu_din),
        .D_OUT   (cpu_dout),
        .A_OUT   (cpu_addr),
        .WE      (cpu_we),
        
        .VPA     (),
        .VDA     (),
        .VP      (cpu_vp),
        .MLB     ()
    );
    
    //=========================================================================
    // Debug
    //=========================================================================
    
    assign dbg_addr  = cpu_addr;
    assign dbg_state = state;

endmodule