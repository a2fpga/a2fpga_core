
interface slot_if ();

    logic [2:0] slot;
    logic [7:0] card_id;
    logic io_select_n;
    logic dev_select_n;
    logic io_strobe_n;

    logic config_select_n;
    logic [31:0] card_config;
    logic card_enable;

    modport slotmaker (
        output slot,
        output card_id,
        output io_select_n,
        output dev_select_n,
        output io_strobe_n,

        output config_select_n,
        output card_config,
        output card_enable
    );

    modport card (
        input slot,
        input card_id,
        input io_select_n,
        input dev_select_n,
        input io_strobe_n,

        input config_select_n,
        input card_config,
        input card_enable
    );

endinterface

