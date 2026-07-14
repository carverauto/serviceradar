//! Support for decoding/encoding [`Uint`] as an ASN.1 DER `INTEGER`.

use crate::{ArrayEncoding, Encoding, Limb, Uint, UintRef, hybrid_array::Array};
use ::der::{
    DecodeValue, EncodeValue, FixedTag, Length, Tag,
    asn1::{AnyRef, UintRef as Asn1UintRef},
};

impl<'a, const LIMBS: usize> TryFrom<AnyRef<'a>> for Uint<LIMBS>
where
    Uint<LIMBS>: ArrayEncoding,
{
    type Error = der::Error;

    fn try_from(any: AnyRef<'a>) -> der::Result<Uint<LIMBS>> {
        Asn1UintRef::try_from(any)?.try_into()
    }
}

impl<'a, const LIMBS: usize> TryFrom<Asn1UintRef<'a>> for Uint<LIMBS>
where
    Uint<LIMBS>: ArrayEncoding,
{
    type Error = der::Error;

    fn try_from(bytes: Asn1UintRef<'a>) -> der::Result<Uint<LIMBS>> {
        let mut array = Array::default();
        let offset = array.len().saturating_sub(bytes.len().try_into()?);
        array[offset..].copy_from_slice(bytes.as_bytes());
        Ok(Uint::from_be_byte_array(array))
    }
}

impl<'a, const LIMBS: usize> DecodeValue<'a> for Uint<LIMBS>
where
    Uint<LIMBS>: ArrayEncoding,
{
    type Error = der::Error;

    fn decode_value<R: der::Reader<'a>>(reader: &mut R, header: der::Header) -> der::Result<Self> {
        Asn1UintRef::decode_value(reader, header)?.try_into()
    }
}

impl<const LIMBS: usize> EncodeValue for Uint<LIMBS>
where
    Uint<LIMBS>: ArrayEncoding,
{
    fn value_len(&self) -> der::Result<Length> {
        Ok(count_der_be_bytes(&self.limbs).into())
    }

    fn encode_value(&self, encoder: &mut impl der::Writer) -> der::Result<()> {
        let array = self.to_be_byte_array();
        Asn1UintRef::new(&array)?.encode_value(encoder)
    }
}

impl<const LIMBS: usize> FixedTag for Uint<LIMBS>
where
    Uint<LIMBS>: ArrayEncoding,
{
    const TAG: Tag = Tag::Integer;
}

/// Counts bytes in DER ASN.1 `INTEGER` big-endian encoding, without leading zero bytes.
#[inline]
pub(crate) fn count_der_be_bytes(limbs: &[Limb]) -> u32 {
    // Number of 0x00 bytes (also index of first non-zero byte)
    let leading_zero_bytes = UintRef::new(limbs).leading_zeros() / 8;

    // Limbs indexed in reverse
    let limb_index = limbs
        .len()
        .saturating_sub(1)
        .saturating_sub(leading_zero_bytes as usize / Limb::BYTES);

    // Limb bytes encoded as big-endian
    let first_nonzero_byte = limbs
        .get(limb_index)
        .cloned()
        .map(|limb| limb.to_be_bytes()[leading_zero_bytes as usize % Limb::BYTES])
        .unwrap_or(0x00);

    // Does the given integer need a leading zero?
    let needs_leading_zero = first_nonzero_byte >= 0x80;

    // Number of bytes in all limbs
    let max_len = (Limb::BYTES * limbs.len()) as u32;

    // If all bytes are zeros:
    if leading_zero_bytes == max_len {
        // we're encoding 0x00, so one byte remains
        1
    } else {
        max_len
            .saturating_sub(leading_zero_bytes)
            .wrapping_add(needs_leading_zero as u32)
    }
}

#[cfg(feature = "alloc")]
pub mod allocating {
    use der::{DecodeValue, EncodeValue, FixedTag, Length, Tag, asn1::UintRef as Asn1UintRef};

    use crate::{BoxedUint, encoding::der::count_der_be_bytes};

    impl EncodeValue for BoxedUint {
        fn value_len(&self) -> der::Result<Length> {
            Ok(count_der_be_bytes(&self.limbs).into())
        }

        fn encode_value(&self, encoder: &mut impl der::Writer) -> der::Result<()> {
            let array = self.to_be_bytes();
            Asn1UintRef::new(&array)?.encode_value(encoder)
        }
    }

    impl<'a> DecodeValue<'a> for BoxedUint {
        type Error = der::Error;

        fn decode_value<R: der::Reader<'a>>(
            reader: &mut R,
            header: der::Header,
        ) -> der::Result<Self> {
            let value = Asn1UintRef::decode_value(reader, header)?;
            let bits_precision = value.as_bytes().len() as u32 * 8;

            let value = BoxedUint::from_be_slice(value.as_bytes(), bits_precision)
                .map_err(|_| Asn1UintRef::TAG.value_error())?;
            Ok(value)
        }
    }

    impl FixedTag for BoxedUint {
        const TAG: Tag = Tag::Integer;
    }
}

#[cfg(test)]
pub mod test {
    use crate::{ArrayEncoding, BoxedUint, U128, Uint};
    use der::{DecodeValue, EncodeValue, Header, Tag};

    fn assert_valid_uint_value_len<const LIMBS: usize>(n: &Uint<LIMBS>) -> der::Result<()>
    where
        Uint<LIMBS>: ArrayEncoding,
    {
        let mut buf = [0u8; 128];
        let encoded_value = {
            let mut writer = der::SliceWriter::new(&mut buf);
            n.encode_value(&mut writer)?;
            writer.finish()?
        };

        let computed_len: u32 = n.value_len()?.into();
        let encoded_len: u32 = encoded_value.len() as u32;
        assert_eq!(
            computed_len, encoded_len,
            "computed_len: {computed_len}, encoded_len: {encoded_len}, n:{n:?}"
        );

        let decoded = {
            let mut reader = der::SliceReader::new(encoded_value)?;
            let header = Header::new(Tag::Integer, encoded_value.len().try_into()?);
            Uint::<LIMBS>::decode_value(&mut reader, header)?
        };

        assert_eq!(n, &decoded);
        Ok(())
    }

    #[cfg(feature = "alloc")]
    fn assert_valid_boxeduint_value_len(n: &BoxedUint) -> der::Result<()> {
        let mut buf = [0u8; 128];
        let encoded_value = {
            let mut writer = der::SliceWriter::new(&mut buf);
            n.encode_value(&mut writer)?;
            writer.finish()?
        };

        let computed_len: u32 = n.value_len()?.into();
        let encoded_len: u32 = encoded_value.len() as u32;
        assert_eq!(
            computed_len, encoded_len,
            "computed_len: {computed_len}, encoded_len: {encoded_len}, n:{n:?}"
        );
        let decoded = {
            let mut reader = der::SliceReader::new(encoded_value)?;
            let header = Header::new(Tag::Integer, encoded_value.len().try_into()?);
            BoxedUint::decode_value(&mut reader, header)?
        };

        assert_eq!(n, &decoded);

        Ok(())
    }

    fn assert_valid_value_len_hex(hex_uint: &str) {
        let n = U128::from_str_radix_vartime(hex_uint, 16).expect("error decoding");
        assert_valid_uint_value_len(&n).expect("error from der: Uint");

        #[cfg(feature = "alloc")]
        assert_valid_boxeduint_value_len(&BoxedUint::from(n)).expect("error from der: BoxedUint");
    }
    #[test]
    fn encode_uint() {
        assert_valid_value_len_hex("00");
        assert_valid_value_len_hex("10");
        assert_valid_value_len_hex("3210");

        assert_valid_value_len_hex("00000000000000007fdcba9876543210");
        assert_valid_value_len_hex("0000000000000000fedcba9876543210");
        assert_valid_value_len_hex("0000000000000010fedcba9876543210");
        assert_valid_value_len_hex("0000000000000080fedcba9876543210");

        assert_valid_value_len_hex("0000008076543210fedcba9876543210");
        assert_valid_value_len_hex("00dcba9876543210fedcba9876543210");
        assert_valid_value_len_hex("0fdcba9876543210fedcba9876543210");
        assert_valid_value_len_hex("7fdcba9876543210fedcba9876543210");
        assert_valid_value_len_hex("fedcba9876543210fedcba9876543210");
    }
}
