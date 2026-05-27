#[cfg(feature = "pcap-capture")]
use std::thread;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread::JoinHandle,
};

use anyhow::{Context, Result};
use tokio::sync::broadcast;

use crate::{
    config::Config, metrics::Metrics, proto::netprobe::FingerprintEvent,
    runtime_config::FingerprintEventGate,
};

#[cfg(feature = "pcap-capture")]
use crate::fingerprint::{now_unix_nano, FingerprintEngine};

#[cfg(feature = "pcap-capture")]
pub type CaptureBackendHandle = pcap::Capture<pcap::Active>;

#[cfg(not(feature = "pcap-capture"))]
pub struct CaptureBackendHandle;

pub struct CaptureHandles<H = CaptureBackendHandle> {
    handles: Vec<CaptureHandle<H>>,
}

pub struct CaptureHandle<H = CaptureBackendHandle> {
    interface: String,
    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
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

    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
    fn into_handles(self) -> Vec<CaptureHandle<H>> {
        self.handles
    }
}

pub struct CaptureWorkers {
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
}

impl CaptureWorkers {
    pub fn start(
        captures: CaptureHandles,
        metrics: Metrics,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        event_gate: Arc<Mutex<FingerprintEventGate>>,
    ) -> Result<Self> {
        start_capture_workers(captures, metrics, fingerprint_events, event_gate)
    }
}

impl Drop for CaptureWorkers {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);

        while let Some(thread) = self.threads.pop() {
            if thread.join().is_err() {
                log::warn!("netprobe capture worker panicked during shutdown");
            }
        }
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

#[cfg(feature = "pcap-capture")]
fn start_capture_workers(
    captures: CaptureHandles,
    metrics: Metrics,
    fingerprint_events: broadcast::Sender<FingerprintEvent>,
    event_gate: Arc<Mutex<FingerprintEventGate>>,
) -> Result<CaptureWorkers> {
    let stop = Arc::new(AtomicBool::new(false));
    let mut threads = Vec::with_capacity(captures.len());

    for mut capture in captures.into_handles() {
        let stop_worker = Arc::clone(&stop);
        let metrics_worker = metrics.clone();
        let event_tx = fingerprint_events.clone();
        let event_gate = Arc::clone(&event_gate);
        let thread_name = format!("netprobe-capture-{}", capture.interface);
        let thread = thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                let interface = capture.interface.clone();
                let mut engine = match FingerprintEngine::tcp_only() {
                    Ok(engine) => engine,
                    Err(err) => {
                        metrics_worker.inc_signature_failures();
                        log::error!(
                            "failed to initialize fingerprint engine for {interface}: {err:#}"
                        );
                        return;
                    }
                };

                while !stop_worker.load(Ordering::SeqCst) {
                    match capture.handle.next_packet() {
                        Ok(packet) => {
                            metrics_worker.inc_packets_processed();
                            let events =
                                engine.analyze_tcp_packet(&interface, now_unix_nano(), packet.data);
                            for event in events {
                                let Some(event) = event_gate
                                    .lock()
                                    .expect("fingerprint event gate lock poisoned")
                                    .filter(event)
                                else {
                                    continue;
                                };
                                let event_interface = event.interface_name.clone();
                                let event_ip = event.ip.clone();
                                metrics_worker.inc_fingerprint_events();
                                if event_tx.send(event).is_err() {
                                    log::debug!(
                                        "dropping fingerprint event with no active IPC receiver for {}",
                                        event_interface
                                    );
                                }
                                log::debug!(
                                    "observed TCP fingerprint on {} for {}",
                                    event_interface,
                                    event_ip
                                );
                            }
                        }
                        Err(pcap::Error::TimeoutExpired) => {}
                        Err(err) => {
                            metrics_worker.inc_packets_dropped();
                            log::warn!("failed to read packet on {interface}: {err}");
                        }
                    }
                }
            })
            .context("failed to start pcap capture worker")?;
        threads.push(thread);
    }

    Ok(CaptureWorkers { stop, threads })
}

#[cfg(not(feature = "pcap-capture"))]
fn start_capture_workers(
    _captures: CaptureHandles,
    _metrics: Metrics,
    _fingerprint_events: broadcast::Sender<FingerprintEvent>,
    _event_gate: Arc<Mutex<FingerprintEventGate>>,
) -> Result<CaptureWorkers> {
    Ok(CaptureWorkers {
        stop: Arc::new(AtomicBool::new(false)),
        threads: Vec::new(),
    })
}

impl CaptureOpener for PcapCaptureOpener {
    type Handle = CaptureBackendHandle;

    #[cfg(feature = "pcap-capture")]
    fn open(&self, interface: &str) -> Result<Self::Handle> {
        let capture = pcap::Capture::from_device(interface)?
            .promisc(false)
            .snaplen(65_535)
            .timeout(1_000)
            .open()?;

        Ok(capture)
    }

    #[cfg(not(feature = "pcap-capture"))]
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

    use super::{open_allowlisted_interfaces, CaptureOpener};
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
        };

        assert!(open_allowlisted_interfaces(&config, &opener).is_err());
        assert!(opener.opened.lock().unwrap().is_empty());
    }
}
