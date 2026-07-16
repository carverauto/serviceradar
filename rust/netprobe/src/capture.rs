use anyhow::{Context, Result};

use crate::config::Config;

#[cfg(feature = "remote-capture")]
const HEADER_FINGERPRINT_SNAPLEN: i32 = 512;

#[cfg(feature = "remote-capture")]
pub type CaptureBackendHandle = pcap::Capture<pcap::Active>;

#[cfg(not(feature = "remote-capture"))]
pub struct CaptureBackendHandle;

pub struct CaptureHandles<H = CaptureBackendHandle> {
    handles: Vec<CaptureHandle<H>>,
}

pub struct CaptureHandle<H = CaptureBackendHandle> {
    interface: String,
    #[allow(dead_code)]
    handle: H,
}

pub trait CaptureOpener {
    type Handle;

    fn open(&self, interface: &str) -> Result<Self::Handle>;
}

pub struct PcapCaptureOpener;

impl CaptureHandles {
    pub fn open(config: &Config) -> Result<Self> {
        open_allowlisted_interfaces(config, &PcapCaptureOpener)
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

    #[allow(dead_code)]
    pub fn interfaces(&self) -> impl Iterator<Item = &str> {
        self.handles.iter().map(|handle| handle.interface.as_str())
    }

    #[allow(dead_code)]
    fn into_handles(self) -> Vec<CaptureHandle<H>> {
        self.handles
    }
}

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
            handle,
        });
    }

    Ok(CaptureHandles { handles })
}

impl CaptureOpener for PcapCaptureOpener {
    type Handle = CaptureBackendHandle;

    #[cfg(feature = "remote-capture")]
    fn open(&self, interface: &str) -> Result<Self::Handle> {
        let capture = pcap::Capture::from_device(interface)?
            .promisc(false)
            .snaplen(HEADER_FINGERPRINT_SNAPLEN)
            .timeout(1_000)
            .open()?;

        Ok(capture)
    }

    #[cfg(not(feature = "remote-capture"))]
    fn open(&self, interface: &str) -> Result<Self::Handle> {
        anyhow::bail!(
            "pcap capture backend is not enabled in this build; cannot open interface {interface}"
        );
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use anyhow::Result;

    use super::{CaptureOpener, open_allowlisted_interfaces};
    use crate::config::Config;

    #[derive(Default)]
    struct FakeOpener {
        opened: Mutex<Vec<String>>,
    }

    impl CaptureOpener for FakeOpener {
        type Handle = ();

        fn open(&self, interface: &str) -> Result<Self::Handle> {
            self.opened.lock().unwrap().push(interface.to_string());
            Ok(())
        }
    }

    #[test]
    fn empty_allowlist_opens_no_handles() {
        let opener = FakeOpener::default();
        let config = Config {
            enabled: true,
            capture_interfaces: Vec::new(),
            ..Default::default()
        };

        let handles = open_allowlisted_interfaces(&config, &opener).unwrap();

        assert_eq!(handles.len(), 0);
        assert!(opener.opened.lock().unwrap().is_empty());
    }

    #[test]
    fn opens_each_allowlisted_interface() {
        let opener = FakeOpener::default();
        let config = Config {
            enabled: true,
            capture_interfaces: vec!["eth0".to_string(), "enp0s1".to_string()],
            ..Default::default()
        };

        let handles = open_allowlisted_interfaces(&config, &opener).unwrap();

        assert_eq!(handles.len(), 2);
        assert_eq!(
            opener.opened.lock().unwrap().as_slice(),
            ["eth0".to_string(), "enp0s1".to_string()]
        );
    }

    #[test]
    fn invalid_allowlist_opens_no_handles() {
        let opener = FakeOpener::default();
        let config = Config {
            enabled: true,
            capture_interfaces: vec!["any".to_string()],
            ..Default::default()
        };

        assert!(open_allowlisted_interfaces(&config, &opener).is_err());
        assert!(opener.opened.lock().unwrap().is_empty());
    }
}
