#ifndef _SOC_H_
#define _SOC_H_

/* 
 * Dummy soc.h to satisfy Zephyr's SiFive I2C driver.
 * The driver needs this macro to calculate the I2C prescaler.
 * We set it to 50 MHz to match your FPGA's system clock.
 */
#define SIFIVE_PERIPHERAL_CLOCK_FREQUENCY 50000000

#endif /* _SOC_H_ */