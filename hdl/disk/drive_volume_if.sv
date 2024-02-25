//
// Apple II drive volume interface
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
// SystemVerilog interface for drive volumes to pass to the PicoSOC
//

interface drive_volume_if();

    logic ready;
    logic active;
    logic mounted; 
    logic readonly; 
    logic [31:0] size;

    // block level access
    logic [31:0] lba;
    logic [5:0] blk_cnt; // number of blocks-1; total size ((sd_blk_cnt+1)*(1<<(BLKSZ+7))) must be <= 16384!
    logic rd;
    logic wr;
    logic ack;

    modport drive (
        input ready,
        output active,
        input mounted, 
        input readonly, 
        input size,

        output lba,
        output blk_cnt,
        output rd,
        output wr,
        input ack

    );

    modport volume (
        output ready,
        input active,
        output mounted, 
        output readonly, 
        output size,

        input lba,
        input blk_cnt,
        input rd,
        input wr,
        output ack

    );

endinterface: drive_volume_if
