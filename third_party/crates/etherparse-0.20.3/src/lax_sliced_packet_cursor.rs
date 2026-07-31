use crate::{
    err::{packet::SliceError, Layer},
    *,
};
use arrayvec::ArrayVec;

/// Helper class for laxly slicing packets.
pub(crate) struct LaxSlicedPacketCursor<'a> {
    pub offset: usize,
    pub len_source: LenSource,
    pub result: LaxSlicedPacket<'a>,
}

impl<'a> LaxSlicedPacketCursor<'a> {
    pub fn parse_from_ethernet2(slice: &'a [u8]) -> Result<LaxSlicedPacket<'a>, err::LenError> {
        use LinkSlice::*;

        let mut cursor = LaxSlicedPacketCursor {
            offset: 0,
            len_source: LenSource::Slice,
            result: LaxSlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
                stop_err: None,
            },
        };

        let result = Ethernet2Slice::from_slice_without_fcs(slice)?;

        // cache the ether_type for later
        let payload = result.payload();

        // set the new data
        cursor.offset += result.header_len();
        cursor.result.link = Some(Ethernet2(result));

        // parse the rest
        Ok(cursor.slice_ether_type(payload))
    }

    pub fn parse_from_ether_type(ether_type: EtherType, slice: &'a [u8]) -> LaxSlicedPacket<'a> {
        let cursor = LaxSlicedPacketCursor {
            offset: 0,
            len_source: LenSource::Slice,
            result: LaxSlicedPacket {
                link: Some(LinkSlice::EtherPayload(EtherPayloadSlice {
                    ether_type,
                    len_source: LenSource::Slice,
                    payload: slice,
                })),
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
                stop_err: None,
            },
        };
        cursor.slice_ether_type(EtherPayloadSlice {
            ether_type,
            len_source: LenSource::Slice,
            payload: slice,
        })
    }

    pub fn parse_from_ip(
        slice: &'a [u8],
    ) -> Result<LaxSlicedPacket<'a>, err::ip::LaxHeaderSliceError> {
        let (ip, stop_err) = LaxIpSlice::from_slice(slice)?;
        let is_ip_v4 = match &ip {
            LaxIpSlice::Ipv4(_) => true,
            LaxIpSlice::Ipv6(_) => false,
        };
        let payload = ip.payload().clone();
        let offset = (payload.payload.as_ptr() as usize) - (slice.as_ptr() as usize);
        Ok(LaxSlicedPacketCursor {
            offset,
            len_source: LenSource::Slice,
            result: LaxSlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: Some(ip.into()),
                transport: None,
                stop_err: stop_err.map(|(stop_err, stop_layer)| {
                    use err::ipv6_exts::HeaderError as E;
                    use err::ipv6_exts::HeaderSliceError as I;
                    use err::packet::SliceError as O;
                    (
                        match stop_err {
                            I::Len(l) => O::Len(l),
                            I::Content(c) => match c {
                                E::HopByHopNotAtStart => O::Ipv6Exts(E::HopByHopNotAtStart),
                                E::IpAuth(auth) => {
                                    if is_ip_v4 {
                                        O::Ipv4Exts(auth)
                                    } else {
                                        O::Ipv6Exts(E::IpAuth(auth))
                                    }
                                }
                            },
                        },
                        stop_layer,
                    )
                }),
            },
        }
        .slice_transport(payload))
    }

    pub fn slice_ether_type(
        mut self,
        mut ether_payload: EtherPayloadSlice<'a>,
    ) -> LaxSlicedPacket<'a> {
        use ether_type::*;
        loop {
            match ether_payload.ether_type {
                VLAN_TAGGED_FRAME | PROVIDER_BRIDGING | VLAN_DOUBLE_TAGGED_FRAME => {
                    if self.result.link_exts.is_full() {
                        return self.result;
                    }
                    let vlan = match SingleVlanSlice::from_slice(ether_payload.payload) {
                        Ok(v) => v,
                        Err(err) => {
                            self.result.stop_err = Some((
                                SliceError::Len(err.add_offset(self.offset)),
                                Layer::VlanHeader,
                            ));
                            return self.result;
                        }
                    };
                    self.offset += vlan.header_len();
                    let vlan_payload = vlan.payload();
                    ether_payload = EtherPayloadSlice {
                        ether_type: vlan_payload.ether_type,
                        len_source: self.len_source,
                        payload: vlan_payload.payload,
                    };
                    // SAFETY: Safe, as the if at the start verifies that there is still
                    //         space in link_exts.
                    unsafe {
                        self.result
                            .link_exts
                            .push_unchecked(LaxLinkExtSlice::Vlan(vlan));
                    }
                }
                MACSEC => {
                    use err::macsec::HeaderSliceError as I;
                    if self.result.link_exts.is_full() {
                        return self.result;
                    }
                    let macsec = match LaxMacsecSlice::from_slice(ether_payload.payload) {
                        Ok(v) => v,
                        Err(I::Len(err)) => {
                            let layer = err.layer;
                            self.result.stop_err =
                                Some((SliceError::Len(err.add_offset(self.offset)), layer));
                            return self.result;
                        }
                        Err(I::Content(err)) => {
                            self.result.stop_err =
                                Some((SliceError::Macsec(err), Layer::MacsecHeader));
                            return self.result;
                        }
                    };

                    self.offset += macsec.header.header_len();
                    let macsec_payload = macsec.payload.clone();
                    // SAFETY: Safe, as the if at the start verifies that there is still
                    //         space in link_exts.
                    unsafe {
                        self.result
                            .link_exts
                            .push_unchecked(LaxLinkExtSlice::Macsec(macsec));
                    }

                    if let LaxMacsecPayloadSlice::Unmodified(e) = macsec_payload {
                        if e.len_source != LenSource::Slice {
                            self.len_source = e.len_source;
                        }
                        ether_payload = EtherPayloadSlice {
                            payload: e.payload,
                            len_source: self.len_source,
                            ether_type: e.ether_type,
                        };
                    } else {
                        return self.result;
                    }
                }
                ARP => {
                    return self.slice_arp(ether_payload.payload);
                }
                IPV4 => return self.slice_ip(ether_payload.payload),
                IPV6 => {
                    return self.slice_ip(ether_payload.payload);
                }
                _ => {
                    return self.result;
                }
            }
        }
    }

    pub fn slice_arp(mut self, slice: &'a [u8]) -> LaxSlicedPacket<'a> {
        let arp = match ArpPacketSlice::from_slice(slice) {
            Ok(arp) => arp,
            Err(mut e) => {
                e.layer_start_offset += self.offset;
                if LenSource::Slice == e.len_source {
                    e.len_source = self.len_source;
                }
                self.result.stop_err = Some((err::packet::SliceError::Len(e), Layer::Arp));
                return self.result;
            }
        };
        self.result.net = Some(LaxNetSlice::Arp(arp));
        self.result
    }

    pub fn slice_ip(mut self, slice: &'a [u8]) -> LaxSlicedPacket<'a> {
        // ip slice
        let ip = match LaxIpSlice::from_slice(slice) {
            Ok(ip) => ip,
            Err(e) => {
                use err::ip::LaxHeaderSliceError as I;
                use err::packet::SliceError as O;
                self.result.stop_err = Some(match e {
                    I::Len(mut l) => {
                        l.layer_start_offset += self.offset;
                        if LenSource::Slice == l.len_source {
                            l.len_source = self.len_source;
                        }
                        (O::Len(l), Layer::IpHeader)
                    }
                    I::Content(c) => (O::Ip(c), Layer::IpHeader),
                });
                return self.result;
            }
        };
        self.result.net = Some(ip.0.clone().into());

        // stop in case there was a stop error in the ip extension headers
        if let Some((stop_err, stop_layer)) = ip.1 {
            use err::ipv6_exts::HeaderError as E;
            use err::ipv6_exts::HeaderSliceError as I;
            use err::packet::SliceError as O;
            self.result.stop_err = Some((
                match stop_err {
                    I::Len(mut l) => O::Len({
                        l.layer_start_offset += self.offset;
                        if LenSource::Slice == l.len_source {
                            l.len_source = self.len_source;
                        }
                        l
                    }),
                    I::Content(c) => match c {
                        E::HopByHopNotAtStart => O::Ipv6Exts(E::HopByHopNotAtStart),
                        E::IpAuth(auth) => match &ip.0 {
                            LaxIpSlice::Ipv4(_) => O::Ipv4Exts(auth),
                            LaxIpSlice::Ipv6(_) => O::Ipv6Exts(E::IpAuth(auth)),
                        },
                    },
                },
                stop_layer,
            ));
        }

        // move offset for the transport layers
        let payload = ip.0.payload().clone();
        self.offset += (payload.payload.as_ptr() as usize) - (slice.as_ptr() as usize);
        if LenSource::Slice != payload.len_source {
            self.len_source = payload.len_source;
        }
        self.slice_transport(payload)
    }

    fn slice_transport(mut self, slice: LaxIpPayloadSlice<'a>) -> LaxSlicedPacket<'a> {
        use err::packet::SliceError as O;
        if slice.fragmented || self.result.stop_err.is_some() {
            // if an error occurred in an upper layer or the payload is fragmented
            // stop here
            return self.result;
        }
        match slice.ip_number {
            ip_number::ICMP => match Icmpv4Slice::from_slice(slice.payload) {
                Ok(icmp) => {
                    self.offset += icmp.slice().len();
                    self.result.transport = Some(TransportSlice::Icmpv4(icmp));
                }
                Err(mut err) => {
                    err.layer_start_offset += self.offset;
                    if LenSource::Slice == err.len_source {
                        err.len_source = slice.len_source;
                    }
                    self.result.stop_err = Some((O::Len(err), Layer::Icmpv4));
                }
            },
            ip_number::UDP => match UdpSlice::from_slice_lax(slice.payload) {
                Ok(udp) => {
                    self.offset += udp.slice().len();
                    self.result.transport = Some(TransportSlice::Udp(udp));
                }
                Err(mut err) => {
                    err.layer_start_offset += self.offset;
                    if LenSource::Slice == err.len_source {
                        err.len_source = slice.len_source;
                    }
                    self.result.stop_err = Some((O::Len(err), Layer::UdpHeader));
                }
            },
            ip_number::TCP => match TcpSlice::from_slice(slice.payload) {
                Ok(tcp) => {
                    self.offset += tcp.slice().len();
                    self.result.transport = Some(TransportSlice::Tcp(tcp));
                }
                Err(err) => {
                    use err::tcp::HeaderSliceError as I;
                    self.result.stop_err = Some((
                        match err {
                            I::Len(mut l) => {
                                l.layer_start_offset += self.offset;
                                if LenSource::Slice == l.len_source {
                                    l.len_source = slice.len_source;
                                }
                                O::Len(l)
                            }
                            I::Content(c) => O::Tcp(c),
                        },
                        Layer::TcpHeader,
                    ));
                }
            },
            ip_number::IPV6_ICMP => match Icmpv6Slice::from_slice(slice.payload) {
                Ok(icmp) => {
                    self.offset += icmp.slice().len();
                    self.result.transport = Some(TransportSlice::Icmpv6(icmp));
                }
                Err(mut err) => {
                    err.layer_start_offset += self.offset;
                    if LenSource::Slice == err.len_source {
                        err.len_source = slice.len_source;
                    }
                    self.result.stop_err = Some((O::Len(err), Layer::Icmpv6));
                }
            },
            _ => {}
        }
        self.result
    }
}
