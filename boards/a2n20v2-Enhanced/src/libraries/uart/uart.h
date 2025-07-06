#include <stdint.h>


#ifndef __UART_H__
#define __UART_H__

#define reg_uart_clkdiv (*(volatile uint32_t*)0x02000004)
#define reg_uart_data (*(volatile uint32_t*)0x02000008)

void uart_putchar(char c);

#endif

