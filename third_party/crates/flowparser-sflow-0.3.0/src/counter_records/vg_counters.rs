use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VgCounters {
    pub in_high_priority_frames: u32,
    pub in_high_priority_octets: u64,
    pub in_norm_priority_frames: u32,
    pub in_norm_priority_octets: u64,
    pub in_ipm_errors: u32,
    pub in_oversize_frame_errors: u32,
    pub in_data_errors: u32,
    pub in_null_addressed_frames: u32,
    pub out_high_priority_frames: u32,
    pub out_high_priority_octets: u64,
    pub out_norm_priority_frames: u32,
    pub out_norm_priority_octets: u64,
    pub in_hc_high_priority_octets: u64,
    pub in_hc_norm_priority_octets: u64,
    pub out_hc_high_priority_octets: u64,
    pub out_hc_norm_priority_octets: u64,
}

pub(crate) fn parse_vg_counters(input: &[u8]) -> IResult<&[u8], VgCounters> {
    let (input, in_high_priority_frames) = be_u32(input)?;
    let (input, in_high_priority_octets) = be_u64(input)?;
    let (input, in_norm_priority_frames) = be_u32(input)?;
    let (input, in_norm_priority_octets) = be_u64(input)?;
    let (input, in_ipm_errors) = be_u32(input)?;
    let (input, in_oversize_frame_errors) = be_u32(input)?;
    let (input, in_data_errors) = be_u32(input)?;
    let (input, in_null_addressed_frames) = be_u32(input)?;
    let (input, out_high_priority_frames) = be_u32(input)?;
    let (input, out_high_priority_octets) = be_u64(input)?;
    let (input, out_norm_priority_frames) = be_u32(input)?;
    let (input, out_norm_priority_octets) = be_u64(input)?;
    let (input, in_hc_high_priority_octets) = be_u64(input)?;
    let (input, in_hc_norm_priority_octets) = be_u64(input)?;
    let (input, out_hc_high_priority_octets) = be_u64(input)?;
    let (input, out_hc_norm_priority_octets) = be_u64(input)?;

    Ok((
        input,
        VgCounters {
            in_high_priority_frames,
            in_high_priority_octets,
            in_norm_priority_frames,
            in_norm_priority_octets,
            in_ipm_errors,
            in_oversize_frame_errors,
            in_data_errors,
            in_null_addressed_frames,
            out_high_priority_frames,
            out_high_priority_octets,
            out_norm_priority_frames,
            out_norm_priority_octets,
            in_hc_high_priority_octets,
            in_hc_norm_priority_octets,
            out_hc_high_priority_octets,
            out_hc_norm_priority_octets,
        },
    ))
}
