//
// SystemVerilog interface for the F18A GPU
//
// Description:
//
// This SystemVerilog interface is used to connect the F18A GPU to the
// alternate co-processors that can be used with the F18A VDP.
//
// The F18A provides a GPU based on the TMS9900 CPU.  The GPU is used to
// run graphics operations on the VDP.  For the A2FPGA, we don't use the
// TMS9900 GPU, but instead use a SystemVerilog interface to the F18A
// GPU signals that can be used to connect the F18A to the PicoRV32 CPU
// or other co-processors.
//

interface f18a_gpu_if;

        // GPU Status Interface
        logic trigger;        // trigger the GPU
        logic running;         // '1' if the GPU is running; '0' when idle
        logic pause;          // pause the GPU; active high
        logic pause_ack;       // acknowledge pause
        logic [15:0] load_pc;
        // GPU VRAM Interface
        logic [7:0] vdin;
        logic vwe;
        logic [13:0] vaddr;
        logic [7:0] vdout;
        // GPU Palette Interface
        logic [11:0] pdin;
        logic pwe;
        logic [5:0] paddr;
        logic [11:0] pdout;
        // GPU Register Interface
        logic [7:0] rdin;
        logic [13:0] raddr;
        logic rwe;             // write enable for VDP registers
        // GPU Data inputs
        logic [7:0] scanline;
        logic blank;          // '1' when blanking (horz and vert)
        logic [7:0] bmlba;    // bitmap layer base address
        logic [7:0] bml_w;    // bitmap layer width
        logic pgba;           // pattern generator base address
        // GPU Data output; 7-bits of user defined status
        logic [6:0] gstatus;

    modport master (
        output trigger,        
        input running,         
        output pause,          
        input pause_ack,       
        output load_pc,
        
        output vdin,
        input vwe,
        input vaddr,
        input vdout,
        
        output pdin,
        input pwe,
        input paddr,
        input pdout,
        
        output rdin,
        input raddr,
        input rwe,             
        
        output scanline,
        output blank,          
        output bmlba,    
        output bml_w,    
        output pgba,           
        
        input gstatus
    );

    modport slave (
        input trigger,        
        output running,         
        input pause,          
        output pause_ack,       
        input load_pc,
        
        input vdin,
        output vwe,
        output vaddr,
        output vdout,
        
        input pdin,
        output pwe,
        output paddr,
        output pdout,
        
        input rdin,
        output raddr,
        output rwe,             
        
        input scanline,
        input blank,          
        input bmlba,    
        input bml_w,    
        input pgba,           
        
        output gstatus
    );


endinterface: f18a_gpu_if
