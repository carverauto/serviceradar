#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_get_stackid, bpf_ktime_get_ns},
    macros::{map, perf_event},
    maps::{HashMap, StackTrace},
    programs::PerfEventContext,
};

// Maximum number of stack frames to capture
const MAX_STACK_DEPTH: u32 = 127;

// Stack trace key structure
#[repr(C)]
#[derive(Clone, Copy)]
pub struct StackKey {
    pub pid: u32,
    pub stack_id: i32,
}

// Stack trace count value
#[repr(C)]
#[derive(Clone, Copy)]
pub struct StackValue {
    pub count: u64,
    pub first_seen: u64,
    pub last_seen: u64,
}

// Target PID for profiling (set from userspace)
#[map]
static TARGET_PID: HashMap<u32, u32> = HashMap::with_max_entries(1, 0);

// Stack traces storage - maps stack IDs to actual stack traces
#[map]
static STACK_TRACES: StackTrace = StackTrace::with_max_entries(10000, 0);

// Stack trace counts - maps (pid, stack_id) to count information
#[map]
static STACK_COUNTS: HashMap<StackKey, StackValue> = HashMap::with_max_entries(10000, 0);

// Statistics map
#[map]
static STATS: HashMap<u32, u64> = HashMap::with_max_entries(10, 0);

// Statistics keys
const STAT_TOTAL_SAMPLES: u32 = 0;
const STAT_FILTERED_SAMPLES: u32 = 1;
const STAT_STACK_TRACE_ERRORS: u32 = 2;

#[perf_event]
pub fn sample_stack_traces(ctx: PerfEventContext) -> u32 {
    match try_sample_stack_traces(ctx) {
        Ok(ret) => ret,
        Err(_) => 1,
    }
}

fn try_sample_stack_traces(ctx: PerfEventContext) -> Result<u32, i64> {
    let pid_tgid = bpf_get_current_pid_tgid();
    let pid = (pid_tgid >> 32) as u32;
    let tgid = pid_tgid as u32;

    // Increment total samples counter
    increment_stat(STAT_TOTAL_SAMPLES)?;

    // Check if we should profile this process
    let target_exists = unsafe { TARGET_PID.get(&0).is_some() };
    if target_exists {
        let target_pid = unsafe { TARGET_PID.get(&0).ok_or(1i64)? };
        if *target_pid != 0 && *target_pid != tgid {
            increment_stat(STAT_FILTERED_SAMPLES)?;
            return Ok(0);
        }
    }

    // Get stack trace
    let stack_id = bpf_get_stackid(&ctx, &STACK_TRACES, 0)?;
    if stack_id < 0 {
        increment_stat(STAT_STACK_TRACE_ERRORS)?;
        return Ok(0);
    }

    let stack_key = StackKey {
        pid: tgid,
        stack_id,
    };

    let current_time = bpf_ktime_get_ns();

    // Update or insert stack count
    match unsafe { STACK_COUNTS.get_ptr_mut(&stack_key) } {
        Some(stack_value) => {
            unsafe {
                (*stack_value).count += 1;
                (*stack_value).last_seen = current_time;
            }
        }
        None => {
            let new_value = StackValue {
                count: 1,
                first_seen: current_time,
                last_seen: current_time,
            };
            let _ = STACK_COUNTS.insert(&stack_key, &new_value, 0);
        }
    }

    Ok(0)
}

fn increment_stat(key: u32) -> Result<(), i64> {
    match unsafe { STATS.get_ptr_mut(&key) } {
        Some(value) => {
            unsafe {
                *value += 1;
            }
            Ok(())
        }
        None => {
            let _ = STATS.insert(&key, &1u64, 0);
            Ok(())
        }
    }
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}