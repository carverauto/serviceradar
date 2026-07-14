//! Functions and structs related to process information
//!
//! The primary source of data for functions in this module is the files in a `/proc/<pid>/`
//! directory.  If you have a process ID, you can use
//! [`Process::new(pid)`](struct.Process.html#method.new), otherwise you can get a
//! list of all running processes using [`all_processes()`](fn.all_processes.html).
//!
//! In case you have procfs filesystem mounted to a location other than `/proc`,
//! use [`Process::new_with_root()`](struct.Process.html#method.new_with_root).
//!
//! # Examples
//!
//! Here's a small example that prints out all processes that are running on the same tty as the calling
//! process.  This is very similar to what "ps" does in its default mode.  You can run this example
//! yourself with:
//!
//! > cargo run --example=ps
//!
//! ```rust
//! let me = procfs::process::Process::myself().unwrap();
//! let me_stat = me.stat().unwrap();
//! let tps = procfs::ticks_per_second();
//!
//! println!("{: >10} {: <8} {: >8} {}", "PID", "TTY", "TIME", "CMD");
//!
//! let tty = format!("pty/{}", me_stat.tty_nr().1);
//! for prc in procfs::process::all_processes().unwrap() {
//!     let Ok(prc) = prc else {
//!         // process vanished
//!         continue;
//!     };
//!     let Ok(stat) = prc.stat() else {
//!         // process vanished
//!         continue;
//!     };
//!     if let Ok(stat) = prc.stat() {
//!         if stat.tty_nr == me_stat.tty_nr {
//!             // total_time is in seconds
//!             let total_time =
//!                 (stat.utime + stat.stime) as f32 / (tps as f32);
//!             println!(
//!                 "{: >10} {: <8} {: >8} {}",
//!                 stat.pid, tty, total_time, stat.comm
//!             );
//!         }
//!     }
//! }
//! ```
//!
//! Here's a simple example of how you could get the total memory used by the current process.
//! There are several ways to do this.  For a longer example, see the `examples/self_memory.rs`
//! file in the git repository.  You can run this example with:
//!
//! > cargo run --example=self_memory
//!
//! ```rust
//! # use procfs::process::Process;
//! let me = Process::myself().unwrap();
//! let me_stat = me.stat().unwrap();
//! let page_size = procfs::page_size();
//!
//! println!("== Data from /proc/self/stat:");
//! println!("Total virtual memory used: {} bytes", me_stat.vsize);
//! println!("Total resident set: {} pages ({} bytes)", me_stat.rss, me_stat.rss as u64 * page_size);
//! ```

use super::*;
use crate::net::{TcpNetEntry, UdpNetEntry};
use crate::sys::kernel::Version;

pub use procfs_core::process::*;
use rustix::fd::{AsFd, BorrowedFd, OwnedFd, RawFd};
use rustix::fs::{AtFlags, Mode, OFlags, RawMode};
#[cfg(feature = "serde1")]
use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::ffi::OsString;
use std::fs::read_link;
use std::io::{self, Read};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::str::FromStr;

mod namespaces;
pub use namespaces::*;

mod task;
pub use task::*;

mod pagemap;
pub use pagemap::*;

#[cfg(test)]
mod tests;

bitflags! {
    /// The mode (read/write permissions) for an open file descriptor
    ///
    /// This is represented as `u16` since the values of these bits are
    /// [documented] to be within the `u16` range.
    ///
    /// [documented]: https://man7.org/linux/man-pages/man2/chmod.2.html#DESCRIPTION
    #[cfg_attr(feature = "serde1", derive(Serialize, Deserialize))]
    #[derive(Copy, Clone, Debug, Hash, Eq, PartialEq, PartialOrd, Ord)]
    pub struct FDPermissions: u16 {
        const READ = Mode::RUSR.bits() as u16;
        const WRITE = Mode::WUSR.bits() as u16;
        const EXECUTE = Mode::XUSR.bits() as u16;
    }
}

/// See the [Process::fd()] method
#[derive(Clone)]
#[cfg_attr(feature = "serde1", derive(Serialize, Deserialize))]
pub struct FDInfo {
    /// The file descriptor
    pub fd: i32,
    /// The permission bits for this FD
    ///
    /// **Note**: this field is only the owner read/write/execute bits.  All the other bits
    /// (include filetype bits) are masked out.  See also the `mode()` method.
    pub mode: u16,
    pub target: FDTarget,
}

impl FDInfo {
    /// Gets a file descriptor from a raw fd
    pub fn from_raw_fd(pid: i32, raw_fd: i32) -> ProcResult<Self> {
        Self::from_raw_fd_with_root("/proc", pid, raw_fd)
    }

    /// Gets a file descriptor from a raw fd based on a specified `/proc` path
    pub fn from_raw_fd_with_root(root: impl AsRef<Path>, pid: i32, raw_fd: i32) -> ProcResult<Self> {
        let path = root.as_ref().join(pid.to_string()).join("fd").join(raw_fd.to_string());
        let link = wrap_io_error!(path, read_link(&path))?;
        let md = wrap_io_error!(path, path.symlink_metadata())?;
        let link_os: &OsStr = link.as_ref();
        Ok(Self {
            fd: raw_fd,
            mode: ((md.mode() as RawMode) & Mode::RWXU.bits()) as u16,
            target: expect!(FDTarget::from_str(expect!(link_os.to_str()))),
        })
    }

    /// Gets a file descriptor from a directory fd and a path relative to it.
    ///
    /// `base` is the path to the directory fd, and is used for error messages.
    fn from_process_at<P: AsRef<Path>, Q: AsRef<Path>>(
        base: P,
        dirfd: BorrowedFd,
        path: Q,
        fd: i32,
    ) -> ProcResult<Self> {
        let p = path.as_ref();
        let root = base.as_ref().join(p);
        // for 2.6.39 <= kernel < 3.6 fstat doesn't support O_PATH see https://github.com/eminence/procfs/issues/265
        let flags = match Version::cached() {
            Ok(v) if v < KernelVersion::new(3, 6, 0) => OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Ok(_) => OFlags::NOFOLLOW | OFlags::PATH | OFlags::CLOEXEC,
            Err(_) => OFlags::NOFOLLOW | OFlags::PATH | OFlags::CLOEXEC,
        };
        let file = wrap_io_error!(root, rustix::fs::openat(dirfd, p, flags, Mode::empty()))?;
        let link = rustix::fs::readlinkat(&file, "", Vec::new()).map_err(io::Error::from)?;
        let md =
            rustix::fs::statat(&file, "", AtFlags::SYMLINK_NOFOLLOW | AtFlags::EMPTY_PATH).map_err(io::Error::from)?;

        let link_os = link.to_string_lossy();
        let target = FDTarget::from_str(link_os.as_ref())?;
        Ok(FDInfo {
            fd,
            mode: (md.st_mode & Mode::RWXU.bits()) as u16,
            target,
        })
    }

    /// Gets the read/write mode of this file descriptor as a bitfield
    pub fn mode(&self) -> FDPermissions {
        FDPermissions::from_bits_truncate(self.mode)
    }
}

impl std::fmt::Debug for FDInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "FDInfo {{ fd: {:?}, mode: 0{:o}, target: {:?} }}",
            &self.fd, self.mode, self.target
        )
    }
}

/// Represents a process in `/proc/<pid>`.
///
/// **Note** The `Process` struct holds an open file descriptor to its `/proc/<pid>` directory.
/// This makes it possible to construct a `Process` object and then later call the various methods
/// on it without a risk of inadvertently getting information from the wrong process (due to PID
/// reuse).
///
/// However the downside is that holding a lot of `Process` objects might cause the process to run
/// out of file descriptors.
///
/// For use cases that don't involve holding a lot of `Process` objects, no special handler is
/// needed.  But if you do hold a lot of these objects (for example if you're writing a `ps`
/// or `top` -like program), you'll likely want to gather all of the necessary info from `Process`
/// object into a new struct and then drop the `Process` object
///
#[derive(Debug)]
pub struct Process {
    fd: OwnedFd,
    pub pid: i32,
    pub(crate) root: PathBuf,
}

/// Methods for constructing a new `Process` object.
impl Process {
    /// Returns a `Process` based on a specified PID.
    ///
    /// This can fail if the process doesn't exist, or if you don't have permission to access it.
    pub fn new(pid: i32) -> ProcResult<Process> {
        let root = PathBuf::from("/proc").join(pid.to_string());
        Self::new_with_root(root)
    }

    /// Returns a `Process` based on a specified `/proc/<pid>` path.
    pub fn new_with_root(root: PathBuf) -> ProcResult<Process> {
        // for 2.6.39 <= kernel < 3.6 fstat doesn't support O_PATH see https://github.com/eminence/procfs/issues/265
        let flags = match Version::cached() {
            Ok(v) if v < KernelVersion::new(3, 6, 0) => OFlags::DIRECTORY | OFlags::CLOEXEC,
            Ok(_) => OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Err(_) => OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC,
        };
        let file = wrap_io_error!(root, rustix::fs::openat(rustix::fs::CWD, &root, flags, Mode::empty()))?;

        let pidres = root
            .as_path()
            .components()
            .last()
            .and_then(|c| match c {
                std::path::Component::Normal(s) => Some(s),
                _ => None,
            })
            .and_then(|s| s.to_string_lossy().parse::<i32>().ok())
            .or_else(|| {
                rustix::fs::readlinkat(rustix::fs::CWD, &root, Vec::new())
                    .ok()
                    .and_then(|s| s.to_string_lossy().parse::<i32>().ok())
            });
        let pid = match pidres {
            Some(pid) => pid,
            None => return Err(ProcError::NotFound(Some(root))),
        };

        Ok(Process { fd: file, pid, root })
    }

    /// Returns a `Process` for the currently running process.
    ///
    /// This is done by using the `/proc/self` symlink
    pub fn myself() -> ProcResult<Process> {
        let root = PathBuf::from("/proc/self");
        Self::new_with_root(root)
    }
}

impl Process {
    /// Returns the complete command line for the process, unless the process is a zombie.
    pub fn cmdline(&self) -> ProcResult<Vec<String>> {
        let mut buf = String::new();
        let mut f = FileWrapper::open_at(&self.root, &self.fd, "cmdline")?;
        f.read_to_string(&mut buf)?;
        Ok(buf
            .split('\0')
            .filter_map(|s| if !s.is_empty() { Some(s.to_string()) } else { None })
            .collect())
    }

    /// Returns the process ID for this process, if the process was created from an ID. Otherwise
    /// use stat().pid.
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Is this process still alive?
    ///
    /// Processes in the Zombie or Dead state are not considered alive.
    pub fn is_alive(&self) -> bool {
        if let Ok(stat) = self.stat() {
            stat.state != 'Z' && stat.state != 'X'
        } else {
            false
        }
    }

    /// What user owns this process?
    pub fn uid(&self) -> ProcResult<u32> {
        Ok(self.metadata()?.st_uid)
    }

    fn metadata(&self) -> ProcResult<rustix::fs::Stat> {
        Ok(rustix::fs::fstat(&self.fd).map_err(io::Error::from)?)
    }

    /// Retrieves current working directory of the process by dereferencing `/proc/<pid>/cwd` symbolic link.
    ///
    /// This method has the following caveats:
    ///
    /// * if the pathname has been unlinked, the symbolic link will contain the string " (deleted)"
    ///   appended to the original pathname
    ///
    /// * in a multithreaded process, the contents of this symbolic link are not available if the
    ///   main thread has already terminated (typically by calling `pthread_exit(3)`)
    ///
    /// * permission to dereference or read this symbolic link is governed by a
    ///   `ptrace(2)` access mode `PTRACE_MODE_READ_FSCREDS` check
    pub fn cwd(&self) -> ProcResult<PathBuf> {
        Ok(PathBuf::from(OsString::from_vec(
            wrap_io_error!(
                self.root.join("cwd"),
                rustix::fs::readlinkat(&self.fd, "cwd", Vec::new())
            )?
            .into_bytes(),
        )))
    }

    /// Retrieves current root directory of the process by dereferencing `/proc/<pid>/root` symbolic link.
    ///
    /// This method has the following caveats:
    ///
    /// * if the pathname has been unlinked, the symbolic link will contain the string " (deleted)"
    ///   appended to the original pathname
    ///
    /// * in a multithreaded process, the contents of this symbolic link are not available if the
    ///   main thread has already terminated (typically by calling `pthread_exit(3)`)
    ///
    /// * permission to dereference or read this symbolic link is governed by a
    ///   `ptrace(2)` access mode `PTRACE_MODE_READ_FSCREDS` check
    pub fn root(&self) -> ProcResult<PathBuf> {
        Ok(PathBuf::from(OsString::from_vec(
            wrap_io_error!(
                self.root.join("root"),
                rustix::fs::readlinkat(&self.fd, "root", Vec::new())
            )?
            .into_bytes(),
        )))
    }

    /// Gets the current environment for the process.  This is done by reading the
    /// `/proc/pid/environ` file.
    pub fn environ(&self) -> ProcResult<HashMap<OsString, OsString>> {
        use std::os::unix::ffi::OsStrExt;

        let mut map = HashMap::new();

        let mut file = FileWrapper::open_at(&self.root, &self.fd, "environ")?;
        let mut buf = Vec::new();
        file.read_to_end(&mut buf)?;

        for slice in buf.split(|b| *b == 0) {
            // slice will be in the form key=var, so split on the first equals sign
            let mut split = slice.splitn(2, |b| *b == b'=');
            if let (Some(k), Some(v)) = (split.next(), split.next()) {
                map.insert(OsStr::from_bytes(k).to_os_string(), OsStr::from_bytes(v).to_os_string());
            };
            //let env = OsStr::from_bytes(slice);
        }

        Ok(map)
    }

    /// Retrieves the actual path of the executed command by dereferencing `/proc/<pid>/exe` symbolic link.
    ///
    /// This method has the following caveats:
    ///
    /// * if the pathname has been unlinked, the symbolic link will contain the string " (deleted)"
    ///   appended to the original pathname
    ///
    /// * in a multithreaded process, the contents of this symbolic link are not available if the
    ///   main thread has already terminated (typically by calling `pthread_exit(3)`)
    ///
    /// * permission to dereference or read this symbolic link is governed by a
    ///   `ptrace(2)` access mode `PTRACE_MODE_READ_FSCREDS` check
    pub fn exe(&self) -> ProcResult<PathBuf> {
        Ok(PathBuf::from(OsString::from_vec(
            wrap_io_error!(
                self.root.join("exe"),
                rustix::fs::readlinkat(&self.fd, "exe", Vec::new())
            )?
            .into_bytes(),
        )))
    }

    /// Return the Io stats for this process, based on the `/proc/pid/io` file.
    ///
    /// (since kernel 2.6.20)
    pub fn io(&self) -> ProcResult<Io> {
        FromRead::from_read(FileWrapper::open_at(&self.root, &self.fd, "io")?)
    }

    /// Return a list of the currently mapped memory regions and their access permissions, based on
    /// the `/proc/pid/maps` file.
    pub fn maps(&self) -> ProcResult<MemoryMaps> {
        FromRead::from_read(FileWrapper::open_at(&self.root, &self.fd, "maps")?)
    }

    /// Returns a list of currently mapped memory regions and verbose information about them,
    /// such as memory consumption per mapping, based on the `/proc/pid/smaps` file.
    ///
    /// (since Linux 2.6.14 and requires CONFIG_PROG_PAGE_MONITOR)
    pub fn smaps(&self) -> ProcResult<MemoryMaps> {
        FromRead::from_read(FileWrapper::open_at(&self.root, &self.fd, "smaps")?)
    }

    /// This is the sum of all the smaps data but it is much more performant to get it this way.
    ///
    /// Since 4.14 and requires CONFIG_PROC_PAGE_MONITOR.
    pub fn smaps_rollup(&self) -> ProcResult<SmapsRollup> {
        FromRead::from_read(FileWrapper::open_at(&self.root, &self.fd, "smaps_rollup")?)
    }

    /// Returns the [MountStat] data for this process's mount namespace.
    pub fn mountstats(&self) -> ProcResult<MountStats> {
        self.read("mountstats")
    }

    /// Returns info about the mountpoints in this this process's mount namespace.
    ///
    /// This data is taken from the `/proc/[pid]/mountinfo` file
    ///
    /// # Example:
    ///
    /// ```
    /// # use procfs::process::Process;
    /// let stats = Process::myself().unwrap().mountstats().unwrap();
    ///
    /// for mount in stats {
    ///     println!("{} mounted on {} wth type {}",
    ///         mount.device.unwrap_or("??".to_owned()),
    ///         mount.mount_point.display(),
    ///         mount.fs
    ///     );
    /// }
    /// ```
    ///
    /// (Since Linux 2.6.26)
    pub fn mountinfo(&self) -> ProcResult<MountInfos> {
        self.read("mountinfo")
    }

    /// Gets the number of open file descriptors for a process
    ///
    /// Calling this function is more efficient than calling `fd().unwrap().count()`
    pub fn fd_count(&self) -> ProcResult<usize> {
        // Use fast path if available (Linux v6.2): https://github.com/torvalds/linux/commit/f1f1f2569901
        let stat = wrap_io_error!(
            self.root.join("fd"),
            rustix::fs::statat(&self.fd, "fd", AtFlags::empty())
        )?;
        if stat.st_size > 0 {
            return Ok(stat.st_size as usize);
        }

        let fds = wrap_io_error!(
            self.root.join("fd"),
            rustix::fs::openat(
                &self.fd,
                "fd",
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
                Mode::empty()
            )
        )?;
        let fds = wrap_io_error!(self.root.join("fd"), rustix::fs::Dir::read_from(fds))?;
        Ok(fds.count())
    }

    /// Gets a iterator of open file descriptors for a process
    pub fn fd(&self) -> ProcResult<FDsIter> {
        let dir_fd = wrap_io_error!(
            self.root.join("fd"),
            rustix::fs::openat(
                &self.fd,
                "fd",
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
                Mode::empty()
            )
        )?;
        let dir = wrap_io_error!(self.root.join("fd"), rustix::fs::Dir::read_from(&dir_fd))?;
        Ok(FDsIter {
            inner: dir,
            inner_fd: dir_fd,
            root: self.root.clone(),
        })
    }

    pub fn fd_from_fd(&self, fd: i32) -> ProcResult<FDInfo> {
        let path = PathBuf::from("fd").join(fd.to_string());
        FDInfo::from_process_at(&self.root, self.fd.as_fd(), path, fd)
    }

    /// Lists which memory segments are written to the core dump in the event that a core dump is performed.
    ///
    /// By default, the following bits are set:
    /// 0, 1, 4 (if the CONFIG_CORE_DUMP_DEFAULT_ELF_HEADERS kernel configuration option is enabled), and 5.
    /// This default can be modified at boot time using the core dump_filter boot option.
    ///
    /// This function will return `Err(ProcError::NotFound)` if the `coredump_filter` file can't be
    /// found.  If it returns `Ok(None)` then the process has no coredump_filter
    pub fn coredump_filter(&self) -> ProcResult<Option<CoredumpFlags>> {
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "coredump_filter")?;
        let mut s = String::new();
        file.read_to_string(&mut s)?;
        if s.trim().is_empty() {
            return Ok(None);
        }
        let flags = from_str!(u32, &s.trim(), 16, pid: self.pid);
        Ok(Some(expect!(CoredumpFlags::from_bits(flags))))
    }

    /// Gets the process's autogroup membership
    ///
    /// (since Linux 2.6.38 and requires CONFIG_SCHED_AUTOGROUP)
    pub fn autogroup(&self) -> ProcResult<String> {
        let mut s = String::new();
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "autogroup")?;
        file.read_to_string(&mut s)?;
        Ok(s)
    }

    /// Get the process's auxiliary vector
    ///
    /// (since 2.6.0-test7)
    pub fn auxv(&self) -> ProcResult<HashMap<u64, u64>> {
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "auxv")?;
        let mut map = HashMap::new();

        let mut buf = Vec::new();
        let bytes_read = file.read_to_end(&mut buf)?;
        if bytes_read == 0 {
            // some kernel processes won't have any data for their auxv file
            return Ok(map);
        }
        buf.truncate(bytes_read);
        let mut file = std::io::Cursor::new(buf);

        let mut buf = 0usize.to_ne_bytes();
        loop {
            file.read_exact(&mut buf)?;
            let key = usize::from_ne_bytes(buf) as u64;
            file.read_exact(&mut buf)?;
            let value = usize::from_ne_bytes(buf) as u64;
            if key == 0 && value == 0 {
                break;
            }
            map.insert(key, value);
        }

        Ok(map)
    }

    /// Gets the symbolic name corresponding to the location in the kernel where the process is sleeping.
    ///
    /// (since Linux 2.6.0)
    pub fn wchan(&self) -> ProcResult<String> {
        let mut s = String::new();
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "wchan")?;
        file.read_to_string(&mut s)?;
        Ok(s)
    }

    /// Return the `Status` for this process, based on the `/proc/[pid]/status` file.
    pub fn status(&self) -> ProcResult<Status> {
        self.read("status")
    }

    /// Returns the status info from `/proc/[pid]/stat`.
    pub fn stat(&self) -> ProcResult<Stat> {
        self.read("stat")
    }

    /// Return the limits for this process
    pub fn limits(&self) -> ProcResult<Limits> {
        self.read("limits")
    }

    /// Gets the process' login uid. May not be available.
    pub fn loginuid(&self) -> ProcResult<u32> {
        let mut uid = String::new();
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "loginuid")?;
        file.read_to_string(&mut uid)?;
        Status::parse_uid_gid(&uid, 0)
    }

    /// The current score that the kernel gives to this process for the purpose of selecting a
    /// process for the OOM-killer
    ///
    /// A higher score means that the process is more likely to be selected by the OOM-killer.
    /// The basis for this score is the amount of memory used by the process, plus other factors.
    ///
    /// Values range from 0 (never kill) to 1000 (always kill) inclusive.
    ///
    /// (Since linux 2.6.11)
    pub fn oom_score(&self) -> ProcResult<u16> {
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "oom_score")?;
        let mut oom = String::new();
        file.read_to_string(&mut oom)?;
        Ok(from_str!(u16, oom.trim()))
    }

    /// Adjust score value is added to the oom score before choosing processes to kill.
    ///
    /// Values range from -1000 (never kill) to 1000 (always kill) inclusive.
    pub fn oom_score_adj(&self) -> ProcResult<i16> {
        let mut file = FileWrapper::open_at(&self.root, &self.fd, "oom_score_adj")?;
        let mut oom = String::new();
        file.read_to_string(&mut oom)?;
        Ok(from_str!(i16, oom.trim()))
    }

    pub fn set_oom_score_adj(&self, new_oom_score_adj: i16) -> ProcResult<()> {
        let path = self.root.join("oom_score_adj");
        write_value(path, new_oom_score_adj)
    }

    /// Set process memory information
    ///
    /// Much of this data is the same as the data from `stat()` and `status()`
    pub fn statm(&self) -> ProcResult<StatM> {
        self.read("statm")
    }

    /// Return a task for the main thread of this process
    pub fn task_main_thread(&self) -> ProcResult<Task> {
        self.task_from_tid(self.pid)
    }

    /// Return a task for the thread based on a specified TID
    pub fn task_from_tid(&self, tid: i32) -> ProcResult<Task> {
        let path = PathBuf::from("task").join(tid.to_string());
        Task::from_process_at(&self.root, self.fd.as_fd(), path, self.pid, tid)
    }

    /// Return the `Schedstat` for this process, based on the `/proc/<pid>/schedstat` file.
    ///
    /// (Requires CONFIG_SCHED_INFO)
    pub fn schedstat(&self) -> ProcResult<Schedstat> {
        self.read("schedstat")
    }

    /// Iterate over all the [`Task`]s (aka Threads) in this process
    ///
    /// Note that the iterator does not receive a snapshot of tasks, it is a
    /// lazy iterator over whatever happens to be running when the iterator
    /// gets there, see the examples below.
    ///
    /// # Examples
    ///
    /// ## Simple iteration over subtasks
    ///
    /// If you want to get the info that most closely matches what was running
    /// when you call `tasks` you should collect them as quikcly as possible,
    /// and then run processing over that collection:
    ///
    /// ```
    /// # use std::thread;
    /// # use std::sync::mpsc::channel;
    /// # use procfs::process::Process;
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// # let (finish_tx, finish_rx) = channel();
    /// # let (start_tx, start_rx) = channel();
    /// let name = "testing:example";
    /// let t = thread::Builder::new().name(name.to_string())
    ///   .spawn(move || { // do work
    /// #     start_tx.send(()).unwrap();
    /// #     finish_rx.recv().expect("valid channel");
    ///   })?;
    /// # start_rx.recv()?;
    ///
    /// let proc = Process::myself()?;
    ///
    /// // Collect a snapshot
    /// let threads: Vec<_> = proc.tasks()?.flatten().map(|t| t.stat().unwrap().comm).collect();
    /// threads.iter().find(|s| &**s == name).expect("thread should exist");
    ///
    /// # finish_tx.send(());
    /// # t.join().unwrap();
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// ## The TaskIterator is lazy
    ///
    /// This means both that tasks that stop before you get to them in
    /// iteration will not be there, and that new tasks that are created after
    /// you start the iterator *will* appear.
    ///
    /// ```
    /// # use std::thread;
    /// # use std::sync::mpsc::channel;
    /// # use procfs::process::Process;
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let proc = Process::myself()?;
    ///
    /// // Task iteration is lazy
    /// let mut task_iter = proc.tasks()?.flatten().map(|t| t.stat().unwrap().comm);
    ///
    /// # let (finish_tx, finish_rx) = channel();
    /// # let (start_tx, start_rx) = channel();
    /// let name = "testing:lazy";
    /// let t = thread::Builder::new().name(name.to_string())
    ///   .spawn(move || { // do work
    /// #     start_tx.send(()).unwrap();
    /// #     finish_rx.recv().expect("valid channel");
    ///   })?;
    /// # start_rx.recv()?;
    ///
    /// task_iter.find(|s| &**s == name).expect("thread should exist");
    ///
    /// # finish_tx.send(());
    /// # t.join().unwrap();
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// Tasks that stop while you're iterating may or may not appear:
    ///
    /// ```
    /// # use std::thread;
    /// # use std::sync::mpsc::channel;
    /// # use procfs::process::Process;
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// # let (finish_tx, finish_rx) = channel();
    /// # let (start_tx, start_rx) = channel();
    /// let name = "testing:stopped";
    /// let t = thread::Builder::new().name(name.to_string())
    ///   .spawn(move || { // do work
    /// #     start_tx.send(()).unwrap();
    /// #     finish_rx.recv().expect("valid channel");
    ///   })?;
    /// # start_rx.recv()?;
    ///
    /// let proc = Process::myself()?;
    ///
    /// // Task iteration is lazy
    /// let mut task_iter = proc.tasks()?.flatten().map(|t| t.stat().unwrap().comm);
    ///
    /// # finish_tx.send(());
    /// t.join().unwrap();
    ///
    /// // It's impossible to know if this is going to be gone
    /// let _ = task_iter.find(|s| &**s == name).is_some();
    /// # Ok(())
    /// # }
    /// ```
    pub fn tasks(&self) -> ProcResult<TasksIter> {
        let task_path = self.root.join("task");
        let dir_fd = wrap_io_error!(
            &task_path,
            rustix::fs::openat(
                &self.fd,
                "task",
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
                Mode::empty()
            )
        )?;
        let dir = wrap_io_error!(&task_path, rustix::fs::Dir::read_from(&dir_fd))?;
        Ok(TasksIter {
            pid: self.pid,
            inner: dir,
            inner_fd: dir_fd,
            root: task_path,
        })
    }

    /// Reads the tcp socket table from the process net namespace
    pub fn tcp(&self) -> ProcResult<Vec<TcpNetEntry>> {
        self.read_si("net/tcp").map(|net::TcpNetEntries(e)| e)
    }

    /// Reads the tcp6 socket table from the process net namespace
    pub fn tcp6(&self) -> ProcResult<Vec<TcpNetEntry>> {
        self.read_si("net/tcp6").map(|net::TcpNetEntries(e)| e)
    }

    /// Reads the udp socket table from the process net namespace
    pub fn udp(&self) -> ProcResult<Vec<UdpNetEntry>> {
        self.read_si("net/udp").map(|net::UdpNetEntries(e)| e)
    }

    /// Reads the udp6 socket table from the process net namespace
    pub fn udp6(&self) -> ProcResult<Vec<UdpNetEntry>> {
        self.read_si("net/udp6").map(|net::UdpNetEntries(e)| e)
    }

    /// Returns basic network device statistics for all interfaces in the process net namespace
    ///
    /// See also the [dev_status()](crate::net::dev_status()) function.
    pub fn dev_status(&self) -> ProcResult<HashMap<String, net::DeviceStatus>> {
        self.read("net/dev").map(|net::InterfaceDeviceStatus(e)| e)
    }

    /// Reads the unix socket table
    pub fn unix(&self) -> ProcResult<Vec<net::UnixNetEntry>> {
        self.read("net/unix").map(|net::UnixNetEntries(e)| e)
    }

    /// Reads the ARP table from the process net namespace
    pub fn arp(&self) -> ProcResult<Vec<net::ARPEntry>> {
        self.read("net/arp").map(|net::ArpEntries(e)| e)
    }

    /// Reads the ipv4 route table from the process net namespace
    pub fn route(&self) -> ProcResult<Vec<net::RouteEntry>> {
        self.read("net/route").map(|net::RouteEntries(e)| e)
    }

    /// Reads the network management information by Simple Network Management Protocol from the
    /// process net namespace
    pub fn snmp(&self) -> ProcResult<net::Snmp> {
        self.read("net/snmp")
    }

    /// Reads the network management information of IPv6 by Simple Network Management Protocol from
    /// the process net namespace
    pub fn snmp6(&self) -> ProcResult<net::Snmp6> {
        self.read("net/snmp6")
    }

    /// Opens a file to the process's memory (`/proc/<pid>/mem`).
    ///
    /// Note: you cannot start reading from the start of the file.  You must first seek to
    /// a mapped page.  See [Process::maps].
    ///
    /// Permission to access this file is governed by a ptrace access mode PTRACE_MODE_ATTACH_FSCREDS check
    ///
    /// # Example
    ///
    /// Find the offset of the "hello" string in the process's stack, and compare it to the
    /// pointer of the variable containing "hello"
    ///
    /// ```rust
    /// # use std::io::{Read, Seek, SeekFrom};
    /// # use procfs::process::{MMapPath, Process};
    /// let me = Process::myself().unwrap();
    /// let mut mem = me.mem().unwrap();
    /// let maps = me.maps().unwrap();
    ///
    /// let hello = "hello".to_string();
    ///
    /// for map in maps {
    ///     if map.pathname == MMapPath::Heap {
    ///         mem.seek(SeekFrom::Start(map.address.0)).unwrap();
    ///         let mut buf = vec![0; (map.address.1 - map.address.0) as usize];
    ///         mem.read_exact(&mut buf).unwrap();
    ///         let idx = buf.windows(5).position(|p| p == b"hello").unwrap();
    ///         assert_eq!(map.address.0 + idx as u64, hello.as_ptr() as u64);
    ///     }
    /// }
    /// ```
    pub fn mem(&self) -> ProcResult<File> {
        let file = FileWrapper::open_at(&self.root, &self.fd, "mem")?;
        Ok(file.inner())
    }

    /// Returns a file which is part of the process proc structure
    pub fn open_relative(&self, path: &str) -> ProcResult<File> {
        let file = FileWrapper::open_at(&self.root, &self.fd, path)?;
        Ok(file.inner())
    }

    /// Parse a file relative to the process proc structure.
    pub fn read<T: FromRead>(&self, path: &str) -> ProcResult<T> {
        FromRead::from_read(FileWrapper::open_at(&self.root, &self.fd, path)?)
    }

    /// Parse a file relative to the process proc structure.
    pub fn read_si<T: FromReadSI>(&self, path: &str) -> ProcResult<T> {
        FromReadSI::from_read(
            FileWrapper::open_at(&self.root, &self.fd, path)?,
            crate::current_system_info(),
        )
    }

    /// Clear reference bits
    ///
    /// See [ClearRefs] and [Process::pagemap()]
    pub fn clear_refs(&self, clear: ClearRefs) -> ProcResult<()> {
        write_value(self.root.join("clear_refs"), clear)
    }
}

/// The result of [`Process::fd`], iterates over all fds in a process
#[derive(Debug)]
pub struct FDsIter {
    inner: rustix::fs::Dir,
    inner_fd: rustix::fd::OwnedFd,
    root: PathBuf,
}

impl std::iter::Iterator for FDsIter {
    type Item = ProcResult<FDInfo>;
    fn next(&mut self) -> Option<ProcResult<FDInfo>> {
        loop {
            match self.inner.next() {
                Some(Ok(entry)) => {
                    let name = entry.file_name().to_string_lossy();
                    if let Ok(fd) = RawFd::from_str(&name) {
                        if let Ok(info) = FDInfo::from_process_at(&self.root, self.inner_fd.as_fd(), name.as_ref(), fd)
                        {
                            break Some(Ok(info));
                        }
                    }
                }
                Some(Err(e)) => break Some(Err(io::Error::from(e).into())),
                None => break None,
            }
        }
    }
}

/// The result of [`Process::tasks`], iterates over all tasks in a process
#[derive(Debug)]
pub struct TasksIter {
    pid: i32,
    inner: rustix::fs::Dir,
    inner_fd: rustix::fd::OwnedFd,
    root: PathBuf,
}

impl std::iter::Iterator for TasksIter {
    type Item = ProcResult<Task>;
    fn next(&mut self) -> Option<ProcResult<Task>> {
        loop {
            match self.inner.next() {
                Some(Ok(tp)) => {
                    if let Ok(tid) = i32::from_str(&tp.file_name().to_string_lossy()) {
                        if let Ok(task) =
                            Task::from_process_at(&self.root, self.inner_fd.as_fd(), tid.to_string(), self.pid, tid)
                        {
                            break Some(Ok(task));
                        }
                    }
                }
                Some(Err(e)) => break Some(Err(io::Error::from(e).into())),
                None => break None,
            }
        }
    }
}

/// Return a iterator of all processes
///
/// If a process can't be constructed for some reason, it will be returned as an `Err(ProcError)`
///
/// See also some important docs on the [ProcessesIter] struct.
///
/// Error handling example
/// ```
/// # use procfs::process::Process;
/// let all_processes: Vec<Process> = procfs::process::all_processes()
/// .expect("Can't read /proc")
/// .filter_map(|p| match p {
///     Ok(p) => Some(p),                                                // happy path
///     Err(e) => match e {
///         procfs::ProcError::NotFound(_) => None,                      // process vanished during iteration, ignore it
///         procfs::ProcError::Io(e, path) => None,                      // can match on path to decide if we can continue
///         x => {
///             println!("Can't read process due to error {x:?}"); // some unknown error
///             None
///         }
///     },
/// })
/// .collect();
/// ```
pub fn all_processes() -> ProcResult<ProcessesIter> {
    all_processes_with_root("/proc")
}

/// Return a list of all processes based on a specified `/proc` path
///
/// See [all_processes] for details and examples
///
/// See also some important docs on the [ProcessesIter] struct.
pub fn all_processes_with_root(root: impl AsRef<Path>) -> ProcResult<ProcessesIter> {
    let root = root.as_ref();
    let dir = wrap_io_error!(
        root,
        rustix::fs::openat(
            rustix::fs::CWD,
            root,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty()
        )
    )?;
    let dir = wrap_io_error!(root, rustix::fs::Dir::read_from(dir))?;
    Ok(ProcessesIter {
        root: PathBuf::from(root),
        inner: dir,
    })
}

/// An iterator over all processes in the system.
///
/// **Note** This is a *lazy* iterator (like most iterators in rust).  You will likely want to consume
/// this iterator as quickly as possible if you want a "snapshot" of the system (though it won't be a
/// true snapshot).  Another important thing to keep in mind is that the [`Process`] struct holds an
/// open file descriptor to its corresponding `/proc/<pid>` directory.  See the docs for [`Process`]
/// for more information.
#[derive(Debug)]
pub struct ProcessesIter {
    root: PathBuf,
    inner: rustix::fs::Dir,
}

impl std::iter::Iterator for ProcessesIter {
    type Item = ProcResult<Process>;
    fn next(&mut self) -> Option<ProcResult<Process>> {
        loop {
            match self.inner.next() {
                Some(Ok(entry)) => {
                    if let Ok(pid) = i32::from_str(&entry.file_name().to_string_lossy()) {
                        break Some(Process::new_with_root(self.root.join(pid.to_string())));
                    }
                }
                Some(Err(e)) => break Some(Err(io::Error::from(e).into())),
                None => break None,
            }
        }
    }
}
