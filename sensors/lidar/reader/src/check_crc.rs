use std::io::Read;
use std::time::Duration;

const HEADER:     u8    = 0x54;
const VER_LEN:    u8    = 0x2C;
const BAUD:       u32   = 230_400;
const PACKET_LEN: usize = 47;

fn main() {
    let port_name = "/dev/ttyUSB0";
    let mut port = serialport::new(port_name, BAUD)
        .timeout(Duration::from_millis(2000))
        .open()
        .unwrap_or_else(|e| {
            eprintln!("Cannot open port: {}", e);
            std::process::exit(1);
        });

    println!("Sniffing raw packets — will print first 5 valid-header packets\n");

    // sync
    let mut b = [0u8; 1];
    loop {
        if port.read_exact(&mut b).is_ok() && b[0] == HEADER {
            let mut v = [0u8; 1];
            if port.read_exact(&mut v).is_ok() && v[0] == VER_LEN {
                break;
            }
        }
    }

    let mut buf = [0u8; PACKET_LEN];
    let mut found = 0;

    while found < 5 {
        buf[0] = HEADER;
        buf[1] = VER_LEN;
        if port.read_exact(&mut buf[2..]).is_err() { continue; }

        // print raw bytes
        println!("── raw packet {} ──", found + 1);
        for (i, byte) in buf.iter().enumerate() {
            print!("{:02x} ", byte);
            if (i + 1) % 16 == 0 { println!(); }
        }
        println!();
        println!("  last byte (CRC sent by sensor): 0x{:02x}", buf[PACKET_LEN - 1]);

        // try all 256 possible starting CRC values and polynomial 0x31
        // to see what would produce the sensor's CRC
        let sensor_crc = buf[PACKET_LEN - 1];
        let data = &buf[..PACKET_LEN - 1];

        'outer: for poly in [0x07u8, 0x31, 0x39, 0x1d, 0x9b, 0xd5] {
            for init in [0x00u8, 0xff, 0x31] {
                let mut crc = init;
                for &byte in data {
                    crc ^= byte;
                    for _ in 0..8 {
                        if crc & 0x80 != 0 {
                            crc = (crc << 1) ^ poly;
                        } else {
                            crc <<= 1;
                        }
                    }
                }
                if crc == sensor_crc {
                    println!("  ✓ MATCH: poly=0x{:02x} init=0x{:02x}", poly, init);
                    break 'outer;
                }
            }
        }
        println!();
        found += 1;

        // re-sync for next packet
        loop {
            if port.read_exact(&mut b).is_ok() && b[0] == HEADER {
                let mut v = [0u8; 1];
                if port.read_exact(&mut v).is_ok() && v[0] == VER_LEN {
                    break;
                }
            }
        }
    }
}