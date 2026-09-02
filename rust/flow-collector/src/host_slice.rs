use crate::config::{Config, HostSliceConfig};
use crate::flowpb::FlowMessage;
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Arc;

#[derive(Debug, Default)]
pub struct HostSliceRouter {
    targets_by_ip: HashMap<IpAddr, Vec<HostSliceTarget>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSliceTarget {
    pub agent_id: Arc<str>,
    pub partition: Arc<str>,
    pub subject: Arc<str>,
}

impl HostSliceRouter {
    pub fn from_config(config: &Config) -> Self {
        let mut targets_by_ip: HashMap<IpAddr, Vec<HostSliceTarget>> = HashMap::new();

        for slice in config
            .host_slices
            .iter()
            .filter(|slice| host_slice_publication_allowed(config, slice))
        {
            let target = HostSliceTarget {
                agent_id: Arc::from(slice.agent_id.as_str()),
                partition: Arc::from(slice.partition.as_str()),
                subject: Arc::from(slice.subject()),
            };

            for ip in &slice.host_ips {
                targets_by_ip.entry(*ip).or_default().push(target.clone());
            }
        }

        Self { targets_by_ip }
    }

    /// Subjects only, for tests that assert on routing without the rest of the target.
    /// Production goes through [`Self::targets_for_flow`], which carries the full target.
    #[cfg(test)]
    pub fn subjects_for_flow(&self, flow: &FlowMessage) -> Vec<String> {
        self.targets_for_flow(flow)
            .into_iter()
            .map(|target| target.subject.to_string())
            .collect()
    }

    pub fn targets_for_flow(&self, flow: &FlowMessage) -> Vec<HostSliceTarget> {
        let mut targets = Vec::new();

        if let Some(src) = flow_ip(&flow.src_addr) {
            self.push_targets(src, &mut targets);
        }
        if let Some(dst) = flow_ip(&flow.dst_addr) {
            self.push_targets(dst, &mut targets);
        }

        targets
    }

    pub fn metric_slices(config: &Config) -> Vec<(String, String)> {
        let mut slices: Vec<_> = config
            .host_slices
            .iter()
            .filter(|slice| host_slice_publication_allowed(config, slice))
            .map(|slice| (slice.agent_id.clone(), slice.subject()))
            .collect();

        slices.sort_by(|left, right| left.1.cmp(&right.1));
        slices.dedup_by(|left, right| left.1 == right.1);
        slices
    }

    fn push_targets(&self, ip: IpAddr, targets: &mut Vec<HostSliceTarget>) {
        let Some(matches) = self.targets_by_ip.get(&ip) else {
            return;
        };

        for target in matches {
            if !targets
                .iter()
                .any(|existing| existing.subject == target.subject)
            {
                targets.push(target.clone());
            }
        }
    }
}

pub fn host_slice_subject(agent_id: &str) -> String {
    format!("flow.host-slice.{agent_id}")
}

pub fn host_slice_publication_allowed(config: &Config, slice: &HostSliceConfig) -> bool {
    slice.partition == config.partition
        && slice.host_network_visibility_enabled()
        && config
            .host_slice_allowlist
            .iter()
            .any(|agent_id| agent_id == &slice.agent_id)
}

fn flow_ip(bytes: &[u8]) -> Option<IpAddr> {
    match bytes.len() {
        4 => Some(IpAddr::from(<[u8; 4]>::try_from(bytes).ok()?)),
        16 => Some(IpAddr::from(<[u8; 16]>::try_from(bytes).ok()?)),
        _ => None,
    }
}

pub fn validate_host_slice(slice: &HostSliceConfig, index: usize) -> anyhow::Result<()> {
    if slice.agent_id.is_empty() {
        anyhow::bail!("host_slices[{}]: agent_id cannot be empty", index);
    }
    if !is_safe_subject_token(&slice.agent_id) {
        anyhow::bail!(
            "host_slices[{}]: agent_id must contain only letters, numbers, '_' or '-'",
            index
        );
    }
    if slice.partition.is_empty() {
        anyhow::bail!("host_slices[{}]: partition cannot be empty", index);
    }
    if !slice.host_network_visibility_enabled() {
        return Ok(());
    }
    if slice.host_ips.is_empty() {
        anyhow::bail!(
            "host_slices[{}]: host_ips cannot be empty for enabled host-network-visibility",
            index
        );
    }

    Ok(())
}

pub fn validate_host_slice_allowlist(allowlist: &[String]) -> anyhow::Result<()> {
    let mut seen = HashSet::new();

    for (index, agent_id) in allowlist.iter().enumerate() {
        if agent_id.is_empty() {
            anyhow::bail!("host_slice_allowlist[{}]: agent_id cannot be empty", index);
        }
        if !is_safe_subject_token(agent_id) {
            anyhow::bail!(
                "host_slice_allowlist[{}]: agent_id must contain only letters, numbers, '_' or '-'",
                index
            );
        }
        if !seen.insert(agent_id) {
            anyhow::bail!(
                "host_slice_allowlist[{}]: duplicate agent_id '{}'",
                index,
                agent_id
            );
        }
    }

    Ok(())
}

fn is_safe_subject_token(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, HostNetworkVisibilityStatus, ListenerConfig};
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn routes_flow_to_matching_host_slice_once() {
        let router = HostSliceRouter::from_config(&config_with_slices(vec![HostSliceConfig {
            agent_id: "agent-1".to_string(),
            partition: "default".to_string(),
            host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            host_network_visibility: HostNetworkVisibilityStatus::Enabled,
        }]));

        let subjects = router.subjects_for_flow(&FlowMessage {
            src_addr: vec![192, 0, 2, 10],
            dst_addr: vec![192, 0, 2, 10],
            ..Default::default()
        });

        assert_eq!(subjects, vec!["flow.host-slice.agent-1"]);

        let targets = router.targets_for_flow(&FlowMessage {
            src_addr: vec![192, 0, 2, 10],
            dst_addr: vec![192, 0, 2, 10],
            ..Default::default()
        });

        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].agent_id.as_ref(), "agent-1");
        assert_eq!(targets[0].partition.as_ref(), "default");
        assert_eq!(targets[0].subject.as_ref(), "flow.host-slice.agent-1");
    }

    #[test]
    fn ignores_unrelated_unavailable_and_cross_partition_slices() {
        let router = HostSliceRouter::from_config(&config_with_slices(vec![
            HostSliceConfig {
                agent_id: "agent-unavailable".to_string(),
                partition: "default".to_string(),
                host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                host_network_visibility: HostNetworkVisibilityStatus::Unavailable,
            },
            HostSliceConfig {
                agent_id: "agent-other-partition".to_string(),
                partition: "tenant-b".to_string(),
                host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                host_network_visibility: HostNetworkVisibilityStatus::Enabled,
            },
            HostSliceConfig {
                agent_id: "agent-unrelated".to_string(),
                partition: "default".to_string(),
                host_ips: vec![IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20))],
                host_network_visibility: HostNetworkVisibilityStatus::Enabled,
            },
        ]));

        assert!(
            router
                .subjects_for_flow(&FlowMessage {
                    src_addr: vec![192, 0, 2, 10],
                    dst_addr: vec![203, 0, 113, 5],
                    ..Default::default()
                })
                .is_empty()
        );
    }

    #[test]
    fn ignores_enabled_slices_without_allowlist_entry() {
        let router = HostSliceRouter::from_config(&config_with_slices_and_allowlist(
            vec![HostSliceConfig {
                agent_id: "agent-1".to_string(),
                partition: "default".to_string(),
                host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                host_network_visibility: HostNetworkVisibilityStatus::Enabled,
            }],
            Vec::new(),
        ));

        assert!(
            router
                .subjects_for_flow(&FlowMessage {
                    src_addr: vec![192, 0, 2, 10],
                    dst_addr: vec![203, 0, 113, 5],
                    ..Default::default()
                })
                .is_empty()
        );
    }

    #[test]
    fn metric_slices_include_only_allowed_slice_subjects() {
        let config = config_with_slices_and_allowlist(
            vec![
                HostSliceConfig {
                    agent_id: "agent-1".to_string(),
                    partition: "default".to_string(),
                    host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                    host_network_visibility: HostNetworkVisibilityStatus::Enabled,
                },
                HostSliceConfig {
                    agent_id: "agent-2".to_string(),
                    partition: "default".to_string(),
                    host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20))],
                    host_network_visibility: HostNetworkVisibilityStatus::Enabled,
                },
            ],
            vec!["agent-1".to_string()],
        );

        assert_eq!(
            HostSliceRouter::metric_slices(&config),
            vec![("agent-1".to_string(), "flow.host-slice.agent-1".to_string())]
        );
    }

    fn config_with_slices(host_slices: Vec<HostSliceConfig>) -> Config {
        let host_slice_allowlist = host_slices
            .iter()
            .map(|slice| slice.agent_id.clone())
            .collect();

        config_with_slices_and_allowlist(host_slices, host_slice_allowlist)
    }

    fn config_with_slices_and_allowlist(
        host_slices: Vec<HostSliceConfig>,
        host_slice_allowlist: Vec<String>,
    ) -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            nats_creds_file: None,
            stream_name: "flows".to_string(),
            stream_subjects: None,
            stream_max_bytes: 1024,
            stream_max_age_secs: 3600,
            stream_replicas: 1,
            rehome_state_path: None,
            template_store: None,
            ready_state_path: None,
            partition: "default".to_string(),
            channel_size: 100,
            batch_size: 10,
            publish_timeout_ms: 1000,
            security: None,
            metrics_addr: None,
            host_slice_allowlist,
            host_slices,
            listeners: vec![ListenerConfig::Sflow {
                listen_addr: "127.0.0.1:6343".to_string(),
                subject: "flows.raw.sflow".to_string(),
                buffer_size: 1024,
                channel_size: None,
                max_samples_per_datagram: None,
            }],
        }
    }
}
