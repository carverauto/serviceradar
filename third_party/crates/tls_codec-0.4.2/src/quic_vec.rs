//! # Variable length vectors
//!
//! While the TLS RFC 8446 only specifies vectors with fixed length length fields
//! the QUIC RFC 9000 defines a variable length integer encoding.
//!
//! Note that we require, as the MLS specification does, that vectors have to
//! use the minimum number of bytes necessary for the encoding.
//! This ensures that encodings are unique.
//!
//! With the `mls` feature the length of variable length vectors can be limited
//! to 30-bit values.
//! This is in contrast to the default behaviour defined by RFC 9000 that allows
//! up to 62-bit length values.
use super::alloc::vec::Vec;
use core::fmt;

#[cfg(feature = "std")]
use zeroize::{Zeroize, ZeroizeOnDrop};

#[cfg(feature = "arbitrary")]
use arbitrary::{Arbitrary, Unstructured};
#[cfg(feature = "serde")]
use serde::{Deserialize as SerdeDeserialize, Serialize as SerdeSerialize};

use crate::{DeserializeBytes, Error, SerializeBytes, Size};

#[cfg(not(feature = "mls"))]
const MAX_LEN: u64 = (1 << 62) - 1;
#[cfg(not(feature = "mls"))]
const MAX_LEN_LEN_LOG: usize = 3;
#[cfg(feature = "mls")]
const MAX_LEN: u64 = (1 << 30) - 1;
#[cfg(feature = "mls")]
const MAX_LEN_LEN_LOG: usize = 2;

#[inline(always)]
fn check_min_length(length: usize, len_len: usize) -> Result<(), Error> {
    if cfg!(feature = "mls") {
        // ensure that len_len is minimal for the given length
        let min_len_len = length_encoding_bytes(length as u64)?;
        if min_len_len != len_len {
            return Err(Error::InvalidVectorLength);
        }
    };
    Ok(())
}

#[inline(always)]
fn calculate_length(len_len_byte: u8) -> Result<(usize, usize), Error> {
    let length: usize = (len_len_byte & 0x3F).into();
    let len_len_log = (len_len_byte >> 6).into();
    if !cfg!(fuzzing) {
        debug_assert!(len_len_log <= MAX_LEN_LEN_LOG);
    }
    if len_len_log > MAX_LEN_LEN_LOG {
        return Err(Error::InvalidVectorLength);
    }
    let len_len = match len_len_log {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
        _ => unreachable!(),
    };
    Ok((length, len_len))
}

#[inline(always)]
fn read_variable_length_bytes(bytes: &[u8]) -> Result<((usize, usize), &[u8]), Error> {
    // The length is encoded in the first two bits of the first byte.

    let (len_len_byte, mut remainder) = u8::tls_deserialize_bytes(bytes)?;

    let (mut length, len_len) = calculate_length(len_len_byte)?;

    for _ in 1..len_len {
        let (next, next_remainder) = u8::tls_deserialize_bytes(remainder)?;
        remainder = next_remainder;
        length = (length << 8) + usize::from(next);
    }

    check_min_length(length, len_len)?;

    Ok(((length, len_len), remainder))
}

#[inline(always)]
fn length_encoding_bytes(length: u64) -> Result<usize, Error> {
    if !cfg!(fuzzing) {
        debug_assert!(length <= MAX_LEN);
    }
    if length > MAX_LEN {
        return Err(Error::InvalidVectorLength);
    }

    Ok(if length <= 0x3f {
        1
    } else if length <= 0x3fff {
        2
    } else if length <= 0x3fff_ffff {
        4
    } else {
        8
    })
}

#[inline(always)]
pub fn write_variable_length(content_length: usize) -> Result<Vec<u8>, Error> {
    let len_len = length_encoding_bytes(content_length.try_into()?)?;
    if !cfg!(fuzzing) {
        debug_assert!(len_len <= 8, "Invalid vector len_len {len_len}");
    }
    if len_len > 8 {
        return Err(Error::LibraryError);
    }
    let mut length_bytes = vec![0u8; len_len];
    match len_len {
        1 => length_bytes[0] = 0x00,
        2 => length_bytes[0] = 0x40,
        4 => length_bytes[0] = 0x80,
        8 => length_bytes[0] = 0xc0,
        _ => {
            if !cfg!(fuzzing) {
                debug_assert!(false, "Invalid vector len_len {len_len}");
            }
            return Err(Error::InvalidVectorLength);
        }
    }
    let mut len = content_length;
    for b in length_bytes.iter_mut().rev() {
        *b |= (len & 0xFF) as u8;
        len >>= 8;
    }

    Ok(length_bytes)
}

impl<T: Size> Size for Vec<T> {
    #[inline(always)]
    fn tls_serialized_len(&self) -> usize {
        self.as_slice().tls_serialized_len()
    }
}

impl<T: Size> Size for &Vec<T> {
    #[inline(always)]
    fn tls_serialized_len(&self) -> usize {
        (*self).tls_serialized_len()
    }
}

impl<T: DeserializeBytes> DeserializeBytes for Vec<T> {
    #[inline(always)]
    fn tls_deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
        let ((length, len_len), mut remainder) = read_variable_length_bytes(bytes)?;

        if length == 0 {
            // An empty vector.
            return Ok((Vec::new(), remainder));
        }

        let mut result = Vec::new();
        let mut read = len_len;
        while (read - len_len) < length {
            let (element, next_remainder) = T::tls_deserialize_bytes(remainder)?;
            remainder = next_remainder;
            read += element.tls_serialized_len();
            result.push(element);
        }
        Ok((result, remainder))
    }
}

impl<T: SerializeBytes> SerializeBytes for &[T] {
    #[inline(always)]
    fn tls_serialize(&self) -> Result<Vec<u8>, Error> {
        // We need to pre-compute the length of the content.
        // This requires more computations but the other option would be to buffer
        // the entire content, which can end up requiring a lot of memory.
        let content_length = self.iter().fold(0, |acc, e| acc + e.tls_serialized_len());
        let mut length = write_variable_length(content_length)?;
        let len_len = length.len();

        let mut out = Vec::with_capacity(content_length + len_len);
        out.append(&mut length);

        // Serialize the elements
        for e in self.iter() {
            out.append(&mut e.tls_serialize()?);
        }
        #[cfg(debug_assertions)]
        if out.len() - len_len != content_length {
            return Err(Error::LibraryError);
        }

        Ok(out)
    }
}

impl<T: SerializeBytes> SerializeBytes for &Vec<T> {
    #[inline(always)]
    fn tls_serialize(&self) -> Result<Vec<u8>, Error> {
        self.as_slice().tls_serialize()
    }
}

impl<T: SerializeBytes> SerializeBytes for Vec<T> {
    fn tls_serialize(&self) -> Result<Vec<u8>, Error> {
        self.as_slice().tls_serialize()
    }
}

impl<T: Size> Size for &[T] {
    #[inline(always)]
    fn tls_serialized_len(&self) -> usize {
        let content_length = self.iter().fold(0, |acc, e| acc + e.tls_serialized_len());
        let len_len = length_encoding_bytes(content_length as u64).unwrap_or({
            // We can't do anything about the error unless we change the trait.
            // Let's say there's no content for now.
            0
        });
        content_length + len_len
    }
}

fn write_hex(f: &mut fmt::Formatter<'_>, data: &[u8]) -> fmt::Result {
    if !data.is_empty() {
        write!(f, "0x")?;
        for byte in data {
            write!(f, "{byte:02x}")?;
        }
    } else {
        write!(f, "b\"\"")?;
    }

    Ok(())
}

macro_rules! impl_vl_bytes_generic {
    ($name:ident) => {
        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{} {{ ", stringify!($name))?;
                write_hex(f, &self.vec())?;
                write!(f, " }}")
            }
        }

        impl $name {
            /// Get a reference to the vlbytes's vec.
            pub fn as_slice(&self) -> &[u8] {
                self.vec().as_ref()
            }

            /// Add an element to this.
            #[inline]
            pub fn push(&mut self, value: u8) {
                self.vec_mut().push(value);
            }

            /// Remove the last element.
            #[inline]
            pub fn pop(&mut self) -> Option<u8> {
                self.vec_mut().pop()
            }
        }

        impl From<Vec<u8>> for $name {
            fn from(vec: Vec<u8>) -> Self {
                Self::new(vec)
            }
        }

        impl From<&[u8]> for $name {
            fn from(slice: &[u8]) -> Self {
                Self::new(slice.to_vec())
            }
        }

        impl<const N: usize> From<&[u8; N]> for $name {
            fn from(slice: &[u8; N]) -> Self {
                Self::new(slice.to_vec())
            }
        }

        impl AsRef<[u8]> for $name {
            fn as_ref(&self) -> &[u8] {
                &self.vec()
            }
        }
    };
}

/// Variable-length encoded byte vectors.
/// Use this struct if bytes are encoded.
/// This is faster than the generic version.
#[cfg_attr(feature = "serde", derive(SerdeSerialize, SerdeDeserialize))]
#[cfg_attr(feature = "std", derive(Zeroize))]
#[derive(Clone, PartialEq, Eq, Hash, Ord, PartialOrd)]
pub struct VLBytes {
    vec: Vec<u8>,
}

impl VLBytes {
    /// Generate a new variable-length byte vector.
    pub fn new(vec: Vec<u8>) -> Self {
        Self { vec }
    }

    fn vec(&self) -> &[u8] {
        &self.vec
    }

    fn vec_mut(&mut self) -> &mut Vec<u8> {
        &mut self.vec
    }
}

impl_vl_bytes_generic!(VLBytes);

impl From<VLBytes> for Vec<u8> {
    fn from(b: VLBytes) -> Self {
        b.vec
    }
}

#[inline(always)]
fn tls_serialize_bytes_len(bytes: &[u8]) -> usize {
    let content_length = bytes.len();
    let len_len = length_encoding_bytes(content_length as u64).unwrap_or({
        // We can't do anything about the error. Let's say there's no content.
        0
    });
    content_length + len_len
}

impl Size for VLBytes {
    #[inline(always)]
    fn tls_serialized_len(&self) -> usize {
        tls_serialize_bytes_len(self.as_slice())
    }
}

impl DeserializeBytes for VLBytes {
    #[inline(always)]
    fn tls_deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
        let ((length, _), remainder) = read_variable_length_bytes(bytes)?;
        if length == 0 {
            return Ok((Self::new(vec![]), remainder));
        }

        if !cfg!(fuzzing) {
            debug_assert!(
                length <= MAX_LEN as usize,
                "Trying to allocate {length} bytes. Only {MAX_LEN} allowed.",
            );
        }
        if length > MAX_LEN as usize {
            return Err(Error::DecodingError(format!(
                "Trying to allocate {length} bytes. Only {MAX_LEN} allowed.",
            )));
        }
        match remainder.get(..length).ok_or(Error::EndOfStream) {
            Ok(vec) => Ok((Self { vec: vec.to_vec() }, &remainder[length..])),
            Err(_e) => {
                let remaining_len = remainder.len();
                if !cfg!(fuzzing) {
                    debug_assert_eq!(
                        remaining_len, length,
                        "Expected to read {length} bytes but {remaining_len} were read.",
                    );
                }
                Err(Error::DecodingError(format!(
                    "{remaining_len} bytes were read but {length} were expected",
                )))
            }
        }
    }
}

impl Size for &VLBytes {
    #[inline(always)]
    fn tls_serialized_len(&self) -> usize {
        (*self).tls_serialized_len()
    }
}

pub struct VLByteSlice<'a>(pub &'a [u8]);

impl fmt::Debug for VLByteSlice<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "VLByteSlice {{ ")?;
        write_hex(f, self.0)?;
        write!(f, " }}")
    }
}

impl VLByteSlice<'_> {
    /// Get the raw slice.
    #[inline(always)]
    pub fn as_slice(&self) -> &[u8] {
        self.0
    }
}

impl Size for &VLByteSlice<'_> {
    #[inline]
    fn tls_serialized_len(&self) -> usize {
        tls_serialize_bytes_len(self.0)
    }
}

impl Size for VLByteSlice<'_> {
    #[inline]
    fn tls_serialized_len(&self) -> usize {
        tls_serialize_bytes_len(self.0)
    }
}

#[cfg(feature = "std")]
pub mod rw {
    use super::*;
    use crate::{Deserialize, Serialize};

    /// Read the length of a variable-length vector.
    ///
    /// This function assumes that the reader is at the start of a variable length
    /// vector and returns an error if there's not a single byte to read.
    ///
    /// The length and number of bytes read are returned.
    #[inline]
    pub fn read_length<R: std::io::Read>(bytes: &mut R) -> Result<(usize, usize), Error> {
        // The length is encoded in the first two bits of the first byte.
        let mut len_len_byte = [0u8; 1];
        if bytes.read(&mut len_len_byte)? == 0 {
            // There must be at least one byte for the length.
            // If we don't even have a length byte, this is not a valid
            // variable-length encoded vector.
            return Err(Error::InvalidVectorLength);
        }
        let len_len_byte = len_len_byte[0];

        let (mut length, len_len) = calculate_length(len_len_byte)?;

        for _ in 1..len_len {
            let mut next = [0u8; 1];
            bytes.read_exact(&mut next)?;
            length = (length << 8) + usize::from(next[0]);
        }

        check_min_length(length, len_len)?;

        Ok((length, len_len))
    }

    impl<T: Deserialize> Deserialize for Vec<T> {
        #[inline(always)]
        fn tls_deserialize<R: std::io::Read>(bytes: &mut R) -> Result<Self, Error> {
            let (length, len_len) = read_length(bytes)?;

            if length == 0 {
                // An empty vector.
                return Ok(Vec::new());
            }

            let mut result = Vec::new();
            let mut read = len_len;
            while (read - len_len) < length {
                let element = T::tls_deserialize(bytes)?;
                read += element.tls_serialized_len();
                result.push(element);
            }
            Ok(result)
        }
    }

    #[inline(always)]
    pub fn write_length<W: std::io::Write>(
        writer: &mut W,
        content_length: usize,
    ) -> Result<usize, Error> {
        let buf = super::write_variable_length(content_length)?;
        let buf_len = buf.len();
        writer.write_all(&buf)?;
        Ok(buf_len)
    }

    impl<T: Serialize + std::fmt::Debug> Serialize for Vec<T> {
        #[inline(always)]
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            self.as_slice().tls_serialize(writer)
        }
    }

    impl<T: Serialize + std::fmt::Debug> Serialize for &[T] {
        #[inline(always)]
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            // We need to pre-compute the length of the content.
            // This requires more computations but the other option would be to buffer
            // the entire content, which can end up requiring a lot of memory.
            let content_length = self.iter().fold(0, |acc, e| acc + e.tls_serialized_len());
            let len_len = write_length(writer, content_length)?;

            // Serialize the elements
            #[cfg(debug_assertions)]
            let mut written = 0;
            for e in self.iter() {
                #[cfg(debug_assertions)]
                {
                    written += e.tls_serialize(writer)?;
                }
                // We don't care about the length here. We pre-computed it.
                #[cfg(not(debug_assertions))]
                e.tls_serialize(writer)?;
            }
            #[cfg(debug_assertions)]
            if written != content_length {
                return Err(Error::LibraryError);
            }

            Ok(content_length + len_len)
        }
    }
}

/// Read/Write (std) based (de)serialization for [`VLBytes`].
#[cfg(feature = "std")]
mod rw_bytes {
    use super::*;
    use crate::{Deserialize, Serialize};

    #[inline(always)]
    fn tls_serialize_bytes<W: std::io::Write>(
        writer: &mut W,
        bytes: &[u8],
    ) -> Result<usize, Error> {
        // Get the byte length of the content, make sure it's not too
        // large and write it out.
        let content_length = bytes.len();

        if !cfg!(fuzzing) {
            debug_assert!(
                content_length as u64 <= MAX_LEN,
                "Vector can't be encoded. It's too large. {content_length} >= {MAX_LEN}",
            );
        }
        if content_length as u64 > MAX_LEN {
            return Err(Error::InvalidVectorLength);
        }

        let length_bytes = write_variable_length(content_length)?;
        let len_len = length_bytes.len();
        writer.write_all(&length_bytes)?;

        // Now serialize the elements
        writer.write_all(bytes)?;

        Ok(content_length + len_len)
    }

    impl Serialize for VLBytes {
        #[inline(always)]
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            tls_serialize_bytes(writer, self.as_slice())
        }
    }

    impl Serialize for &VLBytes {
        #[inline(always)]
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            (*self).tls_serialize(writer)
        }
    }

    impl Deserialize for VLBytes {
        fn tls_deserialize<R: std::io::Read>(bytes: &mut R) -> Result<Self, Error> {
            let (length, _) = rw::read_length(bytes)?;
            if length == 0 {
                return Ok(Self::new(vec![]));
            }

            if !cfg!(fuzzing) {
                debug_assert!(
                    length <= MAX_LEN as usize,
                    "Trying to allocate {length} bytes. Only {MAX_LEN} allowed.",
                );
            }
            if length > MAX_LEN as usize {
                return Err(Error::DecodingError(format!(
                    "Trying to allocate {length} bytes. Only {MAX_LEN} allowed.",
                )));
            }
            let mut result = Self {
                vec: vec![0u8; length],
            };
            bytes.read_exact(result.vec.as_mut_slice())?;
            Ok(result)
        }
    }

    impl Serialize for &VLByteSlice<'_> {
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            tls_serialize_bytes(writer, self.0)
        }
    }

    impl Serialize for VLByteSlice<'_> {
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            tls_serialize_bytes(writer, self.0)
        }
    }
}

#[cfg(feature = "std")]
mod secret_bytes {
    use super::*;
    use crate::{Deserialize, Serialize};

    /// A wrapper struct around [`VLBytes`] that implements [`ZeroizeOnDrop`]. It
    /// behaves just like [`VLBytes`], except that it doesn't allow conversion into
    /// a [`Vec<u8>`].
    #[cfg_attr(feature = "serde", derive(SerdeSerialize, SerdeDeserialize))]
    #[derive(Clone, PartialEq, Eq, Hash, Ord, PartialOrd, Zeroize, ZeroizeOnDrop)]
    pub struct SecretVLBytes(VLBytes);

    impl SecretVLBytes {
        /// Generate a new variable-length byte vector that implements
        /// [`ZeroizeOnDrop`].
        pub fn new(vec: Vec<u8>) -> Self {
            Self(VLBytes { vec })
        }

        fn vec(&self) -> &[u8] {
            &self.0.vec
        }

        fn vec_mut(&mut self) -> &mut Vec<u8> {
            &mut self.0.vec
        }
    }

    impl_vl_bytes_generic!(SecretVLBytes);

    impl Size for SecretVLBytes {
        fn tls_serialized_len(&self) -> usize {
            self.0.tls_serialized_len()
        }
    }

    impl DeserializeBytes for SecretVLBytes {
        fn tls_deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error>
        where
            Self: Sized,
        {
            let (bytes, remainder) = VLBytes::tls_deserialize_bytes(bytes)?;
            Ok((Self(bytes), remainder))
        }
    }

    impl Serialize for SecretVLBytes {
        fn tls_serialize<W: std::io::Write>(&self, writer: &mut W) -> Result<usize, Error> {
            self.0.tls_serialize(writer)
        }
    }

    impl Deserialize for SecretVLBytes {
        fn tls_deserialize<R: std::io::Read>(bytes: &mut R) -> Result<Self, Error>
        where
            Self: Sized,
        {
            Ok(Self(VLBytes::tls_deserialize(bytes)?))
        }
    }
}

#[cfg(feature = "std")]
pub use secret_bytes::SecretVLBytes;

#[cfg(feature = "arbitrary")]
impl<'a> Arbitrary<'a> for VLBytes {
    fn arbitrary(u: &mut Unstructured<'a>) -> arbitrary::Result<Self> {
        // We generate an arbitrary `Vec<u8>` ...
        let mut vec = Vec::arbitrary(u)?;
        // ... and truncate it to `MAX_LEN`.
        vec.truncate(MAX_LEN as usize);
        // We probably won't exceed `MAX_LEN` in practice, e.g., during fuzzing,
        // but better make sure that we generate valid instances.

        Ok(Self { vec })
    }
}

#[cfg(feature = "std")]
#[cfg(test)]
mod test {
    use crate::{SecretVLBytes, VLByteSlice, VLBytes};
    use std::println;

    #[test]
    fn test_debug() {
        let tests = [
            (vec![], "b\"\""),
            (vec![0x00], "0x00"),
            (vec![0xAA], "0xaa"),
            (vec![0xFF], "0xff"),
            (vec![0x00, 0x00], "0x0000"),
            (vec![0x00, 0xAA], "0x00aa"),
            (vec![0x00, 0xFF], "0x00ff"),
            (vec![0xff, 0xff], "0xffff"),
        ];

        for (test, expected) in tests.into_iter() {
            println!("\n# {test:?}");

            let expected_vl_byte_slice = format!("VLByteSlice {{ {expected} }}");
            let got = format!("{:?}", VLByteSlice(&test));
            println!("{got}");
            assert_eq!(expected_vl_byte_slice, got);

            let expected_vl_bytes = format!("VLBytes {{ {expected} }}");
            let got = format!("{:?}", VLBytes::new(test.clone()));
            println!("{got}");
            assert_eq!(expected_vl_bytes, got);

            let expected_secret_vl_bytes = format!("SecretVLBytes {{ {expected} }}");
            let got = format!("{:?}", SecretVLBytes::new(test.clone()));
            println!("{got}");
            assert_eq!(expected_secret_vl_bytes, got);
        }
    }
}
