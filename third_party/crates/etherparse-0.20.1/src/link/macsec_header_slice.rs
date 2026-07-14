use crate::{
    err::{Layer, LenError},
    *,
};

/// Slice containing a MACsec header & next ether type (if possible).
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct MacsecHeaderSlice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> MacsecHeaderSlice<'a> {
    /// Try creating a [`MacsecHeaderSlice`] from a slice containing the
    /// MACsec header & next ether type.
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<MacsecHeaderSlice<'a>, err::macsec::HeaderSliceError> {
        use err::macsec::{HeaderError::*, HeaderSliceError::*};

        if slice.len() < 6 {
            return Err(Len(LenError {
                required_len: 6,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::MacsecHeader,
                layer_start_offset: 0,
            }));
        }

        // SAFETY: Safe as the length was verified to be at least 6.
        let tci_an = unsafe { slice.get_unchecked(0) };

        // validate version
        if 0 != tci_an & 0b1000_0000 {
            return Err(Content(UnexpectedVersion));
        }

        // validate short_len is not 1 in the unmodified case
        let unmodified = 0 == tci_an & 0b1100;
        if unmodified {
            // SAFETY: Safe as the length was verified to be at least 6.
            let short_len = unsafe { slice.get_unchecked(1) & 0b0011_1111 };
            // short len must be zero (unknown) or at least 2 in unmod
            if short_len == 1 {
                return Err(Content(InvalidUnmodifiedShortLen));
            }
        }

        // get the encrypted, changed flag (check if ether_type can be parsed)
        let required_len =
            6 + if unmodified { 2 } else { 0 } + if 0 != tci_an & 0b10_0000 { 8 } else { 0 };

        if slice.len() < required_len {
            return Err(Len(LenError {
                required_len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::MacsecHeader,
                layer_start_offset: 0,
            }));
        }

        Ok(MacsecHeaderSlice {
            // SAFETY: Safe as the length was previously verified to be at least required_len.
            slice: unsafe { core::slice::from_raw_parts(slice.as_ptr(), required_len) },
        })
    }

    /// Slice containing the header & ether type of the next segment
    /// if available.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Raw first byte of the mac sec header (containing TCI & AN).
    #[inline]
    pub fn tci_an_raw(&self) -> u8 {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        unsafe { *self.slice.get_unchecked(0) }
    }

    /// End station identifier (TCI.ES flag).
    #[inline]
    pub fn endstation_id(&self) -> bool {
        0 != (self.tci_an_raw() & 0b100_0000)
    }

    /// Ethernet passive optical network broadcast flag.
    #[inline]
    pub fn tci_scb(&self) -> bool {
        0 != (self.tci_an_raw() & 0b1_0000)
    }

    /// Encryption flag, which indicates whether the user data is
    /// encrypted (true = encrypted, TCI.E flag).
    #[inline]
    pub fn encrypted(&self) -> bool {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        0 != (self.tci_an_raw() & 0b1000)
    }

    /// Flag for change text, set if the user data is modified.
    #[inline]
    pub fn userdata_changed(&self) -> bool {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        0 != (self.tci_an_raw() & 0b100)
    }

    /// True if the payload was neither flagged as modified or encrypted.
    #[inline]
    pub fn is_unmodified(&self) -> bool {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        0 == (self.tci_an_raw() & 0b1100)
    }

    /// Payload type (contains encryption, modification flag as
    /// well as the next ether type if available)
    #[inline]
    pub fn ptype(&self) -> MacsecPType {
        let e = self.encrypted();
        let c = self.userdata_changed();
        if e {
            if c {
                MacsecPType::Encrypted
            } else {
                MacsecPType::EncryptedUnmodified
            }
        } else if c {
            MacsecPType::Modified
        } else if 0 != (self.tci_an_raw() & 0b10_0000) {
            // SAFETY: Slice access safe as length of the slice was
            //         verified in the constructor to be at least 16
            //         if 0b10_0000 is set and and 'c' and 'e' are not
            //         set in the tci_an_raw.
            MacsecPType::Unmodified(EtherType(u16::from_be_bytes(unsafe {
                [*self.slice.get_unchecked(14), *self.slice.get_unchecked(15)]
            })))
        } else {
            // SAFETY: Slice access safe as length of the slice was
            //         verified in the constructor to be at least 8
            //         if 0b10_0000 is not set and 'c' and 'e' are not
            //         set in the tci_an_raw.
            MacsecPType::Unmodified(EtherType(u16::from_be_bytes(unsafe {
                [*self.slice.get_unchecked(6), *self.slice.get_unchecked(7)]
            })))
        }
    }

    /// Association number (identifies SAs).
    #[inline]
    pub fn an(&self) -> MacsecAn {
        // SAFETY: MacSecAn conversion safe as bit-masked to only
        //         contain 2 bits.
        unsafe { MacsecAn::new_unchecked(self.tci_an_raw() & 0b11) }
    }

    /// Short length with reserved bits.
    #[inline]
    pub fn short_len(&self) -> MacsecShortLen {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        //         MacsecSl conversion safe as bit-masked to contain
        //         only 6 bits.
        unsafe { MacsecShortLen::from_u8_unchecked(self.slice.get_unchecked(1) & 0b0011_1111) }
    }

    /// Packet number.
    #[inline]
    pub fn packet_nr(&self) -> u32 {
        // SAFETY: Slice access safe as length of the slice was
        //         verified in the constructor to be at least 6.
        //         MacsecSl conversion safe as bit-masked.
        u32::from_be_bytes(unsafe {
            [
                *self.slice.get_unchecked(2),
                *self.slice.get_unchecked(3),
                *self.slice.get_unchecked(4),
                *self.slice.get_unchecked(5),
            ]
        })
    }

    /// True if the SCI bit is set in the TCI part of the SecTag header.
    #[inline]
    pub fn sci_present(&self) -> bool {
        0 != (self.tci_an_raw() & 0b10_0000)
    }

    /// Secure channel identifier.
    #[inline]
    pub fn sci(&self) -> Option<u64> {
        if self.sci_present() {
            // SAFETY: Slice access safe as length of the slice was
            //         verified in the constructor to be at least 14
            //         if 0b10_0000 is set in the tci_an_raw.
            Some(u64::from_be_bytes(unsafe {
                [
                    *self.slice.get_unchecked(6),
                    *self.slice.get_unchecked(7),
                    *self.slice.get_unchecked(8),
                    *self.slice.get_unchecked(9),
                    *self.slice.get_unchecked(10),
                    *self.slice.get_unchecked(11),
                    *self.slice.get_unchecked(12),
                    *self.slice.get_unchecked(13),
                ]
            }))
        } else {
            None
        }
    }

    /// Ether type of the data following the sec tag (only
    /// available if not encrypted and userdata is not flagged
    /// as modified).
    #[inline]
    pub fn next_ether_type(&self) -> Option<EtherType> {
        if 0 != self.tci_an_raw() & 0b1100 {
            None
        } else if self.sci_present() {
            // SAFETY: Slice access safe as length of the slice was
            //         verified in the constructor to be at least 16
            //         if 0b10_0000 is set and 0b1100 is not set in
            //         the tci_an_raw.
            Some(EtherType(u16::from_be_bytes(unsafe {
                [*self.slice.get_unchecked(14), *self.slice.get_unchecked(15)]
            })))
        } else {
            // SAFETY: Slice access safe as length of the slice was
            //         verified in the constructor to be at least 8
            //         if 0b10_0000 is not set and 0b1100 is not set in
            //         the tci_an_raw.
            Some(EtherType(u16::from_be_bytes(unsafe {
                [*self.slice.get_unchecked(6), *self.slice.get_unchecked(7)]
            })))
        }
    }

    /// Length of the MACsec header (SecTag + next ether type if available).
    #[inline]
    pub fn header_len(&self) -> usize {
        6 + if self.sci_present() { 8 } else { 0 } + if self.is_unmodified() { 2 } else { 0 }
    }

    /// Returns the required length of the payload (data after header +
    /// next_ether_type if present) if possible.
    ///
    /// If the length cannot be determined (`short_len` is zero or less then
    /// `2` when `ptype` `Unmodified`) `None` is returned.
    #[inline]
    pub fn expected_payload_len(&self) -> Option<usize> {
        let sl = self.short_len().value() as usize;
        if sl > 0 {
            if 0 != self.tci_an_raw() & 0b1100 {
                // no ether type (encrypted and/or modified payload)
                Some(sl)
            } else if sl < 2 {
                None
            } else {
                Some(sl - 2)
            }
        } else {
            None
        }
    }

    /// Decodes all MacSecHeader values and returns them as a
    /// [`crate::MacsecHeader`].
    #[inline]
    pub fn to_header(&self) -> MacsecHeader {
        MacsecHeader {
            ptype: self.ptype(),
            endstation_id: self.endstation_id(),
            scb: self.tci_scb(),
            an: self.an(),
            short_len: self.short_len(),
            packet_nr: self.packet_nr(),
            sci: self.sci(),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use arrayvec::ArrayVec;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice(
            macsec in macsec_any(),
            ether_type in ether_type_any(),
            sci in any::<u64>()
        ) {
            use MacsecPType::*;
            use err::macsec::*;

            // variants
            for ptype in [Unmodified(ether_type), Modified, Encrypted, EncryptedUnmodified] {
                for has_sci in [false, true] {
                    let mut macsec = macsec.clone();
                    macsec.ptype = ptype;
                    macsec.sci = if has_sci {
                        Some(sci)
                    } else {
                        None
                    };
                    if matches!(ptype, MacsecPType::Unmodified(_)) && macsec.short_len.value() == 1 {
                        macsec.short_len = MacsecShortLen::ZERO;
                    }

                    // ok case
                    {
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                        bytes.try_extend_from_slice(&[1]).unwrap();
                        let m = MacsecHeaderSlice::from_slice(&bytes).unwrap();
                        assert_eq!(m.to_header(), macsec);
                        assert_eq!(m.slice(), &bytes[..bytes.len() - 1]);
                    }

                    // version error
                    {
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                        bytes.try_extend_from_slice(&[1]).unwrap();

                        // version bit
                        bytes[0] = bytes[0] | 0b1000_0000;

                        let m = MacsecHeaderSlice::from_slice(&bytes);
                        assert_eq!(m, Err(HeaderSliceError::Content(HeaderError::UnexpectedVersion)));
                    }

                    // short len error
                    if matches!(ptype, MacsecPType::Unmodified(_)) {
                        let mut macsec = macsec.clone();
                        macsec.short_len = MacsecShortLen::try_from_u8(1).unwrap();
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                        bytes.try_extend_from_slice(&[1]).unwrap();

                        let m = MacsecHeaderSlice::from_slice(&bytes);
                        assert_eq!(m, Err(HeaderSliceError::Content(HeaderError::InvalidUnmodifiedShortLen)));
                    }

                    // len error
                    for len in 0..macsec.header_len() {
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                        bytes.try_extend_from_slice(&[1]).unwrap();

                        let m = MacsecHeaderSlice::from_slice(&bytes[..len]);
                        assert_eq!(
                            m,
                            Err(HeaderSliceError::Len(err::LenError{
                                required_len: if len < 6 {
                                    6
                                } else {
                                    macsec.header_len()
                                },
                                len,
                                len_source: LenSource::Slice,
                                layer: Layer::MacsecHeader,
                                layer_start_offset: 0,
                            }))
                        );
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn expected_payload_len(
            header in macsec_any(),
            ether_type in ether_type_any(),
            valid_unmodified_len in 2u8..=MacsecShortLen::MAX_U8,
            valid_modified_len in 1u8..=MacsecShortLen::MAX_U8
        ) {
            // unmodified, payload len (non zero or one)
            {
                let mut header = header.clone();
                header.ptype = MacsecPType::Unmodified(ether_type);
                header.short_len = MacsecShortLen::try_from_u8(valid_unmodified_len).unwrap();
                let bytes = header.to_bytes();
                let slice = MacsecHeaderSlice::from_slice(&bytes).unwrap();
                assert_eq!(Some(valid_unmodified_len as usize - 2), slice.expected_payload_len());
            }

            // unmodified, unknown len
            for short_len in 0..2u8 {
                let mut header = header.clone();
                header.ptype = MacsecPType::Unmodified(ether_type);
                header.short_len = MacsecShortLen::try_from_u8(short_len).unwrap();
                let bytes = header.to_bytes();
                let slice = MacsecHeaderSlice{ slice: &bytes };
                assert_eq!(None, slice.expected_payload_len());
            }

            // modified, valid payload len (non zero)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.short_len = MacsecShortLen::try_from_u8(valid_modified_len).unwrap();
                let bytes = header.to_bytes();
                let slice = MacsecHeaderSlice::from_slice(&bytes).unwrap();
                assert_eq!(Some(valid_modified_len as usize), slice.expected_payload_len());
            }

            // modified, unknown len
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.short_len = MacsecShortLen::ZERO;
                let bytes = header.to_bytes();
                let slice = MacsecHeaderSlice::from_slice(&bytes).unwrap();
                assert_eq!(None, slice.expected_payload_len());
            }
        }
    }
}
