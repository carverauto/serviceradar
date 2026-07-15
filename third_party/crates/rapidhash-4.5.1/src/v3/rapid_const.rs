use crate::util::hints::{assume, likely, unlikely};
use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32, read_u64};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets};

/// Rapidhash V3 a single byte stream, matching the C++ implementation, with the default seed.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_v3_inline] instead.
#[inline]
pub const fn rapidhash_v3(data: &[u8]) -> u64 {
    rapidhash_v3_inline::<true, false, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash V3 a single byte stream, matching the C++ implementation, with a custom seed.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_v3_inline] instead.
#[inline]
pub const fn rapidhash_v3_seeded(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_v3_inline::<true, false, false>(data, secrets)
}

/// Rapidhash V3 a single byte stream, matching the C++ implementation.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
/// Can provide large performance uplifts for fixed-length inputs at compile time.
///
/// Compile time arguments:
/// - `AVALANCHE`: Perform an extra mix step to avalanche the bits for higher hash quality. Enabled
///   by default to match the C++ implementation.
/// - `COMPACT`: Generates fewer instructions at compile time with less manual loop unrolling, but
///   may be slower on some platforms. Disabled by default.
/// - `PROTECTED`: Slightly stronger hash quality and DoS resistance by performing two extra XOR
///   instructions on every mix step. Disabled by default.
#[inline(always)]
pub const fn rapidhash_v3_inline<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_core::<AVALANCHE, COMPACT, PROTECTED>(secrets.seed, &secrets.secrets, data)
}

/// Rapidhash V3 Micro, a very compact version of the rapidhash algorithm.
///
/// WARNING: This produces a different output from `rapidhash_v3`.
///
/// Designed for HPC and server applications, where cache misses make a noticeable performance
/// detriment. Compiles it to ~140 instructions without stack usage, both on x86-64 and aarch64.
/// Faster for sizes up to 512 bytes, just 15%-20% slower for inputs above 1kb.
///
/// Compile time arguments:
/// - `AVALANCHE`: Perform an extra mix step to avalanche the bits for higher hash quality. Enabled
///   by default to match the C++ implementation.
/// - `PROTECTED`: Slightly stronger hash quality and DoS resistance by performing two extra XOR
///   instructions on every mix step. Disabled by default.
#[inline(always)]
pub const fn rapidhash_v3_micro_inline<const AVALANCHE: bool, const PROTECTED: bool>(data: &[u8], seed: &RapidSecrets) -> u64 {
    rapidhash_micro_core::<AVALANCHE, PROTECTED>(seed.seed, &seed.secrets, data)
}

/// Rapidhash V3 Nano, a very compact version of the rapidhash algorithm.
///
/// WARNING: This produces a different output from `rapidhash_v3`.
///
/// Designed for Mobile and embedded applications, where keeping a small code size is a top priority.
/// This should compile it to less than 100 instructions with minimal stack usage, both on x86-64
/// and aarch64. The fastest for sizes up to 48 bytes, but may be considerably slower for larger
/// inputs.
///
/// Compile time arguments:
/// - `AVALANCHE`: Perform an extra mix step to avalanche the bits for higher hash quality. Enabled
///   by default to match the C++ implementation.
/// - `PROTECTED`: Slightly stronger hash quality and DoS resistance by performing two extra XOR
///   instructions on every mix step. Disabled by default.
#[inline(always)]
pub const fn rapidhash_v3_nano_inline<const AVALANCHE: bool, const PROTECTED: bool>(data: &[u8], seed: &RapidSecrets) -> u64 {
    rapidhash_nano_core::<AVALANCHE, PROTECTED>(seed.seed, &seed.secrets, data)
}

#[inline(always)]
pub(super) const fn rapidhash_core<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    let mut a;
    let mut b;

    let remainder;
    if likely(data.len() <= 16) {
        a = 0;
        b = 0;

        if data.len() >= 4 {
            seed ^= data.len() as u64;
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
            a ^= ((data[0] as u64) << 45) | data[data.len() - 1] as u64;
            b ^= data[data.len() >> 1] as u64;
        }
        remainder = data.len() as u64;
    } else {
        // SAFETY: we have just verified that data.len() > 16
        unsafe {
            return rapidhash_core_cold::<AVALANCHE, COMPACT, PROTECTED>(seed, secrets, data);
        }
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, remainder, secrets)
    } else {
        a ^ b
    }
}

// This is sadly a fat function with a lot of calling overhead because it clobbers registers.
// Great for reaching max performance on 1kB+ inputs, but not great for 25 byte
// inputs... We therefore mark this as #[inline] to let the compiler decide whether to inline it or
// not, if it knows the input size. If the input size is known to be <112, there's a lot to gain
// through inlining and optimising away the 7 data-independent execution paths. The RapidHasher
// deviates from the V3 implementation here because of this!
#[inline]
const unsafe fn rapidhash_core_cold<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    // SAFETY: we promise to never call this with <=16 length data to omit some bounds checks.
    // This is really intended for codegen-units >1 and/or no LTO.
    assume(data.len() > 16);

    let mut a = 0;
    let mut b = 0;

    let mut slice = data;

    if unlikely(slice.len() > 112) {
        // most CPUs appear to benefit from this unrolled loop
        let mut see1 = seed;
        let mut see2 = seed;
        let mut see3 = seed;
        let mut see4 = seed;
        let mut see5 = seed;
        let mut see6 = seed;

        if !COMPACT {
            while slice.len() > 224 {
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

            if slice.len() > 112 {
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
        } else {
            while slice.len() > 112 {
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
        }

        seed ^= see1;
        see2 ^= see3;
        see4 ^= see5;
        seed ^= see6;
        see2 ^= see4;
        seed ^= see2;
    }

    if slice.len() > 16 {
        seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed);
        if slice.len() > 32 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
            if slice.len() > 48 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[1], read_u64(slice, 40) ^ seed);
                if slice.len() > 64 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[1], read_u64(slice, 56) ^ seed);
                    if slice.len() > 80 {
                        seed = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[2], read_u64(slice, 72) ^ seed);
                        if slice.len() > 96 {
                            seed = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[1], read_u64(slice, 88) ^ seed);
                        }
                    }
                }
            }
        }
    }

    a ^= read_u64(data, data.len() - 16) ^ slice.len() as u64;
    b ^= read_u64(data, data.len() - 8);

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, slice.len() as u64, secrets)
    } else {
        a ^ b
    }
}

const fn rapidhash_micro_core<const AVALANCHE: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    let mut a = 0;
    let mut b = 0;

    let remainder;
    if likely(data.len() <= 16) {
        if data.len() >= 4 {
            seed ^= data.len() as u64;
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
            a ^= ((data[0] as u64) << 45) | data[data.len() - 1] as u64;
            b ^= data[data.len() >> 1] as u64;
        }
        remainder = data.len() as u64;
    } else {
        let mut slice = data;
        if unlikely(slice.len() > 80) {
            let mut see1 = seed;
            let mut see2 = seed;
            let mut see3 = seed;
            let mut see4 = seed;

            while slice.len() > 80 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                see3 = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ see3);
                see4 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ see4);
                let (_, split) = slice.split_at(80);
                slice = split;
            }

            seed ^= see1;
            see2 ^= see3;
            seed ^= see4;
            seed ^= see2;
        }

        if slice.len() > 16 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed);
            if slice.len() > 32 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
                if slice.len() > 48 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[1], read_u64(slice, 40) ^ seed);
                    if slice.len() > 64 {
                        seed = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[1], read_u64(slice, 56) ^ seed);
                    }
                }
            }
        }

        remainder = slice.len() as u64;
        a ^= read_u64(data, data.len() - 16) ^ remainder;
        b ^= read_u64(data, data.len() - 8);
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);

    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, remainder, secrets)
    } else {
        a ^ b
    }
}

const fn rapidhash_nano_core<const AVALANCHE: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    let mut a = 0;
    let mut b = 0;

    let remainder;
    if likely(data.len() <= 16) {
        if data.len() >= 4 {
            seed ^= data.len() as u64;
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
            a ^= ((data[0] as u64) << 45) | data[data.len() - 1] as u64;
            b ^= data[data.len() >> 1] as u64;
        }
        remainder = data.len() as u64;
    } else {
        let mut slice = data;
        if unlikely(slice.len() > 48) {
            let mut see1 = seed;
            let mut see2 = seed;

            while slice.len() > 48 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                let (_, split) = slice.split_at(48);
                slice = split;
            }

            seed ^= see1;
            seed ^= see2;
        }

        if slice.len() > 16 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed);
            if slice.len() > 32 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
            }
        }

        remainder = slice.len() as u64;
        a ^= read_u64(data, data.len() - 16) ^ remainder;
        b ^= read_u64(data, data.len() - 8);
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);
    if AVALANCHE {
        rapidhash_finish::<PROTECTED>(a, b, remainder, secrets)
    } else {
        a ^ b
    }
}

#[inline(always)]
pub(super) const fn rapidhash_finish<const PROTECTED: bool>(a: u64, b: u64, remainder: u64, secrets: &[u64; 7]) -> u64 {
    rapid_mix::<PROTECTED>(a ^ 0xaaaaaaaaaaaaaaaa, b ^ secrets[1] ^ remainder)
}
