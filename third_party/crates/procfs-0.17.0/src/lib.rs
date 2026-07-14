#![allow(unknown_lints)]
// The suggested fix with `str::parse` removes support for Rust 1.48
#![allow(clippy::from_str_radix_10)]
#![deny(rustdoc::broken_intra_doc_links, rustdoc::invalid_html_tags)]
//! This crate provides to an interface into the linux `procfs` filesystem, usually mounted at
//! `/proc`.
//!
//! This is a pseudo-filesystem which is available on most every linux system and provides an
//! interface to kernel data structures.
//!
//!
//! # Kernel support
//!
//! Not all fields/data are available in each kernel.  Some fields were added in specific kernel
//! releases, and other fields are only present in certain kernel configuration options are
//! enabled.  These are represented as `Option` fields in this crate.
//!
//! This crate aims to support all 2.6 kernels (and newer).  WSL2 is also supported.
//!
//! # Documentation
//!
//! In almost all cases, the documentation is taken from the
//! [`proc.5`](http://man7.org/linux/man-pages/man5/proc.5.html) manual page.  This means that
//! sometimes the style of writing is not very "rusty", or may do things like reference related files
//! (instead of referencing related structs).  Contributions to improve this are welcome.
//!
//! # Panicing
//!
//! While previous versions of the library could panic, this current version aims to be panic-free
//! in a many situations as possible.  Whenever the procfs crate encounters a bug in its own
//! parsing code, it will return an [`InternalError`](enum.ProcError.html#variant.InternalError) error.  This should be considered a
//! bug and should be [reported](https://github.com/eminence/procfs).  If you encounter a panic,
//! please report that as well.
//!
//! # Cargo features
//!
//! The following cargo features are available:
//!
//! * `chrono` -- Default.  Optional.  This feature enables a few methods that return values as `DateTime` objects.
//! * `flate2` -- Default.  Optional.  This feature enables parsing gzip compressed `/proc/config.gz` file via the `procfs::kernel_config` method.
//! * `backtrace` -- Optional.  This feature lets you get a stack trace whenever an `InternalError` is raised.
//!
//! # Examples
//!
//! Examples can be found in the various modules shown below, or in the
//! [examples](https://github.com/eminence/procfs/tree/master/procfs/examples) folder of the code repository.
//!

pub use procfs_core::*;

use bitflags::bitflags;

use rustix::fd::AsFd;
use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::io::{self, BufReader, Read, Seek};
use std::path::{Path, PathBuf};
use std::str::FromStr;

#[cfg(feature = "chrono")]
use chrono::DateTime;

const PROC_CONFIG_GZ: &str = "/proc/config.gz";
const BOOT_CONFIG: &str = "/boot/config";

/// Allows associating a specific file to parse.
pub trait Current: FromRead {
    const PATH: &'static str;

    /// Parse the current value using the system file.
    fn current() -> ProcResult<Self> {
        Self::from_file(Self::PATH)
    }
}

/// A type for accessing data about the currently running machine
///
/// For more details, see the [SystemInfoInterface] trait.
pub struct LocalSystemInfo;

impl SystemInfoInterface for LocalSystemInfo {
    fn boot_time_secs(&self) -> ProcResult<u64> {
        crate::boot_time_secs()
    }

    fn ticks_per_second(&self) -> u64 {
        crate::ticks_per_second()
    }

    fn page_size(&self) -> u64 {
        crate::page_size()
    }

    fn is_little_endian(&self) -> bool {
        u16::from_ne_bytes([0, 1]).to_le_bytes() == [0, 1]
    }
}

const LOCAL_SYSTEM_INFO: LocalSystemInfo = LocalSystemInfo;

/// The current [SystemInfo].
pub fn current_system_info() -> &'static SystemInfo {
    &LOCAL_SYSTEM_INFO
}

/// Allows associating a specific file to parse with system information.
pub trait CurrentSI: FromReadSI {
    const PATH: &'static str;

    /// Parse the current value using the system file and the current system info.
    fn current() -> ProcResult<Self> {
        Self::current_with_system_info(current_system_info())
    }

    /// Parse the current value using the system file and the provided system info.
    fn current_with_system_info(si: &SystemInfo) -> ProcResult<Self> {
        Self::from_file(Self::PATH, si)
    }
}

/// Allows `impl WithSystemInfo` to use the current system info.
pub trait WithCurrentSystemInfo<'a>: WithSystemInfo<'a> + Sized {
    /// Get the value using the current system info.
    fn get(self) -> Self::Output {
        self.with_system_info(current_system_info())
    }
}

impl<'a, T: WithSystemInfo<'a>> WithCurrentSystemInfo<'a> for T {}

/// Extension traits useful for importing wholesale.
pub mod prelude {
    pub use super::{Current, CurrentSI, WithCurrentSystemInfo};
    pub use procfs_core::prelude::*;
}

macro_rules! wrap_io_error {
    ($path:expr, $expr:expr) => {
        match $expr {
            Ok(v) => Ok(v),
            Err(e) => {
                let kind = e.kind();
                Err(::std::io::Error::new(
                    kind,
                    crate::IoErrorWrapper {
                        path: $path.to_owned(),
                        inner: e.into(),
                    },
                ))
            }
        }
    };
}

pub(crate) fn read_file<P: AsRef<Path>>(path: P) -> ProcResult<String> {
    std::fs::read_to_string(path.as_ref())
        .map_err(|e| e.into())
        .error_path(path.as_ref())
}

pub(crate) fn write_file<P: AsRef<Path>, T: AsRef<[u8]>>(path: P, buf: T) -> ProcResult<()> {
    std::fs::write(path.as_ref(), buf)
        .map_err(|e| e.into())
        .error_path(path.as_ref())
}

pub(crate) fn read_value<P, T, E>(path: P) -> ProcResult<T>
where
    P: AsRef<Path>,
    T: FromStr<Err = E>,
    ProcError: From<E>,
{
    read_file(path).and_then(|s| s.trim().parse().map_err(ProcError::from))
}

pub(crate) fn write_value<P: AsRef<Path>, T: fmt::Display>(path: P, value: T) -> ProcResult<()> {
    write_file(path, value.to_string().as_bytes())
}

mod cgroups;
pub use crate::cgroups::*;

mod crypto;
pub use crate::crypto::*;

pub mod keyring;

mod iomem;
pub use iomem::*;

mod kpageflags;
pub use kpageflags::*;

mod kpagecount;
pub use kpagecount::*;

pub mod net;

pub mod process;

pub mod sys;
pub use crate::sys::kernel::BuildInfo as KernelBuildInfo;
pub use crate::sys::kernel::Type as KernelType;
pub use crate::sys::kernel::Version as KernelVersion;

/// A wrapper around a `File` that remembers the name of the path
struct FileWrapper {
    inner: File,
    path: PathBuf,
}

impl FileWrapper {
    fn open<P: AsRef<Path>>(path: P) -> Result<FileWrapper, io::Error> {
        let p = path.as_ref();
        let f = wrap_io_error!(p, File::open(p))?;
        Ok(FileWrapper {
            inner: f,
            path: p.to_owned(),
        })
    }
    fn open_at<P, Q, Fd: AsFd>(root: P, dirfd: Fd, path: Q) -> Result<FileWrapper, io::Error>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
    {
        use rustix::fs::{Mode, OFlags};

        let p = root.as_ref().join(path.as_ref());
        let fd = wrap_io_error!(
            p,
            rustix::fs::openat(dirfd, path.as_ref(), OFlags::RDONLY | OFlags::CLOEXEC, Mode::empty())
        )?;
        Ok(FileWrapper {
            inner: File::from(fd),
            path: p,
        })
    }

    /// Returns the inner file
    fn inner(self) -> File {
        self.inner
    }
}

impl Read for FileWrapper {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        wrap_io_error!(self.path, self.inner.read(buf))
    }
    fn read_to_end(&mut self, buf: &mut Vec<u8>) -> io::Result<usize> {
        wrap_io_error!(self.path, self.inner.read_to_end(buf))
    }
    fn read_to_string(&mut self, buf: &mut String) -> io::Result<usize> {
        wrap_io_error!(self.path, self.inner.read_to_string(buf))
    }
    fn read_exact(&mut self, buf: &mut [u8]) -> io::Result<()> {
        wrap_io_error!(self.path, self.inner.read_exact(buf))
    }
}

impl Seek for FileWrapper {
    fn seek(&mut self, pos: io::SeekFrom) -> io::Result<u64> {
        wrap_io_error!(self.path, self.inner.seek(pos))
    }
}

/// Return the number of ticks per second.
///
/// This isn't part of the proc file system, but it's a useful thing to have, since several fields
/// count in ticks.  This is calculated from `sysconf(_SC_CLK_TCK)`.
pub fn ticks_per_second() -> u64 {
    rustix::param::clock_ticks_per_second()
}

/// The boot time of the system, as a `DateTime` object.
///
/// This is calculated from `/proc/stat`.
///
/// This function requires the "chrono" features to be enabled (which it is by default).
#[cfg(feature = "chrono")]
pub fn boot_time() -> ProcResult<DateTime<chrono::Local>> {
    use chrono::TimeZone;
    let secs = boot_time_secs()?;

    let date_time = expect!(chrono::Local.timestamp_opt(secs as i64, 0).single());

    Ok(date_time)
}

/// The boottime of the system, in seconds since the epoch
///
/// This is calculated from `/proc/stat`.
///
#[cfg_attr(
    not(feature = "chrono"),
    doc = "If you compile with the optional `chrono` feature, you can use the `boot_time()` method to get the boot time as a `DateTime` object."
)]
#[cfg_attr(
    feature = "chrono",
    doc = "See also [boot_time()] to get the boot time as a `DateTime`"
)]
pub fn boot_time_secs() -> ProcResult<u64> {
    BOOT_TIME.with(|x| {
        let mut btime = x.borrow_mut();
        if let Some(btime) = *btime {
            Ok(btime)
        } else {
            // KernelStats doesn't call `boot_time_secs()`, so it's safe to call
            // KernelStats::current() (which uses the local system info).
            let stat = KernelStats::current()?;
            *btime = Some(stat.btime);
            Ok(stat.btime)
        }
    })
}

thread_local! {
    static BOOT_TIME : std::cell::RefCell<Option<u64>> = std::cell::RefCell::new(None);
}

/// Memory page size, in bytes.
///
/// This is calculated from `sysconf(_SC_PAGESIZE)`.
pub fn page_size() -> u64 {
    rustix::param::page_size() as u64
}

impl Current for LoadAverage {
    const PATH: &'static str = "/proc/loadavg";
}

impl Current for KernelConfig {
    const PATH: &'static str = PROC_CONFIG_GZ;

    /// Returns a configuration options used to build the currently running kernel
    ///
    /// If CONFIG_KCONFIG_PROC is available, the config is read from `/proc/config.gz`.
    /// Else look in `/boot/config-$(uname -r)` or `/boot/config` (in that order).
    ///
    /// # Notes
    /// Reading the compress `/proc/config.gz` is only supported if the `flate2` feature is enabled
    /// (which it is by default).
    #[cfg_attr(feature = "flate2", doc = "The flate2 feature is currently enabled")]
    #[cfg_attr(not(feature = "flate2"), doc = "The flate2 feature is NOT currently enabled")]
    fn current() -> ProcResult<Self> {
        let reader: Box<dyn Read> = if Path::new(PROC_CONFIG_GZ).exists() && cfg!(feature = "flate2") {
            #[cfg(feature = "flate2")]
            {
                let file = FileWrapper::open(PROC_CONFIG_GZ)?;
                let decoder = flate2::read::GzDecoder::new(file);
                Box::new(decoder)
            }
            #[cfg(not(feature = "flate2"))]
            {
                unreachable!("flate2 feature not enabled")
            }
        } else {
            let kernel = rustix::system::uname();

            let filename = format!("{}-{}", BOOT_CONFIG, kernel.release().to_string_lossy());

            match FileWrapper::open(filename) {
                Ok(file) => Box::new(BufReader::new(file)),
                Err(e) => match e.kind() {
                    io::ErrorKind::NotFound => {
                        let file = FileWrapper::open(BOOT_CONFIG)?;
                        Box::new(file)
                    }
                    _ => return Err(e.into()),
                },
            }
        };

        Self::from_read(reader)
    }
}

/// Returns a configuration options used to build the currently running kernel
///
/// If CONFIG_KCONFIG_PROC is available, the config is read from `/proc/config.gz`.
/// Else look in `/boot/config-$(uname -r)` or `/boot/config` (in that order).
///
/// # Notes
/// Reading the compress `/proc/config.gz` is only supported if the `flate2` feature is enabled
/// (which it is by default).
pub fn kernel_config() -> ProcResult<HashMap<String, ConfigSetting>> {
    KernelConfig::current().map(|c| c.0)
}

impl CurrentSI for KernelStats {
    const PATH: &'static str = "/proc/stat";
}

impl Current for VmStat {
    const PATH: &'static str = "/proc/vmstat";
}

/// Get various virtual memory statistics
///
/// Since the exact set of statistics will vary from kernel to kernel, and because most of them are
/// not well documented, this function returns a HashMap instead of a struct. Consult the kernel
/// source code for more details of this data.
///
/// This data is taken from the /proc/vmstat file.
///
/// (since Linux 2.6.0)
pub fn vmstat() -> ProcResult<HashMap<String, i64>> {
    VmStat::current().map(|s| s.0)
}

impl Current for KernelModules {
    const PATH: &'static str = "/proc/modules";
}

/// Get a list of loaded kernel modules
///
/// This corresponds to the data in `/proc/modules`.
pub fn modules() -> ProcResult<HashMap<String, KernelModule>> {
    KernelModules::current().map(|m| m.0)
}

impl Current for KernelCmdline {
    const PATH: &'static str = "/proc/cmdline";
}

/// Get a list of the arguments passed to the Linux kernel at boot time
///
/// This corresponds to the data in `/proc/cmdline`.
pub fn cmdline() -> ProcResult<Vec<String>> {
    KernelCmdline::current().map(|c| c.0)
}

impl Current for CpuInfo {
    const PATH: &'static str = "/proc/cpuinfo";
}

impl Current for Devices {
    const PATH: &'static str = "/proc/devices";
}

impl Current for DiskStats {
    const PATH: &'static str = "/proc/diskstats";
}

/// Get disk IO stat info from /proc/diskstats
pub fn diskstats() -> ProcResult<Vec<DiskStat>> {
    DiskStats::current().map(|d| d.0)
}

impl Current for Vec<MountEntry> {
    const PATH: &'static str = "/proc/mounts";
}

/// Get a list of mountpoints from `/proc/mounts`
pub fn mounts() -> ProcResult<Vec<MountEntry>> {
    Vec::<MountEntry>::current()
}

impl Current for Vec<PartitionEntry> {
    const PATH: &'static str = "/proc/partitions";
}

/// Get a list of partitions from `/proc/partitions`
pub fn partitions() -> ProcResult<Vec<PartitionEntry>> {
    Vec::<PartitionEntry>::current()
}

impl Current for Locks {
    const PATH: &'static str = "/proc/locks";
}

/// Get a list of current file locks and leases
///
/// Since Linux 4.9, the list of locks is filtered to show just the locks
/// for the processes in the PID namespace for which the `/proc` filesystem
/// was mounted.
pub fn locks() -> ProcResult<Vec<Lock>> {
    Locks::current().map(|l| l.0)
}

impl Current for Meminfo {
    const PATH: &'static str = "/proc/meminfo";
}

impl Current for CpuPressure {
    const PATH: &'static str = "/proc/pressure/cpu";
}

impl Current for MemoryPressure {
    const PATH: &'static str = "/proc/pressure/memory";
}

impl Current for IoPressure {
    const PATH: &'static str = "/proc/pressure/io";
}

impl Current for SharedMemorySegments {
    const PATH: &'static str = "/proc/sysvipc/shm";
}

impl Current for Uptime {
    const PATH: &'static str = "/proc/uptime";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_statics() {
        println!("{:?}", crate::sys::kernel::Version::cached());
    }

    #[test]
    fn test_loadavg() {
        let load = LoadAverage::current().unwrap();
        println!("{:?}", load);
    }

    #[test]
    fn test_kernel_config() {
        // TRAVIS
        // we don't have access to the kernel_config on travis, so skip that test there
        match std::env::var("TRAVIS") {
            Ok(ref s) if s == "true" => return,
            _ => {}
        }
        if !Path::new(PROC_CONFIG_GZ).exists() && !Path::new(BOOT_CONFIG).exists() {
            return;
        }

        let config = KernelConfig::current().unwrap();
        println!("{:#?}", config);
    }

    #[test]
    fn test_file_io_errors() {
        fn inner<P: AsRef<Path>>(p: P) -> Result<(), ProcError> {
            let mut file = FileWrapper::open(p)?;

            let mut buf = [0; 128];
            file.read_exact(&mut buf[0..128])?;

            Ok(())
        }

        let err = inner("/this_should_not_exist").unwrap_err();
        println!("{}", err);

        match err {
            ProcError::NotFound(Some(p)) => {
                assert_eq!(p, Path::new("/this_should_not_exist"));
            }
            x => panic!("Unexpected return value: {:?}", x),
        }

        match inner("/proc/loadavg") {
            Err(ProcError::Io(_, Some(p))) => {
                assert_eq!(p, Path::new("/proc/loadavg"));
            }
            x => panic!("Unexpected return value: {:?}", x),
        }
    }

    #[test]
    fn test_kernel_stat() {
        let stat = KernelStats::current().unwrap();
        println!("{:#?}", stat);

        // the boottime from KernelStats should match the boottime from /proc/uptime
        let boottime = boot_time_secs().unwrap();

        let diff = (boottime as i32 - stat.btime as i32).abs();
        assert!(diff <= 1);

        let cpuinfo = CpuInfo::current().unwrap();
        assert_eq!(cpuinfo.num_cores(), stat.cpu_time.len());

        // the sum of each individual CPU should be equal to the total cpu entry
        // note: on big machines with 128 cores, it seems that the differences can be rather high,
        // especially when heavily loaded.  So this test tolerates a 6000-tick discrepancy
        // (60 seconds in a 100-tick-per-second kernel)

        let user: u64 = stat.cpu_time.iter().map(|i| i.user).sum();
        let nice: u64 = stat.cpu_time.iter().map(|i| i.nice).sum();
        let system: u64 = stat.cpu_time.iter().map(|i| i.system).sum();
        assert!(
            (stat.total.user as i64 - user as i64).abs() < 6000,
            "sum:{} total:{} diff:{}",
            stat.total.user,
            user,
            stat.total.user - user
        );
        assert!(
            (stat.total.nice as i64 - nice as i64).abs() < 6000,
            "sum:{} total:{} diff:{}",
            stat.total.nice,
            nice,
            stat.total.nice - nice
        );
        assert!(
            (stat.total.system as i64 - system as i64).abs() < 6000,
            "sum:{} total:{} diff:{}",
            stat.total.system,
            system,
            stat.total.system - system
        );

        let diff = stat.total.idle as i64 - (stat.cpu_time.iter().map(|i| i.idle).sum::<u64>() as i64).abs();
        assert!(diff < 1000, "idle time difference too high: {}", diff);
    }

    #[test]
    fn test_vmstat() {
        let stat = VmStat::current().unwrap();
        println!("{:?}", stat);
    }

    #[test]
    fn test_modules() {
        let KernelModules(mods) = KernelModules::current().unwrap();
        for module in mods.values() {
            println!("{:?}", module);
        }
    }

    #[test]
    fn tests_tps() {
        let tps = ticks_per_second();
        println!("{} ticks per second", tps);
    }

    #[test]
    fn test_cmdline() {
        let KernelCmdline(cmdline) = KernelCmdline::current().unwrap();

        for argument in cmdline {
            println!("{}", argument);
        }
    }

    /// Test that our error type can be easily used with the `failure` crate
    #[test]
    fn test_failure() {
        fn inner() -> Result<(), failure::Error> {
            let _load = crate::LoadAverage::current()?;
            Ok(())
        }
        let _ = inner();

        fn inner2() -> Result<(), failure::Error> {
            let proc = crate::process::Process::new(1)?;
            let _io = proc.maps()?;
            Ok(())
        }

        let _ = inner2();
        // Unwrapping this failure should produce a message that looks like:
        // thread 'tests::test_failure' panicked at 'called `Result::unwrap()` on an `Err` value: PermissionDenied(Some("/proc/1/maps"))', src/libcore/result.rs:997:5
    }

    /// Test that an ESRCH error gets mapped into a ProcError::NotFound
    #[test]
    fn test_esrch() {
        let mut command = std::process::Command::new("sleep")
            .arg("10000")
            .spawn()
            .expect("Failed to start sleep");
        let p = crate::process::Process::new(command.id() as i32).expect("Failed to create Process");
        command.kill().expect("Failed to kill sleep");
        command.wait().expect("Failed to wait for sleep");
        let e = p.stat().unwrap_err();
        println!("{:?}", e);

        assert!(matches!(e, ProcError::NotFound(_)));
    }

    #[test]
    fn test_cpuinfo() {
        let info = CpuInfo::current().unwrap();
        println!("{:#?}", info.flags(0));
        for num in 0..info.num_cores() {
            info.model_name(num).unwrap();
            info.vendor_id(num).unwrap();
            // May not be available on some old kernels:
            info.physical_id(num);
        }

        //assert_eq!(info.num_cores(), 8);
    }

    #[test]
    fn test_devices() {
        let devices = Devices::current().unwrap();
        println!("{:#?}", devices);
    }

    #[test]
    fn test_diskstats() {
        for disk in super::diskstats().unwrap() {
            println!("{:?}", disk);
        }
    }

    #[test]
    fn test_locks() {
        for lock in locks().unwrap() {
            println!("{:?}", lock);
            if let LockType::Other(s) = lock.lock_type {
                panic!("Found an unknown lock type {:?}", s);
            }
            if let LockKind::Other(s) = lock.kind {
                panic!("Found an unknown lock kind {:?}", s);
            }
            if let LockMode::Other(s) = lock.mode {
                panic!("Found an unknown lock mode {:?}", s);
            }
        }
    }

    #[allow(clippy::cognitive_complexity)]
    #[allow(clippy::blocks_in_if_conditions)]
    #[test]
    fn test_meminfo() {
        // TRAVIS
        // we don't have access to the kernel_config on travis, so skip that test there
        match ::std::env::var("TRAVIS") {
            Ok(ref s) if s == "true" => return,
            _ => {}
        }

        let kernel = KernelVersion::current().unwrap();
        let config = KernelConfig::current().ok();

        let meminfo = Meminfo::current().unwrap();
        println!("{:#?}", meminfo);

        // for the fields that are only present in some kernel versions, make sure our
        // actual kernel agrees

        if kernel >= KernelVersion::new(3, 14, 0) {
            assert!(meminfo.mem_available.is_some());
        }

        if kernel >= KernelVersion::new(2, 6, 28) {
            assert!(meminfo.active_anon.is_some());
            assert!(meminfo.inactive_anon.is_some());
            assert!(meminfo.active_file.is_some());
            assert!(meminfo.inactive_file.is_some());
        } else {
            assert!(meminfo.active_anon.is_none());
            assert!(meminfo.inactive_anon.is_none());
            assert!(meminfo.active_file.is_none());
            assert!(meminfo.inactive_file.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 28)
            && kernel <= KernelVersion::new(2, 6, 30)
            && meminfo.unevictable.is_some()
        {
            if let Some(KernelConfig(ref config)) = config {
                assert!(config.get("CONFIG_UNEVICTABLE_LRU").is_some());
            }
        }

        if kernel >= KernelVersion::new(2, 6, 19)
            && config
                .as_ref()
                .map_or(false, |KernelConfig(cfg)| cfg.contains_key("CONFIG_HIGHMEM"))
        {
            assert!(meminfo.high_total.is_some());
            assert!(meminfo.high_free.is_some());
            assert!(meminfo.low_total.is_some());
            assert!(meminfo.low_free.is_some());
        } else {
            assert!(meminfo.high_total.is_none());
            assert!(meminfo.high_free.is_none());
            assert!(meminfo.low_total.is_none());
            assert!(meminfo.low_free.is_none());
        }

        // Possible bug in procfs documentation:
        // The man page says that MmapCopy requires CONFIG_MMU, but if you look at the
        // source, MmapCopy is only included if CONFIG_MMU is *missing*:
        // https://github.com/torvalds/linux/blob/v4.17/fs/proc/meminfo.c#L80
        //if kernel >= KernelVersion::new(2, 6, 29) && config.contains_key("CONFIG_MMU") {
        //    assert!(meminfo.mmap_copy.is_some());
        //} else {
        //    assert!(meminfo.mmap_copy.is_none());
        //}

        if kernel >= KernelVersion::new(2, 6, 18) {
            assert!(meminfo.anon_pages.is_some());
            assert!(meminfo.page_tables.is_some());
            assert!(meminfo.nfs_unstable.is_some());
            assert!(meminfo.bounce.is_some());
        } else {
            assert!(meminfo.anon_pages.is_none());
            assert!(meminfo.page_tables.is_none());
            assert!(meminfo.nfs_unstable.is_none());
            assert!(meminfo.bounce.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 32) {
            assert!(meminfo.shmem.is_some());
            assert!(meminfo.kernel_stack.is_some());
        } else {
            assert!(meminfo.shmem.is_none());
            assert!(meminfo.kernel_stack.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 19) {
            assert!(meminfo.s_reclaimable.is_some());
            assert!(meminfo.s_unreclaim.is_some());
        } else {
            assert!(meminfo.s_reclaimable.is_none());
            assert!(meminfo.s_unreclaim.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 27)
            && config
                .as_ref()
                .map_or(false, |KernelConfig(cfg)| cfg.contains_key("CONFIG_QUICKLIST"))
        {
            assert!(meminfo.quicklists.is_some());
        } else {
            assert!(meminfo.quicklists.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 26) {
            assert!(meminfo.writeback_tmp.is_some());
        } else {
            assert!(meminfo.writeback_tmp.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 10) {
            assert!(meminfo.commit_limit.is_some());
        } else {
            assert!(meminfo.commit_limit.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 32)
            && config.as_ref().map_or(
                std::path::Path::new("/proc/kpagecgroup").exists(),
                |KernelConfig(cfg)| cfg.contains_key("CONFIG_MEMORY_FAILURE"),
            )
        {
            assert!(meminfo.hardware_corrupted.is_some());
        } else {
            assert!(meminfo.hardware_corrupted.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 38)
            && config.as_ref().map_or(false, |KernelConfig(cfg)| {
                cfg.contains_key("CONFIG_TRANSPARENT_HUGEPAGE")
            })
        {
            assert!(meminfo.anon_hugepages.is_some());
        } else {
            // SOme distributions may backport this option into older kernels
            // assert!(meminfo.anon_hugepages.is_none());
        }

        if kernel >= KernelVersion::new(4, 8, 0)
            && config.as_ref().map_or(true, |KernelConfig(cfg)| {
                cfg.contains_key("CONFIG_TRANSPARENT_HUGEPAGE")
            })
        {
            assert!(meminfo.shmem_hugepages.is_some());
            assert!(meminfo.shmem_pmd_mapped.is_some());
        } else {
            assert!(meminfo.shmem_hugepages.is_none());
            assert!(meminfo.shmem_pmd_mapped.is_none());
        }

        if kernel >= KernelVersion::new(3, 1, 0)
            && config
                .as_ref()
                .map_or(true, |KernelConfig(cfg)| cfg.contains_key("CONFIG_CMA"))
        {
            assert!(meminfo.cma_total.is_some());
            assert!(meminfo.cma_free.is_some());
        } else {
            assert!(meminfo.cma_total.is_none());
            assert!(meminfo.cma_free.is_none());
        }

        if config
            .as_ref()
            .map_or(true, |KernelConfig(cfg)| cfg.contains_key("CONFIG_HUGETLB_PAGE"))
        {
            assert!(meminfo.hugepages_total.is_some());
            assert!(meminfo.hugepages_free.is_some());
            assert!(meminfo.hugepagesize.is_some());
        } else {
            assert!(meminfo.hugepages_total.is_none());
            assert!(meminfo.hugepages_free.is_none());
            assert!(meminfo.hugepagesize.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 17)
            && config
                .as_ref()
                .map_or(true, |KernelConfig(cfg)| cfg.contains_key("CONFIG_HUGETLB_PAGE"))
        {
            assert!(meminfo.hugepages_rsvd.is_some());
        } else {
            assert!(meminfo.hugepages_rsvd.is_none());
        }

        if kernel >= KernelVersion::new(2, 6, 24)
            && config
                .as_ref()
                .map_or(true, |KernelConfig(cfg)| cfg.contains_key("CONFIG_HUGETLB_PAGE"))
        {
            assert!(meminfo.hugepages_surp.is_some());
        } else {
            assert!(meminfo.hugepages_surp.is_none());
        }
    }

    #[allow(clippy::manual_range_contains)]
    fn valid_percentage(value: f32) -> bool {
        value >= 0.00 && value < 100.0
    }

    #[test]
    fn test_mem_pressure() {
        if !Path::new("/proc/pressure/memory").exists() {
            return;
        }

        let mem_psi = MemoryPressure::current().unwrap();
        assert!(valid_percentage(mem_psi.some.avg10));
        assert!(valid_percentage(mem_psi.some.avg60));
        assert!(valid_percentage(mem_psi.some.avg300));

        assert!(valid_percentage(mem_psi.full.avg10));
        assert!(valid_percentage(mem_psi.full.avg60));
        assert!(valid_percentage(mem_psi.full.avg300));
    }

    #[test]
    fn test_io_pressure() {
        if !Path::new("/proc/pressure/io").exists() {
            return;
        }

        let io_psi = IoPressure::current().unwrap();
        assert!(valid_percentage(io_psi.some.avg10));
        assert!(valid_percentage(io_psi.some.avg60));
        assert!(valid_percentage(io_psi.some.avg300));

        assert!(valid_percentage(io_psi.full.avg10));
        assert!(valid_percentage(io_psi.full.avg60));
        assert!(valid_percentage(io_psi.full.avg300));
    }

    #[test]
    fn test_cpu_pressure() {
        if !Path::new("/proc/pressure/cpu").exists() {
            return;
        }

        let cpu_psi = CpuPressure::current().unwrap();
        assert!(valid_percentage(cpu_psi.some.avg10));
        assert!(valid_percentage(cpu_psi.some.avg60));
        assert!(valid_percentage(cpu_psi.some.avg300));
    }
}
