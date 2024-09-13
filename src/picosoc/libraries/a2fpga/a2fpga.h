#include <stdint.h>


#ifndef __A2FPGA_H__
#define __A2FPGA_H__

#define reg_a2fpga_system_time (*(volatile uint32_t*)0x05000000)
#define reg_a2fpga_keycode (*(volatile uint8_t*)0x05000004)
#define reg_a2fpga_video_enable (*(volatile uint8_t*)0x05000008)
#define reg_a2fpga_text_mode (*(volatile uint8_t*)0x0500000C)
#define reg_a2fpga_mixed_mode (*(volatile uint8_t*)0x05000010)
#define reg_a2fpga_page2 (*(volatile uint8_t*)0x05000014)
#define reg_a2fpga_hires_mode (*(volatile uint8_t*)0x05000018)
#define reg_a2fpga_an3 (*(volatile uint8_t*)0x0500001C)
#define reg_a2fpga_store80 (*(volatile uint8_t*)0x05000020)
#define reg_a2fpga_col80 (*(volatile uint8_t*)0x05000024)
#define reg_a2fpga_altchar (*(volatile uint8_t*)0x05000028)
#define reg_a2fpga_text_color (*(volatile uint8_t*)0x0500002C)
#define reg_a2fpga_background_color (*(volatile uint8_t*)0x05000030)
#define reg_a2fpga_border_color (*(volatile uint8_t*)0x05000034)
#define reg_a2fpga_monochrome_mode (*(volatile uint8_t*)0x05000038)
#define reg_a2fpga_monochrome_dhires_mode (*(volatile uint8_t*)0x0500003C)
#define reg_a2fpga_shrg_mode (*(volatile uint8_t*)0x05000040)
#define reg_a2fpga_a2_cmd (*(volatile uint8_t*)0x05000044)
#define reg_a2fpga_a2_data (*(volatile uint8_t*)0x05000048)
#define reg_a2fpga_countdown (*(volatile uint32_t*)0x0500004C)
#define reg_a2fpga_a2bus_ready (*(volatile uint8_t*)0x05000050) 

uint8_t wait_for_cmd();
uint8_t wait_for_char();
void wait_for_countdown(uint32_t us);

#endif

