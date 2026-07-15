// Don't throw clippy warnings for manual string stripping.
// The suggested fix with `strip_prefix` removes support for Rust 1.33 and 1.38
#![allow(clippy::manual_strip)]

//! Information about the networking layer.
//!
//! This module corresponds to the `/proc/net` directory and contains various information about the
//! networking layer.
//!
//! # Example
//!
//! Here's an example that will print out all of the open and listening TCP sockets, and their
//! corresponding processes, if know.  This mimics the "netstat" utility, but for TCP only.  You
//! can run this example yourself with:
//!
//! > cargo run --example=netstat
//!
//! ```rust
//! # use procfs::process::{FDTarget, Stat};
//! # use std::collections::HashMap;
//! let all_procs = procfs::process::all_processes().unwrap();
//!
//! // build up a map between socket inodes and process stat info:
//! let mut map: HashMap<u64, Stat> = HashMap::new();
//! for p in all_procs {
//!     let Ok(process) = p else {
//!         // process vanished
//!         continue;
//!     };
//!     if let (Ok(stat), Ok(fds)) = (process.stat(), process.fd()) {
//!         for fd in fds {
//!             if let FDTarget::Socket(inode) = fd.unwrap().target {
//!                 map.insert(inode, stat.clone());
//!             }
//!         }
//!     }
//! }
//!
//! // get the tcp table
//! let tcp = procfs::net::tcp().unwrap();
//! let tcp6 = procfs::net::tcp6().unwrap();
//! println!("{:<26} {:<26} {:<15} {:<8} {}", "Local address", "Remote address", "State", "Inode", "PID/Program name");
//! for entry in tcp.into_iter().chain(tcp6) {
//!     // find the process (if any) that has an open FD to this entry's inode
//!     let local_address = format!("{}", entry.local_address);
//!     let remote_addr = format!("{}", entry.remote_address);
//!     let state = format!("{:?}", entry.state);
//!     if let Some(stat) = map.get(&entry.inode) {
//!         println!("{:<26} {:<26} {:<15} {:<12} {}/{}", local_address, remote_addr, state, entry.inode, stat.pid, stat.comm);
//!     } else {
//!         // We might not always be able to find the process associated with this socket
//!         println!("{:<26} {:<26} {:<15} {:<12} -", local_address, remote_addr, state, entry.inode);
//!     }
//! }
//! ```
use crate::ProcResult;
use crate::{current_system_info, Current};
pub use procfs_core::net::*;
use procfs_core::FromReadSI;
use std::collections::HashMap;

/// Reads the tcp socket table
///
/// Note that this is the socket table for the current process.  If you want to
/// see the socket table for another process, then see [Process::tcp()](crate::process::Process::tcp())
pub fn tcp() -> ProcResult<Vec<TcpNetEntry>> {
    TcpNetEntries::from_file("/proc/net/tcp", current_system_info()).map(|e| e.0)
}

/// Reads the tcp6 socket table
///
/// Note that this is the socket table for the current process.  If you want to
/// see the socket table for another process, then see [Process::tcp6()](crate::process::Process::tcp6())
pub fn tcp6() -> ProcResult<Vec<TcpNetEntry>> {
    TcpNetEntries::from_file("/proc/net/tcp6", current_system_info()).map(|e| e.0)
}

/// Reads the udp socket table
///
/// Note that this is the socket table for the current process.  If you want to
/// see the socket table for another process, then see [Process::udp()](crate::process::Process::udp())
pub fn udp() -> ProcResult<Vec<UdpNetEntry>> {
    UdpNetEntries::from_file("/proc/net/udp", current_system_info()).map(|e| e.0)
}

/// Reads the udp6 socket table
///
/// Note that this is the socket table for the current process.  If you want to
/// see the socket table for another process, then see [Process::udp6()](crate::process::Process::udp6())
pub fn udp6() -> ProcResult<Vec<UdpNetEntry>> {
    UdpNetEntries::from_file("/proc/net/udp6", current_system_info()).map(|e| e.0)
}

impl Current for UnixNetEntries {
    const PATH: &'static str = "/proc/net/unix";
}

/// Reads the unix socket table
///
/// Note that this is the socket table for the current process.  If you want to
/// see the socket table for another process, then see [Process::unix()](crate::process::Process::unix())
pub fn unix() -> ProcResult<Vec<UnixNetEntry>> {
    UnixNetEntries::current().map(|e| e.0)
}

impl super::Current for ArpEntries {
    const PATH: &'static str = "/proc/net/arp";
}

/// Reads the ARP table
///
/// Note that this is the ARP table for the current progress.  If you want to
/// see the ARP table for another process, then see [Process::arp()](crate::process::Process::arp())
pub fn arp() -> ProcResult<Vec<ARPEntry>> {
    ArpEntries::current().map(|e| e.0)
}

impl super::Current for InterfaceDeviceStatus {
    const PATH: &'static str = "/proc/net/dev";
}

/// Returns basic network device statistics for all interfaces
///
/// This data is from the `/proc/net/dev` file.
///
/// For an example, see the [interface_stats.rs](https://github.com/eminence/procfs/tree/master/examples)
/// example in the source repo.
///
/// Note that this returns information from the networking namespace of the
/// current process.  If you want information for some otherr process, see
/// [Process::dev_status()](crate::process::Process::dev_status())
pub fn dev_status() -> ProcResult<HashMap<String, DeviceStatus>> {
    InterfaceDeviceStatus::current().map(|e| e.0)
}

impl super::Current for RouteEntries {
    const PATH: &'static str = "/proc/net/route";
}

/// Reads the ipv4 route table
///
/// This data is from the `/proc/net/route` file
///
/// Note that this returns information from the networking namespace of the
/// current process.  If you want information for some other process, see
/// [Process::route()](crate::process::Process::route())
pub fn route() -> ProcResult<Vec<RouteEntry>> {
    RouteEntries::current().map(|r| r.0)
}

impl super::Current for Snmp {
    const PATH: &'static str = "/proc/net/snmp";
}

/// Reads the network management information by Simple Network Management Protocol
///
/// This data is from the `/proc/net/snmp` file and for IPv4 Protocol
///
/// Note that this returns information from the networking namespace of the
/// current process.  If you want information for some other process, see
/// [Process::snmp()](crate::process::Process::snmp())
pub fn snmp() -> ProcResult<Snmp> {
    Snmp::current()
}

impl super::Current for Snmp6 {
    const PATH: &'static str = "/proc/net/snmp6";
}

/// Reads the network management information of IPv6 by Simple Network Management Protocol
///
/// This data is from the `/proc/net/snmp6` file and for IPv6 Protocol
///
/// Note that this returns information from the networking namespace of the
/// current process.  If you want information for some other process, see
/// [Process::snmp6()](crate::process::Process::snmp6())
pub fn snmp6() -> ProcResult<Snmp6> {
    Snmp6::current()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tcp() {
        for entry in tcp().unwrap() {
            println!("{:?}", entry);
            assert_eq!(entry.state, TcpState::from_u8(entry.state.to_u8()).unwrap());
        }
    }

    #[test]
    fn test_tcp6() {
        for entry in tcp6().unwrap() {
            println!("{:?}", entry);
            assert_eq!(entry.state, TcpState::from_u8(entry.state.to_u8()).unwrap());
        }
    }

    #[test]
    fn test_udp() {
        for entry in udp().unwrap() {
            println!("{:?}", entry);
            assert_eq!(entry.state, UdpState::from_u8(entry.state.to_u8()).unwrap());
        }
    }

    #[test]
    fn test_udp6() {
        for entry in udp6().unwrap() {
            println!("{:?}", entry);
        }
    }

    #[test]
    fn test_unix() {
        for entry in unix().unwrap() {
            println!("{:?}", entry);
        }
    }

    #[test]
    fn test_dev_status() {
        let status = dev_status().unwrap();
        println!("{:#?}", status);
    }

    #[test]
    fn test_arp() {
        for entry in arp().unwrap() {
            println!("{:?}", entry);
        }
    }

    #[test]
    fn test_route() {
        for entry in route().unwrap() {
            println!("{:?}", entry);
        }
    }

    #[test]
    fn test_snmp() {
        let snmp = snmp().unwrap();
        println!("{:?}", snmp);
    }

    #[test]
    fn test_snmp6() {
        let snmp6 = snmp6().unwrap();
        println!("{:?}", snmp6);
    }
}
