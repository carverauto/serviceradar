use crate::{
    err::{macsec, Layer, LenError},
    *,
};

/// MACsec packet (SecTag header & payload).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MacsecSlice<'a> {
    pub header: MacsecHeaderSlice<'a>,
    pub payload: MacsecPayloadSlice<'a>,
}

impl<'a> MacsecSlice<'a> {
    pub fn from_slice(slice: &'a [u8]) -> Result<MacsecSlice<'a>, macsec::HeaderSliceError> {
        use macsec::HeaderSliceError::Len;

        let header = MacsecHeaderSlice::from_slice(slice)?;

        // validate the length of the slice if the short length is set
        let (payload_slice, len_source) =
            if let Some(req_payload_len) = header.expected_payload_len() {
                let required_len = header.slice().len() + req_payload_len;
                if slice.len() < required_len {
                    return Err(Len(LenError {
                        required_len,
                        len: slice.len(),
                        len_source: LenSource::MacsecShortLength,
                        layer: Layer::MacsecPacket,
                        layer_start_offset: 0,
                    }));
                }
                // SAFETY: Safe as the length was verified above to be at least required_len.
                (
                    unsafe {
                        core::slice::from_raw_parts(
                            slice.as_ptr().add(header.slice().len()),
                            req_payload_len,
                        )
                    },
                    LenSource::MacsecShortLength,
                )
            } else {
                // SAFETY: Safe as the header is a subslice of the original slice.
                (
                    unsafe {
                        core::slice::from_raw_parts(
                            slice.as_ptr().add(header.slice().len()),
                            slice.len() - header.slice().len(),
                        )
                    },
                    LenSource::Slice,
                )
            };

        let payload = if let Some(ether_type) = header.next_ether_type() {
            MacsecPayloadSlice::Unmodified(EtherPayloadSlice {
                ether_type,
                len_source,
                payload: payload_slice,
            })
        } else {
            MacsecPayloadSlice::Modified(payload_slice)
        };

        Ok(MacsecSlice { header, payload })
    }

    /// Get the ether payload if the macsec packet is unencrypted & unmodified.
    pub fn ether_payload(&self) -> Option<EtherPayloadSlice<'a>> {
        if let MacsecPayloadSlice::Unmodified(e) = &self.payload {
            Some(e.clone())
        } else {
            None
        }
    }

    /// Get the ether type of the payload if the macsec packet is unencrypted & unmodified.
    pub fn next_ether_type(&self) -> Option<EtherType> {
        self.header.next_ether_type()
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{err::LenError, test_gens::*};
    use arrayvec::ArrayVec;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice(
            macsec in macsec_any(),
            ethertype in ether_type_any(),
            non_zero_sl_unmodified in 3u8..=0b0011_1111,
            non_zero_sl_modified in 1u8..=0b0011_1111
        ) {
            // macsec (unmodified, complete, nonzero short length)
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.short_len = MacsecShortLen::try_from(non_zero_sl_unmodified).unwrap();

                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize}>::new();
                for v in 0..(non_zero_sl_unmodified - 2) {
                    payload.push(v);
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes).unwrap();
                assert_eq!(
                    m.payload,
                    MacsecPayloadSlice::Unmodified(EtherPayloadSlice{
                        ether_type: ethertype,
                        len_source: LenSource::MacsecShortLength,
                        payload: &payload
                    })
                );
                assert_eq!(
                    m.ether_payload(),
                    Some(EtherPayloadSlice{
                        ether_type: ethertype,
                        len_source: LenSource::MacsecShortLength,
                        payload: &payload
                    })
                );
                assert_eq!(m.next_ether_type(), Some(ethertype));
            }
            // macsec (incomplete, nonzero short length)
            for ptype in [MacsecPType::Unmodified(ethertype), MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize}>::new();
                if matches!(ptype, MacsecPType::Unmodified(_)) {
                    macsec.short_len = MacsecShortLen::try_from(non_zero_sl_unmodified).unwrap();
                    for v in 0..non_zero_sl_unmodified-3 {
                        payload.push(v);
                    }
                } else {
                    macsec.short_len = MacsecShortLen::try_from(non_zero_sl_modified).unwrap();
                    for v in 0..non_zero_sl_modified-1 {
                        payload.push(v);
                    }
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes);
                assert_eq!(
                    m,
                    Err(macsec::HeaderSliceError::Len(LenError{
                        required_len: if matches!(ptype, MacsecPType::Unmodified(_)) {
                            macsec.header_len() + non_zero_sl_unmodified as usize  - 2
                        } else {
                            macsec.header_len() + non_zero_sl_modified as usize
                        },
                        len: bytes.len(),
                        len_source: LenSource::MacsecShortLength,
                        layer: err::Layer::MacsecPacket,
                        layer_start_offset: 0
                    }))
                );
            }
            // macsec (unmodified, zero short length)
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.short_len = MacsecShortLen::ZERO;

                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + 1}>::new();
                for v in 0..non_zero_sl_unmodified+1 {
                    payload.push(v);
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN + 1}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes).unwrap();
                assert_eq!(
                    m.payload,
                    MacsecPayloadSlice::Unmodified(EtherPayloadSlice{
                        ether_type: ethertype,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })
                );
                assert_eq!(
                    m.ether_payload(),
                    Some(EtherPayloadSlice{
                        ether_type: ethertype,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })
                );
                assert_eq!(m.next_ether_type(), Some(ethertype));
            }
            // macsec (modified, complete, nonzero short length)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                macsec.short_len = MacsecShortLen::try_from(non_zero_sl_modified).unwrap();

                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize}>::new();
                for v in 0..non_zero_sl_modified {
                    payload.push(v);
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes).unwrap();
                assert_eq!(
                    m.payload,
                    MacsecPayloadSlice::Modified(&payload),
                );
                assert_eq!(m.ether_payload(), None);
                assert_eq!(m.next_ether_type(), None);
            }
            // macsec (modified, incomplete, nonzero short length)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                macsec.short_len = MacsecShortLen::try_from(non_zero_sl_modified).unwrap();

                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize}>::new();
                for v in 0..non_zero_sl_modified-1 {
                    payload.push(v);
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes);
                assert_eq!(
                    m,
                    Err(macsec::HeaderSliceError::Len(LenError{
                        required_len: macsec.header_len() + non_zero_sl_modified as usize,
                        len: bytes.len(),
                        len_source: LenSource::MacsecShortLength,
                        layer: err::Layer::MacsecPacket,
                        layer_start_offset: 0
                    }))
                );
            }
            // macsec (modified, zero short length)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                macsec.short_len = MacsecShortLen::ZERO;

                let mut payload = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + 1}>::new();
                for v in 0..non_zero_sl_modified+1 {
                    payload.push(v);
                }

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN + 1}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let m = MacsecSlice::from_slice(&bytes).unwrap();
                assert_eq!(
                    m.payload,
                    MacsecPayloadSlice::Modified(&payload)
                );
                assert_eq!(m.ether_payload(), None);
                assert_eq!(m.next_ether_type(), None);
            }
            // header parse error
            for ptype in [MacsecPType::Unmodified(ethertype), MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                macsec.short_len = MacsecShortLen::ZERO;

                let mut bytes = ArrayVec::<u8, {MacsecShortLen::MAX_U8 as usize + MacsecHeader::MAX_LEN + 1}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                let m = MacsecSlice::from_slice(&bytes[..bytes.len() - 1]);
                assert_eq!(
                    m,
                    Err(macsec::HeaderSliceError::Len(LenError{
                        required_len: macsec.header_len(),
                        len: macsec.header_len() - 1,
                        len_source: LenSource::Slice,
                        layer: err::Layer::MacsecHeader,
                        layer_start_offset: 0
                    }))
                );
            }
        }
    }
}
