use crate::util::hints::{likely, unlikely};
use crate::util::mix::{rapid_mix, rapid_mum};
use crate::util::read::{read_u32, read_u64};
use crate::v3::rapid_const::rapidhash_finish;
use crate::v3::RapidSecrets;

/// A bytewise-style incremental interface for rapidhash.
///
/// This interface guarantees incremental inputs are the same as a bulk hash of the same bytes.
///
/// See [`RapidStreamHasherInlineV3`] for more details, or view [`crate::v3::rapidhash_v3_file`] for a
/// `Read`-based incremental interface.
///
/// This is a type alias for [`RapidStreamHasherInlineV3`] that sets:
/// - `AVALANCHE`: `true`
/// - `PROTECTED`: `false`
pub type RapidStreamHasherV3<'a> = RapidStreamHasherInlineV3<'a, true, false>;

/// A bytewise-style incremental interface for rapidhash.
///
/// This interface guarantees incremental inputs are the same as a bulk hash of the same bytes.
///
/// See [`crate::v3::rapidhash_v3_file`] for an alternative `Read`-based incremental interface.
///
/// ## Speed
///
/// `RapidStreamHasher` is slower than `rapidhash_v3` due to the extra overhead from the incremental
/// interface. Where possible, we recommend using `rapidhash_v3` for bulk hashing.
///
/// This will copy bytes, except where written chunks are larger than 112 bytes. Larger chunks
/// will perform better than smaller chunks by avoiding copying.
///
/// ## Portability
///
/// `RapidStreamHasher` does not implement `std::hash::Hasher` and is specially designed to produce
/// stable hashes across platforms and compiler versions. Any changes to hash output in
/// `RapidStreamHasher` will result in a major crate bump.
///
/// We're aiming to support the [portable-hash crate](https://github.com/hoxxep/portable-hash) in
/// the future to enable `derive(PortableHash)` on user-defined types. Please leave a comment or
/// upvote if this would be useful to you on a large project.
///
/// ## Example
///
/// ```rust
/// use rapidhash::v3::{rapidhash_v3_seeded, RapidSecrets, RapidStreamHasherV3};
///
/// let secrets = RapidSecrets::seed(0);
/// let data: &[u8] = [0, 1, 2, 3, 4, 5, 6, 7].as_slice();
///
/// // classic rapidhash v3
/// let expected_hash = rapidhash_v3_seeded(data, &secrets);
///
/// // incremental rapidhash v3
/// let mut hasher = RapidStreamHasherV3::new(&secrets);
/// hasher.write(&data[0..3]);
/// hasher.write(&data[3..6]);
/// hasher.write(&data[6..]);
/// let actual_hash = hasher.finish();
///
/// // equal hashes!
/// assert_eq!(expected_hash, actual_hash);
/// ```
pub struct RapidStreamHasherInlineV3<'a, const AVALANCHE: bool, const PROTECTED: bool> {
    seed: u64,
    secrets: &'a [u64; 7],
    state: RapidStreamChunkState<PROTECTED>,

    /// We treat this as an array with two parts, `[CHUNK_PREV] + [CHUNK]` where
    /// the `CHUNK_PREV` is the final 16 bytes of the preceding chunk, and
    /// the `CHUNK` is the latest 112 byte block that we're appending `data` to
    /// before processing once the block has been filled (or `finish()` is
    /// called). Rapidhash in its longest form processes 112 byte blocks.
    buffer: [u8; CHUNK_PREV + CHUNK_SIZE],
}

/// The size of a single rapidhash processing chunk.
const CHUNK_SIZE: usize = 112;

/// The minimum tail we must keep in the buffer for processing.
const CHUNK_PREV: usize = 16;

/// The intermediate hasher state for any full 112-byte chunks that have been written.
///
/// This is separated to allow mutably borrowing the state and buffer at the same time.
struct RapidStreamChunkState<const PROTECTED: bool> {
    seeds: [u64; 7],
    /// `buffer_len` **excludes** the `CHUNK_PREV` bytes
    buffer_len: usize,
    /// Have we processed a full 112-byte chunk?
    processed: bool,
}

impl<'a, const AVALANCHE: bool, const PROTECTED: bool> RapidStreamHasherInlineV3<'a, AVALANCHE, PROTECTED> {
    /// Create a new `RapidStreamHasher` with seed and secrets.
    #[inline(always)]
    pub fn new(secrets: &'a RapidSecrets) -> Self {
        Self {
            seed: secrets.seed,
            secrets: &secrets.secrets,
            state: RapidStreamChunkState::new(secrets.seed),
            buffer: [0; CHUNK_PREV + CHUNK_SIZE],
        }
    }

    /// Write data to the stream hasher.
    #[inline(always)]
    pub fn write(&mut self, data: &[u8]) {
        // if this data doesn't fit in the remaining buffer, slow-path to write the buffer chunk and
        // any full chunks we can process from `data`.
        if unlikely(CHUNK_SIZE < self.state.buffer_len + data.len()) {
            self.write_inner(data);
            return;
        }

        // fast inlined path for copying into the buffer
        let start = CHUNK_PREV + self.state.buffer_len;
        let end = start + data.len();
        self.buffer[start..end].copy_from_slice(data);
        self.state.buffer_len += data.len();
    }

    /// Write cold path that we keep separate so the copy logic is fast.
    #[inline]
    fn write_inner(&mut self, data: &[u8]) {
        // set up arrays: chunk_prev as buffer[..16] and chunk_buffer as buffer[16..]
        let (chunk_prev, chunk_curr) = self.buffer.split_at_mut(CHUNK_PREV);
        let chunk_prev: &mut [u8; CHUNK_PREV] = chunk_prev.try_into().unwrap();
        let chunk_buffer: &mut [u8; CHUNK_SIZE] = chunk_curr.try_into().unwrap();

        // write buffer up to 112 bytes
        let copy_bytes = CHUNK_SIZE - self.state.buffer_len;
        let start = self.state.buffer_len;
        chunk_buffer[start..].copy_from_slice(&data[..copy_bytes]);
        debug_assert_eq!(CHUNK_SIZE, self.state.buffer_len + copy_bytes);

        // write buffer chunk
        self.state.chunk_write(self.secrets, chunk_buffer);

        // write large data chunks without copying
        // Keep back the last chunk when chunk-aligned: rapidhash v3 uses `pos + 112 < len`
        // (not <=), so the final 112 bytes must go through the tail path in finish().
        let remaining_data = &data[copy_bytes..];
        let stop = (remaining_data.len().saturating_sub(1) / CHUNK_SIZE) * CHUNK_SIZE;
        let mut chunk_last = None;
        let mut pos = 0;
        while pos < stop {
            let chunk = remaining_data[pos..pos + CHUNK_SIZE].try_into().unwrap();
            chunk_last = Some(chunk);
            self.state.chunk_write(self.secrets, chunk);
            pos += CHUNK_SIZE;
        }
        let unprocessed_data = &remaining_data[pos..];

        // copy the final 16 data bytes from the previous chunk
        if let Some(chunk) = chunk_last {
            // if the last full chunk was from `data`
            chunk_prev.copy_from_slice(&chunk[CHUNK_SIZE - CHUNK_PREV..]);
        } else {
            // otherwise the last chunk was from the buffer
            let trailing_end = chunk_buffer.len() - CHUNK_PREV;
            chunk_prev.copy_from_slice(&chunk_buffer[trailing_end..]);
        }

        // write remainder into the buffer
        chunk_buffer[..unprocessed_data.len()].copy_from_slice(unprocessed_data);
        self.state.buffer_len = unprocessed_data.len();
    }

    /// Finalize a hash from the hasher state.
    #[inline(always)]
    #[must_use]
    pub fn finish(&self) -> u64 {
        let mut seed = self.seed;
        let mut a;
        let mut b;
        let remainder;

        if likely(!self.state.processed && self.state.buffer_len <= 16) {
            // short <= 16 pass only if we haven't processed a full chunk yet
            let data =
                &self.buffer[CHUNK_PREV..CHUNK_PREV + self.state.buffer_len];

            if data.len() >= 4 {
                seed ^= data.len() as u64;
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
                a = ((data[0] as u64) << 45) | data[data.len() - 1] as u64;
                b = data[data.len() >> 1] as u64;
            } else {
                a = 0;
                b = 0;
            }

            remainder = data.len() as u64;
        } else {
            if self.state.processed {
                // merge independent lanes if we'd previously processed a full 112 byte chunk
                seed =
                    self.state.seeds[0]
                        ^ self.state.seeds[1]
                        ^ self.state.seeds[2]
                        ^ self.state.seeds[3]
                        ^ self.state.seeds[4]
                        ^ self.state.seeds[5]
                        ^ self.state.seeds[6];
            }

            // the >16 tail is the same whether we've processed a full chunk or not
            let slice = &self.buffer[CHUNK_PREV..CHUNK_PREV + self.state.buffer_len];
            if slice.len() > 16 {
                seed = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ self.secrets[2], read_u64(slice, 8) ^ seed);
                if slice.len() > 32 {
                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ self.secrets[2], read_u64(slice, 24) ^ seed);
                    if slice.len() > 48 {
                        seed = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ self.secrets[1], read_u64(slice, 40) ^ seed);
                        if slice.len() > 64 {
                            seed = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ self.secrets[1], read_u64(slice, 56) ^ seed);
                            if slice.len() > 80 {
                                seed = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ self.secrets[2], read_u64(slice, 72) ^ seed);
                                if slice.len() > 96 {
                                    seed = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ self.secrets[1], read_u64(slice, 88) ^ seed);
                                }
                            }
                        }
                    }
                }
            }

            // the final 16 bytes may read from the CHUNK_PREV part of the buffer
            let data = &self.buffer[..CHUNK_PREV + self.state.buffer_len];
            a = read_u64(data, data.len() - 16) ^ slice.len() as u64;
            b = read_u64(data, data.len() - 8);

            // passed to rapidhash_finish
            remainder = self.state.buffer_len as u64;
        }

        a ^= self.secrets[1];
        b ^= seed;

        (a, b) = rapid_mum::<PROTECTED>(a, b);
        if AVALANCHE {
            rapidhash_finish::<PROTECTED>(a, b, remainder, self.secrets)
        } else {
            a ^ b
        }
    }

    /// Reuse the buffer within this RapidStreamHasher.
    #[inline(always)]
    pub fn reset(&mut self) {
        self.state.reset(self.seed);
    }
}

impl<const PROTECTED: bool> RapidStreamChunkState<PROTECTED> {
    #[inline(always)]
    pub fn new(seed: u64) -> Self {
        Self {
            seeds: [seed; 7],
            processed: false,
            buffer_len: 0,
        }
    }

    /// Write a 112-len chunk to the internal state.
    #[inline(always)]
    fn chunk_write(&mut self, secrets: &[u64; 7], chunk: &[u8; 112]) {
        let slice = chunk.as_slice();
        self.seeds[0] = rapid_mix::<PROTECTED>(read_u64(slice, 0) ^ secrets[0], read_u64(slice, 8) ^ self.seeds[0]);
        self.seeds[1] = rapid_mix::<PROTECTED>(read_u64(slice, 16) ^ secrets[1], read_u64(slice, 24) ^ self.seeds[1]);
        self.seeds[2] = rapid_mix::<PROTECTED>(read_u64(slice, 32) ^ secrets[2], read_u64(slice, 40) ^ self.seeds[2]);
        self.seeds[3] = rapid_mix::<PROTECTED>(read_u64(slice, 48) ^ secrets[3], read_u64(slice, 56) ^ self.seeds[3]);
        self.seeds[4] = rapid_mix::<PROTECTED>(read_u64(slice, 64) ^ secrets[4], read_u64(slice, 72) ^ self.seeds[4]);
        self.seeds[5] = rapid_mix::<PROTECTED>(read_u64(slice, 80) ^ secrets[5], read_u64(slice, 88) ^ self.seeds[5]);
        self.seeds[6] = rapid_mix::<PROTECTED>(read_u64(slice, 96) ^ secrets[6], read_u64(slice, 104) ^ self.seeds[6]);
        self.processed = true;
    }

    /// Reuse the buffer within this RapidStreamHasher.
    #[inline(always)]
    pub fn reset(&mut self, seed: u64) {
        self.seeds = [seed; 7];
        self.processed = false;
        self.buffer_len = 0;
    }
}

#[cfg(test)]
mod tests {
    use crate::util::macros::compare_rapid_stream_hasher;
    use crate::v3::{rapidhash_v3_inline, DEFAULT_RAPID_SECRETS};
    use super::*;

    compare_rapid_stream_hasher!(compare_stream_hasher_v3, rapidhash_v3_inline::<true, false, false>, RapidStreamHasherV3<'a>);
    compare_rapid_stream_hasher!(compare_stream_hasher_v3_protected, rapidhash_v3_inline::<true, false, true>, RapidStreamHasherInlineV3::<'a, true, true>);
    compare_rapid_stream_hasher!(compare_stream_hasher_v3_no_avalanche, rapidhash_v3_inline::<false, false, false>, RapidStreamHasherInlineV3::<'a, false, false>);

    #[test]
    fn test_rapid_stream_hasher() {
        let secrets = DEFAULT_RAPID_SECRETS;
        let data: &[u8] = &[0, 1, 2, 3, 4, 5, 6, 7];
        let expected_hash = rapidhash_v3_inline::<true, false, false>(data, &secrets);

        let mut hasher = RapidStreamHasherV3::new(&secrets);
        hasher.write(data);
        assert_eq!(expected_hash, hasher.finish());

        hasher.reset();
        hasher.write(&data[..1]);
        hasher.write(&data[1..3]);
        hasher.write(&data[3..6]);
        hasher.write(&data[6..]);
        assert_eq!(expected_hash, hasher.finish());
    }

    #[test]
    fn test_chunk_writing() {
        let secrets = DEFAULT_RAPID_SECRETS;
        let mut hasher = RapidStreamHasherV3::new(&secrets);

        let mut data = [0; 128];
        for i in 0..data.len() {
            data[i] = i as u8;
        }

        hasher.write(&data);
        assert_eq!(&hasher.buffer[..32], &data[128-32..]);
    }
}
