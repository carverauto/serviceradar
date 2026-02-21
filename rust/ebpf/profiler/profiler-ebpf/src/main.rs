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

// Add this static PID global to match the bencher example.
// Userspace will patch this value.
#[no_mangle]
static PID: u32 = 0;

// Ring buffer for sending samples to userspace
#[map]
static SAMPLES: RingBuf = RingBuf::with_byte_size(4_096 * 4_096, 0);

#[perf_event]
pub fn perf_profiler(ctx: PerfEventContext) -> u32 {
    // No in-kernel filtering is needed. The kernel will handle it
    // because of how we attach in userspace.
    
    // Reserve memory in the ring buffer for our sample.
    // If the ring buffer is full, we return early.
    let Some(mut sample) = SAMPLES.reserve::<Sample>(0) else {
        aya_log_ebpf::error!(&ctx, "Failed to reserve sample.");
        return 0;
    };

    // The rest of our code is `unsafe` as we are dealing with raw pointers.
    unsafe {
        // Get user space stack trace using the bpf_get_stack helper.
        let stack_len = bpf_get_stack(
            ctx.as_ptr(),
            sample.as_mut_ptr().byte_add(SampleHeader::SIZE) as *mut core::ffi::c_void,
            Sample::STACK_SIZE as u32,
            aya_ebpf::bindings::BPF_F_USER_STACK as u64,
        );

        // If the length of the stack trace is negative, there was an error.
        let Ok(stack_len) = u64::try_from(stack_len) else {
            aya_log_ebpf::error!(&ctx, "Failed to get stack, error code: {}", stack_len);
            // Discard the sample if there was an error.
            sample.discard(aya_ebpf::bindings::BPF_RB_NO_WAKEUP as u64);
            return 0;
        };

        aya_log_ebpf::info!(&ctx, "Successfully got stack trace, length: {}", stack_len);

        // Write the sample header to the reserved buffer.
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

    // Commit the sample to the ring buffer.
    sample.submit(0);
    0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    unsafe { core::hint::unreachable_unchecked() }
}