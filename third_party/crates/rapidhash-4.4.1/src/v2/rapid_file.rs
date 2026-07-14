use std::fs::File;
use std::io::{BufReader, Read};
use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32, read_u64};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets, rapidhash_finish};

/// Rapidhash V2.2 a file, matching the C++ implementation.
///
/// See [rapidhash_v2_file_inline] to compute the hash value using V2.0 or V2.2.
///
/// This method will check the metadata for a file length, and then stream the file with a
/// [BufReader] to compute the hash. This avoids loading the entire file into memory.
#[inline]
#[deprecated(note = "Rapidhash V2 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v2_2_file(data: &mut File) -> std::io::Result<u64> {
    #[allow(deprecated)]
    rapidhash_v2_file_inline::<2, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash V2.2 a file, matching the C++ implementation, with a custom seed.
///
/// See [rapidhash_v2_file_inline] to compute the hash value using V2.0 or V2.2.
///
/// This method will check the metadata for a file length, and then stream the file with a
/// [BufReader] to compute the hash. This avoids loading the entire file into memory.
#[inline]
#[deprecated(note = "Rapidhash V2 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v2_2_file_seeded(data: &mut File, secrets: &RapidSecrets) -> std::io::Result<u64> {
    #[allow(deprecated)]
    rapidhash_v2_file_inline::<2, false>(data, secrets)
}

/// Rapidhash V2 a file, matching the C++ implementation. (2.0, 2.1, and 2.2 supported)
///
/// This method will check the metadata for a file length, and then stream the file with a
/// [BufReader] to compute the hash. This avoids loading the entire file into memory.
///
/// We could easily add more ways to read other streams that can be converted to a [BufReader],
/// but the length must be known at the start of the stream due to how rapidhash is seeded using
/// the data length. Raise a [GitHub](https://github.com/hoxxep/rapidhash) issue if you have a
/// use case to support other stream types.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
/// Can provide large performance uplifts for inputs where the length is known at compile time.
///
/// `MINOR` is the minor version of the rapidhash algorithm:
/// - 0: v2.0
/// - 1: v2.1
/// - 2: v2.2
#[inline(always)]
#[deprecated(note = "Rapidhash V2 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v2_file_inline<const MINOR: u8, const PROTECTED: bool>(data: &mut File, secrets: &RapidSecrets) -> std::io::Result<u64> {
    let len = data.metadata()?.len();
    let mut reader = BufReader::new(data);
    let hash = rapidhash_file_core::<MINOR, PROTECTED>(secrets.seed, &secrets.secrets, len as usize, &mut reader)?;
    Ok(hash)
}

#[inline(always)]
fn rapidhash_file_core<const MINOR: u8, const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 7], len: usize, iter: &mut BufReader<&mut File>) -> std::io::Result<u64> {
    if MINOR > 2 {
        panic!("rapidhash_file_core does not support minor version {}. Supported versions are 0, 1, and 2.", MINOR);
    }

    let mut a = 0;
    let mut b = 0;
    seed ^= len as u64;

    if len <= 16 {
        let mut buf = [0u8; 16];
        iter.read_exact(&mut buf[0..len])?;
        let data = &buf[..len];

        if data.len() >= 4 {
            if data.len() >= 8 {
                let plast = data.len() - 8;
                a = read_u64(data, 0);
                b = read_u64(data, plast);
            } else {
                let plast = data.len() - 4;
                a = read_u32(data, 0) as u64;
                b = read_u32(data, plast) as u64;
            }
        } else if !data.is_empty() {
            if MINOR < 2 {
                a = ((data[0] as u64) << 56) | ((data[data.len() >> 1] as u64) << 32) | data[data.len() - 1] as u64;
            } else {
                a = ((data[0] as u64) << 56) | data[data.len() - 1] as u64;
                b = data[data.len() >> 1] as u64;
            }
        }
    } else if (MINOR >= 1 && len > 64) || (MINOR == 0 && len > 56) {
        let mut remaining = len;
        let mut buf = [0u8; 448];

        // slice is a view on the buffer that we use for reading into, and reading from, depending
        // on the stage of the loop.
        let mut slice = &mut buf[..224];

        // because we're using a buffered reader, it might be worth unrolling this loop further
        let mut see1 = seed;
        let mut see2 = seed;
        let mut see3 = seed;
        let mut see4 = seed;
        let mut see5 = seed;
        let mut see6 = seed;

        while remaining >= 224 {
            // read into and process using the first half of the buffer
            iter.read_exact(slice)?;

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

            remaining -= 224;
        }

        // remaining might be up to 224 bytes, so we read into the second half of the buffer,
        // which allows us to negative index safely in the final a and b xor using `end`.
        slice = &mut buf[224..224 + remaining];
        iter.read_exact(slice)?;
        let end = 224 + remaining;

        if slice.len() >= 112 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            see3 = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ see3);
            see4 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ see4);
            see5 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[5], read_u64(slice, 88) ^ see5);
            see6 = rapid_mix::<PROTECTED>(read_u64(slice, 96) ^ secrets[6], read_u64(slice, 104) ^ see6);
            slice = &mut slice[112..remaining];
            remaining -= 112;
        }

        if remaining >= 48 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
            see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
            see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
            slice = &mut slice[48..remaining];
            remaining -= 48;

            if remaining >= 48 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                slice = &mut slice[48..remaining];
                remaining -= 48;
            }
        }

        see3 ^= see4;
        see5 ^= see6;
        seed ^= see1;
        see3 ^= see2;
        seed ^= see5;
        seed ^= see3;

        if remaining > 16 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed);
            if remaining > 32 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
            }
        }

        a ^= read_u64(&buf, end - 16);
        b ^= read_u64(&buf, end - 8);
    } else {
        let data = &mut [0u8; 64];
        iter.read_exact(&mut data[0..len])?;
        let slice = &data[..len];

        seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
        if slice.len() > 32 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ seed);
            if slice.len() > 48 {
                let index: usize = if MINOR < 2 { 0 } else { 1 };
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[index], read_u64(slice, 40) ^ seed);
            }
        }

        a = read_u64(slice, slice.len() - 16);
        b = read_u64(slice, slice.len() - 8);
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);
    let hash = rapidhash_finish::<PROTECTED>(a, b, len as u64, secrets);
    Ok(hash)
}

#[cfg(test)]
mod tests {
    #![allow(deprecated)]

    use std::io::{Seek, SeekFrom, Write};
    use crate::util::macros::compare_rapidhash_file;
    use crate::v2::rapidhash_v2_inline;
    use super::*;

    compare_rapidhash_file!(compare_rapidhash_v2_0_file, rapidhash_v2_inline::<0, true, false, false>, rapidhash_v2_file_inline::<0, false>);
    compare_rapidhash_file!(compare_rapidhash_v2_1_file, rapidhash_v2_inline::<1, true, false, false>, rapidhash_v2_file_inline::<1, false>);
    compare_rapidhash_file!(compare_rapidhash_v2_2_file, rapidhash_v2_inline::<2, true, false, false>, rapidhash_v2_file_inline::<2, false>);
}
