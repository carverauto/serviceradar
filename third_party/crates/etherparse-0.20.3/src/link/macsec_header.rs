use crate::*;
use arrayvec::ArrayVec;

/// MACsec SecTag header (present at the start of a
/// packet capsuled with MACsec).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MacsecHeader {
    /// Payload type (contains encryption, modification flag as
    /// well as the next ether type if available)
    pub ptype: MacsecPType,

    /// End station identifier (TCI.ES flag).
    pub endstation_id: bool,

    /// Ethernet passive optical network broadcast flag.
    pub scb: bool,

    /// Association number (identifies SAs).
    pub an: MacsecAn,

    /// Short length with reserved bits.
    pub short_len: MacsecShortLen,

    /// Packet number.
    pub packet_nr: u32,

    /// Secure channel identifier.
    pub sci: Option<u64>,
}

impl MacsecHeader {
    /// Minimum length of an MacSec header in bytes/octets.
    pub const MIN_LEN: usize = 6;

    /// Maximum length of an MacSec header (including ether type of payload) in bytes/octets.
    pub const MAX_LEN: usize = 16;

    /// Encryption flag, which indicates whether the user data is
    /// encrypted (true = encrypted, TCI.E flag).
    #[inline]
    pub fn encrypted(&self) -> bool {
        use MacsecPType::*;
        matches!(self.ptype, Encrypted | EncryptedUnmodified)
    }

    /// Flag for change text, set if the user data is modified.
    pub fn userdata_changed(&self) -> bool {
        use MacsecPType::*;
        matches!(self.ptype, Encrypted | Modified)
    }

    /// Ether type of the data following the mac sec tag.
    pub fn next_ether_type(&self) -> Option<EtherType> {
        if let MacsecPType::Unmodified(re) = self.ptype {
            Some(re)
        } else {
            None
        }
    }

    /// Try creating a [`MacsecHeaderSlice`] from a slice containing the
    /// MACsec header & next ether type.
    pub fn from_slice(slice: &[u8]) -> Result<MacsecHeader, err::macsec::HeaderSliceError> {
        MacsecHeaderSlice::from_slice(slice).map(|v| v.to_header())
    }

    /// Serialize the mac sec header.
    pub fn to_bytes(&self) -> ArrayVec<u8, { MacsecHeader::MAX_LEN }> {
        // tci-an is composed of:
        //       ---------------------------------------
        //       | v | es | sc | scp | e | c | an | an |
        //       ---------------------------------------
        // bits    8   7    6     5    4   3    2    1
        //
        // - version (0)
        // - es (end station identifier bit)
        // - sc (SCI present bit)
        // - scp (Ethernet passive optical network broadcast bit)
        // - e (encryption bit)
        // - c (user data change bit)
        // - an (Association number) [2 bits]
        let tci_an = (self.an.value() & 0b11)
            | if self.userdata_changed() { 0b100 } else { 0 }
            | if self.encrypted() { 0b1000 } else { 0 }
            | if self.scb { 0b1_0000 } else { 0 }
            | if self.sci.is_some() { 0b10_0000 } else { 0 }
            | if self.endstation_id { 0b100_0000 } else { 0 };
        let pn_be = self.packet_nr.to_be_bytes();
        let sci_be = self.sci.unwrap_or(0).to_be_bytes();
        let et_be = if let MacsecPType::Unmodified(e) = self.ptype {
            e.0
        } else {
            0
        }
        .to_be_bytes();
        let mut result: ArrayVec<u8, { MacsecHeader::MAX_LEN }> = if self.sci.is_some() {
            [
                tci_an,
                self.short_len.value() & 0b0011_1111,
                pn_be[0],
                pn_be[1],
                pn_be[2],
                pn_be[3],
                sci_be[0],
                sci_be[1],
                sci_be[2],
                sci_be[3],
                sci_be[4],
                sci_be[5],
                sci_be[6],
                sci_be[7],
                et_be[0],
                et_be[1],
            ]
        } else {
            [
                tci_an,
                self.short_len.value() & 0b0011_1111,
                pn_be[0],
                pn_be[1],
                pn_be[2],
                pn_be[3],
                et_be[0],
                et_be[1],
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            ]
        }
        .into();
        // SAFETY: Safe as the maximum size of 16 can not be exceeded.
        unsafe {
            result.set_len(
                6 + if self.sci.is_some() { 8 } else { 0 }
                    + if matches!(self.ptype, MacsecPType::Unmodified(_)) {
                        2
                    } else {
                        0
                    },
            );
        }
        result
    }

    /// Try reading a MACsec header from the position of the reader.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + Sized>(
        reader: &mut T,
    ) -> Result<MacsecHeader, err::macsec::HeaderReadError> {
        use err::macsec::HeaderError::*;
        use err::macsec::HeaderReadError::*;

        let mut bytes = [0; MacsecHeader::MAX_LEN];
        reader.read_exact(&mut bytes[..6]).map_err(Io)?;

        // check version bit
        let tci_an = bytes[0];
        if 0 != tci_an & 0b1000_0000 {
            return Err(Content(UnexpectedVersion));
        }

        // validate short_len is not 1 in the unmodified case
        let unmodified = 0 == tci_an & 0b1100;
        if unmodified {
            // SAFETY: Safe as the length was verified to be at least 6.
            let short_len = bytes[1] & 0b0011_1111;
            // short len must be zero (unknown) or at least 2 in case of an
            // unmodified payload
            if short_len == 1 {
                return Err(Content(InvalidUnmodifiedShortLen));
            }
        }

        // get the encrypted, changed flag (check if ether_type can be parsed)
        let required_len =
            6 + if unmodified { 2 } else { 0 } + if 0 != tci_an & 0b10_0000 { 8 } else { 0 };

        if required_len > 6 {
            reader.read_exact(&mut bytes[6..required_len]).map_err(Io)?;
        }

        Ok(MacsecHeaderSlice {
            slice: &bytes[..required_len],
        }
        .to_header())
    }

    /// Writes a given MACsec header to the current position (SecTag & next
    /// ether type if available).
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Length of the MACsec header (SecTag + next ether type if available).
    #[inline]
    pub fn header_len(&self) -> usize {
        6 + if self.sci.is_some() { 8 } else { 0 }
            + if matches!(self.ptype, MacsecPType::Unmodified(_)) {
                2
            } else {
                0
            }
    }

    /// Returns the required length of the payload (data after header +
    /// next_ether_type if present) if possible.
    ///
    /// If the length cannot be determined (`short_len` is zero or less then
    /// `2` when `ptype` `Unmodified`) `None` is returned.
    #[inline]
    pub fn expected_payload_len(&self) -> Option<usize> {
        let sl = self.short_len.value() as usize;
        if sl > 0 {
            if matches!(self.ptype, MacsecPType::Unmodified(_)) {
                if sl < 2 {
                    None
                } else {
                    Some(sl - 2)
                }
            } else {
                // no ether type (encrypted and/or modified payload)
                Some(sl)
            }
        } else {
            None
        }
    }

    /// Set the `short_len` field based on the given payload byte len
    /// (payload len excluding the ether_type if `ptype` `Unmodified`)
    /// based on the current `ptype`.
    #[inline]
    pub fn set_payload_len(&mut self, payload_len: usize) {
        if matches!(self.ptype, MacsecPType::Unmodified(_)) {
            if payload_len > MacsecShortLen::MAX_USIZE - 2 {
                self.short_len = MacsecShortLen::ZERO;
            } else {
                // SAFETY: Safe as payload_len + 2 <= MacsecShortLen::MAX_USIZE
                //         is guaranteed after the if above.
                self.short_len =
                    unsafe { MacsecShortLen::from_u8_unchecked(payload_len as u8 + 2) };
            }
        } else if payload_len > MacsecShortLen::MAX_USIZE {
            self.short_len = MacsecShortLen::ZERO;
        } else {
            // SAFETY: Safe as payload_len + 2 <= MacsecShortLen::MAX_USIZE
            //         is guaranteed after the if above.
            self.short_len = unsafe { MacsecShortLen::from_u8_unchecked(payload_len as u8) };
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use proptest::prelude::*;
    use std::io::Cursor;

    proptest! {
        #[test]
        fn from_slice_to_bytes(
            header in macsec_any()
        ) {
            let mut header = header.clone();
            if matches!(header.ptype, MacsecPType::Unmodified(_)) && header.short_len.value() == 1 {
                header.short_len = MacsecShortLen::ZERO;
            }
            let bytes = header.to_bytes();
            let actual = MacsecHeader::from_slice(&bytes);
            assert_eq!(actual, Ok(header.clone()));
        }
    }

    proptest! {
        #[test]
        fn getter(
            macsec in macsec_any(),
            ethertype in ether_type_any(),
        ) {

            let tests = [
                // ptype, encrypted, userdata_changed, next_ether_type
                (MacsecPType::Unmodified(ethertype), false, false, Some(ethertype)),
                (MacsecPType::Modified, false, true, None),
                (MacsecPType::Encrypted, true, true, None),
                (MacsecPType::EncryptedUnmodified, true, false, None),
            ];

            for test in tests {
                let mut macsec = macsec.clone();
                macsec.ptype = test.0;

                assert_eq!(test.1, macsec.encrypted());
                assert_eq!(test.2, macsec.userdata_changed());
                assert_eq!(test.3, macsec.next_ether_type());
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(
            macsec in macsec_any(),
            ethertype in ether_type_any(),
            sci in any::<u64>(),
        ) {
            // no ethertype
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                // no sci
                {
                    let mut macsec = macsec.clone();
                    macsec.ptype = ptype;
                    macsec.sci = None;
                    assert_eq!(6, macsec.header_len());
                }
                // with sci
                {
                    let mut macsec = macsec.clone();
                    macsec.ptype = ptype;
                    macsec.sci = Some(sci);
                    assert_eq!(14, macsec.header_len());
                }
            }

            // with ethertype
            // no sci
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.sci = None;
                assert_eq!(8, macsec.header_len());
            }
            // with sci
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.sci = Some(sci);
                assert_eq!(16, macsec.header_len());
            }
        }
    }

    proptest! {
        #[test]
        fn read(
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
                        let mut cursor = Cursor::new(&bytes);
                        let m = MacsecHeader::read(&mut cursor).unwrap();
                        assert_eq!(m, macsec);
                        assert_eq!(macsec.header_len() as u64, cursor.position());
                    }

                    // version error
                    {
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                        bytes.try_extend_from_slice(&[1]).unwrap();

                        // version bit
                        bytes[0] = bytes[0] | 0b1000_0000;

                        let mut cursor = Cursor::new(&bytes);
                        let m = MacsecHeader::read(&mut cursor).unwrap_err();
                        assert_eq!(m.content_error(), Some(HeaderError::UnexpectedVersion));
                    }

                    // short len error
                    if matches!(ptype, MacsecPType::Unmodified(_)) {
                        let mut macsec = macsec.clone();
                        macsec.short_len = MacsecShortLen::try_from_u8(1).unwrap();
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();

                        let mut cursor = Cursor::new(&bytes);
                        let m = MacsecHeader::read(&mut cursor).unwrap_err();
                        assert_eq!(m.content_error(), Some(HeaderError::InvalidUnmodifiedShortLen));
                    }

                    // len error
                    for len in 0..macsec.header_len() {
                        let mut bytes = ArrayVec::<u8, { MacsecHeader::MAX_LEN + 1 }>::new();
                        bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();

                        let mut cursor = Cursor::new(&bytes[..len]);
                        let m = MacsecHeader::read(&mut cursor);
                        assert!(m.unwrap_err().io_error().is_some());
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn write(
            header in macsec_any()
        ) {
            // ok case
            {
                let mut buffer = ArrayVec::<u8, {MacsecHeader::MAX_LEN}>::new();
                header.write(&mut buffer).unwrap();
                assert_eq!(&buffer, &header.to_bytes());
            }
            // not enough memory
            {
                let mut buffer = [0u8;MacsecHeader::MAX_LEN];
                let mut cursor = Cursor::new(&mut buffer[..header.header_len() - 1]);
                header.write(&mut cursor).unwrap_err();
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
                assert_eq!(Some(valid_unmodified_len as usize - 2), header.expected_payload_len());
            }

            // unmodified, unknown len
            for short_len in 0..2u8 {
                let mut header = header.clone();
                header.ptype = MacsecPType::Unmodified(ether_type);
                header.short_len = MacsecShortLen::try_from_u8(short_len).unwrap();
                assert_eq!(None, header.expected_payload_len());
            }

            // modified, valid payload len (non zero)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.short_len = MacsecShortLen::try_from_u8(valid_modified_len).unwrap();
                assert_eq!(Some(valid_modified_len as usize), header.expected_payload_len());
            }

            // modified, unknown len
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.short_len = MacsecShortLen::ZERO;
                assert_eq!(None, header.expected_payload_len());
            }
        }
    }

    proptest! {
        #[test]
        fn set_payload_len(
            header in macsec_any(),
            ether_type in ether_type_any(),
            valid_unmodified_len in 0..=(MacsecShortLen::MAX_USIZE - 2),
            invalid_unmodified_len in (MacsecShortLen::MAX_USIZE - 1)..=usize::MAX,
            valid_modified_len in 1..=MacsecShortLen::MAX_USIZE,
            invalid_modified_len in (MacsecShortLen::MAX_USIZE + 1)..=usize::MAX
        ) {
            // unmodified, payload len (non zero or one)
            {
                let mut header = header.clone();
                header.ptype = MacsecPType::Unmodified(ether_type);
                header.set_payload_len(valid_unmodified_len);
                assert_eq!(header.short_len.value() as usize, valid_unmodified_len + 2);
            }

            // unmodified, invalid len
            {
                let mut header = header.clone();
                header.ptype = MacsecPType::Unmodified(ether_type);
                header.set_payload_len(invalid_unmodified_len);
                assert_eq!(0, header.short_len.value());
            }

            // modified, valid payload len (non zero)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.set_payload_len(valid_modified_len);
                assert_eq!(valid_modified_len, header.short_len.value() as usize);
            }

            // modified, unknown len
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut header = header.clone();
                header.ptype = ptype;
                header.set_payload_len(invalid_modified_len);
                assert_eq!(0, header.short_len.value());
            }
        }
    }
}
