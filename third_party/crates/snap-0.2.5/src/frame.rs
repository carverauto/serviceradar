use std::cmp;
use std::io::{self, Read, Write};

use byteorder::{ReadBytesExt, ByteOrder, LittleEndian as LE};

use compress::{Encoder, max_compress_len};
use crc32::crc32c;
use decompress::{Decoder, decompress_len};
use error::{Error, IntoInnerError, new_into_inner_error};
use MAX_BLOCK_SIZE;

lazy_static! {
    static ref MAX_COMPRESS_BLOCK_SIZE: usize =
        max_compress_len(MAX_BLOCK_SIZE);
}

// The special magic string that starts any stream.
//
// This may appear more than once in a stream in order to support easy
// concatenation of files compressed in the Snappy frame format.
const STREAM_IDENTIFIER: &'static [u8] = b"\xFF\x06\x00\x00sNaPpY";

// The body of the special stream identifier.
const STREAM_BODY: &'static [u8] = b"sNaPpY";

// An enumeration describing each of the 4 main chunk types.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum ChunkType {
    Stream = 0xFF,
    Compressed = 0x00,
    Uncompressed = 0x01,
    Padding = 0xFE,
}

impl ChunkType {
    /// Converts a byte to one of the four defined chunk types represented by
    /// a single byte. If the chunk type is reserved, then it is returned as
    /// an Err.
    fn from_u8(b: u8) -> Result<ChunkType, u8> {
        match b {
            0xFF => Ok(ChunkType::Stream),
            0x00 => Ok(ChunkType::Compressed),
            0x01 => Ok(ChunkType::Uncompressed),
            0xFE => Ok(ChunkType::Padding),
            b => Err(b),
        }
    }
}

/// A writer for compressing a Snappy stream.
///
/// This `Writer` wraps any other writer that implements `io::Write`. Bytes
/// written to this writer are compressed using the
/// [Snappy frame format](https://github.com/google/snappy/blob/master/framing_format.txt)
/// (file extension `sz`, MIME type `application/x-snappy-framed`).
///
/// Writes are buffered automatically, so there's no need to wrap the given
/// writer in a `std::io::BufWriter`.
///
/// The writer will be flushed automatically when it is dropped. If an error
/// occurs, it is ignored.
pub struct Writer<W: Write> {
    /// Our main internal state, split out for borrowck reasons (happily paid).
    ///
    /// Also, it's an `Option` so we can move out of it even though `Writer`
    /// impls `Drop`.
    inner: Option<Inner<W>>,
    /// Our buffer of uncompressed bytes. This isn't part of `inner` because
    /// we may write bytes directly from the caller if the given buffer was
    /// big enough. As a result, the main `write` implementation needs to
    /// accept either the internal buffer or the caller's bytes directly. Since
    /// `write` requires a mutable borrow, we satisfy the borrow checker by
    /// separating `src` from the rest of the state.
    src: Vec<u8>,
}

struct Inner<W> {
    /// The underlying writer.
    w: W,
    /// An encoder that we reuse that does the actual block based compression.
    enc: Encoder,
    /// The compressed bytes buffer. Bytes are compressed from src (usually)
    /// to dst before being written to w.
    dst: Vec<u8>,
    /// When false, the stream identifier (with magic bytes) must precede the
    /// next write.
    wrote_stream_ident: bool,
    /// Space for writing the header of a chunk before writing it to the
    /// underlying writer.
    chunk_header: [u8; 8],
}

impl<W: Write> Writer<W> {
    /// Create a new writer for streaming Snappy compression.
    pub fn new(wtr: W) -> Writer<W> {
        Writer {
            inner: Some(Inner {
                w: wtr,
                enc: Encoder::new(),
                dst: vec![0; *MAX_COMPRESS_BLOCK_SIZE],
                wrote_stream_ident: false,
                chunk_header: [0; 8],
            }),
            src: Vec::with_capacity(MAX_BLOCK_SIZE),
        }
    }

    /// Returns the underlying stream, consuming and flushing this writer.
    ///
    /// If flushing the writer caused an error, then an `IntoInnerError` is
    /// returned, which contains both the writer and the original writer.
    pub fn into_inner(mut self) -> Result<W, IntoInnerError<Writer<W>>> {
        match self.flush() {
            Ok(()) => Ok(self.inner.take().unwrap().w),
            Err(err) => Err(new_into_inner_error(self, err)),
        }
    }

    /// Gets a reference to the underlying writer in this encoder.
    pub fn get_ref(&self) -> &W {
        &self.inner.as_ref().unwrap().w
    }
}

impl<W: Write> Drop for Writer<W> {
    fn drop(&mut self) {
        if self.inner.is_some() {
            // Ignore errors because we can't conceivably return an error and
            // panicing in a dtor is bad juju.
            let _ = self.flush();
        }
    }
}

impl<W: Write> Write for Writer<W> {
    fn write(&mut self, mut buf: &[u8]) -> io::Result<usize> {
        let mut total = 0;
        // If there isn't enough room to add buf to src, then add only a piece
        // of it, flush it and mush on.
        loop {
            let free = self.src.capacity() - self.src.len();
            // n is the number of bytes extracted from buf.
            let n =
                if buf.len() <= free {
                    break;
                } else if self.src.is_empty() {
                    // If buf is bigger than our entire buffer then avoid
                    // the indirection and write the buffer directly.
                    try!(self.inner.as_mut().unwrap().write(buf))
                } else {
                    self.src.extend_from_slice(&buf[0..free]);
                    try!(self.flush());
                    free
                };
            buf = &buf[n..];
            total += n;
        }
        // We're only here if buf.len() will fit within the available space of
        // self.src.
        debug_assert!(buf.len() <= (self.src.capacity() - self.src.len()));
        self.src.extend_from_slice(buf);
        total += buf.len();
        // We should never expand or contract self.src.
        debug_assert!(self.src.capacity() == MAX_BLOCK_SIZE);
        Ok(total)
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.src.is_empty() {
            return Ok(());
        }
        try!(self.inner.as_mut().unwrap().write(&self.src));
        self.src.truncate(0);
        Ok(())
    }
}

impl<W: Write> Inner<W> {
    fn write(&mut self, mut buf: &[u8]) -> io::Result<usize> {
        let mut total = 0;
        if !self.wrote_stream_ident {
            self.wrote_stream_ident = true;
            try!(self.w.write_all(STREAM_IDENTIFIER));
        }
        while !buf.is_empty() {
            // Advance buf and get our block.
            let mut src = buf;
            if src.len() > MAX_BLOCK_SIZE {
                src = &src[0..MAX_BLOCK_SIZE];
            }
            buf = &buf[src.len()..];
            let checksum = crc32c_masked(src);

            // Compress the buffer. If compression sucked, throw it out and
            // write uncompressed bytes instead. Since our buffer is at most
            // MAX_BLOCK_SIZE and our dst buffer has size
            // max_compress_len(MAX_BLOCK_SIZE), we have enough space.
            let compress_len = try!(self.enc.compress(src, &mut self.dst));
            let (chunk_type, chunk_len) =
                // We add 4 to the chunk_len because of the checksum.
                if compress_len >= src.len() - (src.len() / 8) {
                    (ChunkType::Uncompressed, 4 + src.len())
                } else {
                    (ChunkType::Compressed, 4 + compress_len)
                };

            self.chunk_header[0] = chunk_type as u8;
            LE::write_uint(&mut self.chunk_header[1..], chunk_len as u64, 3);
            LE::write_u32(&mut self.chunk_header[4..], checksum);
            try!(self.w.write_all(&self.chunk_header));
            if chunk_type == ChunkType::Compressed {
                try!(self.w.write_all(&self.dst[0..compress_len]))
            } else {
                try!(self.w.write_all(src))
            };
            total += src.len();
        }
        Ok(total)
    }
}

/// A reader for decompressing a Snappy stream.
///
/// This `Reader` wraps any other reader that implements `io::Read`. Bytes
/// read from this reader are decompressed using the
/// [Snappy frame format](https://github.com/google/snappy/blob/master/framing_format.txt)
/// (file extension `sz`, MIME type `application/x-snappy-framed`).
///
/// This reader can potentially make many small reads from the underlying
/// stream depending on its format, therefore, passing in a buffered reader
/// may be beneficial.
pub struct Reader<R: Read> {
    /// The underlying reader.
    r: R,
    /// A Snappy decoder that we reuse that does the actual block based
    /// decompression.
    dec: Decoder,
    /// The compressed bytes buffer, taken from the underlying reader.
    src: Vec<u8>,
    /// The decompressed bytes buffer. Bytes are decompressed from src to dst
    /// before being passed back to the caller.
    dst: Vec<u8>,
    /// Index into dst: starting point of bytes not yet given back to caller.
    dsts: usize,
    /// Index into dst: ending point of bytes not yet given back to caller.
    dste: usize,
    /// Whether we've read the special stream header or not.
    read_stream_ident: bool,
}

impl<R: Read> Reader<R> {
    /// Create a new reader for streaming Snappy decompression.
    pub fn new(rdr: R) -> Reader<R> {
        Reader {
            r: rdr,
            dec: Decoder::new(),
            src: vec![0; *MAX_COMPRESS_BLOCK_SIZE],
            dst: vec![0; MAX_BLOCK_SIZE],
            dsts: 0,
            dste: 0,
            read_stream_ident: false,
        }
    }

    /// Gets a reference to the underlying reader in this decoder.
    pub fn get_ref(&self) -> &R {
        &self.r
    }
}

impl<R: Read> Read for Reader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        macro_rules! fail {
            ($err:expr) => {
                return Err(io::Error::from($err));
            }
        }
        loop {
            if self.dsts < self.dste {
                let len = cmp::min(self.dste - self.dsts, buf.len());
                let dste = self.dsts.checked_add(len).unwrap();
                buf[0..len].copy_from_slice(&self.dst[self.dsts..dste]);
                self.dsts = dste;
                return Ok(len);
            }
            if !try!(read_exact_eof(&mut self.r, &mut self.src[0..4])) {
                return Ok(0);
            }
            let ty = ChunkType::from_u8(self.src[0]);
            if !self.read_stream_ident {
                if ty != Ok(ChunkType::Stream) {
                    fail!(Error::StreamHeader { byte: self.src[0] });
                }
                self.read_stream_ident = true;
            }
            let len64 = LE::read_uint(&self.src[1..4], 3);
            if len64 > self.src.len() as u64 {
                fail!(Error::UnsupportedChunkLength {
                    len: len64,
                    header: false,
                });
            }
            let len = len64 as usize;
            match ty {
                Err(b) if 0x02 <= b && b <= 0x7F => {
                    // Spec says that chunk types 0x02-0x7F are reserved and
                    // conformant decoders must return an error.
                    fail!(Error::UnsupportedChunkType { byte: b });
                }
                Err(b) if 0x80 <= b && b <= 0xFD => {
                    // Spec says that chunk types 0x80-0xFD are reserved but
                    // skippable.
                    try!(self.r.read_exact(&mut self.src[0..len]));
                }
                Err(b) => {
                    // Can never happen. 0x02-0x7F and 0x80-0xFD are handled
                    // above in the error case. That leaves 0x00, 0x01, 0xFE
                    // and 0xFF, each of which correspond to one of the four
                    // defined chunk types.
                    unreachable!("BUG: unhandled chunk type: {}", b);
                }
                Ok(ChunkType::Padding) => {
                    // Just read and move on.
                    try!(self.r.read_exact(&mut self.src[0..len]));
                }
                Ok(ChunkType::Stream) => {
                    if len != STREAM_BODY.len() {
                        fail!(Error::UnsupportedChunkLength {
                            len: len64,
                            header: true,
                        })
                    }
                    try!(self.r.read_exact(&mut self.src[0..len]));
                    if &self.src[0..len] != STREAM_BODY {
                        fail!(Error::StreamHeaderMismatch {
                            bytes: self.src[0..len].to_vec(),
                        });
                    }
                }
                Ok(ChunkType::Uncompressed) => {
                    let expected_sum = try!(self.r.read_u32::<LE>());
                    let n = len - 4;
                    if n > self.dst.len() {
                        fail!(Error::UnsupportedChunkLength {
                            len: n as u64,
                            header: false,
                        });
                    }
                    try!(self.r.read_exact(&mut self.dst[0..n]));
                    let got_sum = crc32c_masked(&self.dst[0..n]);
                    if expected_sum != got_sum {
                        fail!(Error::Checksum {
                            expected: expected_sum,
                            got: got_sum,
                        });
                    }
                    self.dsts = 0;
                    self.dste = n;
                }
                Ok(ChunkType::Compressed) => {
                    let expected_sum = try!(self.r.read_u32::<LE>());
                    let sn = len - 4;
                    if sn > self.src.len() {
                        fail!(Error::UnsupportedChunkLength {
                            len: len64,
                            header: false,
                        });
                    }
                    try!(self.r.read_exact(&mut self.src[0..sn]));
                    let dn = try!(decompress_len(&self.src));
                    if dn > self.dst.len() {
                        fail!(Error::UnsupportedChunkLength {
                            len: dn as u64,
                            header: false,
                        });
                    }
                    try!(self.dec.decompress(
                        &self.src[0..sn], &mut self.dst[0..dn]));
                    let got_sum = crc32c_masked(&self.dst[0..dn]);
                    if expected_sum != got_sum {
                        fail!(Error::Checksum {
                            expected: expected_sum,
                            got: got_sum,
                        });
                    }
                    self.dsts = 0;
                    self.dste = dn;
                }
            }
        }
    }
}

// read_exact_eof is like Read::read_exact, except it converts an UnexpectedEof
// error to a bool of false.
//
// If no error occurred, then this returns true.
fn read_exact_eof<R: Read>(rdr: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    use std::io::ErrorKind::UnexpectedEof;
    match rdr.read_exact(buf) {
        Ok(()) => Ok(true),
        Err(ref err) if err.kind() == UnexpectedEof => Ok(false),
        Err(err) => Err(err),
    }
}

fn crc32c_masked(buf: &[u8]) -> u32 {
    // TODO(burntsushi): SSE 4.2 has a CRC32 instruction that is probably
    // faster. Oh how I long for you, SIMD. See src/crc32.rs for a lamentation.
    let sum = crc32c(buf);
    (sum.wrapping_shr(15) | sum.wrapping_shl(17)).wrapping_add(0xA282EAD8)
}
