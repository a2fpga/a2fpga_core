#include "uart.h"

#define reg_uart_data (*(volatile uint32_t*)0x02000008)

void uart_putchar(char c)
{
	if (c == '\n')
		uart_putchar('\r');
	reg_uart_data = c;
}

