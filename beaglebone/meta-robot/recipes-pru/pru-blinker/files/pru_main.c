#include <stdint.h>
#include <pru_cfg.h>

// Register R30 Bit 2 maps to P9_30 in Mode 5
#define P9_30_BIT (1 << 2)

volatile register uint32_t __R30;

void main(void) {
    // Enable OCP Master Port (allows PRU to access the rest of the chip)
    CT_CFG.SYSCFG_bit.STANDBY_INIT = 0;

    while (1) {
        __R30 |= P9_30_BIT;      // HIGH     // HIGH
        __delay_cycles(1000000); // Fast toggle for PWM-like behavior
        __R30 &= ~P9_30_BIT;     // LOW
        __delay_cycles(1000000);
    }
}