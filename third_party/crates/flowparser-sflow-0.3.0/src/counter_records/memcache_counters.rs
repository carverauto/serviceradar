use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemcacheCounters {
    pub cmd_set: u32,
    pub cmd_touch: u32,
    pub cmd_flush: u32,
    pub get_hits: u32,
    pub get_misses: u32,
    pub delete_hits: u32,
    pub delete_misses: u32,
    pub incr_hits: u32,
    pub incr_misses: u32,
    pub decr_hits: u32,
    pub decr_misses: u32,
    pub cas_hits: u32,
    pub cas_misses: u32,
    pub cas_badval: u32,
    pub auth_cmds: u32,
    pub auth_errors: u32,
    pub threads: u32,
    pub conn_yields: u32,
    pub listen_disabled_num: u32,
    pub curr_connections: u32,
    pub rejected_connections: u32,
    pub total_connections: u32,
    pub connection_structures: u32,
    pub evictions: u32,
    pub reclaimed: u32,
    pub curr_items: u32,
    pub total_items: u32,
    pub bytes_read: u64,
    pub bytes_written: u64,
    pub bytes: u64,
    pub limit_maxbytes: u64,
}

pub(crate) fn parse_memcache_counters(input: &[u8]) -> IResult<&[u8], MemcacheCounters> {
    let (input, cmd_set) = be_u32(input)?;
    let (input, cmd_touch) = be_u32(input)?;
    let (input, cmd_flush) = be_u32(input)?;
    let (input, get_hits) = be_u32(input)?;
    let (input, get_misses) = be_u32(input)?;
    let (input, delete_hits) = be_u32(input)?;
    let (input, delete_misses) = be_u32(input)?;
    let (input, incr_hits) = be_u32(input)?;
    let (input, incr_misses) = be_u32(input)?;
    let (input, decr_hits) = be_u32(input)?;
    let (input, decr_misses) = be_u32(input)?;
    let (input, cas_hits) = be_u32(input)?;
    let (input, cas_misses) = be_u32(input)?;
    let (input, cas_badval) = be_u32(input)?;
    let (input, auth_cmds) = be_u32(input)?;
    let (input, auth_errors) = be_u32(input)?;
    let (input, threads) = be_u32(input)?;
    let (input, conn_yields) = be_u32(input)?;
    let (input, listen_disabled_num) = be_u32(input)?;
    let (input, curr_connections) = be_u32(input)?;
    let (input, rejected_connections) = be_u32(input)?;
    let (input, total_connections) = be_u32(input)?;
    let (input, connection_structures) = be_u32(input)?;
    let (input, evictions) = be_u32(input)?;
    let (input, reclaimed) = be_u32(input)?;
    let (input, curr_items) = be_u32(input)?;
    let (input, total_items) = be_u32(input)?;
    let (input, bytes_read) = be_u64(input)?;
    let (input, bytes_written) = be_u64(input)?;
    let (input, bytes) = be_u64(input)?;
    let (input, limit_maxbytes) = be_u64(input)?;

    Ok((
        input,
        MemcacheCounters {
            cmd_set,
            cmd_touch,
            cmd_flush,
            get_hits,
            get_misses,
            delete_hits,
            delete_misses,
            incr_hits,
            incr_misses,
            decr_hits,
            decr_misses,
            cas_hits,
            cas_misses,
            cas_badval,
            auth_cmds,
            auth_errors,
            threads,
            conn_yields,
            listen_disabled_num,
            curr_connections,
            rejected_connections,
            total_connections,
            connection_structures,
            evictions,
            reclaimed,
            curr_items,
            total_items,
            bytes_read,
            bytes_written,
            bytes,
            limit_maxbytes,
        },
    ))
}
