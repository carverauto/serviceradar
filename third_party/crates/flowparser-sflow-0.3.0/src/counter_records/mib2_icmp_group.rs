use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mib2IcmpGroup {
    pub icmp_in_msgs: u32,
    pub icmp_in_errors: u32,
    pub icmp_in_dest_unreachs: u32,
    pub icmp_in_time_excds: u32,
    pub icmp_in_parm_probs: u32,
    pub icmp_in_src_quenchs: u32,
    pub icmp_in_redirects: u32,
    pub icmp_in_echos: u32,
    pub icmp_in_echo_reps: u32,
    pub icmp_in_timestamps: u32,
    pub icmp_in_timestamp_reps: u32,
    pub icmp_in_addr_masks: u32,
    pub icmp_in_addr_mask_reps: u32,
    pub icmp_out_msgs: u32,
    pub icmp_out_errors: u32,
    pub icmp_out_dest_unreachs: u32,
    pub icmp_out_time_excds: u32,
    pub icmp_out_parm_probs: u32,
    pub icmp_out_src_quenchs: u32,
    pub icmp_out_redirects: u32,
    pub icmp_out_echos: u32,
    pub icmp_out_echo_reps: u32,
    pub icmp_out_timestamps: u32,
    pub icmp_out_timestamp_reps: u32,
    pub icmp_out_addr_masks: u32,
    pub icmp_out_addr_mask_reps: u32,
}

pub(crate) fn parse_mib2_icmp_group(input: &[u8]) -> IResult<&[u8], Mib2IcmpGroup> {
    let (input, icmp_in_msgs) = be_u32(input)?;
    let (input, icmp_in_errors) = be_u32(input)?;
    let (input, icmp_in_dest_unreachs) = be_u32(input)?;
    let (input, icmp_in_time_excds) = be_u32(input)?;
    let (input, icmp_in_parm_probs) = be_u32(input)?;
    let (input, icmp_in_src_quenchs) = be_u32(input)?;
    let (input, icmp_in_redirects) = be_u32(input)?;
    let (input, icmp_in_echos) = be_u32(input)?;
    let (input, icmp_in_echo_reps) = be_u32(input)?;
    let (input, icmp_in_timestamps) = be_u32(input)?;
    let (input, icmp_in_timestamp_reps) = be_u32(input)?;
    let (input, icmp_in_addr_masks) = be_u32(input)?;
    let (input, icmp_in_addr_mask_reps) = be_u32(input)?;
    let (input, icmp_out_msgs) = be_u32(input)?;
    let (input, icmp_out_errors) = be_u32(input)?;
    let (input, icmp_out_dest_unreachs) = be_u32(input)?;
    let (input, icmp_out_time_excds) = be_u32(input)?;
    let (input, icmp_out_parm_probs) = be_u32(input)?;
    let (input, icmp_out_src_quenchs) = be_u32(input)?;
    let (input, icmp_out_redirects) = be_u32(input)?;
    let (input, icmp_out_echos) = be_u32(input)?;
    let (input, icmp_out_echo_reps) = be_u32(input)?;
    let (input, icmp_out_timestamps) = be_u32(input)?;
    let (input, icmp_out_timestamp_reps) = be_u32(input)?;
    let (input, icmp_out_addr_masks) = be_u32(input)?;
    let (input, icmp_out_addr_mask_reps) = be_u32(input)?;

    Ok((
        input,
        Mib2IcmpGroup {
            icmp_in_msgs,
            icmp_in_errors,
            icmp_in_dest_unreachs,
            icmp_in_time_excds,
            icmp_in_parm_probs,
            icmp_in_src_quenchs,
            icmp_in_redirects,
            icmp_in_echos,
            icmp_in_echo_reps,
            icmp_in_timestamps,
            icmp_in_timestamp_reps,
            icmp_in_addr_masks,
            icmp_in_addr_mask_reps,
            icmp_out_msgs,
            icmp_out_errors,
            icmp_out_dest_unreachs,
            icmp_out_time_excds,
            icmp_out_parm_probs,
            icmp_out_src_quenchs,
            icmp_out_redirects,
            icmp_out_echos,
            icmp_out_echo_reps,
            icmp_out_timestamps,
            icmp_out_timestamp_reps,
            icmp_out_addr_masks,
            icmp_out_addr_mask_reps,
        },
    ))
}
