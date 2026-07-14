use pcap::Capture;

fn main() {
    // get the default Device
    let device = pcap::Device::lookup().unwrap().unwrap();

    // Setup Capture
    let mut cap = pcap::Capture::from_device(device)
        .unwrap()
        .immediate_mode(true)
        .open()
        .unwrap();

    // remember linktype to create PCAP files later
    let linktype = cap.get_datalink();

    // For example purposes we will only save 5 files...
    for counter in 0..5 {
        let mut save_file = Capture::dead(linktype)
            .unwrap()
            .savefile(format!("dump_{counter}.pcap"))
            .unwrap();

        // ...30 packets each
        for _ in 0..30 {
            let packet = cap.next_packet().unwrap();
            save_file.write(&packet);
        }
        save_file.flush().unwrap();
    }
}
