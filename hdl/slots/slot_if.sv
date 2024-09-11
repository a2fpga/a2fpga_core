
interface slot_if ();

    logic [2:0] slot;
    logic [7:0] card_id;
    logic ioselect_n;
    logic devselect_n;
    logic iostrobe_n;

    modport slotmaker (
        output slot,
        output card_id,
        output ioselect_n,
        output devselect_n,
        output iostrobe_n
    );

    modport card (
        input slot,
        input card_id,
        input ioselect_n,
        input devselect_n,
        input iostrobe_n
    );

endinterface

