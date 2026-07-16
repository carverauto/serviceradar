use std::{env, fs, io, path::PathBuf};

pub const MIN_KERNEL_MAJOR: u32 = 5;
pub const MIN_KERNEL_MINOR: u32 = 8;
pub const KERNEL_RELEASE_FILE_ENV: &str = "SERVICERADAR_NETPROBE_KERNEL_RELEASE_FILE";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KernelVersion {
    pub release: String,
    pub major: u32,
    pub minor: u32,
}

impl KernelVersion {
    pub fn supports_ebpf_capture(&self) -> bool {
        self.major > MIN_KERNEL_MAJOR
            || (self.major == MIN_KERNEL_MAJOR && self.minor >= MIN_KERNEL_MINOR)
    }
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn ensure_supported_kernel() -> anyhow::Result<KernelVersion> {
    let version = current_kernel_version()?;
    if !version.supports_ebpf_capture() {
        anyhow::bail!(
            "kernel {} is too old for netprobe eBPF capture; minimum is {}.{}",
            version.release,
            MIN_KERNEL_MAJOR,
            MIN_KERNEL_MINOR
        );
    }

    Ok(version)
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn current_kernel_version() -> anyhow::Result<KernelVersion> {
    let release = read_kernel_release()?;
    parse_kernel_release(&release)
        .ok_or_else(|| anyhow::anyhow!("unable to parse kernel release {release:?}"))
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn read_kernel_release() -> io::Result<String> {
    let path = env::var_os(KERNEL_RELEASE_FILE_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| "/proc/sys/kernel/osrelease".into());
    fs::read_to_string(path).map(|value| value.trim().to_string())
}

fn parse_kernel_release(release: &str) -> Option<KernelVersion> {
    let mut parts = release.split(['.', '-']);
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;

    Some(KernelVersion {
        release: release.to_string(),
        major,
        minor,
    })
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, OnceLock};

    use super::{KERNEL_RELEASE_FILE_ENV, current_kernel_version, parse_kernel_release};

    fn kernel_env_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    #[test]
    fn accepts_kernel_floor_and_newer() {
        for release in ["5.8.0-23-generic", "5.15.0", "6.6.12-linuxkit"] {
            let version = parse_kernel_release(release).unwrap();

            assert!(version.supports_ebpf_capture(), "{release}");
        }
    }

    #[test]
    fn rejects_older_kernels() {
        let version = parse_kernel_release("5.4.271").unwrap();

        assert!(!version.supports_ebpf_capture());
    }

    #[test]
    fn rejects_unparseable_release() {
        assert!(parse_kernel_release("not-a-kernel").is_none());
    }

    #[test]
    fn reads_kernel_release_from_test_override_file() {
        let _guard = kernel_env_lock();
        let path = std::env::temp_dir().join(format!(
            "serviceradar-netprobe-kernel-{}",
            std::process::id()
        ));
        std::fs::write(&path, "5.4.0-ci\n").unwrap();
        // SAFETY: soundness here rests on no other thread in this test binary touching the
        // environment while the write lands: `kernel_env_lock` serialises the tests that
        // write this variable, and it is removed again before the guard drops. Revisit if a
        // test that reads the environment concurrently is ever added to this crate.
        unsafe {
            std::env::set_var(KERNEL_RELEASE_FILE_ENV, &path);
        }

        let version = current_kernel_version().unwrap();

        // SAFETY: as above; still holding `kernel_env_lock`.
        unsafe {
            std::env::remove_var(KERNEL_RELEASE_FILE_ENV);
        }
        let _ = std::fs::remove_file(path);
        assert_eq!(version.release, "5.4.0-ci");
        assert!(!version.supports_ebpf_capture());
    }
}
