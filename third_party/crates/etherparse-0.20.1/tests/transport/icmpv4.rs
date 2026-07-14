use super::super::*;

mod icmpv4_regression {
    use super::*;

    #[test]
    fn icmp4_echo_marshall_unmarshall() {
        let icmp4 = Icmpv4Header {
            icmp_type: Icmpv4Type::EchoRequest(IcmpEchoHeader { seq: 1, id: 2 }),
            checksum: 0,
        };
        // serialize
        let mut buffer: Vec<u8> = Vec::with_capacity(256);
        icmp4.write(&mut buffer).unwrap();
        let (new_icmp4, rest) = Icmpv4Header::from_slice(&buffer).unwrap();
        assert_eq!(icmp4, new_icmp4);
        assert_eq!(rest.len(), 0);
    }

    #[test]
    fn ip4_echo_marshall_unmarshall() {
        let builder = PacketBuilder::ipv4(
            [192, 168, 1, 1], //source ip
            [192, 168, 1, 2], //destination ip
            20,
        ) //time to life
        .icmpv4_echo_request(1, 2);
        let payload = [0xde, 0xad, 0xbe, 0xef];
        //get some memory to store the result
        let mut result = Vec::<u8>::with_capacity(builder.size(payload.len()));

        //serialize
        builder.write(&mut result, &payload).unwrap();

        let new_ip = PacketHeaders::from_ip_slice(&result).unwrap();
        if let Some(TransportHeader::Icmpv4(hdr)) = new_ip.transport {
            if let Icmpv4Type::EchoRequest(echo) = hdr.icmp_type {
                assert_eq!(echo.id, 1);
                assert_eq!(echo.seq, 2);
            } else {
                panic!("Not an EchoRequest!?");
            }
        } else {
            panic!("No transport header found!?")
        }
    }
    const ICMP4_ECHO_REQUEST_BYTES: [u8; 98] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x45,
        0x00, 0x00, 0x54, 0x13, 0x6f, 0x40, 0x00, 0x40, 0x01, 0x29, 0x38, 0x7f, 0x00, 0x00, 0x01,
        0x7f, 0x00, 0x00, 0x01, 0x08, 0x00, 0xc9, 0x99, 0x00, 0x03, 0x00, 0x01, 0x79, 0xc5, 0xd9,
        0x61, 0x00, 0x00, 0x00, 0x00, 0x18, 0x68, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    ];

    const ICMP4_ECHO_REPLY_BYTES: [u8; 98] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x45,
        0x00, 0x00, 0x54, 0x13, 0x70, 0x00, 0x00, 0x40, 0x01, 0x69, 0x37, 0x7f, 0x00, 0x00, 0x01,
        0x7f, 0x00, 0x00, 0x01, 0x00, 0x00, 0xd1, 0x99, 0x00, 0x03, 0x00, 0x01, 0x79, 0xc5, 0xd9,
        0x61, 0x00, 0x00, 0x00, 0x00, 0x18, 0x68, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    ];

    // real echo request/reply captured from tcpdump
    // ping 127.0.0.1 to 127.0.0.1
    #[test]
    fn pcap_echo_session() {
        let request = PacketHeaders::from_ethernet_slice(&ICMP4_ECHO_REQUEST_BYTES).unwrap();
        let request_icmp4 = request.transport.unwrap().icmpv4().unwrap();
        match request_icmp4.icmp_type {
            Icmpv4Type::EchoRequest(echo) => {
                assert_eq!(echo.seq, 1);
                assert_eq!(echo.id, 3); // arbitrarily assigned by OS
            }
            _ => panic!(r#"Request didn't parse as ICMP4!?"#),
        }

        let reply = PacketHeaders::from_ethernet_slice(&ICMP4_ECHO_REPLY_BYTES).unwrap();
        let reply_icmp4 = reply.transport.unwrap().icmpv4().unwrap();
        match reply_icmp4.icmp_type {
            Icmpv4Type::EchoReply(echo) => {
                assert_eq!(echo.seq, 1);
                assert_eq!(echo.id, 3); // arbitrarily assigned by OS
            }
            _ => panic!(r#"Request didn't parse as ICMP4!?"#),
        }
        let request_iph = request.net.unwrap();
        let reply_iph = reply.net.unwrap();
        if let NetHeaders::Ipv4(request_ip, _) = request_iph {
            if let NetHeaders::Ipv4(reply_ip, _) = reply_iph {
                assert_eq!(reply_ip.source, request_ip.destination);
                assert_eq!(reply_ip.destination, request_ip.source);
            } else {
                panic!("reply ip not v4!?");
            }
        } else {
            panic!("request ip not v4!?");
        }
    }

    #[test]
    fn echo_request_slice() {
        let echo = SlicedPacket::from_ethernet(&ICMP4_ECHO_REQUEST_BYTES).unwrap();
        use TransportSlice::*;
        let icmp4 = match echo.transport.unwrap() {
            Icmpv4(icmp4) => icmp4,
            Icmpv6(_) | Udp(_) | Tcp(_) => panic!("Misparsed header!"),
        };
        assert!(matches!(icmp4.icmp_type(), Icmpv4Type::EchoRequest(_)));
    }

    #[test]
    fn verify_icmp4_checksum() {
        for (pkt, checksum) in [
            (ICMP4_ECHO_REQUEST_BYTES, 0xc999),
            (ICMP4_ECHO_REPLY_BYTES, 0xd199),
        ] {
            // make sure we can unmarshall the correct checksum
            let request = PacketHeaders::from_ethernet_slice(&pkt).unwrap();
            let mut icmp4 = request.transport.unwrap().icmpv4().unwrap();
            let valid_checksum = icmp4.checksum;
            assert_ne!(valid_checksum, 0);
            assert_eq!(valid_checksum, checksum);
            // reset it and recalculate
            icmp4.checksum = 0;
            assert_eq!(
                icmp4.icmp_type.calc_checksum(request.payload.slice()),
                valid_checksum
            );
        }
    }

    // TTL unreachable from 'traceroute google.com'
    const ICMP4_TTL_EXCEEDED_BYTES: [u8; 94] = [
        0x98, 0x8d, 0x46, 0xc5, 0x03, 0x82, 0x60, 0xa4, 0xb7, 0x25, 0x4b, 0x84, 0x08, 0x00, 0x45,
        0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x01, 0x5c, 0x87, 0xd4, 0x9c, 0xc9, 0x72,
        0xc0, 0xa8, 0x01, 0x6e, 0x0b, 0x00, 0x24, 0x29, 0x00, 0x00, 0x00, 0x00, 0x45, 0x00, 0x00,
        0x3c, 0xe3, 0xaf, 0x00, 0x00, 0x01, 0x11, 0x14, 0x84, 0xc0, 0xa8, 0x01, 0x6e, 0xd8, 0xef,
        0x26, 0x78, 0xc2, 0x8e, 0x82, 0x9f, 0x00, 0x28, 0x03, 0xed, 0x40, 0x41, 0x42, 0x43, 0x44,
        0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53,
        0x54, 0x55, 0x56, 0x57,
    ];
    #[test]
    fn parse_icmp4_ttl_exceeded() {
        let ttl_exceeded = PacketHeaders::from_ethernet_slice(&ICMP4_TTL_EXCEEDED_BYTES).unwrap();
        let ip_header = match ttl_exceeded.net.unwrap() {
            NetHeaders::Ipv4(ip4, _) => ip4,
            _ => panic!("Didn't parse inner v4 IP header!?"),
        };
        assert_eq!(ip_header.source, [212, 156, 201, 114]);
        let icmp4 = ttl_exceeded.transport.unwrap().icmpv4().unwrap();
        let icmp_bytes = icmp4.to_bytes();
        assert_eq!(8, icmp_bytes.len());
        assert_eq!(icmp_bytes[0], icmpv4::TYPE_TIME_EXCEEDED);
        assert_eq!(icmp_bytes[1], 0); // code
        assert_eq!(&icmp_bytes[4..], &[0; 4]); // TTL exceeded doesn't use this field
                                               // now unpack the bounced packet in the payload

        let embedded_pkt = LaxPacketHeaders::from_ip(ttl_exceeded.payload.slice()).unwrap();
        let ip_header = match embedded_pkt.net.unwrap() {
            NetHeaders::Ipv4(ip4, _) => ip4,
            _ => panic!("Didn't parse inner v4 IP header!?"),
        };
        use std::net::Ipv4Addr;
        assert_eq!(
            Ipv4Addr::from(ip_header.source),
            "192.168.1.110".parse::<Ipv4Addr>().unwrap()
        );
        assert_eq!(
            Ipv4Addr::from(ip_header.destination),
            "216.239.38.120".parse::<Ipv4Addr>().unwrap()
        );
        let udp_header = embedded_pkt.transport.unwrap().udp().unwrap();
        assert_eq!(udp_header.source_port, 49806); // numbers read from wireshark
        assert_eq!(udp_header.destination_port, 33439);
    }

    const ICMP4_PORT_UNREACHABLE_BYTES: [u8; 70] = [
        0x98, 0x8d, 0x46, 0xc5, 0x03, 0x82, 0x60, 0xa4, 0xb7, 0x25, 0x4b, 0x84, 0x08, 0x00, 0x45,
        0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x39, 0x01, 0xc0, 0x47, 0xd8, 0xef, 0x26, 0x78,
        0xc0, 0xa8, 0x01, 0x6e, 0x03, 0x03, 0xb3, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x45, 0x80, 0x00,
        0x3c, 0xe3, 0xd2, 0x00, 0x00, 0x01, 0x11, 0x13, 0xe1, 0xc0, 0xa8, 0x01, 0x6e, 0xd8, 0xef,
        0x26, 0x78, 0xb3, 0x4e, 0x82, 0xb2, 0x00, 0x28, 0x13, 0x1a,
    ];
    #[test]
    fn icmp4_dst_unreachable() {
        let offset = 14 + 20 + 1; // ethernet + iphdr + icmp_type
                                  // test all of the unreachable codes to make sure the maps are right
        for code_u8 in 0..icmpv4::CODE_DST_UNREACH_PRECEDENCE_CUTOFF {
            let mut pkt = ICMP4_PORT_UNREACHABLE_BYTES;
            pkt[offset] = code_u8; // over write the code
            let parsed = PacketHeaders::from_ethernet_slice(&pkt).unwrap();
            let icmp4 = parsed.transport.unwrap().icmpv4().unwrap();
            if let Icmpv4Type::DestinationUnreachable(icmp_code) = icmp4.icmp_type {
                assert_eq!(code_u8, icmp_code.code_u8());
            } else {
                panic!("Not destination unreachable!?");
            }
        }
    }
}
