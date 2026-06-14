#ifndef A2FPGA_JTAG_H
#define A2FPGA_JTAG_H

#include <Arduino.h>

// External pin constants (defined in main .ino file)
extern const int PIN_TCK;
extern const int PIN_TMS;
extern const int PIN_TDI;
extern const int PIN_TDO;
extern const int PIN_SRST;

// Function declarations
void route_usb_jtag_to_gpio();
void unroute_usb_jtag_to_gpio();

#endif // A2FPGA_JTAG_H