use super::process::Process;
use crate::{Current, ProcResult};
use procfs_core::CGroupControllers;
pub use procfs_core::ProcessCGroups;

impl Current for CGroupControllers {
    const PATH: &'static str = "/proc/cgroups";
}

/// Information about the cgroup controllers that are compiled into the kernel
///
/// (since Linux 2.6.24)
pub fn cgroups() -> ProcResult<CGroupControllers> {
    CGroupControllers::current()
}

impl Process {
    /// Describes control groups to which the process with the corresponding PID belongs.
    ///
    /// The displayed information differs for cgroupsversion 1 and version 2 hierarchies.
    pub fn cgroups(&self) -> ProcResult<ProcessCGroups> {
        self.read("cgroup")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cgroups() {
        let groups = cgroups().unwrap();
        println!("{:?}", groups);
    }

    #[test]
    fn test_process_cgroups() {
        let myself = Process::myself().unwrap();
        let groups = myself.cgroups();
        println!("{:?}", groups);
    }
}
