use std::process;

fn main() {
    let count = rtlsdr::get_device_count();
    if count == 0 {
        eprintln!("No RTL-SDR devices found!");
        process::exit(1);
    }

    for i in 0..count {
        let name = rtlsdr::get_device_name(i);
        println!("Device {}: {}", i, name);
        if let Ok(usb) = rtlsdr::get_device_usb_strings(i) {
            println!("  Manufacturer: {}", usb.manufacturer);
            println!("  Product: {}", usb.product);
            println!("  Serial: {}", usb.serial);
        }
    }

    let mut dev = rtlsdr::open(0).expect("Failed to open RTL-SDR device");

    let center_freq: u32 = 100_000_000;
    let sample_rate: u32 = 2_048_000;

    dev.set_center_freq(center_freq).expect("Failed to set frequency");
    dev.set_sample_rate(sample_rate).expect("Failed to set sample rate");
    dev.set_tuner_gain_mode(false).expect("Failed to set auto gain");
    dev.set_agc_mode(true).expect("Failed to enable AGC");

    println!("\nTuned to {} Hz, sample rate {} S/s", center_freq, sample_rate);

    let (tuner_id, tuner_name) = dev.get_tuner_type();
    println!("Tuner: {} (id={})", tuner_name, tuner_id);
    println!("Reading IQ samples...\n");

    dev.reset_buffer().expect("Failed to reset buffer");

    let num_reads = 10;
    let buf_len = 512;

    for i in 0..num_reads {
        match dev.read_sync(buf_len) {
            Ok(buf) => {
                println!("--- Frame {} ({} bytes) ---", i, buf.len());

                for pair in buf.chunks(2).take(16) {
                    if pair.len() == 2 {
                        let i_val = pair[0] as i16 - 127;
                        let q_val = pair[1] as i16 - 127;
                        print!("({:+4},{:+4}) ", i_val, q_val);
                    }
                }
                println!("\n");
            }
            Err(e) => {
                eprintln!("Error reading samples: {:?}", e);
            }
        }
    }

    dev.close().expect("Failed to close device");
    println!("Done.");
}
