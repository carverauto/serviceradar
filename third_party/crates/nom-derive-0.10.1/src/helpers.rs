use crate::traits::*;
use nom::error::ParseError;
use nom::{IResult, ToUsize};
use std::marker::PhantomData;

#[derive(Debug, PartialEq)]
pub struct LengthData<L, D> {
    l: PhantomData<L>,
    pub data: D,
}

impl<L, D> LengthData<L, D> {
    pub const fn new(data: D) -> Self {
        let l = PhantomData;
        LengthData { l, data }
    }
}

impl<L, I, E> Parse<I, E> for LengthData<L, I>
where
    I: Clone + PartialEq + InputSlice,
    E: ParseError<I>,
    L: Parse<I, E> + ToUsize,
{
    fn parse(i: I) -> IResult<I, Self, E> {
        let (rem, length) = L::parse(i)?;
        let (rem, data) = rem.take_split(length.to_usize());
        Ok((rem, LengthData::new(data)))
    }
    fn parse_be(i: I) -> IResult<I, Self, E> {
        let (rem, length) = L::parse_be(i)?;
        let (rem, data) = rem.take_split(length.to_usize());
        Ok((rem, LengthData::new(data)))
    }
    fn parse_le(i: I) -> IResult<I, Self, E> {
        let (rem, length) = L::parse_le(i)?;
        let (rem, data) = rem.take_split(length.to_usize());
        Ok((rem, LengthData::new(data)))
    }
}

pub type LengthDataU8<'a> = LengthData<u8, &'a [u8]>;
pub type LengthDataU16<'a> = LengthData<u16, &'a [u8]>;
pub type LengthDataU32<'a> = LengthData<u32, &'a [u8]>;
pub type LengthDataU64<'a> = LengthData<u64, &'a [u8]>;

#[cfg(test)]
mod tests {
    use super::*;
    use nom::error::Error;

    #[test]
    fn test_parse_trait_length_data() {
        let input: &[u8] = b"\x00\x02ab";

        type T<'a> = LengthData<u16, &'a [u8]>;
        let res: IResult<_, _, Error<&[u8]>> = <T>::parse(input);
        assert_eq!(
            res.unwrap(),
            (b"" as &[u8], LengthData::new(b"ab" as &[u8]))
        );
    }

    #[test]
    fn test_parse_trait_length_data16() {
        let input: &[u8] = b"\x00\x02ab";

        type T<'a> = LengthDataU16<'a>;
        let res: IResult<_, _, Error<&[u8]>> = <T>::parse(input);
        assert_eq!(
            res.unwrap(),
            (b"" as &[u8], LengthData::new(b"ab" as &[u8]))
        );
    }
}
