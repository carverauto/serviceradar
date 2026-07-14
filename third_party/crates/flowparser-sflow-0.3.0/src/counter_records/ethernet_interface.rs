use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EthernetInterface {
    pub dot3_stats_alignment_errors: u32,
    pub dot3_stats_fcs_errors: u32,
    pub dot3_stats_single_collision_frames: u32,
    pub dot3_stats_multiple_collision_frames: u32,
    pub dot3_stats_sqe_test_errors: u32,
    pub dot3_stats_deferred_transmissions: u32,
    pub dot3_stats_late_collisions: u32,
    pub dot3_stats_excessive_collisions: u32,
    pub dot3_stats_internal_mac_transmit_errors: u32,
    pub dot3_stats_carrier_sense_errors: u32,
    pub dot3_stats_frame_too_longs: u32,
    pub dot3_stats_internal_mac_receive_errors: u32,
    pub dot3_stats_symbol_errors: u32,
}

pub(crate) fn parse_ethernet_interface(input: &[u8]) -> IResult<&[u8], EthernetInterface> {
    let (input, dot3_stats_alignment_errors) = be_u32(input)?;
    let (input, dot3_stats_fcs_errors) = be_u32(input)?;
    let (input, dot3_stats_single_collision_frames) = be_u32(input)?;
    let (input, dot3_stats_multiple_collision_frames) = be_u32(input)?;
    let (input, dot3_stats_sqe_test_errors) = be_u32(input)?;
    let (input, dot3_stats_deferred_transmissions) = be_u32(input)?;
    let (input, dot3_stats_late_collisions) = be_u32(input)?;
    let (input, dot3_stats_excessive_collisions) = be_u32(input)?;
    let (input, dot3_stats_internal_mac_transmit_errors) = be_u32(input)?;
    let (input, dot3_stats_carrier_sense_errors) = be_u32(input)?;
    let (input, dot3_stats_frame_too_longs) = be_u32(input)?;
    let (input, dot3_stats_internal_mac_receive_errors) = be_u32(input)?;
    let (input, dot3_stats_symbol_errors) = be_u32(input)?;

    Ok((
        input,
        EthernetInterface {
            dot3_stats_alignment_errors,
            dot3_stats_fcs_errors,
            dot3_stats_single_collision_frames,
            dot3_stats_multiple_collision_frames,
            dot3_stats_sqe_test_errors,
            dot3_stats_deferred_transmissions,
            dot3_stats_late_collisions,
            dot3_stats_excessive_collisions,
            dot3_stats_internal_mac_transmit_errors,
            dot3_stats_carrier_sense_errors,
            dot3_stats_frame_too_longs,
            dot3_stats_internal_mac_receive_errors,
            dot3_stats_symbol_errors,
        },
    ))
}
