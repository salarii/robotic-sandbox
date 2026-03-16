use std::collections::VecDeque;
use std::io::Read;
use std::time::Duration;

const HEADER:     u8    = 0x54;
const VER_LEN:    u8    = 0x2C;
const BAUD:       u32   = 230_400;
const PACKET_LEN: usize = 47;
const N_POINTS:   usize = 12;

fn make_crc_table() -> [u8; 256] {
    let mut table = [0u8; 256];
    for i in 0u8..=255 {
        let mut crc = i;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 { (crc << 1) ^ 0x4d } else { crc << 1 };
        }
        table[i as usize] = crc;
    }
    table
}

fn crc8(data: &[u8], table: &[u8; 256]) -> u8 {
    data.iter().fold(0u8, |crc, &b| table[(crc ^ b) as usize])
}

struct Point {
    angle_deg:   f32,
    distance_mm: u16,
    intensity:   u8,
}

struct Packet {
    speed_dps:    u16,
    timestamp_ms: u16,
    points:       Vec<Point>,
}

fn try_parse(buf: &[u8; PACKET_LEN], crc_table: &[u8; 256]) -> Option<Packet> {
    if buf[0] != HEADER || buf[1] != VER_LEN { return None; }
    if crc8(&buf[..PACKET_LEN - 1], crc_table) != buf[PACKET_LEN - 1] { return None; }

    let speed_dps    = u16::from_le_bytes([buf[2], buf[3]]);
    let start_angle  = u16::from_le_bytes([buf[4], buf[5]]) as f32 * 0.01;
    let end_angle    = u16::from_le_bytes([buf[42], buf[43]]) as f32 * 0.01;
    let timestamp_ms = u16::from_le_bytes([buf[44], buf[45]]);

    // sanity check — reject garbage that slipped through CRC
    if speed_dps > 6000 { return None; }

    let span = if end_angle >= start_angle {
        end_angle - start_angle
    } else {
        end_angle + 360.0 - start_angle
    };
    let step = span / (N_POINTS - 1) as f32;

    let points = (0..N_POINTS).map(|i| {
        let o = 6 + i * 3;
        let distance_mm = u16::from_le_bytes([buf[o], buf[o + 1]]);
        let intensity   = buf[o + 2];
        let angle_deg   = (start_angle + step * i as f32) % 360.0;
        Point { angle_deg, distance_mm, intensity }
    }).collect();

    Some(Packet { speed_dps, timestamp_ms, points })
}

fn main() {
    let crc_table = make_crc_table();

    let mut port = serialport::new("/dev/ttyUSB0", BAUD)
        .timeout(Duration::from_millis(2000))
        .open()
        .unwrap_or_else(|e| {
            eprintln!("Cannot open port: {}", e);
            eprintln!("Try: sudo chmod a+rw /dev/ttyUSB0");
            std::process::exit(1);
        });

    println!("Connected. Reading...\n");

    // ── sliding window buffer ──────────────────────────────────────────────
    // We NEVER assume alignment. We maintain a 47-byte window and slide it
    // one byte at a time. Only emit a packet when CRC passes.
    let mut window: VecDeque<u8> = VecDeque::with_capacity(PACKET_LEN * 2);
    let mut raw = [0u8; 64];
    let mut packet_count: u64 = 0;

    loop {
        // fill the deque
        match port.read(&mut raw) {
            Ok(n) => {
                for &b in &raw[..n] {
                    window.push_back(b);
                }
            }
            Err(e) => { eprintln!("read error: {}", e); continue; }
        }

        // try to extract packets from the window
        while window.len() >= PACKET_LEN {
            // fast check: first two bytes must be header
            if window[0] != HEADER || window[1] != VER_LEN {
                window.pop_front(); // slide one byte forward
                continue;
            }

            // copy window into fixed array for parsing
            let buf: [u8; PACKET_LEN] = {
                let mut arr = [0u8; PACKET_LEN];
                for (i, &b) in window.iter().take(PACKET_LEN).enumerate() {
                    arr[i] = b;
                }
                arr
            };

            match try_parse(&buf, &crc_table) {
                Some(pkt) => {
                    // valid packet — consume exactly 47 bytes
                    for _ in 0..PACKET_LEN { window.pop_front(); }
                    packet_count += 1;

                    println!("── packet #{} | speed={} °/s | t={}ms",
                             packet_count, pkt.speed_dps, pkt.timestamp_ms);
                    for (i, pt) in pkt.points.iter().enumerate() {
                        if pt.distance_mm > 0 {
                            println!("  [{:2}] {:7.2}°  {:5} mm  intensity={}",
                                     i, pt.angle_deg, pt.distance_mm, pt.intensity);
                        } else {
                            println!("  [{:2}] {:7.2}°  (no return)", i, pt.angle_deg);
                        }
                    }
                    println!();
                }
                None => {
                    // header bytes matched but CRC failed — slide one byte
                    window.pop_front();
                }
            }
        }
    }
}