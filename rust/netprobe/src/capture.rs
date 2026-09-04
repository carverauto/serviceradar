//! Capture descriptors, opened while privileged and used long afterwards.
//!
//! This module used to open libpcap handles and was dead in every build: the
//! `pcap` dependency sat behind a cargo feature no platform enables, so the
//! only reachable path was a `bail!` saying the backend was not compiled in.
//! It is now the pre-open stage of remote packet capture.
//!
//! # Why descriptors are opened here rather than when a session starts
//!
//! netprobe starts as root for the eBPF setup phase and then drops to the
//! `serviceradar` account (`--drop-user`, see the systemd unit). The drop is a
//! plain `setgid`/`setuid` with no `PR_SET_KEEPCAPS`, and a UID transition off
//! root clears the permitted and effective sets — which clears ambient too.
//! Measured on a real host under the unit's own capability properties:
//! afterwards `CapPrm`, `CapEff` and `CapAmb` are all zero and
//! `socket(AF_PACKET, ...)` returns `EPERM`.
//!
//! A capture session begins later, over IPC, long after that drop. So the
//! privileged step has to happen up front: [`CaptureHandles::open`] runs during
//! the privileged phase and opens one socket per allowlisted interface.
//! Everything a session needs after that — attaching a filter, arming the ring,
//! mapping it, binding, reading statistics — was measured to work with no
//! capabilities at all.
//!
//! This is a better posture than keeping `CAP_NET_RAW`: netprobe ends up
//! holding no capabilities and only descriptors for interfaces an operator
//! already allowlisted, so a compromise after the drop cannot open a capture
//! socket for anything else.

use anyhow::{Context, Result};
use serviceradar_afpacket::Socket;
use thiserror::Error;

use crate::config::Config;

/// Classic BPF encoding shared by both capture filter front doors.
pub mod bpf;
/// A crafted packet corpus that makes filter-compiler mistakes observable.
#[cfg(test)]
pub mod corpus;
/// Differential test of our compiler against libpcap (task 1.11).
#[cfg(test)]
mod differential;
/// tcpdump-subset expression compiler producing classic BPF.
pub mod filter;
/// A classic BPF interpreter, used to compare programs over crafted packets.
#[cfg(test)]
pub mod interp;
/// pcapng encoding for a capture session's output stream.
pub mod pcapng;
/// Validating a wire `StartRemoteCapture` before anything is opened.
pub mod request;
/// The loop that turns a ring into a pcapng stream.
pub mod runner;
/// Session lifecycle: concurrency, descriptors, and the host-local record.
pub mod service;
/// One capture session: caps, counters and the terminal block.
pub mod session;

/// Why a session could not obtain a capture descriptor.
///
/// Distinguishable variants matter here: the kernel reports most of these as a
/// bare `EPERM` or `EINVAL`, which tells an operator nothing about whether the
/// fix is a config change, a restart, or a deployment problem.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum CaptureError {
    /// The interface is not on the operator's allowlist.
    #[error("interface {0} is not in capture_interfaces")]
    NotAllowlisted(String),

    /// Allowlisted, but no descriptor was opened for it — so the allowlist
    /// changed on disk and netprobe has not restarted since.
    #[error(
        "no capture descriptor was pre-opened for {0}; it is allowlisted now but was not when netprobe started and dropped privileges, so capture on it requires a netprobe restart"
    )]
    NotPreOpened(String),

    /// A session is already running. The v1 contract is one at a time.
    #[error("a capture session is already active on {0}")]
    AlreadyInUse(String),
}

/// How a capture descriptor is obtained. A trait so tests can substitute a
/// fake without a privileged socket, as the previous libpcap opener did.
pub trait CaptureOpener {
    type Handle;

    fn open(&self, interface: &str) -> Result<Self::Handle>;
}

/// Opens real `AF_PACKET` sockets. Requires `CAP_NET_RAW`, so it only works
/// during the privileged phase.
pub struct AfPacketOpener;

impl CaptureOpener for AfPacketOpener {
    type Handle = Socket;

    fn open(&self, interface: &str) -> Result<Self::Handle> {
        Ok(Socket::open(interface)?)
    }
}

pub struct CaptureHandles<H = Socket> {
    handles: Vec<CaptureHandle<H>>,
    /// The allowlist as it stood at pre-open time, so [`CaptureHandles::take`]
    /// can tell "never allowlisted" from "allowlisted after we started".
    allowlist: Vec<String>,
}

pub struct CaptureHandle<H = Socket> {
    interface: String,
    /// `None` once a session has taken it. The descriptor returns here when
    /// the session ends.
    handle: Option<H>,
}

impl CaptureHandles {
    /// Open one descriptor per allowlisted interface. **Privileged.**
    pub fn open(config: &Config) -> Result<Self> {
        open_allowlisted_interfaces(config, &AfPacketOpener)
    }
}

impl<H> CaptureHandles<H> {
    pub fn len(&self) -> usize {
        self.handles.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.handles.is_empty()
    }

    /// The allowlist as it stood at pre-open time.
    ///
    /// Read by the capture service so a request is validated against what was
    /// actually opened, not against a config that may have been edited since --
    /// which is the distinction `NotPreOpened` exists to report.
    pub fn allowlist(&self) -> &[String] {
        &self.allowlist
    }

    #[allow(dead_code)]
    pub fn interfaces(&self) -> impl Iterator<Item = &str> {
        self.handles.iter().map(|handle| handle.interface.as_str())
    }

    /// Take the descriptor for `interface`, for the duration of one session.
    ///
    /// The three outcomes are deliberately distinct because the operator action
    /// differs for each, and the kernel would report the first two identically:
    /// a config fix, a netprobe restart, or waiting for the running session.
    #[allow(dead_code)]
    pub fn take(&mut self, interface: &str) -> std::result::Result<H, CaptureError> {
        if !self.allowlist.iter().any(|name| name == interface) {
            return Err(CaptureError::NotAllowlisted(interface.to_string()));
        }

        let slot = self
            .handles
            .iter_mut()
            .find(|handle| handle.interface == interface)
            .ok_or_else(|| CaptureError::NotPreOpened(interface.to_string()))?;

        slot.handle
            .take()
            .ok_or_else(|| CaptureError::AlreadyInUse(interface.to_string()))
    }

    /// Return a descriptor when a session ends, so the interface can be
    /// captured again without a restart.
    #[allow(dead_code)]
    pub fn restore(&mut self, interface: &str, handle: H) {
        if let Some(slot) = self
            .handles
            .iter_mut()
            .find(|entry| entry.interface == interface)
        {
            slot.handle = Some(handle);
        }
    }
}

/// Validate the allowlist and open a descriptor for each entry.
///
/// Both validations are needed and they are not the same check.
/// `validate_capture_interfaces` only rejects empty names, `any` and
/// wildcards; `validate_interface` is the one that consults the allowlist.
/// Calling only the first looks like allowlist enforcement and enforces
/// nothing.
pub fn open_allowlisted_interfaces<O>(
    config: &Config,
    opener: &O,
) -> Result<CaptureHandles<O::Handle>>
where
    O: CaptureOpener,
{
    config.validate_capture_interfaces()?;

    let mut handles = Vec::with_capacity(config.capture_interfaces.len());
    for interface in &config.capture_interfaces {
        config.validate_interface(interface)?;
        let handle = opener
            .open(interface)
            .with_context(|| format!("failed to open capture interface {interface}"))?;
        handles.push(CaptureHandle {
            interface: interface.clone(),
            handle: Some(handle),
        });
    }

    Ok(CaptureHandles {
        handles,
        allowlist: config.capture_interfaces.clone(),
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use anyhow::Result;

    use super::{CaptureError, CaptureOpener, open_allowlisted_interfaces};
    use crate::config::Config;

    /// A stand-in for the real `Socket`, carrying the interface it was opened
    /// for so a test can prove the descriptor it got back is the one it
    /// expected -- not merely that some descriptor came back.
    #[derive(Debug, PartialEq, Eq)]
    struct FakeHandle(String);

    #[derive(Default)]
    struct FakeOpener {
        opened: Mutex<Vec<String>>,
    }

    impl CaptureOpener for FakeOpener {
        type Handle = FakeHandle;

        fn open(&self, interface: &str) -> Result<Self::Handle> {
            self.opened.lock().unwrap().push(interface.to_string());
            Ok(FakeHandle(interface.to_string()))
        }
    }

    fn config_with(interfaces: &[&str]) -> Config {
        Config {
            enabled: true,
            capture_interfaces: interfaces.iter().map(|s| (*s).to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn empty_allowlist_opens_no_handles() {
        let opener = FakeOpener::default();
        let handles = open_allowlisted_interfaces(&config_with(&[]), &opener).unwrap();

        assert_eq!(handles.len(), 0);
        assert!(opener.opened.lock().unwrap().is_empty());
    }

    #[test]
    fn opens_each_allowlisted_interface() {
        let opener = FakeOpener::default();
        let handles =
            open_allowlisted_interfaces(&config_with(&["eth0", "eth1"]), &opener).unwrap();

        assert_eq!(handles.len(), 2);
        assert_eq!(
            *opener.opened.lock().unwrap(),
            vec!["eth0".to_string(), "eth1".to_string()]
        );
    }

    #[test]
    fn invalid_allowlist_opens_no_handles() {
        let opener = FakeOpener::default();
        assert!(open_allowlisted_interfaces(&config_with(&["any"]), &opener).is_err());
        assert!(opener.opened.lock().unwrap().is_empty());
    }

    #[test]
    fn a_session_takes_a_descriptor_and_returns_it() {
        let opener = FakeOpener::default();
        let mut handles = open_allowlisted_interfaces(&config_with(&["eth0"]), &opener).unwrap();

        let descriptor = handles.take("eth0").expect("first take succeeds");
        assert_eq!(descriptor, FakeHandle("eth0".to_string()));

        // The v1 contract is one session per instance; a second take must be
        // refused with a reason, not a generic failure.
        assert_eq!(
            handles.take("eth0"),
            Err(CaptureError::AlreadyInUse("eth0".to_string()))
        );

        handles.restore("eth0", descriptor);
        assert!(
            handles.take("eth0").is_ok(),
            "a returned descriptor must be reusable without a restart"
        );
    }

    #[test]
    fn an_interface_that_was_never_allowlisted_is_distinguished_from_one_added_later() {
        // These are different operator actions -- fix the config, versus restart
        // netprobe -- and the kernel reports both as a bare EPERM.
        let opener = FakeOpener::default();
        let mut handles = open_allowlisted_interfaces(&config_with(&["eth0"]), &opener).unwrap();

        assert_eq!(
            handles.take("eth1"),
            Err(CaptureError::NotAllowlisted("eth1".to_string())),
            "an interface absent from capture_interfaces is a config problem"
        );

        // Now simulate the allowlist gaining an interface after the pre-open:
        // allowlisted, but no descriptor exists for it.
        handles.allowlist.push("eth2".to_string());
        assert_eq!(
            handles.take("eth2"),
            Err(CaptureError::NotPreOpened("eth2".to_string())),
            "an interface allowlisted after startup needs a restart, not a config fix"
        );
    }
}
