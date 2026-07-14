fn main() {
    // get the default Device
    let device = pcap::Device::lookup()
        .expect("device lookup failed")
        .expect("no device available");
    println!("Using device {}", device.name);

    // Setup Capture
    let mut cap = pcap::Capture::from_device(device)
        .unwrap()
        .immediate_mode(true)
        .open()
        .unwrap();

    // get 10 packets
    for _ in 0..10 {
        cap.next_packet().ok();
    }
    let stats = cap.stats().unwrap();
    println!(
        "Received: {}, dropped: {}, if_dropped: {}",
        stats.received, stats.dropped, stats.if_dropped
    );
}
