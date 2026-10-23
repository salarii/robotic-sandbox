#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/sys/printk.h>

/* Check if the device tree has the ADC */
#if !DT_HAS_COMPAT_STATUS_OKAY(ti_ads1115)
#error "Could not find ti,ads1115 in devicetree"
#endif

/* Fetch the ADC device pointer at boot */
static const struct device *adc_dev = DEVICE_DT_GET_ANY(ti_ads1115);

/* ADS1115 channel 0, single-ended (AIN0 vs GND) */
#define ADC_CHANNEL 0

/*
 * Change ONLY this line to change the input range. The conversion to volts
 * below follows it automatically.
 *
 * Gains accepted by the Zephyr ADS1x1x driver (full scale = 2.048 V / gain):
 *   ADC_GAIN_1_3 -> +/-6.144 V   (never put more than VDD + 0.3 V on a pin)
 *   ADC_GAIN_1_2 -> +/-4.096 V
 *   ADC_GAIN_1   -> +/-2.048 V
 *   ADC_GAIN_2   -> +/-1.024 V
 *   ADC_GAIN_4   -> +/-0.512 V
 *   ADC_GAIN_8   -> +/-0.256 V
 */
#define ADC_GAIN_SELECTED ADC_GAIN_1_2

/*
 * Single-ended readings use 15 bits (0..32767), as the driver requires
 * (16 bits only for differential channels).
 */
#define ADC_RESOLUTION_BITS 15
#define ADC_FULL_SCALE_CODE (1 << ADC_RESOLUTION_BITS) /* 32768 */

static const struct adc_channel_cfg channel_cfg = {
    .gain             = ADC_GAIN_SELECTED,
    .reference        = ADC_REF_INTERNAL,   /* ADS1115 uses internal reference */
    .acquisition_time = ADC_ACQ_TIME_DEFAULT,
    .channel_id       = ADC_CHANNEL,
    .differential     = 0,
};

/* Full-scale input range, in millivolts, for a given Zephyr gain macro.
 * Returns 0 for a gain the driver does not support. */
static int gain_full_scale_mv(enum adc_gain gain)
{
    switch (gain) {
    case ADC_GAIN_1_3: return 6144;
    case ADC_GAIN_1_2: return 4096;
    case ADC_GAIN_1:   return 2048;
    case ADC_GAIN_2:   return 1024;
    case ADC_GAIN_4:   return 512;
    case ADC_GAIN_8:   return 256;
    default:           return 0;
    }
}

/*
 * Software fallbacks for GCC atomic built-ins.
 * Required because the VexRiscv soft-core lacks the RISC-V 'A' extension,
 * and bare-metal Zephyr doesn't link libatomic by default.
 */
int __atomic_fetch_add_4(volatile void *ptr, int val, int memorder) {
    unsigned int key = irq_lock();
    int ret = *(volatile int *)ptr;
    *(volatile int *)ptr = ret + val;
    irq_unlock(key);
    return ret;
}

int __atomic_fetch_sub_4(volatile void *ptr, int val, int memorder) {
    unsigned int key = irq_lock();
    int ret = *(volatile int *)ptr;
    *(volatile int *)ptr = ret - val;
    irq_unlock(key);
    return ret;
}

int __atomic_exchange_4(volatile void *ptr, int val, int memorder) {
    unsigned int key = irq_lock();
    int ret = *(volatile int *)ptr;
    *(volatile int *)ptr = val;
    irq_unlock(key);
    return ret;
}

int main(void)
{
    int err;
    int16_t sample_buffer[1];
    const int fs_mv = gain_full_scale_mv(channel_cfg.gain);

    /* Define where the ADC should store the read data */
    struct adc_sequence sequence = {
        .channels    = BIT(ADC_CHANNEL),
        .buffer      = sample_buffer,
        .buffer_size = sizeof(sample_buffer),
        .resolution  = ADC_RESOLUTION_BITS,
    };

    printk("\n=========================================\n");
    printk(" Zephyr ADS1115 I2C ADC Reader           \n");
    printk("=========================================\n\n");

    if (fs_mv == 0) {
        printk("Error: unsupported gain selected\n");
        return -1;
    }

    /* Check if the C driver successfully bound to the I2C hardware */
    if (!device_is_ready(adc_dev)) {
        printk("Error: ADC device not ready. Check I2C bus and DTSI.\n");
        return -1;
    }

    /* Send the configuration to the chip over I2C */
    err = adc_channel_setup(adc_dev, &channel_cfg);
    if (err != 0) {
        printk("Error: Setting up the ADC channel failed (err %d)\n", err);
        return -1;
    }

    printk("ADC configured: full scale +/-%d.%03d V, %d bits, %d uV/LSB (approx)\n\n",
           fs_mv / 1000, fs_mv % 1000, ADC_RESOLUTION_BITS,
           (fs_mv * 1000) / ADC_FULL_SCALE_CODE);

    while (1) {
        err = adc_read(adc_dev, &sequence);
        if (err != 0) {
            printk("ADC read failed (err %d)\n", err);
        } else {
            int32_t raw = sample_buffer[0];
            int32_t sign = (raw < 0) ? -1 : 1;
            int32_t mag = (raw < 0) ? -raw : raw;

            /* raw * fs_mv max = 32768 * 6144 ~ 201e6, fits in int32.
             * volts = raw * fs_mv / 32768 (mV), done without floats or 64-bit math. */
            int32_t prod = mag * fs_mv;
            int32_t mv_int = prod / ADC_FULL_SCALE_CODE;
            int32_t mv_frac = ((prod % ADC_FULL_SCALE_CODE) * 1000) / ADC_FULL_SCALE_CODE;

            printk("Channel %d  raw=%6d  voltage=%s%d.%03d V\n",
                   ADC_CHANNEL, (int)raw,
                   (sign < 0) ? "-" : "",
                   (int)(mv_int / 1000), (int)(mv_int % 1000));
            /* mv_frac is the sub-millivolt part; shown below for fine resolution */
            printk("            (= %s%d.%03d mV)\n",
                   (sign < 0) ? "-" : "", (int)mv_int, (int)mv_frac);
        }

        k_msleep(1000);
    }

    return 0;
}