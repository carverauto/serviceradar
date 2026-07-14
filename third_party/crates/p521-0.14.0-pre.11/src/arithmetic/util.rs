//! Utility functions.

/// Convert an 18-element array of `u32` into a 9-element array of `u16`,
/// assuming integer arrays are in little-endian order.
#[cfg(target_pointer_width = "32")]
pub(crate) const fn u32x18_to_u64x9(w: &[u32; 18]) -> [u64; 9] {
    let mut ret = [0u64; 9];
    let mut i = 0;

    while i < 9 {
        ret[i] = (w[i * 2] as u64) | ((w[(i * 2) + 1] as u64) << 32);
        i += 1;
    }

    ret
}

/// Convert a 9-element array of `u64` into an 18-element array of `u32`,
/// assuming integers are in little-endian order.
#[cfg(target_pointer_width = "32")]
pub(crate) const fn u64x9_to_u32x18(w: &[u64; 9]) -> [u32; 18] {
    let mut ret = [0u32; 18];
    let mut i = 0;

    while i < 9 {
        ret[i * 2] = (w[i] & 0xFFFFFFFF) as u32;
        ret[(i * 2) + 1] = (w[i] >> 32) as u32;
        i += 1;
    }

    ret
}
