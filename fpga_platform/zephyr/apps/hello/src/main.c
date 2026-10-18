#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

int main(void)
{
    int count = 0;

    printk("\n=========================================\n");
    printk(" Zephyr RTOS running on VexRiscv RTL!     \n");
    printk("=========================================\n\n");

    while (1) {
        printk("Tick count: %d\n", count++);
        k_msleep(1000);
    }

    return 0;
}