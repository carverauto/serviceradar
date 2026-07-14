use crate::*;
use arrayvec::ArrayVec;

/// Helper class for slicing packets
pub(crate) struct SlicedPacketCursor<'a> {
    pub offset: usize,
    pub len_source: LenSource,
    pub result: SlicedPacket<'a>,
}

impl<'a> SlicedPacketCursor<'a> {
    pub fn new() -> SlicedPacketCursor<'a> {
        SlicedPacketCursor {
            offset: 0,
            len_source: LenSource::Slice,
            result: SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            },
        }
    }

    pub fn slice_ethernet2(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;
        use LinkSlice::*;

        let result = Ethernet2Slice::from_slice_without_fcs(slice)
            .map_err(|err| Len(err.add_offset(self.offset)))?;

        //cache the ether_type for later
        let ether_payload = result.payload();

        //set the new data
        self.offset += result.header_len();
        self.result.link = Some(Ethernet2(result));

        //continue parsing (if required)
        self.slice_ether_type(ether_payload)
    }

    pub fn slice_linux_sll(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        let result = LinuxSllSlice::from_slice(slice).map_err(|err| match err {
            err::linux_sll::HeaderSliceError::Len(len) => Len(len.add_offset(self.offset)),
            err::linux_sll::HeaderSliceError::Content(content) => {
                err::packet::SliceError::LinuxSll(content)
            }
        })?;

        //cache the protocol type for later
        let payload = result.payload();

        //set the new data
        self.offset += result.header_len();
        self.result.link = Some(LinkSlice::LinuxSll(result));

        //continue parsing (if required)
        match payload.protocol_type {
            LinuxSllProtocolType::EtherType(next_ether_type) => {
                self.slice_ether_type(EtherPayloadSlice {
                    ether_type: next_ether_type,
                    len_source: LenSource::Slice,
                    payload: payload.payload,
                })
            }
            _ => Ok(self.result),
        }
    }

    pub fn slice_ether_type(
        mut self,
        mut ether_payload: EtherPayloadSlice<'a>,
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;
        use ether_type::*;

        loop {
            match ether_payload.ether_type {
                VLAN_TAGGED_FRAME | PROVIDER_BRIDGING | VLAN_DOUBLE_TAGGED_FRAME => {
                    if self.result.link_exts.is_full() {
                        return Ok(self.result);
                    }

                    let vlan = SingleVlanSlice::from_slice(ether_payload.payload)
                        .map_err(|err| Len(err.add_offset(self.offset)))?;
                    self.offset += vlan.header_len();
                    let vlan_payload = vlan.payload();
                    // SAFETY: Safe, as the outer if verifies that there is still space in link_exts.
                    unsafe {
                        self.result
                            .link_exts
                            .push_unchecked(LinkExtSlice::Vlan(vlan));
                    }
                    ether_payload = vlan_payload;
                }
                MACSEC => {
                    if self.result.link_exts.is_full() {
                        return Ok(self.result);
                    }

                    let macsec = MacsecSlice::from_slice(ether_payload.payload).map_err(|err| {
                        use err::macsec::HeaderSliceError as I;
                        use err::packet::SliceError as O;
                        match err {
                            I::Len(l) => O::Len(l.add_offset(self.offset)),
                            I::Content(h) => O::Macsec(h),
                        }
                    })?;

                    // set offset & len source
                    self.offset += macsec.header.header_len();
                    if macsec.header.short_len().value() > 0 {
                        self.len_source = LenSource::MacsecShortLength;
                    }

                    let macsec_payload = macsec.payload.clone();

                    // SAFETY: Safe, as the outer if verifies that there is still space in link_exts.
                    unsafe {
                        self.result
                            .link_exts
                            .push_unchecked(LinkExtSlice::Macsec(macsec));
                    }

                    // only continue if the payload is unencrypted
                    if let MacsecPayloadSlice::Unmodified(e) = macsec_payload {
                        ether_payload = e;
                    } else {
                        return Ok(self.result);
                    }
                }
                ARP => return self.slice_arp(ether_payload.payload),
                IPV4 => return self.slice_ipv4(ether_payload.payload),
                IPV6 => return self.slice_ipv6(ether_payload.payload),
                _ => return Ok(self.result),
            }
        }
    }

    pub fn slice_ip(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        // slice header, extension headers and identify payload range
        let ip = IpSlice::from_slice(slice).map_err(|err| {
            use err::ip::SliceError as I;
            match err {
                I::Len(mut err) => {
                    err.layer_start_offset += self.offset;
                    Len(err)
                }
                I::IpHeaders(err) => match err {
                    err::ip::HeadersError::Ip(err) => Ip(err),
                    err::ip::HeadersError::Ipv4Ext(err) => Ipv4Exts(err),
                    err::ip::HeadersError::Ipv6Ext(err) => Ipv6Exts(err),
                },
            }
        })?;

        // safe data needed
        let payload = ip.payload().clone();

        // set the new data
        self.offset += unsafe {
            // SAFETY: The payload is a subslice of self.slice.
            // therefor calculating the offset from it is safe and
            // the result should always be a positive number.
            payload.payload.as_ptr().offset_from(slice.as_ptr()) as usize
        };
        self.len_source = payload.len_source;
        self.result.net = Some(ip.into());

        // continue to the lower layers
        if payload.fragmented {
            Ok(self.result)
        } else {
            match payload.ip_number {
                ip_number::ICMP => self.slice_icmp4(payload.payload).map_err(Len),
                ip_number::UDP => self.slice_udp(payload.payload).map_err(Len),
                ip_number::TCP => self.slice_tcp(payload.payload).map_err(|err| {
                    use err::tcp::HeaderSliceError as I;
                    match err {
                        I::Len(err) => Len(err),
                        I::Content(err) => Tcp(err),
                    }
                }),
                ip_number::IPV6_ICMP => self.slice_icmp6(payload.payload).map_err(Len),
                _ => Ok(self.result),
            }
        }
    }

    pub fn slice_ipv4(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        // slice ipv4 header & extension headers
        let ipv4 = Ipv4Slice::from_slice(slice).map_err(|err| {
            use err::ipv4::SliceError as I;
            match err {
                I::Len(mut err) => {
                    err.layer_start_offset += self.offset;
                    Len(err)
                }
                I::Header(err) => Ipv4(err),
                I::Exts(err) => Ipv4Exts(err),
            }
        })?;

        // safe data needed in following steps
        let payload = ipv4.payload().clone();

        // set the new data
        self.offset += unsafe {
            // SAFETY: The payload is a subslice of self.slice.
            // therefor calculating the offset from it is safe and
            // the result should always be a positive number.
            payload.payload.as_ptr().offset_from(slice.as_ptr()) as usize
        };
        self.len_source = payload.len_source;
        self.result.net = Some(NetSlice::Ipv4(ipv4));

        if payload.fragmented {
            Ok(self.result)
        } else {
            match payload.ip_number {
                ip_number::UDP => self.slice_udp(payload.payload).map_err(Len),
                ip_number::TCP => self.slice_tcp(payload.payload).map_err(|err| {
                    use err::tcp::HeaderSliceError as I;
                    match err {
                        I::Len(err) => Len(err),
                        I::Content(err) => Tcp(err),
                    }
                }),
                ip_number::ICMP => self.slice_icmp4(payload.payload).map_err(Len),
                ip_number::IPV6_ICMP => self.slice_icmp6(payload.payload).map_err(Len),
                _ => Ok(self.result),
            }
        }
    }

    pub fn slice_ipv6(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        use err::packet::SliceError::*;

        let ipv6 = Ipv6Slice::from_slice(slice).map_err(|err| {
            use err::ipv6::SliceError as I;
            match err {
                I::Len(mut err) => {
                    err.layer_start_offset += self.offset;
                    Len(err)
                }
                I::Header(err) => Ipv6(err),
                I::Exts(err) => Ipv6Exts(err),
            }
        })?;

        // safe data needed in following steps
        let payload = ipv6.payload().clone();

        // set the new data
        self.offset += unsafe {
            // SAFETY: The payload is a subslice of self.slice.
            // therefor calculating the offset from it is safe and
            // the result should always be a positive number.
            ipv6.payload().payload.as_ptr().offset_from(slice.as_ptr()) as usize
        };
        self.len_source = ipv6.payload().len_source;
        self.result.net = Some(NetSlice::Ipv6(ipv6));

        // only try to decode the transport layer if the payload
        // is not fragmented
        if payload.fragmented {
            Ok(self.result)
        } else {
            //parse the data bellow
            match payload.ip_number {
                ip_number::ICMP => self.slice_icmp4(payload.payload).map_err(Len),
                ip_number::UDP => self.slice_udp(payload.payload).map_err(Len),
                ip_number::TCP => self.slice_tcp(payload.payload).map_err(|err| {
                    use err::tcp::HeaderSliceError as I;
                    match err {
                        I::Len(err) => Len(err),
                        I::Content(err) => Tcp(err),
                    }
                }),
                ip_number::IPV6_ICMP => self.slice_icmp6(payload.payload).map_err(Len),
                _ => Ok(self.result),
            }
        }
    }

    pub fn slice_arp(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::packet::SliceError> {
        let result = ArpPacketSlice::from_slice(slice).map_err(|mut err| {
            err.layer_start_offset += self.offset;
            err::packet::SliceError::Len(err)
        })?;

        //set the new data
        self.offset += result.slice().len();
        self.result.net = Some(NetSlice::Arp(result.clone()));

        Ok(self.result)
    }

    pub fn slice_icmp4(mut self, slice: &'a [u8]) -> Result<SlicedPacket<'a>, err::LenError> {
        use crate::TransportSlice::*;

        let result = Icmpv4Slice::from_slice(slice).map_err(|mut err| {
            err.layer_start_offset += self.offset;
            if LenSource::Slice == err.len_source {
                err.len_source = self.len_source;
            }
            err
        })?;

        //set the new data
        self.offset += result.slice().len();
        self.result.transport = Some(Icmpv4(result.clone()));

        Ok(self.result)
    }

    pub fn slice_icmp6(mut self, slice: &'a [u8]) -> Result<SlicedPacket<'a>, err::LenError> {
        use crate::TransportSlice::*;

        let result = Icmpv6Slice::from_slice(slice).map_err(|mut err| {
            err.layer_start_offset += self.offset;
            if LenSource::Slice == err.len_source {
                err.len_source = self.len_source;
            }
            err
        })?;

        //set the new data
        self.offset += result.slice().len();
        self.result.transport = Some(Icmpv6(result.clone()));

        //done
        Ok(self.result)
    }

    pub fn slice_udp(mut self, slice: &'a [u8]) -> Result<SlicedPacket<'a>, err::LenError> {
        use crate::TransportSlice::*;

        let result = UdpSlice::from_slice(slice).map_err(|mut err| {
            err.layer_start_offset += self.offset;
            if LenSource::Slice == err.len_source {
                err.len_source = self.len_source;
            }
            err
        })?;

        //set the new data
        self.offset += result.slice().len();
        self.result.transport = Some(Udp(result));

        // done
        Ok(self.result)
    }

    pub fn slice_tcp(
        mut self,
        slice: &'a [u8],
    ) -> Result<SlicedPacket<'a>, err::tcp::HeaderSliceError> {
        use crate::TransportSlice::*;

        let result = TcpSlice::from_slice(slice).map_err(|mut err| {
            use err::tcp::HeaderSliceError::Len;
            if let Len(err) = &mut err {
                err.layer_start_offset += self.offset;
                if LenSource::Slice == err.len_source {
                    err.len_source = self.len_source;
                }
            }
            err
        })?;

        //set the new data
        self.offset += result.slice().len();
        self.result.transport = Some(Tcp(result));

        // done
        Ok(self.result)
    }
}
