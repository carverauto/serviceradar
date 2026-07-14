use arrayvec::ArrayVec;

use crate::*;

/// Packet slice split into multiple slices containing the different headers & payload.
///
/// Everything that could not be parsed is stored in a slice in the field "payload".
///
/// You can use
///
/// * [`SlicedPacket::from_ethernet`]
/// * [`SlicedPacket::from_ether_type`]
/// * [`SlicedPacket::from_ip`]
///
/// depending on your starting header to slice a packet.
///
/// # Examples
///
/// Basic usage:
///
///```
/// # use etherparse::{SlicedPacket, PacketBuilder};
/// # let builder = PacketBuilder::
/// #    ethernet2([1,2,3,4,5,6],     //source mac
/// #               [7,8,9,10,11,12]) //destination mac
/// #    .ipv4([192,168,1,1], //source ip
/// #          [192,168,1,2], //destination ip
/// #          20)            //time to life
/// #    .udp(21,    //source port
/// #         1234); // destination port
/// #    //payload of the udp packet
/// #    let payload = [1,2,3,4,5,6,7,8];
/// #    //get some memory to store the serialized data
/// #    let mut packet = Vec::<u8>::with_capacity(
/// #                            builder.size(payload.len()));
/// #    builder.write(&mut packet, &payload).unwrap();
/// match SlicedPacket::from_ethernet(&packet) {
///     Err(value) => println!("Err {:?}", value),
///     Ok(value) => {
///         println!("link: {:?}", value.link);
///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
///         println!("net: {:?}", value.net); // ip & arp
///         println!("transport: {:?}", value.transport);
///     }
/// };
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SlicedPacket<'a> {
    /// Ethernet II header if present.
    pub link: Option<LinkSlice<'a>>,

    /// Link extensions (VLAN & MAC Sec headers).
    pub link_exts: ArrayVec<LinkExtSlice<'a>, { SlicedPacket::LINK_EXTS_CAP }>,

    /// IPv4 or IPv6 header, IP extension headers & payload if present.
    pub net: Option<NetSlice<'a>>,

    /// TCP or UDP header & payload if present.
    pub transport: Option<TransportSlice<'a>>,
}

impl<'a> SlicedPacket<'a> {
    /// Maximum supported number of link extensions.
    pub const LINK_EXTS_CAP: usize = 3;

    /// Separates a network packet slice into different slices containing the headers from the ethernet header downwards.
    ///
    /// The result is returned as a [`SlicedPacket`] struct. This function assumes the given data starts
    /// with an ethernet II header.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{SlicedPacket, PacketBuilder};
    /// # let builder = PacketBuilder::
    /// #    ethernet2([1,2,3,4,5,6],     //source mac
    /// #               [7,8,9,10,11,12]) //destination mac
    /// #    .ipv4([192,168,1,1], //source ip
    /// #          [192,168,1,2], //destination ip
    /// #          20)            //time to life
    /// #    .udp(21,    //source port
    /// #         1234); // destination port
    /// #    //payload of the udp packet
    /// #    let payload = [1,2,3,4,5,6,7,8];
    /// #    //get some memory to store the serialized data
    /// #    let mut packet = Vec::<u8>::with_capacity(
    /// #                            builder.size(payload.len()));
    /// #    builder.write(&mut packet, &payload).unwrap();
    /// match SlicedPacket::from_ethernet(&packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// };
    /// ```
    pub fn from_ethernet(data: &'a [u8]) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        SlicedPacketCursor::new().slice_ethernet2(data)
    }

    /// Separates a network packet slice into different slices containing the
    /// headers from the Linux Cooked Capture v1 (SLL) header downwards.
    ///
    /// The result is returned as a [`SlicedPacket`] struct. This function
    /// assumes the given data starts with a Linux Cooked Capture v1 (SLL)
    /// header.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{SlicedPacket, PacketBuilder, LinuxSllPacketType};
    /// # let builder = PacketBuilder::
    /// #    linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    /// #              6, //sender address valid length
    /// #              [1,2,3,4,5,6,0,0]) //sender address with padding
    /// #   .ipv4([192,168,1,1], //source ip
    /// #         [192,168,1,2], //destination ip
    /// #         20)            //time to life
    /// #   .udp(21,    //source port
    /// #        1234); //destination port
    /// #    //payload of the udp packet
    /// #    let payload = [1,2,3,4,5,6,7,8];
    /// #    //get some memory to store the serialized data
    /// #    let mut packet = Vec::<u8>::with_capacity(
    /// #                            builder.size(payload.len()));
    /// #    builder.write(&mut packet, &payload).unwrap();
    /// match SlicedPacket::from_linux_sll(&packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// };
    /// ```
    pub fn from_linux_sll(data: &'a [u8]) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        SlicedPacketCursor::new().slice_linux_sll(data)
    }

    /// Separates a network packet slice into different slices containing the headers using
    /// the given `ether_type` number to identify the first header.
    ///
    /// The result is returned as a [`SlicedPacket`] struct. Currently supported
    /// ether type numbers are:
    ///
    /// * `ether_type::ARP`
    /// * `ether_type::IPV4`
    /// * `ether_type::IPV6`
    /// * `ether_type::VLAN_TAGGED_FRAME`
    /// * `ether_type::PROVIDER_BRIDGING`
    /// * `ether_type::VLAN_DOUBLE_TAGGED_FRAME`
    ///
    /// If an unsupported ether type is given the given slice will be set as payload
    /// and all other fields will be set to `None`.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{Ethernet2Header, PacketBuilder};
    /// # let builder = PacketBuilder::
    /// #    ethernet2([1,2,3,4,5,6],     //source mac
    /// #               [7,8,9,10,11,12]) //destination mac
    /// #    .ipv4([192,168,1,1], //source ip
    /// #          [192,168,1,2], //destination ip
    /// #          20)            //time to life
    /// #    .udp(21,    //source port
    /// #         1234); // destination port
    /// # // payload of the udp packet
    /// # let payload = [1,2,3,4,5,6,7,8];
    /// # // get some memory to store the serialized data
    /// # let mut complete_packet = Vec::<u8>::with_capacity(
    /// #     builder.size(payload.len())
    /// # );
    /// # builder.write(&mut complete_packet, &payload).unwrap();
    /// #
    /// # // skip ethernet 2 header so we can parse from there downwards
    /// # let packet = &complete_packet[Ethernet2Header::LEN..];
    /// #
    /// use etherparse::{ether_type, SlicedPacket};
    ///
    /// match SlicedPacket::from_ether_type(ether_type::IPV4, packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// };
    /// ```
    pub fn from_ether_type(
        ether_type: EtherType,
        data: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        let mut cursor = SlicedPacketCursor::new();
        cursor.result.link = Some(LinkSlice::EtherPayload(EtherPayloadSlice {
            ether_type,
            len_source: LenSource::Slice,
            payload: data,
        }));
        cursor.slice_ether_type(EtherPayloadSlice {
            ether_type,
            len_source: LenSource::Slice,
            payload: data,
        })
    }

    /// Separates a network packet slice into different slices containing the headers from the ip header downwards.
    ///
    /// The result is returned as a [`SlicedPacket`] struct. This function assumes the given data starts
    /// with an IPv4 or IPv6 header.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{SlicedPacket, PacketBuilder};
    /// # let builder = PacketBuilder::
    /// #    ipv4([192,168,1,1], //source ip
    /// #         [192,168,1,2], //destination ip
    /// #         20)            //time to life
    /// #    .udp(21,    //source port
    /// #         1234); // destination port
    /// #    //payload of the udp packet
    /// #    let payload = [1,2,3,4,5,6,7,8];
    /// #    //get some memory to store the serialized data
    /// #    let mut packet = Vec::<u8>::with_capacity(
    /// #                            builder.size(payload.len()));
    /// #    builder.write(&mut packet, &payload).unwrap();
    /// match SlicedPacket::from_ip(&packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         //link & vlan fields are empty when parsing from ip downwards
    ///         assert_eq!(None, value.link);
    ///         assert!(value.link_exts.is_empty());
    ///
    ///         //ip & transport (udp or tcp)
    ///         println!("net: {:?}", value.net);
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// };
    /// ```
    pub fn from_ip(data: &'a [u8]) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        SlicedPacketCursor::new().slice_ip(data)
    }

    /// If the slice in the `payload` field contains an ethernet payload
    /// this method returns the ether type number describing the payload type.
    ///
    /// The ether type number can come from an ethernet II header or a
    /// VLAN header depending on which headers are present.
    ///
    /// In case that `ip` and/or `transport` fields are the filled None
    /// is returned, as the payload contents then are defined by a
    /// lower layer protocol described in these fields.
    pub fn payload_ether_type(&self) -> Option<EtherType> {
        if self.net.is_some() || self.transport.is_some() {
            None
        } else if let Some(last_ext) = &self.link_exts.last() {
            use LinkExtSlice::*;
            match last_ext {
                Vlan(single_vlan_slice) => Some(single_vlan_slice.ether_type()),
                Macsec(macsec_slice) => macsec_slice.next_ether_type(),
            }
        } else if let Some(link) = &self.link {
            use LinkSlice::*;
            match link {
                Ethernet2(eth) => Some(eth.ether_type()),
                LinkSlice::LinuxSll(e) => match e.protocol_type() {
                    LinuxSllProtocolType::EtherType(EtherType(v)) => Some(EtherType(v)),
                    _ => None,
                },
                EtherPayload(e) => Some(e.ether_type),
                LinkSlice::LinuxSllPayload(e) => match e.protocol_type {
                    LinuxSllProtocolType::EtherType(EtherType(v)) => Some(EtherType(v)),
                    _ => None,
                },
            }
        } else {
            None
        }
    }

    /// Returns the last ether payload of the packet (if one is present).
    ///
    /// If VLAN header is present the payload after the most inner VLAN
    /// header is returned and if there is no VLAN header is present in the
    /// link field is returned.
    pub fn ether_payload(&self) -> Option<EtherPayloadSlice<'a>> {
        if let Some(last_ext) = self.link_exts.last() {
            let mut len_source = LenSource::Slice;
            for e in &self.link_exts {
                match e {
                    LinkExtSlice::Vlan(_) => {}
                    LinkExtSlice::Macsec(m) => {
                        if m.header.short_len() != MacsecShortLen::ZERO {
                            len_source = LenSource::MacsecShortLength;
                        }
                    }
                }
            }
            match last_ext {
                LinkExtSlice::Vlan(v) => {
                    let mut p = v.payload();
                    p.len_source = len_source;
                    Some(p)
                }
                LinkExtSlice::Macsec(m) => {
                    if let Some(mut p) = m.ether_payload() {
                        p.len_source = len_source;
                        Some(p)
                    } else {
                        None
                    }
                }
            }
        } else if let Some(link) = self.link.as_ref() {
            match link {
                LinkSlice::Ethernet2(e) => Some(e.payload()),
                LinkSlice::LinuxSll(e) => match e.protocol_type() {
                    LinuxSllProtocolType::EtherType(_) => {
                        Some(EtherPayloadSlice::try_from(e.payload()).ok()?)
                    }
                    _ => None,
                },
                LinkSlice::EtherPayload(e) => Some(e.clone()),
                LinkSlice::LinuxSllPayload(e) => match e.protocol_type {
                    LinuxSllProtocolType::EtherType(_) => {
                        Some(EtherPayloadSlice::try_from(e.clone()).ok()?)
                    }
                    _ => None,
                },
            }
        } else {
            None
        }
    }

    /// Return the IP payload after the the IP header and the IP extension
    /// headers (if one is present).
    pub fn ip_payload(&self) -> Option<&IpPayloadSlice<'a>> {
        if let Some(net) = self.net.as_ref() {
            use NetSlice::*;
            match net {
                Ipv4(v) => Some(v.payload()),
                Ipv6(v) => Some(v.payload()),
                Arp(_) => None,
            }
        } else {
            None
        }
    }

    /// Returns true if `net` contains an fragmented IPv4 or IPv6 payload.
    pub fn is_ip_payload_fragmented(&self) -> bool {
        use NetSlice::*;
        match &self.net {
            Some(Ipv4(v)) => v.is_payload_fragmented(),
            Some(Ipv6(v)) => v.is_payload_fragmented(),
            Some(Arp(_)) | None => false,
        }
    }

    /// Returns the vlan headers present in the sliced packet.
    pub fn vlan(&self) -> Option<VlanSlice<'a>> {
        let mut result = None;
        for ext in &self.link_exts {
            if let LinkExtSlice::Vlan(vlan_slice) = ext {
                if let Some(outer) = result {
                    return Some(VlanSlice::DoubleVlan(DoubleVlanSlice {
                        outer,
                        inner: vlan_slice.clone(),
                    }));
                } else {
                    result = Some(vlan_slice.clone());
                }
            }
        }
        result.map(VlanSlice::SingleVlan)
    }

    /// Returns the VLAN ids present in this packet.
    pub fn vlan_ids(&self) -> ArrayVec<VlanId, { SlicedPacket::LINK_EXTS_CAP }> {
        let mut result = ArrayVec::<VlanId, { SlicedPacket::LINK_EXTS_CAP }>::new_const();
        for e in &self.link_exts {
            // SAFETY: Safe as the vlan ids array has the same size as slice.link_exts.
            if let LinkExtSlice::Vlan(s) = e {
                unsafe {
                    result.push_unchecked(s.vlan_identifier());
                }
            }
        }
        result
    }
}

#[cfg(test)]
mod test {
    use std::vec::Vec;

    use super::*;
    use crate::err::macsec;
    use crate::err::{packet::SliceError, Layer, LenError};
    use crate::test_gens::*;
    use crate::test_packet::TestPacket;
    use proptest::prelude::*;

    const VLAN_ETHER_TYPES: [EtherType; 3] = [
        ether_type::VLAN_TAGGED_FRAME,
        ether_type::PROVIDER_BRIDGING,
        ether_type::VLAN_DOUBLE_TAGGED_FRAME,
    ];
    const MACSEC_ETHER_TYPES: [EtherType; 1] = [ether_type::MACSEC];

    #[test]
    fn clone_eq() {
        let header = SlicedPacket {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
        };
        assert_eq!(header.clone(), header);
    }

    #[test]
    fn debug() {
        use alloc::format;
        let header = SlicedPacket {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
        };
        assert_eq!(
            format!("{:?}", header),
            format!(
                "SlicedPacket {{ link: {:?}, link_exts: {:?}, net: {:?}, transport: {:?} }}",
                header.link, header.link_exts, header.net, header.transport,
            )
        );
    }

    #[test]
    fn ether_payload() {
        use alloc::vec::*;

        // no content
        assert_eq!(
            SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            }
            .ether_payload(),
            None
        );

        // only ethernet header II
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ethernet2Header::LEN + 4);
            buf.extend_from_slice(
                &Ethernet2Header {
                    ether_type: EtherType::WAKE_ON_LAN,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ethernet(&buf).unwrap().ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }

        // ether type payload
        {
            let payload = [1, 2, 3, 4];
            assert_eq!(
                SlicedPacket {
                    link: Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                        ether_type: EtherType::WAKE_ON_LAN,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })),
                    link_exts: ArrayVec::new_const(),
                    net: None,
                    transport: None,
                }
                .ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }

        // only linux_sll payload
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(LinuxSllHeader::LEN + 4);
            buf.extend_from_slice(
                &LinuxSllHeader {
                    packet_type: LinuxSllPacketType::HOST,
                    arp_hrd_type: ArpHardwareId::ETHERNET,
                    sender_address_valid_length: 6,
                    sender_address: [1, 2, 3, 4, 5, 6, 0, 0],
                    protocol_type: LinuxSllProtocolType::EtherType(EtherType::WAKE_ON_LAN),
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_linux_sll(&buf).unwrap().ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }
        // only linux sll
        {
            let test = [
                (None, ArpHardwareId::FRAD, LinuxSllProtocolType::Ignored(0)),
                (
                    None,
                    ArpHardwareId::NETLINK,
                    LinuxSllProtocolType::NetlinkProtocolType(0),
                ),
                (
                    None,
                    ArpHardwareId::IPGRE,
                    LinuxSllProtocolType::GenericRoutingEncapsulationProtocolType(0),
                ),
                (
                    Some(ether_type::WAKE_ON_LAN),
                    ArpHardwareId::ETHERNET,
                    LinuxSllProtocolType::EtherType(ether_type::WAKE_ON_LAN),
                ),
                (
                    None,
                    ArpHardwareId::ETHERNET,
                    LinuxSllProtocolType::LinuxNonstandardEtherType(LinuxNonstandardEtherType::CAN),
                ),
            ];

            for (expected, arp_hrd_type, protocol_type) in test {
                {
                    let l = LinuxSllHeader {
                        packet_type: LinuxSllPacketType::HOST,
                        arp_hrd_type,
                        sender_address_valid_length: 6,
                        sender_address: [0; 8],
                        protocol_type,
                    };

                    let mut bytes = Vec::with_capacity(l.header_len());
                    l.write(&mut bytes).unwrap();

                    let s = SlicedPacket::from_linux_sll(&bytes).unwrap();
                    assert_eq!(
                        expected.map(|ether_type| {
                            EtherPayloadSlice {
                                ether_type,
                                len_source: LenSource::Slice,
                                payload: &[],
                            }
                        }),
                        s.ether_payload()
                    );
                }
                {
                    let s = SlicedPacket {
                        link: Some(LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice {
                            protocol_type: protocol_type,
                            payload: &[],
                        })),
                        link_exts: Default::default(),
                        net: None,
                        transport: None,
                    };
                    assert_eq!(
                        expected.map(|ether_type| {
                            EtherPayloadSlice {
                                ether_type,
                                len_source: LenSource::Slice,
                                payload: &[],
                            }
                        }),
                        s.ether_payload()
                    );
                }
            }
        }

        // ether type payload
        {
            let payload = [1, 2, 3, 4];
            assert_eq!(
                SlicedPacket {
                    link: Some(LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice {
                        protocol_type: LinuxSllProtocolType::EtherType(EtherType::WAKE_ON_LAN),
                        payload: &payload
                    })),
                    link_exts: ArrayVec::new_const(),
                    net: None,
                    transport: None,
                }
                .ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }

        // single vlan header
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ethernet2Header::LEN + SingleVlanHeader::LEN + 4);
            buf.extend_from_slice(
                &Ethernet2Header {
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    ether_type: EtherType::WAKE_ON_LAN,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ethernet(&buf).unwrap().ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }

        // double vlan header
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ethernet2Header::LEN + SingleVlanHeader::LEN * 2 + 4);
            buf.extend_from_slice(
                &Ethernet2Header {
                    ether_type: EtherType::VLAN_DOUBLE_TAGGED_FRAME,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    ether_type: EtherType::WAKE_ON_LAN,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ethernet(&buf).unwrap().ether_payload(),
                Some(EtherPayloadSlice {
                    ether_type: EtherType::WAKE_ON_LAN,
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
        }

        // macsec
        {
            let tests = [
                (
                    Some(ether_type::WAKE_ON_LAN),
                    MacsecPType::Unmodified(ether_type::WAKE_ON_LAN),
                ),
                (None, MacsecPType::Modified),
                (None, MacsecPType::Encrypted),
                (None, MacsecPType::EncryptedUnmodified),
            ];
            for (expected, ptype) in tests {
                let eth_mod = Ethernet2Header {
                    source: [0; 6],
                    destination: [0; 6],
                    ether_type: ether_type::VLAN_TAGGED_FRAME,
                };
                let vlan = SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(1).unwrap(),
                    ether_type: EtherType::MACSEC,
                };
                let macsec0 = MacsecHeader {
                    ptype: MacsecPType::Unmodified(EtherType::MACSEC),
                    endstation_id: false,
                    scb: false,
                    an: MacsecAn::ZERO,
                    short_len: MacsecShortLen::ZERO,
                    packet_nr: 0,
                    sci: None,
                };
                let mut macsec1 = MacsecHeader {
                    ptype,
                    endstation_id: false,
                    scb: false,
                    an: MacsecAn::ZERO,
                    short_len: MacsecShortLen::ZERO,
                    packet_nr: 0,
                    sci: None,
                };
                let payload = [1, 2, 3, 4];
                macsec1.set_payload_len(payload.len());
                let mut serialized = Vec::with_capacity(
                    eth_mod.header_len()
                        + vlan.header_len()
                        + macsec0.header_len()
                        + macsec1.header_len()
                        + payload.len(),
                );
                eth_mod.write(&mut serialized).unwrap();
                vlan.write(&mut serialized).unwrap();
                macsec0.write(&mut serialized).unwrap();
                macsec1.write(&mut serialized).unwrap();
                serialized.extend_from_slice(&payload);

                assert_eq!(
                    expected.map(|ether_type| EtherPayloadSlice {
                        ether_type,
                        len_source: LenSource::MacsecShortLength,
                        payload: &payload,
                    }),
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .ether_payload()
                );
            }
        }
    }

    #[test]
    fn ip_payload() {
        use alloc::vec::*;

        // no content
        assert_eq!(
            SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            }
            .ip_payload(),
            None
        );

        // arp
        {
            let mut buf = Vec::with_capacity(Ethernet2Header::LEN + ArpEthIpv4Packet::LEN);
            buf.extend_from_slice(
                &Ethernet2Header {
                    source: [0; 6],
                    destination: [0; 6],
                    ether_type: EtherType::ARP,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &ArpEthIpv4Packet {
                    operation: ArpOperation::REPLY,
                    sender_mac: [0; 6],
                    sender_ipv4: [0; 4],
                    target_mac: [0; 6],
                    target_ipv4: [0; 4],
                }
                .to_bytes(),
            );
            assert_eq!(
                SlicedPacket::from_ethernet(&buf).unwrap().ip_payload(),
                None
            );
        }

        // ipv4
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
            buf.extend_from_slice(
                &Ipv4Header {
                    protocol: IpNumber::ARIS,
                    total_len: Ipv4Header::MIN_LEN_U16 + 4,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ip(&buf).unwrap().ip_payload(),
                Some(&IpPayloadSlice {
                    payload: &payload,
                    ip_number: IpNumber::ARIS,
                    fragmented: false,
                    len_source: LenSource::Ipv4HeaderTotalLen,
                })
            );
        }

        // ipv6
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv6Header::LEN + 4);
            buf.extend_from_slice(
                &Ipv6Header {
                    payload_length: 4,
                    next_header: IpNumber::ARGUS,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ip(&buf).unwrap().ip_payload(),
                Some(&IpPayloadSlice {
                    payload: &payload,
                    ip_number: IpNumber::ARGUS,
                    fragmented: false,
                    len_source: LenSource::Ipv6HeaderPayloadLen,
                })
            );
        }
    }

    #[test]
    fn is_ip_payload_fragmented() {
        use alloc::vec::*;

        // no content
        assert_eq!(
            SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            }
            .is_ip_payload_fragmented(),
            false
        );

        // arp
        {
            let mut buf = Vec::with_capacity(Ethernet2Header::LEN + ArpEthIpv4Packet::LEN);
            buf.extend_from_slice(
                &Ethernet2Header {
                    source: [0; 6],
                    destination: [0; 6],
                    ether_type: EtherType::ARP,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &ArpEthIpv4Packet {
                    operation: ArpOperation::REPLY,
                    sender_mac: [0; 6],
                    sender_ipv4: [0; 4],
                    target_mac: [0; 6],
                    target_ipv4: [0; 4],
                }
                .to_bytes(),
            );
            assert_eq!(
                SlicedPacket::from_ethernet(&buf)
                    .unwrap()
                    .is_ip_payload_fragmented(),
                false
            );
        }

        // ipv4 (non fragmented)
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
            buf.extend_from_slice(
                &Ipv4Header {
                    protocol: IpNumber::ARIS,
                    total_len: Ipv4Header::MIN_LEN_U16 + 4,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ip(&buf)
                    .unwrap()
                    .is_ip_payload_fragmented(),
                false
            );
        }

        // ipv4 (fragmented)
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
            buf.extend_from_slice(
                &Ipv4Header {
                    protocol: IpNumber::ARIS,
                    total_len: Ipv4Header::MIN_LEN_U16 + 4,
                    more_fragments: true,
                    fragment_offset: IpFragOffset::ZERO,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert!(SlicedPacket::from_ip(&buf)
                .unwrap()
                .is_ip_payload_fragmented());
        }

        // ipv6 (non fragmented)
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv6Header::LEN + 4);
            buf.extend_from_slice(
                &Ipv6Header {
                    payload_length: 4,
                    next_header: IpNumber::ARGUS,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert_eq!(
                SlicedPacket::from_ip(&buf)
                    .unwrap()
                    .is_ip_payload_fragmented(),
                false
            );
        }

        // ipv6 (fragmented)
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(Ipv6Header::LEN + 4);
            buf.extend_from_slice(
                &Ipv6Header {
                    payload_length: Ipv6FragmentHeader::LEN as u16 + 4,
                    next_header: IpNumber::IPV6_FRAGMENTATION_HEADER,
                    ..Default::default()
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &Ipv6FragmentHeader {
                    next_header: IpNumber::ARGUS,
                    fragment_offset: IpFragOffset::ZERO,
                    more_fragments: true,
                    identification: 0,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);
            assert!(SlicedPacket::from_ip(&buf)
                .unwrap()
                .is_ip_payload_fragmented());
        }
    }

    #[test]
    fn vlan_vlan_ids() {
        // no content
        assert_eq!(
            SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            }
            .vlan(),
            None
        );
        assert_eq!(
            SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            }
            .vlan_ids(),
            ArrayVec::<VlanId, 3>::new_const()
        );

        // single vlan header
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(SingleVlanHeader::LEN + 4);
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(1).unwrap(),
                    ether_type: EtherType::WAKE_ON_LAN,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);

            let slice = SlicedPacket::from_ether_type(ether_type::VLAN_TAGGED_FRAME, &buf).unwrap();

            assert_eq!(
                slice.vlan(),
                Some(VlanSlice::SingleVlan(SingleVlanSlice { slice: &buf[..] }))
            );
            assert_eq!(slice.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids
            });
        }

        // two vlan header
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(SingleVlanHeader::LEN * 2 + 4);
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(1).unwrap(),
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(2).unwrap(),
                    ether_type: EtherType::WAKE_ON_LAN,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);

            let slice =
                SlicedPacket::from_ether_type(ether_type::VLAN_DOUBLE_TAGGED_FRAME, &buf).unwrap();

            assert_eq!(
                slice.vlan(),
                Some(VlanSlice::DoubleVlan(DoubleVlanSlice {
                    outer: SingleVlanSlice { slice: &buf },
                    inner: SingleVlanSlice {
                        slice: &buf[SingleVlanHeader::LEN..]
                    },
                }))
            );
            assert_eq!(slice.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids.push(VlanId::try_new(2).unwrap());
                ids
            });
        }

        // two vlan header & macsec header
        {
            let payload = [1, 2, 3, 4];
            let macsec = MacsecHeader {
                ptype: MacsecPType::Unmodified(ether_type::VLAN_DOUBLE_TAGGED_FRAME),
                endstation_id: false,
                scb: false,
                an: MacsecAn::ZERO,
                short_len: MacsecShortLen::ZERO,
                packet_nr: 0,
                sci: None,
            };
            let mut buf = Vec::with_capacity(macsec.header_len() + SingleVlanHeader::LEN * 2 + 4);
            buf.extend_from_slice(&macsec.to_bytes());
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(1).unwrap(),
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(2).unwrap(),
                    ether_type: EtherType::WAKE_ON_LAN,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);

            let slice = SlicedPacket::from_ether_type(ether_type::MACSEC, &buf).unwrap();

            assert_eq!(
                slice.vlan(),
                Some(VlanSlice::DoubleVlan(DoubleVlanSlice {
                    outer: SingleVlanSlice {
                        slice: &buf[macsec.header_len()..]
                    },
                    inner: SingleVlanSlice {
                        slice: &buf[macsec.header_len() + SingleVlanHeader::LEN..]
                    },
                }))
            );
            assert_eq!(slice.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids.push(VlanId::try_new(2).unwrap());
                ids
            });
        }

        // three vlan header
        {
            let payload = [1, 2, 3, 4];
            let mut buf = Vec::with_capacity(SingleVlanHeader::LEN * 3 + 4);
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(1).unwrap(),
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(2).unwrap(),
                    ether_type: EtherType::VLAN_TAGGED_FRAME,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::ZERO,
                    drop_eligible_indicator: false,
                    vlan_id: VlanId::try_new(3).unwrap(),
                    ether_type: EtherType::WAKE_ON_LAN,
                }
                .to_bytes(),
            );
            buf.extend_from_slice(&payload);

            let slice =
                SlicedPacket::from_ether_type(ether_type::VLAN_DOUBLE_TAGGED_FRAME, &buf).unwrap();

            assert_eq!(
                slice.vlan(),
                Some(VlanSlice::DoubleVlan(DoubleVlanSlice {
                    outer: SingleVlanSlice { slice: &buf },
                    inner: SingleVlanSlice {
                        slice: &buf[SingleVlanHeader::LEN..]
                    },
                }))
            );
            assert_eq!(slice.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids.push(VlanId::try_new(2).unwrap());
                ids.push(VlanId::try_new(3).unwrap());
                ids
            });
        }
    }

    #[test]
    fn from_x_slice() {
        // no eth
        from_x_slice_link_exts_variants(&TestPacket {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
        });

        // eth payload
        {
            let data = [1, 2, 3, 4];
            let result = SlicedPacket::from_ether_type(EtherType(0x8221), &data).unwrap();
            assert_eq!(
                result,
                SlicedPacket {
                    link: Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                        ether_type: EtherType(0x8221),
                        len_source: LenSource::Slice,
                        payload: &data
                    })),
                    link_exts: ArrayVec::new_const(),
                    net: None,
                    transport: None
                }
            );
        }

        // eth
        {
            let eth = Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [1, 2, 3, 4, 5, 6],
                ether_type: 0.into(),
            };
            let test = TestPacket {
                link: Some(LinkHeader::Ethernet2(eth.clone())),
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            };

            // ok ethernet header (with unknown next)
            from_x_slice_link_exts_variants(&test);

            // eth len error
            {
                let data = test.to_vec(&[]);
                for len in 0..data.len() {
                    let err = LenError {
                        required_len: eth.header_len(),
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::Ethernet2Header,
                        layer_start_offset: 0,
                    };

                    from_slice_assert_err(&test, &data[..len], SliceError::Len(err.clone()));
                }
            }
        }

        // linux_sll
        {
            let linux_sll = LinuxSllHeader {
                packet_type: LinuxSllPacketType::HOST,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 6,
                sender_address: [1, 2, 3, 4, 5, 6, 0, 0],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType::WAKE_ON_LAN),
            };
            let test = TestPacket {
                link: Some(LinkHeader::LinuxSll(linux_sll.clone())),
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            };

            // eth len error
            {
                let data = test.to_vec(&[]);
                for len in 0..data.len() {
                    let err = LenError {
                        required_len: linux_sll.header_len(),
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::LinuxSllHeader,
                        layer_start_offset: 0,
                    };

                    from_slice_assert_err(&test, &data[..len], SliceError::Len(err.clone()));
                }
            }
        }
    }

    fn from_x_slice_link_exts_variants(base: &TestPacket) {
        #[derive(Copy, Clone, Eq, PartialEq)]
        enum Ext {
            Macsec,
            VlanTaggedFrame,
            VlanDoubleTaggedFrame,
            ProviderBridging,
        }

        impl Ext {
            pub fn ether_type(&self) -> EtherType {
                match self {
                    Ext::Macsec => EtherType::MACSEC,
                    Ext::VlanTaggedFrame => EtherType::VLAN_TAGGED_FRAME,
                    Ext::VlanDoubleTaggedFrame => EtherType::VLAN_DOUBLE_TAGGED_FRAME,
                    Ext::ProviderBridging => EtherType::PROVIDER_BRIDGING,
                }
            }

            pub fn add(&self, base: &TestPacket) -> TestPacket {
                let mut test = base.clone();
                test.set_ether_type(self.ether_type());
                test.link_exts
                    .try_push(match self {
                        Ext::Macsec => LinkExtHeader::Macsec(MacsecHeader {
                            ptype: MacsecPType::Unmodified(EtherType(3)),
                            endstation_id: false,
                            scb: false,
                            an: MacsecAn::ZERO,
                            short_len: MacsecShortLen::ZERO,
                            packet_nr: 0,
                            sci: None,
                        }),
                        Ext::VlanTaggedFrame
                        | Ext::VlanDoubleTaggedFrame
                        | Ext::ProviderBridging => LinkExtHeader::Vlan(SingleVlanHeader {
                            pcp: VlanPcp::ZERO,
                            drop_eligible_indicator: false,
                            vlan_id: VlanId::try_new(1).unwrap(),
                            ether_type: 3.into(),
                        }),
                    })
                    .unwrap();
                test
            }
        }

        let test_macsec_mod = |test: &TestPacket| {
            for ptype in [
                MacsecPType::Modified,
                MacsecPType::Encrypted,
                MacsecPType::EncryptedUnmodified,
            ] {
                let mut test = test.clone();
                if let Some(LinkExtHeader::Macsec(m)) = test.link_exts.last_mut() {
                    m.ptype = ptype;
                }
                if matches!(test.link_exts.last(), Some(LinkExtHeader::Macsec(_))) {
                    from_x_slice_assert_ok(&test);
                }
            }
        };

        let len_errors = |test: &TestPacket| {
            let data = test.to_vec(&[]);
            let req_len = test.link_exts.last().unwrap().header_len();
            for len in 0..req_len {
                let base_len = test.len(&[]) - req_len;

                let (err_req_len, err_layer) = match test.link_exts.last().unwrap() {
                    LinkExtHeader::Vlan(h) => (h.header_len(), Layer::VlanHeader),
                    LinkExtHeader::Macsec(_) => {
                        if len < 6 {
                            (6, Layer::MacsecHeader)
                        } else {
                            (req_len, Layer::MacsecHeader)
                        }
                    }
                };

                let mut len_source = LenSource::Slice;
                for prev_exts in test.link_exts.iter().rev().skip(1) {
                    if let LinkExtHeader::Macsec(m) = prev_exts {
                        if m.short_len != MacsecShortLen::ZERO {
                            len_source = LenSource::MacsecShortLength;
                        }
                    }
                }

                let err = LenError {
                    required_len: err_req_len,
                    len,
                    len_source,
                    layer: err_layer,
                    layer_start_offset: base_len,
                };
                from_slice_assert_err(&test, &data[..base_len + len], SliceError::Len(err.clone()));
            }
        };

        let content_errors = |test: &TestPacket| {
            if let Some(LinkExtHeader::Macsec(last)) = test.link_exts.last() {
                let mut data = test.to_vec(&[]);

                // inject bad version id
                let macsec_offset = data.len() - last.header_len();
                data[macsec_offset] = data[macsec_offset] | 0b1000_0000;

                from_slice_assert_err(
                    &test,
                    &data,
                    SliceError::Macsec(macsec::HeaderError::UnexpectedVersion),
                );
            }
        };

        // extensions
        let extensions = [
            Ext::Macsec,
            Ext::VlanTaggedFrame,
            Ext::VlanDoubleTaggedFrame,
            Ext::ProviderBridging,
        ];

        // none
        from_x_slice_net_variants(base);

        // add up to three layers of extensions
        for ext0 in extensions {
            let test0 = ext0.add(base);
            from_x_slice_net_variants(&test0);
            test_macsec_mod(&test0);
            len_errors(&test0);
            content_errors(&test0);

            for ext1 in extensions {
                let test1 = ext1.add(&test0);
                from_x_slice_net_variants(&test1);
                test_macsec_mod(&test1);
                len_errors(&test1);
                content_errors(&test1);

                for ext2 in extensions {
                    let test2 = ext2.add(&test1);
                    from_x_slice_net_variants(&test2);
                    test_macsec_mod(&test2);
                    len_errors(&test2);
                    content_errors(&test2);

                    // above max supported link ext
                    for ext3 in extensions {
                        let mut test3 = test2.clone();
                        let l = test3.link_exts.last_mut().unwrap();
                        match l {
                            LinkExtHeader::Vlan(s) => {
                                s.ether_type = ext3.ether_type();
                            }
                            LinkExtHeader::Macsec(m) => {
                                m.ptype = MacsecPType::Unmodified(ext3.ether_type());
                            }
                        }
                        from_x_slice_assert_ok(&test3);
                    }
                }
            }
        }
    }

    fn from_x_slice_net_variants(base: &TestPacket) {
        // none
        from_x_slice_transport_variants(base);

        // ipv4
        for fragmented in [false, true] {
            let ipv4 = {
                let mut ipv4 =
                    Ipv4Header::new(0, 1, 2.into(), [3, 4, 5, 6], [7, 8, 9, 10]).unwrap();
                ipv4.more_fragments = fragmented;
                ipv4
            };

            {
                let test = {
                    let mut test = base.clone();
                    test.set_ether_type(ether_type::IPV4);
                    test.net = Some(NetHeaders::Ipv4(ipv4.clone(), Default::default()));
                    test.set_payload_len(0);
                    test
                };

                // ok ipv4
                from_x_slice_transport_variants(&test);

                // ipv4 len error
                {
                    for len in 0..ipv4.header_len() {
                        let mut test = test.clone();
                        let base_len = test.len(&[]) - ipv4.header_len();
                        test.set_payload_len_link_ext(len);

                        let data = test.to_vec(&[]);

                        let err = LenError {
                            required_len: ipv4.header_len(),
                            len,
                            len_source: LenSource::Slice,
                            layer: Layer::Ipv4Header,
                            layer_start_offset: base_len,
                        };
                        from_slice_assert_err(
                            &test,
                            &data[..base_len + len],
                            if test.link.is_some() || !test.link_exts.is_empty() {
                                SliceError::Len(err.clone())
                            } else {
                                SliceError::Len({
                                    if len < 1 {
                                        let mut err = err.clone();
                                        err.required_len = 1;
                                        err.layer = Layer::IpHeader;
                                        err
                                    } else {
                                        err.clone()
                                    }
                                })
                            },
                        );
                    }
                }

                // ipv4 content error (ihl length too small)
                {
                    use err::ip::HeaderError::*;

                    let mut data = test.to_vec(&[]);
                    let ipv4_offset = data.len() - ipv4.header_len();

                    // set the ihl to 0 to trigger a content error
                    data[ipv4_offset] = 0b1111_0000 & data[ipv4_offset];

                    from_slice_assert_err(
                        &test,
                        &data,
                        if test.link.is_some() || !test.link_exts.is_empty() {
                            SliceError::Ipv4(
                                err::ipv4::HeaderError::HeaderLengthSmallerThanHeader { ihl: 0 },
                            )
                        } else {
                            SliceError::Ip(Ipv4HeaderLengthSmallerThanHeader { ihl: 0 })
                        },
                    );
                }

                // ipv4 content error (total length too small)
                {
                    let mut data = test.to_vec(&[]);
                    let ipv4_offset = data.len() - ipv4.header_len();

                    // set the total length to 0 to trigger a content error
                    data[ipv4_offset + 2] = 0;
                    data[ipv4_offset + 3] = 0;

                    let err = LenError {
                        required_len: ipv4.header_len(),
                        len: 0,
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        layer: Layer::Ipv4Packet,
                        layer_start_offset: {
                            test.link.as_ref().map(|h| h.header_len()).unwrap_or(0)
                                + test
                                    .link_exts
                                    .as_ref()
                                    .iter()
                                    .map(|h| h.header_len())
                                    .sum::<usize>()
                        },
                    };

                    from_slice_assert_err(&test, &data, SliceError::Len(err.clone()));
                }
            }

            // ipv4 extension content error
            {
                let auth = IpAuthHeader::new(0.into(), 1, 2, &[]).unwrap();

                let mut test = base.clone();
                test.set_ether_type(ether_type::IPV4);
                test.net = Some(NetHeaders::Ipv4(
                    {
                        let mut ipv4 = ipv4.clone();
                        ipv4.protocol = ip_number::AUTH;
                        ipv4
                    },
                    Ipv4Extensions {
                        auth: Some(auth.clone()),
                    },
                ));
                test.set_payload_len(0);

                // ok ipv4 & extension
                from_x_slice_transport_variants(&test);

                // ipv4 extension len error
                for len in 0..auth.header_len() {
                    // set payload length
                    let mut test = test.clone();
                    test.set_payload_len_link_ext(
                        test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len
                            - auth.header_len(),
                    );
                    test.set_payload_len_ip(-1 * (auth.header_len() as isize) + (len as isize));

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        layer: Layer::IpAuthHeader,
                        layer_start_offset: base_len,
                    };

                    from_slice_assert_err(
                        &test,
                        &data[..base_len + len],
                        SliceError::Len(err.clone()),
                    );
                }

                // ipv4 extension content error
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();

                    // set the icv len too smaller then allowed
                    data[auth_offset + 1] = 0;

                    // expect an error
                    let err = err::ip_auth::HeaderError::ZeroPayloadLen;
                    from_slice_assert_err(&test, &data, SliceError::Ipv4Exts(err.clone()));
                }
            }
        }

        // ipv6
        {
            let ipv6 = Ipv6Header {
                traffic_class: 0,
                flow_label: 1.try_into().unwrap(),
                payload_length: 2,
                next_header: 3.into(),
                hop_limit: 4,
                source: [0; 16],
                destination: [0; 16],
            };

            // ipv6 header only
            {
                let test = {
                    let mut test = base.clone();
                    test.set_ether_type(ether_type::IPV6);
                    test.net = Some(NetHeaders::Ipv6(ipv6.clone(), Default::default()));
                    test.set_payload_len(0);
                    test
                };

                // ok ipv6
                from_x_slice_transport_variants(&test);

                // header len ipv6
                for len in 0..ipv6.header_len() {
                    let base_len = test.len(&[]) - ipv6.header_len();

                    let mut test = test.clone();
                    test.set_payload_len_link_ext(len);

                    let data = test.to_vec(&[]);
                    let err = err::LenError {
                        required_len: ipv6.header_len(),
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::Ipv6Header,
                        layer_start_offset: base_len,
                    };

                    from_slice_assert_err(
                        &test,
                        &data[..base_len + len],
                        if test.link.is_some() || !test.link_exts.is_empty() {
                            SliceError::Len(err.clone())
                        } else {
                            SliceError::Len({
                                if len < 1 {
                                    let mut err = err.clone();
                                    err.required_len = 1;
                                    err.layer = Layer::IpHeader;
                                    err
                                } else {
                                    err.clone()
                                }
                            })
                        },
                    );
                }

                // content error ipv6
                {
                    use err::ip::HeaderError::*;

                    let mut data = test.to_vec(&[]);

                    // inject an invalid ip version
                    let base_len = data.len() - ipv6.header_len();
                    data[base_len] = data[base_len] & 0b0000_1111;

                    from_slice_assert_err(
                        &test,
                        &data,
                        if test.link.is_some() || !test.link_exts.is_empty() {
                            SliceError::Ipv6(err::ipv6::HeaderError::UnexpectedVersion {
                                version_number: 0,
                            })
                        } else {
                            SliceError::Ip(UnsupportedIpVersion { version_number: 0 })
                        },
                    );
                }
            }

            // ipv6 + extension
            for fragment in [false, true] {
                let auth = IpAuthHeader::new(ip_number::GGP, 1, 2, &[]).unwrap();
                let frag = Ipv6FragmentHeader {
                    next_header: ip_number::AUTH,
                    fragment_offset: 0.try_into().unwrap(),
                    more_fragments: fragment,
                    identification: 3,
                };

                let mut test = base.clone();
                test.set_ether_type(ether_type::IPV6);
                test.net = Some(NetHeaders::Ipv6(
                    {
                        let mut ipv6 = ipv6.clone();
                        ipv6.next_header = ip_number::IPV6_FRAG;
                        ipv6
                    },
                    {
                        let mut exts: Ipv6Extensions = Default::default();
                        exts.fragment = Some(frag.clone());
                        exts.auth = Some(auth.clone());
                        exts
                    },
                ));
                test.set_payload_len(0);

                // ok ipv6 & extensions
                from_x_slice_transport_variants(&test);

                // ipv6 extension len error
                for len in 0..auth.header_len() {
                    // set payload length
                    let mut test = test.clone();
                    test.set_payload_len_link_ext(
                        test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len
                            - auth.header_len(),
                    );
                    test.set_payload_len_ip(-1 * (auth.header_len() as isize) + (len as isize));

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        layer: Layer::IpAuthHeader,
                        layer_start_offset: base_len,
                    };
                    from_slice_assert_err(
                        &test,
                        &data[..base_len + len],
                        SliceError::Len(err.clone()),
                    );
                }

                // ipv6 extension content error (auth)
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();
                    // set the icv len too smaller then allowed
                    data[auth_offset + 1] = 0;

                    let err = err::ip_auth::HeaderError::ZeroPayloadLen;
                    from_slice_assert_err(
                        &test,
                        &data,
                        SliceError::Ipv6Exts(err::ipv6_exts::HeaderError::IpAuth(err.clone())),
                    );
                }

                // ipv6 extension content error (hop by hop not at start)
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();

                    // set the next header to be a hop-by-hop header to trigger a "not at start error"
                    data[auth_offset] = 0;

                    from_slice_assert_err(
                        &test,
                        &data,
                        SliceError::Ipv6Exts(err::ipv6_exts::HeaderError::HopByHopNotAtStart),
                    );
                }
            }
        }
    }

    fn from_x_slice_transport_variants(base: &TestPacket) {
        // none
        from_x_slice_assert_ok(base);

        // transport can only be set if ip is present
        if let Some(ip) = &base.net {
            // udp
            {
                let udp = UdpHeader {
                    source_port: 1,
                    destination_port: 2,
                    length: 3,
                    checksum: 4,
                };
                let mut test = base.clone();
                test.net = Some({
                    let mut ip = match ip {
                        NetHeaders::Ipv4(h, e) => IpHeaders::Ipv4(h.clone(), e.clone()),
                        NetHeaders::Ipv6(h, e) => IpHeaders::Ipv6(h.clone(), e.clone()),
                        NetHeaders::Arp(_) => unreachable!(),
                    };
                    ip.set_next_headers(ip_number::UDP);
                    ip.into()
                });
                test.transport = Some(TransportHeader::Udp(udp.clone()));
                test.set_payload_len(0);

                // ok decode
                from_x_slice_assert_ok(&test);

                // length error
                if false == test.is_ip_payload_fragmented() {
                    for len in 0..udp.header_len() {
                        // build new test packet
                        let mut test = test.clone();

                        // set payload length
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            len + test.net.as_ref().map(|v| v.header_len()).unwrap_or(0),
                        );

                        // generate data
                        let data = test.to_vec(&[]);

                        let base_len = test.len(&[]) - udp.header_len();
                        let err = LenError {
                            required_len: udp.header_len(),
                            len,
                            len_source: match test.net.as_ref().unwrap() {
                                NetHeaders::Ipv4(_, _) => LenSource::Ipv4HeaderTotalLen,
                                NetHeaders::Ipv6(_, _) => LenSource::Ipv6HeaderPayloadLen,
                                NetHeaders::Arp(_) => unreachable!(),
                            },
                            layer: Layer::UdpHeader,
                            layer_start_offset: base_len,
                        };
                        from_slice_assert_err(
                            &test,
                            &data[..base_len + len],
                            SliceError::Len(err.clone()),
                        );
                    }
                }
            }

            // tcp
            {
                let tcp = TcpHeader::new(1, 2, 3, 4);
                let mut test = base.clone();
                test.net = Some({
                    let mut ip = match ip {
                        NetHeaders::Ipv4(h, e) => IpHeaders::Ipv4(h.clone(), e.clone()),
                        NetHeaders::Ipv6(h, e) => IpHeaders::Ipv6(h.clone(), e.clone()),
                        NetHeaders::Arp(_) => unreachable!(),
                    };
                    ip.set_next_headers(ip_number::TCP);
                    ip.into()
                });
                test.transport = Some(TransportHeader::Tcp(tcp.clone()));
                test.set_payload_len(0);

                // ok decode
                from_x_slice_assert_ok(&test);

                // error can only occur if ip does not fragment the packet
                if false == test.is_ip_payload_fragmented() {
                    // length error
                    {
                        for len in 0..(tcp.header_len() as usize) {
                            // set payload length
                            let mut test = test.clone();
                            test.set_payload_len_ip(len as isize);
                            test.set_payload_len_link_ext(
                                len + test.net.as_ref().map(|v| v.header_len()).unwrap_or(0),
                            );

                            let data = test.to_vec(&[]);
                            let base_len = test.len(&[]) - (tcp.header_len() as usize);

                            let err = LenError {
                                required_len: tcp.header_len() as usize,
                                len,
                                len_source: match test.net.as_ref().unwrap() {
                                    NetHeaders::Ipv4(_, _) => LenSource::Ipv4HeaderTotalLen,
                                    NetHeaders::Ipv6(_, _) => LenSource::Ipv6HeaderPayloadLen,
                                    NetHeaders::Arp(_) => unreachable!(),
                                },
                                layer: Layer::TcpHeader,
                                layer_start_offset: base_len,
                            };
                            from_slice_assert_err(
                                &test,
                                &data[..base_len + len],
                                SliceError::Len(err.clone()),
                            );
                        }
                    }

                    // content error
                    {
                        let mut data = test.to_vec(&[]);
                        let base_len = test.len(&[]) - (tcp.header_len() as usize);

                        // set data offset to 0 to trigger an error
                        data[base_len + 12] = data[base_len + 12] & 0b0000_1111;

                        let err = err::tcp::HeaderError::DataOffsetTooSmall { data_offset: 0 };
                        from_slice_assert_err(&test, &data, SliceError::Tcp(err.clone()));
                    }
                }
            }

            // icmpv4
            {
                let icmpv4 =
                    Icmpv4Header::new(Icmpv4Type::EchoReply(IcmpEchoHeader { id: 1, seq: 2 }));
                let mut test = base.clone();
                test.net = Some({
                    let mut ip = match ip {
                        NetHeaders::Ipv4(h, e) => IpHeaders::Ipv4(h.clone(), e.clone()),
                        NetHeaders::Ipv6(h, e) => IpHeaders::Ipv6(h.clone(), e.clone()),
                        NetHeaders::Arp(_) => unreachable!(),
                    };
                    ip.set_next_headers(ip_number::ICMP);
                    ip.into()
                });
                test.transport = Some(TransportHeader::Icmpv4(icmpv4.clone()));
                test.set_payload_len(0);

                // ok decode
                from_x_slice_assert_ok(&test);

                // length error
                if false == test.is_ip_payload_fragmented() {
                    for len in 0..icmpv4.header_len() {
                        // set payload length
                        let mut test = test.clone();
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            len + test.net.as_ref().map(|v| v.header_len()).unwrap_or(0),
                        );

                        let data = test.to_vec(&[]);
                        let base_len = test.len(&[]) - icmpv4.header_len();

                        let err = LenError {
                            required_len: icmpv4.header_len(),
                            len,
                            len_source: match test.net.as_ref().unwrap() {
                                NetHeaders::Ipv4(_, _) => LenSource::Ipv4HeaderTotalLen,
                                NetHeaders::Ipv6(_, _) => LenSource::Ipv6HeaderPayloadLen,
                                NetHeaders::Arp(_) => unreachable!(),
                            },
                            layer: Layer::Icmpv4,
                            layer_start_offset: base_len,
                        };
                        from_slice_assert_err(
                            &test,
                            &data[..base_len + len],
                            SliceError::Len(err.clone()),
                        );
                    }
                }
            }

            // icmpv6
            {
                let icmpv6 =
                    Icmpv6Header::new(Icmpv6Type::EchoReply(IcmpEchoHeader { id: 1, seq: 2 }));
                let mut test = base.clone();
                test.net = Some({
                    let mut ip = match ip {
                        NetHeaders::Ipv4(h, e) => IpHeaders::Ipv4(h.clone(), e.clone()),
                        NetHeaders::Ipv6(h, e) => IpHeaders::Ipv6(h.clone(), e.clone()),
                        NetHeaders::Arp(_) => unreachable!(),
                    };
                    ip.set_next_headers(ip_number::IPV6_ICMP);
                    ip.into()
                });
                test.transport = Some(TransportHeader::Icmpv6(icmpv6.clone()));
                test.set_payload_len(0);

                // ok decode
                from_x_slice_assert_ok(&test);

                // length error
                if false == test.is_ip_payload_fragmented() {
                    for len in 0..icmpv6.header_len() {
                        // set payload length
                        let mut test = test.clone();
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            len + test.net.as_ref().map(|v| v.header_len()).unwrap_or(0),
                        );

                        let data = test.to_vec(&[]);
                        let base_len = test.len(&[]) - icmpv6.header_len();

                        let err = LenError {
                            required_len: icmpv6.header_len(),
                            len,
                            len_source: match test.net.as_ref().unwrap() {
                                NetHeaders::Ipv4(_, _) => LenSource::Ipv4HeaderTotalLen,
                                NetHeaders::Ipv6(_, _) => LenSource::Ipv6HeaderPayloadLen,
                                NetHeaders::Arp(_) => unreachable!(),
                            },
                            layer: Layer::Icmpv6,
                            layer_start_offset: base_len,
                        };
                        from_slice_assert_err(
                            &test,
                            &data[..base_len + len],
                            SliceError::Len(err.clone()),
                        );
                    }
                }
            }
        }
    }

    fn from_x_slice_assert_ok(test_base: &TestPacket) {
        fn assert_test_result(test: &TestPacket, expected_payload: &[u8], result: &SlicedPacket) {
            // check if fragmenting
            let is_fragmented = test.is_ip_payload_fragmented();

            // check headers
            assert_eq!(
                test.link,
                match result.link.as_ref() {
                    Some(s) => match s {
                        LinkSlice::Ethernet2(e) => Some(LinkHeader::Ethernet2(e.to_header())),
                        LinkSlice::LinuxSll(e) => Some(LinkHeader::LinuxSll(e.to_header())),
                        LinkSlice::EtherPayload(_) => None,
                        LinkSlice::LinuxSllPayload(_) => None,
                    },
                    None => None,
                }
            );
            assert_eq!(
                test.link_exts,
                result
                    .link_exts
                    .as_ref()
                    .iter()
                    .map(|e| e.to_header())
                    .collect::<ArrayVec<LinkExtHeader, 3>>()
            );
            assert_eq!(
                test.net,
                result.net.as_ref().map(|s: &NetSlice| -> NetHeaders {
                    match s {
                        NetSlice::Ipv4(ipv4) => NetHeaders::Ipv4(
                            ipv4.header().to_header(),
                            ipv4.extensions().to_header(),
                        ),
                        NetSlice::Ipv6(ipv6) => NetHeaders::Ipv6(
                            ipv6.header().to_header(),
                            Ipv6Extensions::from_slice(
                                ipv6.header().next_header(),
                                ipv6.extensions().slice(),
                            )
                            .unwrap()
                            .0,
                        ),
                        NetSlice::Arp(arp) => NetHeaders::Arp(arp.to_packet()),
                    }
                })
            );

            // check transport header & payload
            if is_fragmented {
                assert_eq!(result.transport, None);
            } else {
                use TransportHeader as H;
                use TransportSlice as S;
                match &result.transport {
                    Some(S::Icmpv4(icmpv4)) => {
                        assert_eq!(&test.transport, &Some(H::Icmpv4(icmpv4.header())));
                        assert_eq!(icmpv4.payload(), expected_payload);
                    }
                    Some(S::Icmpv6(icmpv6)) => {
                        assert_eq!(&test.transport, &Some(H::Icmpv6(icmpv6.header())));
                        assert_eq!(icmpv6.payload(), expected_payload);
                    }
                    Some(S::Udp(s)) => {
                        assert_eq!(&test.transport, &Some(H::Udp(s.to_header())));
                    }
                    Some(S::Tcp(s)) => {
                        assert_eq!(&test.transport, &Some(H::Tcp(s.to_header())));
                    }
                    None => {
                        assert_eq!(&test.transport, &None);
                    }
                }
            }
        }

        // setup payload
        let payload = [1, 2, 3, 4];

        // set length fields in ip headers
        let test = {
            let mut test = test_base.clone();
            test.set_payload_len(payload.len());
            test
        };

        // write data
        let data = test.to_vec(&payload);

        // from_ethernet
        if test.link.is_some() {
            let result = SlicedPacket::from_ethernet(&data).unwrap();
            assert_test_result(&test, &payload, &result);
        }
        // from_ether_type (vlan at start)
        if test.link.is_none() && !test.link_exts.is_empty() {
            let ether_types: &[EtherType] = match test.link_exts.first().unwrap() {
                LinkExtHeader::Vlan(_) => &VLAN_ETHER_TYPES,
                LinkExtHeader::Macsec(_) => &MACSEC_ETHER_TYPES,
            };
            for ether_type in ether_types {
                let result = SlicedPacket::from_ether_type(*ether_type, &data).unwrap();
                assert_eq!(
                    result.link,
                    Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                        ether_type: *ether_type,
                        len_source: LenSource::Slice,
                        payload: &data
                    }))
                );
                assert_test_result(&test, &payload, &result);
            }
        }
        // from_ether_type (ip at start)
        if test.link.is_none() && test.link_exts.is_empty() {
            if let Some(ip) = &test.net {
                let ether_type = match ip {
                    NetHeaders::Ipv4(_, _) => ether_type::IPV4,
                    NetHeaders::Ipv6(_, _) => ether_type::IPV6,
                    NetHeaders::Arp(_) => ether_type::ARP,
                };
                let result = SlicedPacket::from_ether_type(ether_type, &data).unwrap();
                assert_eq!(
                    result.link,
                    Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                        ether_type,
                        len_source: LenSource::Slice,
                        payload: &data
                    }))
                );
                assert_test_result(&test, &payload, &result);
            }
        }
        // from_ip_slice
        if test.link.is_none() && test.link_exts.is_empty() && test.net.is_some() {
            let result = SlicedPacket::from_ip(&data).unwrap();
            assert_test_result(&test, &payload, &result);
        }
    }

    /// Check that the given errors get triggered if presented with the given
    /// data.
    fn from_slice_assert_err(test: &TestPacket, data: &[u8], err: SliceError) {
        // from_ethernet_slice
        if let Some(ref header) = test.link {
            match header {
                LinkHeader::Ethernet2(_) => {
                    assert_eq!(err.clone(), SlicedPacket::from_ethernet(&data).unwrap_err())
                }
                LinkHeader::LinuxSll(_) => assert_eq!(
                    err.clone(),
                    SlicedPacket::from_linux_sll(&data).unwrap_err()
                ),
            }
        }
        // from_ether_type (vlan at start)
        if test.link.is_none() && !test.link_exts.is_empty() {
            let ether_types: &[EtherType] = match test.link_exts.first().unwrap() {
                LinkExtHeader::Vlan(_) => &VLAN_ETHER_TYPES,
                LinkExtHeader::Macsec(_) => &MACSEC_ETHER_TYPES,
            };
            for ether_type in ether_types {
                assert_eq!(
                    err.clone(),
                    SlicedPacket::from_ether_type(*ether_type, &data).unwrap_err()
                );
            }
        }
        // from_ether_type (ip at start)
        if test.link.is_none() && test.link_exts.is_empty() {
            if let Some(ip) = &test.net {
                let err = SlicedPacket::from_ether_type(
                    match ip {
                        NetHeaders::Ipv4(_, _) => ether_type::IPV4,
                        NetHeaders::Ipv6(_, _) => ether_type::IPV6,
                        NetHeaders::Arp(_) => ether_type::ARP,
                    },
                    &data,
                )
                .unwrap_err();
                assert_eq!(err, err.clone());
            }
        }
        // from_ip_slice
        if test.link.is_none() && test.link_exts.is_empty() && test.net.is_some() {
            assert_eq!(err, SlicedPacket::from_ip(&data).unwrap_err());
        }
    }

    proptest! {
        #[test]
        fn payload_ether_type(
            ref eth in ethernet_2_unknown(),
            ether_type in ether_type_unknown(),
            ref linux_sll in linux_sll_any(),
            ref vlan_outer in vlan_single_unknown(),
            ref vlan_inner in vlan_single_unknown(),
            ref macsec in macsec_any(),
            ref ipv4 in ipv4_unknown(),
            ref udp in udp_any(),
        ) {
            use IpHeaders::*;
            use alloc::vec::Vec;

            // empty
            {
                let s = SlicedPacket{
                    link: None,
                    link_exts: ArrayVec::new_const(),
                    net: None,
                    transport: None,
                };
                assert_eq!(None, s.payload_ether_type());
            }

            // only linux sll
            {
                let test = [
                    (None, ArpHardwareId::FRAD, LinuxSllProtocolType::Ignored(0)),
                    (None, ArpHardwareId::NETLINK, LinuxSllProtocolType::NetlinkProtocolType(0)),
                    (None, ArpHardwareId::IPGRE, LinuxSllProtocolType::GenericRoutingEncapsulationProtocolType(0)),
                    (Some(ether_type::WAKE_ON_LAN), ArpHardwareId::ETHERNET, LinuxSllProtocolType::EtherType(ether_type::WAKE_ON_LAN)),
                    (None, ArpHardwareId::ETHERNET, LinuxSllProtocolType::LinuxNonstandardEtherType(LinuxNonstandardEtherType::CAN)),
                ];

                for (expected, arp_hrd_type, protocol_type) in test {
                    {
                        let mut l = linux_sll.clone();
                        l.arp_hrd_type = arp_hrd_type;
                        l.protocol_type = protocol_type;

                        let mut bytes = Vec::with_capacity(linux_sll.header_len());
                        l.write(&mut bytes).unwrap();

                        let s = SlicedPacket::from_linux_sll(&bytes).unwrap();
                        assert_eq!(
                            expected,
                            s.payload_ether_type()
                        );
                    }
                    {
                        let s = SlicedPacket{
                            link: Some(LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice{
                                protocol_type: protocol_type,
                                payload: &[]
                            })),
                            link_exts: Default::default(),
                            net: None,
                            transport: None,
                        };
                        assert_eq!(
                            expected,
                            s.payload_ether_type()
                        );
                    }
                }
            }

            // only ethernet
            {
                let mut serialized = Vec::with_capacity(eth.header_len());
                eth.write(&mut serialized).unwrap();
                assert_eq!(
                    Some(eth.ether_type),
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .payload_ether_type()
                );
            }

            // only ethernet payload
            {
                let s = SlicedPacket {
                    link: Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                        ether_type,
                        len_source: LenSource::Slice,
                        payload: &[],
                    })),
                    link_exts: Default::default(),
                    net: None,
                    transport: None,
                };
                assert_eq!(
                    Some(ether_type),
                    s.payload_ether_type()
                );
            }

            // with single vlan
            {
                let mut eth_mod = eth.clone();
                eth_mod.ether_type = ether_type::VLAN_TAGGED_FRAME;

                let mut serialized = Vec::with_capacity(
                    eth_mod.header_len() +
                    vlan_outer.header_len()
                );
                eth_mod.write(&mut serialized).unwrap();
                vlan_outer.write(&mut serialized).unwrap();
                assert_eq!(
                    Some(vlan_outer.ether_type),
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .payload_ether_type()
                );
            }

            // with double vlan
            {
                let mut eth_mod = eth.clone();
                eth_mod.ether_type = ether_type::VLAN_TAGGED_FRAME;

                let mut vlan_outer_mod = vlan_outer.clone();
                vlan_outer_mod.ether_type = ether_type::VLAN_TAGGED_FRAME;

                let mut serialized = Vec::with_capacity(
                    eth_mod.header_len() +
                    vlan_outer_mod.header_len() +
                    vlan_inner.header_len()
                );
                eth_mod.write(&mut serialized).unwrap();
                vlan_outer_mod.write(&mut serialized).unwrap();
                vlan_inner.write(&mut serialized).unwrap();
                assert_eq!(
                    Some(vlan_inner.ether_type),
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .payload_ether_type()
                );
            }

            // macsec
            {
                let tests = [
                    (Some(ether_type), MacsecPType::Unmodified(ether_type)),
                    (None, MacsecPType::Modified),
                    (None, MacsecPType::Encrypted),
                    (None, MacsecPType::EncryptedUnmodified),
                ];
                for (expected, ptype) in tests {
                    let mut eth_mod = eth.clone();
                    eth_mod.ether_type = ether_type::MACSEC;

                    let mut serialized = Vec::with_capacity(
                        eth_mod.header_len() +
                        macsec.header_len()
                    );
                    eth_mod.write(&mut serialized).unwrap();
                    let mut macsec = macsec.clone();
                    macsec.ptype = ptype;
                    macsec.set_payload_len(0);
                    macsec.write(&mut serialized).unwrap();
                    assert_eq!(
                        expected,
                        SlicedPacket::from_ethernet(&serialized)
                            .unwrap()
                            .payload_ether_type()
                    );
                }
            }

            // with ip
            {
                let builder = PacketBuilder::ethernet2(eth.source, eth.destination)
                    .ip(Ipv4(ipv4.clone(), Default::default()));

                let mut serialized = Vec::with_capacity(builder.size(0));
                builder.write(&mut serialized, ipv4.protocol, &[]).unwrap();

                assert_eq!(
                    None,
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .payload_ether_type()
                );
            }

            // with transport
            {
                let builder = PacketBuilder::ethernet2(eth.source, eth.destination)
                    .ip(Ipv4(ipv4.clone(), Default::default()))
                    .udp(udp.source_port, udp.destination_port);
                let mut serialized = Vec::with_capacity(builder.size(0));
                builder.write(&mut serialized, &[]).unwrap();

                assert_eq!(
                    None,
                    SlicedPacket::from_ethernet(&serialized)
                        .unwrap()
                        .payload_ether_type()
                );
            }
        }
    }
}
