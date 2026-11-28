/* usb_urbfix.h -- see usb_urbfix.c (recovered EHCI XactErr/DBErr = success) */
#pragma once
#include <stdint.h>

uint32_t usb_urbfix_count(void);   /* completions corrected since boot */
