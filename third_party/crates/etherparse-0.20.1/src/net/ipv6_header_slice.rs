use crate::*;
use core::slice::from_raw_parts;

/// A slice containing an ipv6 header of a network package.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct Ipv6HeaderSlice<'a> {
    slice: &'a [u8],
}

impl<'a> Ipv6HeaderSlice<'a> {
    /// Creates a slice containing an ipv6 header (without header extensions).
    pub fn from_slice(slice: &'a [u8]) -> Result<Ipv6HeaderSlice<'a>, err::ipv6::HeaderSliceError> {
        use err::ipv6::{HeaderError::*, HeaderSliceError::*};

        // check length
        if slice.len() < Ipv6Header::LEN {
            return Err(Len(err::LenError {
                required_len: Ipv6Header::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Ipv6Header,
                layer_start_offset: 0,
            }));
        }

        // read version & ihl
        //
        // SAFETY:
        // This is safe as the slice len is checked to be
        // at least 40 bytes at the start of the function.
        let version_number = unsafe { slice.get_unchecked(0) >> 4 };

        // check version
        if 6 != version_number {
            return Err(Content(UnexpectedVersion { version_number }));
        }

        // all good
        Ok(Ipv6HeaderSlice {
            // SAFETY:
            // This is safe as the slice length is checked to be
            // at least Ipv6Header::LEN (40)
            // at the start of the function.
            slice: unsafe { from_raw_parts(slice.as_ptr(), Ipv6Header::LEN) },
        })
    }

    /// Converts the given slice into a ipv6 header slice WITHOUT any
    /// checks to ensure that the data present is an ipv4 header or that the
    /// slice length is matching the header length.
    ///
    /// If you are not sure what this means, use [`Ipv6HeaderSlice::from_slice`]
    /// instead.
    ///
    /// # Safety
    ///
    /// It must ensured that the slice length is at least [`Ipv6Header::LEN`].
    #[inline]
    pub(crate) unsafe fn from_slice_unchecked(slice: &[u8]) -> Ipv6HeaderSlice<'_> {
        Ipv6HeaderSlice { slice }
    }

    /// Returns the slice containing the ipv6 header
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Read the "version" field from the slice (should be 6).
    #[inline]
    pub fn version(&self) -> u8 {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { *self.slice.get_unchecked(0) >> 4 }
    }

    /// Read the "traffic class" field from the slice.
    #[inline]
    pub fn traffic_class(&self) -> u8 {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { (self.slice.get_unchecked(0) << 4) | (self.slice.get_unchecked(1) >> 4) }
    }

    /// Returns the [`IpEcn`] decoded from the `traffic_class` octet.
    #[inline]
    pub fn ecn(&self) -> IpEcn {
        // SAFETY: Safe as value can only be at most 0b11 as it is bit-and-ed with 0b11.
        unsafe { IpEcn::new_unchecked(self.traffic_class() & 0b0000_0011) }
    }

    /// Returns the [`IpDscp`] decoded from the `traffic_class` octet.
    #[inline]
    pub fn dscp(&self) -> IpDscp {
        // SAFETY: Safe as value can not be bigger than IpDscp::MAX_U8 as it
        //         is bit masked with IpDscp::MAX_U8 (0b0011_1111).
        unsafe { IpDscp::new_unchecked((self.traffic_class() >> 2) & 0b0011_1111) }
    }

    /// Read the "flow label" field from the slice.
    #[inline]
    pub fn flow_label(&self) -> Ipv6FlowLabel {
        unsafe {
            // SAFETY:
            // Slice access safe as the slice length is set to Ipv6Header::LEN (40)
            // during construction of the struct.
            // Conversion to flow label safe as the bitmask & 0 constant guarantee
            // that the value does not exceed 20 bits.
            Ipv6FlowLabel::new_unchecked(u32::from_be_bytes([
                0,
                *self.slice.get_unchecked(1) & 0xf,
                *self.slice.get_unchecked(2),
                *self.slice.get_unchecked(3),
            ]))
        }
    }

    /// Read the "payload length" field from  the slice. The length should contain the length of all extension headers and payload.
    #[inline]
    pub fn payload_length(&self) -> u16 {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(4)) }
    }

    /// Read the "next header" field from the slice.
    ///
    /// The next header value specifies what the next header or transport
    /// layer protocol is (see [IpNumber] or [ip_number] for a definitions of ids).
    #[inline]
    pub fn next_header(&self) -> IpNumber {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        IpNumber(unsafe { *self.slice.get_unchecked(6) })
    }

    /// Read the "hop limit" field from the slice. The hop limit specifies the number of hops the packet can take before it is discarded.
    #[inline]
    pub fn hop_limit(&self) -> u8 {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { *self.slice.get_unchecked(7) }
    }

    /// Returns a slice containing the IPv6 source address.
    #[inline]
    pub fn source(&self) -> [u8; 16] {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { get_unchecked_16_byte_array(self.slice.as_ptr().add(8)) }
    }

    /// Return the ipv6 source address as an core::net::Ipv6Addr
    #[inline]
    pub fn source_addr(&self) -> core::net::Ipv6Addr {
        core::net::Ipv6Addr::from(self.source())
    }

    /// Returns a slice containing the IPv6 destination address.
    #[inline]
    pub fn destination(&self) -> [u8; 16] {
        // SAFETY:
        // Safe as the slice length is set to
        // Ipv6Header::LEN (40) during construction
        // of the struct.
        unsafe { get_unchecked_16_byte_array(self.slice.as_ptr().add(24)) }
    }

    /// Return the ipv6 destination address as an core::net::Ipv6Addr
    #[inline]
    pub fn destination_addr(&self) -> core::net::Ipv6Addr {
        core::net::Ipv6Addr::from(self.destination())
    }

    /// Decode all the fields and copy the results to a Ipv6Header struct
    pub fn to_header(&self) -> Ipv6Header {
        Ipv6Header {
            traffic_class: self.traffic_class(),
            flow_label: self.flow_label(),
            payload_length: self.payload_length(),
            next_header: self.next_header(),
            hop_limit: self.hop_limit(),
            source: self.source(),
            destination: self.destination(),
        }
    }

    /// Returns the length of the IPv6 header in bytes (same as [`crate::Ipv6Header::LEN`]).
    pub const fn header_len(&self) -> usize {
        Ipv6Header::LEN
    }
}

#[cfg(test)]
mod test {
    use crate::{err::ipv6::HeaderError::*, err::ipv6::HeaderSliceError::*, test_gens::*, *};
    use alloc::format;
    use proptest::*;

    #[test]
    fn debug() {
        let header: Ipv6Header = Default::default();
        let bytes = header.to_bytes();
        let slice = Ipv6HeaderSlice::from_slice(&bytes).unwrap();
        assert_eq!(
            format!("{:?}", slice),
            format!("Ipv6HeaderSlice {{ slice: {:?} }}", &bytes[..])
        );
    }

    proptest! {
        #[test]
        fn clone_eq(header in ipv6_any()) {
            let bytes = header.to_bytes();
            let slice = Ipv6HeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            header in ipv6_any(),
            bad_version in 0..=0b1111u8)
        {
            // ok read
            {
                let bytes = header.to_bytes();
                let actual = Ipv6HeaderSlice::from_slice(&bytes).unwrap();
                assert_eq!(actual.slice(), &bytes[..]);
            }

            // version error
            if bad_version != 6 {
                let mut bytes = header.to_bytes();
                // inject a bad version number
                bytes[0] = (0b1111 & bytes[0]) | (bad_version << 4);

                assert_eq!(
                    Ipv6HeaderSlice::from_slice(&bytes).unwrap_err(),
                    Content(UnexpectedVersion{ version_number: bad_version })
                );
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6HeaderSlice::from_slice(&bytes[..len])
                            .unwrap_err(),
                        Len(err::LenError{
                            required_len: Ipv6Header::LEN,
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6Header,
                            layer_start_offset: 0,
                        })
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_unchecked(header in ipv6_any()) {
            let bytes = header.to_bytes();
            let actual = unsafe {
                Ipv6HeaderSlice::from_slice_unchecked(&bytes)
            };
            assert_eq!(actual.slice(), &bytes[..]);
        }
    }

    proptest! {
        #[test]
        fn getters(header in ipv6_any()) {
            let bytes = header.to_bytes();
            let actual = Ipv6HeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(actual.slice(), &bytes[..]);
            assert_eq!(actual.version(), 6);
            assert_eq!(actual.traffic_class(), header.traffic_class);
            assert_eq!(actual.ecn(), header.ecn());
            assert_eq!(actual.dscp(), header.dscp());
            assert_eq!(actual.flow_label(), header.flow_label);
            assert_eq!(actual.payload_length(), header.payload_length);
            assert_eq!(actual.next_header(), header.next_header);
            assert_eq!(actual.hop_limit(), header.hop_limit);
            assert_eq!(actual.source(), header.source);
            assert_eq!(actual.destination(), header.destination);
            assert_eq!(actual.source_addr(), core::net::Ipv6Addr::from(header.source));
            assert_eq!(actual.destination_addr(), core::net::Ipv6Addr::from(header.destination));
        }
    }

    proptest! {
        #[test]
        fn to_header(header in ipv6_any()) {
            let bytes = header.to_bytes();
            let actual = Ipv6HeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(actual.to_header(), header);
        }
    }
}
