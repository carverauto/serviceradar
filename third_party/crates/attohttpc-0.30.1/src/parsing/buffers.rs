use std::io::{self, BufRead, BufReader, Read, Write};

pub fn read_line<R>(reader: &mut BufReader<R>, buf: &mut Vec<u8>, max_buf_len: u64) -> io::Result<usize>
where
    R: Read,
{
    buf.clear();
    let n = reader.take(max_buf_len).read_until(b'\n', buf)?;

    if buf.ends_with(b"\r\n") {
        buf.truncate(buf.len() - 2);
    } else if buf.ends_with(b"\n") {
        buf.truncate(buf.len() - 1);
    } else {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }

    Ok(n)
}

pub fn read_line_strict<R>(reader: &mut BufReader<R>, buf: &mut Vec<u8>, max_buf_len: u64) -> io::Result<usize>
where
    R: Read,
{
    buf.clear();
    let mut reader = reader.take(max_buf_len);
    let mut n = 0;

    loop {
        let k = reader.read_until(b'\n', buf)?;
        n += k;

        if k == 0 || buf[buf.len() - 1] != b'\n' {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }

        if k >= 2 && buf[buf.len() - 2] == b'\r' && buf[buf.len() - 1] == b'\n' {
            buf.truncate(buf.len() - 2);
            return Ok(n);
        }
    }
}

pub fn read_line_ending<R>(reader: &mut BufReader<R>) -> io::Result<bool>
where
    R: Read,
{
    let mut b = [0];
    reader.read_exact(&mut b)?;

    if &b == b"\r" {
        reader.read_exact(&mut b)?;
    }

    Ok(&b == b"\n")
}

pub fn trim_byte(byte: u8, buf: &[u8]) -> &[u8] {
    trim_byte_left(byte, trim_byte_right(byte, buf))
}

pub fn trim_byte_left(byte: u8, buf: &[u8]) -> &[u8] {
    buf.iter().position(|b| *b != byte).map_or(&[], |n| &buf[n..])
}

pub fn trim_byte_right(byte: u8, buf: &[u8]) -> &[u8] {
    buf.iter().rposition(|b| *b != byte).map_or(&[], |n| &buf[..=n])
}

pub fn replace_byte(byte: u8, replace: u8, buf: &mut [u8]) {
    for val in buf {
        if *val == byte {
            *val = replace;
        }
    }
}

#[derive(Debug)]
pub struct BufReaderWrite<R> {
    inner: BufReader<R>,
}

impl<R: Read> BufReaderWrite<R> {
    pub fn new(inner: R) -> BufReaderWrite<R> {
        BufReaderWrite {
            inner: BufReader::new(inner),
        }
    }
}

impl<R: Read> Read for BufReaderWrite<R> {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<R: Write> Write for BufReaderWrite<R> {
    #[inline]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.inner.get_mut().write(buf)
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        self.inner.get_mut().flush()
    }
}

impl<R> std::ops::Deref for BufReaderWrite<R> {
    type Target = BufReader<R>;
    fn deref(&self) -> &BufReader<R> {
        &self.inner
    }
}

impl<R> std::ops::DerefMut for BufReaderWrite<R> {
    fn deref_mut(&mut self) -> &mut BufReader<R> {
        &mut self.inner
    }
}

#[test]
fn test_read_line_lf() {
    let mut reader = BufReader::new(&b"hello\nworld\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(6));
    assert_eq!(line, b"hello");

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(6));
    assert_eq!(line, b"world");
}

#[test]
fn test_read_line_crlf() {
    let mut reader = BufReader::new(&b"hello\r\nworld\r\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(7));
    assert_eq!(line, b"hello");

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(7));
    assert_eq!(line, b"world");
}

#[test]
fn test_read_line_empty_crlf() {
    let mut reader = BufReader::new(&b"\r\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(2));
    assert_eq!(line, b"");
}

#[test]
fn test_read_line_empty_lf() {
    let mut reader = BufReader::new(&b"\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line(&mut reader, &mut line, u64::MAX).ok(), Some(1));
    assert_eq!(line, b"");
}

#[test]
fn test_read_line_beyond_limit() {
    let mut reader = BufReader::new(&b"1234567890\n"[..]);
    let mut line = Vec::new();

    assert_eq!(
        read_line(&mut reader, &mut line, 5).unwrap_err().kind(),
        io::ErrorKind::UnexpectedEof
    );
    assert_eq!(line, b"12345");
}

#[test]
fn test_read_line_strict() {
    let mut reader = BufReader::new(&b"foo\r\nbar\r\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line_strict(&mut reader, &mut line, u64::MAX).ok(), Some(3 + 2));
    assert_eq!(line, b"foo");
}

#[test]
fn test_read_line_strict_empty_crlf() {
    let mut reader = BufReader::new(&b"\r\n"[..]);
    let mut line = Vec::new();

    assert_eq!(read_line_strict(&mut reader, &mut line, u64::MAX).ok(), Some(2));
    assert_eq!(line, b"");
}

#[test]
fn test_read_line_strict_missing_crlf() {
    let mut reader = BufReader::new(&b"foo\n"[..]);
    let mut line = Vec::new();

    assert_eq!(
        read_line_strict(&mut reader, &mut line, u64::MAX).unwrap_err().kind(),
        io::ErrorKind::UnexpectedEof
    );
    assert_eq!(line, b"foo\n");
}

#[test]
fn test_read_line_strict_inner_lf() {
    let mut reader = BufReader::new(&b"123\n456\n789\n0\r\nABC"[..]);
    let mut line = Vec::new();

    assert_eq!(
        read_line_strict(&mut reader, &mut line, u64::MAX).ok(),
        Some(10 + 3 + 2)
    );
    assert_eq!(line, b"123\n456\n789\n0");
}

#[test]
fn test_read_line_strict_inner_cr() {
    let mut reader = BufReader::new(&b"123\r456\r789\r0\r\nXYZ"[..]);
    let mut line = Vec::new();

    assert_eq!(
        read_line_strict(&mut reader, &mut line, u64::MAX).ok(),
        Some(10 + 3 + 2)
    );
    assert_eq!(line, b"123\r456\r789\r0");
}

#[test]
fn test_trim_byte() {
    assert_eq!(trim_byte(b' ', b"  hello  "), b"hello");
    assert_eq!(trim_byte(b' ', b"hello"), b"hello");
    assert_eq!(trim_byte(b' ', b""), b"");
}

#[test]
fn test_trim_byte_left() {
    assert_eq!(trim_byte_left(b' ', b"  hello"), b"hello");
    assert_eq!(trim_byte_left(b' ', b"hello"), b"hello");
    assert_eq!(trim_byte_left(b' ', b""), b"");
}

#[test]
fn test_trim_byte_right() {
    assert_eq!(trim_byte_right(b' ', b"hello  "), b"hello");
    assert_eq!(trim_byte_right(b' ', b"hello"), b"hello");
    assert_eq!(trim_byte_right(b' ', b""), b"");
}
