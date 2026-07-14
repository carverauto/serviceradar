use crate::*;
use proptest::prelude::*;
use proptest::*;

pub fn vlan_ethertype_any() -> impl Strategy<Value = EtherType> {
    prop_oneof![
        Just(ether_type::VLAN_TAGGED_FRAME),
        Just(ether_type::PROVIDER_BRIDGING),
        Just(ether_type::VLAN_DOUBLE_TAGGED_FRAME),
    ]
}

prop_compose! {
    pub fn ether_type_any()
        (value in any::<u16>())
        -> EtherType
    {
        EtherType(value)
    }
}

prop_compose! {
    pub fn ether_type_unknown()
        (ether_type in ether_type_any().prop_filter("ether_type must be unknown",
        |v| !ETHERNET_KNOWN_ETHER_TYPES.iter().any(|&x| v == &x)))
        -> EtherType
    {
        ether_type
    }
}

prop_compose! {
    pub fn vlan_id_any()
        (value in 0..=0b0000_1111_1111_1111u16)
        -> VlanId
    {
        VlanId::try_new(value).unwrap()
    }
}

prop_compose! {
    pub fn vlan_pcp_any()
        (value in 0..=0b0000_0111u8)
        -> VlanPcp
    {
        VlanPcp::try_new(value).unwrap()
    }
}

prop_compose! {
    pub fn vlan_single_unknown()(
        pcp in vlan_pcp_any(),
        drop_eligible_indicator in any::<bool>(),
        vlan_id in vlan_id_any(),
        ether_type in ether_type_any().prop_filter("ether_type must be unknown",
            |v| !ETHERNET_KNOWN_ETHER_TYPES.iter().any(|&x| v == &x)))
        -> SingleVlanHeader
    {
        SingleVlanHeader {
            pcp,
            drop_eligible_indicator,
            vlan_id,
            ether_type,
        }
    }
}

prop_compose! {
    pub fn ip_ecn_any()
        (value in 0u8..=0b0000_0011)
        -> IpEcn
    {
        IpEcn::try_new(value).unwrap()
    }
}

prop_compose! {
    pub fn ip_dscp_any()
        (value in 0u8..=0b0011_1111)
        -> IpDscp
    {
        IpDscp::try_new(value).unwrap()
    }
}

prop_compose! {
    pub fn ipv6_flow_label_any()
        (value in 0u32..=0b1111_11111111_11111111u32)
        -> Ipv6FlowLabel
    {
        Ipv6FlowLabel::try_new(value).unwrap()
    }
}

prop_compose! {
    pub fn ip_number_any()
        (value in any::<u8>())
        -> IpNumber
    {
        IpNumber(value)
    }
}

prop_compose! {
    pub fn ethernet_2_with(ether_type: EtherType)(
        source in prop::array::uniform6(any::<u8>()),
        dest in prop::array::uniform6(any::<u8>()),
        ether_type in proptest::strategy::Just(ether_type))
        -> Ethernet2Header
    {
        Ethernet2Header {
            source: source,
            destination: dest,
            ether_type: ether_type
        }
    }
}

prop_compose! {
    pub fn ethernet_2_any()
        (ether_type in ether_type_any())
        (result in ethernet_2_with(ether_type))
        -> Ethernet2Header
    {
        result
    }
}

prop_compose! {
    pub fn linux_sll_packet_type_any()
        (value in 0..=LinuxSllPacketType::MAX_VAL)
        -> LinuxSllPacketType
    {
        LinuxSllPacketType::try_from(value).unwrap()
    }
}

prop_compose! {
    pub fn linux_sll_arp_hrd_type_any()
        (index in 0..=(LinuxSllProtocolType::SUPPORTED_ARPHWD.len()-1))
        -> ArpHardwareId
    {
        LinuxSllProtocolType::SUPPORTED_ARPHWD[index]
    }
}

prop_compose! {
    pub fn linux_sll_sender_address_any()
        (mut sender_address in prop::collection::vec(any::<u8>(), 0..8))
        -> (u16, [u8; 8])
    {
        let size = sender_address.len().try_into().unwrap();
        sender_address.resize(8, 0);
        let mut v: [u8; 8] = [0u8;8];
        v.copy_from_slice(&sender_address);

        (size, v)
    }
}

prop_compose! {
    pub fn linux_sll_any()
        (packet_type in linux_sll_packet_type_any(),
        arp_hrd_type in linux_sll_arp_hrd_type_any(),
        (sender_address_valid_length, sender_address) in linux_sll_sender_address_any(),
        protocol_num in any::<u16>()
    )
        -> LinuxSllHeader
    {
        LinuxSllHeader {
            packet_type,
            arp_hrd_type,
            sender_address_valid_length,
            sender_address,
            protocol_type: LinuxSllProtocolType::try_from((arp_hrd_type, protocol_num)).unwrap()
        }
    }
}

pub static ETHERNET_KNOWN_ETHER_TYPES: &'static [EtherType] = &[
    ether_type::ARP,
    ether_type::IPV4,
    ether_type::IPV6,
    ether_type::VLAN_TAGGED_FRAME,
    ether_type::PROVIDER_BRIDGING,
    ether_type::VLAN_DOUBLE_TAGGED_FRAME,
    ether_type::MACSEC,
];

prop_compose! {
    pub fn ethernet_2_unknown()(
        source in prop::array::uniform6(any::<u8>()),
        dest in prop::array::uniform6(any::<u8>()),
        ether_type in ether_type_any().prop_filter("ether_type must be unknown",
            |v| !ETHERNET_KNOWN_ETHER_TYPES.iter().any(|&x| v == &x)))
        -> Ethernet2Header
    {
        Ethernet2Header {
            source: source,
            destination: dest,
            ether_type: ether_type
        }
    }
}

prop_compose! {
    pub fn vlan_single_with(ether_type: EtherType)(
        pcp in vlan_pcp_any(),
        drop_eligible_indicator in any::<bool>(),
        vlan_id in vlan_id_any(),
        ether_type in proptest::strategy::Just(ether_type))
        -> SingleVlanHeader
    {
        SingleVlanHeader {
            pcp,
            drop_eligible_indicator,
            vlan_id,
            ether_type,
        }
    }
}

prop_compose! {
    pub fn vlan_single_any()
        (ether_type in ether_type_any())
        (result in vlan_single_with(ether_type))
        -> SingleVlanHeader
    {
        result
    }
}

prop_compose! {
    pub fn vlan_double_any()
        (ether_type in ether_type_any())
        (result in vlan_double_with(ether_type))
        -> DoubleVlanHeader
    {
        result
    }
}

prop_compose! {
    pub fn vlan_double_with(ether_type: EtherType)(
        outer_ethertype in vlan_ethertype_any(),
        inner_ethertype in proptest::strategy::Just(ether_type)
    )(
        outer in vlan_single_with(outer_ethertype),
        inner in vlan_single_with(inner_ethertype)
    ) -> DoubleVlanHeader {
        DoubleVlanHeader {
            outer,
            inner
        }
    }
}

prop_compose! {
    pub fn macsec_an_any()(
        an in 0u8..=0b11,
    ) -> MacsecAn
    {
        MacsecAn::try_from(an).unwrap()
    }
}

prop_compose! {
    pub fn macsec_short_len_any()(
        sl in 0u8..=0b0011_1111,
    ) -> MacsecShortLen
    {
        MacsecShortLen::try_from(sl).unwrap()
    }
}

prop_compose! {
    pub fn macsec_any()(
        endstation_id in any::<bool>(),
        scb in any::<bool>(),
        encrypted in any::<bool>(),
        userdata_changed in any::<bool>(),
        an in macsec_an_any(),
        short_len in macsec_short_len_any(),
        packet_nr in any::<u32>(),
        sci_present in any::<bool>(),
        sci in any::<u64>(),
        next_ether_type in ether_type_any()
    ) -> MacsecHeader
    {
        MacsecHeader {
            ptype: if encrypted {
                if userdata_changed {
                    MacsecPType::Encrypted
                } else {
                    MacsecPType::EncryptedUnmodified
                }
            } else {
                if userdata_changed {
                    MacsecPType::Modified
                } else {
                    MacsecPType::Unmodified(next_ether_type)
                }
            },
            endstation_id,
            scb,
            an,
            short_len,
            packet_nr,
            sci: if sci_present {
                Some(sci)
            } else {
                None
            },
        }
    }
}

prop_compose! {
    pub fn macsec_unknown()(
        endstation_id in any::<bool>(),
        scb in any::<bool>(),
        encrypted in any::<bool>(),
        userdata_changed in any::<bool>(),
        an in macsec_an_any(),
        short_len in macsec_short_len_any(),
        packet_nr in any::<u32>(),
        sci_present in any::<bool>(),
        sci in any::<u64>(),
        next_ether_type in ether_type_any().prop_filter("ether_type must be unknown",
            |v| !ETHERNET_KNOWN_ETHER_TYPES.iter().any(|&x| v == &x)))
        -> MacsecHeader
    {
        MacsecHeader {
            ptype: if encrypted {
                if userdata_changed {
                    MacsecPType::Encrypted
                } else {
                    MacsecPType::EncryptedUnmodified
                }
            } else {
                if userdata_changed {
                    MacsecPType::Modified
                } else {
                    MacsecPType::Unmodified(next_ether_type)
                }
            },
            endstation_id,
            scb,
            an,
            short_len,
            packet_nr,
            sci: if sci_present {
                Some(sci)
            } else {
                None
            },
        }
    }
}

prop_compose! {
    pub fn arp_packet_any()
    (
        hw_addr_size in any::<u8>(),
        proto_addr_size in any::<u8>()
    )
    (
        hw_addr_type in any::<u16>(),
        proto_addr_type in any::<u16>(),
        operation in any::<u16>(),
        sender_hw_addr in prop::collection::vec(any::<u8>(), hw_addr_size as usize),
        sender_protocol_addr in prop::collection::vec(any::<u8>(), proto_addr_size as usize),
        target_hw_addr in prop::collection::vec(any::<u8>(), hw_addr_size as usize),
        target_protocol_addr in prop::collection::vec(any::<u8>(), proto_addr_size as usize)
    ) -> ArpPacket
    {
        ArpPacket::new(
            ArpHardwareId(hw_addr_type),
            EtherType(proto_addr_type),
            ArpOperation(operation),
            &sender_hw_addr[..],
            &sender_protocol_addr[..],
            &target_hw_addr[..],
            &target_protocol_addr[..]
        ).unwrap()
    }
}

prop_compose! {
    pub fn arp_eth_ipv4_packet_any()
    (
        operation in any::<u16>(),
        sender_mac in prop::array::uniform6(any::<u8>()),
        sender_ipv4 in prop::array::uniform4(any::<u8>()),
        target_mac in prop::array::uniform6(any::<u8>()),
        target_ipv4 in prop::array::uniform4(any::<u8>())
    ) -> ArpEthIpv4Packet
    {
        ArpEthIpv4Packet {
            operation: ArpOperation(operation),
            sender_mac,
            sender_ipv4,
            target_mac,
            target_ipv4,
        }
    }
}

prop_compose! {
    pub fn ipv4_options_any()
    (
        len_div_4 in 0u8..10,
        options_part0 in prop::array::uniform32(any::<u8>()),
        options_part1 in prop::array::uniform8(any::<u8>())
    ) -> Ipv4Options
    {
        let mut options: [u8;40] = [0;40];
        //copy together 40 bytes of random data (the limit for static arrays in proptest 32,
        //so a 32 & 8 byte array get combined here)
        let len = usize::from(len_div_4)*4;
        if len > 0 {
            let sub_len = std::cmp::min(len,32);
            options[..sub_len].copy_from_slice(&options_part0[..sub_len]);
        }
        if len > 32 {
            let sub_len = len - 32;
            options[32..len].copy_from_slice(&options_part1[..sub_len]);
        }

        //set the options
        (&options[..len]).try_into().unwrap()
    }
}

prop_compose! {
    pub fn ipv4_with(protocol: IpNumber)
    (
        protocol in proptest::strategy::Just(protocol),
        options in ipv4_options_any()
    )(
        source in prop::array::uniform4(any::<u8>()),
        destination in prop::array::uniform4(any::<u8>()),
        dscp in 0u8..=0b0011_1111,
        ecn in 0u8..=0b0000_0011,
        identification in any::<u16>(),
        time_to_live in any::<u8>(),
        dont_fragment in any::<bool>(),
        more_fragments in any::<bool>(),
        fragment_offset in prop::bits::u16::between(0, 13),
        header_checksum in any::<u16>(),
        total_len in ((Ipv4Header::MIN_LEN + usize::from(options.len())) as u16)..core::u16::MAX,
        protocol in proptest::strategy::Just(protocol),
        options in proptest::strategy::Just(options)
    ) -> Ipv4Header
    {
        Ipv4Header{
            dscp: dscp.try_into().unwrap(),
            ecn: ecn.try_into().unwrap(),
            total_len,
            identification,
            dont_fragment,
            more_fragments,
            fragment_offset: fragment_offset.try_into().unwrap(),
            time_to_live,
            protocol,
            header_checksum,
            source,
            destination,
            options
        }
    }
}
prop_compose! {
    pub fn ipv4_any()
               (protocol in ip_number_any())
               (result in ipv4_with(protocol))
               -> Ipv4Header
    {
        result
    }
}

static IPV4_KNOWN_PROTOCOLS: &[IpNumber] = &[
    ip_number::ICMP,
    ip_number::UDP,
    ip_number::TCP,
    ip_number::AUTH,
    ip_number::IPV6_ICMP,
];

prop_compose! {
    pub fn ipv4_unknown()
        (protocol in ip_number_any().prop_filter("protocol must be unknown",
            |v| !IPV4_KNOWN_PROTOCOLS.iter().any(|&x| v == &x))
        )
        (header in ipv4_with(protocol)
    ) -> Ipv4Header
    {
        header
    }
}

prop_compose! {
    pub fn ipv4_extensions_with(next_header: IpNumber)
    (
        has_auth in any::<bool>(),
        auth in ip_auth_with(next_header)
    ) -> Ipv4Extensions
    {
        if has_auth {
            Ipv4Extensions{
                auth: Some(auth),
            }
        } else {
            Ipv4Extensions{
                auth: None,
            }
        }
    }
}

prop_compose! {
    pub fn ipv4_extensions_any()
               (protocol in ip_number_any())
               (result in ipv4_extensions_with(protocol))
               -> Ipv4Extensions
    {
        result
    }
}

prop_compose! {
    pub fn ipv4_extensions_unknown()
        (
            next_header in ip_number_any().prop_filter(
                "next_header must be unknown",
                |v| !IPV4_KNOWN_PROTOCOLS.iter().any(|&x| v == &x)
            )
        ) (
            result in ipv4_extensions_with(next_header)
        ) -> Ipv4Extensions
    {
        result
    }
}

prop_compose! {
    pub fn ipv6_with(next_header: IpNumber)
    (
        source in prop::array::uniform16(any::<u8>()),
        dest in prop::array::uniform16(any::<u8>()),
        traffic_class in any::<u8>(),
        flow_label in ipv6_flow_label_any(),
        payload_length in any::<u16>(),
        hop_limit in any::<u8>(),
        next_header in proptest::strategy::Just(next_header)
    ) -> Ipv6Header
    {
        Ipv6Header {
            traffic_class: traffic_class,
            flow_label: flow_label,
            payload_length: payload_length,
            next_header: next_header,
            hop_limit: hop_limit,
            source: source,
            destination: dest
        }
    }
}

prop_compose! {
    pub fn ipv6_any()
        (next_header in ip_number_any())
        (result in ipv6_with(next_header)
    ) -> Ipv6Header
    {
        result
    }
}

static IPV6_KNOWN_NEXT_HEADERS: &[IpNumber] = &[
    ip_number::ICMP,
    ip_number::UDP,
    ip_number::TCP,
    ip_number::IPV6_HOP_BY_HOP,
    ip_number::IPV6_ICMP,
    ip_number::IPV6_ROUTE,
    ip_number::IPV6_FRAG,
    ip_number::AUTH,
    ip_number::IPV6_DEST_OPTIONS,
    ip_number::MOBILITY,
    ip_number::HIP,
    ip_number::SHIM6,
    // currently not supported:
    // - EncapsulatingSecurityPayload
    // - ExperimentalAndTesting0
    // - ExperimentalAndTesting1
];

prop_compose! {
    pub fn ipv6_unknown()(
        source in prop::array::uniform16(any::<u8>()),
        destination in prop::array::uniform16(any::<u8>()),
        traffic_class in any::<u8>(),
        flow_label in ipv6_flow_label_any(),
        payload_length in any::<u16>(),
        hop_limit in any::<u8>(),
        next_header in ip_number_any().prop_filter("next_header must be unknown",
            |v| !IPV6_KNOWN_NEXT_HEADERS.iter().any(|&x| v == &x))
    ) -> Ipv6Header
    {
        Ipv6Header {
            traffic_class,
            flow_label,
            payload_length,
            next_header,
            hop_limit,
            source,
            destination,
        }
    }
}

prop_compose! {
    pub fn ipv6_raw_ext_with(
        next_header: IpNumber,
        len: u8
    ) (
        next_header in proptest::strategy::Just(next_header),
        payload in proptest::collection::vec(any::<u8>(), (len as usize)*8 + 6)
    ) -> Ipv6RawExtHeader
    {
        Ipv6RawExtHeader::new_raw(
            next_header,
            &payload[..]
        ).unwrap()
    }
}

prop_compose! {
    pub fn ipv6_raw_ext_any()
        (
            next_header in ip_number_any(),
            len in any::<u8>()
        ) (
            result in ipv6_raw_ext_with(next_header, len)
    ) -> Ipv6RawExtHeader
    {
        result
    }
}

prop_compose! {
    pub fn ipv6_extensions_with(next_header: IpNumber)
    (
        has_hop_by_hop_options in any::<bool>(),
        hop_by_hop_options in ipv6_raw_ext_any(),
        has_destination_options in any::<bool>(),
        destination_options in ipv6_raw_ext_any(),
        has_routing in any::<bool>(),
        routing in ipv6_raw_ext_any(),
        has_fragment in any::<bool>(),
        fragment in ipv6_fragment_any(),
        has_auth in any::<bool>(),
        auth in ip_auth_with(next_header),
        has_final_destination_options in any::<bool>(),
        final_destination_options in ipv6_raw_ext_any()
    ) -> Ipv6Extensions
    {
        let mut result = Ipv6Extensions {
            hop_by_hop_options: if has_hop_by_hop_options {
                Some(hop_by_hop_options)
            } else {
                None
            },
            destination_options: if has_destination_options {
                Some(destination_options)
            } else {
                None
            },
            routing: if has_routing {
                Some(
                    Ipv6RoutingExtensions{
                        routing,
                        final_destination_options: if has_final_destination_options {
                            Some(final_destination_options)
                        } else {
                            None
                        }
                    }
                )
            } else {
                None
            },
            fragment: if has_fragment {
                Some(fragment)
            } else {
                None
            },
            auth: if has_auth {
                Some(auth)
            } else {
                None
            },
        };
        result.set_next_headers(next_header);
        result
    }
}

prop_compose! {
    pub fn ipv6_extensions_any()
        (
            next_header in ip_number_any()
        ) (
            result in ipv6_extensions_with(next_header)
    ) -> Ipv6Extensions
    {
        result
    }
}

prop_compose! {
    pub fn ipv6_extensions_unknown()
        (
            next_header in ip_number_any().prop_filter(
                "next_header must be unknown",
                |v| !IPV6_KNOWN_NEXT_HEADERS.iter().any(|&x| v == &x)
            )
        ) (
            result in ipv6_extensions_with(next_header)
        ) -> Ipv6Extensions
    {
        result
    }
}

prop_compose! {
    pub fn ipv6_fragment_with(
        next_header: IpNumber
    ) (
        next_header in proptest::strategy::Just(next_header),
        fragment_offset in 0u16..=0b0001_1111_1111_1111u16,
        more_fragments in any::<bool>(),
        identification in any::<u32>(),
    ) -> Ipv6FragmentHeader
    {
        Ipv6FragmentHeader::new(
            next_header,
            fragment_offset.try_into().unwrap(),
            more_fragments,
            identification
        )
    }
}

prop_compose! {
    pub fn ipv6_fragment_any()
        (next_header in ip_number_any())
        (result in ipv6_fragment_with(next_header)
    ) -> Ipv6FragmentHeader
    {
        result
    }
}

prop_compose! {
    pub fn ip_auth_with(
        next_header: IpNumber
    ) (
        next_header in proptest::strategy::Just(next_header),
        len in 1..0xffu8
    ) (
        next_header in proptest::strategy::Just(next_header),
        spi in any::<u32>(),
        sequence_number in any::<u32>(),
        icv in proptest::collection::vec(any::<u8>(), (len as usize)*4)
    ) -> IpAuthHeader {
        IpAuthHeader::new(
            next_header,
            spi,
            sequence_number,
            &icv
        ).unwrap()
    }
}

prop_compose! {
    pub fn ip_auth_any() (
        next_header in ip_number_any()
    ) (
        header in ip_auth_with(next_header)
    ) -> IpAuthHeader {
        header
    }
}

prop_compose! {
    pub fn udp_any()(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            length in any::<u16>(),
            checksum in any::<u16>())
        -> UdpHeader
    {
        UdpHeader {
            source_port: source_port,
            destination_port: destination_port,
            length: length,
            checksum: checksum
        }
    }
}

prop_compose! {
    pub fn tcp_any()
        (data_offset in TcpHeader::MIN_DATA_OFFSET..(TcpHeader::MAX_DATA_OFFSET + 1))
        (
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            sequence_number in any::<u32>(),
            acknowledgment_number in any::<u32>(),
            ns in any::<bool>(),
            fin in any::<bool>(),
            syn in any::<bool>(),
            rst in any::<bool>(),
            psh in any::<bool>(),
            ack in any::<bool>(),
            ece in any::<bool>(),
            urg in any::<bool>(),
            cwr  in any::<bool>(),
            window_size in any::<u16>(),
            checksum in any::<u16>(),
            urgent_pointer in any::<u16>(),
            options in proptest::collection::vec(any::<u8>(), ((data_offset - 5) as usize)*4))
        -> TcpHeader
    {
        let mut result = TcpHeader::new(source_port, destination_port, sequence_number, window_size);
        result.acknowledgment_number = acknowledgment_number;
        result.ns = ns;
        result.fin = fin;
        result.syn = syn;
        result.rst = rst;
        result.psh = psh;
        result.ack = ack;
        result.ece = ece;
        result.urg = urg;
        result.cwr = cwr;
        result.checksum = checksum;
        result.urgent_pointer = urgent_pointer;
        result.set_options_raw(&options[..]).unwrap();
        result
    }
}

prop_compose! {
    pub fn tcp_options_any()
    (data_offset in TcpHeader::MIN_DATA_OFFSET..(TcpHeader::MAX_DATA_OFFSET + 1))
    (
        options in proptest::collection::vec(any::<u8>(), ((data_offset - 5) as usize)*4)
    ) -> TcpOptions
    {
        TcpOptions::try_from_slice(&options).unwrap()
    }
}

prop_compose! {
    pub fn icmpv4_type_any()
        (
            bytes in any::<[u8;20]>(),
        ) -> Icmpv4Type
    {
        Icmpv4Header::from_slice(&bytes).unwrap().0.icmp_type
    }
}

prop_compose! {
    pub fn icmpv4_header_any()
        (
            bytes in any::<[u8;20]>(),
        ) -> Icmpv4Header
    {
        Icmpv4Header::from_slice(&bytes).unwrap().0
    }
}

prop_compose! {
    pub fn icmpv6_type_any()
        (
            bytes in any::<[u8;8]>(),
        ) -> Icmpv6Type
    {
        Icmpv6Header::from_slice(&bytes).unwrap().0.icmp_type
    }
}

prop_compose! {
    pub fn icmpv6_header_any()
        (
            bytes in any::<[u8;8]>(),
        ) -> Icmpv6Header
    {
        Icmpv6Header::from_slice(&bytes).unwrap().0
    }
}
