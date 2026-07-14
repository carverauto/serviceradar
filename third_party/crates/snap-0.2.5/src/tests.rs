use quickcheck::{QuickCheck, StdGen, TestResult};
#[cfg(feature = "cpp")]
use snappy_cpp as cpp;

use {Encoder, Decoder, Error, decompress_len};

// roundtrip is a macro that compresses the input, then decompresses the result
// and compares it with the original input. If they are not equal, then the
// test fails.
macro_rules! roundtrip {
    ($data:expr) => {{
        let d = &$data[..];
        assert_eq!(d, &*depress(&press(d)));
    }}
}

// errored is a macro that tries to decompress the input and asserts that it
// resulted in an error. If decompression was successful, then the test fails.
macro_rules! errored {
    ($data:expr, $err:expr) => {
        errored!($data, $err, false);
    };
    ($data:expr, $err:expr, $bad_header:expr) => {{
        let d = &$data[..];

        let mut buf = if $bad_header {
            assert_eq!($err, decompress_len(d).unwrap_err());
            vec![0; 1024]
        } else {
            vec![0; decompress_len(d).unwrap()]
        };
        match Decoder::new().decompress(d, &mut buf) {
            Err(ref err) if err == &$err => {}
            Err(ref err) => {
                panic!("expected decompression to fail with {:?}, \
                        but got {:?}", $err, err)
            }
            Ok(n) => {
                panic!("\nexpected decompression to fail, but did not!
original (len == {:?})
----------------------
{:?}

decompressed (len == {:?})
--------------------------
{:?}
", d.len(), d, n, buf);
            }
        }
    }}
}

// testtrip is a macro that defines a test that compresses the input, then
// decompresses the result and compares it with the original input. If they are
// not equal, then the test fails. This test is performed both on the raw
// Snappy format and the framed Snappy format.
//
// If tests are compiled with the cpp feature, then this also tests that the
// C++ library compresses to the same bytes that the Rust library does.
macro_rules! testtrip {
    ($name:ident, $data:expr) => {
        mod $name {
            #[test]
            fn roundtrip_raw() {
                use super::{depress, press};
                roundtrip!($data);
            }

            #[test]
            fn roundtrip_frame() {
                use super::{frame_depress, frame_press};
                let d = &$data[..];
                assert_eq!(d, &*frame_depress(&frame_press(d)));
            }

            #[test]
            #[cfg(feature = "cpp")]
            fn cmpcpp() {
                use super::{press, press_cpp};

                let data = &$data[..];
                let rust = press(data);
                let cpp = press_cpp(data);
                if rust == cpp {
                    return;
                }
                panic!("\ncompression results are not equal!
original (len == {:?})
----------------------
{:?}

rust (len == {:?})
------------------
{:?}

cpp (len == {:?})
-----------------
{:?}
", data.len(), data, rust.len(), rust, cpp.len(), cpp);
            }
        }
    }
}

// testcorrupt is a macro that defines a test that decompresses the input,
// and if the result is anything other than the error given, the test fails.
macro_rules! testerrored {
    ($name:ident, $data:expr, $err:expr) => {
        testerrored!($name, $data, $err, false);
    };
    ($name:ident, $data:expr, $err:expr, $bad_header:expr) => {
        #[test]
        fn $name() {
            errored!($data, $err, $bad_header);
        }
    };
}

// Simple test cases.
testtrip!(empty, &[]);
testtrip!(one_zero, &[0]);

// Roundtrip all of the benchmark data.
testtrip!(data_html, include_bytes!("../data/html"));
testtrip!(data_urls, include_bytes!("../data/urls.10K"));
testtrip!(data_jpg, include_bytes!("../data/fireworks.jpeg"));
testtrip!(data_pdf, include_bytes!("../data/paper-100k.pdf"));
testtrip!(data_html4, include_bytes!("../data/html_x_4"));
testtrip!(data_txt1, include_bytes!("../data/alice29.txt"));
testtrip!(data_txt2, include_bytes!("../data/asyoulik.txt"));
testtrip!(data_txt3, include_bytes!("../data/lcet10.txt"));
testtrip!(data_txt4, include_bytes!("../data/plrabn12.txt"));
testtrip!(data_pb, include_bytes!("../data/geo.protodata"));
testtrip!(data_gaviota, include_bytes!("../data/kppkn.gtb"));
testtrip!(data_golden, include_bytes!("../data/Mark.Twain-Tom.Sawyer.txt"));

// Do it again, with the Snappy frame format.

// Roundtrip the golden data, starting with the compressed bytes.
#[test]
fn data_golden_rev() {
    let data = include_bytes!("../data/Mark.Twain-Tom.Sawyer.txt.rawsnappy");
    let data = &data[..];
    assert_eq!(data, &*press(&depress(data)));
}

// Miscellaneous tests.
#[test]
fn small_copy() {
    use std::iter::repeat;

    for i in 0..32 {
        let inner: String = repeat('b').take(i).collect();
        roundtrip!(format!("aaaa{}aaaabbbb", inner).into_bytes());
    }
}

#[test]
fn small_regular() {
    let mut i = 1;
    while i < 20_000 {
        let mut buf = vec![0; i];
        for (j, x) in buf.iter_mut().enumerate() {
            *x = (j % 10) as u8 + b'a';
        }
        roundtrip!(buf);
        i += 23;
    }
}

// Test that triggered an out of bounds write.
#[test]
fn decompress_copy_close_to_end_1() {
    let buf = [27,
               0b000010_00, 1, 2, 3,
               0b000_000_10, 3, 0,
               0b010110_00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 ,21, 22, 23, 24, 25, 26];
    let decompressed = [1, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26];
    assert_eq!(decompressed, &*depress(&buf));
}

#[test]
fn decompress_copy_close_to_end_2() {
    let buf = [28,
               0b000010_00, 1, 2, 3,
               0b000_000_10, 3, 0,
               0b010111_00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 ,21, 22, 23, 24, 25, 26, 27];
    let decompressed = [1, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27];
    assert_eq!(decompressed, &*depress(&buf));
}

// Tests decompression on malformed data.

// An empty buffer.
testerrored!(err_empty, &b""[..], Error::Empty);

// Decompress fewer bytes than the header reports.
testerrored!(err_header_mismatch, &b"\x05\x00a"[..],
             Error::HeaderMismatch {
                 expected_len: 5,
                 got_len: 1,
             });

// An invalid varint (final byte has continuation bit set).
testerrored!(err_varint1, &b"\xFF"[..], Error::Header, true);

// A varint that overflows u64.
testerrored!(
    err_varint2,
    &b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00"[..],
    Error::Header,
    true
);

// A varint that fits in u64 but overflows u32.
testerrored!(
    err_varint3,
    &b"\x80\x80\x80\x80\x10"[..],
    Error::TooBig {
        given: 4294967296,
        max: 4294967295,
    },
    true
);

// A literal whose length is too small.
// Since the literal length is 1, 'h' is read as a literal and 'i' is
// interpreted as a copy 1 operation missing its offset byte.
testerrored!(err_lit, &b"\x02\x00hi"[..],
             Error::CopyRead {
                 len: 1,
                 src_len: 0,
             });
// A literal whose length is too big.
testerrored!(err_lit_big1, &b"\x02\xechi"[..],
             Error::Literal {
                 len: 60,
                 src_len: 2,
                 dst_len: 2,
             });
// A literal whose length is too big, requires 1 extra byte to be read, and
// src is too short to read that byte.
testerrored!(err_lit_big2a, &b"\x02\xf0hi"[..],
             Error::Literal {
                 len: 4,
                 src_len: 2,
                 dst_len: 2,
             });
// A literal whose length is too big, requires 1 extra byte to be read,
// src is too short to read the full literal.
testerrored!(err_lit_big2b, &b"\x02\xf0hi\x00\x00\x00"[..],
             Error::Literal {
                 len: 105, // because 105 == 'h' as u8 + 1
                 src_len: 4,
                 dst_len: 2,
             });

// A copy 1 operation that stops at the tag byte. This fails because there's
// no byte to read for the copy offset.
testerrored!(err_copy1, &b"\x02\x00a\x01"[..],
             Error::CopyRead { len: 1, src_len: 0 });
// A copy 2 operation that stops at the tag byte and another copy 2 operation
// that stops after the first byte in the offset.
testerrored!(err_copy2a, &b"\x11\x00a\x3e"[..],
             Error::CopyRead { len: 2, src_len: 0 });
testerrored!(err_copy2b, &b"\x11\x00a\x3e\x01"[..],
             Error::CopyRead { len: 2, src_len: 1 });
// Same as copy 2, but for copy 4.
testerrored!(err_copy3a, &b"\x11\x00a\x3f"[..],
             Error::CopyRead { len: 4, src_len: 0 });
testerrored!(err_copy3b, &b"\x11\x00a\x3f\x00"[..],
             Error::CopyRead { len: 4, src_len: 1 });
testerrored!(err_copy3c, &b"\x11\x00a\x3f\x00\x00"[..],
             Error::CopyRead { len: 4, src_len: 2 });
testerrored!(err_copy3d, &b"\x11\x00a\x3f\x00\x00\x00"[..],
             Error::CopyRead { len: 4, src_len: 3 });

// A copy operation whose offset is zero.
testerrored!(err_copy_offset_zero, &b"\x11\x00a\x01\x00"[..],
             Error::Offset { offset: 0, dst_pos: 1 });

// A copy operation whose offset is too big.
testerrored!(err_copy_offset_big, &b"\x11\x00a\x01\xFF"[..],
             Error::Offset { offset: 255, dst_pos: 1 });

// A copy operation whose length is too big.
testerrored!(err_copy_len_big, &b"\x05\x00a\x1d\x01"[..],
             Error::CopyWrite {
                 len: 11,
                 dst_len: 4,
             });

// Selected random inputs pulled from quickcheck failure witnesses.
testtrip!(random1, &[
    0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 1, 1,
    0, 0, 1, 2, 0, 0, 2, 1, 0, 0, 2, 2, 0, 0, 0, 6, 0, 0, 3, 1, 0, 0, 0, 7, 0,
    0, 1, 3, 0, 0, 0, 8, 0, 0, 2, 3, 0, 0, 0, 9, 0, 0, 1, 4, 0, 0, 1, 0, 0, 3,
    0, 0, 1, 0, 1, 0, 0, 0, 10, 0, 0, 0, 0, 2, 4, 0, 0, 2, 0, 0, 3, 0, 1, 0, 0,
    1, 5, 0, 0, 6, 0, 0, 0, 0, 11, 0, 0, 1, 6, 0, 0, 1, 7, 0, 0, 0, 12, 0, 0,
    3, 2, 0, 0, 0, 13, 0, 0, 2, 5, 0, 0, 0, 3, 3, 0, 0, 0, 1, 8, 0, 0, 1, 0,
    1, 0, 0, 0, 4, 1, 0, 0, 0, 0, 14, 0, 0, 0, 1, 9, 0, 0, 0, 1, 10, 0, 0, 0,
    0, 1, 11, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 5, 1, 0, 0, 0, 1,
    2, 1, 0, 0, 0, 0, 0, 2, 6, 0, 0, 0, 0, 0, 1, 12, 0, 0, 0, 0, 0, 3, 4, 0, 0,
    0, 0, 0, 7, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);
testtrip!(random2, &[
    10, 2, 14, 13, 0, 8, 2, 10, 2, 14, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);
testtrip!(random3, &[
    0, 0, 0, 4, 1, 4, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);
testtrip!(random4, &[
    0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 1, 1,
    0, 0, 1, 2, 0, 0, 1, 3, 0, 0, 1, 4, 0, 0, 2, 1, 0, 0, 0, 4, 0, 1, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0
]);

// QuickCheck properties for testing that random data roundtrips.
// These properties tend to produce the inputs for the "random" tests above.

#[test]
fn qc_roundtrip() {
    fn p(bytes: Vec<u8>) -> bool {
        depress(&press(&bytes)) == bytes
    }
    QuickCheck::new()
        .gen(StdGen::new(::rand::thread_rng(), 10_000))
        .tests(1_000)
        .quickcheck(p as fn(_) -> _);
}

#[test]
fn qc_roundtrip_stream() {
    fn p(bytes: Vec<u8>) -> TestResult {
        if bytes.is_empty() {
            return TestResult::discard();
        }
        TestResult::from_bool(frame_depress(&frame_press(&bytes)) == bytes)
    }
    QuickCheck::new()
        .gen(StdGen::new(::rand::thread_rng(), 10_000))
        .tests(1_000)
        .quickcheck(p as fn(_) -> _);
}

#[test]
#[cfg(feature = "cpp")]
fn qc_cmpcpp() {
    fn p(bytes: Vec<u8>) -> bool {
        press(&bytes) == press_cpp(&bytes)
    }
    QuickCheck::new()
        .gen(StdGen::new(::rand::thread_rng(), 10_000))
        .tests(1_000)
        .quickcheck(p as fn(_) -> _);
}

// Regression tests.

// See: https://github.com/BurntSushi/rust-snappy/issues/3
#[cfg(target_pointer_width = "32")]
testerrored!(err_lit_len_overflow1, &b"\x11\x00\x00\xfc\xfe\xff\xff\xff"[..],
             Error::Literal {
                 len: ::std::u32::MAX as u64,
                 src_len: 0,
                 dst_len: 16,
             });
#[cfg(target_pointer_width = "32")]
testerrored!(err_lit_len_overflow2, &b"\x11\x00\x00\xfc\xff\xff\xff\xff"[..],
             Error::Literal {
                 len: ::std::u32::MAX as u64 + 1,
                 src_len: 0,
                 dst_len: 16,
             });

// Helper functions.

fn press(bytes: &[u8]) -> Vec<u8> {
    Encoder::new().compress_vec(bytes).unwrap()
}

fn depress(bytes: &[u8]) -> Vec<u8> {
    Decoder::new().decompress_vec(bytes).unwrap()
}

fn frame_press(bytes: &[u8]) -> Vec<u8> {
    use std::io::Write;
    use frame::Writer;

    let mut wtr = Writer::new(vec![]);
    wtr.write_all(bytes).unwrap();
    wtr.into_inner().unwrap()
}

fn frame_depress(bytes: &[u8]) -> Vec<u8> {
    use std::io::Read;
    use frame::Reader;

    let mut buf = vec![];
    Reader::new(bytes).read_to_end(&mut buf).unwrap();
    buf
}

#[cfg(feature = "cpp")]
fn press_cpp(bytes: &[u8]) -> Vec<u8> {
    use compress::max_compress_len;

    let mut buf = vec![0; max_compress_len(bytes.len())];
    let n = cpp::compress(bytes, &mut buf).unwrap();
    buf.truncate(n);
    buf
}
