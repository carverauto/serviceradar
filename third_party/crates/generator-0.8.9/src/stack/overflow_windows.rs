use super::windows_bindings::Windows::Win32::{
    Foundation::EXCEPTION_STACK_OVERFLOW,
    System::Diagnostics::Debug::{AddVectoredExceptionHandler, CONTEXT, EXCEPTION_POINTERS},
};
use crate::rt::{guard, Context, ContextStack};
use std::sync::Once;

unsafe extern "system" fn vectored_handler(exception_info: *mut EXCEPTION_POINTERS) -> i32 {
    const EXCEPTION_CONTINUE_SEARCH: i32 = 0;
    const EXCEPTION_CONTINUE_EXECUTION: i32 = -1;

    let info = &*exception_info;
    let rec = &(*info.ExceptionRecord);
    let context = &mut (*info.ContextRecord);

    #[cfg(target_arch = "x86_64")]
    let fault_sp = context.Rsp as usize;
    #[cfg(target_arch = "aarch64")]
    let fault_sp = context.Sp as usize;

    if rec.ExceptionCode == EXCEPTION_STACK_OVERFLOW && guard::current().contains(&fault_sp) {
        eprintln!(
            "\ncoroutine in thread '{}' has overflowed its stack\n",
            std::thread::current().name().unwrap_or("<unknown>")
        );

        let env = ContextStack::current();
        let cur = env.top();
        cur.err = Some(Box::new(crate::Error::StackErr));

        context_init(env.pop_context(cur as *mut _), context);

        //yield_now();

        EXCEPTION_CONTINUE_EXECUTION
    } else {
        EXCEPTION_CONTINUE_SEARCH
    }
}

unsafe fn init() {
    AddVectoredExceptionHandler(1, Some(vectored_handler));
}

pub fn init_once() {
    static INIT_ONCE: Once = Once::new();

    INIT_ONCE.call_once(|| unsafe {
        init();
    })
}

#[cfg(target_arch = "x86_64")]
unsafe fn context_init(parent: &mut Context, context: &mut CONTEXT) {
    let [rbx, rsp, rbp, _, r12, r13, r14, r15, _, _, _, stack_base, stack_limit, dealloc_stack, ..] =
        parent.regs.regs.gpr;

    let rip = *(rsp as *const usize);
    let rsp = rsp + std::mem::size_of::<usize>();

    context.Rbx = rbx as u64;
    context.Rsp = rsp as u64;
    context.Rbp = rbp as u64;
    context.R12 = r12 as u64;
    context.R13 = r13 as u64;
    context.R14 = r14 as u64;
    context.R15 = r15 as u64;
    context.Rip = rip as u64;

    let teb: usize;

    unsafe {
        std::arch::asm!(
        "mov {0}, gs:[0x30]",
        out(reg) teb
        );
    }

    *((teb + 0x08) as *mut usize) = stack_base;
    *((teb + 0x10) as *mut usize) = stack_limit;
    *((teb + 0x1478) as *mut usize) = dealloc_stack;
}

#[cfg(target_arch = "aarch64")]
unsafe fn context_init(parent: &mut Context, context: &mut CONTEXT) {
    // Must match initialize_call_frame / swap_registers in aarch64_windows.rs
    const X19: usize = 0;
    // X20..X28
    const FP: usize = 10;
    const LR: usize = 11;
    const SP: usize = 12;
    const D_BASE: usize = 14; // d8 starts here (byte offset 112) and ends d15 (byte offset 168)
    const STACK_BASE: usize = 22;
    const STACK_LIMIT: usize = 23;
    const STACK_DEALLOC: usize = 24;

    let gpr = &parent.regs.regs.gpr;

    // Integer + control: x19..x28, fp, lr, sp, pc
    let regs = &mut context.Anonymous.Anonymous;
    regs.X19 = gpr[X19] as u64;
    regs.X20 = gpr[X19 + 1] as u64;
    regs.X21 = gpr[X19 + 2] as u64;
    regs.X22 = gpr[X19 + 3] as u64;
    regs.X23 = gpr[X19 + 4] as u64;
    regs.X24 = gpr[X19 + 5] as u64;
    regs.X25 = gpr[X19 + 6] as u64;
    regs.X26 = gpr[X19 + 7] as u64;
    regs.X27 = gpr[X19 + 8] as u64;
    regs.X28 = gpr[X19 + 9] as u64;
    regs.Fp = gpr[FP] as u64;
    regs.Lr = gpr[LR] as u64;
    context.Sp = gpr[SP] as u64;
    context.Pc = gpr[LR] as u64;

    // Callee-saved FP regs: d8..d15 live in low 64 bits of V[8..16]
    let d_src = (gpr.as_ptr() as *const u64).add(D_BASE);
    for i in 0..8 {
        let bits = *d_src.add(i);
        context.V[8 + i].Anonymous.Low = bits;
        context.V[8 + i].Anonymous.High = 0;
    }

    let teb: usize;
    core::arch::asm!("mov {0}, x18", out(reg) teb);

    *((teb + 0x08) as *mut usize) = gpr[STACK_BASE];
    *((teb + 0x10) as *mut usize) = gpr[STACK_LIMIT];
    *((teb + 0x1478) as *mut usize) = gpr[STACK_DEALLOC];
}
