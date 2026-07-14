/// Sources of length limiting values (e.g. "ipv6 payload length field").
#[derive(Copy, Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum LenSource {
    /// Limiting length was the slice length (we don't know what determined
    /// that one originally).
    Slice,
    /// Short length field in the MACsec header.
    MacsecShortLength,
    /// Length
    Ipv4HeaderTotalLen,
    /// Error occurred in the IPv6 layer.
    Ipv6HeaderPayloadLen,
    /// Error occurred while decoding an UDP header.
    UdpHeaderLen,
    /// Error occurred while decoding a TCP header.
    TcpHeaderLen,
    /// Error occurred while decoding a ARP packet.
    ArpAddrLengths,
}

#[cfg(test)]
mod test {
    use super::LenSource::*;
    use alloc::format;
    use std::{
        cmp::Ordering,
        collections::hash_map::DefaultHasher,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("Slice", format!("{:?}", Slice));
    }

    #[test]
    fn clone_eq_hash_ord() {
        let layer = Slice;
        assert_eq!(layer, layer.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            layer.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            layer.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
        assert_eq!(Ordering::Equal, layer.cmp(&layer));
        assert_eq!(Some(Ordering::Equal), layer.partial_cmp(&layer));
    }
}
