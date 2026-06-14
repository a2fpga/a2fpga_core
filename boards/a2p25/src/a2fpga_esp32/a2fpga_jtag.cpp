#include "a2fpga_jtag.h"
#include "esp_rom_gpio.h"
#include "soc/usb_serial_jtag_reg.h"

void route_usb_jtag_to_gpio()
{
  pinMode(PIN_TCK, OUTPUT);
  pinMode(PIN_TMS, OUTPUT);
  pinMode(PIN_TDI, OUTPUT);
  pinMode(PIN_TDO, INPUT);
  pinMode(PIN_SRST, OUTPUT);
  WRITE_PERI_REG(USB_SERIAL_JTAG_CONF0_REG,
    READ_PERI_REG(USB_SERIAL_JTAG_CONF0_REG)
  | USB_SERIAL_JTAG_USB_JTAG_BRIDGE_EN);
  // esp_rom_gpio_connect_out_signal(GPIO, IOMATRIX, false, false);
  esp_rom_gpio_connect_out_signal(PIN_TCK,   USB_JTAG_TCK_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_TMS,   USB_JTAG_TMS_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_TDI,   USB_JTAG_TDI_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_SRST,  USB_JTAG_TRST_IDX, false, false);
  esp_rom_gpio_connect_in_signal (PIN_TDO,   USB_JTAG_TDO_BRIDGE_IDX,  false);
}

void unroute_usb_jtag_to_gpio()
{
  WRITE_PERI_REG(USB_SERIAL_JTAG_CONF0_REG,
    READ_PERI_REG(USB_SERIAL_JTAG_CONF0_REG)
  & ~USB_SERIAL_JTAG_USB_JTAG_BRIDGE_EN);
  pinMode(PIN_TCK,  INPUT);
  pinMode(PIN_TMS,  INPUT);
  pinMode(PIN_TDI,  INPUT);
  pinMode(PIN_TDO,  INPUT);
  pinMode(PIN_SRST, INPUT);
}