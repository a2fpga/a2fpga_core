// The accelerator-only build's alternative sequencer clocks (see gowin_acc_pll_mod.v):
// gowin_gs_pll's wrapper (hdl/dp_test_138b/gowin_plls_138b.sv) with MDIV 21 (105 MHz)
// or 20 (100 MHz).
module gowin_acc_pll #(parameter int MDIV = 21) (output lock, output clkout, input clkin);

    wire [5:0] icpsel;
    wire [2:0] lpfres;
    wire       pll_lock;
    wire       pll_rst;

    gowin_acc_pll_MOD #(.MDIV(MDIV)) u_pll (
        .clkout0 (clkout),
        .lock    (pll_lock),
        .clkin   (clkin),
        .reset   (pll_rst),
        .icpsel  (icpsel),
        .lpfres  (lpfres),
        .lpfcap  (2'b00)
    );

    PLL_INIT u_pll_init (
        .CLKIN   (clkin),         // 50 MHz crystal - always running
        .I_RST   (1'b0),
        .O_RST   (pll_rst),
        .PLLLOCK (pll_lock),
        .O_LOCK  (lock),
        .ICPSEL  (icpsel),
        .LPFRES  (lpfres)
    );
    defparam u_pll_init.CLK_PERIOD = 20;   // ns, 50 MHz
    defparam u_pll_init.MULTI_FAC  = MDIV; // MDIV_SEL

endmodule
