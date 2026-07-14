//! Support for indefinite lengths as used by ASN.1 BER and described in X.690 Section 8.1.3.6:
//!
//! > 8.1.3.6 For the indefinite form, the length octets indicate that the
//! > contents octets are terminated by end-of-contents
//! > octets (see 8.1.5), and shall consist of a single octet.
//! >
//! > 8.1.3.6.1 The single octet shall have bit 8 set to one, and bits 7 to
//! > 1 set to zero.
//! >
//! > 8.1.3.6.2 If this form of length is used, then end-of-contents octets
//! > (see 8.1.5) shall be present in the encoding following the contents
//! > octets.
//! >
//! > [...]
//! >
//! > 8.1.5 End-of-contents octets
//! > The end-of-contents octets shall be present if the length is encoded as specified in 8.1.3.6,
//! > otherwise they shall not be present.
//! >
//! > The end-of-contents octets shall consist of two zero octets.

use crate::{Decode, ErrorKind, Header, Length, Reader};

#[cfg(feature = "alloc")]
use crate::Tag;

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

/// The end-of-contents octets can be considered as the encoding of a value whose tag is
/// universal class, whose form is primitive, whose number of the tag is zero, and whose
/// contents are absent.
const EOC_TAG: u8 = 0x00;

/// Decode TLV records until an end-of-contents marker (`00 00`) is found, computing the
/// resulting length based on the amount of data decoded.
pub(super) fn decode_indefinite_length<'a>(reader: &mut impl Reader<'a>) -> crate::Result<Length> {
    let start_pos = reader.position();

    loop {
        // Look for the end-of-contents marker
        if reader.peek_byte() == Some(EOC_TAG) {
            read_eoc(reader)?;

            // Compute how much we read and flag the decoded length as indefinite
            let mut ret = (reader.position() - start_pos)?;
            ret.indefinite = true;
            return Ok(ret);
        }

        let header = Header::decode(reader)?;
        reader.drain(header.length())?;
    }
}

/// Read an expected end-of-contents (EOC) marker: `00 00`.
///
/// # Errors
///
/// - Returns `ErrorKind::IndefiniteLength` if the EOC marker isn't present as expected.
pub(crate) fn read_eoc<'a>(reader: &mut impl Reader<'a>) -> crate::Result<()> {
    for _ in 0..Length::EOC_LEN.inner as usize {
        if reader.read_byte()? != 0 {
            return Err(reader.error(ErrorKind::IndefiniteLength));
        }
    }

    Ok(())
}

/// Read a constructed value into a [`Vec`], removing intermediate headers and assembling the result
/// into a single contiguous bytestring.
///
/// The end-of-content marker is not handled by this function. Instead, it's expected for this to
/// be called with a nested reader which ends immediately before the EOC.
#[cfg(feature = "alloc")]
pub(crate) fn read_constructed_vec<'r, R: Reader<'r>>(
    reader: &mut R,
    length: Length,
    inner_tag: Tag,
) -> crate::Result<Vec<u8>> {
    if !length.is_indefinite() {
        return Err(reader.error(ErrorKind::IndefiniteLength));
    }

    let mut bytes = Vec::with_capacity(length.try_into()?);
    let mut offset = 0;

    while !reader.is_finished() {
        let h = Header::decode(reader)?;
        h.tag().assert_eq(inner_tag)?;

        // This constructed string is ‘recursively constructed’
        // as one of its segments is itself encoded with
        // constructed, indefinite-length method.
        // This is currently chosen to be unsupported.
        //
        // See discussion:
        //   - https://github.com/RustCrypto/formats/issues/779#issuecomment-3049589340
        if h.length().is_indefinite() {
            return Err(reader.error(ErrorKind::IndefiniteLength));
        }

        // Add enough zeroes into the `Vec` to store the chunk
        let l = usize::try_from(h.length())?;
        bytes.extend(core::iter::repeat_n(0, l));
        reader.read_into(&mut bytes[offset..(offset + l)])?;
        offset += l;
    }

    Ok(bytes)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use crate::{Decode, EncodingRules, Length, Reader, SliceReader, Tag};
    use hex_literal::hex;

    #[test]
    fn decode() {
        /// Length of example in octets.
        const EXAMPLE_LEN: usize = 68;

        /// Test vector from: <https://github.com/RustCrypto/formats/issues/779#issuecomment-2902948789>
        ///
        /// Notably this example contains nested indefinite lengths to ensure the decoder handles
        /// them correctly.
        const EXAMPLE_BER: [u8; EXAMPLE_LEN] = hex!(
            "30 80 06 09 2A 86 48 86 F7 0D 01 07 01
             30 1D 06 09 60 86 48 01 65 03 04 01 2A 04 10 37
             34 3D F1 47 0D F6 25 EE B6 F4 BF D2 F1 AC C3 A0
             80 04 10 CC 74 AD F6 5D 97 3C 8B 72 CD 51 E1 B9
             27 F0 F0 00 00 00 00"
        );

        // Ensure the indefinite bit isn't set when decoding DER
        assert!(!Length::from_der(&[0x00]).unwrap().indefinite);

        let mut reader =
            SliceReader::new_with_encoding_rules(&EXAMPLE_BER, EncodingRules::Ber).unwrap();

        // Decode initial tag of the message, leaving the reader at the length
        let tag = Tag::decode(&mut reader).unwrap();
        assert_eq!(tag, Tag::Sequence);

        // Decode indefinite length
        let length = Length::decode(&mut reader).unwrap();
        assert!(length.is_indefinite());

        // Decoding the length should leave the position at the end of the indefinite length octet
        let pos = usize::try_from(reader.position()).unwrap();
        assert_eq!(pos, 2);

        // The first two bytes are the header and the rest is the length of the message.
        // The last four are two end-of-content markers (2 * 2 bytes).
        assert_eq!(usize::try_from(length).unwrap(), EXAMPLE_LEN - pos);

        // Read OID
        reader.tlv_bytes().unwrap();
        // Read SEQUENCE
        reader.tlv_bytes().unwrap();

        // We're now at the next indefinite length record
        let tag = Tag::decode(&mut reader).unwrap();
        assert_eq!(
            tag,
            Tag::ContextSpecific {
                constructed: true,
                number: 0u32.into()
            }
        );

        // Parse the inner indefinite length
        let length = Length::decode(&mut reader).unwrap();
        assert!(length.is_indefinite());
        assert_eq!(usize::try_from(length).unwrap(), 20);
    }
}
