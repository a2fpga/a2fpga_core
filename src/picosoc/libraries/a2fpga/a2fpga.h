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

#define reg_a2fpga_volume_0_ready (*(volatile uint8_t*)0x05000080)
#define reg_a2fpga_volume_0_active (*(volatile uint8_t*)0x05000084)
#define reg_a2fpga_volume_0_mounted (*(volatile uint8_t*)0x05000088)
#define reg_a2fpga_volume_0_readonly (*(volatile uint8_t*)0x0500008C)
#define reg_a2fpga_volume_0_size (*(volatile uint32_t*)0x05000090)
#define reg_a2fpga_volume_0_lba (*(volatile uint32_t*)0x05000094)
#define reg_a2fpga_volume_0_blk_cnt (*(volatile uint8_t*)0x05000098)
#define reg_a2fpga_volume_0_rd (*(volatile uint8_t*)0x0500009C)
#define reg_a2fpga_volume_0_wr (*(volatile uint8_t*)0x050000A0)
#define reg_a2fpga_volume_0_ack (*(volatile uint32_t*)0x050000A4)

#define reg_a2fpga_volume_1_ready (*(volatile uint8_t*)0x050000C0)
#define reg_a2fpga_volume_1_active (*(volatile uint8_t*)0x050000C4)
#define reg_a2fpga_volume_1_mounted (*(volatile uint8_t*)0x050000C8)
#define reg_a2fpga_volume_1_readonly (*(volatile uint8_t*)0x050000CC)
#define reg_a2fpga_volume_1_size (*(volatile uint32_t*)0x050000D0)
#define reg_a2fpga_volume_1_lba (*(volatile uint32_t*)0x050000D4)
#define reg_a2fpga_volume_1_blk_cnt (*(volatile uint8_t*)0x050000D8)
#define reg_a2fpga_volume_1_rd (*(volatile uint8_t*)0x050000DC)
#define reg_a2fpga_volume_1_wr (*(volatile uint8_t*)0x050000E0)
#define reg_a2fpga_volume_1_ack (*(volatile uint32_t*)0x050000E4)

uint8_t wait_for_cmd();
uint8_t wait_for_char();
void wait_for_countdown(uint32_t us);

#endif

