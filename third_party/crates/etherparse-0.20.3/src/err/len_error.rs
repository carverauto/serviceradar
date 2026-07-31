use crate::{err::Layer, LenSource};

/// Error when different lengths are conflicting with each other (e.g. not
/// enough data in a slice to decode a header).
///
/// This error is triggered whenever there is not enough data to decode
/// an element (e.g. if a slice is too small to decode an header) or
/// if a length that is inhered from an upper layer is too big for the
/// lower layer (e.g. length inherited from an IP header is too big to
/// be used as an ICMP packet length).
///
/// When the error is caused by not enough data being available
/// `required_len > len` must be true. While when the length from
/// the upper layer is too big for the lower layer the inverse
/// (`required_len < len`) must be true.
///
/// # Examples:
///
/// An example for an error that could be returned when there is not enough
/// data available to decode an UDP header would be:
///
/// ```
/// use etherparse::*;
///
/// err::LenError{
///     // Expected to have at least the length of an UDP header present:
///     required_len: UdpHeader::LEN,
///     // Could not decode the UDP header:
///     layer: err::Layer::UdpHeader,
///     // There was only 1 byte left (not enough for an UDP header):
///     len: 1,
///     // The provided length was determined by the total length field in the
///     // IPv4 header:
///     len_source: LenSource::Ipv4HeaderTotalLen,
///     // Offset in bytes from the start of decoding (ethernet in this) case
///     // to the expected UDP header start:
///     layer_start_offset: Ethernet2Header::LEN + Ipv4Header::MIN_LEN
/// };
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct LenError {
    /// Expected minimum or maximum length conflicting with the
    /// `len` value.
    pub required_len: usize,

    /// Length limiting or exceeding the required length.
    pub len: usize,

    /// Source of the outer length (e.g. Slice or a length specified by
    /// an upper level protocol).
    pub len_source: LenSource,

    /// Layer in which the length error was encountered.
    pub layer: Layer,

    /// Offset from the start of the parsed data to the layer where the
    /// length error occurred.
    pub layer_start_offset: usize,
}

impl LenError {
    /// Adds an offset value to the `layer_start_offset` field.
    #[inline]
    pub const fn add_offset(self, offset: usize) -> Self {
        LenError {
            required_len: self.required_len,
            layer: self.layer,
            len: self.len,
            len_source: self.len_source,
            layer_start_offset: self.layer_start_offset + offset,
        }
    }
}

impl core::fmt::Display for LenError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let len_source: &'static str = {
            use LenSource::*;
            match self.len_source {
                Slice => "slice length",
                MacsecShortLength => {
                    "length calculated from the MACsec header 'short length' field"
                }
                Ipv4HeaderTotalLen => "length calculated from the IPv4 header 'total length' field",
                Ipv6HeaderPayloadLen => {
                    "length calculated from the IPv6 header 'payload length' field"
                }
                UdpHeaderLen => "length calculated from the UDP header 'length' field",
                TcpHeaderLen => "length calculated from the TCP header 'length' field",
                ArpAddrLengths => {
                    "length calculated from the ARP 'hw_addr_size' & 'proto_addr_size' fields"
                }
            }
        };

        if self.required_len > self.len {
            if self.layer_start_offset > 0 {
                write!(
                    f,
                    "{}: Not enough data to decode '{}'. {} byte(s) would be required, but only {} byte(s) are available based on the {} ('{}' starts at overall parsed byte {}).",
                    self.layer.error_title(),
                    self.layer,
                    self.required_len,
                    self.len,
                    len_source,
                    self.layer,
                    self.layer_start_offset
                )
            } else {
                write!(
                    f,
                    "{}: Not enough data to decode '{}'. {} byte(s) would be required, but only {} byte(s) are available based on the {}.",
                    self.layer.error_title(),
                    self.layer,
                    self.required_len,
                    self.len,
                    len_source
                )
            }
        } else if self.layer_start_offset > 0 {
            write!(
                f,
                "{}: Length of {} byte(s) is too big for an '{}' (maximum is {} bytes). The {} was used to determine the length ('{}' starts at overall parsed byte {}).",
                self.layer.error_title(),
                self.len,
                self.layer,
                self.required_len,
                len_source,
                self.layer,
                self.layer_start_offset
            )
        } else {
            write!(
                f,
                "{}: Length of {} byte(s) is too big for an '{}' (maximum is {} bytes). The {} was used to determine the length.",
                self.layer.error_title(),
                self.len,
                self.layer,
                self.required_len,
                len_source
            )
        }
    }
}

impl core::error::Error for LenError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn add_offset() {
        assert_eq!(
            LenError {
                required_len: 2,
                layer: Layer::Icmpv4,
                len: 1,
                len_source: LenSource::Slice,
                layer_start_offset: 20,
            }
            .add_offset(100),
            LenError {
                required_len: 2,
                layer: Layer::Icmpv4,
                len: 1,
                len_source: LenSource::Slice,
                layer_start_offset: 120,
            }
        );
    }

    #[test]
    fn debug() {
        assert_eq!(
            format!(
                "{:?}",
                LenError {
                    required_len: 2,
                    layer: Layer::Ipv4Header,
                    len: 1,
                    len_source: LenSource::Slice,
                    layer_start_offset: 0
                }
            ),
            format!(
                "LenError {{ required_len: {:?}, len: {:?}, len_source: {:?}, layer: {:?}, layer_start_offset: {:?} }}",
                2, 1, LenSource::Slice, Layer::Ipv4Header, 0
            ),
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = LenError {
            required_len: 2,
            layer: Layer::Icmpv4,
            len: 1,
            len_source: LenSource::Slice,
            layer_start_offset: 20,
        };
        assert_eq!(err, err.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            err.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            err.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
    }

    #[test]
    fn fmt() {
        // len sources based tests (not enough data)
        {
            use crate::LenSource::*;
            let len_source_tests = [
                (Slice, "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the slice length."),
                (Ipv4HeaderTotalLen, "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the length calculated from the IPv4 header 'total length' field."),
                (Ipv6HeaderPayloadLen, "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the length calculated from the IPv6 header 'payload length' field."),
                (UdpHeaderLen, "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the length calculated from the UDP header 'length' field."),
                (TcpHeaderLen, "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the length calculated from the TCP header 'length' field."),
            ];

            for test in len_source_tests {
                assert_eq!(
                    test.1,
                    format!(
                        "{}",
                        LenError {
                            required_len: 2,
                            layer: Layer::Ipv4Header,
                            len: 1,
                            len_source: test.0,
                            layer_start_offset: 0
                        }
                    )
                );
            }
        }

        // start offset based test
        assert_eq!(
            "IPv4 Header Error: Not enough data to decode 'IPv4 header'. 2 byte(s) would be required, but only 1 byte(s) are available based on the slice length ('IPv4 header' starts at overall parsed byte 4).",
            format!(
                "{}",
                LenError{
                    required_len: 2,
                    len: 1,
                    len_source: LenSource::Slice,
                    layer: Layer::Ipv4Header,
                    layer_start_offset: 4
                }
            )
        );

        // len sources based tests (length too big)
        {
            use crate::LenSource::*;
            let len_source_tests = [
                (Slice, "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The slice length was used to determine the length."),
                (Ipv4HeaderTotalLen, "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The length calculated from the IPv4 header 'total length' field was used to determine the length."),
                (Ipv6HeaderPayloadLen, "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The length calculated from the IPv6 header 'payload length' field was used to determine the length."),
                (UdpHeaderLen, "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The length calculated from the UDP header 'length' field was used to determine the length."),
                (TcpHeaderLen, "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The length calculated from the TCP header 'length' field was used to determine the length."),
            ];

            for test in len_source_tests {
                assert_eq!(
                    test.1,
                    format!(
                        "{}",
                        LenError {
                            required_len: 1,
                            layer: Layer::Ipv4Header,
                            len: 2,
                            len_source: test.0,
                            layer_start_offset: 0
                        }
                    )
                );
            }
        }

        // start offset based test
        assert_eq!(
            "IPv4 Header Error: Length of 2 byte(s) is too big for an 'IPv4 header' (maximum is 1 bytes). The slice length was used to determine the length ('IPv4 header' starts at overall parsed byte 4).",
            format!(
                "{}",
                LenError{
                    required_len: 1,
                    len: 2,
                    len_source: LenSource::Slice,
                    layer: Layer::Ipv4Header,
                    layer_start_offset: 4
                }
            )
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(LenError {
            required_len: 0,
            len: 0,
            len_source: LenSource::Slice,
            layer: Layer::Ipv4Header,
            layer_start_offset: 0
        }
        .source()
        .is_none());
    }
}
