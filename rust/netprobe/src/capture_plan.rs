//! Which configured capture interfaces this host can actually capture on.
//!
//! `capture_interfaces` reaches netprobe from add-on profiles that can target a
//! whole fleet, but interface names are facts about one host: a VM's virtio NIC
//! name does not exist on a hypervisor whose NICs are bridges and bonds. Opening
//! an absent interface used to be a fatal startup error, so systemd restarted
//! netprobe forever and flow attribution -- which needs no capture interface at
//! all -- went down with it.
//!
//! The plan splits the configured list into present and absent names once, at
//! startup. Capture, the interface allowlist and the TC/XDP attachment use only
//! the present ones; the absent ones become a DEGRADED health report so the
//! operator sees the misconfiguration instead of a restart counter.

use std::collections::BTreeMap;

use crate::config::Config;

/// Upper bound on interface names quoted in the health reason and details. A
/// hypervisor carries one tap/veth/firewall-bridge interface per guest, so an
/// unbounded list would bury the names an operator is looking for.
const MAX_LISTED_INTERFACES: usize = 16;

pub const DETAIL_MISSING: &str = "capture_interfaces.missing";
pub const DETAIL_PRESENT: &str = "capture_interfaces.present";
pub const DETAIL_AVAILABLE: &str = "capture_interfaces.available";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CapturePlan {
    /// Configured interfaces that exist on this host, in configured order.
    pub present: Vec<String>,
    /// Configured interfaces that do not exist on this host.
    pub missing: Vec<String>,
    /// Every non-loopback interface on this host, sorted.
    pub available: Vec<String>,
}

impl CapturePlan {
    /// Splits `configured` against the host's interface names.
    ///
    /// `host_interfaces` is `None` when the host's interfaces could not be
    /// listed. The plan then treats every configured name as present, so the
    /// capture open reports its own error rather than netprobe guessing.
    pub fn new(configured: &[String], host_interfaces: Option<&[String]>) -> Self {
        let Some(host_interfaces) = host_interfaces else {
            return Self {
                present: configured.to_vec(),
                ..Self::default()
            };
        };

        let (present, missing) = configured
            .iter()
            .cloned()
            .partition(|name| host_interfaces.contains(name));
        let mut available: Vec<String> = host_interfaces
            .iter()
            .filter(|name| name.as_str() != "lo")
            .cloned()
            .collect();
        available.sort();
        available.dedup();

        Self {
            present,
            missing,
            available,
        }
    }

    /// Resolves `configured` against the interfaces of the running host.
    pub fn for_host(configured: &[String]) -> Self {
        if configured.is_empty() {
            return Self::default();
        }
        let host_interfaces = host_interface_names();
        if let Err(err) = &host_interfaces {
            log::warn!(
                "could not list host network interfaces ({err}); capture interfaces are not pre-checked"
            );
        }

        Self::new(configured, host_interfaces.ok().as_deref())
    }

    /// The config capture runs with: `config` restricted to the present
    /// interfaces. Everything that compares configs keeps the requested list,
    /// so the flow table keeps the size the requested list implies.
    pub fn capture_config(&self, config: &Config) -> Config {
        Config {
            capture_interfaces: self.present.clone(),
            flow_table_max_entries: config.effective_flow_table_max_entries(),
            ..config.clone()
        }
    }

    /// The operator-facing explanation, when any configured interface is absent.
    pub fn degradation_reason(&self) -> Option<String> {
        if self.missing.is_empty() {
            return None;
        }

        let noun = if self.missing.len() == 1 {
            "capture interface"
        } else {
            "capture interfaces"
        };
        let present = if self.present.is_empty() {
            "none".to_owned()
        } else {
            bounded_list(&self.present)
        };

        Some(format!(
            "{noun} {} not present on this host (available: {}); present: {present}",
            self.missing.join(", "),
            bounded_list(&self.available),
        ))
    }

    /// Structured form of the same state for `HealthResponse.details`.
    pub fn health_details(&self) -> BTreeMap<String, String> {
        if self.missing.is_empty() {
            return BTreeMap::new();
        }

        BTreeMap::from([
            (DETAIL_MISSING.to_owned(), bounded_list(&self.missing)),
            (DETAIL_PRESENT.to_owned(), bounded_list(&self.present)),
            (DETAIL_AVAILABLE.to_owned(), bounded_list(&self.available)),
        ])
    }
}

fn bounded_list(names: &[String]) -> String {
    if names.len() <= MAX_LISTED_INTERFACES {
        return names.join(", ");
    }

    format!(
        "{}, and {} more",
        names[..MAX_LISTED_INTERFACES].join(", "),
        names.len() - MAX_LISTED_INTERFACES
    )
}

/// The network interfaces visible to this process.
///
/// `/sys/class/net` lists the interfaces of the network namespace sysfs was
/// mounted in, which for the systemd unit is the host namespace that capture
/// opens in.
#[cfg(target_os = "linux")]
fn host_interface_names() -> std::io::Result<Vec<String>> {
    std::fs::read_dir("/sys/class/net")?
        .map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned()))
        .collect()
}

#[cfg(not(target_os = "linux"))]
fn host_interface_names() -> std::io::Result<Vec<String>> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "interface listing is only implemented on Linux",
    ))
}

#[cfg(test)]
mod tests {
    use super::{CapturePlan, DETAIL_AVAILABLE, DETAIL_MISSING, DETAIL_PRESENT};
    use crate::config::Config;

    fn names(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn splits_configured_interfaces_into_present_and_missing() {
        let host = names(&["lo", "eth-test1", "br-test0"]);
        let plan = CapturePlan::new(&names(&["eth-test0", "eth-test1"]), Some(&host));

        assert_eq!(plan.present, names(&["eth-test1"]));
        assert_eq!(plan.missing, names(&["eth-test0"]));
        assert_eq!(plan.available, names(&["br-test0", "eth-test1"]));
        assert_eq!(
            plan.degradation_reason().as_deref(),
            Some(
                "capture interface eth-test0 not present on this host \
                 (available: br-test0, eth-test1); present: eth-test1"
            )
        );
        let details = plan.health_details();
        assert_eq!(details[DETAIL_MISSING], "eth-test0");
        assert_eq!(details[DETAIL_PRESENT], "eth-test1");
        assert_eq!(details[DETAIL_AVAILABLE], "br-test0, eth-test1");
    }

    #[test]
    fn capture_config_sizes_the_flow_table_from_the_requested_list() {
        let host = names(&["eth-test1"]);
        let requested = names(&["eth-test0", "eth-test1"]);
        let plan = CapturePlan::new(&requested, Some(&host));
        let config = Config {
            capture_interfaces: requested,
            flow_table_max_entries: 0,
            ..Config::default()
        };

        let capture = plan.capture_config(&config);

        assert_eq!(capture.capture_interfaces, names(&["eth-test1"]));
        assert_eq!(capture.effective_flow_table_max_entries(), 131_072);
    }

    #[test]
    fn no_present_interface_is_reported_as_none_present() {
        let host = names(&["br-test0"]);
        let plan = CapturePlan::new(&names(&["eth-test0"]), Some(&host));

        assert!(plan.present.is_empty());
        let reason = plan
            .degradation_reason()
            .expect("absent interface degrades");
        assert_eq!(
            reason,
            "capture interface eth-test0 not present on this host \
             (available: br-test0); present: none"
        );
    }

    #[test]
    fn every_interface_present_is_not_degraded() {
        let host = names(&["eth-test0"]);
        let plan = CapturePlan::new(&names(&["eth-test0"]), Some(&host));

        assert_eq!(plan.present, names(&["eth-test0"]));
        assert_eq!(plan.degradation_reason(), None);
        assert!(plan.health_details().is_empty());
    }

    #[test]
    fn unlistable_host_keeps_every_configured_interface() {
        let plan = CapturePlan::new(&names(&["eth-test0"]), None);

        assert_eq!(plan.present, names(&["eth-test0"]));
        assert_eq!(plan.degradation_reason(), None);
    }

    #[test]
    fn long_interface_lists_are_bounded() {
        let host: Vec<String> = (0..40).map(|index| format!("tap-test{index:02}")).collect();
        let plan = CapturePlan::new(&names(&["eth-test0"]), Some(&host));

        let available = &plan.health_details()[DETAIL_AVAILABLE];
        assert!(available.ends_with(", and 24 more"), "{available}");
        assert_eq!(available.matches("tap-test").count(), 16);
    }
}
