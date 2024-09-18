#include <stdint.h>

#ifndef __GPIO_H__
#define __GPIO_H__

#define reg_led (*(volatile uint8_t*)0x03000000)
#define reg_ws2812 (*(volatile uint32_t*)0x03000004)
#define reg_button (*(volatile uint8_t*)0x03000008)

#endif

