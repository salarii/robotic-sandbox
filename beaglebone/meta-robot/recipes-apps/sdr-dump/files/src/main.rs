use rtl_sdr_rs::RtlSdr;
use std::process;

fn main() {
    // List connected devices
    let devices = RtlSdr::list_devices().unwrap_or_default();
    if devices.is_empty() {
        eprintln!("No RTL-SDR devices found!");
        process::exit(1);
    }

    for dev in &devices {
        println!("Found device {}: {} {}", dev.index, dev.vendor, dev.product);
    }

    // Open first device
    let mut sdr = RtlSdr::open_with_index(0).expect("Failed to open RTL-SDR device");

    // Configure
    let center_freq = 100_000_000; // 100 MHz (FM band)
    let sample_rate = 2_048_000;   // 2.048 MS/s

    sdr.set_center_freq(center_freq).expect("Failed to set frequency");
    sdr.set_sample_rate(sample_rate).expect("Failed to set sample rate");
    sdr.set_tuner_gain_mode(false).expect("Failed to set auto gain");

    println!("Tuned to {} Hz, sample rate {} S/s", center_freq, sample_rate);
    println!("Reading IQ samples...\n");

    // Reset the buffer before reading
    sdr.reset_buffer().expect("Failed to reset buffer");

    // Read and print frames
    let num_reads = 10;
    let buf_len = 512; // 256 I/Q sample pairs

    for i in 0..num_reads {
        let samples = sdr.read_sync(buf_len).expect("Failed to read samples");
        println!("--- Frame {} ({} bytes) ---", i, samples.len());

        // Print first 32 bytes as I/Q pairs (unsigned 8-bit)
        for pair in samples.chunks(2).take(16) {
            if pair.len() == 2 {
                let i_val = pair[0] as i16 - 127;
                let q_val = pair[1] as i16 - 127;
                print!("({:+4},{:+4}) ", i_val, q_val);
            }
        }
        println!("\n");
    }

    println!("Done.");
}
