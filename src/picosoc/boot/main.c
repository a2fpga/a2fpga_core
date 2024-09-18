#include <stdint.h>
#include <stdbool.h>
#include <soc/soc.h>
#include <a2fpga/a2fpga.h>
#include <uart/uart.h>
#include <xprintf/xprintf.h>
#include <a2mem/a2mem.h>
#include <a2disk/a2disk.h>
#include <ff/ff.h>

//
// A2FPGA Kernel
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
// This is the kernel for the A2FPGA. It is responsible for presenting
// a simple OSD UX for selecting and mounting Apple II disk images as
// well as other system configuration options.
//

#define reg_uart_clkdiv (*(volatile uint32_t*)0x02000004)
#define reg_uart_data (*(volatile uint32_t*)0x02000008)
#define gpio (*(volatile uint32_t*)0x03000000)

static void put_rc (FRESULT rc)
{
	reg_a2fpga_video_enable = 1;
	const char *str =
		"OK\0" "DISK_ERR\0" "INT_ERR\0" "NOT_READY\0" "NO_FILE\0" "NO_PATH\0"
		"INVALID_NAME\0" "DENIED\0" "EXIST\0" "INVALID_OBJECT\0" "WRITE_PROTECTED\0"
		"INVALID_DRIVE\0" "NOT_ENABLED\0" "NO_FILE_SYSTEM\0" "MKFS_ABORTED\0" "TIMEOUT\0"
		"LOCKED\0" "NOT_ENOUGH_CORE\0" "TOO_MANY_OPEN_FILES\0" "INVALID_PARAMETER\0";
	FRESULT i;

	for (i = 0; i != rc && *str; i++) {
		while (*str++) ;
	}
	xprintf("rc=%u FR_%s\n", (UINT)rc, str);
}

FATFS FatFs;				/* File system object for each logical drive */
FILINFO Finfo;
DIR Dir;					/* Directory object */

void main(soc_firmware_jump_table_t* firmware_jump_table) {
	soc_irq(0);

    reg_uart_clkdiv = 468; // 54000000 / 115200

	xdev_out(screen_putchar);
	reg_a2fpga_video_enable = 1;

    screen_clear();
    xputs("A2FPGA OS Loaded\n\n");

	FRESULT res;
	UINT acc_files, acc_dirs;
 	QWORD acc_size;

    res = f_mount(&FatFs, "", 0);
    if (res) { put_rc(res); return; }
   
    res = f_opendir(&Dir, "");
    if (res) { put_rc(res); return; }

    acc_size = acc_dirs = acc_files = 0;
    for(;;) {
        res = f_readdir(&Dir, &Finfo);
        if ((res != FR_OK) || !Finfo.fname[0]) break;
        if (Finfo.fattrib & AM_DIR) {
            acc_dirs++;
        } else {
            acc_files++; 
            acc_size += Finfo.fsize;
        }
        xprintf("%c %7lu  %s\n",
                (Finfo.fattrib & AM_DIR) ? 'D' : '-',
                Finfo.fsize, Finfo.fname);
    }
    xprintf("\n%4u File(s)\n", acc_files);
    xprintf("%9llu bytes total\n", acc_size);
    xprintf("%4u Dir(s)\n", acc_dirs);

	uint32_t *buff=(uint32_t *)0x04080000;
	UINT br;

    FIL fil;
	xputs("\nOpening DOS 3.3...\n");
	res = f_open(&fil, "dos33.nib", FA_READ);
    if (res) { put_rc(res); return; }

    xputs("\nLoading DOS 3.3...\n");
	res = f_read(&fil, buff, 0x40000, &br);
    //if (res) { put_rc(res); return; }

    f_close(&fil);

    xprintf("\n%4u bytes read\n", br);

    xputs("\nDOS 3.3 loaded!\n");

    reg_a2fpga_volume_0_ready = 1;
    reg_a2fpga_volume_0_mounted = 1;
    reg_a2fpga_volume_0_readonly = 1;
    reg_a2fpga_volume_0_size = 0x40000;
    reg_a2fpga_volume_0_blk_cnt = 0x80;
    reg_a2fpga_volume_0_ack = 1;

    soc_wait(5000);

	reg_a2fpga_video_enable = 0;

    while (1) {

        firmware_jump_table->wait_for_cmd();
        reg_a2fpga_a2_cmd = 0;

        reg_a2fpga_video_enable = 1;
	    xputs("\nEntering co-processor...\n");

        uint8_t c;
        //while (c = firmware_jump_table->wait_for_char() != 'Q') {
        while ((c = wait_for_char()) != 'Q') {
            screen_putchar(c);
        }
	    xputs("\nExiting co-processor...\n");

        reg_a2fpga_video_enable = 0;
    }

    //printf("\nDone!\n");
}
