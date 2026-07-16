use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32, read_u64};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets};

/// Rapidhash V2.2 a single byte stream, matching the C++ implementation, with the default seed.
///
/// See [rapidhash_v2_inline] to compute the hash value using V2.0 or V2.2.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_v2_inline] instead.
#[inline]
pub const fn rapidhash_v2_2(data: &[u8]) -> u64 {
    rapidhash_v2_inline::<2, true, false, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash V2.2 a single byte stream, matching the C++ implementation, with a custom seed.
///
/// See [rapidhash_v2_inline] to compute the hash value using V2.0 or V2.2.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_v2_inline] instead.
#[inline]
pub const fn rapidhash_v2_2_seeded(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_v2_inline::<2, true, false, false>(data, secrets)
}

/// Rapidhash V2 a single byte stream, matching the C++ implementation.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
/// Can provide large performance uplifts for fixed-length inputs at compile time.
///
/// Compile time arguments:
/// - `MINOR`: the minor version of the rapidhash algorithm:
///   - 0: v2.0
///   - 1: v2.1
///   - 2: v2.2
/// - `AVALANCHE`: Perform an extra mix step to avalanche the bits for higher hash quality. Enabled
///   by default to match the C++ implementation.
/// - `COMPACT`: Generates fewer instructions at compile time with less manual loop unrolling, but
///   may be slower on some platforms. Disabled by default.
/// - `PROTECTED`: Slightly stronger hash quality and DoS resistance by performing two extra XOR
///   instructions on every mix step. Disabled by default.
#[inline(always)]
pub const fn rapidhash_v2_inline<const MINOR: u8, const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_core::<MINOR, AVALANCHE, COMPACT, PROTECTED>(secrets.seed, &secrets.secrets, data)
}

#[inline(always)]
pub(super) const fn rapidhash_core<const MINOR: u8, const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    if MINOR > 2 {
        panic!("rapidhash_core unsupported minor version. Supported versions are 0, 1, and 2.");
    }

    let mut a = 0;
    let mut b = 0;
    seed ^= data.len() as u64;

    if data.len() <= 16 {
        if data.len() >= 4 {
            if data.len() >= 8 {
                let plast = data.len() - 8;
                a ^= read_u64(data, 0);
                b ^= read_u64(data, plast);
            } else {
                let plast = data.len() - 4;
                a ^= read_u32(data, 0) as u64;
                b ^= read_u32(data, plast) as u64;
            }
        } else if !data.is_empty() {
            if MINOR < 2 {
                a ^= ((data[0] as u64) << 56) | ((data[data.len() >> 1] as u64) << 32) | data[data.len() - 1] as u64;
            } else {
                a ^= ((data[0] as u64) << 56) | data[data.len() - 1] as u64;
                b ^= data[data.len() >> 1] as u64;
            }
        }
    } else if (MINOR == 0 && data.len() <= 56) || (MINOR > 0 && data.len() <= 64) {
        // len is 17..=64
        return rapidhash_core_17_64::<MINOR, AVALANCHE, PROTECTED>(seed, secrets, data);
    } else {
        return rapidhash_core_cold::<AVALANCHE, COMPACT, PROTECTED>(seed, secrets, data);
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, data.len() as u64, secrets)
    } else {
        a ^ b
    }
}

#[inline]  // intentionally not always
const fn rapidhash_core_17_64<const MINOR: u8, const AVALANCHE: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    let mut a = 0;
    let mut b = 0;

    let slice = data;

    seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
    if slice.len() > 32 {
        seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ seed);
        if slice.len() > 48 {
            let index: usize = if MINOR < 2 { 0 } else { 1 };
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[index], read_u64(slice, 40) ^ seed);
        }
    }

    a ^= read_u64(data, data.len() - 16);
    b ^= read_u64(data, data.len() - 8);

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, data.len() as u64, secrets)
    } else {
        a ^ b
    }
}

/// The long path, intentionally kept cold because at this length of data the function call is
/// minor, but the complexity of this function — if it were inlined — could prevent x.hash() from
/// being inlined which would have a much higher penalty and prevent other optimisations.
#[cold]
const fn rapidhash_core_cold<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    let mut a = 0;
    let mut b = 0;

    let mut slice = data;

    // most CPUs appear to benefit from this unrolled loop
    let mut see1 = seed;
    let mut see2 = seed;
    let mut see3 = seed;
    let mut see4 = seed;
    let mut see5 = seed;
    let mut see6 = seed;

    if !COMPACT {
        while slice.len() >= 224 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            see3 = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ see3);
            see4 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ see4);
            see5 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[5], read_u64(slice, 88) ^ see5);
            see6 = rapid_mix::<PROTECTED>(read_u64(slice, 96) ^ secrets[6], read_u64(slice, 104) ^ see6);

            seed = rapid_mix::<PROTECTED>(read_u64(slice, 112) ^ secrets[0], read_u64(slice, 120) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 128) ^ secrets[1], read_u64(slice, 136) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 144) ^ secrets[2], read_u64(slice, 152) ^ see2);
            see3 = rapid_mix::<PROTECTED>(read_u64(slice, 160) ^ secrets[3], read_u64(slice, 168) ^ see3);
            see4 = rapid_mix::<PROTECTED>(read_u64(slice, 176) ^ secrets[4], read_u64(slice, 184) ^ see4);
            see5 = rapid_mix::<PROTECTED>(read_u64(slice, 192) ^ secrets[5], read_u64(slice, 200) ^ see5);
            see6 = rapid_mix::<PROTECTED>(read_u64(slice, 208) ^ secrets[6], read_u64(slice, 216) ^ see6);

            let (_, split) = slice.split_at(224);
            slice = split;
        }

        if slice.len() >= 112 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            see3 = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ see3);
            see4 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ see4);
            see5 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[5], read_u64(slice, 88) ^ see5);
            see6 = rapid_mix::<PROTECTED>(read_u64(slice, 96) ^ secrets[6], read_u64(slice, 104) ^ see6);
            let (_, split) = slice.split_at(112);
            slice = split;
        }

        if slice.len() >= 48 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            let (_, split) = slice.split_at(48);
            slice = split;

            if slice.len() >= 48 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                let (_, split) = slice.split_at(48);
                slice = split;
            }
        }
    } else {
        while slice.len() >= 112 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            see3 = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ see3);
            see4 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ see4);
            see5 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[5], read_u64(slice, 88) ^ see5);
            see6 = rapid_mix::<PROTECTED>(read_u64(slice, 96) ^ secrets[6], read_u64(slice, 104) ^ see6);
            let (_, split) = slice.split_at(112);
            slice = split;
        }

        while slice.len() >= 48 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            let (_, split) = slice.split_at(48);
            slice = split;
        }
    }

    see3 ^= see4;
    see5 ^= see6;
    seed ^= see1;
    see3 ^= see2;
    seed ^= see5;
    seed ^= see3;

    if slice.len() > 16 {
        seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed);
        if slice.len() > 32 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
        }
    }

    a ^= read_u64(data, data.len() - 16);
    b ^= read_u64(data, data.len() - 8);

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, data.len() as u64, secrets)
    } else {
        a ^ b
    }
}

#[inline(always)]
pub(super) const fn rapidhash_finish<const PROTECTED: bool>(a: u64, b: u64, len: u64, secrets: &[u64; 7]) -> u64 {
    rapid_mix::<PROTECTED>(a ^ 0xaaaaaaaaaaaaaaaa ^ len, b ^ secrets[1])
}
