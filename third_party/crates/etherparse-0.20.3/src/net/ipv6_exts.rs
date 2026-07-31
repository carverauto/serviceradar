use crate::{
    err::{ipv6_exts::*, Layer},
    *,
};

/// IPv6 extension headers present after the ip header.
///
/// Currently supported:
///
/// * Authentication Header
/// * Hop by Hop Options Header
/// * Destination Options Header (before and after routing headers)
/// * Routing Header
/// * Fragment
/// * Authentication Header
///
/// Currently not supported:
///
/// * Encapsulating Security Payload Header (ESP)
/// * Host Identity Protocol (HIP)
/// * IP Mobility
/// * Site Multihoming by IPv6 Intermediation (SHIM6)
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct Ipv6Extensions {
    pub hop_by_hop_options: Option<Ipv6RawExtHeader>,
    pub destination_options: Option<Ipv6RawExtHeader>,
    pub routing: Option<Ipv6RoutingExtensions>,
    pub fragment: Option<Ipv6FragmentHeader>,
    pub auth: Option<IpAuthHeader>,
}

impl Ipv6Extensions {
    /// Minimum length required for extension header in bytes/octets.
    /// Which is zero as no extension headers are required.
    pub const MIN_LEN: usize = 0;

    /// Maximum summed up length of all extension headers in bytes/octets.
    pub const MAX_LEN: usize = Ipv6RawExtHeader::MAX_LEN * 2
        + Ipv6RoutingExtensions::MAX_LEN
        + Ipv6FragmentHeader::LEN
        + IpAuthHeader::MAX_LEN;

    /// Reads as many extension headers as possible from the slice.
    ///
    /// Returns the found ipv6 extension headers, the next header ip number after the read
    /// headers and a slice containing the rest of the packet after the read headers.
    ///
    /// Note that this function can only handle ipv6 extensions if each extension header does
    /// occur at most once, except for destination options headers which are allowed to
    /// exist once in front of a routing header and once after a routing header.
    ///
    /// In case that more extension headers then can fit into a `Ipv6Extensions` struct are
    /// encountered, the parsing is stoped at the point where the data would no longer fit into
    /// the struct. In such a scenario a struct with the data that could be parsed is returned
    /// together with the next header ip number and slice containing the unparsed data.
    ///
    /// It is in the responsibility of the caller to handle a scenario like this.
    ///
    /// The reason that no error is generated, is that even though according to RFC 8200 packets
    /// "should" not contain more then one occurence of an extension header the RFC also specifies
    /// that "IPv6 nodes must accept and attempt to process extension headers in any order and
    /// occurring any number of times in the same packet". So packets with multiple headers "should"
    /// not exist, but are still valid IPv6 packets. As such this function does not generate a
    /// parsing error, as it is not an invalid packet, but if packets like these are encountered
    /// the user of this function has to themself decide how to handle packets like these.
    ///
    /// The only exception is if an hop by hop header is located somewhere else then directly at
    /// the start. In this case an `ReadError::Ipv6HopByHopHeaderNotAtStart` error is generated as
    /// the hop by hop header is required to be located directly after the IPv6 header according
    /// to RFC 8200.
    pub fn from_slice(
        start_ip_number: IpNumber,
        slice: &[u8],
    ) -> Result<(Ipv6Extensions, IpNumber, &[u8]), err::ipv6_exts::HeaderSliceError> {
        let mut result: Ipv6Extensions = Default::default();
        let mut rest = slice;
        let mut next_header = start_ip_number;

        use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};
        use ip_number::*;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_header {
            let slice = Ipv6RawExtHeaderSlice::from_slice(rest).map_err(Len)?;
            rest = &rest[slice.slice().len()..];
            next_header = slice.next_header();
            result.hop_by_hop_options = Some(slice.to_header());
        }

        loop {
            match next_header {
                IPV6_HOP_BY_HOP => {
                    return Err(Content(HopByHopNotAtStart));
                }
                IPV6_DEST_OPTIONS => {
                    if let Some(ref mut routing) = result.routing {
                        // if the routing header is already present
                        // this this a "final destination options" header
                        if routing.final_destination_options.is_some() {
                            // more then one header of this type found -> abort parsing
                            return Ok((result, next_header, rest));
                        } else {
                            let slice = Ipv6RawExtHeaderSlice::from_slice(rest)
                                .map_err(|err| Len(err.add_offset(slice.len() - rest.len())))?;
                            rest = &rest[slice.slice().len()..];
                            next_header = slice.next_header();
                            routing.final_destination_options = Some(slice.to_header());
                        }
                    } else if result.destination_options.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_header, rest));
                    } else {
                        let slice = Ipv6RawExtHeaderSlice::from_slice(rest)
                            .map_err(|err| Len(err.add_offset(slice.len() - rest.len())))?;
                        rest = &rest[slice.slice().len()..];
                        next_header = slice.next_header();
                        result.destination_options = Some(slice.to_header());
                    }
                }
                IPV6_ROUTE => {
                    if result.routing.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_header, rest));
                    } else {
                        let slice = Ipv6RawExtHeaderSlice::from_slice(rest)
                            .map_err(|err| Len(err.add_offset(slice.len() - rest.len())))?;
                        rest = &rest[slice.slice().len()..];
                        next_header = slice.next_header();
                        result.routing = Some(Ipv6RoutingExtensions {
                            routing: slice.to_header(),
                            final_destination_options: None,
                        });
                    }
                }
                IPV6_FRAG => {
                    if result.fragment.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_header, rest));
                    } else {
                        let slice = Ipv6FragmentHeaderSlice::from_slice(rest)
                            .map_err(|err| Len(err.add_offset(slice.len() - rest.len())))?;
                        rest = &rest[slice.slice().len()..];
                        next_header = slice.next_header();
                        result.fragment = Some(slice.to_header());
                    }
                }
                AUTH => {
                    if result.auth.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_header, rest));
                    } else {
                        let slice = IpAuthHeaderSlice::from_slice(rest).map_err(|err| {
                            use err::ip_auth::HeaderSliceError as I;
                            use err::ipv6_exts::HeaderError as O;
                            match err {
                                I::Len(err) => Len(err.add_offset(slice.len() - rest.len())),
                                I::Content(err) => Content(O::IpAuth(err)),
                            }
                        })?;
                        rest = &rest[slice.slice().len()..];
                        next_header = slice.next_header();
                        result.auth = Some(slice.to_header());
                    }
                }
                _ => {
                    // done parsing, the next header is not a known header extension
                    return Ok((result, next_header, rest));
                }
            }
        }
        //should not be hit
    }

    /// Reads as many extension headers as possible from the slice until a non IPv6 extension
    /// header or an error gets encountered.
    ///
    /// This function differs from [`Ipv6Extensions::from_slice`] in that it returns the successfully
    /// parsed parts together with the error. While [`Ipv6Extensions::from_slice`] only returns an
    /// error.
    ///
    /// Note that this function (same as [`Ipv6Extensions::from_slice`]) will stop parsing as soon
    /// as more headers then can be stored in [`Ipv6Extensions`] are encountered. E.g. if there is
    /// more then one "auth" header the function returns as soon as the second "auth" header is
    /// encountered.
    pub fn from_slice_lax(
        start_ip_number: IpNumber,
        slice: &[u8],
    ) -> (
        Ipv6Extensions,
        IpNumber,
        &[u8],
        Option<(err::ipv6_exts::HeaderSliceError, err::Layer)>,
    ) {
        let mut result: Ipv6Extensions = Default::default();
        let mut rest = slice;
        let mut next_header = start_ip_number;

        use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};
        use ip_number::*;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_header {
            match Ipv6RawExtHeaderSlice::from_slice(rest) {
                Ok(slice) => {
                    rest = &rest[slice.slice().len()..];
                    next_header = slice.next_header();
                    result.hop_by_hop_options = Some(slice.to_header());
                }
                Err(error) => {
                    return (
                        result,
                        next_header,
                        rest,
                        Some((Len(error), Layer::Ipv6HopByHopHeader)),
                    );
                }
            }
        }

        loop {
            match next_header {
                IPV6_HOP_BY_HOP => {
                    return (
                        result,
                        next_header,
                        rest,
                        Some((Content(HopByHopNotAtStart), Layer::Ipv6HopByHopHeader)),
                    );
                }
                IPV6_DEST_OPTIONS => {
                    if let Some(ref mut routing) = result.routing {
                        // if the routing header is already present
                        // this this a "final destination options" header
                        if routing.final_destination_options.is_some() {
                            // more then one header of this type found -> abort parsing
                            return (result, next_header, rest, None);
                        } else {
                            match Ipv6RawExtHeaderSlice::from_slice(rest) {
                                Ok(slice) => {
                                    rest = &rest[slice.slice().len()..];
                                    next_header = slice.next_header();
                                    routing.final_destination_options = Some(slice.to_header());
                                }
                                Err(err) => {
                                    return (
                                        result,
                                        next_header,
                                        rest,
                                        Some((
                                            Len(err.add_offset(slice.len() - rest.len())),
                                            Layer::Ipv6DestOptionsHeader,
                                        )),
                                    );
                                }
                            }
                        }
                    } else if result.destination_options.is_some() {
                        // more then one header of this type found -> abort parsing
                        return (result, next_header, rest, None);
                    } else {
                        match Ipv6RawExtHeaderSlice::from_slice(rest) {
                            Ok(slice) => {
                                rest = &rest[slice.slice().len()..];
                                next_header = slice.next_header();
                                result.destination_options = Some(slice.to_header());
                            }
                            Err(err) => {
                                return (
                                    result,
                                    next_header,
                                    rest,
                                    Some((
                                        Len(err.add_offset(slice.len() - rest.len())),
                                        Layer::Ipv6DestOptionsHeader,
                                    )),
                                );
                            }
                        }
                    }
                }
                IPV6_ROUTE => {
                    if result.routing.is_some() {
                        // more then one header of this type found -> abort parsing
                        return (result, next_header, rest, None);
                    } else {
                        match Ipv6RawExtHeaderSlice::from_slice(rest) {
                            Ok(slice) => {
                                rest = &rest[slice.slice().len()..];
                                next_header = slice.next_header();
                                result.routing = Some(Ipv6RoutingExtensions {
                                    routing: slice.to_header(),
                                    final_destination_options: None,
                                });
                            }
                            Err(err) => {
                                return (
                                    result,
                                    next_header,
                                    rest,
                                    Some((
                                        Len(err.add_offset(slice.len() - rest.len())),
                                        Layer::Ipv6RouteHeader,
                                    )),
                                );
                            }
                        }
                    }
                }
                IPV6_FRAG => {
                    if result.fragment.is_some() {
                        // more then one header of this type found -> abort parsing
                        return (result, next_header, rest, None);
                    } else {
                        match Ipv6FragmentHeaderSlice::from_slice(rest) {
                            Ok(slice) => {
                                rest = &rest[slice.slice().len()..];
                                next_header = slice.next_header();
                                result.fragment = Some(slice.to_header());
                            }
                            Err(err) => {
                                return (
                                    result,
                                    next_header,
                                    rest,
                                    Some((
                                        Len(err.add_offset(slice.len() - rest.len())),
                                        Layer::Ipv6FragHeader,
                                    )),
                                );
                            }
                        }
                    }
                }
                AUTH => {
                    if result.auth.is_some() {
                        // more then one header of this type found -> abort parsing
                        return (result, next_header, rest, None);
                    } else {
                        match IpAuthHeaderSlice::from_slice(rest) {
                            Ok(slice) => {
                                rest = &rest[slice.slice().len()..];
                                next_header = slice.next_header();
                                result.auth = Some(slice.to_header());
                            }
                            Err(err) => {
                                use err::ip_auth::HeaderSliceError as I;
                                use err::ipv6_exts::HeaderError as O;
                                return (
                                    result,
                                    next_header,
                                    rest,
                                    Some((
                                        match err {
                                            I::Len(err) => {
                                                Len(err.add_offset(slice.len() - rest.len()))
                                            }
                                            I::Content(err) => Content(O::IpAuth(err)),
                                        },
                                        Layer::IpAuthHeader,
                                    )),
                                );
                            }
                        }
                    }
                }
                _ => {
                    // done parsing, the next header is not a known header extension
                    return (result, next_header, rest, None);
                }
            }
        }
        //should not be hit
    }

    /// Reads as many extension headers as possible from the reader and returns the found ipv6
    /// extension headers and the next header ip number.
    ///
    /// If no extension headers are present an unfilled struct and the original `first_header`
    /// ip number is returned.
    ///
    /// Note that this function can only handle ipv6 extensions if each extension header does
    /// occur at most once, except for destination options headers which are allowed to
    /// exist once in front of a routing header and once after a routing header.
    ///
    /// In case that more extension headers then can fit into a `Ipv6Extensions` struct are
    /// encountered, the parsing is stoped at the point where the data would no longer fit into
    /// the struct. In such a scenario a struct with the data that could be parsed is returned
    /// together with the next header ip number that identfies which header could be read next.
    ///
    /// It is in the responsibility of the caller to handle a scenario like this.
    ///
    /// The reason that no error is generated, is that even though according to RFC 8200, packets
    /// "should" not contain more then one occurence of an extension header, the RFC also specifies
    /// that "IPv6 nodes must accept and attempt to process extension headers in any order and
    /// occurring any number of times in the same packet". So packets with multiple headers "should"
    /// not exist, but are still valid IPv6 packets. As such this function does not generate a
    /// parsing error, as it is not an invalid packet, but if packets like these are encountered
    /// the user of this function has to themself decide how to handle packets like these.
    ///
    /// The only exception is if an hop by hop header is located somewhere else then directly at
    /// the start. In this case an `ReadError::Ipv6HopByHopHeaderNotAtStart` error is generated as
    /// the hop by hop header is required to be located directly after the IPv6 header according
    /// to RFC 8200.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
        start_ip_number: IpNumber,
    ) -> Result<(Ipv6Extensions, IpNumber), err::ipv6_exts::HeaderReadError> {
        let mut result: Ipv6Extensions = Default::default();
        let mut next_protocol = start_ip_number;

        use err::ipv6_exts::{HeaderError::*, HeaderReadError::*};
        use ip_number::*;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_protocol {
            let header = Ipv6RawExtHeader::read(reader).map_err(Io)?;
            next_protocol = header.next_header;
            result.hop_by_hop_options = Some(header);
        }

        loop {
            match next_protocol {
                IPV6_HOP_BY_HOP => {
                    return Err(Content(HopByHopNotAtStart));
                }
                IPV6_DEST_OPTIONS => {
                    if let Some(ref mut routing) = result.routing {
                        // if the routing header is already present
                        // asume this is a "final destination options" header
                        if routing.final_destination_options.is_some() {
                            // more then one header of this type found -> abort parsing
                            return Ok((result, next_protocol));
                        } else {
                            let header = Ipv6RawExtHeader::read(reader).map_err(Io)?;
                            next_protocol = header.next_header;
                            routing.final_destination_options = Some(header);
                        }
                    } else if result.destination_options.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header = Ipv6RawExtHeader::read(reader).map_err(Io)?;
                        next_protocol = header.next_header;
                        result.destination_options = Some(header);
                    }
                }
                IPV6_ROUTE => {
                    if result.routing.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header = Ipv6RawExtHeader::read(reader).map_err(Io)?;
                        next_protocol = header.next_header;
                        result.routing = Some(Ipv6RoutingExtensions {
                            routing: header,
                            final_destination_options: None,
                        });
                    }
                }
                IPV6_FRAG => {
                    if result.fragment.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header = Ipv6FragmentHeader::read(reader).map_err(Io)?;
                        next_protocol = header.next_header;
                        result.fragment = Some(header);
                    }
                }
                AUTH => {
                    if result.auth.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header = IpAuthHeader::read(reader).map_err(|err| {
                            use err::ip_auth::HeaderReadError as I;
                            match err {
                                I::Io(err) => Io(err),
                                I::Content(err) => Content(IpAuth(err)),
                            }
                        })?;
                        next_protocol = header.next_header;
                        result.auth = Some(header);
                    }
                }
                _ => {
                    // done parsing, the next header is not a known header extension
                    return Ok((result, next_protocol));
                }
            }
        }

        //should not be hit
    }

    /// Reads as many extension headers as possible from the limited reader and returns the found ipv6
    /// extension headers and the next header ip number.
    ///
    /// If no extension headers are present an unfilled struct and the original `first_header`
    /// ip number is returned.
    ///
    /// Note that this function can only handle ipv6 extensions if each extension header does
    /// occur at most once, except for destination options headers which are allowed to
    /// exist once in front of a routing header and once after a routing header.
    ///
    /// In case that more extension headers then can fit into a `Ipv6Extensions` struct are
    /// encountered, the parsing is stoped at the point where the data would no longer fit into
    /// the struct. In such a scenario a struct with the data that could be parsed is returned
    /// together with the next header ip number that identfies which header could be read next.
    ///
    /// It is in the responsibility of the caller to handle a scenario like this.
    ///
    /// The reason that no error is generated, is that even though according to RFC 8200, packets
    /// "should" not contain more then one occurence of an extension header, the RFC also specifies
    /// that "IPv6 nodes must accept and attempt to process extension headers in any order and
    /// occurring any number of times in the same packet". So packets with multiple headers "should"
    /// not exist, but are still valid IPv6 packets. As such this function does not generate a
    /// parsing error, as it is not an invalid packet, but if packets like these are encountered
    /// the user of this function has to themself decide how to handle packets like these.
    ///
    /// The only exception is if an hop by hop header is located somewhere else then directly at
    /// the start. In this case an `ReadError::Ipv6HopByHopHeaderNotAtStart` error is generated as
    /// the hop by hop header is required to be located directly after the IPv6 header according
    /// to RFC 8200.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_limited<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut crate::io::LimitedReader<T>,
        start_ip_number: IpNumber,
    ) -> Result<(Ipv6Extensions, IpNumber), HeaderLimitedReadError> {
        use ip_number::*;
        use HeaderError::*;
        use HeaderLimitedReadError::*;

        fn map_limited_err(err: err::io::LimitedReadError) -> HeaderLimitedReadError {
            use crate::err::io::LimitedReadError as I;
            match err {
                I::Io(err) => Io(err),
                I::Len(err) => Len(err),
            }
        }

        // start decoding
        let mut result: Ipv6Extensions = Default::default();
        let mut next_protocol = start_ip_number;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_protocol {
            let header = Ipv6RawExtHeader::read_limited(reader).map_err(map_limited_err)?;
            next_protocol = header.next_header;
            result.hop_by_hop_options = Some(header);
        }

        loop {
            match next_protocol {
                IPV6_HOP_BY_HOP => {
                    return Err(Content(HopByHopNotAtStart));
                }
                IPV6_DEST_OPTIONS => {
                    if let Some(ref mut routing) = result.routing {
                        // if the routing header is already present
                        // asume this is a "final destination options" header
                        if routing.final_destination_options.is_some() {
                            // more then one header of this type found -> abort parsing
                            return Ok((result, next_protocol));
                        } else {
                            let header =
                                Ipv6RawExtHeader::read_limited(reader).map_err(map_limited_err)?;
                            next_protocol = header.next_header;
                            routing.final_destination_options = Some(header);
                        }
                    } else if result.destination_options.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header =
                            Ipv6RawExtHeader::read_limited(reader).map_err(map_limited_err)?;
                        next_protocol = header.next_header;
                        result.destination_options = Some(header);
                    }
                }
                IPV6_ROUTE => {
                    if result.routing.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header =
                            Ipv6RawExtHeader::read_limited(reader).map_err(map_limited_err)?;
                        next_protocol = header.next_header;
                        result.routing = Some(Ipv6RoutingExtensions {
                            routing: header,
                            final_destination_options: None,
                        });
                    }
                }
                IPV6_FRAG => {
                    if result.fragment.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header =
                            Ipv6FragmentHeader::read_limited(reader).map_err(map_limited_err)?;
                        next_protocol = header.next_header;
                        result.fragment = Some(header);
                    }
                }
                AUTH => {
                    if result.auth.is_some() {
                        // more then one header of this type found -> abort parsing
                        return Ok((result, next_protocol));
                    } else {
                        let header = IpAuthHeader::read_limited(reader).map_err(|err| {
                            use err::ip_auth::HeaderLimitedReadError as I;
                            match err {
                                I::Io(err) => Io(err),
                                I::Len(err) => Len(err),
                                I::Content(err) => Content(IpAuth(err)),
                            }
                        })?;
                        next_protocol = header.next_header;
                        result.auth = Some(header);
                    }
                }
                _ => {
                    // done parsing, the next header is not a known header extension
                    return Ok((result, next_protocol));
                }
            }
        }

        //should not be hit
    }

    /// Writes the given headers to a writer based on the order defined in
    /// the next_header fields of the headers and the first header_id
    /// passed to this function.
    ///
    /// It is required that all next header are correctly set in the headers
    /// and no other ipv6 header extensions follow this header. If this is not
    /// the case a [`err::ipv6_exts::ExtsWalkError`] is returned.
    pub(crate) fn write_internal<T: CoreWrite + ?Sized>(
        &self,
        writer: &mut T,
        first_header: IpNumber,
    ) -> Result<(), WriteError<T::Error, err::ipv6_exts::ExtsWalkError>> {
        use err::ipv6_exts::ExtsWalkError::*;
        use ip_number::*;

        /// Struct flagging if a header needs to be written.
        struct NeedsWrite {
            pub hop_by_hop_options: bool,
            pub destination_options: bool,
            pub routing: bool,
            pub fragment: bool,
            pub auth: bool,
            pub final_destination_options: bool,
        }

        let mut needs_write = NeedsWrite {
            hop_by_hop_options: self.hop_by_hop_options.is_some(),
            destination_options: self.destination_options.is_some(),
            routing: self.routing.is_some(),
            fragment: self.fragment.is_some(),
            auth: self.auth.is_some(),
            final_destination_options: if let Some(ref routing) = self.routing {
                routing.final_destination_options.is_some()
            } else {
                false
            },
        };

        let mut next_header = first_header;
        let mut route_written = false;

        // check if hop by hop header should be written first
        if IPV6_HOP_BY_HOP == next_header {
            let header = &self.hop_by_hop_options.as_ref().unwrap();
            writer
                .write_all(&header.to_bytes())
                .map_err(WriteError::Io)?;
            next_header = header.next_header;
            needs_write.hop_by_hop_options = false;
        }

        loop {
            match next_header {
                IPV6_HOP_BY_HOP => {
                    // Only trigger a "hop by hop not at start" error
                    // if we actually still have to write a hop by hop header.
                    //
                    // The ip number for hop by hop is 0, which could be used
                    // as a placeholder by user and later replaced. So let's
                    // not be overzealous and allow a next header with hop
                    // by hop if it is not part of this extensions struct.
                    if needs_write.hop_by_hop_options {
                        // the hop by hop header is only allowed at the start
                        return Err(WriteError::Content(HopByHopNotAtStart));
                    } else {
                        break;
                    }
                }
                IPV6_DEST_OPTIONS => {
                    // the destination options are allowed to be written twice
                    // once before a routing header and once after.
                    if route_written {
                        if needs_write.final_destination_options {
                            let header = &self
                                .routing
                                .as_ref()
                                .unwrap()
                                .final_destination_options
                                .as_ref()
                                .unwrap();
                            writer
                                .write_all(&header.to_bytes())
                                .map_err(WriteError::Io)?;
                            next_header = header.next_header;
                            needs_write.final_destination_options = false;
                        } else {
                            break;
                        }
                    } else if needs_write.destination_options {
                        let header = &self.destination_options.as_ref().unwrap();
                        writer
                            .write_all(&header.to_bytes())
                            .map_err(WriteError::Io)?;
                        next_header = header.next_header;
                        needs_write.destination_options = false;
                    } else {
                        break;
                    }
                }
                IPV6_ROUTE => {
                    if needs_write.routing {
                        let header = &self.routing.as_ref().unwrap().routing;
                        writer
                            .write_all(&header.to_bytes())
                            .map_err(WriteError::Io)?;
                        next_header = header.next_header;
                        needs_write.routing = false;
                        // for destination options
                        route_written = true;
                    } else {
                        break;
                    }
                }
                IPV6_FRAG => {
                    if needs_write.fragment {
                        let header = &self.fragment.as_ref().unwrap();
                        writer
                            .write_all(&header.to_bytes())
                            .map_err(WriteError::Io)?;
                        next_header = header.next_header;
                        needs_write.fragment = false;
                    } else {
                        break;
                    }
                }
                AUTH => {
                    if needs_write.auth {
                        let header = &self.auth.as_ref().unwrap();
                        writer
                            .write_all(&header.to_bytes())
                            .map_err(WriteError::Io)?;
                        next_header = header.next_header;
                        needs_write.auth = false;
                    } else {
                        break;
                    }
                }
                _ => {
                    // reached an unknown next_header id, proceed to check if everything was written
                    break;
                }
            }
        }

        // check that all header have been written
        if needs_write.hop_by_hop_options {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_HEADER_HOP_BY_HOP,
            }))
        } else if needs_write.destination_options {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_DESTINATION_OPTIONS,
            }))
        } else if needs_write.routing {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_ROUTE_HEADER,
            }))
        } else if needs_write.fragment {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_FRAGMENTATION_HEADER,
            }))
        } else if needs_write.auth {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            }))
        } else if needs_write.final_destination_options {
            Err(WriteError::Content(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_DESTINATION_OPTIONS,
            }))
        } else {
            Ok(())
        }
    }

    /// Writes the given headers to a writer based on the order defined in
    /// the next_header fields of the headers and the first header_id
    /// passed to this function.
    ///
    /// It is required that all next header are correctly set in the headers
    /// and no other ipv6 header extensions follow this header. If this is not
    /// the case an [`err::ipv6_exts::HeaderWriteError::Content`] error is
    /// returned.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(
        &self,
        writer: &mut T,
        first_header: IpNumber,
    ) -> Result<(), err::ipv6_exts::HeaderWriteError> {
        self.write_internal(&mut IoWriter(writer), first_header)
            .map_err(|err| match err {
                WriteError::Io(err) => err::ipv6_exts::HeaderWriteError::Io(err),
                WriteError::Content(err) => err::ipv6_exts::HeaderWriteError::Content(err),
            })
    }

    /// Length of the all present headers in bytes.
    pub fn header_len(&self) -> usize {
        let mut result = 0;

        if let Some(ref header) = self.hop_by_hop_options {
            result += header.header_len();
        }
        if let Some(ref header) = self.destination_options {
            result += header.header_len();
        }
        if let Some(ref header) = self.routing {
            result += header.routing.header_len();
            if let Some(ref header) = header.final_destination_options {
                result += header.header_len();
            }
        }
        if let Some(ref header) = self.fragment {
            result += header.header_len();
        }
        if let Some(ref header) = self.auth {
            result += header.header_len();
        }

        result
    }

    /// Sets all the next_header fields of the headers based on the adviced default order
    /// with the given protocol number as last "next header" value. The return value is the protocol
    /// number of the first existing extension header that should be entered in the ipv6 header as
    /// next_header.
    ///
    /// If no extension headers are present the value of the argument is returned.
    pub fn set_next_headers(&mut self, last_protocol_number: IpNumber) -> IpNumber {
        use ip_number::*;

        let mut next = last_protocol_number;

        // go through the proposed order of extension headers from
        // RFC 8200 backwards. The header order defined in RFC8200 is:
        //
        // * IPv6 header
        // * Hop-by-Hop Options header
        // * Destination Options header
        // * Routing header
        // * Fragment header
        // * Authentication header
        // * Encapsulating Security Payload header
        // * Destination Options header
        // * Upper-Layer header
        //
        if let Some(ref mut routing) = self.routing {
            if let Some(ref mut header) = routing.final_destination_options {
                header.next_header = next;
                next = IPV6_DEST_OPTIONS;
            }
        }
        if let Some(ref mut header) = self.auth {
            header.next_header = next;
            next = AUTH;
        }
        if let Some(ref mut header) = self.fragment {
            header.next_header = next;
            next = IPV6_FRAG;
        }
        if let Some(ref mut routing) = self.routing {
            routing.routing.next_header = next;
            next = IPV6_ROUTE;
        }
        if let Some(ref mut header) = self.destination_options {
            header.next_header = next;
            next = IPV6_DEST_OPTIONS;
        }
        if let Some(ref mut header) = self.hop_by_hop_options {
            header.next_header = next;
            next = IPV6_HOP_BY_HOP;
        }

        next
    }

    /// Return next header based on the extension headers and
    /// the first ip protocol number.
    pub fn next_header(&self, first_next_header: IpNumber) -> Result<IpNumber, ExtsWalkError> {
        use ip_number::*;
        use ExtsWalkError::*;

        /// Struct flagging if a header needs to be referenced.
        struct OutstandingRef {
            pub hop_by_hop_options: bool,
            pub destination_options: bool,
            pub routing: bool,
            pub fragment: bool,
            pub auth: bool,
            pub final_destination_options: bool,
        }

        let mut outstanding_refs = OutstandingRef {
            hop_by_hop_options: self.hop_by_hop_options.is_some(),
            destination_options: self.destination_options.is_some(),
            routing: self.routing.is_some(),
            fragment: self.fragment.is_some(),
            auth: self.auth.is_some(),
            final_destination_options: if let Some(ref routing) = self.routing {
                routing.final_destination_options.is_some()
            } else {
                false
            },
        };

        let mut next = first_next_header;
        let mut route_refed = false;

        // check if hop by hop header should be written first
        if IPV6_HOP_BY_HOP == next {
            if let Some(ref header) = self.hop_by_hop_options {
                next = header.next_header;
                outstanding_refs.hop_by_hop_options = false;
            }
        }

        loop {
            match next {
                IPV6_HOP_BY_HOP => {
                    // Only trigger a "hop by hop not at start" error
                    // if we actually still have to write a hop by hop header.
                    //
                    // The ip number for hop by hop is 0, which could be used
                    // as a placeholder by user and later replaced. So let's
                    // not be overzealous and allow a next header with hop
                    // by hop if it is not part of this extensions struct.
                    if outstanding_refs.hop_by_hop_options {
                        // the hop by hop header is only allowed at the start
                        return Err(HopByHopNotAtStart);
                    } else {
                        break;
                    }
                }
                IPV6_DEST_OPTIONS => {
                    // the destination options are allowed to be written twice
                    // once before a routing header and once after.
                    if route_refed {
                        if outstanding_refs.final_destination_options {
                            let header = &self
                                .routing
                                .as_ref()
                                .unwrap()
                                .final_destination_options
                                .as_ref()
                                .unwrap();
                            next = header.next_header;
                            outstanding_refs.final_destination_options = false;
                        } else {
                            break;
                        }
                    } else if outstanding_refs.destination_options {
                        let header = &self.destination_options.as_ref().unwrap();
                        next = header.next_header;
                        outstanding_refs.destination_options = false;
                    } else {
                        break;
                    }
                }
                IPV6_ROUTE => {
                    if outstanding_refs.routing {
                        let header = &self.routing.as_ref().unwrap().routing;
                        next = header.next_header;
                        outstanding_refs.routing = false;
                        // for destination options
                        route_refed = true;
                    } else {
                        break;
                    }
                }
                IPV6_FRAG => {
                    if outstanding_refs.fragment {
                        let header = &self.fragment.as_ref().unwrap();
                        next = header.next_header;
                        outstanding_refs.fragment = false;
                    } else {
                        break;
                    }
                }
                AUTH => {
                    if outstanding_refs.auth {
                        let header = &self.auth.as_ref().unwrap();
                        next = header.next_header;
                        outstanding_refs.auth = false;
                    } else {
                        break;
                    }
                }
                _ => break,
            }
        }

        // assume all done
        if outstanding_refs.hop_by_hop_options {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_HEADER_HOP_BY_HOP,
            });
        }
        if outstanding_refs.destination_options {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_DESTINATION_OPTIONS,
            });
        }
        if outstanding_refs.routing {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_ROUTE_HEADER,
            });
        }
        if outstanding_refs.fragment {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_FRAGMENTATION_HEADER,
            });
        }
        if outstanding_refs.auth {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            });
        }
        if outstanding_refs.final_destination_options {
            return Err(ExtNotReferenced {
                missing_ext: IpNumber::IPV6_DESTINATION_OPTIONS,
            });
        }

        Ok(next)
    }

    /// Returns true if a fragmentation header is present in
    /// the extensions that fragments the payload.
    ///
    /// Note: A fragmentation header can still be present
    /// even if the return value is false in case the fragmentation
    /// headers don't fragment the payload. This is the case if
    /// the offset of all fragmentation header is 0 and the
    /// more fragment bit is not set.
    #[inline]
    pub fn is_fragmenting_payload(&self) -> bool {
        if let Some(frag) = self.fragment.as_ref() {
            frag.is_fragmenting_payload()
        } else {
            false
        }
    }

    /// Returns true if no IPv6 extension header is present (all fields `None`).
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.hop_by_hop_options.is_none()
            && self.destination_options.is_none()
            && self.routing.is_none()
            && self.fragment.is_none()
            && self.auth.is_none()
    }
}

#[cfg(test)]
pub mod ipv6_exts_test_helpers {
    use super::*;
    use crate::ip_number::*;
    use alloc::vec::Vec;

    /// IP numbers that are assigned ipv6 header extensions.
    pub const EXTENSION_KNOWN_IP_NUMBERS: [IpNumber; 5] = [
        AUTH,
        IPV6_DEST_OPTIONS,
        IPV6_HOP_BY_HOP,
        IPV6_FRAG,
        IPV6_ROUTE,
    ];

    /// Helper struct that generates test data with dummy
    /// extension header data.
    pub struct ExtensionTestPayload {
        pub ip_numbers: Vec<IpNumber>,
        pub lengths: Vec<usize>,
        pub data: Vec<u8>,
    }

    impl ExtensionTestPayload {
        pub fn new(ip_numbers: &[IpNumber], header_sizes: &[u8]) -> ExtensionTestPayload {
            assert!(ip_numbers.len() > 1);
            assert!(header_sizes.len() > 0);

            let mut result = ExtensionTestPayload {
                ip_numbers: ip_numbers.to_vec(),
                lengths: Vec::with_capacity(ip_numbers.len() - 1),
                data: Vec::with_capacity((ip_numbers.len() - 1) * (0xff * 8 + 8)),
            };
            for i in 0..ip_numbers.len() - 1 {
                result.add_payload(
                    ip_numbers[i],
                    ip_numbers[i + 1],
                    header_sizes[i % header_sizes.len()],
                )
            }
            result
        }

        pub fn slice(&self) -> &[u8] {
            &self.data
        }

        fn add_payload(&mut self, ip_number: IpNumber, next_header: IpNumber, header_ext_len: u8) {
            match ip_number {
                IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS => {
                    // insert next header & size
                    let mut raw: [u8; 0xff * 8 + 8] = [0; 0xff * 8 + 8];
                    raw[0] = next_header.0;
                    raw[1] = header_ext_len;

                    // insert payload
                    self.data
                        .extend_from_slice(&raw[..8 + usize::from(header_ext_len) * 8]);
                    self.lengths.push(8 + usize::from(header_ext_len) * 8);
                }
                IPV6_FRAG => {
                    // generate payload
                    let mut raw: [u8; 8] = [0; 8];
                    raw[0] = next_header.0;
                    raw[1] = 0;

                    // insert payload
                    self.data.extend_from_slice(&raw[..8]);
                    self.lengths.push(8);
                }
                AUTH => {
                    let mut raw: [u8; 0xff * 4 + 8] = [0; 0xff * 4 + 8];
                    raw[0] = next_header.0;
                    // authentfication header len is defined as
                    // '32-bit words (4-byteunits), minus "2"'
                    let len = if header_ext_len > 0 {
                        raw[1] = header_ext_len;
                        usize::from(header_ext_len) * 4
                    } else {
                        // auth has a minimum size of 1
                        raw[1] = 1;
                        4
                    } + 8;
                    self.data.extend_from_slice(&raw[..len]);
                    self.lengths.push(len);
                }
                _ => unreachable!(),
            }
        }

        /// Returns true of the payload will trigger a "hop by hop not
        /// at start" error which is not ignored because of an early
        /// parsing abort.
        pub fn exts_hop_by_hop_error(&self) -> bool {
            struct ReadState {
                dest_opt: bool,
                routing: bool,
                final_dest_opt: bool,
                frag: bool,
                auth: bool,
            }

            // state if a header type has already been read
            let mut read = ReadState {
                dest_opt: false,
                routing: false,
                final_dest_opt: false,
                frag: false,
                auth: false,
            };

            for i in 0..self.ip_numbers.len() {
                match self.ip_numbers[i] {
                    IPV6_HOP_BY_HOP => {
                        if i != 0 {
                            return true;
                        }
                    }
                    IPV6_ROUTE => {
                        if read.routing {
                            return false;
                        } else {
                            read.routing = true;
                        }
                    }
                    IPV6_DEST_OPTIONS => {
                        // check the kind of destination options (aka is it before or after the routing header)
                        if read.routing {
                            // final dest opt
                            if read.final_dest_opt {
                                return false;
                            } else {
                                read.final_dest_opt = true;
                            }
                        } else {
                            // dst opt
                            if read.dest_opt {
                                return false;
                            } else {
                                read.dest_opt = true;
                            }
                        }
                    }
                    IPV6_FRAG => {
                        if read.frag {
                            return false;
                        } else {
                            read.frag = true;
                        }
                    }
                    AUTH => {
                        if read.auth {
                            return false;
                        } else {
                            read.auth = true;
                        }
                    }
                    _ => return false,
                }
            }
            return false;
        }

        /// Checks the if the extensions match the expected values based
        /// on this test payload.
        pub fn assert_extensions(
            &self,
            exts: &Ipv6Extensions,
        ) -> (usize, Option<IpNumber>, IpNumber) {
            struct ReadState {
                hop_by_hop: bool,
                dest_opt: bool,
                routing: bool,
                final_dest_opt: bool,
                frag: bool,
                auth: bool,
            }

            // state if a header type has already been read
            let mut read = ReadState {
                hop_by_hop: false,
                dest_opt: false,
                routing: false,
                final_dest_opt: false,
                frag: false,
                auth: false,
            };

            let mut slice = &self.data[..];
            let mut last_decoded = None;
            let mut post_header = self.ip_numbers[0];

            for i in 0..self.ip_numbers.len() - 1 {
                let mut stop = false;
                match self.ip_numbers[i] {
                    IPV6_HOP_BY_HOP => {
                        assert!(false == read.hop_by_hop);
                        let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                        assert_eq!(&header, exts.hop_by_hop_options.as_ref().unwrap());
                        slice = rest;
                        read.hop_by_hop = true;
                        last_decoded = Some(IPV6_HOP_BY_HOP);
                    }
                    IPV6_ROUTE => {
                        if read.routing {
                            stop = true;
                        } else {
                            let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                            assert_eq!(&header, &exts.routing.as_ref().unwrap().routing);
                            slice = rest;
                            read.routing = true;
                            last_decoded = Some(IPV6_ROUTE);
                        }
                    }
                    IPV6_DEST_OPTIONS => {
                        // check the kind of destination options (aka is it before or after the routing header)
                        if read.routing {
                            // final dest opt
                            if read.final_dest_opt {
                                stop = true;
                            } else {
                                let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                                assert_eq!(
                                    &header,
                                    exts.routing
                                        .as_ref()
                                        .unwrap()
                                        .final_destination_options
                                        .as_ref()
                                        .unwrap()
                                );
                                slice = rest;
                                read.final_dest_opt = true;
                                last_decoded = Some(IPV6_DEST_OPTIONS);
                            }
                        } else {
                            // dst opt
                            if read.dest_opt {
                                stop = true;
                            } else {
                                let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                                assert_eq!(&header, exts.destination_options.as_ref().unwrap());
                                slice = rest;
                                read.dest_opt = true;
                                last_decoded = Some(IPV6_DEST_OPTIONS);
                            }
                        }
                    }
                    IPV6_FRAG => {
                        if read.frag {
                            // duplicate header -> stop
                            stop = true;
                        } else {
                            let (header, rest) = Ipv6FragmentHeader::from_slice(slice).unwrap();
                            assert_eq!(&header, exts.fragment.as_ref().unwrap());
                            slice = rest;
                            read.frag = true;
                            last_decoded = Some(IPV6_FRAG);
                        }
                    }
                    AUTH => {
                        if read.auth {
                            // duplicate header -> stop
                            stop = true;
                        } else {
                            let (header, rest) = IpAuthHeader::from_slice(slice).unwrap();
                            assert_eq!(&header, exts.auth.as_ref().unwrap());
                            slice = rest;
                            read.auth = true;
                            last_decoded = Some(AUTH);
                        }
                    }
                    _ => {
                        // non extension header -> stop
                        stop = true;
                    }
                }
                if stop {
                    post_header = self.ip_numbers[i];
                    break;
                } else {
                    post_header = self.ip_numbers[i + 1];
                }
            }

            // check the non parsed headers are not present
            if false == read.hop_by_hop {
                assert!(exts.hop_by_hop_options.is_none());
            }
            if false == read.dest_opt {
                assert!(exts.destination_options.is_none());
            }
            if false == read.routing {
                assert!(exts.routing.is_none());
            } else {
                if false == read.final_dest_opt {
                    assert!(exts
                        .routing
                        .as_ref()
                        .unwrap()
                        .final_destination_options
                        .is_none());
                }
            }
            if false == read.frag {
                assert!(exts.fragment.is_none());
            }
            if false == read.auth {
                assert!(exts.auth.is_none());
            }

            (self.data.len() - slice.len(), last_decoded, post_header)
        }

        /// Return the expected lax from slice result and ipnumber which caused
        /// an error.
        pub fn lax_extensions_for_len(
            &self,
            limiting_len: usize,
        ) -> (Ipv6Extensions, IpNumber, &[u8], Option<IpNumber>) {
            // state if a header type has already been read
            let mut exts: Ipv6Extensions = Default::default();
            let mut post_header = *self.ip_numbers.first().unwrap();
            let mut slice = &self.data[..];

            for i in 0..self.ip_numbers.len() - 1 {
                // check if the limiting size gets hit
                if self.slice().len() - slice.len() + self.lengths[i] > limiting_len {
                    return (
                        exts,
                        self.ip_numbers[i],
                        &self.slice()[self.slice().len() - slice.len()..limiting_len],
                        Some(self.ip_numbers[i]),
                    );
                }

                let mut stop = false;
                match self.ip_numbers[i] {
                    IPV6_HOP_BY_HOP => {
                        assert!(exts.hop_by_hop_options.is_none());
                        let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                        exts.hop_by_hop_options = Some(header);
                        slice = rest;
                    }
                    IPV6_ROUTE => {
                        if exts.routing.is_some() {
                            stop = true;
                        } else {
                            let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                            exts.routing = Some(Ipv6RoutingExtensions {
                                routing: header,
                                final_destination_options: None,
                            });
                            slice = rest;
                        }
                    }
                    IPV6_DEST_OPTIONS => {
                        // check the kind of destination options (aka is it before or after the routing header)
                        if let Some(routing) = exts.routing.as_mut() {
                            // final dest opt
                            if routing.final_destination_options.is_some() {
                                stop = true;
                            } else {
                                let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                                routing.final_destination_options = Some(header);
                                slice = rest;
                            }
                        } else {
                            // dst opt
                            if exts.destination_options.is_some() {
                                stop = true;
                            } else {
                                let (header, rest) = Ipv6RawExtHeader::from_slice(slice).unwrap();
                                exts.destination_options = Some(header);
                                slice = rest;
                            }
                        }
                    }
                    IPV6_FRAG => {
                        if exts.fragment.is_some() {
                            // duplicate header -> stop
                            stop = true;
                        } else {
                            let (header, rest) = Ipv6FragmentHeader::from_slice(slice).unwrap();
                            exts.fragment = Some(header);
                            slice = rest;
                        }
                    }
                    AUTH => {
                        if exts.auth.is_some() {
                            // duplicate header -> stop
                            stop = true;
                        } else {
                            let (header, rest) = IpAuthHeader::from_slice(slice).unwrap();
                            exts.auth = Some(header);
                            slice = rest;
                        }
                    }
                    _ => {
                        // non extension header -> stop
                        stop = true;
                    }
                }
                if stop {
                    post_header = self.ip_numbers[i];
                    break;
                } else {
                    post_header = self.ip_numbers[i + 1];
                }
            }

            (
                exts,
                post_header,
                &self.slice()[self.slice().len() - slice.len()..limiting_len],
                None,
            )
        }
    }

    /// extension header data.
    #[derive(Clone)]
    pub struct ExtensionTestHeaders {
        pub ip_numbers: Vec<IpNumber>,
        pub data: Ipv6Extensions,
    }

    impl ExtensionTestHeaders {
        pub fn new(ip_numbers: &[IpNumber], header_sizes: &[u8]) -> ExtensionTestHeaders {
            assert!(ip_numbers.len() > 1);
            assert!(header_sizes.len() > 0);

            let mut result = ExtensionTestHeaders {
                ip_numbers: ip_numbers.to_vec(),
                data: Default::default(),
            };
            for i in 0..ip_numbers.len() - 1 {
                let succ = result.add_payload(
                    ip_numbers[i],
                    ip_numbers[i + 1],
                    header_sizes[i % header_sizes.len()],
                );
                if false == succ {
                    // write was not possible (duplicate)
                    // reduce the list so the current ip number
                    // is the final one
                    result.ip_numbers.truncate(i + 1);
                    break;
                }
            }
            result
        }

        pub fn introduce_missing_ref(&mut self, new_header: IpNumber) -> IpNumber {
            assert!(self.ip_numbers.len() >= 2);

            // set the next_header of the last extension header and return the id
            if self.ip_numbers.len() >= 3 {
                match self.ip_numbers[self.ip_numbers.len() - 3] {
                    IPV6_HOP_BY_HOP => {
                        self.data.hop_by_hop_options.as_mut().unwrap().next_header = new_header;
                    }
                    IPV6_DEST_OPTIONS => {
                        if self.ip_numbers[..self.ip_numbers.len() - 3]
                            .iter()
                            .any(|&x| x == IPV6_ROUTE)
                        {
                            self.data
                                .routing
                                .as_mut()
                                .unwrap()
                                .final_destination_options
                                .as_mut()
                                .unwrap()
                                .next_header = new_header;
                        } else {
                            self.data.destination_options.as_mut().unwrap().next_header =
                                new_header;
                        }
                    }
                    IPV6_ROUTE => {
                        self.data.routing.as_mut().unwrap().routing.next_header = new_header;
                    }
                    IPV6_FRAG => {
                        self.data.fragment.as_mut().unwrap().next_header = new_header;
                    }
                    AUTH => {
                        self.data.auth.as_mut().unwrap().next_header = new_header;
                    }
                    _ => unreachable!(),
                }
                match self.ip_numbers[self.ip_numbers.len() - 2] {
                    IPV6_HOP_BY_HOP => IpNumber::IPV6_HEADER_HOP_BY_HOP,
                    IPV6_DEST_OPTIONS => IpNumber::IPV6_DESTINATION_OPTIONS,
                    IPV6_ROUTE => IpNumber::IPV6_ROUTE_HEADER,
                    IPV6_FRAG => IpNumber::IPV6_FRAGMENTATION_HEADER,
                    AUTH => IpNumber::AUTHENTICATION_HEADER,
                    _ => unreachable!(),
                }
            } else {
                // rewrite start number in case it is just one extension header
                let missing = self.ip_numbers[0];
                self.ip_numbers[0] = new_header;
                match missing {
                    IPV6_HOP_BY_HOP => IpNumber::IPV6_HEADER_HOP_BY_HOP,
                    IPV6_DEST_OPTIONS => IpNumber::IPV6_DESTINATION_OPTIONS,
                    IPV6_ROUTE => IpNumber::IPV6_ROUTE_HEADER,
                    IPV6_FRAG => IpNumber::IPV6_FRAGMENTATION_HEADER,
                    AUTH => IpNumber::AUTHENTICATION_HEADER,
                    _ => unreachable!(),
                }
            }
        }

        fn add_payload(
            &mut self,
            ip_number: IpNumber,
            next_header: IpNumber,
            header_ext_len: u8,
        ) -> bool {
            match ip_number {
                IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS => {
                    use Ipv6RawExtHeader as R;
                    let payload: [u8; R::MAX_PAYLOAD_LEN] = [0; R::MAX_PAYLOAD_LEN];
                    let len = usize::from(header_ext_len) * 8 + 6;

                    let raw = Ipv6RawExtHeader::new_raw(next_header, &payload[..len]).unwrap();
                    match ip_number {
                        IPV6_HOP_BY_HOP => {
                            if self.data.hop_by_hop_options.is_none() {
                                self.data.hop_by_hop_options = Some(raw);
                                true
                            } else {
                                false
                            }
                        }
                        IPV6_ROUTE => {
                            if self.data.routing.is_none() {
                                self.data.routing = Some(Ipv6RoutingExtensions {
                                    routing: raw,
                                    final_destination_options: None,
                                });
                                true
                            } else {
                                false
                            }
                        }
                        IPV6_DEST_OPTIONS => {
                            if let Some(ref mut route) = self.data.routing {
                                if route.final_destination_options.is_none() {
                                    route.final_destination_options = Some(raw);
                                    true
                                } else {
                                    false
                                }
                            } else {
                                // dest option
                                if self.data.destination_options.is_none() {
                                    self.data.destination_options = Some(raw);
                                    true
                                } else {
                                    false
                                }
                            }
                        }
                        _ => unreachable!(),
                    }
                }
                IPV6_FRAG => {
                    if self.data.fragment.is_none() {
                        self.data.fragment = Some(Ipv6FragmentHeader::new(
                            next_header,
                            IpFragOffset::ZERO,
                            true,
                            123,
                        ));
                        true
                    } else {
                        false
                    }
                }
                AUTH => {
                    if self.data.auth.is_none() {
                        use IpAuthHeader as A;

                        let mut len = usize::from(header_ext_len) * 4;
                        if len > A::MAX_ICV_LEN {
                            len = A::MAX_ICV_LEN;
                        }
                        let raw_icv: [u8; A::MAX_ICV_LEN] = [0; A::MAX_ICV_LEN];
                        self.data.auth = Some(
                            IpAuthHeader::new(next_header, 123, 234, &raw_icv[..len]).unwrap(),
                        );
                        true
                    } else {
                        false
                    }
                }
                _ => unreachable!(),
            }
        }
    }
}

#[cfg(test)]
mod test {
    use super::ipv6_exts_test_helpers::*;
    use super::*;
    use crate::ip_number::*;
    use crate::test_gens::*;
    use alloc::{borrow::ToOwned, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};

            // no extension headers filled
            {
                let some_data = [1,2,3,4];
                let actual = Ipv6Extensions::from_slice(post_header, &some_data).unwrap();
                assert_eq!(actual.0, Default::default());
                assert_eq!(actual.1, post_header);
                assert_eq!(actual.2, &some_data);
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );

                if e.exts_hop_by_hop_error() {
                    // a hop by hop header that is not at the start triggers an error
                    assert_eq!(
                        Ipv6Extensions::from_slice(ip_numbers[0], e.slice()).unwrap_err(),
                        Content(HopByHopNotAtStart)
                    );
                } else {
                    // normal read
                    let (header, next, rest) = Ipv6Extensions::from_slice(ip_numbers[0], e.slice()).unwrap();
                    let (read_len, last_header, expected_post_header) = e.assert_extensions(&header);
                    assert_eq!(next, expected_post_header);
                    assert_eq!(rest, &e.slice()[read_len..]);

                    // unexpected end of slice
                    {
                        let mut offset: usize = 0;
                        for l in &e.lengths {
                            if offset + l >= read_len {
                                break;
                            }
                            offset += l;
                        }

                        assert_eq!(
                            Ipv6Extensions::from_slice(ip_numbers[0], &e.slice()[..read_len - 1]).unwrap_err(),
                            Len(err::LenError {
                                required_len: read_len - offset,
                                len: read_len - offset - 1,
                                len_source: LenSource::Slice,
                                layer: match last_header.unwrap() {
                                    AUTH => err::Layer::IpAuthHeader,
                                    IPV6_FRAG => err::Layer::Ipv6FragHeader,
                                    _ => err::Layer::Ipv6ExtHeader
                                },
                                layer_start_offset: offset,
                            })
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }

            // test that the auth content error gets forwarded
            {
                let auth = IpAuthHeader::new(post_header, 0, 0, &[]).unwrap();
                let mut bytes = auth.to_bytes();
                // inject an invalid len value
                bytes[1] = 0;
                let actual = Ipv6Extensions::from_slice(AUTH, &bytes).unwrap_err();

                use err::ipv6_exts::HeaderError::IpAuth;
                use err::ip_auth::HeaderError::ZeroPayloadLen;
                assert_eq!(actual, Content(IpAuth(ZeroPayloadLen)));
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_lax(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};

            // no extension headers filled
            {
                let some_data = [1,2,3,4];
                let actual = Ipv6Extensions::from_slice_lax(post_header, &some_data);
                assert_eq!(actual.0, Default::default());
                assert_eq!(actual.1, post_header);
                assert_eq!(actual.2, &some_data);
                assert!(actual.3.is_none());
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );

                if e.exts_hop_by_hop_error() {
                    // a hop by hop header that is not at the start triggers an error
                    let actual = Ipv6Extensions::from_slice_lax(ip_numbers[0], e.slice());
                    assert_eq!(actual.3.unwrap(), (Content(HopByHopNotAtStart), Layer::Ipv6HopByHopHeader));
                } else {
                    // normal read
                    let norm_actual = Ipv6Extensions::from_slice_lax(ip_numbers[0], e.slice());
                    let norm_expected = e.lax_extensions_for_len(e.slice().len());
                    assert_eq!(norm_actual.0, norm_expected.0);
                    assert_eq!(norm_actual.1, norm_expected.1);
                    assert_eq!(norm_actual.2, norm_expected.2);
                    assert!(norm_actual.3.is_none());

                    // unexpected end of slice
                    if norm_actual.0.header_len() > 0 {

                        let norm_len = norm_actual.0.header_len();
                        let actual = Ipv6Extensions::from_slice_lax(ip_numbers[0], &e.slice()[..norm_len - 1]);

                        let expected = e.lax_extensions_for_len(norm_len - 1);
                        assert_eq!(actual.0, expected.0);
                        assert_eq!(actual.1, expected.1);
                        assert_eq!(actual.2, expected.2);
                        let len_err = actual.3.unwrap().0.len_error().unwrap().clone();
                        assert_eq!(len_err.len, norm_len - 1 - expected.0.header_len());
                        assert_eq!(len_err.len_source, LenSource::Slice);
                        assert_eq!(
                            len_err.layer,
                            match expected.3.unwrap() {
                                AUTH => err::Layer::IpAuthHeader,
                                IPV6_FRAG => err::Layer::Ipv6FragHeader,
                                _ => err::Layer::Ipv6ExtHeader
                            }
                        );
                        assert_eq!(len_err.layer_start_offset, expected.0.header_len());
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }

            // test that the auth content error gets forwarded
            {
                let auth = IpAuthHeader::new(post_header, 0, 0, &[]).unwrap();
                let mut bytes = auth.to_bytes();
                // inject an invalid len value
                bytes[1] = 0;
                let actual = Ipv6Extensions::from_slice_lax(AUTH, &bytes);
                assert_eq!(0, actual.0.header_len());
                assert_eq!(AUTH, actual.1);
                assert_eq!(&bytes[..], actual.2);

                use err::ipv6_exts::HeaderError::IpAuth;
                use err::ip_auth::HeaderError::ZeroPayloadLen;
                assert_eq!(actual.3.unwrap(), (Content(IpAuth(ZeroPayloadLen)), Layer::IpAuthHeader));
            }
        }
    }

    proptest! {
        #[test]
        fn read(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::HeaderError::*;
            use std::io::Cursor;

            // no extension headers filled
            {
                let mut cursor = Cursor::new(&[]);
                let actual = Ipv6Extensions::read(&mut cursor, post_header).unwrap();
                assert_eq!(actual.0, Default::default());
                assert_eq!(actual.1, post_header);
                assert_eq!(0, cursor.position());
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );
                let mut cursor = Cursor::new(e.slice());

                if e.exts_hop_by_hop_error() {
                    // a hop by hop header that is not at the start triggers an error
                    assert_eq!(
                        Ipv6Extensions::read(&mut cursor, ip_numbers[0]).unwrap_err().content_error().unwrap(),
                        HopByHopNotAtStart
                    );
                } else {
                    // normal read
                    let (header, next) = Ipv6Extensions::read(&mut cursor, ip_numbers[0]).unwrap();
                    let (read_len, _, expected_post_header) = e.assert_extensions(&header);
                    assert_eq!(next, expected_post_header);
                    assert_eq!(cursor.position() as usize, read_len);

                    // unexpected end of slice
                    {
                        let mut short_cursor = Cursor::new(&e.slice()[..read_len - 1]);
                        assert!(
                            Ipv6Extensions::read(&mut short_cursor, ip_numbers[0])
                            .unwrap_err()
                            .io_error()
                            .is_some()
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }

            // test that the auth content error gets forwarded
            {
                let auth = IpAuthHeader::new(post_header, 0, 0, &[]).unwrap();
                let mut bytes = auth.to_bytes();
                // inject an invalid len value
                bytes[1] = 0;
                let mut cursor = Cursor::new(&bytes[..]);
                let actual = Ipv6Extensions::read(&mut cursor, AUTH).unwrap_err();

                use err::ipv6_exts::HeaderError::IpAuth;
                use err::ip_auth::HeaderError::ZeroPayloadLen;
                assert_eq!(actual.content_error().unwrap(), IpAuth(ZeroPayloadLen));
            }
        }
    }

    proptest! {
        #[test]
        fn read_limited(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::HeaderError::*;
            use err::Layer;
            use std::io::Cursor;
            use crate::io::LimitedReader;

            // no extension headers filled
            {
                let mut reader = LimitedReader::new(
                    Cursor::new(&[]),
                    0,
                    LenSource::Slice,
                    0,
                    Layer::Ipv6Header
                );
                let actual = Ipv6Extensions::read_limited(&mut reader, post_header).unwrap();
                assert_eq!(actual.0, Default::default());
                assert_eq!(actual.1, post_header);
                assert_eq!(0, reader.read_len());
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );
                let mut reader = LimitedReader::new(
                    Cursor::new(e.slice()),
                    e.slice().len(),
                    LenSource::Slice,
                    0,
                    Layer::Ipv6Header
                );

                if e.exts_hop_by_hop_error() {
                    // a hop by hop header that is not at the start triggers an error
                    assert_eq!(
                        Ipv6Extensions::read_limited(&mut reader, ip_numbers[0]).unwrap_err().content().unwrap(),
                        HopByHopNotAtStart
                    );
                } else {
                    // normal read
                    let (header, next) = Ipv6Extensions::read_limited(&mut reader, ip_numbers[0]).unwrap();
                    let (read_len, _, expected_post_header) = e.assert_extensions(&header);
                    assert_eq!(next, expected_post_header);
                    assert_eq!(reader.read_len() + reader.layer_offset(), read_len);

                    // io error unexpected end
                    {
                        let mut short_reader = LimitedReader::new(
                            Cursor::new(&e.slice()[..read_len - 1]),
                            read_len,
                            LenSource::Slice,
                            0,
                            Layer::Ipv6Header
                        );

                        assert!(
                            Ipv6Extensions::read_limited(&mut short_reader, ip_numbers[0])
                            .unwrap_err()
                            .io()
                            .is_some()
                        );
                    }

                    // len error
                    {
                        let mut short_reader = LimitedReader::new(
                            Cursor::new(e.slice()),
                            read_len - 1,
                            LenSource::Slice,
                            0,
                            Layer::Ipv6Header
                        );

                        assert!(
                            Ipv6Extensions::read_limited(&mut short_reader, ip_numbers[0])
                            .unwrap_err()
                            .len()
                            .is_some()
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }

            // test that the auth content error gets forwarded
            {
                let auth = IpAuthHeader::new(post_header, 0, 0, &[]).unwrap();
                let mut bytes = auth.to_bytes();
                // inject an invalid len value
                bytes[1] = 0;
                let mut reader = LimitedReader::new(
                    Cursor::new(&bytes[..]),
                    bytes.len(),
                    LenSource::Slice,
                    0,
                    Layer::Ipv6Header
                );
                let actual = Ipv6Extensions::read_limited(&mut reader, AUTH).unwrap_err();

                use err::ipv6_exts::HeaderError::IpAuth;
                use err::ip_auth::HeaderError::ZeroPayloadLen;
                assert_eq!(actual.content().unwrap(), IpAuth(ZeroPayloadLen));
            }
        }
    }

    proptest! {
        #[test]
        fn write(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            // no extension headers filled
            {
                let exts : Ipv6Extensions = Default::default();
                let mut buffer = Vec::new();
                exts.write(&mut buffer, post_header).unwrap();
                assert_eq!(0, buffer.len());
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8], post_header: IpNumber) {
                use std::io::Cursor;
                use crate::err::ipv6_exts::ExtsWalkError::*;

                // setup test header
                let e = ExtensionTestHeaders::new(
                    ip_numbers,
                    header_sizes
                );

                if e.ip_numbers[1..e.ip_numbers.len()-1].iter().any(|&x| x == IPV6_HOP_BY_HOP) {
                    // a hop by hop header that is not at the start triggers an error
                    let mut writer = Vec::with_capacity(e.data.header_len());
                    assert_eq!(
                        e.data.write(&mut writer, e.ip_numbers[0]).unwrap_err().content().unwrap(),
                        &HopByHopNotAtStart
                    );
                } else {
                    // normal write
                    {
                        let mut writer = Vec::with_capacity(e.data.header_len());
                        e.data.write(&mut writer, e.ip_numbers[0]).unwrap();

                        if *e.ip_numbers.last().unwrap() != IPV6_HOP_BY_HOP {
                            // decoding if there will be no duplicate hop by hop error
                            // will be triggered
                            let (read, read_next, _) = Ipv6Extensions::from_slice(
                                e.ip_numbers[0],
                                &writer
                            ).unwrap();
                            assert_eq!(e.data, read);
                            assert_eq!(*e.ip_numbers.last().unwrap(), read_next);
                        }
                    }

                    // write error
                    {
                        let mut buffer = Vec::with_capacity(e.data.header_len() - 1);
                        buffer.resize(e.data.header_len() - 1, 0);
                        let mut cursor = Cursor::new(&mut buffer[..]);

                        let err = e.data.write(
                            &mut cursor,
                            e.ip_numbers[0]
                        ).unwrap_err();

                        assert!(err.io().is_some());
                    }

                    // missing reference (skip the last header)
                    {
                        use crate::err::ipv6_exts::ExtsWalkError::ExtNotReferenced;

                        let mut missing_ref = e.clone();
                        let missing_ext = missing_ref.introduce_missing_ref(post_header);

                        let mut writer = Vec::with_capacity(e.data.header_len());
                        let err = missing_ref.data.write(
                            &mut writer,
                            missing_ref.ip_numbers[0]
                        ).unwrap_err();

                        assert_eq!(
                            err.content().unwrap(),
                            &ExtNotReferenced{ missing_ext }
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                    post_header,
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                        post_header,
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                            post_header,
                        );
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(
            hop_by_hop_options in ipv6_raw_ext_any(),
            destination_options in ipv6_raw_ext_any(),
            routing in ipv6_raw_ext_any(),
            fragment in ipv6_fragment_any(),
            auth in ip_auth_any(),
            final_destination_options in ipv6_raw_ext_any(),
        ) {
            // None
            {
                let exts : Ipv6Extensions = Default::default();
                assert_eq!(0, exts.header_len());
            }

            // All filled
            {
                let exts = Ipv6Extensions{
                    hop_by_hop_options: Some(hop_by_hop_options.clone()),
                    destination_options: Some(destination_options.clone()),
                    routing: Some(
                        Ipv6RoutingExtensions{
                            routing: routing.clone(),
                            final_destination_options: Some(final_destination_options.clone()),
                        }
                    ),
                    fragment: Some(fragment.clone()),
                    auth: Some(auth.clone()),
                };
                assert_eq!(
                    exts.header_len(),
                    (
                        hop_by_hop_options.header_len() +
                        destination_options.header_len() +
                        routing.header_len() +
                        final_destination_options.header_len() +
                        fragment.header_len() +
                        auth.header_len()
                    )
                );
            }

            // Routing without final destination options
            {
                let exts = Ipv6Extensions{
                    hop_by_hop_options: Some(hop_by_hop_options.clone()),
                    destination_options: Some(destination_options.clone()),
                    routing: Some(
                        Ipv6RoutingExtensions{
                            routing: routing.clone(),
                            final_destination_options: None,
                        }
                    ),
                    fragment: Some(fragment.clone()),
                    auth: Some(auth.clone()),
                };
                assert_eq!(
                    exts.header_len(),
                    (
                        hop_by_hop_options.header_len() +
                        destination_options.header_len() +
                        routing.header_len() +
                        fragment.header_len() +
                        auth.header_len()
                    )
                );
            }
        }
    }

    proptest! {
        #[test]
        fn set_next_headers(
            hop_by_hop_options in ipv6_raw_ext_any(),
            destination_options in ipv6_raw_ext_any(),
            routing in ipv6_raw_ext_any(),
            fragment in ipv6_fragment_any(),
            auth in ip_auth_any(),
            final_destination_options in ipv6_raw_ext_any(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                ),
        ) {
            // none filled
            {
                let mut exts : Ipv6Extensions = Default::default();
                assert_eq!(post_header, exts.set_next_headers(post_header));
                assert!(exts.hop_by_hop_options.is_none());
                assert!(exts.destination_options.is_none());
                assert!(exts.routing.is_none());
                assert!(exts.fragment.is_none());
                assert!(exts.auth.is_none());
            }

            // all filled
            {
                let mut exts = Ipv6Extensions{
                    hop_by_hop_options: Some(hop_by_hop_options.clone()),
                    destination_options: Some(destination_options.clone()),
                    routing: Some(
                        Ipv6RoutingExtensions{
                            routing: routing.clone(),
                            final_destination_options: Some(final_destination_options.clone()),
                        }
                    ),
                    fragment: Some(fragment.clone()),
                    auth: Some(auth.clone()),
                };
                assert_eq!(IPV6_HOP_BY_HOP, exts.set_next_headers(post_header));

                assert_eq!(IPV6_DEST_OPTIONS, exts.hop_by_hop_options.as_ref().unwrap().next_header);
                assert_eq!(IPV6_ROUTE, exts.destination_options.as_ref().unwrap().next_header);
                assert_eq!(IPV6_FRAG, exts.routing.as_ref().unwrap().routing.next_header);
                assert_eq!(AUTH, exts.fragment.as_ref().unwrap().next_header);
                assert_eq!(IPV6_DEST_OPTIONS, exts.auth.as_ref().unwrap().next_header);
                assert_eq!(post_header, exts.routing.as_ref().unwrap().final_destination_options.as_ref().unwrap().next_header);
            }
        }
    }

    proptest! {
        #[test]
        fn next_header(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                ),)
        {
            // test empty
            {
                let exts : Ipv6Extensions = Default::default();
                assert_eq!(post_header, exts.next_header(post_header).unwrap());
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8], post_header: IpNumber) {
                // setup test header
                let e = ExtensionTestHeaders::new(
                    ip_numbers,
                    header_sizes
                );

                if e.ip_numbers[1..e.ip_numbers.len()-1].iter().any(|&x| x == IPV6_HOP_BY_HOP) {
                    // a hop by hop header that is not at the start triggers an error
                    use crate::err::ipv6_exts::ExtsWalkError::HopByHopNotAtStart;
                    assert_eq!(
                        e.data.next_header(e.ip_numbers[0]).unwrap_err(),
                        HopByHopNotAtStart
                    );
                } else {
                    // normal header
                    assert_eq!(
                        *e.ip_numbers.last().unwrap(),
                        e.data.next_header(e.ip_numbers[0]).unwrap()
                    );

                    // missing reference (skip the last header)
                    {
                        use crate::err::ipv6_exts::ExtsWalkError::ExtNotReferenced;

                        let mut missing_ref = e.clone();
                        let missing_ext = missing_ref.introduce_missing_ref(post_header);
                        assert_eq!(
                            missing_ref.data.next_header(missing_ref.ip_numbers[0]).unwrap_err(),
                            ExtNotReferenced{ missing_ext }
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                    post_header,
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                        post_header,
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                            post_header,
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn is_fragmenting_payload() {
        // empty
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: None,
                fragment: None,
                auth: None,
            }
            .is_fragmenting_payload()
        );

        // non fragmenting frag header
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: None,
                fragment: Some(Ipv6FragmentHeader::new(
                    ip_number::UDP,
                    IpFragOffset::ZERO,
                    false,
                    0
                )),
                auth: None,
            }
            .is_fragmenting_payload()
        );

        // fragmenting frag header
        assert!(Ipv6Extensions {
            hop_by_hop_options: None,
            destination_options: None,
            routing: None,
            fragment: Some(Ipv6FragmentHeader::new(
                ip_number::UDP,
                IpFragOffset::ZERO,
                true,
                0
            )),
            auth: None,
        }
        .is_fragmenting_payload());
    }

    #[test]
    fn is_empty() {
        // empty
        assert!(Ipv6Extensions {
            hop_by_hop_options: None,
            destination_options: None,
            routing: None,
            fragment: None,
            auth: None,
        }
        .is_empty());

        // hop_by_hop_options
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: Some(
                    Ipv6RawExtHeader::new_raw(ip_number::UDP, &[1, 2, 3, 4, 5, 6]).unwrap()
                ),
                destination_options: None,
                routing: None,
                fragment: None,
                auth: None,
            }
            .is_empty()
        );

        // destination_options
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: Some(
                    Ipv6RawExtHeader::new_raw(ip_number::UDP, &[1, 2, 3, 4, 5, 6]).unwrap()
                ),
                routing: None,
                fragment: None,
                auth: None,
            }
            .is_empty()
        );

        // routing
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: Some(Ipv6RoutingExtensions {
                    routing: Ipv6RawExtHeader::new_raw(ip_number::UDP, &[1, 2, 3, 4, 5, 6])
                        .unwrap(),
                    final_destination_options: None,
                }),
                fragment: None,
                auth: None,
            }
            .is_empty()
        );

        // fragment
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: None,
                fragment: Some(Ipv6FragmentHeader::new(
                    ip_number::UDP,
                    IpFragOffset::ZERO,
                    true,
                    0
                )),
                auth: None,
            }
            .is_empty()
        );

        // auth
        assert_eq!(
            false,
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: None,
                fragment: None,
                auth: Some(IpAuthHeader::new(ip_number::UDP, 0, 0, &[]).unwrap()),
            }
            .is_empty()
        );
    }

    #[test]
    fn debug() {
        use alloc::format;

        let a: Ipv6Extensions = Default::default();
        assert_eq!(
            &format!(
                "Ipv6Extensions {{ hop_by_hop_options: {:?}, destination_options: {:?}, routing: {:?}, fragment: {:?}, auth: {:?} }}",
                a.hop_by_hop_options,
                a.destination_options,
                a.routing,
                a.fragment,
                a.auth,
            ),
            &format!("{:?}", a)
        );
    }

    #[test]
    fn clone_eq() {
        let a: Ipv6Extensions = Default::default();
        assert_eq!(a, a.clone());
    }

    #[test]
    fn default() {
        let a: Ipv6Extensions = Default::default();
        assert_eq!(a.hop_by_hop_options, None);
        assert_eq!(a.destination_options, None);
        assert_eq!(a.routing, None);
        assert_eq!(a.fragment, None);
        assert_eq!(a.auth, None);
    }
}
