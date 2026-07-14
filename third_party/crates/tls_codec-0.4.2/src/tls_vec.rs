//! A vector with a length field for TLS serialisation.
//! Use this for any vector that is serialised.

// TODO: #2 share code between the different implementations. There's too much
//       duplicate code in here.

use alloc::vec::Vec;
use core::ops::Drop;

#[cfg(feature = "serde")]
use serde::ser::SerializeStruct;
#[cfg(feature = "std")]
use std::io::{Read, Write};
use zeroize::Zeroize;

use crate::{Deserialize, DeserializeBytes, Error, Serialize, SerializeBytes, Size, U24};

macro_rules! impl_size {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        /// The serialized len
        #[inline(always)]
        fn tls_serialized_length(&$self) -> usize {
            $self.as_slice()
                .iter()
                .fold($len_len, |acc, e| acc + e.tls_serialized_len())
        }
    }
}

macro_rules! impl_byte_size {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        /// The serialized len
        #[inline(always)]
        fn tls_serialized_byte_length(&$self) -> usize {
            $self.as_slice().len() + $len_len
        }
    }
}

macro_rules! impl_byte_deserialize {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        #[cfg(feature = "std")]
        #[inline(always)]
        fn deserialize_bytes<R: Read>(bytes: &mut R) -> Result<Self, Error> {
            let len = <$size>::tls_deserialize(bytes)?.try_into().unwrap();
            // When fuzzing we limit the maximum size to allocate.
            // XXX: We should think about a configurable limit for the allocation
            //      here.
            if cfg!(fuzzing) && len > u16::MAX as usize {
                return Err(Error::DecodingError(format!(
                    "Trying to allocate {} bytes. Only {} allowed.",
                    len,
                    u16::MAX
                )));
            }
            let mut result = Self {
                vec: vec![0u8; len],
            };
            bytes.read_exact(result.vec.as_mut_slice())?;
            Ok(result)
        }

        #[inline(always)]
        fn deserialize_bytes_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
            let (type_len, remainder) = <$size>::tls_deserialize_bytes(bytes)?;
            let len = type_len.try_into().unwrap();
            // When fuzzing we limit the maximum size to allocate.
            // XXX: We should think about a configurable limit for the allocation
            //      here.
            if cfg!(fuzzing) && len > u16::MAX as usize {
                return Err(Error::DecodingError(alloc::format!(
                    "Trying to allocate {} bytes. Only {} allowed.",
                    len,
                    u16::MAX
                )));
            }
            let vec = bytes
                .get($len_len..len + $len_len)
                .ok_or(Error::EndOfStream)?;
            let result = Self { vec: vec.to_vec() };
            Ok((result, &remainder.get(len..).ok_or(Error::EndOfStream)?))
        }
    };
}

macro_rules! impl_deserialize {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        #[cfg(feature = "std")]
        #[inline(always)]
        fn deserialize<R: Read>(bytes: &mut R) -> Result<Self, Error> {
            let mut result = Self { vec: Vec::new() };
            let len = <$size>::tls_deserialize(bytes)?;
            let mut read = len.tls_serialized_len();
            let len_len = read;
            while (read - len_len) < len.try_into().unwrap() {
                let element = T::tls_deserialize(bytes)?;
                read += element.tls_serialized_len();
                result.push(element);
            }
            Ok(result)
        }
    };
}

macro_rules! impl_deserialize_bytes {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        #[inline(always)]
        fn deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
            let mut result = Self { vec: Vec::new() };
            let (len, mut remainder) = <$size>::tls_deserialize_bytes(bytes)?;
            let mut read = len.tls_serialized_len();
            let len_len = read;
            while (read - len_len) < len.try_into().unwrap() {
                let (element, next_remainder) = T::tls_deserialize_bytes(remainder)?;
                remainder = next_remainder;
                read += element.tls_serialized_len();
                result.push(element);
            }
            Ok((result, remainder))
        }
    };
}

macro_rules! impl_serialize {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        #[cfg(feature = "std")]
        #[inline(always)]
        fn serialize<W: Write>(&$self, writer: &mut W) -> Result<usize, Error> {
            // Get the byte length of the content, make sure it's not too
            // large and write it out.
            let (tls_serialized_len, byte_length) = $self.get_content_lengths()?;

            let mut written = <$size as Serialize>::tls_serialize(&<$size>::try_from(byte_length).unwrap(), writer)?;

            // Now serialize the elements
            for e in $self.as_slice().iter() {
                written += e.tls_serialize(writer)?;
            }

            $self.assert_written_bytes(tls_serialized_len, written)?;
            Ok(written)
        }
    };
}

macro_rules! impl_byte_serialize {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        #[cfg(feature = "std")]
        #[inline(always)]
        fn serialize_bytes<W: Write>(&$self, writer: &mut W) -> Result<usize, Error> {
            // Get the byte length of the content, make sure it's not too
            // large and write it out.
            let (tls_serialized_len, byte_length) = $self.get_content_lengths()?;

            let mut written = <$size as Serialize>::tls_serialize(&<$size>::try_from(byte_length).unwrap(), writer)?;

            // Now serialize the elements
            written += writer.write($self.as_slice())?;

            $self.assert_written_bytes(tls_serialized_len, written)?;
            Ok(written)
        }
    };
}

macro_rules! impl_serialize_common {
    ($self:ident, $size:ty, $name:ident, $len_len:literal $(,#[$std_enabled:meta])?) => {
        $(#[$std_enabled])?
        fn get_content_lengths(&$self) -> Result<(usize, usize), Error> {
            let tls_serialized_len = $self.tls_serialized_len();
            let byte_length = tls_serialized_len - $len_len;

            let max_len = <$size>::MAX.try_into().unwrap();
            debug_assert!(
                byte_length <= max_len,
                "Vector length can't be encoded in the vector length a {} >= {}",
                byte_length,
                max_len
            );
            if byte_length > max_len {
                return Err(Error::InvalidVectorLength);
            }
            Ok((tls_serialized_len, byte_length))
        }

        $(#[$std_enabled])?
        fn assert_written_bytes(&$self, tls_serialized_len: usize, written: usize) -> Result<(), Error> {
            debug_assert_eq!(
                written, tls_serialized_len,
                "{} bytes should have been serialized but {} were written",
                tls_serialized_len, written
            );
            if written != tls_serialized_len {
                return Err(Error::EncodingError(format!(
                    "{} bytes should have been serialized but {} were written",
                    tls_serialized_len, written
                )));
            }
            Ok(())
        }
    };
}

macro_rules! impl_serialize_bytes_bytes {
    ($self:ident, $size:ty, $name:ident, $len_len:literal) => {
        fn serialize_bytes_bytes(&$self) -> Result<Vec<u8>, Error> {
            let (tls_serialized_len, byte_length) = $self.get_content_lengths()?;

            let mut vec = Vec::<u8>::with_capacity(tls_serialized_len);
            let length_vec = <$size as SerializeBytes>::tls_serialize(&byte_length.try_into().unwrap())?;
            let mut written = length_vec.len();
            vec.extend_from_slice(&length_vec);

            let bytes = $self.as_slice();
            vec.extend_from_slice(bytes);
            written += bytes.len();

            $self.assert_written_bytes(tls_serialized_len, written)?;

            Ok(vec)
        }
    };
}

macro_rules! impl_tls_vec_codec_generic {
    ($size:ty, $name:ident, $len_len: literal $(, $bounds:ident)*) => {
        impl<T: $($bounds + )* Serialize> Serialize for $name<T> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize(writer)
            }
        }

        impl<T: $($bounds + )* Size> Size for $name<T> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_length()
            }
        }

        impl<T: $($bounds + )* Serialize> Serialize for &$name<T> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize(writer)
            }
        }

        impl<T: $($bounds + )* Size> Size for &$name<T> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_length()
            }
        }

        impl<T: $($bounds + )* Deserialize> Deserialize for $name<T> {
            #[cfg(feature = "std")]
            fn tls_deserialize<R: Read>(bytes: &mut R) -> Result<Self, Error> {
                Self::deserialize(bytes)
            }
        }

        impl<T: $($bounds + )* DeserializeBytes> DeserializeBytes for $name<T> {
            fn tls_deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
                Self::deserialize_bytes(bytes)
            }
        }
    };
}

macro_rules! impl_tls_vec_codec_bytes {
    ($size:ty, $name:ident, $len_len: literal) => {
        impl Serialize for $name {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize_bytes(writer)
            }
        }

        impl Size for $name {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_byte_length()
            }
        }

        impl Serialize for &$name {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize_bytes(writer)
            }
        }

        impl Size for &$name {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_byte_length()
            }
        }

        impl Deserialize for $name {
            #[cfg(feature = "std")]
            fn tls_deserialize<R: Read>(bytes: &mut R) -> Result<Self, Error> {
                Self::deserialize_bytes(bytes)
            }
        }

        impl DeserializeBytes for $name {
            fn tls_deserialize_bytes(bytes: &[u8]) -> Result<(Self, &[u8]), Error> {
                Self::deserialize_bytes_bytes(bytes)
            }
        }

        impl SerializeBytes for $name {
            fn tls_serialize(&self) -> Result<Vec<u8>, Error> {
                self.serialize_bytes_bytes()
            }
        }
    };
}

macro_rules! impl_vec_members {
    ($element_type:ident, $len_len:literal) => {
        /// Create a new `TlsVec` from a Rust Vec.
        #[inline]
        pub fn new(vec: Vec<$element_type>) -> Self {
            Self { vec }
        }

        /// Create a new `TlsVec` from a slice.
        #[inline]
        pub fn from_slice(slice: &[$element_type]) -> Self
        where
            $element_type: Clone,
        {
            Self {
                vec: slice.to_vec(),
            }
        }

        /// Get the length of the vector.
        #[inline]
        pub fn len(&self) -> usize {
            self.vec.len()
        }

        /// Get a slice to the raw vector.
        #[inline]
        pub fn as_slice(&self) -> &[$element_type] {
            &self.vec
        }

        /// Check if the vector is empty.
        #[inline]
        pub fn is_empty(&self) -> bool {
            self.vec.is_empty()
        }

        /// Get the underlying vector and consume this.
        #[inline]
        pub fn into_vec(mut self) -> Vec<$element_type> {
            core::mem::take(&mut self.vec)
        }

        /// Add an element to this.
        #[inline]
        pub fn push(&mut self, value: $element_type) {
            self.vec.push(value);
        }

        /// Remove the last element.
        #[inline]
        pub fn pop(&mut self) -> Option<$element_type> {
            self.vec.pop()
        }

        /// Remove the element at `index`.
        #[inline]
        pub fn remove(&mut self, index: usize) -> $element_type {
            self.vec.remove(index)
        }

        /// Returns a reference to an element or subslice depending on the type of index.
        /// XXX: implement SliceIndex instead
        #[inline]
        pub fn get(&self, index: usize) -> Option<&$element_type> {
            self.vec.get(index)
        }

        /// Returns an iterator over the slice.
        #[inline]
        pub fn iter(&self) -> core::slice::Iter<'_, $element_type> {
            self.vec.iter()
        }

        /// Retains only the elements specified by the predicate.
        #[inline]
        pub fn retain<F>(&mut self, f: F)
        where
            F: FnMut(&$element_type) -> bool,
        {
            self.vec.retain(f)
        }

        /// Get the number of bytes used for the length encoding.
        #[inline(always)]
        pub fn len_len() -> usize {
            $len_len
        }
    };
}

macro_rules! impl_tls_vec_generic {
    ($size:ty, $name:ident, $len_len: literal $(, $bounds:ident)*) => {
        #[derive(Eq, Debug)]
        pub struct $name<T: $($bounds + )*> {
            vec: Vec<T>,
        }

        impl<T: $($bounds + )* Clone> Clone for $name<T> {
            fn clone(&self) -> Self {
                Self::new(self.vec.clone())
            }
        }

        impl<T: $($bounds + )*> $name<T> {
            impl_vec_members!(T, $len_len);
        }

        impl<T: $($bounds + )* core::hash::Hash> core::hash::Hash for $name<T> {
            #[inline]
            fn hash<H: core::hash::Hasher>(&self, state: &mut H) {
                self.vec.hash(state)
            }
        }

        impl<T: $($bounds + )*> core::ops::Index<usize> for $name<T> {
            type Output = T;

            #[inline]
            fn index(&self, i: usize) -> &T {
                self.vec.index(i)
            }
        }

        impl<T: $($bounds + )* core::cmp::PartialEq> core::cmp::PartialEq for $name<T> {
            fn eq(&self, other: &Self) -> bool {
                self.vec.eq(&other.vec)
            }
        }

        impl<T: $($bounds + )*> core::ops::IndexMut<usize> for $name<T> {
            #[inline]
            fn index_mut(&mut self, i: usize) -> &mut Self::Output {
                self.vec.index_mut(i)
            }
        }

        impl<T: $($bounds + )*> core::borrow::Borrow<[T]> for $name<T> {
            #[inline]
            fn borrow(&self) -> &[T] {
                &self.vec
            }
        }

        impl<T: $($bounds + )*> core::iter::FromIterator<T> for $name<T> {
            #[inline]
            fn from_iter<I>(iter: I) -> Self
            where
                I: IntoIterator<Item = T>,
            {
                let vec = Vec::<T>::from_iter(iter);
                Self { vec }
            }
        }

        impl<T: $($bounds + )*> From<Vec<T>> for $name<T> {
            #[inline]
            fn from(v: Vec<T>) -> Self {
                Self::new(v)
            }
        }

        impl<T: $($bounds + )* Clone> From<&[T]> for $name<T> {
            #[inline]
            fn from(v: &[T]) -> Self {
                Self::from_slice(v)
            }
        }

        impl<T: $($bounds + )*> From<$name<T>> for Vec<T> {
            #[inline]
            fn from(mut v: $name<T>) -> Self {
                core::mem::take(&mut v.vec)
            }
        }

        impl<T: $($bounds + )*> Default for $name<T> {
            #[inline]
            fn default() -> Self {
                Self { vec: Vec::new() }
            }
        }

        #[cfg(feature = "serde")]
        impl<T> serde::Serialize for $name<T>
        where
            T: $($bounds + )* serde::Serialize,
        {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: serde::Serializer,
            {
                let mut state = serializer.serialize_struct(stringify!($name), 1)?;
                state.serialize_field("vec", &self.vec)?;
                state.end()
            }
        }

        #[cfg(feature = "serde")]
        impl<'de, T> serde::de::Deserialize<'de> for $name<T>
        where
            T: $($bounds + )* serde::de::Deserialize<'de>,
        {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::de::Deserializer<'de>,
            {
                enum Field {
                    Vec,
                }

                impl<'de> serde::de::Deserialize<'de> for Field {
                    fn deserialize<D>(deserializer: D) -> Result<Field, D::Error>
                    where
                        D: serde::de::Deserializer<'de>,
                    {
                        struct FieldVisitor;

                        impl<'de> serde::de::Visitor<'de> for FieldVisitor {
                            type Value = Field;

                            fn expecting(
                                &self,
                                formatter: &mut core::fmt::Formatter<'_>,
                            ) -> core::fmt::Result {
                                formatter.write_str("`vec`")
                            }

                            fn visit_str<E>(self, value: &str) -> Result<Field, E>
                            where
                                E: serde::de::Error,
                            {
                                match value {
                                    "vec" => Ok(Field::Vec),
                                    _ => Err(serde::de::Error::unknown_field(value, &["vec"])),
                                }
                            }
                        }

                        deserializer.deserialize_identifier(FieldVisitor)
                    }
                }

                struct TlsVecVisitor<T> {
                    data: core::marker::PhantomData<T>,
                }

                impl<'de, T> serde::de::Visitor<'de> for TlsVecVisitor<T>
                where
                    T: $($bounds + )* serde::de::Deserialize<'de>,
                {
                    type Value = $name<T>;
                    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                        formatter.write_fmt(format_args!("struct {}<T>", stringify!($name)))
                    }
                    fn visit_seq<V>(self, mut seq: V) -> Result<$name<T>, V::Error>
                    where
                        V: serde::de::SeqAccess<'de>,
                    {
                        let vec = seq
                            .next_element()?
                            .ok_or_else(|| serde::de::Error::invalid_length(0, &self))?;
                        Ok($name::<T>::new(vec))
                    }
                    fn visit_map<V>(self, mut map: V) -> Result<$name<T>, V::Error>
                    where
                        V: serde::de::MapAccess<'de>,
                    {
                        let mut vec = None;
                        while let Some(key) = map.next_key()? {
                            match key {
                                Field::Vec => {
                                    if vec.is_some() {
                                        return Err(serde::de::Error::duplicate_field("vec"));
                                    }
                                    vec = Some(map.next_value()?);
                                }
                            }
                        }
                        let vec = vec.ok_or_else(|| serde::de::Error::missing_field("vec"))?;
                        Ok($name::<T>::new(vec))
                    }
                }
                deserializer.deserialize_struct(
                    stringify!($name),
                    &["vec"],
                    TlsVecVisitor {
                        data: core::marker::PhantomData,
                    },
                )
            }
        }
    };
}

macro_rules! impl_tls_vec {
    ($name:ident, $len_len:literal) => {
        #[derive(Eq, Clone, Debug)]
        pub struct $name {
            vec: Vec<u8>,
        }

        impl $name {
            impl_vec_members!(u8, $len_len);
        }

        impl core::hash::Hash for $name {
            #[inline]
            fn hash<H: core::hash::Hasher>(&self, state: &mut H) {
                self.vec.hash(state)
            }
        }

        impl core::ops::Index<usize> for $name {
            type Output = u8;

            #[inline]
            fn index(&self, i: usize) -> &u8 {
                self.vec.index(i)
            }
        }

        impl core::cmp::PartialEq for $name {
            fn eq(&self, other: &Self) -> bool {
                self.vec.eq(&other.vec)
            }
        }

        impl core::ops::IndexMut<usize> for $name {
            #[inline]
            fn index_mut(&mut self, i: usize) -> &mut Self::Output {
                self.vec.index_mut(i)
            }
        }

        impl core::borrow::Borrow<[u8]> for $name {
            #[inline]
            fn borrow(&self) -> &[u8] {
                &self.vec
            }
        }

        impl core::iter::FromIterator<u8> for $name {
            #[inline]
            fn from_iter<I>(iter: I) -> Self
            where
                I: IntoIterator<Item = u8>,
            {
                let vec = Vec::<u8>::from_iter(iter);
                Self { vec }
            }
        }

        impl From<Vec<u8>> for $name {
            #[inline]
            fn from(v: Vec<u8>) -> Self {
                Self::new(v)
            }
        }

        impl From<&[u8]> for $name {
            #[inline]
            fn from(v: &[u8]) -> Self {
                Self::from_slice(v)
            }
        }

        impl From<$name> for Vec<u8> {
            #[inline]
            fn from(mut v: $name) -> Self {
                core::mem::take(&mut v.vec)
            }
        }

        impl Default for $name {
            #[inline]
            fn default() -> Self {
                Self { vec: Vec::new() }
            }
        }

        #[cfg(feature = "serde")]
        impl serde::Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: serde::Serializer,
            {
                let mut state = serializer.serialize_struct(stringify!($name), 1)?;
                state.serialize_field("vec", &self.vec)?;
                state.end()
            }
        }

        #[cfg(feature = "serde")]
        impl<'de> serde::de::Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::de::Deserializer<'de>,
            {
                enum Field {
                    Vec,
                }

                impl<'de> serde::de::Deserialize<'de> for Field {
                    fn deserialize<D>(deserializer: D) -> Result<Field, D::Error>
                    where
                        D: serde::de::Deserializer<'de>,
                    {
                        struct FieldVisitor;

                        impl<'de> serde::de::Visitor<'de> for FieldVisitor {
                            type Value = Field;

                            fn expecting(
                                &self,
                                formatter: &mut core::fmt::Formatter<'_>,
                            ) -> core::fmt::Result {
                                formatter.write_str("`vec`")
                            }

                            fn visit_str<E>(self, value: &str) -> Result<Field, E>
                            where
                                E: serde::de::Error,
                            {
                                match value {
                                    "vec" => Ok(Field::Vec),
                                    _ => Err(serde::de::Error::unknown_field(value, &["vec"])),
                                }
                            }
                        }

                        deserializer.deserialize_identifier(FieldVisitor)
                    }
                }

                struct TlsVecVisitor {
                    data: core::marker::PhantomData<u8>,
                }

                impl<'de> serde::de::Visitor<'de> for TlsVecVisitor {
                    type Value = $name;
                    fn expecting(
                        &self,
                        formatter: &mut core::fmt::Formatter<'_>,
                    ) -> core::fmt::Result {
                        formatter.write_fmt(format_args!("struct {}", stringify!($name)))
                    }
                    fn visit_seq<V>(self, mut seq: V) -> Result<$name, V::Error>
                    where
                        V: serde::de::SeqAccess<'de>,
                    {
                        let vec = seq
                            .next_element()?
                            .ok_or_else(|| serde::de::Error::invalid_length(0, &self))?;
                        Ok($name::new(vec))
                    }
                    fn visit_map<V>(self, mut map: V) -> Result<$name, V::Error>
                    where
                        V: serde::de::MapAccess<'de>,
                    {
                        let mut vec = None;
                        while let Some(key) = map.next_key()? {
                            match key {
                                Field::Vec => {
                                    if vec.is_some() {
                                        return Err(serde::de::Error::duplicate_field("vec"));
                                    }
                                    vec = Some(map.next_value()?);
                                }
                            }
                        }
                        let vec = vec.ok_or_else(|| serde::de::Error::missing_field("vec"))?;
                        Ok($name::new(vec))
                    }
                }
                deserializer.deserialize_struct(
                    stringify!($name),
                    &["vec"],
                    TlsVecVisitor {
                        data: core::marker::PhantomData,
                    },
                )
            }
        }
    };
}

macro_rules! impl_secret_tls_vec {
    ($size:ty, $name:ident, $len_len: literal) => {
        impl_tls_vec_generic!($size, $name, $len_len, Zeroize);
        impl_tls_vec_codec_generic!($size, $name, $len_len, Zeroize);

        impl<T: Serialize + Zeroize> $name<T> {
            impl_serialize_common!(self, $size, $name, $len_len, #[cfg(feature = "std")]);
            impl_serialize!(self, $size, $name, $len_len);
        }

        impl<T: Size + Zeroize> $name<T> {
            impl_size!(self, $size, $name, $len_len);
        }

        impl<T: Deserialize + Zeroize> $name<T> {
            impl_deserialize!(self, $size, $name, $len_len);
        }

        impl<T: DeserializeBytes + Zeroize> $name<T> {
            impl_deserialize_bytes!(self, $size, $name, $len_len);
        }

        impl<T: Zeroize> Zeroize for $name<T> {
            fn zeroize(&mut self) {
                self.vec.zeroize()
            }
        }

        impl<T: Zeroize> Drop for $name<T> {
            fn drop(&mut self) {
                self.zeroize()
            }
        }
    };
}

macro_rules! impl_public_tls_vec {
    ($size:ty, $name:ident, $len_len: literal) => {
        impl_tls_vec_generic!($size, $name, $len_len);

        impl_tls_vec_codec_generic!($size, $name, $len_len);

        impl<T: Serialize> $name<T> {
            impl_serialize_common!(self, $size, $name, $len_len, #[cfg(feature = "std")]);
            impl_serialize!(self, $size, $name, $len_len);
        }

        impl<T: Size> $name<T> {
            impl_size!(self, $size, $name, $len_len);
        }

        impl<T: Deserialize> $name<T> {
            impl_deserialize!(self, $size, $name, $len_len);
        }

        impl<T: DeserializeBytes> $name<T> {
            impl_deserialize_bytes!(self, $size, $name, $len_len);
        }
    };
}

macro_rules! impl_tls_byte_vec {
    ($size:ty, $name:ident, $len_len: literal) => {
        impl_tls_vec!($name, $len_len);

        impl $name {
            // This implements serialize and size for all versions
            impl_serialize_common!(self, $size, $name, $len_len);
            impl_byte_serialize!(self, $size, $name, $len_len);
            impl_serialize_bytes_bytes!(self, $size, $name, $len_len);
            impl_byte_size!(self, $size, $name, $len_len);
            impl_byte_deserialize!(self, $size, $name, $len_len);
        }

        impl_tls_vec_codec_bytes!($size, $name, $len_len);
    };
}

impl_public_tls_vec!(u8, TlsVecU8, 1);
impl_public_tls_vec!(u16, TlsVecU16, 2);
impl_public_tls_vec!(U24, TlsVecU24, 3);
impl_public_tls_vec!(u32, TlsVecU32, 4);

impl_tls_byte_vec!(u8, TlsByteVecU8, 1);
impl_tls_byte_vec!(u16, TlsByteVecU16, 2);
impl_tls_byte_vec!(U24, TlsByteVecU24, 3);
impl_tls_byte_vec!(u32, TlsByteVecU32, 4);

// Secrets should be put into these Secret tls vectors as they implement zeroize.
impl_secret_tls_vec!(u8, SecretTlsVecU8, 1);
impl_secret_tls_vec!(u16, SecretTlsVecU16, 2);
impl_secret_tls_vec!(U24, SecretTlsVecU24, 3);
impl_secret_tls_vec!(u32, SecretTlsVecU32, 4);

// We also implement shallow serialization for slices

macro_rules! impl_tls_byte_slice {
    ($size:ty, $name:ident, $len_len:literal) => {
        pub struct $name<'a>(pub &'a [u8]);

        impl<'a> $name<'a> {
            /// Get the raw slice.
            #[inline(always)]
            pub fn as_slice(&self) -> &[u8] {
                self.0
            }
        }

        impl<'a> $name<'a> {
            impl_serialize_common!(self, $size, $name, $len_len, #[cfg(feature = "std")]);
            impl_byte_serialize!(self, $size, $name, $len_len);
            impl_byte_size!(self, $size, $name, $len_len);
        }

        impl<'a> Serialize for &$name<'a> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize_bytes(writer)
            }
        }

        impl<'a> Serialize for $name<'a> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize_bytes(writer)
            }
        }

        impl<'a> Size for &$name<'a> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_byte_length()
            }
        }

        impl<'a> Size for $name<'a> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_byte_length()
            }
        }
    };
}

impl_tls_byte_slice!(u8, TlsByteSliceU8, 1);
impl_tls_byte_slice!(u16, TlsByteSliceU16, 2);
impl_tls_byte_slice!(U24, TlsByteSliceU24, 3);
impl_tls_byte_slice!(u32, TlsByteSliceU32, 4);

macro_rules! impl_tls_slice {
    ($size:ty, $name:ident, $len_len: literal) => {
        pub struct $name<'a, T>(pub &'a [T]);

        impl<'a, T> $name<'a, T> {
            /// Get the raw slice.
            #[inline(always)]
            pub fn as_slice(&self) -> &[T] {
                self.0
            }
        }

        impl<'a, T: Size> $name<'a, T> {
            impl_size!(self, $size, $name, $len_len);
        }

        impl<'a, T: Serialize> $name<'a, T> {
            impl_serialize_common!(self, $size, $name, $len_len, #[cfg(feature = "std")]);
            impl_serialize!(self, $size, $name, $len_len);
        }

        impl<'a, T: Serialize> Serialize for &$name<'a, T> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize(writer)
            }
        }

        impl<'a, T: Serialize> Serialize for $name<'a, T> {
            #[cfg(feature = "std")]
            fn tls_serialize<W: Write>(&self, writer: &mut W) -> Result<usize, Error> {
                self.serialize(writer)
            }
        }

        impl<'a, T: Size> Size for &$name<'a, T> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_length()
            }
        }

        impl<'a, T: Size> Size for $name<'a, T> {
            #[inline]
            fn tls_serialized_len(&self) -> usize {
                self.tls_serialized_length()
            }
        }
    };
}

impl_tls_slice!(u8, TlsSliceU8, 1);
impl_tls_slice!(u16, TlsSliceU16, 2);
impl_tls_slice!(U24, TlsSliceU24, 3);
impl_tls_slice!(u32, TlsSliceU32, 4);

impl From<core::num::TryFromIntError> for Error {
    fn from(_e: core::num::TryFromIntError) -> Self {
        Self::InvalidVectorLength
    }
}

impl From<core::convert::Infallible> for Error {
    fn from(_e: core::convert::Infallible) -> Self {
        Self::InvalidVectorLength
    }
}
