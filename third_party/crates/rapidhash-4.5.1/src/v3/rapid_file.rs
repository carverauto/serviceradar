use std::io::Read;
use crate::util::hints::{likely, unlikely};
use super::{DEFAULT_RAPID_SECRETS, RapidSecrets, RapidStreamHasherInlineV3};

/// Rapidhash a stream or file, matching the C++ implementation.
///
/// This is a streaming implementation of rapidhash v3. It will produce exactly the same output as
/// [`crate::v3::rapidhash_v3`], but accepts a streaming `Read` interface.
///
/// This implementation makes use of the incremental [`RapidStreamHasherInlineV3`] interface, which
/// may be preferred over a `Read` interface for some streaming use cases.
#[inline]
pub fn rapidhash_v3_file<R: Read>(data: R) -> std::io::Result<u64> {
    rapidhash_v3_file_inline::<R, false>(data, &DEFAULT_RAPID_SECRETS)
}

/// Rapidhash a stream or file, matching the C++ implementation, with a custom seed.
///
/// This is a streaming implementation of rapidhash v3. It will produce exactly the same output as
/// [`crate::v3::rapidhash_v3_seeded`], but accepts a streaming `Read` interface.
///
/// This implementation makes use of the incremental [`RapidStreamHasherInlineV3`] interface, which
/// may be preferred over a `Read` interface for some streaming use cases.
#[inline]
pub fn rapidhash_v3_file_seeded<R: Read>(data: R, secrets: &RapidSecrets) -> std::io::Result<u64> {
    rapidhash_v3_file_inline::<R, false>(data, secrets)
}

/// Rapidhash a stream or file, matching the C++ implementation.
///
/// This is a streaming implementation of rapidhash v3. It will produce exactly the same output as
/// [`crate::v3::rapidhash_v3_inline`], but accepts a streaming `Read` interface.
///
/// Is marked with `#[inline(always)]` to force the compiler to inline and optimize the method.
///
/// This implementation makes use of the incremental [`RapidStreamHasherInlineV3`] interface, which
/// may be preferred over a `Read` interface for some streaming use cases.
#[inline(always)]
pub fn rapidhash_v3_file_inline<R: Read, const PROTECTED: bool>(mut data: R, secrets: &RapidSecrets) -> std::io::Result<u64> {
    let mut hasher = RapidStreamHasherInlineV3::<true, PROTECTED>::new(secrets);
    let mut buf = [0u8; 8 * 1024];  // TODO(v5): make the buffer size configurable.
    let mut pos = 0;
    loop {
        let n = data.read(&mut buf[pos..])?;
        pos += n;

        // The Read interface _forces_ us to copy into `buf`, but we then want to avoid the
        // double-copy into the `RapidStreamHasher` buffer too. So if an interface is giving us
        // lots of small reads, it's better to cache these all in the `buf` so that the
        // `hasher.write` call will zero-copy most of the buffer in 112 byte chunks.
        if likely(n > 0 && pos < buf.len()) {
            continue;
        }

        hasher.write(&buf[..pos]);

        if unlikely(n == 0) {
            break;
        }

        pos = 0;
    }

    Ok(hasher.finish())
}

#[cfg(test)]
mod tests {
    use std::io::{Seek, SeekFrom, Write};
    use crate::util::macros::compare_rapidhash_file;
    use crate::v3::rapidhash_v3_inline;
    use super::*;

    compare_rapidhash_file!(compare_rapidhash_v1_file, rapidhash_v3_inline::<true, false, false>, rapidhash_v3_file_inline::<_, false>);
}
