use serdect::serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error};

use crate::BoxedUint;

impl<'de> Deserialize<'de> for BoxedUint {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let slice = serdect::slice::deserialize_hex_or_bin_vec(deserializer)?;
        let bit_precision = (slice.len() as u32).checked_mul(8).ok_or(Error::custom(
            "Deserialized value overflows u32 bit precision!",
        ))?;
        Self::from_le_slice(&slice, bit_precision).map_err(Error::custom)
    }
}

impl Serialize for BoxedUint {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serdect::slice::serialize_hex_lower_or_bin(&self.to_le_bytes(), serializer)
    }
}

#[cfg(test)]
mod tests {
    use super::BoxedUint;
    #[cfg(target_pointer_width = "32")]
    use crate::Limb;
    #[cfg(target_pointer_width = "32")]
    use hex_literal::hex;

    #[test]
    #[cfg(target_pointer_width = "64")]
    fn serde() {
        let test: BoxedUint = BoxedUint::from_be_hex("7711223344556600", 64).unwrap();

        let serialized = bincode::serde::encode_to_vec(&test, bincode::config::standard()).unwrap();
        let deserialized: BoxedUint =
            bincode::serde::decode_from_slice(&serialized, bincode::config::standard())
                .unwrap()
                .0;

        assert_eq!(test, deserialized);
    }

    #[test]
    #[cfg(target_pointer_width = "32")]
    fn from_le_slice_eq_test() {
        let bytes = hex!("7766554433221100");
        let box_uint = BoxedUint::from_le_slice(&bytes, 64).unwrap();

        let serialized =
            bincode::serde::encode_to_vec(&box_uint, bincode::config::standard()).unwrap();
        let deserialized: BoxedUint =
            bincode::serde::decode_from_slice(serialized.as_slice(), bincode::config::standard())
                .unwrap()
                .0;

        assert_eq!(
            deserialized.as_limbs(),
            &[Limb(0x44556677), Limb(0x00112233)]
        );
    }
}
