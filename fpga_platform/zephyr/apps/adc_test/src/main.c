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

/* Configure ADS1115 Channel 0 (Single-ended) */
#define ADC_CHANNEL 0

static const struct adc_channel_cfg channel_cfg = {
    .gain             = ADC_GAIN_1,             /* Range: +/- 4.096V */
    .reference        = ADC_REF_INTERNAL,       /* ADS1115 uses internal reference */
    .acquisition_time = ADC_ACQ_TIME_DEFAULT,
    .channel_id       = ADC_CHANNEL,
    .differential     = 0,
};

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

    /* Define where the ADC should store the read data */
    struct adc_sequence sequence = {
        .channels    = BIT(ADC_CHANNEL),
        .buffer      = sample_buffer,
        .buffer_size = sizeof(sample_buffer),
        .resolution  = 15, /* ADS1115 is 16-bit */
    };

    printk("\n=========================================\n");
    printk(" Zephyr ADS1115 I2C ADC Reader           \n");
    printk("=========================================\n\n");

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

    printk("ADC successfully configured! Starting sampling...\n\n");

    /* Infinite loop matching your original structure */
    while (1) {
        err = adc_read(adc_dev, &sequence);
        if (err != 0) {
            printk("ADC read failed (err %d)\n", err);
        } else {
            /* sample_buffer[0] now contains the 16-bit two's complement value */
            printk("Channel %d Raw Value: %d\n", ADC_CHANNEL, sample_buffer[0]);
        }
        
        k_msleep(1000);
    }

    return 0;
}