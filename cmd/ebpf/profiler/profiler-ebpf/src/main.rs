#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::gen::{bpf_get_stack, bpf_ktime_get_ns},
    macros::{map, perf_event},
    maps::ring_buf::RingBuf,
    programs::PerfEventContext,
    EbpfContext,
};
use profiler_common::{Sample, SampleHeader};

// Global variable for target PID set by userspace
#[no_mangle]
static PID: u32 = 0;

// Ring buffer for sending samples to userspace
#[map]
static SAMPLES: RingBuf = RingBuf::with_byte_size(4_096 * 4_096, 0);

#[perf_event]
pub fn perf_profiler(ctx: PerfEventContext) -> u32 {
    // Reserve memory in the ring buffer for our sample
    let Some(mut sample) = SAMPLES.reserve::<Sample>(0) else {
        aya_log_ebpf::error!(&ctx, "Failed to reserve sample.");
        return 0;
    };

    // Check if we should profile this process
    let current_pid = ctx.tgid();
    if PID != 0 && PID != current_pid {
        sample.discard(aya_ebpf::bindings::BPF_RB_NO_WAKEUP as u64);
        return 0;
    }

    unsafe {
        // Get user space stack trace
        let stack_len = bpf_get_stack(
            ctx.as_ptr(),
            sample.as_mut_ptr().byte_add(SampleHeader::SIZE) as *mut core::ffi::c_void,
            Sample::STACK_SIZE as u32,
            aya_ebpf::bindings::BPF_F_USER_STACK as u64,
        );

        // Check if stack trace was successful
        let Ok(stack_len) = u64::try_from(stack_len) else {
            aya_log_ebpf::error!(&ctx, "Failed to get stack.");
            sample.discard(aya_ebpf::bindings::BPF_RB_NO_WAKEUP as u64);
            return 0;
        };

        // Write sample header
        core::ptr::write_unaligned(
            sample.as_mut_ptr() as *mut SampleHeader,
            SampleHeader {
                ktime: bpf_ktime_get_ns(),
                pid: ctx.tgid(),
                tid: ctx.pid(),
                stack_len,
            },
        );
    }

    // Submit the sample
    sample.submit(0);
    0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    unsafe { core::hint::unreachable_unchecked() }
}



