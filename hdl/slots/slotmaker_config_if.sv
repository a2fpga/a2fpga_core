interface slotmaker_config_if();
    logic [2:0] slot;
    logic wr;
    logic [7:0] card_i;
    logic [7:0] card_o;

    modport slotmaker (
        input slot,
        input wr,
        input card_i,
        output card_o
    );

    modport controller (
        output slot,
        output wr,
        output card_i,
        input card_o
    );

endinterface