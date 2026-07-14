use super::*;

use crate::test_gens::*;
use alloc::vec::Vec;
use arrayvec::ArrayVec;
use proptest::prelude::*;

#[derive(Clone, Debug, Eq, PartialEq)]
struct ComponentTest<'a> {
    link: Option<LinkHeader>,
    link_exts: ArrayVec<LinkExtHeader, 3>,
    net: Option<NetHeaders>,
    transport: Option<TransportHeader>,
    payload: &'a [u8],
}

impl<'a> ComponentTest<'a> {
    fn serialize(&self) -> Vec<u8> {
        let mut buffer = Vec::<u8>::with_capacity(
            match &self.link {
                Some(header) => header.header_len(),
                None => 0,
            } + self
                .link_exts
                .as_ref()
                .iter()
                .map(|v| v.header_len())
                .sum::<usize>()
                + match &self.net {
                    Some(headers) => headers.header_len(),
                    None => 0,
                }
                + match &self.transport {
                    Some(header) => header.header_len(),
                    None => 0,
                }
                + self.payload.len(),
        );

        //fill all the elements
        match &self.link {
            Some(header) => header.write(&mut buffer).unwrap(),
            None => {}
        }
        for e in &self.link_exts {
            match e {
                LinkExtHeader::Vlan(s) => s.write(&mut buffer).unwrap(),
                LinkExtHeader::Macsec(m) => m.write(&mut buffer).unwrap(),
            }
        }
        match &self.net {
            Some(NetHeaders::Ipv4(header, exts)) => {
                header.write_raw(&mut buffer).unwrap();
                exts.write(&mut buffer, header.protocol).unwrap();
            }
            Some(NetHeaders::Ipv6(header, exts)) => {
                header.write(&mut buffer).unwrap();
                exts.write(&mut buffer, header.next_header).unwrap();
            }
            Some(NetHeaders::Arp(arp)) => {
                arp.write(&mut buffer).unwrap();
            }
            None => {}
        }
        match &self.transport {
            Some(TransportHeader::Icmpv6(header)) => header.write(&mut buffer).unwrap(),
            Some(TransportHeader::Icmpv4(header)) => header.write(&mut buffer).unwrap(),
            Some(TransportHeader::Udp(header)) => header.write(&mut buffer).unwrap(),
            Some(TransportHeader::Tcp(header)) => header.write(&mut buffer).unwrap(),
            None => {}
        }
        use std::io::Write;
        buffer.write_all(self.payload).unwrap();
        buffer
    }

    /// Serialize the headers & payload specified in the headers and check that
    /// the different decoding & slicing methods for entire packets work correctly.
    ///
    /// The following functions will be checked if they work correctly:
    /// * `SlicedPacket::from_ethernet`
    /// * `SlicedPacket::from_ip`
    /// * `PacketHeaders::from_ethernet_slice`
    /// * `PacketHeaders::from_ip_slice`
    fn run(&self) {
        // clone the test so the length fields can be adapted
        let mut test = self.clone();

        // set ether types & macsec length
        {
            let mut next_ether_type = test.net.as_ref().map(|net| match net {
                NetHeaders::Ipv4(_, _) => EtherType::IPV4,
                NetHeaders::Ipv6(_, _) => EtherType::IPV6,
                NetHeaders::Arp(_) => EtherType::ARP,
            });
            let mut next_payload_len = test.net.as_ref().map(|net| net.header_len()).unwrap_or(0)
                + test.transport.as_ref().map(|t| t.header_len()).unwrap_or(0)
                + test.payload.len();

            for ext in test.link_exts.iter_mut().rev() {
                if let Some(e) = next_ether_type {
                    match ext {
                        LinkExtHeader::Vlan(vlan) => {
                            vlan.ether_type = e;
                        }
                        LinkExtHeader::Macsec(macsec) => {
                            macsec.ptype = MacsecPType::Unmodified(e);
                            macsec.set_payload_len(next_payload_len);
                        }
                    }
                } else {
                    match ext {
                        LinkExtHeader::Vlan(_) => {}
                        LinkExtHeader::Macsec(macsec) => {
                            macsec.set_payload_len(next_payload_len);
                        }
                    }
                }
                next_ether_type = match ext {
                    LinkExtHeader::Vlan(_) => Some(EtherType::VLAN_TAGGED_FRAME),
                    LinkExtHeader::Macsec(_) => Some(EtherType::MACSEC),
                };
                next_payload_len += ext.header_len();
            }
            if let Some(link) = test.link.as_mut() {
                if let Some(e) = next_ether_type {
                    match link {
                        LinkHeader::LinuxSll(sll) => {
                            sll.protocol_type = LinuxSllProtocolType::EtherType(e);
                        }
                        LinkHeader::Ethernet2(eth) => {
                            eth.ether_type = e;
                        }
                    }
                }
            }
        }

        // set IP & ARP the payload length & last ether type
        if let Some(net) = test.net.as_mut() {
            match net {
                NetHeaders::Ipv4(ipv4, exts) => {
                    ipv4.set_payload_len(
                        exts.header_len()
                            + self.transport.as_ref().map_or(0, |t| t.header_len())
                            + self.payload.len(),
                    )
                    .unwrap();
                }
                NetHeaders::Ipv6(ipv6, exts) => {
                    ipv6.set_payload_length(
                        exts.header_len()
                            + self.transport.as_ref().map_or(0, |t| t.header_len())
                            + self.payload.len(),
                    )
                    .unwrap();
                }
                NetHeaders::Arp(_) => {}
            }
        }

        // set transport length
        if let Some(TransportHeader::Udp(udp)) = test.transport.as_mut() {
            udp.length = udp.header_len_u16() + self.payload.len() as u16;
        }

        //packet with ethernet2 & vlan headers
        {
            //serialize to buffer
            let buffer = test.serialize();

            // PacketHeaders::from_ethernet_slice
            test.assert_headers(PacketHeaders::from_ethernet_slice(&buffer).unwrap());

            // SlicedPacket::from_ethernet
            test.assert_sliced_packet(SlicedPacket::from_ethernet(&buffer).unwrap());

            // create unexpected end of slice errors for the different headers
            for len in test.invalid_ser_lengths() {
                if let Some(len) = len {
                    assert!(PacketHeaders::from_ethernet_slice(&buffer[..len]).is_err());
                    assert!(SlicedPacket::from_ethernet(&buffer[..len]).is_err());
                }
            }
        }

        // packet data starting right after the link layer (tests from_ether_type functions)
        {
            // remove the link layer
            let ether_down = {
                let mut ether_down = test.clone();
                ether_down.link = None;
                ether_down
            };

            // serialize to buffer
            let buffer = ether_down.serialize();

            // PacketHeaders::from_ether_type
            ether_down.assert_headers(
                PacketHeaders::from_ether_type(
                    test.link.clone().unwrap().ethernet2().unwrap().ether_type,
                    &buffer[..],
                )
                .unwrap(),
            );

            // SlicedPacket::from_ether_type
            ether_down.assert_sliced_packet(
                SlicedPacket::from_ether_type(
                    test.link.clone().unwrap().ethernet2().unwrap().ether_type,
                    &buffer[..],
                )
                .unwrap(),
            );

            // create unexpected end of slice errors for the different headers
            for len in ether_down.invalid_ser_lengths() {
                if let Some(len) = len {
                    assert!(PacketHeaders::from_ether_type(
                        test.link.clone().unwrap().ethernet2().unwrap().ether_type,
                        &buffer[..len]
                    )
                    .is_err());
                    assert!(SlicedPacket::from_ether_type(
                        test.link.clone().unwrap().ethernet2().unwrap().ether_type,
                        &buffer[..len]
                    )
                    .is_err());
                }
            }
        }

        // packet from the internet layer down (without ethernet2 & vlan headers)
        if test.net.as_ref().map(|v| v.is_ip()).unwrap_or(false) {
            // serialize from the ip layer downwards
            let ip_down = {
                let mut ip_down = test.clone();
                ip_down.link = None;
                ip_down.link_exts.clear();
                ip_down
            };

            // serialize to buffer
            let buffer = ip_down.serialize();

            // PacketHeaders::from_ip_slice
            ip_down.assert_headers(PacketHeaders::from_ip_slice(&buffer).unwrap());

            // SlicedPacket::from_ip
            ip_down.assert_sliced_packet(SlicedPacket::from_ip(&buffer).unwrap());

            // create unexpected end of slice errors for the different headers
            for len in ip_down.invalid_ser_lengths() {
                if let Some(len) = len {
                    assert!(PacketHeaders::from_ip_slice(&buffer[..len]).is_err());
                    assert!(SlicedPacket::from_ip(&buffer[..len]).is_err());
                }
            }
        }
    }

    /// Creates slice lengths at which an too short slice error
    /// should be triggered.
    fn invalid_ser_lengths(&self) -> [Option<usize>; 12] {
        struct Builder {
            result: [Option<usize>; 12],
            next_index: usize,
            offset: usize,
        }

        impl Builder {
            fn add(&mut self, header_len: usize) {
                self.offset += header_len;
                self.result[self.next_index] = Some(self.offset - 1);
                self.next_index += 1;
            }
        }

        let mut builder = Builder {
            result: [None; 12],
            next_index: 0,
            offset: 0,
        };

        if let Some(link) = self.link.as_ref() {
            builder.add(link.header_len());
        }
        for e in &self.link_exts {
            match e {
                LinkExtHeader::Vlan(s) => {
                    builder.add(s.header_len());
                }
                LinkExtHeader::Macsec(m) => {
                    builder.add(m.header_len());
                }
            }
        }
        if let Some(net) = self.net.as_ref() {
            use NetHeaders::*;
            match net {
                Ipv4(header, exts) => {
                    builder.add(header.header_len());
                    if let Some(auth) = exts.auth.as_ref() {
                        builder.add(auth.header_len());
                    }
                }
                Ipv6(header, exts) => {
                    builder.add(header.header_len());
                    if let Some(e) = exts.hop_by_hop_options.as_ref() {
                        builder.add(e.header_len());
                    }
                    if let Some(e) = exts.destination_options.as_ref() {
                        builder.add(e.header_len());
                    }
                    if let Some(routing) = exts.routing.as_ref() {
                        builder.add(routing.routing.header_len());
                        if let Some(e) = routing.final_destination_options.as_ref() {
                            builder.add(e.header_len());
                        }
                    }
                    if let Some(e) = exts.fragment.as_ref() {
                        builder.add(e.header_len());
                    }
                    if let Some(e) = exts.auth.as_ref() {
                        builder.add(e.header_len());
                    }
                }
                Arp(arp) => {
                    builder.add(arp.packet_len());
                }
            }
        }
        if let Some(transport) = self.transport.as_ref() {
            builder.add(transport.header_len());
        }

        builder.result
    }

    fn assert_headers(&self, actual: PacketHeaders) {
        assert_eq!(self.link, actual.link);
        assert_eq!(self.link_exts, actual.link_exts);
        assert_eq!(self.net, actual.net);
        assert_eq!(self.transport, actual.transport);
        assert_eq!(self.payload[..], actual.payload.slice()[..]);
    }

    fn assert_sliced_packet(&self, result: SlicedPacket) {
        //assert identity to touch the derives (code coverage hack)
        assert_eq!(result.clone(), result);

        //ethernet & link extensions
        assert_eq!(
            self.link,
            match result.link.as_ref() {
                Some(l) => match l {
                    LinkSlice::Ethernet2(e) => Some(LinkHeader::Ethernet2(e.to_header())),
                    LinkSlice::LinuxSll(e) => Some(LinkHeader::LinuxSll(e.to_header())),
                    LinkSlice::EtherPayload(_) => None,
                    LinkSlice::LinuxSllPayload(_) => None,
                },
                None => None,
            }
        );
        assert_eq!(
            self.link_exts,
            result
                .link_exts
                .as_ref()
                .iter()
                .map(|x| x.to_header())
                .collect::<ArrayVec<LinkExtHeader, 3>>()
        );

        //ip
        assert_eq!(self.net, {
            use crate::NetSlice::*;
            match result.net.as_ref() {
                Some(Ipv4(actual)) => Some(NetHeaders::Ipv4(
                    actual.header().to_header(),
                    Ipv4Extensions {
                        auth: actual.extensions().auth.map(|ref x| x.to_header()),
                    },
                )),
                Some(Ipv6(actual)) => Some(NetHeaders::Ipv6(
                    actual.header().to_header(),
                    Ipv6Extensions::from_slice(
                        actual.header().next_header(),
                        actual.extensions().slice(),
                    )
                    .unwrap()
                    .0,
                )),
                Some(Arp(arp)) => Some(NetHeaders::Arp(arp.to_packet())),
                None => None,
            }
        });

        // transport header
        assert_eq!(
            self.transport,
            match result.transport.as_ref() {
                Some(TransportSlice::Icmpv4(actual)) =>
                    Some(TransportHeader::Icmpv4(actual.header())),
                Some(TransportSlice::Icmpv6(actual)) =>
                    Some(TransportHeader::Icmpv6(actual.header())),
                Some(TransportSlice::Udp(actual)) => Some(TransportHeader::Udp(actual.to_header())),
                Some(TransportSlice::Tcp(actual)) => Some(TransportHeader::Tcp(actual.to_header())),
                None => None,
            }
        );
        // additional check for the contents of Unknown
        if self.transport.is_none() {
            match result.transport.as_ref() {
                None => assert!(result.transport.is_none()),
                _ => unreachable!(),
            }
        }

        //payload
        match result.transport.as_ref() {
            Some(TransportSlice::Icmpv4(icmpv4)) => {
                assert_eq!(&self.payload[..], icmpv4.payload());
            }
            Some(TransportSlice::Icmpv6(icmpv6)) => {
                assert_eq!(&self.payload[..], icmpv6.payload());
            }
            Some(TransportSlice::Udp(udp)) => {
                assert_eq!(&self.payload[..], udp.payload());
            }
            Some(TransportSlice::Tcp(tcp)) => {
                assert_eq!(&self.payload[..], tcp.payload());
            }
            // check ip next
            None => {
                if let Some(ip) = result.net.as_ref() {
                    assert_eq!(
                        &self.payload[..],
                        match ip {
                            NetSlice::Ipv4(s) => s.payload.payload,
                            NetSlice::Ipv6(s) => s.payload.payload,
                            NetSlice::Arp(_) => &[],
                        }
                    );
                } else {
                    if let Some(ext) = result.link_exts.last() {
                        if let Some(p) = ext.ether_payload() {
                            assert_eq!(&self.payload[..], p.payload);
                        }
                    } else {
                        if let Some(LinkSlice::Ethernet2(eth)) = result.link.as_ref() {
                            assert_eq!(&self.payload[..], eth.payload().payload);
                        }
                    }
                }
            }
        }
    }

    fn run_link_exts(
        &self,
        vlans: &[SingleVlanHeader],
        macsecs: &[MacsecHeader],
        arp: &ArpPacket,
        ipv4: &Ipv4Header,
        ipv4_ext: &Ipv4Extensions,
        ipv6: &Ipv6Header,
        ipv6_ext: &Ipv6Extensions,
        udp: &UdpHeader,
        tcp: &TcpHeader,
        icmpv4: &Icmpv4Header,
        icmpv6: &Icmpv6Header,
    ) {
        // add vlan
        {
            // build test
            let test = {
                let mut test = self.clone();
                test.link_exts
                    .try_push(LinkExtHeader::Vlan(vlans[0].clone()))
                    .unwrap();
                test
            };
            let vlans = &vlans[1..];

            // run next steps
            test.run();
            if !test.link_exts.is_full() {
                test.run_link_exts(
                    vlans, macsecs, arp, ipv4, ipv4_ext, ipv6, ipv6_ext, udp, tcp, icmpv4, icmpv6,
                );
            }
            test.run_arp(arp);
            test.run_ipv4(ipv4, ipv4_ext, udp, tcp, icmpv4, icmpv6);
            test.run_ipv6(ipv6, ipv6_ext, udp, tcp, icmpv4, icmpv6);
        }

        // add macsec
        {
            // build test
            let test = {
                let mut test = self.clone();
                test.link_exts
                    .try_push(LinkExtHeader::Macsec(macsecs[0].clone()))
                    .unwrap();
                test
            };
            let macsecs = &macsecs[1..];

            // run next steps
            test.run();
            if !test.link_exts.is_full() {
                test.run_link_exts(
                    vlans, macsecs, arp, ipv4, ipv4_ext, ipv6, ipv6_ext, udp, tcp, icmpv4, icmpv6,
                );
            }
            test.run_arp(arp);
            test.run_ipv4(ipv4, ipv4_ext, udp, tcp, icmpv4, icmpv6);
            test.run_ipv6(ipv6, ipv6_ext, udp, tcp, icmpv4, icmpv6);
        }
    }

    fn run_arp(&self, arp: &ArpPacket) {
        let mut test = self.clone();
        test.net = Some(NetHeaders::Arp(arp.clone()));
        test.payload = &[];
        test.run();
    }

    fn run_ipv4(
        &self,
        ip: &Ipv4Header,
        ip_exts: &Ipv4Extensions,
        udp: &UdpHeader,
        tcp: &TcpHeader,
        icmpv4: &Icmpv4Header,
        icmpv6: &Icmpv6Header,
    ) {
        // fragmenting
        {
            let mut test = self.clone();
            test.net = Some({
                let mut frag = ip.clone();
                if false == frag.is_fragmenting_payload() {
                    frag.more_fragments = true;
                }
                let mut ip_exts = ip_exts.clone();
                frag.protocol = ip_exts.set_next_headers(ip.protocol);
                NetHeaders::Ipv4(frag, ip_exts.clone())
            });

            // run without transport header
            test.run();
        }

        // non fragmenting
        {
            let mut test = self.clone();
            test.net = Some({
                let mut non_frag = ip.clone();
                non_frag.more_fragments = false;
                non_frag.fragment_offset = 0.try_into().unwrap();
                let mut ip_exts = ip_exts.clone();
                non_frag.protocol = ip_exts.set_next_headers(ip.protocol);
                NetHeaders::Ipv4(non_frag, ip_exts)
            });
            test.run_transport(udp, tcp, icmpv4, icmpv6);
        }
    }

    fn run_ipv6(
        &self,
        ip: &Ipv6Header,
        ip_exts: &Ipv6Extensions,
        udp: &UdpHeader,
        tcp: &TcpHeader,
        icmpv4: &Icmpv4Header,
        icmpv6: &Icmpv6Header,
    ) {
        // fragmenting
        {
            let mut test = self.clone();
            test.net = Some({
                let mut frag = ip_exts.clone();
                if let Some(frag) = frag.fragment.as_mut() {
                    if false == frag.is_fragmenting_payload() {
                        frag.more_fragments = true;
                    }
                } else {
                    frag.fragment = Some(Ipv6FragmentHeader::new(
                        ip_number::UDP,
                        IpFragOffset::ZERO,
                        true,
                        0,
                    ));
                }
                let mut ip = ip.clone();
                ip.next_header = frag.set_next_headers(ip.next_header);
                NetHeaders::Ipv6(ip, frag)
            });
            test.run();
        }

        // non fragmenting
        {
            let mut test = self.clone();
            test.net = Some({
                let mut non_frag = ip_exts.clone();
                non_frag.fragment = None;
                let mut ip = ip.clone();
                ip.next_header = non_frag.set_next_headers(ip.next_header);
                NetHeaders::Ipv6(ip, non_frag)
            });
            test.run_transport(udp, tcp, icmpv4, icmpv6);
        }
    }

    fn run_transport(
        &self,
        udp: &UdpHeader,
        tcp: &TcpHeader,
        icmpv4: &Icmpv4Header,
        icmpv6: &Icmpv6Header,
    ) {
        // unknown transport layer
        self.run();

        // udp
        {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::UDP)
                .unwrap();
            test.transport = Some(TransportHeader::Udp(udp.clone()));
            test.run()
        }

        // tcp
        {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::TCP)
                .unwrap();
            test.transport = Some(TransportHeader::Tcp(tcp.clone()));
            test.run()
        }

        // icmpv4
        if let Some(payload_size) = icmpv4.fixed_payload_size() {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::ICMP)
                .unwrap();
            test.transport = Some(TransportHeader::Icmpv4(icmpv4.clone()));
            // resize the payload in case it does not have to be as big
            let mut v = Vec::new();
            if payload_size <= test.payload.len() {
                test.payload = &test.payload[..payload_size];
            } else {
                v.resize(payload_size, 0);
                test.payload = &v;
            }
            test.run()
        } else {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::ICMP)
                .unwrap();
            test.transport = Some(TransportHeader::Icmpv4(icmpv4.clone()));
            test.run()
        }

        // icmpv6
        if let Some(payload_size) = icmpv6.fixed_payload_size() {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::IPV6_ICMP)
                .unwrap();
            test.transport = Some(TransportHeader::Icmpv6(icmpv6.clone()));
            // resize the payload in case it does not have to be as big
            let mut v = Vec::new();
            if payload_size <= test.payload.len() {
                test.payload = &test.payload[..payload_size];
            } else {
                v.resize(payload_size, 0);
                test.payload = &v;
            }
            test.run()
        } else {
            let mut test = self.clone();
            test.net
                .as_mut()
                .unwrap()
                .try_set_next_headers(ip_number::IPV6_ICMP)
                .unwrap();
            test.transport = Some(TransportHeader::Icmpv6(icmpv6.clone()));
            test.run()
        }
    }
}

proptest! {
    ///Test that all known packet compositions are parsed correctly.
    #[test]
    // #[cfg_attr(miri, ignore)] // vec allocation reduces miri run-speed too much
    fn test_compositions(ref eth in ethernet_2_unknown(),
                         ref vlan0 in vlan_single_unknown(),
                         ref vlan1 in vlan_single_unknown(),
                         ref vlan2 in vlan_single_unknown(),
                         ref macsec0 in macsec_unknown(),
                         ref macsec1 in macsec_unknown(),
                         ref macsec2 in macsec_unknown(),
                         ref ipv4 in ipv4_unknown(),
                         ref ipv4_exts in ipv4_extensions_unknown(),
                         ref ipv6 in ipv6_unknown(),
                         ref ipv6_exts in ipv6_extensions_unknown(),
                         ref arp in arp_packet_any(),
                         ref udp in udp_any(),
                         ref tcp in tcp_any(),
                         ref icmpv4 in icmpv4_header_any(),
                         ref icmpv6 in icmpv6_header_any(),
                         ref payload in proptest::collection::vec(any::<u8>(), 0..1024))
    {
        let setup_eth = || -> ComponentTest {
            ComponentTest {
                payload: &payload,
                link: Some(LinkHeader::Ethernet2(eth.clone())),
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None
            }
        };

        // ethernet 2: standalone, ipv4, ipv6
        setup_eth().run();
        setup_eth().run_arp(arp);
        setup_eth().run_ipv4(ipv4, ipv4_exts, udp, tcp, icmpv4, icmpv6);
        setup_eth().run_ipv6(ipv6, ipv6_exts, udp, tcp, icmpv4, icmpv6);

        // link exts
        {
            let vlans = [vlan0.clone(), vlan1.clone(), vlan2.clone()];
            let macsecs = [macsec0.clone(), macsec1.clone(), macsec2.clone()];
            setup_eth().run_link_exts(&vlans[..], &macsecs[..], arp, ipv4, ipv4_exts, ipv6, ipv6_exts, udp, tcp, icmpv4, icmpv6);
        }
    }
}

///Test that assert_sliced_packet is panicking when the ethernet header is missing
#[test]
#[should_panic]
fn test_packet_slicing_panics() {
    let s = SlicedPacket {
        link: None,
        link_exts: ArrayVec::new_const(),
        net: None,
        transport: None,
    };
    ComponentTest {
        link: Some(LinkHeader::Ethernet2(Ethernet2Header {
            source: [0; 6],
            destination: [0; 6],
            ether_type: 0.into(),
        })),
        link_exts: ArrayVec::new_const(),
        net: None,
        transport: None,
        payload: &[],
    }
    .assert_sliced_packet(s);
}
