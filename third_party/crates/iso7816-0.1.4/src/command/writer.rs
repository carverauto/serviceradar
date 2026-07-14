use core::fmt::{Debug, Display};
use core::mem;

pub trait Error: Debug + Display {
    fn failed_serialization(cause: &'static str) -> Self;
}

#[derive(Debug)]
pub enum BufferFull {
    BufferFull,
    Serialization(&'static str),
}

impl Error for BufferFull {
    fn failed_serialization(cause: &'static str) -> Self {
        Self::Serialization(cause)
    }
}

impl Display for BufferFull {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            BufferFull::BufferFull => f.write_str("Buffer is full"),
            BufferFull::Serialization(cause) => f.write_str(cause),
        }
    }
}

pub trait Writer {
    type Error: Error;

    fn write(&mut self, data: &[u8]) -> Result<usize, Self::Error>;
    fn write_all(&mut self, data: &[u8]) -> Result<(), Self::Error> {
        let mut offset = 0;
        while offset < data.len() {
            offset += self.write(&data[offset..])?;
        }
        Ok(())
    }
}

impl Writer for &mut [u8] {
    type Error = BufferFull;
    fn write(&mut self, data: &[u8]) -> Result<usize, BufferFull> {
        let amt = data.len().min(self.len());

        if amt == 0 {
            return Err(BufferFull::BufferFull);
        }

        let (a, b) = mem::take(self).split_at_mut(amt);
        a.copy_from_slice(&data[..amt]);
        *self = b;
        Ok(amt)
    }
}
impl IntoWriter for &mut [u8] {
    type Writer = Self;
    fn into_writer(self, to_write: usize) -> Result<Self, BufferFull> {
        if self.len() < to_write {
            Err(BufferFull::BufferFull)
        } else {
            Ok(self)
        }
    }
}

impl<const N: usize> Writer for heapless::Vec<u8, N> {
    type Error = BufferFull;
    fn write(&mut self, data: &[u8]) -> Result<usize, BufferFull> {
        let amt = data.len().min(self.capacity() - self.len());

        if amt == 0 {
            return Err(BufferFull::BufferFull);
        }

        self.extend_from_slice(&data[..amt]).unwrap();
        Ok(amt)
    }
}
impl<const N: usize> IntoWriter for heapless::Vec<u8, N> {
    type Writer = Self;
    fn into_writer(self, to_write: usize) -> Result<Self, BufferFull> {
        if N - self.len() < to_write {
            Err(BufferFull::BufferFull)
        } else {
            Ok(self)
        }
    }
}

#[cfg(feature = "heapless-bytes")]
impl<const N: usize> Writer for heapless_bytes::Bytes<N> {
    type Error = BufferFull;
    fn write(&mut self, data: &[u8]) -> Result<usize, BufferFull> {
        let amt = data.len().min(self.capacity() - self.len());

        if amt == 0 {
            return Err(BufferFull::BufferFull);
        }

        self.extend_from_slice(&data[..amt]).unwrap();
        Ok(amt)
    }
}

#[cfg(feature = "heapless-bytes")]
impl<const N: usize> IntoWriter for heapless_bytes::Bytes<N> {
    type Writer = Self;
    fn into_writer(self, to_write: usize) -> Result<Self, BufferFull> {
        if N - self.len() < to_write {
            Err(BufferFull::BufferFull)
        } else {
            Ok(self)
        }
    }
}

#[derive(Debug)]
pub struct SerializationError(&'static str);

impl Display for SerializationError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.0)
    }
}

impl Error for SerializationError {
    fn failed_serialization(cause: &'static str) -> Self {
        Self(cause)
    }
}

#[cfg(any(feature = "std", test))]
impl Writer for Vec<u8> {
    type Error = SerializationError;
    fn write(&mut self, data: &[u8]) -> Result<usize, SerializationError> {
        self.extend_from_slice(data);
        Ok(data.len())
    }
}

#[cfg(any(feature = "std", test))]
impl IntoWriter for Vec<u8> {
    type Writer = Self;
    fn into_writer(self, _to_write: usize) -> Result<Self, SerializationError> {
        Ok(self)
    }
}

pub trait IntoWriter {
    type Writer: Writer;
    fn into_writer(self, to_write: usize) -> Result<Self::Writer, <Self::Writer as Writer>::Error>;
}
