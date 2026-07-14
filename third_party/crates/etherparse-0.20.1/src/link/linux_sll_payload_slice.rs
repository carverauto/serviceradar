use crate::{EtherPayloadSlice, EtherType, LenSource, LinuxSllProtocolType};

/// Payload of Linux Cooked Capture v1 (SLL) packet
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct LinuxSllPayloadSlice<'a> {
    /// Identifying content of the payload.
    pub protocol_type: LinuxSllProtocolType,

    /// Payload
    pub payload: &'a [u8],
}

impl<'a> From<EtherPayloadSlice<'a>> for LinuxSllPayloadSlice<'a> {
    fn from(value: EtherPayloadSlice<'a>) -> LinuxSllPayloadSlice<'a> {
        LinuxSllPayloadSlice {
            protocol_type: LinuxSllProtocolType::EtherType(value.ether_type),
            payload: value.payload,
        }
    }
}

impl<'a> TryFrom<LinuxSllPayloadSlice<'a>> for EtherPayloadSlice<'a> {
    type Error = ();

    fn try_from(value: LinuxSllPayloadSlice<'a>) -> Result<EtherPayloadSlice<'a>, Self::Error> {
        match value.protocol_type {
            LinuxSllProtocolType::LinuxNonstandardEtherType(nonstandard_ether_type) => {
                Ok(EtherPayloadSlice {
                    ether_type: EtherType(nonstandard_ether_type.into()),
                    len_source: LenSource::Slice,
                    payload: value.payload,
                })
            }
            LinuxSllProtocolType::EtherType(ether_type) => Ok(EtherPayloadSlice {
                ether_type,
                len_source: LenSource::Slice,
                payload: value.payload,
            }),
            _ => Err(()),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn debug() {
        let s = LinuxSllPayloadSlice {
            protocol_type: LinuxSllProtocolType::EtherType(EtherType::IPV4),
            payload: &[],
        };
        assert_eq!(
            format!(
                "LinuxSllPayloadSlice {{ protocol_type: {:?}, payload: {:?} }}",
                s.protocol_type, s.payload
            ),
            format!("{:?}", s)
        );
    }

    #[test]
    fn clone_eq() {
        let s = LinuxSllPayloadSlice {
            protocol_type: LinuxSllProtocolType::EtherType(EtherType::IPV4),
            payload: &[],
        };
        assert_eq!(s.clone(), s);
    }
}
