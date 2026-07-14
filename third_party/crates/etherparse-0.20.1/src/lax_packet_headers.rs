use crate::{
    err::{packet::SliceError, Layer, LenError},
    *,
};
use arrayvec::ArrayVec;

/// Decoded packet headers (data link layer and lower) with lax length checks.
///
/// You can use
///
/// * [`LaxPacketHeaders::from_ethernet`]
/// * [`LaxPacketHeaders::from_ether_type`]
/// * [`LaxPacketHeaders::from_ip`]
///
/// depending on your starting header to parse the headers in a slice and get this
/// struct as a result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaxPacketHeaders<'a> {
    /// Ethernet II header if present.
    pub link: Option<LinkHeader>,

    /// Link extension headers (VLAN & MAC Sec headers).
    pub link_exts: ArrayVec<LinkExtHeader, { LaxPacketHeaders::LINK_EXTS_CAP }>,

    /// IPv4 or IPv6 header and IP extension headers if present.
    pub net: Option<NetHeaders>,

    /// TCP or UDP header if present.
    pub transport: Option<TransportHeader>,

    /// Payload of the last parsed layer.
    pub payload: LaxPayloadSlice<'a>,

    /// Error that stopped the parsing and the layer on which the stop occurred.
    pub stop_err: Option<(err::packet::SliceError, Layer)>,
}

impl<'a> LaxPacketHeaders<'a> {
    /// Maximum supported number of link extensions headers.
    pub const LINK_EXTS_CAP: usize = 3;

    /// Separates a network packet into different headers from the ethernet header
    /// downwards with lax length checks and non-terminating errors.
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
    /// #         1234); //destination port
    /// # // payload of the udp packet
    /// # let payload = [1,2,3,4,5,6,7,8];
    /// # // get some memory to store the serialized data
    /// # let mut packet = Vec::<u8>::with_capacity(
    /// #     builder.size(payload.len())
    /// # );
    /// # builder.write(&mut packet, &payload).unwrap();
    /// #
    /// use etherparse::{ether_type, LaxPacketHeaders, LenSource, LaxPayloadSlice};
    ///
    /// match LaxPacketHeaders::from_ethernet(&packet) {
    ///     Err(value) => {
    ///         // An error is returned in case the ethernet II header could
    ///         // not be parsed (other errors are stored in the "stop_err" field)
    ///         println!("Err {:?}", value)
    ///     },
    ///     Ok(value) => {
    ///         if let Some((stop_err, error_layer)) = value.stop_err.as_ref() {
    ///             // error was encountered after parsing the ethernet 2 header
    ///             println!("Error on layer {}: {:?}", error_layer, stop_err);
    ///         }
    ///
    ///         // parts that could be parsed without error
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///
    ///         // net (ip) & transport (udp or tcp)
    ///         println!("net: {:?}", value.net);
    ///         match value.payload {
    ///             LaxPayloadSlice::Empty => {
    ///                 // in case of ARP packet the payload is empty
    ///             }
    ///             LaxPayloadSlice::MacsecModified { payload, incomplete } => {
    ///                 println!("MACsec modified payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  MACsec payload incomplete (length in MACsec header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Ether(e) => {
    ///                 println!("ether payload (ether type {:?}): {:?}", e.ether_type, e.payload);
    ///             }
    ///             LaxPayloadSlice::Ip(ip) => {
    ///                 println!("IP payload (IP number {:?}): {:?}", ip.ip_number, ip.payload);
    ///                 if ip.incomplete {
    ///                     println!("  IP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///                 if ip.fragmented {
    ///                     println!("  IP payload fragmented");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Udp{ payload, incomplete } => {
    ///                 println!("UDP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  UDP payload incomplete (length in UDP or IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Tcp{ payload, incomplete } => {
    ///                 println!("TCP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  TCP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv4{ payload, incomplete } => {
    ///                 println!("Icmpv4 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv4 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv6{ payload, incomplete } => {
    ///                 println!("Icmpv6 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv6 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::LinuxSll(linux_sll) => {
    ///                 println!("Linux SLL payload (protocol type {:?}): {:?}", linux_sll.protocol_type, linux_sll.payload);
    ///             }
    ///         }
    ///     }
    /// }
    ///
    /// ```
    pub fn from_ethernet(slice: &'a [u8]) -> Result<LaxPacketHeaders<'a>, err::LenError> {
        let (ethernet, rest) = Ethernet2Header::from_slice(slice)?;
        let mut result = Self::from_ether_type(ethernet.ether_type, rest);
        result.link = Some(LinkHeader::Ethernet2(ethernet));
        if let Some((SliceError::Len(l), _)) = result.stop_err.as_mut() {
            l.layer_start_offset += Ethernet2Header::LEN;
        }
        Ok(result)
    }

    /// Separates a network packet into different headers using
    /// the given `ether_type` number to identify the first header with lax length
    /// checks and non-terminating errors.
    ///
    /// The result is returned as a [`LaxSlicedPacket`] struct. Currently supported
    /// ether type numbers are:
    ///
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
    /// #         1234); //destination port
    /// # // payload of the udp packet
    /// # let payload = [1,2,3,4,5,6,7,8];
    /// # // get some memory to store the serialized data
    /// # let mut complete_packet = Vec::<u8>::with_capacity(
    /// #     builder.size(payload.len())
    /// # );
    /// # builder.write(&mut complete_packet, &payload).unwrap();
    /// # // skip ethernet 2 header so we can parse from there downwards
    /// # let packet = &complete_packet[Ethernet2Header::LEN..];
    /// #
    /// use etherparse::{ether_type, LaxPacketHeaders, LenSource, LaxPayloadSlice};
    ///
    /// let value = LaxPacketHeaders::from_ether_type(ether_type::IPV4, &packet);
    ///
    /// if let Some((stop_err, error_layer)) = value.stop_err.as_ref() {
    ///     // error was encountered after parsing the ethernet 2 header
    ///     println!("Error on layer {}: {:?}", error_layer, stop_err);
    /// }
    ///
    /// // link is unfilled
    /// assert_eq!(value.link, None);
    ///
    /// // parts that could be parsed without error
    /// println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    /// println!("net: {:?}", value.net); // ip & arp
    /// println!("transport: {:?}", value.transport);
    ///
    /// // net (ip) & transport (udp or tcp)
    /// println!("net: {:?}", value.net);
    /// match value.payload {
    ///     LaxPayloadSlice::Empty => {
    ///         // Some packets don't have separate payloads. For example ARP packets.
    ///     }
    ///     LaxPayloadSlice::Ether(e) => {
    ///         println!("ether payload (ether type {:?}): {:?}", e.ether_type, e.payload);
    ///         if e.incomplete {
    ///             println!("ether payload incomplete (MACsec short length indicates more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::MacsecModified{ payload, incomplete } => {
    ///         println!("MACsec modified payload: {:?}", payload);
    ///         if incomplete {
    ///             println!("MACsec payload (MACsec short length indicates more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::Ip(ip) => {
    ///         println!("IP payload (IP number {:?}): {:?}", ip.ip_number, ip.payload);
    ///         if ip.incomplete {
    ///             println!("  IP payload incomplete (length in IP header indicated more data should be present)");
    ///         }
    ///         if ip.fragmented {
    ///             println!("  IP payload fragmented");
    ///         }
    ///     }
    ///     LaxPayloadSlice::Udp{ payload, incomplete } => {
    ///         println!("UDP payload: {:?}", payload);
    ///         if incomplete {
    ///             println!("  UDP payload incomplete (length in UDP or IP header indicated more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::Tcp{ payload, incomplete } => {
    ///         println!("TCP payload: {:?}", payload);
    ///         if incomplete {
    ///             println!("  TCP payload incomplete (length in IP header indicated more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::Icmpv4{ payload, incomplete } => {
    ///         println!("Icmpv4 payload: {:?}", payload);
    ///         if incomplete {
    ///             println!("  Icmpv4 payload incomplete (length in IP header indicated more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::Icmpv6{ payload, incomplete } => {
    ///         println!("Icmpv6 payload: {:?}", payload);
    ///         if incomplete {
    ///             println!("  Icmpv6 payload incomplete (length in IP header indicated more data should be present)");
    ///         }
    ///     }
    ///     LaxPayloadSlice::LinuxSll(linux_sll) => {
    ///         println!("Linux SLL payload (protocol type {:?}): {:?}", linux_sll.protocol_type, linux_sll.payload);
    ///     }
    /// }
    /// ```
    pub fn from_ether_type(mut ether_type: EtherType, slice: &'a [u8]) -> LaxPacketHeaders<'a> {
        use err::packet::SliceError::*;

        let mut rest = slice;
        let mut offset = 0;
        let mut result = LaxPacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            payload: LaxPayloadSlice::Ether(LaxEtherPayloadSlice {
                incomplete: false,
                ether_type,
                len_source: LenSource::Slice,
                payload: rest,
            }),
            stop_err: None,
        };

        // parse vlan header(s)
        let mut len_source = LenSource::Slice;
        use ether_type::*;
        loop {
            match ether_type {
                VLAN_TAGGED_FRAME | PROVIDER_BRIDGING | VLAN_DOUBLE_TAGGED_FRAME => {
                    if result.link_exts.is_full() {
                        break;
                    }
                    let (vlan, vlan_rest) = match SingleVlanHeader::from_slice(rest) {
                        Ok(value) => value,
                        Err(err) => {
                            result.stop_err = Some((
                                Len(err.add_offset(slice.len() - rest.len())),
                                Layer::VlanHeader,
                            ));
                            return result;
                        }
                    };

                    // set the rest & ether_type for the following operations
                    rest = vlan_rest;
                    offset += SingleVlanHeader::LEN;
                    ether_type = vlan.ether_type;
                    result.payload = LaxPayloadSlice::Ether(LaxEtherPayloadSlice {
                        incomplete: false,
                        ether_type,
                        len_source,
                        payload: rest,
                    });

                    // SAFETY: Safe as the while loop verified that there is still space left
                    unsafe {
                        result.link_exts.push_unchecked(LinkExtHeader::Vlan(vlan));
                    }
                }
                MACSEC => {
                    use err::macsec::HeaderSliceError as H;

                    if result.link_exts.is_full() {
                        break;
                    }

                    let macsec = match LaxMacsecSlice::from_slice(rest) {
                        Ok(m) => m,
                        Err(err) => {
                            result.stop_err = Some(match err {
                                H::Content(c) => (Macsec(c), Layer::MacsecHeader),
                                H::Len(l) => (
                                    Len(l.add_offset(slice.len() - rest.len())),
                                    Layer::MacsecHeader,
                                ),
                            });
                            return result;
                        }
                    };

                    // SAFETY: Safe as the while loop verified that there is still space left
                    unsafe {
                        result
                            .link_exts
                            .push_unchecked(LinkExtHeader::Macsec(macsec.header.to_header()));
                    }

                    match macsec.payload {
                        LaxMacsecPayloadSlice::Unmodified(l) => {
                            rest = l.payload;
                            offset += macsec.header.header_len();
                            ether_type = l.ether_type;
                            if l.len_source != LenSource::Slice {
                                len_source = l.len_source;
                            }
                            result.payload = LaxPayloadSlice::Ether(LaxEtherPayloadSlice {
                                incomplete: l.incomplete,
                                ether_type,
                                len_source,
                                payload: l.payload,
                            });
                        }
                        LaxMacsecPayloadSlice::Modified {
                            incomplete,
                            payload,
                        } => {
                            result.payload = LaxPayloadSlice::MacsecModified {
                                incomplete,
                                payload,
                            };
                            return result;
                        }
                    }
                }
                // stop looping as soon as a non link extension ether type is encountered
                _ => break,
            }
        }

        // parse ip or arp
        match ether_type {
            IPV4 | IPV6 => match result.add_ip(offset, rest) {
                Ok(_) => {}
                Err(err) => {
                    use err::ip::LaxHeaderSliceError as I;
                    result.stop_err = Some(match err {
                        I::Len(mut l) => {
                            l.layer_start_offset += offset;
                            (Len(l), Layer::IpHeader)
                        }
                        I::Content(c) => (Ip(c), Layer::IpHeader),
                    });
                    return result;
                }
            },
            ARP => {
                let arp = match ArpPacket::from_slice(rest) {
                    Ok(value) => value,
                    Err(mut err) => {
                        err.layer_start_offset += offset;
                        result.stop_err = Some((Len(err), Layer::Arp));
                        return result;
                    }
                };
                result.net = Some(NetHeaders::Arp(arp));
                return result;
            }
            _ => {}
        };

        result
    }

    /// Separates a network packet slice into different headers from the
    /// ip header downwards with lax length checks and will still return
    /// a result even if an error is encountered in a layer (except IP).
    ///
    /// This function has two main differences to [`PacketHeaders::from_ip_slice`]:
    ///
    /// * Errors encountered bellow the IpHeader will only stop the parsing and
    ///   return an `Ok` with the successfully parsed parts and the error as optional.
    ///   Only if an unrecoverable error is encountered in the IP header itself an
    ///   `Err` is returned.
    /// * Length in the IP header & UDP headers are allowed to be inconsistent with the
    ///   given slice length (e.g. data is missing from the slice). In this case it falls
    ///   back to the length of slice. See [`LaxIpSlice::from_slice`] for a detailed
    ///   description of when the slice length is used as a fallback.
    ///
    /// The result is returned as a [`SlicedPacket`] struct. This function
    /// assumes the given data starts with an IPv4 or IPv6 header.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{PacketBuilder, Ethernet2Header};
    /// # let builder = PacketBuilder::
    /// #    ipv4([192,168,1,1], //source ip
    /// #         [192,168,1,2], //destination ip
    /// #         20)            //time to life
    /// #    .udp(21,    //source port
    /// #         1234); //destination port
    /// # //payload of the udp packet
    /// # let payload = [1,2,3,4,5,6,7,8];
    /// # // get some memory to store the serialized data
    /// # let mut complete_packet = Vec::<u8>::with_capacity(
    /// #     builder.size(payload.len())
    /// # );
    /// # builder.write(&mut complete_packet, &payload).unwrap();
    /// # // skip ethernet 2 header so we can parse from there downwards
    /// # let packet = &complete_packet[Ethernet2Header::LEN..];
    /// #
    /// use etherparse::{ether_type, LaxPacketHeaders, LenSource, LaxPayloadSlice};
    ///
    /// match LaxPacketHeaders::from_ip(&packet) {
    ///     Err(value) => {
    ///         // An error is returned in case the ip header could
    ///         // not be parsed (other errors are stored in the "stop_err" field)
    ///         println!("Err {:?}", value)
    ///     },
    ///     Ok(value) => {
    ///         if let Some((stop_err, error_layer)) = value.stop_err.as_ref() {
    ///             // error was encountered after parsing the ethernet 2 header
    ///             println!("Error on layer {}: {:?}", error_layer, stop_err);
    ///         }
    ///
    ///         // link & vlan is unfilled
    ///         assert_eq!(value.link, None);
    ///         assert!(value.link_exts.is_empty());
    ///
    ///         // parts that could be parsed without error
    ///         println!("net: {:?}", value.net);
    ///         println!("transport: {:?}", value.transport);
    ///
    ///         // net (ip) & transport (udp or tcp)
    ///         println!("net: {:?}", value.net);
    ///         match value.payload {
    ///             // if you parse from IP down there will be no ether payload and the
    ///             // empty payload does not appear (only present in ARP packets).
    ///             LaxPayloadSlice::Ether(_) |
    ///                 LaxPayloadSlice::MacsecModified{ payload: _, incomplete: _} |
    ///                 LaxPayloadSlice::Empty |
    ///                 LaxPayloadSlice::LinuxSll(_) => unreachable!(),
    ///             LaxPayloadSlice::Ip(ip) => {
    ///                 println!("IP payload (IP number {:?}): {:?}", ip.ip_number, ip.payload);
    ///                 if ip.incomplete {
    ///                     println!("  IP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///                 if ip.fragmented {
    ///                     println!("  IP payload fragmented");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Udp{ payload, incomplete } => {
    ///                 println!("UDP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  UDP payload incomplete (length in UDP or IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Tcp{ payload, incomplete } => {
    ///                 println!("TCP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  TCP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv4{ payload, incomplete } => {
    ///                 println!("Icmpv4 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv4 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv6{ payload, incomplete } => {
    ///                 println!("Icmpv6 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv6 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///         }
    ///     }
    /// }
    ///
    /// ```
    pub fn from_ip(slice: &'a [u8]) -> Result<LaxPacketHeaders<'a>, err::ip::LaxHeaderSliceError> {
        let mut result = Self {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            // dummy initialize (will be overwritten if add_ip is successful)
            payload: LaxPayloadSlice::Udp {
                payload: &[],
                incomplete: true,
            },
            stop_err: None,
        };
        result.add_ip(0, slice)?;
        Ok(result)
    }

    /// Separates a network packet into different headers from the Linux Cooked Capture (SLL)
    /// header downwards with lax length checks and non-terminating errors.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    ///```
    /// # use etherparse::{LinuxSllPacketType, PacketBuilder};
    /// # let builder = PacketBuilder::
    /// #    linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    /// #              6,                             //sender address valid length
    /// #              [1,2,3,4,5,6,0,0])             //sender address with padding
    /// #    .ipv4([192,168,1,1], //source ip
    /// #          [192,168,1,2], //destination ip
    /// #          20)            //time to life
    /// #    .udp(21,    //source port
    /// #         1234); //destination port
    /// # // payload of the udp packet
    /// # let payload = [1,2,3,4,5,6,7,8];
    /// # // get some memory to store the serialized data
    /// # let mut packet = Vec::<u8>::with_capacity(
    /// #     builder.size(payload.len())
    /// # );
    /// # builder.write(&mut packet, &payload).unwrap();
    /// #
    /// use etherparse::{ether_type, LaxPacketHeaders, LenSource, LaxPayloadSlice};
    ///
    /// match LaxPacketHeaders::from_linux_sll(&packet) {
    ///     Err(value) => {
    ///         // An error is returned in case the ethernet II header could
    ///         // not be parsed (other errors are stored in the "stop_err" field)
    ///         println!("Err {:?}", value)
    ///     },
    ///     Ok(value) => {
    ///         if let Some((stop_err, error_layer)) = value.stop_err.as_ref() {
    ///             // error was encountered after parsing the ethernet 2 header
    ///             println!("Error on layer {}: {:?}", error_layer, stop_err);
    ///         }
    ///
    ///         // parts that could be parsed without error
    ///         println!("link: {:?}", value.link);
    ///         println!("link_exts: {:?}", value.link_exts); // vlan & macsec
    ///         println!("net: {:?}", value.net); // ip & arp
    ///         println!("transport: {:?}", value.transport);
    ///
    ///         // net (ip) & transport (udp or tcp)
    ///         println!("net: {:?}", value.net);
    ///         match value.payload {
    ///             LaxPayloadSlice::Empty => {
    ///                 // in case of ARP packet the payload is empty
    ///             }
    ///             LaxPayloadSlice::MacsecModified { payload, incomplete } => {
    ///                 println!("MACsec modified payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  MACsec payload incomplete (length in MACsec header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Ether(e) => {
    ///                 println!("ether payload (ether type {:?}): {:?}", e.ether_type, e.payload);
    ///             }
    ///             LaxPayloadSlice::Ip(ip) => {
    ///                 println!("IP payload (IP number {:?}): {:?}", ip.ip_number, ip.payload);
    ///                 if ip.incomplete {
    ///                     println!("  IP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///                 if ip.fragmented {
    ///                     println!("  IP payload fragmented");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Udp{ payload, incomplete } => {
    ///                 println!("UDP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  UDP payload incomplete (length in UDP or IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Tcp{ payload, incomplete } => {
    ///                 println!("TCP payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  TCP payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv4{ payload, incomplete } => {
    ///                 println!("Icmpv4 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv4 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::Icmpv6{ payload, incomplete } => {
    ///                 println!("Icmpv6 payload: {:?}", payload);
    ///                 if incomplete {
    ///                     println!("  Icmpv6 payload incomplete (length in IP header indicated more data should be present)");
    ///                 }
    ///             }
    ///             LaxPayloadSlice::LinuxSll(linux_sll) => {
    ///                 println!("Linux SLL payload (protocol type {:?}): {:?}", linux_sll.protocol_type, linux_sll.payload);
    ///             }
    ///         }
    ///     }
    /// }
    ///
    /// ```
    pub fn from_linux_sll(
        slice: &'a [u8],
    ) -> Result<LaxPacketHeaders<'a>, err::linux_sll::HeaderSliceError> {
        let (linux_sll, payload) = LinuxSllHeader::from_slice(slice)?;
        match linux_sll.protocol_type {
            LinuxSllProtocolType::EtherType(ether_type) => {
                let mut result = Self::from_ether_type(ether_type, payload);
                if let Some((SliceError::Len(l), _)) = result.stop_err.as_mut() {
                    l.layer_start_offset += linux_sll.header_len();
                }
                result.link = Some(LinkHeader::LinuxSll(linux_sll));
                Ok(result)
            }
            _ => {
                let mut result = LaxPacketHeaders {
                    link: None,
                    link_exts: ArrayVec::new_const(),
                    net: None,
                    transport: None,
                    payload: LaxPayloadSlice::LinuxSll(LinuxSllPayloadSlice {
                        protocol_type: linux_sll.protocol_type,
                        payload,
                    }),
                    stop_err: None,
                };
                result.link = Some(LinkHeader::LinuxSll(linux_sll));
                Ok(result)
            }
        }
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

    fn add_ip(
        &mut self,
        offset: usize,
        slice: &'a [u8],
    ) -> Result<(), err::ip::LaxHeaderSliceError> {
        use err::packet::SliceError::*;

        // read ipv4 header & extensions and payload slice
        let (ip, ip_payload, stop_err) = IpHeaders::from_slice_lax(slice)?;

        // set the next
        self.net = Some(ip.into());
        self.payload = LaxPayloadSlice::Ip(ip_payload.clone());

        // if a stop error was encountered return it
        if let Some((err, layer)) = stop_err {
            use err::ip_exts::HeaderError as IC;
            use err::ip_exts::HeadersSliceError as I;

            self.stop_err = Some((
                match err {
                    I::Len(mut l) => {
                        l.layer_start_offset += offset;
                        l.len_source = ip_payload.len_source;
                        Len(l)
                    }
                    I::Content(e) => match e {
                        IC::Ipv4Ext(e) => SliceError::Ipv4Exts(e),
                        IC::Ipv6Ext(e) => SliceError::Ipv6Exts(e),
                    },
                },
                layer,
            ));
            return Ok(());
        }

        // update the offset with the ip headers
        let offset = offset + ((ip_payload.payload.as_ptr() as usize) - (slice.as_ptr() as usize));

        // decode transport layer
        if false == ip_payload.fragmented {
            // helper function to set the len source in len errors
            let add_len_source = |mut len_error: LenError| -> err::packet::SliceError {
                // only change the len source if the lower layer has not set it
                if LenSource::Slice == len_error.len_source {
                    len_error.len_source = ip_payload.len_source;
                    len_error.layer_start_offset += offset;
                }
                err::packet::SliceError::Len(len_error)
            };

            use crate::ip_number::*;
            use err::tcp::HeaderSliceError::*;
            match ip_payload.ip_number {
                ICMP => match Icmpv4Slice::from_slice(ip_payload.payload) {
                    Ok(i) => {
                        self.transport = Some(TransportHeader::Icmpv4(i.header()));
                        self.payload = LaxPayloadSlice::Icmpv4 {
                            payload: i.payload(),
                            incomplete: ip_payload.incomplete,
                        };
                    }
                    Err(e) => {
                        self.stop_err = Some((add_len_source(e), Layer::Icmpv4));
                    }
                },
                IPV6_ICMP => match Icmpv6Slice::from_slice(ip_payload.payload) {
                    Ok(i) => {
                        self.transport = Some(TransportHeader::Icmpv6(i.header()));
                        self.payload = LaxPayloadSlice::Icmpv6 {
                            payload: i.payload(),
                            incomplete: ip_payload.incomplete,
                        };
                    }
                    Err(e) => {
                        self.stop_err = Some((add_len_source(e), Layer::Icmpv6));
                    }
                },
                UDP => {
                    match UdpSlice::from_slice_lax(ip_payload.payload) {
                        Ok(u) => {
                            self.transport = Some(TransportHeader::Udp(u.to_header()));
                            self.payload = LaxPayloadSlice::Udp {
                                payload: u.payload(),
                                // TODO also check the udp header length
                                incomplete: ip_payload.incomplete,
                            };
                        }
                        Err(e) => {
                            self.stop_err = Some((add_len_source(e), Layer::UdpHeader));
                        }
                    }
                }
                TCP => match TcpHeader::from_slice(ip_payload.payload) {
                    Ok(t) => {
                        self.transport = Some(TransportHeader::Tcp(t.0));
                        self.payload = LaxPayloadSlice::Tcp {
                            payload: t.1,
                            incomplete: ip_payload.incomplete,
                        };
                    }
                    Err(e) => match e {
                        Len(l) => {
                            self.stop_err = Some((add_len_source(l), Layer::TcpHeader));
                        }
                        Content(c) => {
                            self.stop_err = Some((SliceError::Tcp(c), Layer::TcpHeader));
                        }
                    },
                },
                _ => {}
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use std::vec::Vec;

    use super::*;
    use crate::test_packet::TestPacket;

    const VLAN_ETHER_TYPES: [EtherType; 3] = [
        ether_type::VLAN_TAGGED_FRAME,
        ether_type::PROVIDER_BRIDGING,
        ether_type::VLAN_DOUBLE_TAGGED_FRAME,
    ];

    const MACSEC_ETHER_TYPES: [EtherType; 1] = [ether_type::MACSEC];

    #[test]
    fn clone_eq() {
        let header = LaxPacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            stop_err: None,
            payload: LaxPayloadSlice::Udp {
                payload: &[],
                incomplete: false,
            },
        };
        assert_eq!(header.clone(), header);
    }

    #[test]
    fn debug() {
        use alloc::format;
        let payload = LaxPayloadSlice::Udp {
            payload: &[],
            incomplete: false,
        };
        let header = LaxPacketHeaders {
            link: None,
            link_exts: ArrayVec::new_const(),
            net: None,
            transport: None,
            payload: payload.clone(),
            stop_err: None,
        };
        assert_eq!(
            format!("{:?}", header),
            format!(
                "LaxPacketHeaders {{ link: {:?}, link_exts: {:?}, net: {:?}, transport: {:?}, payload: {:?}, stop_err: {:?} }}",
                header.link, header.link_exts, header.net, header.transport, payload, header.stop_err
            )
        );
    }

    #[test]
    fn vlan_vlan_ids() {
        // no content
        {
            let headers = LaxPacketHeaders {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
                payload: LaxPayloadSlice::Empty,
                stop_err: None,
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
            let headers = LaxPacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Vlan(outer.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: LaxPayloadSlice::Empty,
                stop_err: None,
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
            let headers = LaxPacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Vlan(outer.clone()));
                    exts.push(LinkExtHeader::Vlan(inner.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: LaxPayloadSlice::Empty,
                stop_err: None,
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

        // two vlan header & macsec header
        {
            let macsec = MacsecHeader {
                ptype: MacsecPType::Unmodified(EtherType::VLAN_DOUBLE_TAGGED_FRAME),
                endstation_id: false,
                scb: false,
                an: MacsecAn::ZERO,
                short_len: MacsecShortLen::ZERO,
                packet_nr: 0,
                sci: None,
            };
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

            let headers = LaxPacketHeaders {
                link: None,
                link_exts: {
                    let mut exts = ArrayVec::new_const();
                    exts.push(LinkExtHeader::Macsec(macsec.clone()));
                    exts.push(LinkExtHeader::Vlan(outer.clone()));
                    exts.push(LinkExtHeader::Vlan(inner.clone()));
                    exts
                },
                net: None,
                transport: None,
                payload: LaxPayloadSlice::Empty,
                stop_err: None,
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
            let headers = LaxPacketHeaders {
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
                payload: LaxPayloadSlice::Empty,
                stop_err: None,
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
                    assert_test_result(&test, &[], &data[..len], None, None);
                }
            }
        }

        // linux ssl
        {
            let linux_sll = LinuxSllHeader {
                packet_type: LinuxSllPacketType::HOST,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 0,
                sender_address: [0; 8],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType(0)),
            };
            let test = TestPacket {
                link: Some(LinkHeader::LinuxSll(linux_sll.clone())),
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
                    assert_test_result(&test, &[], &data[..len], None, None);
                }
            }

            // non ethernet linux sll
            {
                let header = LinuxSllHeader {
                    packet_type: LinuxSllPacketType::HOST,
                    arp_hrd_type: ArpHardwareId::NETLINK,
                    sender_address_valid_length: 0,
                    sender_address: [0; 8],
                    protocol_type: LinuxSllProtocolType::NetlinkProtocolType(0),
                };
                let payload = [1, 2, 3, 4];
                let data = {
                    let mut data = Vec::with_capacity(header.header_len() + payload.len());
                    data.extend_from_slice(&header.to_bytes());
                    data.extend_from_slice(&payload);
                    data
                };
                let actual = LaxPacketHeaders::from_linux_sll(&data).unwrap();
                let expected = LaxPacketHeaders {
                    link: Some(LinkHeader::LinuxSll(header.clone())),
                    link_exts: Default::default(),
                    net: None,
                    transport: None,
                    payload: LaxPayloadSlice::LinuxSll(LinuxSllPayloadSlice {
                        protocol_type: LinuxSllProtocolType::NetlinkProtocolType(0),
                        payload: &payload,
                    }),
                    stop_err: None,
                };
                assert_eq!(expected, actual);
            }
        }

        // from_ether_type unknown ether_type
        {
            let payload = [1, 2, 3, 4];
            let actual = LaxPacketHeaders::from_ether_type(0.into(), &payload);
            assert_eq!(None, actual.link);
            assert!(actual.link_exts.is_empty());
            assert_eq!(None, actual.net);
            assert_eq!(None, actual.transport);
            assert_eq!(
                actual.payload,
                LaxPayloadSlice::Ether(LaxEtherPayloadSlice {
                    incomplete: false,
                    ether_type: 0.into(),
                    len_source: LenSource::Slice,
                    payload: &payload
                })
            );
            assert_eq!(None, actual.stop_err);
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
                assert_test_result(
                    &test,
                    &[],
                    &data[..base_len + len],
                    None,
                    Some((SliceError::Len(err.clone()), err_layer)),
                );
            }
        };

        let content_errors = |test: &TestPacket| {
            if let Some(LinkExtHeader::Macsec(last)) = test.link_exts.last() {
                let mut data = test.to_vec(&[]);

                // inject bad version id
                let macsec_offset = data.len() - last.header_len();
                data[macsec_offset] = data[macsec_offset] | 0b1000_0000;

                assert_test_result(
                    &{
                        let mut expected = test.clone();
                        expected.link_exts.pop();
                        expected
                    },
                    &[],
                    &data,
                    None,
                    Some((
                        SliceError::Macsec(err::macsec::HeaderError::UnexpectedVersion),
                        Layer::MacsecHeader,
                    )),
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

        // arp
        {
            let arp = ArpPacket::new(
                ArpHardwareId::ETHERNET,
                EtherType::IPV4,
                ArpOperation::REQUEST,
                &[1, 2, 3, 4, 5, 6],
                &[7, 8, 9, 10],
                &[11, 12, 13, 14, 15, 16],
                &[17, 18, 19, 20],
            )
            .unwrap();

            let mut test = base.clone();
            test.set_ether_type(ether_type::ARP);
            test.net = Some(NetHeaders::Arp(arp.clone()));
            from_x_slice_assert_ok(&test);

            // arp len error
            {
                let data = test.to_vec(&[]);
                for len in 0..arp.packet_len() {
                    let base_len = test.len(&[]) - arp.packet_len();

                    let err = LenError {
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

                    assert_test_result(
                        &test,
                        &[],
                        &data[..base_len + len],
                        Some(err::ip::LaxHeaderSliceError::Len(err.clone())),
                        Some((SliceError::Len(err.clone()), Layer::Arp)),
                    );
                }
            }
        }

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
                test.set_payload_len(0);

                // ok ipv4
                from_x_slice_transport_variants(&test);

                // ipv4 len error
                {
                    let data = test.to_vec(&[]);
                    for len in 0..ipv4.header_len() {
                        let base_len = test.len(&[]) - ipv4.header_len();

                        let err = LenError {
                            required_len: if len < 1 { 1 } else { ipv4.header_len() },
                            len,
                            len_source: LenSource::Slice,
                            layer: if len < 1 {
                                Layer::IpHeader
                            } else {
                                Layer::Ipv4Header
                            },
                            layer_start_offset: base_len,
                        };

                        assert_test_result(
                            &test,
                            &[],
                            &data[..base_len + len],
                            Some(err::ip::LaxHeaderSliceError::Len(err.clone())),
                            Some((SliceError::Len(err.clone()), Layer::IpHeader)),
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

                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        Some(err::ip::LaxHeaderSliceError::Content(
                            Ipv4HeaderLengthSmallerThanHeader { ihl: 0 },
                        )),
                        Some((
                            SliceError::Ip(Ipv4HeaderLengthSmallerThanHeader { ihl: 0 }),
                            Layer::IpHeader,
                        )),
                    );
                }

                // ipv 4total length too small (does not change the output)
                {
                    let mut data = test.to_vec(&[]);
                    let ipv4_offset = data.len() - ipv4.header_len();

                    // set the total length to 0 to trigger a content error
                    data[ipv4_offset + 2] = 0;
                    data[ipv4_offset + 3] = 0;

                    let mut mod_test = test.clone();
                    mod_test.net = Some({
                        let (h, e) = test.net.as_ref().map(|v| v.ipv4_ref()).flatten().unwrap();
                        let mut ipv4 = h.clone();
                        ipv4.total_len = 0;
                        NetHeaders::Ipv4(ipv4, e.clone())
                    });

                    assert_test_result(&mod_test, &[], &data, None, None);
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

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        layer: Layer::IpAuthHeader,
                        layer_start_offset: base_len,
                    };

                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        None,
                        Some((SliceError::Len(err.clone()), Layer::IpAuthHeader)),
                    );
                }

                // ipv4 extension content error
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();

                    // set the icv len too smaller then allowed
                    data[auth_offset + 1] = 0;

                    // expect an error
                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        None,
                        Some((
                            SliceError::Ipv4Exts(err::ip_auth::HeaderError::ZeroPayloadLen),
                            Layer::IpAuthHeader,
                        )),
                    );
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
                {
                    let data = test.to_vec(&[]);
                    for len in 0..ipv6.header_len() {
                        let base_len = test.len(&[]) - ipv6.header_len();

                        let err = err::LenError {
                            required_len: if len < 1 { 1 } else { ipv6.header_len() },
                            len,
                            len_source: LenSource::Slice,
                            layer: if len < 1 {
                                Layer::IpHeader
                            } else {
                                Layer::Ipv6Header
                            },
                            layer_start_offset: base_len,
                        };

                        assert_test_result(
                            &test,
                            &[],
                            &data[..base_len + len],
                            Some(err::ip::LaxHeaderSliceError::Len(err.clone())),
                            Some((
                                SliceError::Len({
                                    if len < 1 {
                                        let mut err = err.clone();
                                        err.required_len = 1;
                                        err.layer = Layer::IpHeader;
                                        err
                                    } else {
                                        err.clone()
                                    }
                                }),
                                Layer::IpHeader,
                            )),
                        );
                    }
                }

                // content error ipv6
                {
                    use err::ip::{HeaderError::*, LaxHeaderSliceError::Content};

                    let mut data = test.to_vec(&[]);

                    // inject an invalid ip version
                    let base_len = data.len() - ipv6.header_len();
                    data[base_len] = data[base_len] & 0b0000_1111;

                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        Some(Content(UnsupportedIpVersion { version_number: 0 })),
                        Some((
                            SliceError::Ip(UnsupportedIpVersion { version_number: 0 }),
                            Layer::IpHeader,
                        )),
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

                    let data = test.to_vec(&[]);
                    let base_len = test.len(&[]) - auth.header_len();

                    let err = LenError {
                        required_len: auth.header_len(),
                        len,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        layer: Layer::IpAuthHeader,
                        layer_start_offset: base_len,
                    };
                    assert_test_result(
                        &test,
                        &[],
                        &data[..base_len + len],
                        None,
                        Some((SliceError::Len(err.clone()), Layer::IpAuthHeader)),
                    );
                }

                // ipv6 extension content error (auth)
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();
                    // set the icv len too smaller then allowed
                    data[auth_offset + 1] = 0;

                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        None,
                        Some((
                            SliceError::Ipv6Exts(err::ipv6_exts::HeaderError::IpAuth(
                                err::ip_auth::HeaderError::ZeroPayloadLen,
                            )),
                            Layer::IpAuthHeader,
                        )),
                    );
                }

                // ipv6 extension content error (hop by hop not at start)
                {
                    let mut data = test.to_vec(&[]);
                    let auth_offset = data.len() - auth.header_len();

                    // set the next header to be a hop-by-hop header to trigger a "not at start error"
                    data[auth_offset] = 0;

                    assert_test_result(
                        &test,
                        &[],
                        &data,
                        None,
                        Some((
                            SliceError::Ipv6Exts(err::ipv6_exts::HeaderError::HopByHopNotAtStart),
                            Layer::Ipv6HopByHopHeader,
                        )),
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
                        assert_test_result(
                            &test,
                            &[],
                            &data[..base_len + len],
                            None,
                            Some((SliceError::Len(err.clone()), Layer::UdpHeader)),
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
                            assert_test_result(
                                &test,
                                &[],
                                &data[..base_len + len],
                                None,
                                Some((SliceError::Len(err.clone()), Layer::TcpHeader)),
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
                        assert_test_result(
                            &test,
                            &[],
                            &data,
                            None,
                            Some((SliceError::Tcp(err.clone()), Layer::TcpHeader)),
                        );
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
                        assert_test_result(
                            &test,
                            &[],
                            &data[..base_len + len],
                            None,
                            Some((SliceError::Len(err.clone()), Layer::Icmpv4)),
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
                        assert_test_result(
                            &test,
                            &[],
                            &data[..base_len + len],
                            None,
                            Some((SliceError::Len(err.clone()), Layer::Icmpv6)),
                        );
                    }
                }
            }
        }
    }

    fn from_x_slice_assert_ok(test_base: &TestPacket) {
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
        assert_test_result(&test, &payload, &data, None, None);
    }

    /// Check that the given output & errors (if present) are generated based on the given
    /// input.
    fn assert_test_result(
        test: &TestPacket,
        expected_payload: &[u8],
        data: &[u8],
        expected_ip_err: Option<err::ip::LaxHeaderSliceError>,
        expected_stop_err: Option<(SliceError, Layer)>,
    ) {
        fn compare_exts(test: &TestPacket, data: &[u8], actual: &LaxPacketHeaders) {
            let mut vlan_offset = if let Some(e) = test.link.as_ref() {
                e.header_len()
            } else {
                0
            };

            let mut expected = ArrayVec::<LinkExtHeader, 3>::new();
            for e in &test.link_exts {
                match e {
                    LinkExtHeader::Vlan(s) => {
                        if data.len() >= vlan_offset + s.header_len() {
                            expected.push(e.clone());
                            vlan_offset += s.header_len();
                        } else {
                            // no more space left
                            break;
                        }
                    }
                    LinkExtHeader::Macsec(m) => {
                        if data.len() >= vlan_offset + m.header_len() {
                            expected.push(e.clone());
                            vlan_offset += m.header_len();
                        } else {
                            // no more space left
                            break;
                        }
                    }
                }
            }
            assert_eq!(expected, actual.link_exts);
        }

        fn compare_net_only(test: &TestPacket, actual: &LaxPacketHeaders) {
            assert_eq!(
                test.net.as_ref().map(|s| -> NetHeaders {
                    match s {
                        NetHeaders::Ipv4(h, _) => NetHeaders::Ipv4(h.clone(), Default::default()),
                        NetHeaders::Ipv6(h, _) => NetHeaders::Ipv6(h.clone(), Default::default()),
                        NetHeaders::Arp(h) => NetHeaders::Arp(h.clone()),
                    }
                }),
                actual.net.as_ref().map(|s| -> NetHeaders {
                    match s {
                        NetHeaders::Ipv4(h, _) => NetHeaders::Ipv4(h.clone(), Default::default()),
                        NetHeaders::Ipv6(h, _) => NetHeaders::Ipv6(h.clone(), Default::default()),
                        NetHeaders::Arp(h) => NetHeaders::Arp(h.clone()),
                    }
                })
            );
        }

        fn compare_transport(
            test: &TestPacket,
            is_fragmented: bool,
            expected_payload: &[u8],
            actual: &LaxPacketHeaders,
        ) {
            if is_fragmented {
                assert_eq!(actual.transport, None);
            } else {
                use TransportHeader as H;
                match &actual.transport {
                    Some(H::Icmpv4(icmpv4)) => {
                        assert_eq!(&test.transport, &Some(H::Icmpv4(icmpv4.clone())));
                        assert_eq!(
                            actual.payload,
                            LaxPayloadSlice::Icmpv4 {
                                payload: expected_payload,
                                incomplete: false
                            }
                        );
                    }
                    Some(H::Icmpv6(icmpv6)) => {
                        assert_eq!(&test.transport, &Some(H::Icmpv6(icmpv6.clone())));
                        assert_eq!(
                            actual.payload,
                            LaxPayloadSlice::Icmpv6 {
                                payload: expected_payload,
                                incomplete: false
                            }
                        );
                    }
                    Some(H::Udp(s)) => {
                        assert_eq!(&test.transport, &Some(H::Udp(s.clone())));
                        assert_eq!(
                            actual.payload,
                            LaxPayloadSlice::Udp {
                                payload: expected_payload,
                                incomplete: false
                            }
                        );
                    }
                    Some(H::Tcp(s)) => {
                        assert_eq!(&test.transport, &Some(H::Tcp(s.clone())));
                        assert_eq!(
                            actual.payload,
                            LaxPayloadSlice::Tcp {
                                payload: expected_payload,
                                incomplete: false
                            }
                        );
                    }
                    None => {
                        assert_eq!(&test.transport, &None);
                    }
                }
            }
        }

        // from_ethernet_slice
        if matches!(test.link, Some(LinkHeader::Ethernet2(_))) {
            if data.len() < Ethernet2Header::LEN {
                assert_eq!(
                    LenError {
                        required_len: Ethernet2Header::LEN,
                        len: data.len(),
                        len_source: LenSource::Slice,
                        layer: Layer::Ethernet2Header,
                        layer_start_offset: 0
                    },
                    LaxPacketHeaders::from_ethernet(&data).unwrap_err()
                );
            } else {
                let actual = LaxPacketHeaders::from_ethernet(&data).unwrap();
                assert_eq!(actual.stop_err, expected_stop_err);
                match expected_stop_err.as_ref().map(|v| v.1) {
                    None => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(test.net, actual.net);
                        compare_transport(
                            test,
                            test.is_ip_payload_fragmented(),
                            expected_payload,
                            &actual,
                        );
                    }
                    Some(Layer::VlanHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::MacsecHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::Ipv6Header)
                    | Some(Layer::Ipv4Header)
                    | Some(Layer::IpHeader)
                    | Some(Layer::Arp) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::IpAuthHeader)
                    | Some(Layer::Ipv6ExtHeader)
                    | Some(Layer::Ipv6HopByHopHeader)
                    | Some(Layer::Ipv6DestOptionsHeader)
                    | Some(Layer::Ipv6RouteHeader)
                    | Some(Layer::Ipv6FragHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        compare_net_only(test, &actual);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    Some(Layer::TcpHeader)
                    | Some(Layer::UdpHeader)
                    | Some(Layer::Icmpv4)
                    | Some(Layer::Icmpv6) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(test.net, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    layer => unreachable!("error in an unexpected layer {layer:?}"),
                }
            }
        }
        // from_linux_sll
        if matches!(test.link, Some(LinkHeader::LinuxSll(_))) {
            if data.len() < LinuxSllHeader::LEN {
                assert_eq!(
                    err::linux_sll::HeaderSliceError::Len(LenError {
                        required_len: LinuxSllHeader::LEN,
                        len: data.len(),
                        len_source: LenSource::Slice,
                        layer: Layer::LinuxSllHeader,
                        layer_start_offset: 0
                    }),
                    LaxPacketHeaders::from_linux_sll(&data).unwrap_err()
                );
            } else {
                let actual = LaxPacketHeaders::from_linux_sll(&data).unwrap();
                assert_eq!(actual.stop_err, expected_stop_err);
                match expected_stop_err.as_ref().map(|v| v.1) {
                    None => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(test.net, actual.net);
                        compare_transport(
                            test,
                            test.is_ip_payload_fragmented(),
                            expected_payload,
                            &actual,
                        );
                    }
                    Some(Layer::VlanHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::MacsecHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::Ipv6Header)
                    | Some(Layer::Ipv4Header)
                    | Some(Layer::IpHeader)
                    | Some(Layer::Arp) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::IpAuthHeader)
                    | Some(Layer::Ipv6ExtHeader)
                    | Some(Layer::Ipv6HopByHopHeader)
                    | Some(Layer::Ipv6DestOptionsHeader)
                    | Some(Layer::Ipv6RouteHeader)
                    | Some(Layer::Ipv6FragHeader) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        compare_net_only(test, &actual);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    Some(Layer::TcpHeader)
                    | Some(Layer::UdpHeader)
                    | Some(Layer::Icmpv4)
                    | Some(Layer::Icmpv6) => {
                        assert_eq!(test.link, actual.link);
                        compare_exts(test, data, &actual);
                        assert_eq!(test.net, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    layer => unreachable!("error in an unexpected layer {layer:?}"),
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
                let actual = LaxPacketHeaders::from_ether_type(*ether_type, data);
                assert_eq!(actual.stop_err, expected_stop_err);
                compare_exts(test, data, &actual);
                match expected_stop_err.as_ref().map(|v| v.1) {
                    None => {
                        assert_eq!(test.net, actual.net);
                        compare_transport(
                            test,
                            test.is_ip_payload_fragmented(),
                            expected_payload,
                            &actual,
                        );
                    }
                    Some(Layer::VlanHeader) => {
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::MacsecHeader) => {
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::Ipv6Header)
                    | Some(Layer::Ipv4Header)
                    | Some(Layer::IpHeader)
                    | Some(Layer::Arp) => {
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ether(_)));
                    }
                    Some(Layer::IpAuthHeader)
                    | Some(Layer::Ipv6ExtHeader)
                    | Some(Layer::Ipv6HopByHopHeader)
                    | Some(Layer::Ipv6DestOptionsHeader)
                    | Some(Layer::Ipv6RouteHeader)
                    | Some(Layer::Ipv6FragHeader) => {
                        compare_net_only(test, &actual);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    Some(Layer::TcpHeader)
                    | Some(Layer::UdpHeader)
                    | Some(Layer::Icmpv4)
                    | Some(Layer::Icmpv6) => {
                        assert_eq!(test.net, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    _ => unreachable!("error in an unexpected layer"),
                }
            }
        }
        // from_ether_type (ip or arp at start)
        if test.link.is_none() && test.link_exts.is_empty() {
            if let Some(net) = &test.net {
                let ether_type = match net {
                    NetHeaders::Ipv4(_, _) => ether_type::IPV4,
                    NetHeaders::Ipv6(_, _) => ether_type::IPV6,
                    NetHeaders::Arp(_) => ether_type::ARP,
                };
                let actual = LaxPacketHeaders::from_ether_type(ether_type, &data);
                assert_eq!(actual.stop_err, expected_stop_err);
                assert_eq!(None, actual.link);
                assert!(actual.link_exts.is_empty());
                match expected_stop_err.as_ref().map(|v| v.1) {
                    None => {
                        assert_eq!(test.net, actual.net);
                        compare_transport(
                            test,
                            test.is_ip_payload_fragmented(),
                            expected_payload,
                            &actual,
                        );
                    }
                    Some(Layer::Ipv6Header)
                    | Some(Layer::Ipv4Header)
                    | Some(Layer::IpHeader)
                    | Some(Layer::Arp) => {
                        assert_eq!(None, actual.net);
                        assert_eq!(None, actual.transport);
                        assert_eq!(
                            LaxPayloadSlice::Ether(LaxEtherPayloadSlice {
                                incomplete: false,
                                ether_type,
                                len_source: LenSource::Slice,
                                payload: data
                            }),
                            actual.payload
                        );
                    }
                    Some(Layer::IpAuthHeader)
                    | Some(Layer::Ipv6ExtHeader)
                    | Some(Layer::Ipv6HopByHopHeader)
                    | Some(Layer::Ipv6DestOptionsHeader)
                    | Some(Layer::Ipv6RouteHeader)
                    | Some(Layer::Ipv6FragHeader) => {
                        compare_net_only(test, &actual);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    Some(Layer::TcpHeader)
                    | Some(Layer::UdpHeader)
                    | Some(Layer::Icmpv4)
                    | Some(Layer::Icmpv6) => {
                        assert_eq!(test.net, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    _ => unreachable!("error in an unexpected layer"),
                }
            }
        }
        // from_ip_slice
        if test.link.is_none()
            && test.link_exts.is_empty()
            && test.net.is_some()
            && !matches!(test.net, Some(NetHeaders::Arp(_)))
        {
            if let Some(err) = expected_ip_err {
                assert_eq!(err, LaxPacketHeaders::from_ip(&data).unwrap_err());
            } else {
                let actual = LaxPacketHeaders::from_ip(&data).unwrap();
                assert_eq!(actual.stop_err, expected_stop_err);
                assert_eq!(actual.link, None);
                assert!(actual.link_exts.is_empty());
                match expected_stop_err.as_ref().map(|v| v.1) {
                    None => {
                        assert_eq!(test.net, actual.net);
                        compare_transport(
                            test,
                            test.is_ip_payload_fragmented(),
                            expected_payload,
                            &actual,
                        );
                    }
                    Some(Layer::IpAuthHeader)
                    | Some(Layer::Ipv6ExtHeader)
                    | Some(Layer::Ipv6HopByHopHeader)
                    | Some(Layer::Ipv6DestOptionsHeader)
                    | Some(Layer::Ipv6RouteHeader)
                    | Some(Layer::Ipv6FragHeader) => {
                        compare_net_only(test, &actual);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    Some(Layer::TcpHeader)
                    | Some(Layer::UdpHeader)
                    | Some(Layer::Icmpv4)
                    | Some(Layer::Icmpv6) => {
                        assert_eq!(test.net, actual.net);
                        assert_eq!(None, actual.transport);
                        assert!(matches!(actual.payload, LaxPayloadSlice::Ip(_)));
                    }
                    _ => unreachable!("error in an unexpected layer"),
                }
            }
        }
    }
}
