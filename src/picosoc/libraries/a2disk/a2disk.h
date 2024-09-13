#include <stdint.h>


#ifndef __A2DISK_H__
#define __A2DISK_H__

#define reg_a2disk_volume_0_ready (*(volatile uint8_t*)0x07000000)
#define reg_a2disk_volume_0_active (*(volatile uint8_t*)0x07000004)
#define reg_a2disk_volume_0_mounted (*(volatile uint8_t*)0x07000008)
#define reg_a2disk_volume_0_readonly (*(volatile uint8_t*)0x0700000C)
#define reg_a2disk_volume_0_size (*(volatile uint32_t*)0x07000010)
#define reg_a2disk_volume_0_lba (*(volatile uint32_t*)0x07000014)
#define reg_a2disk_volume_0_blk_cnt (*(volatile uint8_t*)0x07000018)
#define reg_a2disk_volume_0_rd (*(volatile uint8_t*)0x0700001C)
#define reg_a2disk_volume_0_wr (*(volatile uint8_t*)0x07000020)
#define reg_a2disk_volume_0_ack (*(volatile uint32_t*)0x07000024)

#define reg_a2disk_volume_1_ready (*(volatile uint8_t*)0x07000080)
#define reg_a2disk_volume_1_active (*(volatile uint8_t*)0x07000084)
#define reg_a2disk_volume_1_mounted (*(volatile uint8_t*)0x07000088)
#define reg_a2disk_volume_1_readonly (*(volatile uint8_t*)0x0700008C)
#define reg_a2disk_volume_1_size (*(volatile uint32_t*)0x07000090)
#define reg_a2disk_volume_1_lba (*(volatile uint32_t*)0x07000094)
#define reg_a2disk_volume_1_blk_cnt (*(volatile uint8_t*)0x07000098)
#define reg_a2disk_volume_1_rd (*(volatile uint8_t*)0x0700009C)
#define reg_a2disk_volume_1_wr (*(volatile uint8_t*)0x070000A0)
#define reg_a2disk_volume_1_ack (*(volatile uint32_t*)0x070000A4)

#endif

