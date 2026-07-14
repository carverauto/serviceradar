use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ieee80211Counters {
    pub transmitted_fragments: u32,
    pub multicast_transmitted_frames: u32,
    pub failures: u32,
    pub retries: u32,
    pub multiple_retries: u32,
    pub frame_duplicates: u32,
    pub rts_successes: u32,
    pub rts_failures: u32,
    pub ack_failures: u32,
    pub received_fragments: u32,
    pub multicast_received_frames: u32,
    pub fcs_errors: u32,
    pub transmitted_frames: u32,
    pub wep_undecryptables: u32,
    pub qos_discarded_fragments: u32,
    pub associated_stations: u32,
    pub qos_cf_polls_received: u32,
    pub qos_cf_polls_unused: u32,
    pub qos_cf_polls_unusable: u32,
    pub qos_cf_polls_lost: u32,
}

pub(crate) fn parse_ieee80211_counters(input: &[u8]) -> IResult<&[u8], Ieee80211Counters> {
    let (input, transmitted_fragments) = be_u32(input)?;
    let (input, multicast_transmitted_frames) = be_u32(input)?;
    let (input, failures) = be_u32(input)?;
    let (input, retries) = be_u32(input)?;
    let (input, multiple_retries) = be_u32(input)?;
    let (input, frame_duplicates) = be_u32(input)?;
    let (input, rts_successes) = be_u32(input)?;
    let (input, rts_failures) = be_u32(input)?;
    let (input, ack_failures) = be_u32(input)?;
    let (input, received_fragments) = be_u32(input)?;
    let (input, multicast_received_frames) = be_u32(input)?;
    let (input, fcs_errors) = be_u32(input)?;
    let (input, transmitted_frames) = be_u32(input)?;
    let (input, wep_undecryptables) = be_u32(input)?;
    let (input, qos_discarded_fragments) = be_u32(input)?;
    let (input, associated_stations) = be_u32(input)?;
    let (input, qos_cf_polls_received) = be_u32(input)?;
    let (input, qos_cf_polls_unused) = be_u32(input)?;
    let (input, qos_cf_polls_unusable) = be_u32(input)?;
    let (input, qos_cf_polls_lost) = be_u32(input)?;

    Ok((
        input,
        Ieee80211Counters {
            transmitted_fragments,
            multicast_transmitted_frames,
            failures,
            retries,
            multiple_retries,
            frame_duplicates,
            rts_successes,
            rts_failures,
            ack_failures,
            received_fragments,
            multicast_received_frames,
            fcs_errors,
            transmitted_frames,
            wep_undecryptables,
            qos_discarded_fragments,
            associated_stations,
            qos_cf_polls_received,
            qos_cf_polls_unused,
            qos_cf_polls_unusable,
            qos_cf_polls_lost,
        },
    ))
}
