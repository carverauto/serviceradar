/// Helper for calculating the sum of all 16 bit words checksums used in
/// in checksum fields in TCP and UDP headers.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Sum16BitWords {
    /// Partial sum
    #[cfg(target_pointer_width = "64")]
    sum: u64,

    /// Partial sum
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    sum: u32,
}

impl Sum16BitWords {
    pub fn new() -> Sum16BitWords {
        Sum16BitWords { sum: 0 }
    }

    /// Add the given slice to the checksum. In case the slice
    /// has a length that is not multiple of 2 the last byte
    /// will be padded with 0.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn add_slice(self, slice: &[u8]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u32_16bit_word::add_slice(self.sum, slice),
        }
    }

    /// Add the given slice to the checksum. In case the slice
    /// has a length that is not multiple of 2 the last byte
    /// will be padded with 0.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn add_slice(self, slice: &[u8]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u64_16bit_word::add_slice(self.sum, slice),
        }
    }

    /// Add a 2 byte word.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn add_2bytes(self, value: [u8; 2]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u32_16bit_word::add_2bytes(self.sum, value),
        }
    }

    /// Add a 2 byte word.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn add_2bytes(self, value: [u8; 2]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u64_16bit_word::add_2bytes(self.sum, value),
        }
    }

    /// Add a 4 byte word.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn add_4bytes(&mut self, value: [u8; 4]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u32_16bit_word::add_4bytes(self.sum, value),
        }
    }

    /// Add a 4 byte word.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn add_4bytes(&mut self, value: [u8; 4]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u64_16bit_word::add_4bytes(self.sum, value),
        }
    }

    /// Add a 8 byte word.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn add_8bytes(&mut self, value: [u8; 8]) -> Sum16BitWords {
        self.add_4bytes([value[0], value[1], value[2], value[3]])
            .add_4bytes([value[4], value[5], value[6], value[7]])
    }

    /// Add a 8 byte word.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn add_8bytes(&mut self, value: [u8; 8]) -> Sum16BitWords {
        Sum16BitWords {
            sum: u64_16bit_word::add_8bytes(self.sum, value),
        }
    }

    /// Add a 16 bytes.
    #[inline]
    pub fn add_16bytes(&mut self, value: [u8; 16]) -> Sum16BitWords {
        self.add_8bytes([
            value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
        ])
        .add_8bytes([
            value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15],
        ])
    }

    /// Converts summed up words from an u32 to an u16 ones complement
    /// which can be used in a ipv4 checksum.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn ones_complement(&self) -> u16 {
        u32_16bit_word::ones_complement(self.sum)
    }

    /// Converts summed up words from an u32 to an u16 ones complement
    /// which can be used in a ipv4 checksum.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn ones_complement(&self) -> u16 {
        u64_16bit_word::ones_complement(self.sum)
    }

    /// Converts summed up words from an u32 to an u16 ones complement
    /// with 0 being replaced by 0xffff (useful for TCP and UDP).
    ///
    /// This kind of checksum is used in TCP and UDP headers.
    #[inline]
    #[cfg(any(target_pointer_width = "16", target_pointer_width = "32"))]
    pub fn to_ones_complement_with_no_zero(&self) -> u16 {
        u32_16bit_word::ones_complement_with_no_zero(self.sum)
    }

    /// Converts summed up words from an u32 to an u16 ones complement
    /// with 0 being replaced by 0xffff (useful for TCP and UDP).
    ///
    /// This kind of checksum is used in TCP and UDP headers.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub fn to_ones_complement_with_no_zero(&self) -> u16 {
        u64_16bit_word::ones_complement_with_no_zero(self.sum)
    }
}

#[cfg(test)]
mod sum16_bit_words_tests {
    use super::*;
    use alloc::format;

    #[test]
    fn new() {
        assert_eq!(0xffff, Sum16BitWords::new().ones_complement());
    }

    #[test]
    fn add_slice() {
        assert_eq!(
            !u16::from_ne_bytes([0x12, 0x34]),
            Sum16BitWords::new()
                .add_slice(&[0x12, 0x34])
                .ones_complement()
        );
    }

    #[test]
    fn add_2bytes() {
        assert_eq!(
            !u16::from_ne_bytes([0xf0, 0x0f]),
            Sum16BitWords::new()
                .add_2bytes([0xf0, 0x0f])
                .ones_complement()
        );
    }

    #[test]
    fn add_4bytes() {
        assert_eq!(
            !(u16::from_ne_bytes([0x12, 0x34]) + u16::from_ne_bytes([0x56, 0x78])),
            Sum16BitWords::new()
                .add_4bytes([0x12, 0x34, 0x56, 0x78])
                .ones_complement()
        );
    }

    #[test]
    fn add_8bytes() {
        assert_eq!(
            !(u16::from_ne_bytes([0x12, 0x34])
                + u16::from_ne_bytes([0x56, 0x78])
                + u16::from_ne_bytes([0x23, 0x22])
                + u16::from_ne_bytes([0x34, 0x11])),
            Sum16BitWords::new()
                .add_8bytes([0x12, 0x34, 0x56, 0x78, 0x23, 0x22, 0x34, 0x11])
                .ones_complement()
        );
    }

    #[test]
    fn add_16bytes() {
        assert_eq!(
            u32_16bit_word::ones_complement(u32_16bit_word::add_4bytes(
                u32_16bit_word::add_4bytes(
                    u32_16bit_word::add_4bytes(
                        u32_16bit_word::add_4bytes(0, [0x12, 0x34, 0x56, 0x78]),
                        [0x9a, 0xbc, 0xde, 0xf0]
                    ),
                    [0x0f, 0xed, 0xcb, 0xa9]
                ),
                [0x87, 0x65, 0x43, 0x21]
            )),
            Sum16BitWords::new()
                .add_16bytes([
                    0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x0f, 0xed, 0xcb, 0xa9, 0x87,
                    0x65, 0x43, 0x21,
                ])
                .ones_complement()
        );
    }

    #[test]
    fn ones_complement() {
        assert_eq!(
            !u16::from_ne_bytes([0xf0, 0x0f]),
            Sum16BitWords::new()
                .add_2bytes([0xf0, 0x0f])
                .ones_complement()
        );
    }

    #[test]
    fn to_ones_complement_with_no_zero() {
        // normal case
        assert_eq!(
            !u16::from_ne_bytes([0xf0, 0x0f]),
            Sum16BitWords::new()
                .add_2bytes([0xf0, 0x0f])
                .to_ones_complement_with_no_zero()
        );

        // zero case
        assert_eq!(
            0xffffu16,
            Sum16BitWords::new()
                // ones complement would result in 0
                // will be converted to 0xffff as 0
                // is a reserved value
                .add_2bytes([0xff, 0xff])
                .to_ones_complement_with_no_zero()
        );
    }

    #[test]
    fn debug() {
        let input = Sum16BitWords::new();
        assert_eq!(
            &format!("Sum16BitWords {{ sum: {} }}", input.sum),
            &format!("{:?}", input)
        );
    }

    #[test]
    fn default() {
        let d: Sum16BitWords = Default::default();
        assert_eq!(d.sum, 0);
    }

    #[test]
    fn clone_eq() {
        let value = Sum16BitWords::new();
        assert_eq!(value.clone(), value)
    }
}

/// Helper functions for calculating a 16 bit checksum using
/// a u32 to sum up all values.
pub mod u32_16bit_word {

    /// Add a 4 byte word.
    #[inline]
    pub fn add_4bytes(start: u32, value: [u8; 4]) -> u32 {
        let (sum, carry) = start.overflowing_add(u32::from_ne_bytes(value));
        sum + (carry as u32)
    }

    /// Add a 2 byte word.
    #[inline]
    pub fn add_2bytes(start: u32, value: [u8; 2]) -> u32 {
        let (sum, carry) = start.overflowing_add(u32::from(u16::from_ne_bytes(value)));
        sum + (carry as u32)
    }

    /// Add the given slice to the checksum. In case the slice
    /// has a length that is not multiple of 2 the last byte
    /// will be padded with 0.
    #[inline]
    pub fn add_slice(start_sum: u32, slice: &[u8]) -> u32 {
        let mut sum: u32 = start_sum;

        // sum up all 4 byte values
        let end_32 = slice.len() - (slice.len() % 4);
        for i in (0..end_32).step_by(4) {
            sum = add_4bytes(
                sum,
                // SAFETY:
                // Guranteed to always have at least 4 bytes to read
                // from i. As end_32 is gurenateed to be a multiple of
                // 4 bytes with a size equal or less then slice.len().
                unsafe {
                    [
                        *slice.get_unchecked(i),
                        *slice.get_unchecked(i + 1),
                        *slice.get_unchecked(i + 2),
                        *slice.get_unchecked(i + 3),
                    ]
                },
            );
        }

        // in case 2 bytes are left add them as an word
        if slice.len() - end_32 >= 2 {
            sum = add_2bytes(
                sum,
                // SAFETY:
                // If check guarantees there to be at least
                // 2 bytes.
                unsafe {
                    [
                        *slice.get_unchecked(end_32),
                        *slice.get_unchecked(end_32 + 1),
                    ]
                },
            );
        }

        // unaligned end pad the last byte with
        if 0 != slice.len() % 2 {
            sum = add_2bytes(
                sum,
                // SAFETY:
                // If check guarantees there to be at least
                // 2 bytes.
                unsafe { [*slice.get_unchecked(slice.len() - 1), 0] },
            );
        }

        // done
        sum
    }

    /// Converts summed up words from an u32 to an u16 with 0 being replaced by 0xffff (useful
    /// for TCP and UDP headers).
    ///
    /// This kind of checksum is used in TCP and udp headers.
    #[inline]
    pub fn ones_complement_with_no_zero(sum: u32) -> u16 {
        // In case of 0 use the ones complement (zero is reserved
        // value for no checksum).
        let u16value = ones_complement(sum);
        if u16value == 0 {
            0xffff
        } else {
            u16value
        }
    }

    /// Converts summed up words from an u32 to an u16 which can be used in a ipv4.
    #[inline]
    pub fn ones_complement(sum: u32) -> u16 {
        // Add the upper 16 bits to the lower 16 bits twice.
        //
        // Notes: Two carry adds are needed as the first one could
        //        result in an additional carry add.
        let first = ((sum >> 16) & 0xffff) + (sum & 0xffff);
        let u16value = (((first >> 16) & 0xffff) + (first & 0xffff)) as u16;

        // switch back to big endian (allows to use
        // native endinaess during calculations).
        !u16value
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn add_4bytes_test() {
            // trivial case
            assert_eq!(0, add_4bytes(0, [0, 0, 0, 0]));
            // check that the carry gets added
            assert_eq!(
                0xffff_ffff, // normal overflow would result in 0xffff_fffe
                add_4bytes(0xffff_ffff, [0xff, 0xff, 0xff, 0xff])
            );
            // non max & min values
            assert_eq!(
                0x1234_5678 + u32::from_ne_bytes([0x23, 0x45, 0x67, 0x89]),
                add_4bytes(0x1234_5678, [0x23, 0x45, 0x67, 0x89])
            );
        }

        #[test]
        fn add_2bytes_test() {
            // trivial case
            assert_eq!(0, add_2bytes(0, [0, 0]));
            // check that the carry gets added
            assert_eq!(
                0x0000_ffff, // normal overflow would result in 0x10000fffe
                add_2bytes(0xffff_ffff, [0xff, 0xff])
            );
            // non max & min values
            assert_eq!(
                0x1234_5678 + u32::from(u16::from_ne_bytes([0x23, 0x45])),
                add_2bytes(0x1234_5678, [0x23, 0x45])
            );
        }

        #[test]
        fn add_slice_test() {
            // empty
            assert_eq!(0x1234, add_slice(0x1234, &[]));

            // aligned
            assert_eq!(
                0x1 + u32::from_ne_bytes([0x11, 0x12, 0x13, 0x14])
                    + u32::from_ne_bytes([0x15, 0x16, 0x17, 0x18])
                    + u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c])
                    + u32::from_ne_bytes([0x1d, 0x1e, 0x1f, 0x10]),
                add_slice(
                    0x1,
                    &[
                        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
                        0x1d, 0x1e, 0x1f, 0x10,
                    ]
                )
            );

            // aligned with carry
            assert_eq!(
                0x1 +
                0x3 + // expected carry
                u32::from_ne_bytes([0xf1, 0x11, 0x10, 0xf0]).wrapping_add(
                    u32::from_ne_bytes([0xf2, 0x12, 0x11, 0xf1]).wrapping_add(
                        u32::from_ne_bytes([0xf3, 0x13, 0x12, 0xf2]).wrapping_add(
                            u32::from_ne_bytes([0xf4, 0x14, 0x13, 0xf3])
                        )
                    )
                ),
                add_slice(
                    0x1,
                    &[
                        0xf1, 0x11, 0x10, 0xf0, 0xf2, 0x12, 0x11, 0xf1, 0xf3, 0x13, 0x12, 0xf2,
                        0xf4, 0x14, 0x13, 0xf3,
                    ]
                )
            );

            // 1 byte unalgined
            assert_eq!(
                0x1 + u32::from_ne_bytes([0x11, 0x12, 0x13, 0x14])
                    + u32::from_ne_bytes([0x15, 0x16, 0x17, 0x18])
                    + u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c])
                    + u32::from(u16::from_ne_bytes([0x1d, 0x1e]))
                    + u32::from(u16::from_ne_bytes([0x1f, 0x00])),
                add_slice(
                    0x1,
                    &[
                        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
                        0x1d, 0x1e, 0x1f,
                    ]
                )
            );

            // 2 byte unaligned
            assert_eq!(
                0x1 + u32::from_ne_bytes([0x11, 0x12, 0x13, 0x14])
                    + u32::from_ne_bytes([0x15, 0x16, 0x17, 0x18])
                    + u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c])
                    + u32::from(u16::from_ne_bytes([0x1d, 0x1e])),
                add_slice(
                    0x1,
                    &[
                        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
                        0x1d, 0x1e,
                    ]
                )
            );

            // 4 byte unaligned
            assert_eq!(
                0x1 + u32::from_ne_bytes([0x11, 0x12, 0x13, 0x14])
                    + u32::from_ne_bytes([0x15, 0x16, 0x17, 0x18])
                    + u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c])
                    + u32::from(u16::from_ne_bytes([0x1d, 0x00])),
                add_slice(
                    0x1,
                    &[
                        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
                        0x1d,
                    ]
                )
            );
        }

        #[test]
        fn ones_complement_with_no_zero_test() {
            // zero case
            assert_eq!(0xffff, ones_complement_with_no_zero(0));

            // 0xffff should stay 0xffff (0 is reserved for no checksum)
            assert_eq!(0xffff, ones_complement_with_no_zero(0xffff));

            // big endian conversion check
            assert_eq!(!0x1234u16, ones_complement_with_no_zero(0x1234),);

            // add of the upper and lower 16 bits without a carry
            assert_eq!(
                !(0x2345u16 + 0x1234),
                ones_complement_with_no_zero(0x2345_1234),
            );

            // add which in itself will again produce a carry
            assert_eq!(
                !(((0x1456u32 + 0xf123u32 + 1u32) & 0xffff) as u16),
                ones_complement_with_no_zero(0x1456_f123),
            );
        }

        #[test]
        fn ones_complement_test() {
            // zero case
            assert_eq!(0xffff, ones_complement(0));

            // check that zero is not reserved
            assert_eq!(0, ones_complement(0xffff));

            // big endian conversion check
            assert_eq!(!0x1234u16, ones_complement(0x1234),);

            // add of the upper and lower 16 bits without a carry
            assert_eq!(!(0x2345u16 + 0x1234u16), ones_complement(0x2345_1234),);

            // add which in itself will again produce a carry
            assert_eq!(
                !(((0x1456u32 + 0xf123u32 + 1u32) & 0xffff) as u16),
                ones_complement(0x1456_f123),
            );
        }
    }
}

/// Helper functions for calculating a 16 bit checksum using
/// a u64 to sum up all values.
pub mod u64_16bit_word {

    /// Add a 8 byte word.
    #[inline]
    pub fn add_8bytes(start: u64, value: [u8; 8]) -> u64 {
        let (sum, carry) = start.overflowing_add(u64::from_ne_bytes(value));
        sum + (carry as u64)
    }

    /// Add a 4 byte word.
    #[inline]
    pub fn add_4bytes(start: u64, value: [u8; 4]) -> u64 {
        let (sum, carry) = start.overflowing_add(u64::from(u32::from_ne_bytes(value)));
        sum + (carry as u64)
    }

    /// Add a 2 byte word.
    #[inline]
    pub fn add_2bytes(start: u64, value: [u8; 2]) -> u64 {
        let (sum, carry) = start.overflowing_add(u64::from(u16::from_ne_bytes(value)));
        sum + (carry as u64)
    }

    /// Add the given slice to the checksum. In case the slice
    /// has a length that is not multiple of 2 the last byte
    /// will be padded with 0.
    #[inline]
    pub fn add_slice(start_sum: u64, slice: &[u8]) -> u64 {
        let mut sum: u64 = start_sum;

        // sum up all 4 byte values
        let end_64 = slice.len() - (slice.len() % 8);
        for i in (0..end_64).step_by(8) {
            sum = add_8bytes(
                sum,
                // SAFETY:
                // Guranteed to always have at least 8 bytes to read
                // from i. As end_64 is gurenateed to be a multiple of
                // 8 bytes with a size equal or less then slice.len().
                unsafe {
                    [
                        *slice.get_unchecked(i),
                        *slice.get_unchecked(i + 1),
                        *slice.get_unchecked(i + 2),
                        *slice.get_unchecked(i + 3),
                        *slice.get_unchecked(i + 4),
                        *slice.get_unchecked(i + 5),
                        *slice.get_unchecked(i + 6),
                        *slice.get_unchecked(i + 7),
                    ]
                },
            );
        }

        // in case 4 or more bytes are left add the first 4 bytes
        let end_32 = if slice.len() - end_64 >= 4 {
            sum = add_4bytes(
                sum,
                // SAFETY:
                // If check guarantees there to be at least
                // 2 bytes.
                unsafe {
                    [
                        *slice.get_unchecked(end_64),
                        *slice.get_unchecked(end_64 + 1),
                        *slice.get_unchecked(end_64 + 2),
                        *slice.get_unchecked(end_64 + 3),
                    ]
                },
            );

            // shift by 4
            end_64 + 4
        } else {
            end_64
        };

        // in case 2 bytes are left add them as an word
        if slice.len() - end_32 >= 2 {
            sum = add_2bytes(
                sum,
                // SAFETY:
                // If check guarantees there to be at least
                // 2 bytes.
                unsafe {
                    [
                        *slice.get_unchecked(end_32),
                        *slice.get_unchecked(end_32 + 1),
                    ]
                },
            );
        }

        // unaligned end pad the last byte with
        if 0 != slice.len() % 2 {
            sum = add_2bytes(
                sum,
                // SAFETY:
                // If check guarantees there to be at least
                // 2 bytes.
                unsafe { [*slice.get_unchecked(slice.len() - 1), 0] },
            );
        }

        // done
        sum
    }

    /// Converts summed up words from an u64 to an u16 with 0 being replaced by 0xffff (useful
    /// for TCP and UDP headers).
    ///
    /// This kind of checksum is used in TCP and udp headers.
    #[inline]
    pub fn ones_complement_with_no_zero(sum: u64) -> u16 {
        // In case of 0 use the ones complement (zero is reserved
        // value for no checksum).
        let u16value = ones_complement(sum);
        if u16value == 0 {
            0xffff
        } else {
            u16value
        }
    }

    /// Converts summed up words from an u64 to an u16 which can be used in a ipv4.
    #[inline]
    pub fn ones_complement(sum: u64) -> u16 {
        let first = ((sum >> 48) & 0xffff)
            + ((sum >> 32) & 0xffff)
            + ((sum >> 16) & 0xffff)
            + (sum & 0xffff);
        // Add the upper 16 bits to the lower 16 bits twice.
        //
        // Notes: Two carry adds are needed as the first one could
        //        result in an additional carry add.
        let second = ((first >> 16) & 0xffff) + (first & 0xffff);
        let u16value = (((second >> 16) & 0xffff) + (second & 0xffff)) as u16;

        // switch back to big endian (allows to use
        // native endinaess during calculations).
        !u16value
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use proptest::prelude::*;

        #[test]
        fn add_8bytes_test() {
            // trivial case
            assert_eq!(0, add_8bytes(0, [0, 0, 0, 0, 0, 0, 0, 0]));
            // check that the carry gets added
            assert_eq!(
                0xffff_ffff_ffff_ffff, // normal overflow would result in 0xffff_ffff_ffff_fffe
                add_8bytes(
                    0xffff_ffff_ffff_ffff,
                    [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
                )
            );
            // non max & min values
            assert_eq!(
                0x1234_5678_1234_5678
                    + u64::from_ne_bytes([0x23, 0x45, 0x67, 0x89, 0x11, 0x22, 0x33, 0x44]),
                add_8bytes(
                    0x1234_5678_1234_5678,
                    [0x23, 0x45, 0x67, 0x89, 0x11, 0x22, 0x33, 0x44]
                )
            );
        }

        #[test]
        fn add_4bytes_test() {
            // trivial case
            assert_eq!(0, add_4bytes(0, [0, 0, 0, 0]));
            // check that the carry gets added
            assert_eq!(
                0xffff_ffff, // normal overflow would result in 0xffff_fffe
                add_4bytes(0xffff_ffff_ffff_ffff, [0xff, 0xff, 0xff, 0xff])
            );
            // non max & min values
            assert_eq!(
                0x1234_5678_1234_5678 + u64::from(u32::from_ne_bytes([0x23, 0x45, 0x67, 0x89])),
                add_4bytes(0x1234_5678_1234_5678, [0x23, 0x45, 0x67, 0x89])
            );
        }

        #[test]
        fn add_2bytes_test() {
            // trivial case
            assert_eq!(0, add_2bytes(0, [0, 0]));
            // check that the carry gets added
            assert_eq!(
                0xffff, // normal overflow would result in 0xfffe
                add_2bytes(0xffff_ffff_ffff_ffff, [0xff, 0xff])
            );
            // non max & min values
            assert_eq!(
                0x9876_0123_1234_5678 + u64::from(u16::from_ne_bytes([0x23, 0x45])),
                add_2bytes(0x9876_0123_1234_5678, [0x23, 0x45])
            );
        }

        #[test]
        fn add_slice_test() {
            // empty
            assert_eq!(0x1234, add_slice(0x1234, &[]));

            // aligned
            assert_eq!(
                0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                    + u64::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x10]),
                add_slice(
                    0x1,
                    &[
                        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
                        0x1d, 0x1e, 0x1f, 0x10,
                    ]
                )
            );

            // aligned with carry
            assert_eq!(
                0x1 +
                0x1 + // expected carry
                u64::from_ne_bytes([0xf1, 0x11, 0x10, 0xf0, 0xf2, 0x12, 0x11, 0xf1]).wrapping_add(
                    u64::from_ne_bytes([0xf3, 0x13, 0x12, 0xf2, 0xf4, 0x14, 0x13, 0xf3])
                ),
                add_slice(
                    0x1,
                    &[
                        0xf1, 0x11, 0x10, 0xf0, 0xf2, 0x12, 0x11, 0xf1, 0xf3, 0x13, 0x12, 0xf2,
                        0xf4, 0x14, 0x13, 0xf3,
                    ]
                )
            );

            // unaligned access
            {
                let base_data = [
                    0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
                    0x1e, 0x1f, 0x00,
                ];

                // 1 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c]))
                        + u64::from(u16::from_ne_bytes([0x1d, 0x1e]))
                        + u64::from(u16::from_ne_bytes([0x1f, 0x00])),
                    add_slice(0x1, &base_data[..base_data.len() - 1])
                );

                // 2 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c]))
                        + u64::from(u16::from_ne_bytes([0x1d, 0x1e])),
                    add_slice(0x1, &base_data[..base_data.len() - 2])
                );

                // 3 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c]))
                        + u64::from(u16::from_ne_bytes([0x1d, 0x00])),
                    add_slice(0x1, &base_data[..base_data.len() - 3])
                );

                // 4 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u32::from_ne_bytes([0x19, 0x1a, 0x1b, 0x1c])),
                    add_slice(0x1, &base_data[..base_data.len() - 4])
                );

                // 5 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u16::from_ne_bytes([0x19, 0x1a]))
                        + u64::from(u16::from_ne_bytes([0x1b, 0x00])),
                    add_slice(0x1, &base_data[..base_data.len() - 5])
                );

                // 6 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u16::from_ne_bytes([0x19, 0x1a])),
                    add_slice(0x1, &base_data[..base_data.len() - 6])
                );

                // 6 byte unaligned
                assert_eq!(
                    0x1 + u64::from_ne_bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
                        + u64::from(u16::from_ne_bytes([0x19, 0x00])),
                    add_slice(0x1, &base_data[..base_data.len() - 7])
                );
            }
        }

        #[test]
        fn ones_complement_with_no_zero_test() {
            // zero case
            assert_eq!(0xffff, ones_complement_with_no_zero(0));

            // 0xffff should stay 0xffff (0 is reserved for no checksum)
            assert_eq!(0xffff, ones_complement_with_no_zero(0xffff));

            // big endian conversion check
            assert_eq!(!0x1234u16, ones_complement_with_no_zero(0x1234),);

            // add of the upper and lower 16 bits without a carry
            assert_eq!(
                !(0x2456u16 + 0x1345 + 0x2345u16 + 0x1234u16),
                ones_complement_with_no_zero(0x2456_1345_2345_1234),
            );

            // add which in itself will again produce two as carry
            assert_eq!(
                !(((0x1234 + 0xf234u32 + 0x1456u32 + 0xf123u32 + 2u32) & 0xffff) as u16),
                ones_complement_with_no_zero(0x1234_f234_1456_f123),
            );
        }

        #[test]
        fn ones_complement_test() {
            // zero case
            assert_eq!(0xffff, ones_complement(0));

            // check that zero is not reserved
            assert_eq!(0, ones_complement(0xffff));

            // big endian conversion check
            assert_eq!(!0x1234u16, ones_complement(0x1234),);

            // add of the upper and lower 16 bits without a carry
            assert_eq!(
                !(0x2456u16 + 0x1345 + 0x2345u16 + 0x1234u16),
                ones_complement(0x2456_1345_2345_1234),
            );

            // add which in itself will again produce two as carry
            assert_eq!(
                !(((0x1234 + 0xf234u32 + 0x1456u32 + 0xf123u32 + 2u32) & 0xffff) as u16),
                ones_complement(0x1234_f234_1456_f123),
            );

            // will result in a first 16bit sum that will have to be
            // carry added twice
            assert_eq!(!1, ones_complement(0x02f6_e312_7fd7_9a20),);
        }

        proptest! {
            #[test]
            #[cfg_attr(miri, ignore)] // vec allocation reduces miri runspeed too much
            fn u32_u16_comparison(
                data in proptest::collection::vec(any::<u8>(), 0..0xfffusize)
            ) {
                use crate::checksum::*;

                let u32_oc = u32_16bit_word::ones_complement(
                    u32_16bit_word::add_slice(0, &data)
                );
                let u64_oc = u64_16bit_word::ones_complement(
                    u64_16bit_word::add_slice(0, &data)
                );
                assert_eq!(u32_oc, u64_oc);

                let struct_oc = Sum16BitWords::new()
                    .add_slice(&data)
                    .ones_complement();
                assert_eq!(u32_oc, struct_oc);
            }
        }
    }
}
