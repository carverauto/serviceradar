use super::*;
use crate::err::LenError;
use arrayvec::ArrayVec;

/// Decoded packet headers (data link layer and lower).
///
/// You can use
///
/// * [`PacketHeaders::from_ethernet_slice`]
/// * [`PacketHeaders::from_ether_type`]
/// * [`PacketHeaders::from_ip_slice`]
///
/// depending on your starting header to parse the headers in a slice and get this
/// struct as a result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PacketHeaders<'a> {
    /// Ethernet II header if present.
    pub link: Option<LinkHeader>,

    /// Link extension headers (VLAN & MAC Sec headers).
    pub link_exts: ArrayVec<LinkExtHeader, { PacketHeaders::LINK_EXTS_CAP }>,

    /// IPv4 or IPv6 header and IP extension headers if present.
    pub net: Option<NetHeaders>,

    /// TCP or UDP header if present.
    pub transport: Option<TransportHeader>,

    /// Payload of the last parsed layer.
    pub payload: PayloadSlice<'a>,
}

impl<'a> PacketHeaders<'a> {
    /// Maximum supported number of link extensions headers.
    pub const LINK_EXTS_CAP: usize = 3;

    /// Decodes a network packet into different headers from a slice that starts with an Ethernet II header.
    ///
    /// The result is returned as a [`PacketHeaders`] struct.
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
    /// use etherparse::{ether_type, PacketHeaders};
    ///
    /// match PacketHeaders::from_ether_type(ether_type::IPV4, packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// }
    /// ```
    pub fn from_ethernet_slice(
        slice: &'a [u8],
    ) -> Result<PacketHeaders<'a>, err::packet::SliceError> {
        use err::packet::SliceError::Len;

        let (ethernet, rest) = Ethernet2Header::from_slice(slice).map_err(Len)?;
        let mut result = Self::from_ether_type(ethernet.ether_type, rest);

        match &mut result {
            // inject ethernet header into the result
            Ok(result) => result.link = Some(LinkHeader::Ethernet2(ethernet)),
            // add the ethernet header to the overall offset in case there is a length error
            Err(Len(err)) => err.layer_start_offset += Ethernet2Header::LEN,
            _ => {}
        }
        result
    }

    /// Tries to decode a network packet into different headers using the
    /// given `ether_type` number to identify the first header.
    ///
    /// The result is returned as a [`PacketHeaders`] struct. Currently supported
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
    /// use etherparse::{ether_type, PacketHeaders};
    ///
    /// match PacketHeaders::from_ether_type(ether_type::IPV4, packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// }
    /// ```
    pub fn from_ether_type(
        mut ether_type: EtherType,
        slice: &'a [u8],
    ) -> Result<PacketHeaders<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        let mut rest = slice;

        // helper function to add the current offset to length errors
        let add_offset = |mut len_error: LenError, rest: &[u8]| -> LenError {
            len_error.layer_start_offset += unsafe {
                // SAFETY: Safe as rest is a subslice of slice.
                rest.as_ptr().offset_from(slice.as_ptr()) as usize
            };
            len_error
        };

        let mut result = PacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            payload: PayloadSlice::Ether(EtherPayloadSlice {
                ether_type,
                len_source: LenSource::Slice,
                payload: rest,
            }),
        };

        use ether_type::*;
        let mut len_source = LenSource::Slice;
        loop {
            match ether_type {
                VLAN_TAGGED_FRAME | PROVIDER_BRIDGING | VLAN_DOUBLE_TAGGED_FRAME => {
                    if result.link_exts.is_full() {
                        break;
                    }
                    let (vlan, vlan_rest) = match SingleVlanHeader::from_slice(rest) {
                        Ok(v) => v,
                        Err(err) => {
                            return Err(Len(err.add_offset(slice.len() - rest.len())));
                        }
                    };
                    // set the rest & ether_type for the following operations
                    rest = vlan_rest;
                    ether_type = vlan.ether_type;
                    result.payload = PayloadSlice::Ether(EtherPayloadSlice {
                        ether_type,
                        len_source,
                        payload: rest,
                    });
                    // SAFETY: Safe as the while loop condition verifies that there is space left.
                    unsafe {
                        result.link_exts.push_unchecked(LinkExtHeader::Vlan(vlan));
                    }
                }
                MACSEC => {
                    use err::macsec::HeaderSliceError as I;
                    if result.link_exts.is_full() {
                        break;
                    }
                    let macsec = match MacsecSlice::from_slice(rest) {
                        Ok(v) => v,
                        Err(I::Len(err)) => {
                            return Err(Len(err.add_offset(slice.len() - rest.len())));
                        }
                        Err(I::Content(err)) => {
                            return Err(Macsec(err));
                        }
                    };

                    // SAFETY: Safe as the while loop condition verifies that there is space left.
                    unsafe {
                        result
                            .link_exts
                            .push_unchecked(LinkExtHeader::Macsec(macsec.header.to_header()));
                    }

                    use MacsecPayloadSlice::*;
                    match macsec.payload {
                        Unmodified(e) => {
                            rest = e.payload;
                            ether_type = e.ether_type;
                            if e.len_source != LenSource::Slice {
                                len_source = e.len_source;
                            }
                            result.payload = PayloadSlice::Ether(EtherPayloadSlice {
                                ether_type: e.ether_type,
                                len_source,
                                payload: e.payload,
                            });
                        }
                        Modified(m) => {
                            result.payload = PayloadSlice::MacsecMod(m);
                            return Ok(result);
                        }
                    }
                }
                _ => {
                    break;
                }
            }
        }

        // parse ip
        match ether_type {
            IPV4 => {
                // read ipv4 header & extensions and payload slice
                let (ip, ip_payload) = IpHeaders::from_ipv4_slice(rest).map_err(|err| {
                    use err::ipv4::SliceError as I;
                    match err {
                        I::Len(err) => Len(add_offset(err, rest)),
                        I::Header(err) => Ipv4(err),
                        I::Exts(err) => Ipv4Exts(err),
                    }
                })?;

                // set the next
                rest = ip_payload.payload;
                result.net = Some(ip.into());
                result.payload = PayloadSlice::Ip(ip_payload.clone());

                // decode transport layer
                let (transport, payload) = read_transport(ip_payload).map_err(|err| {
                    use err::tcp::HeaderSliceError as I;
                    match err {
                        I::Len(err) => Len(add_offset(err, rest)),
                        I::Content(err) => Tcp(err),
                    }
                })?;

                result.transport = transport;
                result.payload = payload;
            }
            IPV6 => {
                // read ipv6 header & extensions and payload slice
                let (ip, ip_payload) = IpHeaders::from_ipv6_slice(rest).map_err(|err| {
                    use err::ipv6::SliceError as I;
                    match err {
                        I::Len(err) => Len(add_offset(err, rest)),
                        I::Header(err) => Ipv6(err),
                        I::Exts(err) => Ipv6Exts(err),
                    }
                })?;

                //set the ip result & rest
                rest = ip_payload.payload;
                result.net = Some(ip.into());
                result.payload = PayloadSlice::Ip(ip_payload.clone());

                // decode transport layer
                let (transport, payload) = read_transport(ip_payload).map_err(|err| {
                    use err::tcp::HeaderSliceError as I;
                    match err {
                        I::Len(err) => Len(add_offset(err, rest)),
                        I::Content(err) => Tcp(err),
                    }
                })?;

                result.transport = transport;
                result.payload = payload;
            }
            ARP => {
                result.net = Some(NetHeaders::Arp(
                    ArpPacket::from_slice(rest).map_err(|err| Len(add_offset(err, rest)))?,
                ));

                result.payload = PayloadSlice::Empty;
            }
            _ => {}
        };

        Ok(result)
    }

    /// Tries to decode an ip packet and its transport headers.
    ///
    /// Assumes the given slice starts with the first byte of the IP header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// # // build a UDP packet
    /// # let payload = [0u8;18];
    /// # let builder = PacketBuilder::
    /// #    ipv4([192,168,1,1], //source ip
    /// #         [192,168,1,2], //destination ip
    /// #         20)            //time to life
    /// #    .udp(21,    //source port
    /// #        1234); //  destination port
    /// #
    /// # // serialize the packet
    /// # let packet = {
    /// #     let mut packet = Vec::<u8>::with_capacity(
    /// #         builder.size(payload.len())
    /// #     );
    /// #     builder.write(&mut packet, &payload).unwrap();
    /// #     packet
    /// # };
    /// use etherparse::PacketHeaders;
    ///
    /// match PacketHeaders::from_ip_slice(&packet) {
    ///     Err(value) => println!("Err {:?}", value),
    ///     Ok(value) => {
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///     }
    /// }
    /// ```
    pub fn from_ip_slice(slice: &[u8]) -> Result<PacketHeaders<'_>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        // read ip headers
        let (ip_header, ip_payload) = IpHeaders::from_slice(slice).map_err(|err| {
            use err::ip::HeadersSliceError as I;
            match err {
                I::Len(err) => Len(err),
                I::Content(err) => match err {
                    err::ip::HeadersError::Ip(err) => Ip(err),
                    err::ip::HeadersError::Ipv4Ext(err) => Ipv4Exts(err),
                    err::ip::HeadersError::Ipv6Ext(err) => Ipv6Exts(err),
                },
            }
        })?;

        let mut result = PacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: Some(ip_header.into()),
            transport: None,
            payload: PayloadSlice::Ip(ip_payload.clone()),
        };

        // cache rest for offset addition
        let rest = ip_payload.payload;

        // try to parse the transport header (only if data is not fragmented)
        let (transport, payload) = read_transport(ip_payload).map_err(|err| {
            use err::tcp::HeaderSliceError as I;
            match err {
                I::Len(mut err) => {
                    err.layer_start_offset += unsafe {
                        // SAFETY: Safe as rest is a subslice of slice.
                        rest.as_ptr().offset_from(slice.as_ptr()) as usize
                    };
                    Len(err)
                }
                I::Content(err) => Tcp(err),
            }
        })?;

        // update output
        result.transport = transport;
        result.payload = payload;

        Ok(result)
    }

    /// Returns the first two VLAN headers.
    pub fn vlan(&self) -> Option<VlanHeader> {
        let mut result = None;
        for ext in &self.link_exts {
            if let LinkExtHeader::Vlan(s) = ext {
                if let Some(outer) = result {
                    return Some(VlanHeader::Double(DoubleVlanHeader {
                        outer,
                        inner: s.clone(),
                    }));
                } else {
                    result = Some(s.clone());
                }
            }
        }
        result.map(VlanHeader::Single)
    }

    /// Returns the VLAN ids present in this packet.
    pub fn vlan_ids(&self) -> ArrayVec<VlanId, { PacketHeaders::LINK_EXTS_CAP }> {
        let mut result = ArrayVec::<VlanId, { PacketHeaders::LINK_EXTS_CAP }>::new_const();
        for e in &self.link_exts {
            if let LinkExtHeader::Vlan(s) = e {
                // SAFETY: Safe as the vlan ids array has the same size as slice.link_exts.
                unsafe {
                    result.push_unchecked(s.vlan_id);
                }
            }
        }
        result
    }
}

/// helper function to process transport headers
fn read_transport(
    ip_payload: IpPayloadSlice,
) -> Result<(Option<TransportHeader>, PayloadSlice), err::tcp::HeaderSliceError> {
    if ip_payload.fragmented {
        Ok((None, PayloadSlice::Ip(ip_payload)))
    } else {
        // helper function to set the len source in len errors
        let add_len_source = |mut len_error: LenError| -> err::tcp::HeaderSliceError {
            // only change the len source if the lower layer has not set it
            if LenSource::Slice == len_error.len_source {
                len_error.len_source = ip_payload.len_source;
            }
            Len(len_error)
        };
        use crate::ip_number::*;
        use err::tcp::HeaderSliceError::*;
        match ip_payload.ip_number {
            ICMP => Icmpv4Slice::from_slice(ip_payload.payload)
                .map_err(add_len_source)
                .map(|value| {
                    (
                        Some(TransportHeader::Icmpv4(value.header())),
                        PayloadSlice::Icmpv4(value.payload()),
                    )
                }),
            IPV6_ICMP => Icmpv6Slice::from_slice(ip_payload.payload)
                .map_err(add_len_source)
                .map(|value| {
                    (
                        Some(TransportHeader::Icmpv6(value.header())),
                        PayloadSlice::Icmpv6(value.payload()),
                    )
                }),
            UDP => UdpHeader::from_slice(ip_payload.payload)
                .map_err(add_len_source)
                .map(|value| {
                    (
                        Some(TransportHeader::Udp(value.0)),
                        PayloadSlice::Udp(value.1),
                    )
                }),
            TCP => TcpHeader::from_slice(ip_payload.payload)
                .map_err(|err| match err {
                    Len(err) => add_len_source(err),
                    Content(err) => Content(err),
                })
                .map(|value| {
                    (
                        Some(TransportHeader::Tcp(value.0)),
                        PayloadSlice::Tcp(value.1),
                    )
                }),
            _ => Ok((None, PayloadSlice::Ip(ip_payload))),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::err::packet::SliceError;
    use crate::err::Layer;
    use crate::test_packet::TestPacket;

    const VLAN_ETHER_TYPES: [EtherType; 3] = [
        ether_type::VLAN_TAGGED_FRAME,
        ether_type::PROVIDER_BRIDGING,
        ether_type::VLAN_DOUBLE_TAGGED_FRAME,
    ];
    const MACSEC_ETHER_TYPES: [EtherType; 1] = [ether_type::MACSEC];

    #[test]
    fn debug() {
        use alloc::format;
        let header = PacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            payload: PayloadSlice::Ether(EtherPayloadSlice {
                ether_type: EtherType(0),
                len_source: LenSource::Slice,
                payload: &[],
            }),
        };
        assert_eq!(
            &format!("{:?}", header),
            &format!(
                "PacketHeaders {{ link: {:?}, link_exts: {:?}, net: {:?}, transport: {:?}, payload: {:?} }}",
                header.link,
                header.link_exts,
                header.net,
                header.transport,
                header.payload
            )
        );
    }

    #[test]
    fn clone_eq() {
        let header = PacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            payload: PayloadSlice::Ether(EtherPayloadSlice {
                ether_type: EtherType(0),
                len_source: LenSource::Slice,
                payload: &[],
            }),
        };
        assert_eq!(header.clone(), header);
    }

    #[test]
    fn vlan_vlan_ids() {
        // no content
        {
            let headers = PacketHeaders {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
                payload: PayloadSlice::Empty,
            };
            assert_eq!(headers.vlan(), None);
            assert_eq!(headers.vlan_ids(), ArrayVec::<VlanId, 3>::new_const());
        }

        // single vlan header
        {
            let outer = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(1).unwrap(),
                ether_type: EtherType::WAKE_ON_LAN,
            };
            let headers = PacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Vlan(outer.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: PayloadSlice::Empty,
            };

            assert_eq!(headers.vlan(), Some(VlanHeader::Single(outer.clone())));
            assert_eq!(headers.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids
            });
        }

        // two vlan header
        {
            let outer = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(1).unwrap(),
                ether_type: EtherType::VLAN_TAGGED_FRAME,
            };
            let inner = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(2).unwrap(),
                ether_type: EtherType::WAKE_ON_LAN,
            };
            let headers = PacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Vlan(outer.clone()));
                    exts.push(LinkExtHeader::Vlan(inner.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: PayloadSlice::Empty,
            };

            assert_eq!(
                headers.vlan(),
                Some(VlanHeader::Double(DoubleVlanHeader {
                    outer: outer.clone(),
                    inner: inner.clone(),
                }))
            );
            assert_eq!(headers.vlan_ids(), {
                let mut ids = ArrayVec::<VlanId, 3>::new_const();
                ids.push(VlanId::try_new(1).unwrap());
                ids.push(VlanId::try_new(2).unwrap());
                ids
            });
        }

        // three vlan header
        {
            let vlan1 = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(1).unwrap(),
                ether_type: EtherType::VLAN_TAGGED_FRAME,
            };
            let vlan2 = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(2).unwrap(),
                ether_type: EtherType::WAKE_ON_LAN,
            };
            let vlan3 = SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: VlanId::try_new(3).unwrap(),
                ether_type: EtherType::WAKE_ON_LAN,
            };
            let headers = PacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Vlan(vlan1.clone()));
                    exts.push(LinkExtHeader::Vlan(vlan2.clone()));
                    exts.push(LinkExtHeader::Vlan(vlan3.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: PayloadSlice::Empty,
            };

            assert_eq!(
                headers.vlan(),
                Some(VlanHeader::Double(DoubleVlanHeader {
                    outer: vlan1.clone(),
                    inner: vlan2.clone(),
                }))
            );
            assert_eq!(headers.vlan_ids(), {
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
                        layer: err::Layer::Ethernet2Header,
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
                    SliceError::Macsec(err::macsec::HeaderError::UnexpectedVersion),
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
                let mut test = base.clone();
                test.set_ether_type(ether_type::IPV4);
                test.net = Some(NetHeaders::Ipv4(ipv4.clone(), Default::default()));

                // ok ipv4
                from_x_slice_transport_variants(&test);

                // ipv4 len error
                {
                    let data = test.to_vec(&[]);
                    for len in 0..ipv4.header_len() {
                        let base_len = test.len(&[]) - ipv4.header_len();

                        let err = LenError {
                            required_len: ipv4.header_len(),
                            len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv4Header,
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
                                        err.layer = err::Layer::IpHeader;
                                        err
                                    } else {
                                        err.clone()
                                    }
                                })
                            },
                        );
                    }
                }

                // ipv4 content error
                {
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
                            SliceError::Ip(
                                err::ip::HeaderError::Ipv4HeaderLengthSmallerThanHeader { ihl: 0 },
                            )
                        },
                    );
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
                    test.set_payload_len_ip(-1 * (auth.header_len() as isize) + (len as isize));
                    test.set_payload_len_link_ext(
                        test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len
                            - auth.header_len(),
                    );

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        layer: err::Layer::IpAuthHeader,
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
                let mut test = base.clone();
                test.set_ether_type(ether_type::IPV6);
                test.net = Some(NetHeaders::Ipv6(ipv6.clone(), Default::default()));
                test.set_payload_len(0);

                // ok ipv6
                from_x_slice_transport_variants(&test);

                // header len ipv6
                for len in 0..ipv6.header_len() {
                    let mut test = test.clone();
                    test.set_payload_len_link_ext(len);

                    let base_len = test.len(&[]) - ipv6.header_len();
                    let data = test.to_vec(&[]);
                    let err = err::LenError {
                        required_len: ipv6.header_len(),
                        len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Ipv6Header,
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
                                    err.layer = err::Layer::IpHeader;
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
                    test.set_payload_len_ip(-1 * (auth.header_len() as isize) + (len as isize));
                    test.set_payload_len_link_ext(
                        test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len
                            - auth.header_len(),
                    );

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        layer: err::Layer::IpAuthHeader,
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

        // arp
        {
            let arp = ArpPacket::new(
                ArpHardwareId::ETHERNET,
                EtherType::IPV4,
                ArpOperation::REPLY,
                &[0u8; 6],
                &[0u8; 4],
                &[0u8; 6],
                &[0u8; 4],
            )
            .unwrap();

            let mut test = base.clone();
            test.set_ether_type(ether_type::ARP);
            test.net = Some(NetHeaders::Arp(arp.clone()));
            test.set_payload_len(0);

            // ok arp
            from_x_slice_assert_ok(&test);

            // len error
            {
                for len in 0..arp.packet_len() {
                    let mut test = test.clone();
                    test.set_payload_len_link_ext(len);
                    let base_len = test.len(&[]) - arp.packet_len();
                    let data = test.to_vec(&[]);

                    let err = err::LenError {
                        required_len: if len < 8 { 8 } else { arp.packet_len() },
                        len,
                        len_source: if len < 8 {
                            LenSource::Slice
                        } else {
                            LenSource::ArpAddrLengths
                        },
                        layer: Layer::Arp,
                        layer_start_offset: base_len,
                    };

                    from_slice_assert_err(
                        &test,
                        &data[..base_len + len],
                        SliceError::Len({
                            if len < 8 {
                                let mut err = err.clone();
                                err.required_len = 8;
                                err.layer = Layer::Arp;
                                err
                            } else {
                                err.clone()
                            }
                        }),
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
                            test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len,
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
                            layer: err::Layer::UdpHeader,
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
                    for len in 0..(tcp.header_len() as usize) {
                        // set payload length
                        let mut test = test.clone();
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len,
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
                            layer: err::Layer::TcpHeader,
                            layer_start_offset: base_len,
                        };
                        from_slice_assert_err(
                            &test,
                            &data[..base_len + len],
                            SliceError::Len(err.clone()),
                        );
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

                // ok decode
                from_x_slice_assert_ok(&test);

                // length error
                if false == test.is_ip_payload_fragmented() {
                    for len in 0..icmpv4.header_len() {
                        // set payload length
                        let mut test = test.clone();
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len,
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
                            layer: err::Layer::Icmpv4,
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

                // ok decode
                from_x_slice_assert_ok(&test);

                // length error
                if false == test.is_ip_payload_fragmented() {
                    for len in 0..icmpv6.header_len() {
                        // set payload length
                        let mut test = test.clone();
                        test.set_payload_len_ip(len as isize);
                        test.set_payload_len_link_ext(
                            test.net.as_ref().map(|v| v.header_len()).unwrap_or(0) + len,
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
                            layer: err::Layer::Icmpv6,
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
        let payload = [1, 2, 3, 4];

        // set length fields in ip headers
        let test = {
            let mut test = test_base.clone();
            test.set_payload_len(payload.len());
            test
        };

        // check if fragmenting
        let is_fragmented = test.is_ip_payload_fragmented();

        // write data
        let data = test.to_vec(&payload);

        // from_ethernet_slice
        if test.link.is_some() {
            let result = PacketHeaders::from_ethernet_slice(&data).unwrap();
            assert_eq!(result.link, test.link);
            assert_eq!(result.link_exts, test.link_exts);
            assert_eq!(result.net, test.net);
            if is_fragmented {
                assert_eq!(result.transport, None);
            } else {
                assert_eq!(result.transport, test.transport);
                if test.has_arp() {
                    assert_eq!(result.payload.slice(), &[]);
                } else {
                    assert_eq!(result.payload.slice(), &[1, 2, 3, 4]);
                }
            }
        }
        // from_ether_type (vlan at start)
        if test.link.is_none() && !test.link_exts.is_empty() {
            let ether_types: &[EtherType] = match test.link_exts.first().unwrap() {
                LinkExtHeader::Vlan(_) => &VLAN_ETHER_TYPES,
                LinkExtHeader::Macsec(_) => &MACSEC_ETHER_TYPES,
            };
            for ether_type in ether_types {
                let result = PacketHeaders::from_ether_type(*ether_type, &data).unwrap();
                assert_eq!(result.link, test.link);
                assert_eq!(result.link_exts, test.link_exts);
                assert_eq!(result.net, test.net);
                if is_fragmented {
                    assert_eq!(result.transport, None);
                } else {
                    assert_eq!(result.transport, test.transport);
                    if test.has_arp() {
                        assert_eq!(result.payload.slice(), &[]);
                    } else {
                        assert_eq!(result.payload.slice(), &[1, 2, 3, 4]);
                    }
                }
            }
        }
        // from_ether_type (net at start)
        if test.link.is_none() && test.link_exts.is_empty() {
            if let Some(ip) = &test.net {
                let result = PacketHeaders::from_ether_type(
                    match ip {
                        NetHeaders::Ipv4(_, _) => ether_type::IPV4,
                        NetHeaders::Ipv6(_, _) => ether_type::IPV6,
                        NetHeaders::Arp(_) => ether_type::ARP,
                    },
                    &data,
                )
                .unwrap();
                assert_eq!(result.link, test.link);
                assert_eq!(result.link_exts, test.link_exts);
                assert_eq!(result.net, test.net);
                if is_fragmented {
                    assert_eq!(result.transport, None);
                } else {
                    assert_eq!(result.transport, test.transport);
                    if test.has_arp() {
                        assert_eq!(result.payload.slice(), &[]);
                    } else {
                        assert_eq!(result.payload.slice(), &[1, 2, 3, 4]);
                    }
                }
            }
        }
        // from_ip_slice
        if test.link.is_none()
            && test.link_exts.is_empty()
            && test.net.as_ref().map(|v| v.is_ip()).unwrap_or(false)
        {
            let result = PacketHeaders::from_ip_slice(&data).unwrap();
            assert_eq!(result.link, test.link);
            assert_eq!(result.link_exts, test.link_exts);
            assert_eq!(result.net, test.net);
            if is_fragmented {
                assert_eq!(result.transport, None);
            } else {
                assert_eq!(result.transport, test.transport);
                assert_eq!(result.payload.slice(), &[1, 2, 3, 4]);
            }
        }
    }

    /// Check that the given errors get triggered if presented with the given
    /// data.
    fn from_slice_assert_err(test: &TestPacket, data: &[u8], err: SliceError) {
        // from_ethernet_slice
        if test.link.is_some() {
            assert_eq!(
                err.clone(),
                PacketHeaders::from_ethernet_slice(&data).unwrap_err()
            );
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
                    PacketHeaders::from_ether_type(*ether_type, &data).unwrap_err()
                );
            }
        }
        // from_ether_type (ip at start)
        if test.link.is_none() && test.link_exts.is_empty() {
            if let Some(ip) = &test.net {
                let err = PacketHeaders::from_ether_type(
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
        if test.link.is_none()
            && test.link_exts.is_empty()
            && test.net.as_ref().map(|v| v.is_ip()).unwrap_or(false)
        {
            assert_eq!(err, PacketHeaders::from_ip_slice(&data).unwrap_err());
        }
    }
}
