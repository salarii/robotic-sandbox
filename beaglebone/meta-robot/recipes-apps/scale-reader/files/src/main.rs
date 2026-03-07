use hx711::Hx711;
use linux_embedded_hal::gpio_cdev::{Chip, LineRequestFlags};
use linux_embedded_hal::{CdevPin, Delay};
use std::thread;
use std::time::Duration;

fn main() {
    // Open the GPIO chip (gpiochip0 on BeagleBone Black)
    let mut chip = Chip::new("/dev/gpiochip0").expect("Failed to open GPIO chip");

    // Request the data pin (GPIO 60 = P9_12) as input
    let data_line = chip
        .get_line(60)
        .expect("Failed to get data line")
        .request(LineRequestFlags::INPUT, 0, "hx711-data")
        .expect("Failed to request data line");

    // Request the clock pin (GPIO 48 = P9_15) as output
    let clock_line = chip
        .get_line(48)
        .expect("Failed to get clock line")
        .request(LineRequestFlags::OUTPUT, 0, "hx711-clock")
        .expect("Failed to request clock line");

    // Wrap them in CdevPin for embedded-hal compatibility
    let data_pin = CdevPin::new(data_line).expect("Failed to create data CdevPin");
    let clock_pin = CdevPin::new(clock_line).expect("Failed to create clock CdevPin");

    let delay = Delay;

    // Initialize the HX711
    let mut scale = Hx711::new(delay, data_pin, clock_pin).expect("Failed to init HX711");

    println!("Starting scale read loop...");

    loop {
        // Retrieve the raw 24-bit value
        match scale.retrieve() {
            Ok(value) => println!("Raw Weight Value: {}", value),
            Err(e) => eprintln!("Error reading scale: {:?}", e),
        }
        thread::sleep(Duration::from_millis(500));
    }
}