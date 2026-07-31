/// A ICMPv4 timestamp or timestamp response message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimestampMessage {
    pub id: u16,
    pub seq: u16,
    pub originate_timestamp: u32,
    pub receive_timestamp: u32,
    pub transmit_timestamp: u32,
}

impl TimestampMessage {
    /// Deprecated use [`TimestampMessage::LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Use `TimestampMessage::LEN` instead")]
    pub const SERIALIZED_SIZE: usize = 20;

    /// The size in bytes/octets of a timestamp request or timestamp response message.
    pub const LEN: usize = 20;

    /// Decodes the timestamp message part of an ICMPv4 message.
    pub fn from_bytes(bytes: [u8; 16]) -> TimestampMessage {
        TimestampMessage {
            id: u16::from_be_bytes([bytes[0], bytes[1]]),
            seq: u16::from_be_bytes([bytes[2], bytes[3]]),
            originate_timestamp: u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
            receive_timestamp: u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]),
            transmit_timestamp: u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::icmpv4::*;
    use alloc::format;
    use proptest::prelude::*;

    #[test]
    fn constants() {
        assert_eq!(20, TimestampMessage::LEN);
    }

    proptest! {
        #[test]
        fn from_bytes(bytes in any::<[u8;16]>()) {
            assert_eq!(
                TimestampMessage::from_bytes(bytes),
                TimestampMessage{
                    id: u16::from_be_bytes([bytes[0], bytes[1]]),
                    seq: u16::from_be_bytes([bytes[2], bytes[3]]),
                    originate_timestamp: u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
                    receive_timestamp: u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]),
                    transmit_timestamp: u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
                }
            );
        }
    }

    #[test]
    fn clone_eq() {
        let v = TimestampMessage {
            id: 0,
            seq: 0,
            originate_timestamp: 0,
            receive_timestamp: 0,
            transmit_timestamp: 0,
        };
        assert_eq!(v.clone(), v);
    }

    #[test]
    fn debug() {
        let v = TimestampMessage {
            id: 0,
            seq: 0,
            originate_timestamp: 0,
            receive_timestamp: 0,
            transmit_timestamp: 0,
        };
        assert_eq!(
            format!("{:?}", v),
            format!(
                "TimestampMessage {{ id: {:?}, seq: {:?}, originate_timestamp: {:?}, receive_timestamp: {:?}, transmit_timestamp: {:?} }}",
                v.id,
                v.seq,
                v.originate_timestamp,
                v.receive_timestamp,
                v.transmit_timestamp,
            )
        );
    }
}
