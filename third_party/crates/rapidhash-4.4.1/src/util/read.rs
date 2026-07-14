//! Internal module for reading unaligned bytes from a slice into `u64` and `u32` values.

/// A macro for assertions that can be disabled with the `unsafe` feature. These should all be
/// elided at compile-time anyway.
macro_rules! unsafe_assert {
    ($cond:expr) => {
        #[cfg(feature = "unsafe")]
        {
            debug_assert!($cond);
        }

        #[cfg(not(feature = "unsafe"))]
        {
            assert!($cond);
        }
    };
}

/// Unsafe but const-friendly unaligned bytes to u64. The compiler can't seem to remove the bounds
/// checks for small integers because we do some funky bit shifting in the indexing.
///
/// SAFETY: `slice` must be at least `offset+8` bytes long, which we guarantee in this rapidhash
/// implementation.
#[inline(always)]
pub(crate) const fn read_u64(slice: &[u8], offset: usize) -> u64 {
    unsafe_assert!(slice.len() >= 8 + offset);
    let val = unsafe { core::ptr::read_unaligned(slice.as_ptr().add(offset) as *const u64) };
    val.to_le()  // swap bytes on big-endian systems to get the same u64 value
}

/// Unsafe but const-friendly unaligned bytes to u32. The compiler can't seem to remove the bounds
/// checks for small integers because we do some funky bit shifting in the indexing.
///
/// SAFETY: `slice` must be at least `offset+8` bytes long, which we guarantee in this rapidhash
/// implementation.
#[inline(always)]
pub(crate) const fn read_u32(slice: &[u8], offset: usize) -> u32 {
    unsafe_assert!(slice.len() >= 4 + offset);
    let val = unsafe { core::ptr::read_unaligned(slice.as_ptr().add(offset) as *const u32) };
    val.to_le()  // swap bytes on big-endian systems to get the same u64 value
}

/// Only used in rapidhash V1
#[inline(always)]
pub(crate) const fn read_u32_combined(slice: &[u8], offset_top: usize, offset_bot: usize) -> u64 {
    debug_assert!(slice.len() >= 4 + offset_top && slice.len() >= 4 + offset_bot);
    let top = read_u32(slice, offset_top) as u64;
    let bot = read_u32(slice, offset_bot) as u64;
    (top << 32) | bot
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_u32() {
        let bytes = &[23, 145, 3, 34];
        assert_eq!(read_u32(bytes, 0), 570659095);

        let bytes = &[24, 54, 3, 23, 145, 3, 34];
        assert_eq!(read_u32(bytes, 3), 570659095);

        assert_eq!(read_u32(&[0, 0, 0, 0], 0), 0);
        assert_eq!(read_u32(&[1, 0, 0, 0], 0), 1);
        assert_eq!(read_u32(&[12, 0, 0, 0], 0), 12);
        assert_eq!(read_u32(&[0, 10, 0, 0], 0), 2560);
    }

    #[test]
    fn test_read_u64() {
        let bytes = [23, 145, 3, 34, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64(bytes, 0), 570659095);

        let bytes = [1, 2, 3, 23, 145, 3, 34, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64(bytes, 3), 570659095);

        let bytes = [0, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64(bytes, 0), 0);
    }

    #[cfg(feature = "std")]
    #[test]
    fn test_u32_to_u128_delta() {
        fn formula(len: u64) -> u64 {
            (len & 24) >> (len >> 3)
        }

        fn formula2(len: u64) -> u64 {
            match len {
                8.. => 4,
                _ => 0,
            }
        }

        let inputs: std::vec::Vec<u64> = (4..=16).collect();
        let outputs: std::vec::Vec<u64> = inputs.iter().map(|&x| formula(x)).collect();
        let expected = std::vec![0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, 4];
        assert_eq!(outputs, expected);
        assert_eq!(outputs, inputs.iter().map(|&x| formula2(x)).collect::<Vec<u64>>());
    }

    #[test]
    #[should_panic]
    #[cfg(any(test, not(feature = "unsafe")))]
    fn test_read_u32_to_short_panics() {
        let bytes = [23, 145, 0].as_slice();
        assert_eq!(read_u32(bytes, 0), 0);
    }

    #[test]
    #[should_panic]
    #[cfg(any(test, not(feature = "unsafe")))]
    fn test_read_u64_to_short_panics() {
        let bytes = [23, 145, 0].as_slice();
        assert_eq!(read_u64(bytes, 0), 0);
    }
}
