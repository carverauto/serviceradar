//! Internal module for reading unaligned bytes from a slice into `u64` and `u32` values.
//!
//! This is a non-portable implementation specifically designed for `RapidHasher`.

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
pub(crate) const fn read_u64_np(slice: &[u8], offset: usize) -> u64 {
    unsafe_assert!(slice.len() >= 8 + offset);
    // SAFETY: read_u64_np must always be called in a manner that guarantees the above assertions
    unsafe { core::ptr::read_unaligned(slice.as_ptr().add(offset) as *const u64) }
}

/// Unsafe but const-friendly unaligned bytes to u32. The compiler can't seem to remove the bounds
/// checks for small integers because we do some funky bit shifting in the indexing.
///
/// SAFETY: `slice` must be at least `offset+8` bytes long, which we guarantee in this rapidhash
/// implementation.
#[inline(always)]
pub(crate) const fn read_u32_np(slice: &[u8], offset: usize) -> u32 {
    unsafe_assert!(slice.len() >= 4 + offset);
    // SAFETY: read_u64_np must always be called in a manner that guarantees the above assertions
    unsafe { core::ptr::read_unaligned(slice.as_ptr().add(offset) as *const u32) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_endian = "little")]
    #[test]
    fn test_read_u32_np() {
        let bytes = &[23, 145, 3, 34];
        assert_eq!(read_u32_np(bytes, 0), 570659095);

        let bytes = &[24, 54, 3, 23, 145, 3, 34];
        assert_eq!(read_u32_np(bytes, 3), 570659095);

        assert_eq!(read_u32_np(&[0, 0, 0, 0], 0), 0);
        assert_eq!(read_u32_np(&[1, 0, 0, 0], 0), 1);
        assert_eq!(read_u32_np(&[12, 0, 0, 0], 0), 12);
        assert_eq!(read_u32_np(&[0, 10, 0, 0], 0), 2560);
    }

    #[cfg(target_endian = "little")]
    #[test]
    fn test_read_u64_np() {
        let bytes = [23, 145, 3, 34, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64_np(bytes, 0), 570659095);

        let bytes = [1, 2, 3, 23, 145, 3, 34, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64_np(bytes, 3), 570659095);

        let bytes = [0, 0, 0, 0, 0, 0, 0, 0].as_slice();
        assert_eq!(read_u64_np(bytes, 0), 0);
    }

    #[cfg(target_endian = "little")]
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
    fn test_read_u32_np_to_short_panics() {
        let bytes = [23, 145, 0].as_slice();
        assert_eq!(read_u32_np(bytes, 0), 0);
    }

    #[test]
    #[should_panic]
    #[cfg(any(test, not(feature = "unsafe")))]
    fn test_read_u64_np_to_short_panics() {
        let bytes = [23, 145, 0].as_slice();
        assert_eq!(read_u64_np(bytes, 0), 0);
    }
}
