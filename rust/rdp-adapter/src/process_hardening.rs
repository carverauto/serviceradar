use std::io;

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn harden_process_for_secrets() -> io::Result<()> {
    disable_core_dumps()?;

    #[cfg(target_os = "linux")]
    disable_linux_dumpable()?;

    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn harden_process_for_secrets() -> io::Result<()> {
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn disable_core_dumps() -> io::Result<()> {
    let limit = RLimit {
        rlim_cur: 0,
        rlim_max: 0,
    };

    // SAFETY: setrlimit is called with a valid pointer to an initialized
    // rlimit value for RLIMIT_CORE. The call does not retain the pointer.
    let result = unsafe { setrlimit(RLIMIT_CORE, &limit) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}

#[cfg(target_os = "linux")]
fn disable_linux_dumpable() -> io::Result<()> {
    // SAFETY: prctl(PR_SET_DUMPABLE, 0) takes integer arguments only and does
    // not dereference pointers for this operation.
    let result = unsafe { prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
const RLIMIT_CORE: i32 = 4;

#[cfg(target_os = "linux")]
const PR_SET_DUMPABLE: i32 = 4;

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[repr(C)]
struct RLimit {
    rlim_cur: u64,
    rlim_max: u64,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
unsafe extern "C" {
    fn setrlimit(resource: i32, rlim: *const RLimit) -> i32;
}

#[cfg(target_os = "linux")]
unsafe extern "C" {
    fn prctl(option: i32, ...) -> i32;
}
