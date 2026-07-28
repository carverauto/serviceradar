use etherparse::*;

fn main() {
    // setup some network data to parse
    let builder = PacketBuilder::ethernet2(
        // source mac
        [1, 2, 3, 4, 5, 6],
        // destination mac
        [7, 8, 9, 10, 11, 12],
    )
    .ip(IpHeaders::Ipv4(
        Ipv4Header {
            total_len: 0, // will be overwritten by builder
            identification: 1234,
            dont_fragment: false,
            more_fragments: true,
            fragment_offset: IpFragOffset::try_new(1024 / 8).unwrap(),
            time_to_live: 20,
            protocol: IpNumber::UDP,
            header_checksum: 0, // will be overwritten by builder
            source: [1, 2, 3, 4],
            destination: [2, 3, 4, 5],
            ..Default::default()
        },
        Default::default(),
    ))
    .udp(
        21,   // source port
        1234, // desitnation port
    );

    // payload of the udp packet
    let payload = [1, 2, 3, 4, 5, 6, 7, 8];

    // get some memory to store the serialized data
    let mut serialized = Vec::<u8>::with_capacity(builder.size(payload.len()));
    builder.write(&mut serialized, &payload).unwrap();

    // pool that manages the different fragmented packets & the different memory buffers for re-assembly
    let mut ip_defrag_pool = defrag::IpDefragPool::<(), ()>::new();

    // slice the packet into the different header components
    let sliced_packet = match SlicedPacket::from_ethernet(&serialized) {
        Err(err) => {
            println!("Err {:?}", err);
            return;
        }
        Ok(v) => v,
    };

    // constructed
    if sliced_packet.is_ip_payload_fragmented() {
        let defrag_result = ip_defrag_pool.process_sliced_packet(&sliced_packet, (), ());
        match defrag_result {
            Ok(Some(finished)) => {
                println!(
                    "Successfully reconstructed fragmented IP packet ({} bytes, protocol {:?})",
                    finished.payload.len(),
                    finished.ip_number,
                );

                // continue parsing the payload
                // ... fill in your code here

                // IMPORTANT: After done return the finished packet buffer to avoid unneeded allocations
                ip_defrag_pool.return_buf(finished);
            }
            Ok(None) => {
                println!(
                    "Received a fragmented packet, but the reconstruction was not yet finished"
                );
            }
            Err(err) => {
                println!("Error reconstructing fragmented IPv4 packet: {err}");
            }
        }
    }
}
