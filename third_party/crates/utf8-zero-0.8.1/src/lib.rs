#![no_std]
#![deny(missing_docs)]

//! Zero-copy, incremental UTF-8 decoding with error handling.
//!
//! Three levels of API:
//!
//! * [`decode()`] -- low-level, single-shot decode of a byte slice. Returns the valid
//!   prefix and either an invalid sequence or an incomplete suffix that can be completed
//!   with more input.
//! * [`LossyDecoder`] -- a push-based streaming decoder. Feed it chunks of bytes and it
//!   calls back with `&str` slices, replacing errors with U+FFFD.
//! * [`BufReadDecoder`] (requires the `std` feature) -- a pull-based streaming decoder
//!   wrapping any [`std::io::BufRead`], with both strict and lossy modes.

#[cfg(feature = "std")]
extern crate std;

mod lossy;
#[cfg(feature = "std")]
mod read;

pub use lossy::LossyDecoder;
#[cfg(feature = "std")]
pub use read::{BufReadDecoder, BufReadDecoderError};

use core::cmp;
use core::fmt;
use core::str;

/// The replacement character, U+FFFD. In lossy decoding, insert it for every decoding error.
pub const REPLACEMENT_CHARACTER: &str = "\u{FFFD}";

/// Error from [`decode()`] when the input is not entirely valid UTF-8.
#[derive(Debug, Copy, Clone)]
pub enum DecodeError<'a> {
    /// In lossy decoding insert `valid_prefix`, then `"\u{FFFD}"`,
    /// then call `decode()` again with `remaining_input`.
    Invalid {
        /// The leading valid UTF-8 portion of the input.
        valid_prefix: &'a str,
        /// The bytes that form the invalid sequence.
        invalid_sequence: &'a [u8],
        /// The bytes after the invalid sequence, not yet decoded.
        remaining_input: &'a [u8],
    },

    /// Call the `incomplete_suffix.try_complete` method with more input when available.
    /// If no more input is available, this is an invalid byte sequence.
    Incomplete {
        /// The leading valid UTF-8 portion of the input.
        valid_prefix: &'a str,
        /// The trailing bytes that start a multi-byte code point but are not complete.
        incomplete_suffix: Incomplete,
    },
}

impl<'a> fmt::Display for DecodeError<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            DecodeError::Invalid {
                valid_prefix,
                invalid_sequence,
                remaining_input,
            } => write!(
                f,
                "found invalid byte sequence {invalid_sequence:02x?} after \
                 {valid_byte_count} valid bytes, followed by {unprocessed_byte_count} more \
                 unprocessed bytes",
                invalid_sequence = invalid_sequence,
                valid_byte_count = valid_prefix.len(),
                unprocessed_byte_count = remaining_input.len()
            ),
            DecodeError::Incomplete {
                valid_prefix,
                incomplete_suffix,
            } => write!(
                f,
                "found incomplete byte sequence {incomplete_suffix:02x?} after \
                 {valid_byte_count} bytes",
                incomplete_suffix = incomplete_suffix,
                valid_byte_count = valid_prefix.len()
            ),
        }
    }
}

#[cfg(feature = "std")]
impl<'a> std::error::Error for DecodeError<'a> {}

/// An incomplete byte sequence for a multi-byte UTF-8 code point.
///
/// Feed more bytes via [`try_complete()`](Incomplete::try_complete) to finish decoding.
#[derive(Debug, Copy, Clone)]
pub struct Incomplete {
    /// Internal buffer holding the incomplete bytes (up to 4).
    pub buffer: [u8; 4],
    /// How many bytes in `buffer` are occupied.
    pub buffer_len: u8,
}

/// Decode a byte slice as UTF-8, returning the valid prefix on error.
///
/// Unlike [`std::str::from_utf8()`], this distinguishes between invalid and
/// incomplete byte sequences so that callers can request more input.
///
/// ```
/// use utf8_zero::{decode, DecodeError};
///
/// // Fully valid input.
/// assert_eq!(decode(b"hello").unwrap(), "hello");
///
/// // Invalid byte — returns the valid prefix and the bad sequence.
/// match decode(b"hello\xC0world") {
///     Err(DecodeError::Invalid { valid_prefix, .. }) => {
///         assert_eq!(valid_prefix, "hello");
///     }
///     _ => unreachable!(),
/// }
///
/// // Input ends mid-codepoint — returns Incomplete so the caller can
/// // supply more bytes.
/// match decode(b"\xC3") {
///     Err(DecodeError::Incomplete { valid_prefix, incomplete_suffix }) => {
///         assert_eq!(valid_prefix, "");
///         assert_eq!(incomplete_suffix.buffer_len, 1);
///     }
///     _ => unreachable!(),
/// }
/// ```
pub fn decode(input: &[u8]) -> Result<&str, DecodeError<'_>> {
    let error = match str::from_utf8(input) {
        Ok(valid) => return Ok(valid),
        Err(error) => error,
    };

    // FIXME: separate function from here to guide inlining?
    let (valid, after_valid) = input.split_at(error.valid_up_to());
    let valid = unsafe { str::from_utf8_unchecked(valid) };

    match error.error_len() {
        Some(invalid_sequence_length) => {
            let (invalid, rest) = after_valid.split_at(invalid_sequence_length);
            Err(DecodeError::Invalid {
                valid_prefix: valid,
                invalid_sequence: invalid,
                remaining_input: rest,
            })
        }
        None => Err(DecodeError::Incomplete {
            valid_prefix: valid,
            incomplete_suffix: Incomplete::new(after_valid),
        }),
    }
}

impl Incomplete {
    /// Create an empty `Incomplete` with no buffered bytes.
    pub fn empty() -> Self {
        Incomplete {
            buffer: [0, 0, 0, 0],
            buffer_len: 0,
        }
    }

    /// Returns `true` if no bytes are buffered.
    pub fn is_empty(&self) -> bool {
        self.buffer_len == 0
    }

    /// Create an `Incomplete` pre-filled with the given bytes.
    pub fn new(bytes: &[u8]) -> Self {
        let mut buffer = [0, 0, 0, 0];
        let len = bytes.len();
        buffer[..len].copy_from_slice(bytes);
        Incomplete {
            buffer,
            buffer_len: len as u8,
        }
    }

    /// * `None`: still incomplete, call `try_complete` again with more input.
    ///   If no more input is available, this is invalid byte sequence.
    /// * `Some((result, remaining_input))`: We’re done with this `Incomplete`.
    ///   To keep decoding, pass `remaining_input` to `decode()`.
    #[allow(clippy::type_complexity)]
    pub fn try_complete<'input>(
        &mut self,
        input: &'input [u8],
    ) -> Option<(Result<&str, &[u8]>, &'input [u8])> {
        let (consumed, opt_result) = self.try_complete_offsets(input);
        let result = opt_result?;
        let remaining_input = &input[consumed..];
        let result_bytes = self.take_buffer();
        let result = match result {
            Ok(()) => Ok(unsafe { str::from_utf8_unchecked(result_bytes) }),
            Err(()) => Err(result_bytes),
        };
        Some((result, remaining_input))
    }

    fn take_buffer(&mut self) -> &[u8] {
        let len = self.buffer_len as usize;
        self.buffer_len = 0;
        &self.buffer[..len]
    }

    /// (consumed_from_input, None): not enough input
    /// (consumed_from_input, Some(Err(()))): error bytes in buffer
    /// (consumed_from_input, Some(Ok(()))): UTF-8 string in buffer
    fn try_complete_offsets(&mut self, input: &[u8]) -> (usize, Option<Result<(), ()>>) {
        let initial_buffer_len = self.buffer_len as usize;
        let copied_from_input;
        {
            let unwritten = &mut self.buffer[initial_buffer_len..];
            copied_from_input = cmp::min(unwritten.len(), input.len());
            unwritten[..copied_from_input].copy_from_slice(&input[..copied_from_input]);
        }
        let spliced = &self.buffer[..initial_buffer_len + copied_from_input];
        match str::from_utf8(spliced) {
            Ok(_) => {
                self.buffer_len = spliced.len() as u8;
                (copied_from_input, Some(Ok(())))
            }
            Err(error) => {
                let valid_up_to = error.valid_up_to();
                if valid_up_to > 0 {
                    let consumed = valid_up_to.checked_sub(initial_buffer_len).unwrap();
                    self.buffer_len = valid_up_to as u8;
                    (consumed, Some(Ok(())))
                } else {
                    match error.error_len() {
                        Some(invalid_sequence_length) => {
                            let consumed = invalid_sequence_length
                                .checked_sub(initial_buffer_len)
                                .unwrap();
                            self.buffer_len = invalid_sequence_length as u8;
                            (consumed, Some(Err(())))
                        }
                        None => {
                            self.buffer_len = spliced.len() as u8;
                            (copied_from_input, None)
                        }
                    }
                }
            }
        }
    }
}
