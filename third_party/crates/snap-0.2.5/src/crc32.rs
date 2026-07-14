// Sadly, all of the crc crates in Rust appear to be insufficient for high
// performance algorithms. In fact, the implementation here is insufficient!
// The best implementation uses the CRC32 instruction from SSE 4.2, but using
// specialty instructions on stable Rust is an absolute nightmare at the
// moment. The only way I can think to do it is to write some Assembly in a
// separate source file and run an Assembler from build.rs. But we'd need to be
// careful to only do this on platforms that support the CRC32 instruction,
// which means we'd need to query CPUID. There are a couple Rust crates for
// that, but of course, they only work on unstable Rust so we'd need to hand
// roll that too.
//
// As a stopgap, we implement the fastest (slicing-by-16) algorithm described
// here: http://create.stephan-brumme.com/crc32/
// (Actually, slicing-by-16 doesn't seem to be measurably faster than
// slicing-by-8 on my i7-6900K, so use slicing-by-8.)
//
// For Snappy, we only care about CRC32C (32 bit, Castagnoli).
//
// ---AG

// We have a bunch of different implementations of crc32 below that seem
// somewhat useful to leave around for easy benchmarking.
#![allow(dead_code)]

use byteorder::{ByteOrder, LittleEndian as LE};

const CASTAGNOLI_POLY: u32 = 0x82f63b78;

lazy_static! {
    static ref TABLE: [u32; 256] = make_table(CASTAGNOLI_POLY);
    static ref TABLE16: [[u32; 256]; 16] = {
        let mut tab = [[0; 256]; 16];
        tab[0] = make_table(CASTAGNOLI_POLY);
        for i in 0..256 {
            let mut crc = tab[0][i];
            for j in 1..16 {
                crc = (crc >> 8) ^ tab[0][crc as u8 as usize];
                tab[j][i] = crc;
            }
        }
        tab
    };
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
pub fn crc32c(buf: &[u8]) -> u32 {
    // I can't measure any difference between slice8 and slice16.
    crc32c_slice8(buf)
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
fn crc32c_slice16(mut buf: &[u8]) -> u32 {
    let tab = &*TABLE;
    let tab16 = &*TABLE16;
    let mut crc: u32 = !0;
    while buf.len() >= 16 {
        crc ^= LE::read_u32(&buf[0..4]);
        crc = tab16[0][buf[15] as usize]
            ^ tab16[1][buf[14] as usize]
            ^ tab16[2][buf[13] as usize]
            ^ tab16[3][buf[12] as usize]
            ^ tab16[4][buf[11] as usize]
            ^ tab16[5][buf[10] as usize]
            ^ tab16[6][buf[9] as usize]
            ^ tab16[7][buf[8] as usize]
            ^ tab16[8][buf[7] as usize]
            ^ tab16[9][buf[6] as usize]
            ^ tab16[10][buf[5] as usize]
            ^ tab16[11][buf[4] as usize]
            ^ tab16[12][(crc >> 24) as u8 as usize]
            ^ tab16[13][(crc >> 16) as u8 as usize]
            ^ tab16[14][(crc >> 8 ) as u8 as usize]
            ^ tab16[15][(crc      ) as u8 as usize];
        buf = &buf[16..];
    }
    for &b in buf {
        crc = tab[((crc as u8) ^ b) as usize] ^ (crc >> 8);
    }
    !crc
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
fn crc32c_slice8(mut buf: &[u8]) -> u32 {
    let tab = &*TABLE;
    let tab8 = &*TABLE16;
    let mut crc: u32 = !0;
    while buf.len() >= 8 {
        crc ^= LE::read_u32(&buf[0..4]);
        crc = tab8[0][buf[7] as usize]
            ^ tab8[1][buf[6] as usize]
            ^ tab8[2][buf[5] as usize]
            ^ tab8[3][buf[4] as usize]
            ^ tab8[4][(crc >> 24) as u8 as usize]
            ^ tab8[5][(crc >> 16) as u8 as usize]
            ^ tab8[6][(crc >> 8 ) as u8 as usize]
            ^ tab8[7][(crc      ) as u8 as usize];
        buf = &buf[8..];
    }
    for &b in buf {
        crc = tab[((crc as u8) ^ b) as usize] ^ (crc >> 8);
    }
    !crc
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
fn crc32c_slice4(mut buf: &[u8]) -> u32 {
    let tab = &*TABLE;
    let tab4 = &*TABLE16;
    let mut crc: u32 = !0;
    while buf.len() >= 4 {
        crc ^= LE::read_u32(&buf[0..4]);
        crc = tab4[0][(crc >> 24) as u8 as usize]
            ^ tab4[1][(crc >> 16) as u8 as usize]
            ^ tab4[2][(crc >> 8 ) as u8 as usize]
            ^ tab4[3][(crc      ) as u8 as usize];
        buf = &buf[4..];
    }
    for &b in buf {
        crc = tab[((crc as u8) ^ b) as usize] ^ (crc >> 8);
    }
    !crc
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
fn crc32c_multiple(buf: &[u8]) -> u32 {
    let tab = &*TABLE;
    let mut crc: u32 = !0;
    for &b in buf {
        crc = tab[((crc as u8) ^ b) as usize] ^ (crc >> 8);
    }
    !crc
}

/// Returns the CRC32 checksum of `buf` using the Castagnoli polynomial.
fn crc32c_bitwise(buf: &[u8]) -> u32 {
    let mut crc: u32 = !0;
    for &b in buf {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = (crc >> 1) ^ ((crc & 1) * CASTAGNOLI_POLY);
        }
    }
    !crc
}

fn make_table(poly: u32) -> [u32; 256] {
    let mut tab = [0; 256];
    for i in 0u32..256u32 {
        let mut crc = i;
        for _ in 0..8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ poly;
            } else {
                crc >>= 1;
            }
        }
        tab[i as usize] = crc;
    }
    tab
}
