//! Utility functions.

use elliptic_curve::bigint::U576;

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

/// Converts the saturated representation [`U576`] into a 528bit array. Each
/// word is copied in little-endian.
pub const fn u576_to_le_bytes(w: U576) -> [u8; 66] {
    #[cfg(target_pointer_width = "32")]
    let words = u32x18_to_u64x9(w.as_words());
    #[cfg(target_pointer_width = "64")]
    let words = w.as_words();

    let mut result: [u8; 66] = [0u8; 66];
    let mut i = 0;
    while i < words.len() - 1 {
        let word = words[i].to_le_bytes();
        let start = i * 8;
        result[start] = word[0];
        result[start + 1] = word[1];
        result[start + 2] = word[2];
        result[start + 3] = word[3];
        result[start + 4] = word[4];
        result[start + 5] = word[5];
        result[start + 6] = word[6];
        result[start + 7] = word[7];
        i += 1;
    }
    let last_word = words[8].to_le_bytes();
    result[i * 8] = last_word[0];
    result[(i * 8) + 1] = last_word[1];

    result
}
