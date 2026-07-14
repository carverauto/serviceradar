use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OvsDpStats {
    pub n_hit: u32,
    pub n_missed: u32,
    pub n_lost: u32,
    pub n_mask_hit: u32,
    pub n_flows: u32,
    pub n_masks: u32,
}

pub(crate) fn parse_ovs_dp_stats(input: &[u8]) -> IResult<&[u8], OvsDpStats> {
    let (input, n_hit) = be_u32(input)?;
    let (input, n_missed) = be_u32(input)?;
    let (input, n_lost) = be_u32(input)?;
    let (input, n_mask_hit) = be_u32(input)?;
    let (input, n_flows) = be_u32(input)?;
    let (input, n_masks) = be_u32(input)?;

    Ok((
        input,
        OvsDpStats {
            n_hit,
            n_missed,
            n_lost,
            n_mask_hit,
            n_flows,
            n_masks,
        },
    ))
}
