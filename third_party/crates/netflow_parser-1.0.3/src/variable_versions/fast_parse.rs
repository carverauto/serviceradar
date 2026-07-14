//! Fast big-endian parsers using `from_be_bytes` intrinsics.
//!
//! nom's generic `be_uint` uses a `Shl + Add + From<u8>` trait loop that LLVM
//! does not optimize into a single `bswap`/`rev` instruction on all widths.
//! Micro-benchmarks show 9-26x speedup for these over nom's equivalents.
//!
//! All functions follow the nom `IResult<&[u8], T>` convention: on success they
//! return `(remaining_input, parsed_value)`, on failure they return an `Eof` error.

use nom::{
    Err as NomErr, IResult,
    error::{Error as NomError, ErrorKind},
};

#[inline]
fn eof_error<T>(input: &[u8]) -> IResult<&[u8], T> {
    Err(NomErr::Error(NomError::new(input, ErrorKind::Eof)))
}

#[inline]
pub(crate) fn parse_u8(input: &[u8]) -> IResult<&[u8], u8> {
    match input.split_first() {
        Some((&byte, remaining)) => Ok((remaining, byte)),
        None => eof_error(input),
    }
}

#[inline]
pub(crate) fn parse_i8(input: &[u8]) -> IResult<&[u8], i8> {
    parse_u8(input).map(|(remaining, value)| (remaining, value as i8))
}

#[inline]
pub(crate) fn parse_u16_be(input: &[u8]) -> IResult<&[u8], u16> {
    if input.len() < 2 {
        return eof_error(input);
    }
    Ok((&input[2..], u16::from_be_bytes([input[0], input[1]])))
}

#[inline]
pub(crate) fn parse_i16_be(input: &[u8]) -> IResult<&[u8], i16> {
    parse_u16_be(input).map(|(remaining, value)| (remaining, value as i16))
}

#[inline]
pub(crate) fn parse_u24_be(input: &[u8]) -> IResult<&[u8], u32> {
    if input.len() < 3 {
        return eof_error(input);
    }
    Ok((
        &input[3..],
        u32::from_be_bytes([0, input[0], input[1], input[2]]),
    ))
}

#[inline]
pub(crate) fn parse_i24_be(input: &[u8]) -> IResult<&[u8], i32> {
    let (remaining, value) = parse_u24_be(input)?;
    let signed = if (value & 0x0080_0000) != 0 {
        (value as i32) | !0x00FF_FFFF
    } else {
        value as i32
    };
    Ok((remaining, signed))
}

#[inline]
pub(crate) fn parse_u32_be(input: &[u8]) -> IResult<&[u8], u32> {
    if input.len() < 4 {
        return eof_error(input);
    }
    Ok((
        &input[4..],
        u32::from_be_bytes([input[0], input[1], input[2], input[3]]),
    ))
}

#[inline]
pub(crate) fn parse_i32_be(input: &[u8]) -> IResult<&[u8], i32> {
    parse_u32_be(input).map(|(remaining, value)| (remaining, value as i32))
}

#[inline]
pub(crate) fn parse_u64_be(input: &[u8]) -> IResult<&[u8], u64> {
    if input.len() < 8 {
        return eof_error(input);
    }
    Ok((
        &input[8..],
        u64::from_be_bytes([
            input[0], input[1], input[2], input[3], input[4], input[5], input[6], input[7],
        ]),
    ))
}

#[inline]
pub(crate) fn parse_i64_be(input: &[u8]) -> IResult<&[u8], i64> {
    parse_u64_be(input).map(|(remaining, value)| (remaining, value as i64))
}

#[inline]
pub(crate) fn parse_u128_be(input: &[u8]) -> IResult<&[u8], u128> {
    if input.len() < 16 {
        return eof_error(input);
    }
    Ok((
        &input[16..],
        u128::from_be_bytes([
            input[0], input[1], input[2], input[3], input[4], input[5], input[6], input[7],
            input[8], input[9], input[10], input[11], input[12], input[13], input[14],
            input[15],
        ]),
    ))
}

#[inline]
pub(crate) fn parse_i128_be(input: &[u8]) -> IResult<&[u8], i128> {
    parse_u128_be(input).map(|(remaining, value)| (remaining, value as i128))
}

/// Parse a fixed-size slice of exactly 6 bytes (e.g. MAC address).
#[inline]
pub(crate) fn parse_6_bytes(input: &[u8]) -> IResult<&[u8], [u8; 6]> {
    if input.len() < 6 {
        return eof_error(input);
    }
    Ok((
        &input[6..],
        [input[0], input[1], input[2], input[3], input[4], input[5]],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Success cases: correct value and remaining input ---

    #[test]
    fn test_parse_u8() {
        let (rest, val) = parse_u8(&[0xAB, 0xCD]).unwrap();
        assert_eq!(val, 0xAB);
        assert_eq!(rest, &[0xCD]);
    }

    #[test]
    fn test_parse_i8() {
        let (rest, val) = parse_i8(&[0xFF, 0x00]).unwrap();
        assert_eq!(val, -1);
        assert_eq!(rest, &[0x00]);
    }

    #[test]
    fn test_parse_u16_be() {
        let (rest, val) = parse_u16_be(&[0x01, 0x02, 0x03]).unwrap();
        assert_eq!(val, 0x0102);
        assert_eq!(rest, &[0x03]);
    }

    #[test]
    fn test_parse_i16_be() {
        // -256 in big-endian two's complement
        let (rest, val) = parse_i16_be(&[0xFF, 0x00, 0xAA]).unwrap();
        assert_eq!(val, -256);
        assert_eq!(rest, &[0xAA]);
    }

    #[test]
    fn test_parse_u24_be() {
        let (rest, val) = parse_u24_be(&[0x01, 0x02, 0x03, 0xFF]).unwrap();
        assert_eq!(val, 0x010203);
        assert_eq!(rest, &[0xFF]);
    }

    #[test]
    fn test_parse_i24_be_positive() {
        // Max positive 24-bit: 0x7FFFFF = 8388607
        let (rest, val) = parse_i24_be(&[0x7F, 0xFF, 0xFF, 0x00]).unwrap();
        assert_eq!(val, 8388607);
        assert_eq!(rest, &[0x00]);
    }

    #[test]
    fn test_parse_i24_be_negative_one() {
        // -1 in 24-bit two's complement: 0xFFFFFF
        let (_, val) = parse_i24_be(&[0xFF, 0xFF, 0xFF]).unwrap();
        assert_eq!(val, -1);
    }

    #[test]
    fn test_parse_i24_be_min() {
        // Min 24-bit: 0x800000 = -8388608
        let (_, val) = parse_i24_be(&[0x80, 0x00, 0x00]).unwrap();
        assert_eq!(val, -8388608);
    }

    #[test]
    fn test_parse_i24_be_negative_small() {
        // -2 in 24-bit two's complement: 0xFFFFFE
        let (_, val) = parse_i24_be(&[0xFF, 0xFF, 0xFE]).unwrap();
        assert_eq!(val, -2);
    }

    #[test]
    fn test_parse_i24_be_zero() {
        let (_, val) = parse_i24_be(&[0x00, 0x00, 0x00]).unwrap();
        assert_eq!(val, 0);
    }

    #[test]
    fn test_parse_u32_be() {
        let (rest, val) = parse_u32_be(&[0x0A, 0x0B, 0x0C, 0x0D, 0xEE]).unwrap();
        assert_eq!(val, 0x0A0B0C0D);
        assert_eq!(rest, &[0xEE]);
    }

    #[test]
    fn test_parse_i32_be() {
        // -1 in big-endian
        let (_, val) = parse_i32_be(&[0xFF, 0xFF, 0xFF, 0xFF]).unwrap();
        assert_eq!(val, -1);
    }

    #[test]
    fn test_parse_u64_be() {
        let input = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xFF];
        let (rest, val) = parse_u64_be(&input).unwrap();
        assert_eq!(val, 256);
        assert_eq!(rest, &[0xFF]);
    }

    #[test]
    fn test_parse_i64_be() {
        let input = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE];
        let (_, val) = parse_i64_be(&input).unwrap();
        assert_eq!(val, -2);
    }

    #[test]
    fn test_parse_u128_be() {
        let mut input = [0u8; 17];
        input[15] = 0x42;
        input[16] = 0xAA; // trailing byte
        let (rest, val) = parse_u128_be(&input).unwrap();
        assert_eq!(val, 0x42);
        assert_eq!(rest, &[0xAA]);
    }

    #[test]
    fn test_parse_i128_be() {
        let input = [0xFF; 16];
        let (_, val) = parse_i128_be(&input).unwrap();
        assert_eq!(val, -1);
    }

    #[test]
    fn test_parse_6_bytes() {
        let input = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11];
        let (rest, val) = parse_6_bytes(&input).unwrap();
        assert_eq!(val, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
        assert_eq!(rest, &[0x11]);
    }

    // --- Exact-size input (no remaining bytes) ---

    #[test]
    fn test_parse_u32_be_exact() {
        let (rest, val) = parse_u32_be(&[0x01, 0x02, 0x03, 0x04]).unwrap();
        assert_eq!(val, 0x01020304);
        assert!(rest.is_empty());
    }

    // --- Error cases: insufficient input ---

    #[test]
    fn test_parse_u8_empty() {
        assert!(parse_u8(&[]).is_err());
    }

    #[test]
    fn test_parse_u16_be_too_short() {
        assert!(parse_u16_be(&[0x01]).is_err());
    }

    #[test]
    fn test_parse_u24_be_too_short() {
        assert!(parse_u24_be(&[0x01, 0x02]).is_err());
    }

    #[test]
    fn test_parse_u32_be_too_short() {
        assert!(parse_u32_be(&[0x01, 0x02, 0x03]).is_err());
    }

    #[test]
    fn test_parse_u64_be_too_short() {
        assert!(parse_u64_be(&[0x01; 7]).is_err());
    }

    #[test]
    fn test_parse_u128_be_too_short() {
        assert!(parse_u128_be(&[0x01; 15]).is_err());
    }

    #[test]
    fn test_parse_6_bytes_too_short() {
        assert!(parse_6_bytes(&[0x01; 5]).is_err());
    }

    #[test]
    fn test_parse_u16_be_empty() {
        assert!(parse_u16_be(&[]).is_err());
    }
}
