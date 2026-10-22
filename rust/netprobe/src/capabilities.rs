use anyhow::{Context, Result};

pub fn assert_phase1_capabilities() -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        if has_effective_cap_net_raw()? {
            return Ok(());
        }

        anyhow::bail!("CAP_NET_RAW is required before opening capture interfaces");
    }

    #[cfg(not(target_os = "linux"))]
    {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn has_effective_cap_net_raw() -> Result<bool> {
    // CAP_NET_RAW is 13 in <linux/capability.h>; see capabilities(7).
    const CAP_NET_RAW: u64 = 13;

    let status =
        std::fs::read_to_string("/proc/self/status").context("failed to read /proc/self/status")?;
    let cap_eff = status
        .lines()
        .find_map(|line| line.strip_prefix("CapEff:"))
        .context("CapEff not present in /proc/self/status")?
        .trim();
    let bits = u64::from_str_radix(cap_eff, 16).context("failed to parse CapEff")?;

    Ok(bits & (1u64 << CAP_NET_RAW) != 0)
}

pub fn drop_privileges_or_allow_root(user: Option<&str>, allow_root: bool) -> Result<()> {
    #[cfg(unix)]
    {
        drop_privileges_unix(user, allow_root)?;
    }

    #[cfg(not(unix))]
    {
        let _ = (user, allow_root);
    }

    Ok(())
}

pub fn running_as_root() -> bool {
    #[cfg(unix)]
    {
        nix::unistd::Uid::current().is_root()
    }

    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(unix)]
fn drop_privileges_unix(user: Option<&str>, allow_root: bool) -> Result<()> {
    use std::ffi::CString;

    use nix::unistd::{Uid, User, setgid, setuid};

    let Some(user) = user else {
        if Uid::current().is_root() && !allow_root {
            anyhow::bail!(
                "serviceradar-netprobe refuses to serve IPC as root; configure --drop-user or set --allow-root for development only"
            );
        }
        if Uid::current().is_root() && allow_root {
            log::warn!(
                "serviceradar-netprobe continuing as root because --allow-root was set; do not use this in production"
            );
        }

        return Ok(());
    };

    let Some(target) =
        User::from_name(user).with_context(|| format!("failed to resolve user {user}"))?
    else {
        anyhow::bail!("user {user} does not exist");
    };

    let c_user = CString::new(user).context("drop user contains an embedded NUL byte")?;
    initialize_supplementary_groups(&c_user, target.gid)
        .with_context(|| format!("failed to initialize supplementary groups for {user}"))?;
    #[cfg(target_os = "linux")]
    retained::keep_across_setuid(true)?;
    setgid(target.gid).with_context(|| format!("failed to set gid for {user}"))?;
    setuid(target.uid).with_context(|| format!("failed to set uid for {user}"))?;
    #[cfg(target_os = "linux")]
    {
        retained::retain_only_sys_ptrace()?;
        retained::start_executor()?;
    }

    Ok(())
}

/// Runs `job` on the thread that holds the capability retained after the privilege drop,
/// and returns its result.
///
/// Capabilities are per thread, and every thread netprobe started before the drop (the
/// tokio workers, the eBPF readers) lost them in the `setuid`. Only the dropping thread
/// keeps `CAP_SYS_PTRACE`, so the drop spawns one executor thread from it, which inherits
/// it. Before the drop, when running as root, or off Linux, `job` runs inline. Returns
/// `None` only if the executor thread is gone.
#[cfg(target_os = "linux")]
pub fn run_privileged<R: Send + 'static>(job: impl FnOnce() -> R + Send + 'static) -> Option<R> {
    retained::run(job)
}

#[cfg(not(target_os = "linux"))]
pub fn run_privileged<R: Send + 'static>(job: impl FnOnce() -> R + Send + 'static) -> Option<R> {
    Some(job())
}

/// The one capability netprobe keeps after dropping to its service user.
///
/// `CAP_SYS_PTRACE` gives ptrace-read access to `/proc/<pid>/exe` and `/proc/<pid>/root`
/// of processes owned by other users, which executable-ownership resolution needs
/// (add-srql-exposure-intelligence, design Decision 18). It is kept in the permitted and
/// effective sets only: never inheritable or ambient, so nothing netprobe executes
/// receives it.
#[cfg(target_os = "linux")]
pub mod retained {
    use std::sync::OnceLock;
    use std::sync::mpsc::{SyncSender, sync_channel};

    use anyhow::{Context, Result};

    type Job = Box<dyn FnOnce() + Send>;

    static EXECUTOR: OnceLock<SyncSender<Job>> = OnceLock::new();

    pub(super) fn run<R: Send + 'static>(job: impl FnOnce() -> R + Send + 'static) -> Option<R> {
        let Some(executor) = EXECUTOR.get() else {
            return Some(job());
        };
        let (reply, result) = sync_channel(1);
        executor
            .send(Box::new(move || {
                let _ = reply.send(job());
            }))
            .ok()?;
        result.recv().ok()
    }

    /// Spawns the executor thread from the calling (dropping) thread, so it inherits that
    /// thread's capabilities.
    pub(super) fn start_executor() -> Result<()> {
        if EXECUTOR.get().is_some() {
            return Ok(());
        }
        let (jobs, queue) = sync_channel::<Job>(64);
        std::thread::Builder::new()
            .name("netprobe-procfs".to_string())
            .spawn(move || {
                for job in queue {
                    job();
                }
            })
            .context("failed to spawn the procfs executor thread")?;
        let _ = EXECUTOR.set(jobs);
        Ok(())
    }

    /// `CAP_SYS_PTRACE` in <linux/capability.h>.
    pub const CAP_SYS_PTRACE: u32 = 19;
    const LINUX_CAPABILITY_VERSION_3: u32 = 0x2008_0522;

    #[repr(C)]
    struct CapUserHeader {
        version: u32,
        pid: i32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct CapUserData {
        effective: u32,
        permitted: u32,
        inheritable: u32,
    }

    /// Sets or clears `PR_SET_KEEPCAPS`, which keeps the permitted set across the
    /// `setuid` that leaves root. The effective set is still cleared by that `setuid`.
    pub fn keep_across_setuid(keep: bool) -> Result<()> {
        // SAFETY: PR_SET_KEEPCAPS takes one integer argument and no pointers.
        let rc = unsafe { libc::prctl(libc::PR_SET_KEEPCAPS, libc::c_ulong::from(keep), 0, 0, 0) };
        if rc != 0 {
            return Err(std::io::Error::last_os_error()).context("prctl(PR_SET_KEEPCAPS)");
        }
        Ok(())
    }

    /// Reduces the permitted and effective sets to `CAP_SYS_PTRACE`, empties the
    /// inheritable and ambient sets, and clears `PR_SET_KEEPCAPS`.
    ///
    /// When `CAP_SYS_PTRACE` is not in the permitted set (a unit whose bounding set lacks
    /// it), every set is emptied instead and executable ownership reports
    /// `NOT_PERMITTED` for other users' processes; startup does not fail.
    pub fn retain_only_sys_ptrace() -> Result<()> {
        // SAFETY: PR_CAP_AMBIENT_CLEAR_ALL takes no pointer arguments.
        let rc = unsafe {
            libc::prctl(
                libc::PR_CAP_AMBIENT,
                libc::PR_CAP_AMBIENT_CLEAR_ALL as libc::c_ulong,
                0,
                0,
                0,
            )
        };
        if rc != 0 {
            return Err(std::io::Error::last_os_error()).context("prctl(PR_CAP_AMBIENT_CLEAR_ALL)");
        }
        if let Err(err) = set_capabilities(1 << CAP_SYS_PTRACE) {
            log::warn!(
                "CAP_SYS_PTRACE is not available after the privilege drop ({err}); executable \
                 ownership of other users' processes will be reported as not permitted"
            );
            set_capabilities(0).context("capset(empty)")?;
        }
        keep_across_setuid(false)
    }

    /// Sets permitted and effective to `mask` (capabilities 0-31) and inheritable to empty.
    fn set_capabilities(mask: u32) -> std::io::Result<()> {
        let header = CapUserHeader {
            version: LINUX_CAPABILITY_VERSION_3,
            pid: 0,
        };
        let data = [
            CapUserData {
                effective: mask,
                permitted: mask,
                inheritable: 0,
            },
            CapUserData::default(),
        ];
        // SAFETY: capset reads one header and, for version 3, two data structs; both
        // live on this stack frame for the duration of the call.
        let rc =
            unsafe { libc::syscall(libc::SYS_capset, std::ptr::from_ref(&header), data.as_ptr()) };
        if rc != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

#[cfg(all(unix, target_os = "linux"))]
fn initialize_supplementary_groups(user: &std::ffi::CStr, gid: nix::unistd::Gid) -> Result<()> {
    use nix::unistd::initgroups;

    initgroups(user, gid)?;

    Ok(())
}

#[cfg(all(unix, not(target_os = "linux")))]
fn initialize_supplementary_groups(_user: &std::ffi::CStr, _gid: nix::unistd::Gid) -> Result<()> {
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use std::io::{Read, Write};

    use anyhow::{Context, Result, bail};
    use nix::unistd::{ForkResult, Uid, fork};

    use super::retained::CAP_SYS_PTRACE;

    /// The drop changes process-wide state, so it runs in a forked, single-threaded child.
    /// The capability sets are read on the executor thread, the thread that resolves
    /// executable ownership in production.
    #[test]
    fn privilege_drop_leaves_the_executor_exactly_cap_sys_ptrace() {
        let (mut reader, writer) = std::io::pipe().unwrap();
        // SAFETY: the child runs only the code below and leaves through `_exit`.
        match unsafe { fork() }.unwrap() {
            ForkResult::Child => {
                drop(reader);
                let report = match executor_capability_sets() {
                    Ok(report) => report,
                    Err(err) => format!("error: {err:#}"),
                };
                let _ = (&writer).write_all(report.as_bytes());
                drop(writer);
                // SAFETY: ends the forked child without running the test harness's
                // exit path.
                unsafe { libc::_exit(0) };
            }
            ForkResult::Parent { child } => {
                drop(writer);
                let mut report = String::new();
                reader.read_to_string(&mut report).unwrap();
                nix::sys::wait::waitpid(child, None).unwrap();

                let ptrace = 1u64 << CAP_SYS_PTRACE;
                assert_eq!(
                    report,
                    format!("permitted={ptrace:x} effective={ptrace:x} inheritable=0 ambient=0")
                );
            }
        }
    }

    fn executor_capability_sets() -> Result<String> {
        let ptrace = 1u64 << CAP_SYS_PTRACE;
        if Uid::effective().is_root() && capability_set("CapBnd")? & ptrace != 0 {
            // The production path: root, whose unit bounding set includes CAP_SYS_PTRACE,
            // drops to an unprivileged account.
            super::drop_privileges_or_allow_root(Some("nobody"), false)?;
            if Uid::effective().is_root() {
                bail!("still root after the drop");
            }
        } else {
            // Otherwise a new user namespace grants a full capability set to reduce.
            // SAFETY: unshare takes only flags; this child is single-threaded.
            if unsafe { libc::unshare(libc::CLONE_NEWUSER) } != 0 {
                bail!(
                    "needs root or unprivileged user namespaces: {}",
                    std::io::Error::last_os_error()
                );
            }
            super::retained::retain_only_sys_ptrace()?;
            super::retained::start_executor()?;
        }
        super::run_privileged(|| -> Result<String> {
            Ok(format!(
                "permitted={:x} effective={:x} inheritable={:x} ambient={:x}",
                capability_set("CapPrm")?,
                capability_set("CapEff")?,
                capability_set("CapInh")?,
                capability_set("CapAmb")?,
            ))
        })
        .context("executor thread is gone")?
    }

    /// One capability set of the calling thread.
    fn capability_set(name: &str) -> Result<u64> {
        let status = std::fs::read_to_string("/proc/thread-self/status")?;
        let value = status
            .lines()
            .find_map(|line| line.strip_prefix(&format!("{name}:")))
            .with_context(|| format!("{name} missing from /proc/thread-self/status"))?;
        Ok(u64::from_str_radix(value.trim(), 16)?)
    }
}
