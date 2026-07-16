use core::str;

use crate::Error;
use crate::util::find_crlf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dechunker {
    Size,
    Chunk(usize),
    CrLf,
    Ending,
    Trailer,
    Ended,
}

#[derive(Debug)]
struct Pos {
    index_in: usize,
    index_out: usize,
}

impl Dechunker {
    pub fn new() -> Self {
        Dechunker::Size
    }

    pub fn parse_input(&mut self, src: &[u8], dst: &mut [u8]) -> Result<(usize, usize), Error> {
        let mut pos = Pos {
            index_in: 0,
            index_out: 0,
        };

        loop {
            let more = match self {
                Dechunker::Size => self.read_size(src, &mut pos)?,
                Dechunker::Chunk(_) => self.read_data(src, dst, &mut pos)?,
                Dechunker::CrLf => self.expect_crlf(src, &mut pos)?,
                Dechunker::Ending => self.trailer_or_ended(src, &mut pos)?,
                Dechunker::Trailer => self.trailer(src, &mut pos)?,
                Dechunker::Ended => false,
            };

            if !more {
                break;
            }
        }

        Ok((pos.index_in, pos.index_out))
    }

    pub fn is_on_chunk_boundary(&self) -> bool {
        *self == Self::Size
    }

    #[cfg(test)]
    fn left(&self) -> usize {
        if let Self::Chunk(l) = self { *l } else { 0 }
    }

    pub fn is_ended(&self) -> bool {
        matches!(self, Self::Ended)
    }

    #[cfg(feature = "client")]
    pub fn is_ending(&self) -> bool {
        matches!(self, Self::Ending)
    }

    fn read_size(&mut self, src: &[u8], pos: &mut Pos) -> Result<bool, Error> {
        let src = &src[pos.index_in..];

        let i = match find_crlf(src) {
            Some(v) => v,
            None => return Ok(false),
        };

        const SANITY_CHECK: usize = 20;

        // Some sanity check for how long the chunk length is
        if i > SANITY_CHECK {
            return Err(Error::ChunkExpectedCrLf);
        }
        let maybe_meta = src.iter().take(100).position(|c| *c == b';');

        let len_end = maybe_meta.unwrap_or(SANITY_CHECK + 1).min(i);
        let len_str = str::from_utf8(&src[..len_end])
            .map_err(|_| Error::ChunkLenNotAscii)?
            .trim();

        let len = usize::from_str_radix(len_str, 16).map_err(|_| Error::ChunkLenNotANumber)?;

        pos.index_in += i + 2;
        *self = if len == 0 {
            Self::Ending
        } else {
            Self::Chunk(len)
        };

        Ok(true)
    }

    fn read_data(&mut self, src: &[u8], dst: &mut [u8], pos: &mut Pos) -> Result<bool, Error> {
        let src = &src[pos.index_in..];
        let dst = &mut dst[pos.index_out..];

        let left = match self {
            Self::Chunk(v) => v,
            _ => unreachable!(),
        };

        // Read the smallest amount of input/output or length left of chunk.
        let to_read = src.len().min(dst.len()).min(*left);

        dst[..to_read].copy_from_slice(&src[..to_read]);
        pos.index_in += to_read;
        pos.index_out += to_read;
        *left -= to_read;

        if *left == 0 {
            *self = Self::CrLf;
        }

        Ok(to_read > 0)
    }

    fn expect_crlf(&mut self, src: &[u8], pos: &mut Pos) -> Result<bool, Error> {
        let src = &src[pos.index_in..];

        let i = match find_crlf(src) {
            Some(v) => v,
            None => return Ok(false),
        };

        if i > 0 {
            return Err(Error::ChunkExpectedCrLf);
        }

        pos.index_in += 2;
        *self = Self::Size;

        Ok(false)
    }

    fn trailer_or_ended(&mut self, src: &[u8], pos: &mut Pos) -> Result<bool, Error> {
        let src = &src[pos.index_in..];

        let i = match find_crlf(src) {
            Some(v) => v,
            None => return Ok(false),
        };

        if i == 0 {
            pos.index_in += 2;
            *self = Self::Ended;
        } else {
            // Non-crlf before
            *self = Self::Trailer;
        }

        Ok(true)
    }

    fn trailer(&mut self, src: &[u8], pos: &mut Pos) -> Result<bool, Error> {
        let src = &src[pos.index_in..];

        let i = match find_crlf(src) {
            Some(v) => v,
            None => return Ok(false),
        };
        assert!(i > 0);

        // advance the trailer, and 2 for the crlf.
        pos.index_in += i + 2;
        *self = Self::Ending;

        Ok(true)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_dechunk_size() -> Result<(), Error> {
        let mut d = Dechunker::new();
        let mut b = [0; 1024];
        assert_eq!(d.parse_input(b"", &mut b)?, (0, 0));
        assert_eq!(d.parse_input(b"2", &mut b)?, (0, 0));
        assert_eq!(d.parse_input(b"2\r", &mut b)?, (0, 0));
        assert_eq!(d.left(), 0);
        assert_eq!(d.parse_input(b"2\r\n", &mut b)?, (3, 0));
        assert_eq!(d.left(), 2);
        Ok(())
    }

    #[test]
    fn test_dechunk_size_meta() -> Result<(), Error> {
        let mut d = Dechunker::new();
        let mut b = [0; 1024];
        assert_eq!(d.parse_input(b"2;meta\r", &mut b)?, (0, 0));
        assert_eq!(d.parse_input(b"2;meta\r\n", &mut b)?, (8, 0));
        Ok(())
    }

    #[test]
    fn test_dechunk_size_not_meta() -> Result<(), Error> {
        let mut d = Dechunker::new();
        let mut b = [0; 1024];
        assert_eq!(d.parse_input(b"9\r\nnot meta;\r\n", &mut b)?, (14, 9));
        assert_eq!(String::from_utf8_lossy(&b[..9]), "not meta;");
        Ok(())
    }

    #[test]
    #[cfg(feature = "client")]
    fn test_dechunk_data() -> Result<(), Error> {
        let mut d = Dechunker::new();
        let mut b = [0; 1024];
        assert_eq!(d.parse_input(b"2\r\nOK", &mut b)?, (5, 2));
        assert_eq!(&b[..2], b"OK");
        assert_eq!(d.left(), 0);
        assert_eq!(d.parse_input(b"\r\n", &mut b)?, (2, 0));
        assert_eq!(d.left(), 0);
        assert!(!d.is_ended());
        assert!(!d.is_ending());
        assert_eq!(d.parse_input(b"0\r\n", &mut b)?, (3, 0));
        assert!(!d.is_ended());
        assert!(d.is_ending());
        assert_eq!(d.parse_input(b"\r\n", &mut b)?, (2, 0));
        assert!(d.is_ended());
        assert!(!d.is_ending());
        Ok(())
    }

    #[test]
    fn test_dechunk_one_chunk_at_a_time() -> Result<(), Error> {
        let mut d = Dechunker::new();
        let mut b = [0; 1024];
        const DATA: &[u8] = b"4\r\ndata\r\n4\r\nmoar\r\n";
        assert_eq!(d.parse_input(DATA, &mut b)?, (9, 4));

        // Stop reading on every chunk boundary.
        assert!(d.is_on_chunk_boundary());

        assert_eq!(String::from_utf8_lossy(&b[..4]), "data");
        Ok(())
    }
}
