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

    let mut count = 0;
    cap.for_each(None, |packet| {
        println!("Got {:?}", packet.header);
        count += 1;
        if count > 100 {
            panic!("ow");
        }
    })
    .unwrap();
}
