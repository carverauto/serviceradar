use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32_combined, read_u64};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets};

/// Rapidhash a single byte stream, matching the C++ implementation.
#[inline]
pub const fn rapidhash_v1(data: &[u8]) -> u64 {
    rapidhash_v1_inline::<true, false, false, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash a single byte stream, matching the C++ implementation, with a custom seed.
#[inline]
pub const fn rapidhash_v1_seeded(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_v1_inline::<true, false, false, false>(data, secrets)
}

/// Rapidhash a single byte stream, matching the C++ implementation.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
/// Can provide large performance uplifts for inputs where the length is known at compile time.
///
/// Compile time arguments:
/// - `AVALANCHE`: Perform an extra mix step to avalanche the bits for higher hash quality. Enabled
///   by default to match the C++ implementation.
/// - `COMPACT`: Generates fewer instructions at compile time with less manual loop unrolling, but
///   may be slower on some platforms. Disabled by default.
/// - `PROTECTED`: Slightly stronger hash quality and DoS resistance by performing two extra XOR
///   instructions on every mix step. Disabled by default.
/// - `V1_BUG`: True to re-introduce the bug that was present on 48 byte length inputs in the
///   1.x crate versions for backwards compatibility with the old rust implementation.
#[inline(always)]
pub const fn rapidhash_v1_inline<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool, const V1_BUG: bool>(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_core::<AVALANCHE, COMPACT, PROTECTED, V1_BUG>(secrets.seed, &secrets.secrets, data)
}

#[inline(always)]
pub(super) const fn rapidhash_core<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool, const V1_BUG: bool>(mut seed: u64, secrets: &[u64; 3], data: &[u8]) -> u64 {
    let mut a = 0;
    let mut b = 0;

    seed ^= data.len() as u64;

    if data.len() <= 16 {
        // deviation from the C++ impl computes delta as follows
        // let delta = (data.len() & 24) >> (data.len() >> 3);
        // this is equivalent to "match {..8=>0, 8..=>4}"
        // and so using the extra if-else statement is equivalent and allows the compiler to skip
        // some unnecessary bounds checks while still being safe rust.
        if data.len() >= 8 {
            // len is 4..=16
            let plast = data.len() - 4;
            let delta = 4;
            a ^= read_u32_combined(data, 0, plast);
            b ^= read_u32_combined(data, delta, plast - delta);
        } else if data.len() >= 4 {
            let plast = data.len() - 4;
            let delta = 0;
            a ^= read_u32_combined(data, 0, plast);
            b ^= read_u32_combined(data, delta, plast - delta);
        } else if !data.is_empty() {
            // len is 1..=3
            let len = data.len();
            a ^= ((data[0] as u64) << 56) | ((data[len >> 1] as u64) << 32) | data[len - 1] as u64;
            // b = 0;
        }
    } else {
        let mut slice = data;

        // the v1.x.x versions of rapidhash had a bug where this if statement was omitted, which
        // caused the hash to be incorrect for 48 byte inputs. The v2.x.x versions of this crate
        // incorrectly handled the V1_BUG... The v3.x.x versions of this crate should now match
        // the buggy v1.x.x crate version when V1_BUG=true. Kicking myself for this one.
        if slice.len() > 48 || V1_BUG {
            // most CPUs appear to benefit from this unrolled loop
            let mut see1 = seed;
            let mut see2 = seed;

            if !COMPACT {
                while slice.len() >= 96 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                    see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                    see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[0], read_u64(slice, 56) ^ seed);
                    see1 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[1], read_u64(slice, 72) ^ see1);
                    see2 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[2], read_u64(slice, 88) ^ see2);
                    let (_, split) = slice.split_at(96);
                    slice = split;
                }
                if slice.len() >= 48 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                    see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                    see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                    let (_, split) = slice.split_at(48);
                    slice = split;
                }
            } else {
                while slice.len() >= 48 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                    see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                    see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                    let (_, split) = slice.split_at(48);
                    slice = split;
                }
            }
            seed ^= see1 ^ see2;
        }

        if slice.len() > 16 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed ^ secrets[1]);
            if slice.len() > 32 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
            }
        }

        a ^= read_u64(data, data.len() - 16);
        b ^= read_u64(data, data.len() - 8);
    }

    a ^= secrets[1];
    b ^= seed;

    let (a2, b2) = rapid_mum::<PROTECTED>(a, b);
    a = a2;
    b = b2;

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, data.len() as u64, secrets)
    } else {
        a ^ b
    }
}

#[inline(always)]
pub(super) const fn rapidhash_finish<const PROTECTED: bool>(a: u64, b: u64, len: u64, secrets: &[u64; 3]) -> u64 {
    rapid_mix::<PROTECTED>(a ^ secrets[0] ^ len, b ^ secrets[1])
}
