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

    // get a packet and print its bytes
    println!("{:?}", cap.next_packet());
}
