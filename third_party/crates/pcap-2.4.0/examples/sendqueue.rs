#[cfg(windows)]
fn main() {
    const NUM_PACKETS: usize = 32;

    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        println!("{} <device> <target MAC>\n", args[0]);

        println!("Devices:");
        let devs = pcap::Device::list().unwrap();
        for dev in devs {
            println!("{}", dev.name);
        }

        return;
    }

    let mut cap = pcap::Capture::from_device(&*args[1])
        .unwrap()
        .open()
        .unwrap();

    let src_addr = eui48::MacAddress::parse_str("01:02:03:04:05:06").unwrap();
    let dst_addr = eui48::MacAddress::parse_str(&args[2]).unwrap();

    // 1MB send queue.
    let mut sq = pcap::sendqueue::SendQueue::new(1024 * 1024).unwrap();

    let mut pktbuf = [0u8; 1514]; // typical L2 MTU

    // Prepare an L2 header for sending a raw ethernet packet from
    // 01:02:03:04:05 to the MAC address specified in argv[1].  The ethertype
    // will be set to 0x5555.
    pktbuf[0..6].copy_from_slice(dst_addr.as_bytes());
    pktbuf[6..12].copy_from_slice(src_addr.as_bytes());

    // big-endian encoding isn't important since we have a symmetrical value,
    // but we encode it for purpose of illustration.
    let ethertype: u16 = 0x5555;
    pktbuf[12..14].copy_from_slice(&ethertype.to_be_bytes());

    for idx in 0..NUM_PACKETS {
        let payload = &mut pktbuf[14..1514];

        // Make the payload contain the packet index, u32 big-endian encoded.
        payload[0..4].copy_from_slice(&(idx as u32).to_be_bytes());

        // Add 256 bytes of L2 payload
        sq.queue(None, &pktbuf[..14 + 256]).unwrap();
    }

    sq.transmit(&mut cap, pcap::sendqueue::SendSync::Off)
        .unwrap();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Windows-only program");
}
