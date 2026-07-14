use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IbCounters {
    pub port_xmit_data: u64,
    pub port_rcv_data: u64,
    pub port_xmit_pkts: u64,
    pub port_rcv_pkts: u64,
    pub symbol_error_counter: u32,
    pub link_error_recovery_counter: u32,
    pub link_downed_counter: u32,
    pub port_rcv_errors: u32,
    pub port_rcv_remote_physical_errors: u32,
    pub port_rcv_switch_relay_errors: u32,
    pub port_xmit_discards: u32,
    pub port_xmit_constraint_errors: u32,
    pub port_rcv_constraint_errors: u32,
    pub local_link_integrity_errors: u32,
    pub excessive_buffer_overrun_errors: u32,
    pub vl15_dropped: u32,
}

pub(crate) fn parse_ib_counters(input: &[u8]) -> IResult<&[u8], IbCounters> {
    let (input, port_xmit_data) = be_u64(input)?;
    let (input, port_rcv_data) = be_u64(input)?;
    let (input, port_xmit_pkts) = be_u64(input)?;
    let (input, port_rcv_pkts) = be_u64(input)?;
    let (input, symbol_error_counter) = be_u32(input)?;
    let (input, link_error_recovery_counter) = be_u32(input)?;
    let (input, link_downed_counter) = be_u32(input)?;
    let (input, port_rcv_errors) = be_u32(input)?;
    let (input, port_rcv_remote_physical_errors) = be_u32(input)?;
    let (input, port_rcv_switch_relay_errors) = be_u32(input)?;
    let (input, port_xmit_discards) = be_u32(input)?;
    let (input, port_xmit_constraint_errors) = be_u32(input)?;
    let (input, port_rcv_constraint_errors) = be_u32(input)?;
    let (input, local_link_integrity_errors) = be_u32(input)?;
    let (input, excessive_buffer_overrun_errors) = be_u32(input)?;
    let (input, vl15_dropped) = be_u32(input)?;

    Ok((
        input,
        IbCounters {
            port_xmit_data,
            port_rcv_data,
            port_xmit_pkts,
            port_rcv_pkts,
            symbol_error_counter,
            link_error_recovery_counter,
            link_downed_counter,
            port_rcv_errors,
            port_rcv_remote_physical_errors,
            port_rcv_switch_relay_errors,
            port_xmit_discards,
            port_xmit_constraint_errors,
            port_rcv_constraint_errors,
            local_link_integrity_errors,
            excessive_buffer_overrun_errors,
            vl15_dropped,
        },
    ))
}
