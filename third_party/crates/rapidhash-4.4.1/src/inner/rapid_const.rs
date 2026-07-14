use crate::util::hints::{assume, likely, unlikely};
use super::mix_np::{rapid_mix_np, rapid_mum_np};
use super::read_np::{read_u32_np, read_u64_np};

#[cfg(test)]
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets};

/// This is a somewhat arbitrary cutoff for the long path.
///
/// It's dependent on the cost of the function call, register clobbering, setup/teardown of the 7
/// independent lanes etc. The current value should be reached by testing against the
/// hash/rapidhash-f/medium benchmarks, and may benefit from being tuned per target platform.
const COLD_PATH_CUTOFF: usize = 400;

/// Rapidhash a single byte stream, matching the C++ implementation, with the default seed.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_rs_inline] instead.
#[inline]
#[cfg(test)]
pub(crate) const fn rapidhash_rs(data: &[u8]) -> u64 {
    rapidhash_rs_inline::<true, false, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash a single byte stream, matching the C++ implementation, with a custom seed.
///
/// Fixed length inputs will greatly benefit from inlining with [rapidhash_rs_inline] instead.
#[inline]
#[cfg(test)]
pub(crate) const fn rapidhash_rs_seeded(data: &[u8], secrets: &RapidSecrets) -> u64 {
    rapidhash_rs_inline::<true, false, false>(data, secrets)
}

/// Rapidhash a single byte stream, matching the C++ implementation.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
/// Can provide large performance uplifts for fixed-length inputs at compile time.
#[inline(always)]
#[cfg(test)]
pub(crate) const fn rapidhash_rs_inline<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(data: &[u8], secrets: &RapidSecrets) -> u64 {
    let seed = secrets.seed;
    let secrets = &secrets.secrets;
    let hash = rapidhash_core::<AVALANCHE, COMPACT, PROTECTED>(seed, secrets, data);
    if AVALANCHE {
        rapid_mix_np::<PROTECTED>(hash, super::DEFAULT_RAPID_SECRETS.secrets[1])
    } else {
        hash
    }
}

#[inline(always)]
#[must_use]
pub(super) const fn rapidhash_core<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    if likely(data.len() <= 16) {
        let mut a = 0;
        let mut b = 0;

        if likely(data.len() >= 8) {
            a = read_u64_np(data, 0);
            b = read_u64_np(data, data.len() - 8);
        } else if likely(data.len() >= 4) {
            a = read_u32_np(data, 0) as u64;
            b = read_u32_np(data, data.len() - 4) as u64;
        } else if !data.is_empty() {
            a = ((data[0] as u64) << 45) | data[data.len() - 1] as u64;
            b = data[data.len() >> 1] as u64;
        }

        seed = seed.wrapping_add(data.len() as u64);
        rapidhash_finish::<AVALANCHE, PROTECTED>(a, b , seed, secrets)
    } else {
        // SAFETY: we have just checked the length is >16
        unsafe {
            rapidhash_core_17_288::<AVALANCHE, COMPACT, PROTECTED>(seed, secrets, data)
        }
    }
}

// Never inline this, keep the small string path as small as possible to improve the inlining
// chances of the write_length_prefix and finish functions. If those two don't get inlined, the
// overall performance can be 5x worse when hashing a single string under 100 bytes. <=288 inputs
// pay the cost of one extra if, and >288 inputs pay one more function call, but this is nominal
// in comparison to the overall hashing cost.
#[cold]
#[inline(never)]
#[must_use]
const unsafe fn rapidhash_core_17_288<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    // SAFETY: we promise to never call this with <=16 length data to omit some bounds checks.
    // This is really intended for codegen-units >1 and/or no LTO.
    assume(data.len() > 16);

    // This branch is a hack to move the function prologue/epilogue (stack spilling) into the >48
    // path as it otherwise unnecessarily hurts the <48 path.
    // - It slows down aarch64 >48 inputs, where there is no stack spill.
    // - It speeds up x86_64 by removing the stack spill on the <48 path, but is
    //   slightly slower on the >48 path... I cannot figure out how to move the spill into the >48
    //   path only but then re-use the already cached <48 path finish. Ideas welcome.
    // - It makes minimal difference on WASM.
    #[cfg(not(target_arch = "aarch64"))]
    if likely(data.len() <= 48) {
        // SAFETY: data.len() is guaranteed to be >16
        return rapidhash_final_48::<AVALANCHE, PROTECTED>(seed, secrets, data, data);
    }

    let mut slice = data;
    if unlikely(data.len() > 48) {
        if unlikely(data.len() > COLD_PATH_CUTOFF) {
            // SAFETY: data.len() is guaranteed to be >COLD_PATH_CUTOFF
            return rapidhash_core_cold::<AVALANCHE, COMPACT, PROTECTED>(seed, secrets, data);
        }

        let mut see1 = seed;
        let mut see2 = seed;

        while slice.len() >= 48 {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
            let (_, split) = slice.split_at(48);
            slice = split;
        }

        seed ^= see1 ^ see2;
    }

    // SAFETY: data.len() is guaranteed to be >48, and therefore >16
    rapidhash_final_48::<AVALANCHE, PROTECTED>(seed, secrets, slice, data)
}

/// The long path, intentionally kept cold because at this length of data the function call is
/// minor, but the complexity of this function — if it were inlined — could prevent x.hash() from
/// being inlined which would have a much higher penalty and prevent other optimisations.
#[cold]
#[inline(never)]
#[must_use]
const unsafe fn rapidhash_core_cold<const AVALANCHE: bool, const COMPACT: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], data: &[u8]) -> u64 {
    // SAFETY: we promise to never call this with <=COLD_PATH_CUTOFF length data to omit some bounds checks
    assume(data.len() > COLD_PATH_CUTOFF);

    let mut slice = data;

    let mut see1 = seed;
    let mut see2 = seed;
    let mut see3 = seed;
    let mut see4 = seed;
    let mut see5 = seed;
    let mut see6 = seed;

    if !COMPACT {
        while slice.len() >= 224 {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
            see3 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 48) ^ secrets[3], read_u64_np(slice, 56) ^ see3);
            see4 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 64) ^ secrets[4], read_u64_np(slice, 72) ^ see4);
            see5 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 80) ^ secrets[5], read_u64_np(slice, 88) ^ see5);
            see6 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 96) ^ secrets[6], read_u64_np(slice, 104) ^ see6);

            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 112) ^ secrets[0], read_u64_np(slice, 120) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 128) ^ secrets[1], read_u64_np(slice, 136) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 144) ^ secrets[2], read_u64_np(slice, 152) ^ see2);
            see3 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 160) ^ secrets[3], read_u64_np(slice, 168) ^ see3);
            see4 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 176) ^ secrets[4], read_u64_np(slice, 184) ^ see4);
            see5 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 192) ^ secrets[5], read_u64_np(slice, 200) ^ see5);
            see6 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 208) ^ secrets[6], read_u64_np(slice, 216) ^ see6);

            let (_, split) = slice.split_at(224);
            slice = split;
        }

        if likely(slice.len() >= 112) {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
            see3 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 48) ^ secrets[3], read_u64_np(slice, 56) ^ see3);
            see4 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 64) ^ secrets[4], read_u64_np(slice, 72) ^ see4);
            see5 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 80) ^ secrets[5], read_u64_np(slice, 88) ^ see5);
            see6 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 96) ^ secrets[6], read_u64_np(slice, 104) ^ see6);
            let (_, split) = slice.split_at(112);
            slice = split;
        }
    } else {
        while slice.len() >= 112 {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
            see3 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 48) ^ secrets[3], read_u64_np(slice, 56) ^ see3);
            see4 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 64) ^ secrets[4], read_u64_np(slice, 72) ^ see4);
            see5 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 80) ^ secrets[5], read_u64_np(slice, 88) ^ see5);
            see6 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 96) ^ secrets[6], read_u64_np(slice, 104) ^ see6);
            let (_, split) = slice.split_at(112);
            slice = split;
        }
    }

    if !COMPACT {
        if slice.len() >= 48 {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
            let (_, split) = slice.split_at(48);
            slice = split;

            if slice.len() >= 48 {
                seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
                see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
                see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
                let (_, split) = slice.split_at(48);
                slice = split;
            }
        }
    } else {
        while slice.len() >= 48 {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
            see1 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[1], read_u64_np(slice, 24) ^ see1);
            see2 = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 32) ^ secrets[2], read_u64_np(slice, 40) ^ see2);
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

    rapidhash_final_48::<AVALANCHE, PROTECTED>(seed, secrets, slice, data)
}

#[inline(always)]
#[must_use]
const unsafe fn rapidhash_final_48<const AVALANCHE: bool, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], slice: &[u8], data: &[u8]) -> u64 {
    // SAFETY: the final 48 byte handling is only called with >16 length data
    assume(data.len() > 16);

    if likely(slice.len() > 16) {
        seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 0) ^ secrets[0], read_u64_np(slice, 8) ^ seed);
        if likely(slice.len() > 32) {
            seed = rapid_mix_np::<PROTECTED>(read_u64_np(slice, 16) ^ secrets[0], read_u64_np(slice, 24) ^ seed);
        }
    }

    let a = read_u64_np(data, data.len() - 16);
    let b = read_u64_np(data, data.len() - 8);
    seed = seed.wrapping_add(data.len() as u64);
    rapidhash_finish::<AVALANCHE, PROTECTED>(a, b, seed, secrets)
}

#[inline(always)]
#[must_use]
const fn rapidhash_finish<const AVALANCHE: bool, const PROTECTED: bool>(mut a: u64, mut b: u64, seed: u64, secrets: &[u64; 7]) -> u64 {
    a ^= secrets[0];
    b ^= seed;

    (a, b) = rapid_mum_np::<PROTECTED>(a, b);

    if AVALANCHE {
        // we keep RAPID_CONST constant as the XOR 0xaa can be done in a single instruction on some
        // platforms, whereas it would require an additional load for a random secret.
        rapid_mix_np::<PROTECTED>(a ^ 0xaaaaaaaaaaaaaaaa ^ seed, b ^ secrets[1])
    } else {
        a ^ b
    }
}
