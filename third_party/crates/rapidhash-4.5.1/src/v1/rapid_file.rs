use std::fs::File;
use std::io::{BufReader, Read};
use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32_combined, read_u64};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets, rapidhash_finish};

/// Rapidhash a file, matching the C++ implementation.
///
/// This method will check the metadata for a file length, and then stream the file with a
/// [BufReader] to compute the hash. This avoids loading the entire file into memory.
#[inline]
#[deprecated(note = "Rapidhash V1 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v1_file(data: &mut File) -> std::io::Result<u64> {
    #[allow(deprecated)]
    rapidhash_v1_file_inline::<false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash a file, matching the C++ implementation, with a custom seed.
///
/// This method will check the metadata for a file length, and then stream the file with a
/// [BufReader] to compute the hash. This avoids loading the entire file into memory.
#[inline]
#[deprecated(note = "Rapidhash V1 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v1_file_seeded(data: &mut File, secrets: &RapidSecrets) -> std::io::Result<u64> {
    #[allow(deprecated)]
    rapidhash_v1_file_inline::<false>(data, secrets)
}

/// Rapidhash a file, matching the C++ implementation.
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
#[inline(always)]
#[deprecated(note = "Rapidhash V1 is not a streaming algorithm. We recommend using V3 instead.")]
pub fn rapidhash_v1_file_inline<const PROTECTED: bool>(data: &mut File, secrets: &RapidSecrets) -> std::io::Result<u64> {
    let len = data.metadata()?.len();
    let mut reader = BufReader::new(data);
    let hash = rapidhash_file_core::<PROTECTED>(secrets.seed, &secrets.secrets, len as usize, &mut reader)?;
    Ok(hash)
}

#[inline(always)]
fn rapidhash_file_core<const PROTECTED: bool>(mut seed: u64, secrets: &[u64; 3], len: usize, iter: &mut BufReader<&mut File>) -> std::io::Result<u64> {
    let mut a = 0;
    let mut b = 0;
    seed ^= len as u64;

    if len <= 16 {
        let mut data = [0u8; 16];
        iter.read_exact(&mut data[0..len])?;

        // deviation from the C++ impl computes delta as follows
        // let delta = (data.len() & 24) >> (data.len() >> 3);
        // this is equivalent to "match {..8=>0, 8..=>4}"
        // and so using the extra if-else statement is equivalent and allows the compiler to skip
        // some unnecessary bounds checks while still being safe rust.
        if len >= 8 {
            // len is 8..=16
            let plast = len - 4;
            let delta = 4;
            a ^= read_u32_combined(&data, 0, plast);
            b ^= read_u32_combined(&data, delta, plast - delta);
        } else if len >= 4 {
            // len is 4..=7
            let plast = len - 4;
            let delta = 0;
            a ^= read_u32_combined(&data, 0, plast);
            b ^= read_u32_combined(&data, delta, plast - delta);
        } else if len > 0 {
            // len is 1..=3
            a ^= ((data[0] as u64) << 56) | ((data[len >> 1] as u64) << 32) | data[len - 1] as u64;
            // b = 0;
        }
    } else {
        let mut remaining = len;
        let mut buf = [0u8; 192];

        // slice is a view on the buffer that we use for reading into, and reading from, depending
        // on the stage of the loop.
        let mut slice = &mut buf[..96];
        let end;

        if remaining > 48 {
            // because we're using a buffered reader, it might be worth unrolling this loop further
            let mut see1 = seed;
            let mut see2 = seed;
            while remaining >= 96 {
                // read into and process using the first half of the buffer
                iter.read_exact(slice)?;
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[0], read_u64(slice, 56) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[1], read_u64(slice, 72) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[2], read_u64(slice, 88) ^ see2);
                remaining -= 96;
            }

            // remaining might be up to 95 bytes, so we read into the second half of the buffer,
            // which allows us to negative index safely in the final a and b xor using `end`.
            slice = &mut buf[96..96 + remaining];
            iter.read_exact(slice)?;
            end = 96 + remaining;

            if remaining >= 48 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ seed);
                see1 = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ see1);
                see2 = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ see2);
                slice = &mut buf[96 + 48..96 + remaining];
                remaining -= 48;
            }

            seed ^= see1 ^ see2;
        } else {
            end = remaining;
            slice = &mut buf[..remaining];
            iter.read_exact(slice)?;
        }

        if remaining > 16 {
            seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[2], read_u64(slice, 8) ^ seed ^ secrets[1]);
            if remaining > 32 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[2], read_u64(slice, 24) ^ seed);
            }
        }

        a ^= read_u64(&buf, end - 16);
        b ^= read_u64(&buf, end - 8);
    }

    a ^= secrets[1];
    b ^= seed;

    (a, b) = rapid_mum::<PROTECTED>(a, b);
    Ok(rapidhash_finish::<PROTECTED>(a, b, len as u64, secrets))
}

#[cfg(test)]
mod tests {
    #![allow(deprecated)]
    use std::io::{Seek, SeekFrom, Write};
    use crate::util::macros::compare_rapidhash_file;
    use crate::v1::rapidhash_v1_inline;
    use super::*;

    compare_rapidhash_file!(compare_rapidhash_v1_file, rapidhash_v1_inline::<true, false, false, false>, rapidhash_v1_file_inline::<false>);
}
