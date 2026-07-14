#[cfg(feature = "alloc")]
use alloc::vec::Vec;
#[cfg(feature = "alloc")]
use core::convert::Infallible;

/// Internal writer abstraction used to share serialization code between
/// `std` and `no_std` code paths.
pub(crate) trait CoreWrite {
    type Error;

    fn write_all(&mut self, slice: &[u8]) -> Result<(), Self::Error>;
}

/// Internal generic write error that separates transport errors (`Io`) from
/// semantic/content errors (`Content`).
pub(crate) enum WriteError<IO, Content> {
    Io(IO),
    Content(Content),
}

#[cfg(feature = "std")]
pub(crate) struct IoWriter<'a, T: std::io::Write + ?Sized>(pub(crate) &'a mut T);

#[cfg(feature = "alloc")]
pub(crate) struct VecWriter<'a>(pub(crate) &'a mut Vec<u8>);

pub(crate) struct SliceCoreWrite<'a> {
    buf: &'a mut [u8],
    pos: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub(crate) struct SliceCoreWriteError {
    pub(crate) required_len: usize,
    pub(crate) len: usize,
}

impl<'a> SliceCoreWrite<'a> {
    #[inline]
    pub(crate) fn new(buf: &'a mut [u8]) -> Self {
        SliceCoreWrite { buf, pos: 0 }
    }
}

impl CoreWrite for SliceCoreWrite<'_> {
    type Error = SliceCoreWriteError;

    #[inline]
    fn write_all(&mut self, slice: &[u8]) -> Result<(), Self::Error> {
        let buf_len = self.buf.len();

        let required_len = self.pos.saturating_add(slice.len());
        self.buf
            .get_mut(self.pos..)
            .and_then(|tail| tail.get_mut(..slice.len()))
            .ok_or(SliceCoreWriteError {
                required_len,
                len: buf_len,
            })?
            .copy_from_slice(slice);
        self.pos = required_len;
        Ok(())
    }
}

#[cfg(feature = "std")]
impl<T: std::io::Write + ?Sized> CoreWrite for IoWriter<'_, T> {
    type Error = std::io::Error;

    #[inline]
    fn write_all(&mut self, slice: &[u8]) -> Result<(), Self::Error> {
        std::io::Write::write_all(self.0, slice)
    }
}

#[cfg(feature = "alloc")]
impl CoreWrite for VecWriter<'_> {
    type Error = Infallible;

    #[inline]
    fn write_all(&mut self, slice: &[u8]) -> Result<(), Self::Error> {
        self.0.extend_from_slice(slice);
        Ok(())
    }
}
