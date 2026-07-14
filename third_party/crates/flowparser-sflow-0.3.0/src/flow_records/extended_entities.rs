use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Extended entities data (enterprise=0, format=2210).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedEntities {
    pub src_ds_class: u32,
    pub src_ds_index: u32,
    pub dst_ds_class: u32,
    pub dst_ds_index: u32,
}

pub(crate) fn parse_extended_entities(input: &[u8]) -> IResult<&[u8], ExtendedEntities> {
    let (input, src_ds_class) = be_u32(input)?;
    let (input, src_ds_index) = be_u32(input)?;
    let (input, dst_ds_class) = be_u32(input)?;
    let (input, dst_ds_index) = be_u32(input)?;

    Ok((
        input,
        ExtendedEntities {
            src_ds_class,
            src_ds_index,
            dst_ds_class,
            dst_ds_index,
        },
    ))
}
