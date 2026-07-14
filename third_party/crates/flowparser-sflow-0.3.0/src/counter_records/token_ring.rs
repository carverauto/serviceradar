use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenRing {
    pub dot5_stats_line_errors: u32,
    pub dot5_stats_burst_errors: u32,
    pub dot5_stats_ac_errors: u32,
    pub dot5_stats_abort_trans_errors: u32,
    pub dot5_stats_internal_errors: u32,
    pub dot5_stats_lost_frame_errors: u32,
    pub dot5_stats_receive_congestions: u32,
    pub dot5_stats_frame_copied_errors: u32,
    pub dot5_stats_token_errors: u32,
    pub dot5_stats_soft_errors: u32,
    pub dot5_stats_hard_errors: u32,
    pub dot5_stats_signal_loss: u32,
    pub dot5_stats_transmit_beacons: u32,
    pub dot5_stats_recoverys: u32,
    pub dot5_stats_lobe_wires: u32,
    pub dot5_stats_removes: u32,
    pub dot5_stats_singles: u32,
    pub dot5_stats_freq_errors: u32,
}

pub(crate) fn parse_token_ring(input: &[u8]) -> IResult<&[u8], TokenRing> {
    let (input, dot5_stats_line_errors) = be_u32(input)?;
    let (input, dot5_stats_burst_errors) = be_u32(input)?;
    let (input, dot5_stats_ac_errors) = be_u32(input)?;
    let (input, dot5_stats_abort_trans_errors) = be_u32(input)?;
    let (input, dot5_stats_internal_errors) = be_u32(input)?;
    let (input, dot5_stats_lost_frame_errors) = be_u32(input)?;
    let (input, dot5_stats_receive_congestions) = be_u32(input)?;
    let (input, dot5_stats_frame_copied_errors) = be_u32(input)?;
    let (input, dot5_stats_token_errors) = be_u32(input)?;
    let (input, dot5_stats_soft_errors) = be_u32(input)?;
    let (input, dot5_stats_hard_errors) = be_u32(input)?;
    let (input, dot5_stats_signal_loss) = be_u32(input)?;
    let (input, dot5_stats_transmit_beacons) = be_u32(input)?;
    let (input, dot5_stats_recoverys) = be_u32(input)?;
    let (input, dot5_stats_lobe_wires) = be_u32(input)?;
    let (input, dot5_stats_removes) = be_u32(input)?;
    let (input, dot5_stats_singles) = be_u32(input)?;
    let (input, dot5_stats_freq_errors) = be_u32(input)?;

    Ok((
        input,
        TokenRing {
            dot5_stats_line_errors,
            dot5_stats_burst_errors,
            dot5_stats_ac_errors,
            dot5_stats_abort_trans_errors,
            dot5_stats_internal_errors,
            dot5_stats_lost_frame_errors,
            dot5_stats_receive_congestions,
            dot5_stats_frame_copied_errors,
            dot5_stats_token_errors,
            dot5_stats_soft_errors,
            dot5_stats_hard_errors,
            dot5_stats_signal_loss,
            dot5_stats_transmit_beacons,
            dot5_stats_recoverys,
            dot5_stats_lobe_wires,
            dot5_stats_removes,
            dot5_stats_singles,
            dot5_stats_freq_errors,
        },
    ))
}
