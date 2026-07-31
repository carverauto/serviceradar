/// Echo Request & Response common parts between ICMPv4 and ICMPv6.
///
/// # RFC 4443 Description (ICMPv6)
///
/// Every node MUST implement an ICMPv6 Echo responder function that
/// receives Echo Requests and originates corresponding Echo Replies.  A
/// node SHOULD also implement an application-layer interface for
/// originating Echo Requests and receiving Echo Replies, for diagnostic
/// purposes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub struct IcmpEchoHeader {
    /// An identifier to aid in matching Echo Replies to Echo Requests. May be zero.
    pub id: u16,
    /// A sequence number to aid in matching Echo Replies to Echo Requests. May be zero.
    pub seq: u16,
}

impl IcmpEchoHeader {
    /// Serialized size of an IcmpEchoHeader header in bytes/octets.
    pub const LEN: usize = 4;

    /// Return the seq + id encoded to the on the wire format.
    #[inline]
    pub fn to_bytes(&self) -> [u8; 4] {
        let id_be = self.id.to_be_bytes();
        let seq_be = self.seq.to_be_bytes();
        [id_be[0], id_be[1], seq_be[0], seq_be[1]]
    }

    /// Decodes the seq + id from the on the wire format.
    #[inline]
    pub fn from_bytes(bytes5to8: [u8; 4]) -> IcmpEchoHeader {
        IcmpEchoHeader {
            id: u16::from_be_bytes([bytes5to8[0], bytes5to8[1]]),
            seq: u16::from_be_bytes([bytes5to8[2], bytes5to8[3]]),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::*;
    use alloc::format;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn to_bytes(
            id in any::<u16>(),
            seq in any::<u16>()
        ) {
            let id_bytes = id.to_be_bytes();
            let seq_bytes = seq.to_be_bytes();
            assert_eq!(
                IcmpEchoHeader{ id, seq }.to_bytes(),
                [
                    id_bytes[0], id_bytes[1],
                    seq_bytes[0], seq_bytes[1]
                ]
            );
        }

        #[test]
        fn from_bytes(
            bytes in any::<[u8;4]>()
        ) {
            assert_eq!(
                IcmpEchoHeader::from_bytes(bytes),
                IcmpEchoHeader {
                    id: u16::from_be_bytes([bytes[0], bytes[1]]),
                    seq: u16::from_be_bytes([bytes[2], bytes[3]])
                }
            );
        }

        #[test]
        fn clone_eq(
            id in any::<u16>(),
            seq in any::<u16>()
        ) {
            let value = IcmpEchoHeader{ id, seq };
            assert_eq!(value.clone(), value);
        }

        #[test]
        fn debug(
            id in any::<u16>(),
            seq in any::<u16>()
        ) {
            assert_eq!(
                format!("{:?}", IcmpEchoHeader{ id, seq }),
                format!("IcmpEchoHeader {{ id: {:?}, seq: {:?} }}", id, seq)
            );
        }
    }
}
