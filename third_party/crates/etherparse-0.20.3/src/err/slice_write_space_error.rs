use crate::err::Layer;

/// Error when not enough space is available in a slice
/// to write a packet or header to it.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct SliceWriteSpaceError {
    /// Expected minimum length conflicting with the
    /// `actual_len` value.
    pub required_len: usize,

    /// Length limiting or exceeding the required length.
    pub len: usize,

    /// Layer in which could not be written to the slice.
    pub layer: Layer,

    /// Offset from the start of the parsed data to the layer where the
    /// length error occurred.
    pub layer_start_offset: usize,
}

impl core::fmt::Display for SliceWriteSpaceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if self.layer_start_offset > 0 {
            write!(
                f,
                "Not enough space to write {} to slice. Needed {} byte(s), but only {} byte(s) were available (start offset of {} write was {} byte(s)).",
                self.layer,
                self.required_len,
                self.len,
                self.layer,
                self.layer_start_offset
            )
        } else {
            write!(
                f,
                "Not enough space to write {} to slice. Needed {} byte(s), but only {} byte(s) were available.",
                self.layer,
                self.required_len,
                self.len,
            )
        }
    }
}

impl core::error::Error for SliceWriteSpaceError {
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
    fn debug() {
        assert_eq!(
            format!(
                "{:?}",
                SliceWriteSpaceError {
                    required_len: 2,
                    layer: Layer::Ipv4Header,
                    len: 1,
                    layer_start_offset: 0
                }
            ),
            format!(
                "SliceWriteSpaceError {{ required_len: {:?}, len: {:?}, layer: {:?}, layer_start_offset: {:?} }}",
                2, 1, Layer::Ipv4Header, 0
            ),
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = SliceWriteSpaceError {
            required_len: 2,
            layer: Layer::Icmpv4,
            len: 1,
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
        // layer_start_offset set
        assert_eq!(
            "Not enough space to write IPv4 header to slice. Needed 2 byte(s), but only 1 byte(s) were available (start offset of IPv4 header write was 4 byte(s)).",
            format!(
                "{}",
                SliceWriteSpaceError{
                    required_len: 2,
                    len: 1,
                    layer: Layer::Ipv4Header,
                    layer_start_offset: 4
                }
            )
        );

        // layer_start_offset zero
        assert_eq!(
            "Not enough space to write IPv4 header to slice. Needed 4 byte(s), but only 3 byte(s) were available.",
            format!(
                "{}",
                SliceWriteSpaceError{
                    required_len: 4,
                    len: 3,
                    layer: Layer::Ipv4Header,
                    layer_start_offset: 0
                }
            )
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(SliceWriteSpaceError {
            required_len: 0,
            len: 0,
            layer: Layer::Ipv4Header,
            layer_start_offset: 0
        }
        .source()
        .is_none());
    }
}
