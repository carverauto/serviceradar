use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JvmStatistics {
    pub heap_initial: u64,
    pub heap_used: u64,
    pub heap_committed: u64,
    pub heap_max: u64,
    pub non_heap_initial: u64,
    pub non_heap_used: u64,
    pub non_heap_committed: u64,
    pub non_heap_max: u64,
    pub gc_count: u32,
    pub gc_time: u32,
    pub classes_loaded: u32,
    pub classes_total: u32,
    pub classes_unloaded: u32,
    pub compilation_time: u32,
    pub threads_live: u32,
    pub threads_daemon: u32,
    pub threads_started: u32,
    pub fds_open: u32,
    pub fds_max: u32,
}

pub(crate) fn parse_jvm_statistics(input: &[u8]) -> IResult<&[u8], JvmStatistics> {
    let (input, heap_initial) = be_u64(input)?;
    let (input, heap_used) = be_u64(input)?;
    let (input, heap_committed) = be_u64(input)?;
    let (input, heap_max) = be_u64(input)?;
    let (input, non_heap_initial) = be_u64(input)?;
    let (input, non_heap_used) = be_u64(input)?;
    let (input, non_heap_committed) = be_u64(input)?;
    let (input, non_heap_max) = be_u64(input)?;
    let (input, gc_count) = be_u32(input)?;
    let (input, gc_time) = be_u32(input)?;
    let (input, classes_loaded) = be_u32(input)?;
    let (input, classes_total) = be_u32(input)?;
    let (input, classes_unloaded) = be_u32(input)?;
    let (input, compilation_time) = be_u32(input)?;
    let (input, threads_live) = be_u32(input)?;
    let (input, threads_daemon) = be_u32(input)?;
    let (input, threads_started) = be_u32(input)?;
    let (input, fds_open) = be_u32(input)?;
    let (input, fds_max) = be_u32(input)?;

    Ok((
        input,
        JvmStatistics {
            heap_initial,
            heap_used,
            heap_committed,
            heap_max,
            non_heap_initial,
            non_heap_used,
            non_heap_committed,
            non_heap_max,
            gc_count,
            gc_time,
            classes_loaded,
            classes_total,
            classes_unloaded,
            compilation_time,
            threads_live,
            threads_daemon,
            threads_started,
            fds_open,
            fds_max,
        },
    ))
}
