#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::gen::{bpf_get_stack, bpf_ktime_get_ns, bpf_get_current_pid_tgid},
    macros::{map, perf_event},
    maps::ring_buf::RingBuf,
    programs::PerfEventContext,
    EbpfContext,
};
use profiler_common::{Sample, SampleHeader};

// Target PID to profile - will be patched by userspace
#[no_mangle]
static TARGET_PID: u32 = 0;

// Ring buffer for sending samples to userspace
#[map]
static SAMPLES: RingBuf = RingBuf::with_byte_size(4_096 * 4_096, 0);

// Add a stats map for debugging
#[map]
static mut STATS: aya_ebpf::maps::Array<u64> = aya_ebpf::maps::Array::with_max_entries(4, 0);

const STAT_TOTAL_EVENTS: u32 = 0;
const STAT_FILTERED_OUT: u32 = 1;
const STAT_SAMPLES_SENT: u32 = 2;
const STAT_BUFFER_FULL: u32 = 3;

#[perf_event]
pub fn perf_profiler(ctx: PerfEventContext) -> u32 {
    // Increment total events counter
    unsafe {
        if let Some(stat) = STATS.get_ptr_mut(STAT_TOTAL_EVENTS) {
            *stat += 1;
        }
    }

    // Get current PID/TID
    let pid_tgid = unsafe { bpf_get_current_pid_tgid() };
    let tgid = (pid_tgid >> 32) as u32; // This is the PID (process ID)
    let pid = (pid_tgid & 0xFFFFFFFF) as u32; // This is the TID (thread ID)

    // Check if we should profile this process
    let target = unsafe { core::ptr::read_volatile(&TARGET_PID) };

    // Enhanced debug logging to understand what PIDs we're getting
    unsafe {
        let event_count = STATS.get(STAT_TOTAL_EVENTS).copied().unwrap_or(0);
        
        // Log first 20 events to see the pattern
        if event_count <= 20 {
            aya_log_ebpf::info!(&ctx, "Event {}: PID={}, TID={}, Target={}", event_count, tgid, pid, target);
        }
        
        // Log every 5000th event to monitor ongoing activity (reduced noise)
        if event_count % 5000 == 0 && event_count > 0 {
            aya_log_ebpf::info!(&ctx, "Milestone: {} events processed, latest PID={}, Target={}", event_count, tgid, target);
        }
    }

    // If TARGET_PID is set (non-zero), filter by it
    if target != 0 && tgid != target {
        unsafe {
            if let Some(stat) = STATS.get_ptr_mut(STAT_FILTERED_OUT) {
                *stat += 1;
            }
            // Log every 10000th filtered event to reduce noise
            let filtered = STATS.get(STAT_FILTERED_OUT).copied().unwrap_or(0);
            if filtered % 10000 == 0 && filtered > 0 {
                aya_log_ebpf::debug!(&ctx, "Filtered {} events, latest PID {} (looking for {})", filtered, tgid, target);
            }
        }
        return 0;
    }

    // Debug: Log when we actually hit the target PID - always log these!
    if target != 0 && tgid == target {
        unsafe {
            let samples = STATS.get(STAT_SAMPLES_SENT).copied().unwrap_or(0);
            let total = STATS.get(STAT_TOTAL_EVENTS).copied().unwrap_or(0);
            aya_log_ebpf::info!(&ctx, "🎯 TARGET HIT! PID={}, TID={}, Event #{}, Samples sent: {}", tgid, pid, total, samples);
        }
    }
    
    // Also log if we get any non-zero, non-target PID to see what else is running
    if tgid != 0 && target != 0 && tgid != target {
        unsafe {
            let total = STATS.get(STAT_TOTAL_EVENTS).copied().unwrap_or(0);
            // Only log first few of these to avoid spam
            if total <= 50 {
                aya_log_ebpf::debug!(&ctx, "Other process: PID={}, TID={} (looking for PID={})", tgid, pid, target);
            }
        }
    }

    // Reserve memory in the ring buffer for our sample
    let Some(mut sample) = SAMPLES.reserve::<Sample>(0) else {
        unsafe {
            if let Some(stat) = STATS.get_ptr_mut(STAT_BUFFER_FULL) {
                *stat += 1;
            }
        }
        // Log only occasionally to avoid spam
        if unsafe { STATS.get(STAT_BUFFER_FULL).copied().unwrap_or(0) % 100 == 1 } {
            aya_log_ebpf::error!(&ctx, "Ring buffer full");
        }
        return 0;
    };

    unsafe {
        // Try to get user space stack trace first
        let mut stack_len = bpf_get_stack(
            ctx.as_ptr(),
            sample.as_mut_ptr().byte_add(SampleHeader::SIZE) as *mut core::ffi::c_void,
            Sample::STACK_SIZE as u32,
            aya_ebpf::bindings::BPF_F_USER_STACK as u64,
        );

        // If user stack failed, try kernel stack as fallback
        if stack_len <= 0 {
            stack_len = bpf_get_stack(
                ctx.as_ptr(),
                sample.as_mut_ptr().byte_add(SampleHeader::SIZE) as *mut core::ffi::c_void,
                Sample::STACK_SIZE as u32,
                0, // No flags = kernel stack
            );
        }

        // If both failed, still submit a minimal sample with just PID info
        // This helps us understand if we're at least hitting the right process
        if stack_len <= 0 {
            // Set a minimal stack with just a marker
            let marker_addr: u64 = 0xDEADBEEF;
            core::ptr::write_unaligned(
                sample.as_mut_ptr().byte_add(SampleHeader::SIZE) as *mut u64,
                marker_addr,
            );
            stack_len = 8; // One address
        }

        let stack_len = stack_len as u64;

        // Write the sample header
        core::ptr::write_unaligned(
            sample.as_mut_ptr() as *mut SampleHeader,
            SampleHeader {
                ktime: bpf_ktime_get_ns(),
                pid: tgid,  // Use process ID, not thread ID
                tid: pid,   // Thread ID
                stack_len,
            },
        );

        // Increment samples sent counter
        if let Some(stat) = STATS.get_ptr_mut(STAT_SAMPLES_SENT) {
            *stat += 1;
        }
    }

    // Submit the sample
    sample.submit(0);
    0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    unsafe { core::hint::unreachable_unchecked() }
}