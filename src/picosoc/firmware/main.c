#include <stdint.h>
#include <stdbool.h>
#include <a2fpga/a2fpga.h>
#include <soc/soc.h>
#include <uart/uart.h>
#include <xprintf/xprintf.h>
#include <a2mem/a2mem.h>
#include <pff/pff.h>		/* Declarations of FatFs API */

//
// A2FPGA Firmware
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
// This is the main firmware for the A2FPGA. It is responsible for loading the
// kernel from the SD card and starting it. It also provides a simple UART
// interface for debugging and a simple timer interrupt for blinking the LEDs.
//

#define gpio (*(volatile uint32_t*)0x03000000)

void die (		/* Stop with dying message */
	FRESULT rc	/* FatFs return value */
)
{
	reg_a2fpga_a2bus_ready = 1;
	reg_a2fpga_video_enable = 1;

	xprintf("\nDisk error: %u", rc);

	soc_wait(10000);
	reg_a2fpga_video_enable = 0;

	// idle forever on error
	for (;;) ;
}

void update_leds()
{
	static uint32_t status = 1;
	gpio = (status++) & 1;
}

void irq_handler(uint32_t irq_mask, uint32_t *regs)
{
	// IRQ 0: timer interrupt
	if (irq_mask & 1)
	{
		// run IRQ payload
		update_leds();

		// restart timer
		soc_timer(10000000);
	}

	// IRQ 1, IRQ 2: SBREAK, ILLINS, or BUSERROR
	if (irq_mask & 6)
	{
		reg_a2fpga_video_enable = 1;
		xputs("System error!\n");

		// regs[0] is the return address of the IRQ handler, i.e. it points to the instruction _after_
		// the one that caused the IRQ. This is a heuristic that tries to detect if the instruction
		// before that is a 16 bit opcode or a 32 bit opcode. It is not perfect.. (This is only a
		// problem when compressed ISA is enabled. This will always do the right thing when the IRQ
		// is triggered from uncompressed code.)

		uint16_t *pc = (void*)(regs[0] - 4);
		unsigned int instr = (pc[1] << 16) | pc[0];

		if ((instr & 3) != 3) {
			pc = (void*)(regs[0] - 2);
			instr = pc[0];
		}

		xputs("\n--\n");

		if ((irq_mask & 4) != 0)
			xputs("Bus error in ");

		if ((irq_mask & 2) != 0) {
			if (instr == 0x00100073 || instr == 0x9002)
				xputs("SBREAK ");
			else
				xputs("Illegal ");
		}

		xprintf("instruction at %p: 0x%0*x\n", pc, ((instr & 3) == 3) ? 8 : 4, instr);

		for (int i = 0; i < 8; i++)
		for (int k = 0; k < 4; k++)
		{
			int r = i + k*8;

			if (r == 0)
				xputs("pc  ");
			else
				xprintf("x%-2d ", r);

			xprintf("0x%08x%s", (unsigned int)regs[r], k == 3 ? "\n" : "    ");
		}

		// calling sbreak within the IRQ handler will halt the system
		xputs("STOP.\n");
		
		soc_wait(10000);
		reg_a2fpga_video_enable = 0;
		reg_a2fpga_a2bus_ready = 1;
		
		soc_sbreak();
	}

}

void debug_putchar(uint8_t c)
{
	uart_putchar(c);
	screen_putchar(c);
}

soc_firmware_jump_table_t jump_table = {
	.wait_for_cmd = wait_for_cmd,
	.wait_for_char = wait_for_char,
};

void main() {
	// set UART clock divider for 115200 baud
    reg_uart_clkdiv = 468; // 54000000 / 115200

	//xdev_out(uart_putchar);
	//for (int i = 0; i < 10; i++) xputs("Testing Serial Port\n");

	// set character output function to screen output
	//xdev_out(debug_putchar);
	xdev_out(screen_putchar);

	// register IRQ handler
	soc_irq(irq_handler);

	// enable IRQs
	soc_maskirq(0);

	// start timer (IRQ 0)
	soc_timer(10000000);

    screen_clear();
    xputs("        A2fpga Firmware v1.0b1\n\n");

	reg_a2fpga_a2bus_ready = 1;

	FATFS fatfs;			/* File system object */
	UINT bw, br, i;
	uint32_t *buff=(uint32_t *)0x04400000;

	xputs("\nMounting SDCard\n");

	FRESULT rc = pf_mount(&fatfs);
	if (rc) die(rc);

	xputs("\nOpening boot.bin\n");
	rc = pf_open("BOOT.BIN");
	if (rc) die(rc);

	xputs("\nLoading kernel...\n");
	rc = pf_read(buff, UINT32_MAX, &br);
	if (rc) die(rc);
	
    xputs("\nKernel loaded!\n");
    gpio = 0x00000000;

	// disable IRQs
	soc_maskirq(0xffffffff);

	// unregister IRQ handler
	soc_irq(0);

	void (*kernel_ptr)(soc_firmware_jump_table_t*) = (void *)0x04400000;

	(*kernel_ptr)(&jump_table); 

}
