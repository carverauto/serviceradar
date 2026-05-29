use crate::config::{Config, HostSliceConfig};
use crate::flowpb::FlowMessage;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;

#[derive(Debug, Default)]
pub struct HostSliceRouter {
    subjects_by_ip: HashMap<IpAddr, Vec<Arc<str>>>,
}

impl HostSliceRouter {
    pub fn from_config(config: &Config) -> Self {
        let mut subjects_by_ip: HashMap<IpAddr, Vec<Arc<str>>> = HashMap::new();

        for slice in config.host_slices.iter().filter(|slice| {
            slice.partition == config.partition && slice.host_network_visibility_enabled()
        }) {
            let subject: Arc<str> = Arc::from(slice.subject());

            for ip in &slice.host_ips {
                subjects_by_ip
                    .entry(*ip)
                    .or_default()
                    .push(Arc::clone(&subject));
            }
        }

        Self { subjects_by_ip }
    }

    pub fn subjects_for_flow(&self, flow: &FlowMessage) -> Vec<String> {
        let mut subjects = Vec::new();

        if let Some(src) = flow_ip(&flow.src_addr) {
            self.push_subjects(src, &mut subjects);
        }
        if let Some(dst) = flow_ip(&flow.dst_addr) {
            self.push_subjects(dst, &mut subjects);
        }

        subjects
    }

    fn push_subjects(&self, ip: IpAddr, subjects: &mut Vec<String>) {
        let Some(matches) = self.subjects_by_ip.get(&ip) else {
            return;
        };

        for subject in matches {
            if !subjects.iter().any(|existing| existing == subject.as_ref()) {
                subjects.push(subject.to_string());
            }
        }
    }
}

pub fn host_slice_subject(agent_id: &str) -> String {
    format!("flow.host-slice.{agent_id}")
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

fn is_safe_subject_token(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, DropPolicy, HostNetworkVisibilityStatus, ListenerConfig};
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

    fn config_with_slices(host_slices: Vec<HostSliceConfig>) -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            nats_creds_file: None,
            stream_name: "events".to_string(),
            stream_subjects: None,
            stream_max_bytes: 1024,
            stream_replicas: 1,
            partition: "default".to_string(),
            channel_size: 100,
            batch_size: 10,
            publish_timeout_ms: 1000,
            drop_policy: DropPolicy::DropOldest,
            security: None,
            metrics_addr: None,
            host_slices,
            listeners: vec![ListenerConfig::Sflow {
                listen_addr: "127.0.0.1:6343".to_string(),
                subject: "flows.raw.sflow".to_string(),
                buffer_size: 1024,
                max_samples_per_datagram: None,
            }],
        }
    }
}
