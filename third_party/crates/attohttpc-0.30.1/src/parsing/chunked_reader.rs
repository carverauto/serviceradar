use std::cmp;
use std::io::{self, BufRead, BufReader, Read};
use std::str;

use crate::error::InvalidResponseKind;
use crate::parsing::buffers;

fn parse_chunk_size(line: &[u8]) -> io::Result<usize> {
    line.iter()
        .position(|&b| b == b';')
        .map_or_else(|| str::from_utf8(line), |idx| str::from_utf8(&line[..idx]))
        .map_err(|_| InvalidResponseKind::ChunkSize)
        .and_then(|line| usize::from_str_radix(line.trim(), 16).map_err(|_| InvalidResponseKind::ChunkSize))
        .map_err(|e| e.into())
}

#[derive(Debug)]
pub struct ChunkedReader<R>
where
    R: Read,
{
    inner: BufReader<R>,
    buffer: Vec<u8>,
    consumed: usize,  // bytes consumed from `buffer`
    remaining: usize, // bytes remaining until next chunk
    reached_eof: bool,
}

impl<R> ChunkedReader<R>
where
    R: Read,
{
    pub fn new(reader: BufReader<R>) -> ChunkedReader<R> {
        ChunkedReader {
            inner: reader,
            buffer: Vec::new(),
            consumed: 0,
            remaining: 0,
            reached_eof: false,
        }
    }

    fn read_chunk_size(&mut self) -> io::Result<usize> {
        buffers::read_line(&mut self.inner, &mut self.buffer, 128)?;
        if self.buffer.is_empty() {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        parse_chunk_size(&self.buffer)
    }
}

impl<R> BufRead for ChunkedReader<R>
where
    R: Read,
{
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        const MAX_BUFFER_LEN: usize = 64 * 1024;

        if self.buffer.len() == self.consumed && !(self.remaining == 0 && self.reached_eof) {
            if self.remaining == 0 {
                self.remaining = self.read_chunk_size()?;
                if self.remaining == 0 {
                    self.reached_eof = true;
                }
            }

            self.buffer.resize(cmp::min(self.remaining, MAX_BUFFER_LEN), 0);
            self.inner.read_exact(&mut self.buffer)?;
            self.consumed = 0;
            self.remaining -= self.buffer.len();

            if self.remaining == 0 && !buffers::read_line_ending(&mut self.inner)? {
                self.buffer.clear();
                self.reached_eof = true;

                return Err(InvalidResponseKind::Chunk.into());
            }
        }

        Ok(&self.buffer[self.consumed..])
    }

    fn consume(&mut self, amt: usize) {
        self.consumed = cmp::min(self.consumed + amt, self.buffer.len());
    }
}

impl<R> Read for ChunkedReader<R>
where
    R: Read,
{
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.fill_buf()?.read(buf)?;
        self.consume(n);
        Ok(n)
    }
}

#[test]
fn test_read_works() {
    let msg = b"4\r\nwiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    reader.read_to_string(&mut s).unwrap();
    assert_eq!(s, "wikipedia in\r\n\r\nchunks.");
}

#[test]
fn test_read_empty() {
    let msg = b"0\r\n\r\n";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    reader.read_to_string(&mut s).unwrap();
    assert_eq!(s, "");
}

#[test]
fn test_read_invalid_empty() {
    let msg = b"";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    assert!(reader.read_to_string(&mut s).is_err());
}

#[test]
fn test_read_invalid_chunk() {
    let msg = b"4\r\nwik";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    assert_eq!(
        reader.read_to_string(&mut s).err().unwrap().kind(),
        io::ErrorKind::UnexpectedEof
    );
}

#[test]
fn test_read_invalid_no_terminating_chunk() {
    let msg = b"4\r\nwiki";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    assert_eq!(
        reader.read_to_string(&mut s).err().unwrap().kind(),
        io::ErrorKind::UnexpectedEof
    );
}

#[test]
fn test_read_invalid_bad_terminating_chunk() {
    let msg = b"4\r\nwiki\r\n0\r\n";
    let mut reader = ChunkedReader::new(BufReader::new(&msg[..]));
    let mut s = String::new();
    assert_eq!(
        reader.read_to_string(&mut s).err().unwrap().kind(),
        io::ErrorKind::UnexpectedEof
    );
}
