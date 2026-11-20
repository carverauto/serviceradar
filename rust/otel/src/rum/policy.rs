use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use futures::StreamExt;
use log::{debug, info, warn};
use prost::Message;

use crate::config::RumConfig;
use crate::nats::{NATSConfig, NATSOutput};
use crate::rum::prefix::TagTrie;
use crate::rum_proto::{RumPrefixTagRule, WebPropertyRumPolicy, WebPropertyRumPolicySnapshot};

#[derive(Clone, Debug)]
pub struct CompiledPropertyPolicy {
    pub web_property_id: String,
    pub name: String,
    pub canonical_origin: String,
    pub allowed_origins: Vec<String>,
    pub allowed_query_keys: Vec<String>,
    pub trace_propagate_origins: Vec<String>,
    pub rum_site_key: String,
    pub rum_enabled: bool,
    pub rum_sample_rate: f64,
    pub anonymize_client_ip: bool,
    pub environment: String,
    pub prefix_trie: TagTrie,
}

#[derive(Debug, Default)]
struct PolicySnapshotState {
    version: u64,
    by_site_key: HashMap<String, CompiledPropertyPolicy>,
    global_prefix_trie: TagTrie,
}

#[derive(Debug, Default)]
pub struct RumPolicyCache {
    state: RwLock<PolicySnapshotState>,
}

impl RumPolicyCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_snapshot(snapshot: WebPropertyRumPolicySnapshot) -> Self {
        let cache = Self::new();
        cache.apply_snapshot(snapshot);
        cache
    }

    /// Replaces the active policy snapshot if `snapshot.version` is monotonic
    /// (`snapshot.version == 0 || snapshot.version >= current.version`).
    pub fn apply_snapshot(&self, snapshot: WebPropertyRumPolicySnapshot) -> bool {
        let mut by_site_key = HashMap::with_capacity(snapshot.properties.len());
        for prop in snapshot.properties {
            if let Some(compiled) = compile_property(prop) {
                by_site_key.insert(compiled.rum_site_key.clone(), compiled);
            }
        }
        let global_prefix_trie = compile_trie(&snapshot.global_prefix_tags);

        let mut guard = self
            .state
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if snapshot.version > 0 && snapshot.version < guard.version {
            debug!(
                "Ignoring stale RUM policy snapshot version {} (current {})",
                snapshot.version, guard.version
            );
            return false;
        }
        guard.version = snapshot.version;
        guard.by_site_key = by_site_key;
        guard.global_prefix_trie = global_prefix_trie;
        true
    }

    pub fn version(&self) -> u64 {
        self.state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .version
    }

    pub fn lookup(&self, site_key: &str) -> Option<CompiledPropertyPolicy> {
        let trimmed = site_key.trim();
        if trimmed.is_empty() {
            return None;
        }
        self.state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .by_site_key
            .get(trimmed)
            .cloned()
    }

    pub fn lookup_prefix_tag(&self, policy: &CompiledPropertyPolicy, ip: IpAddr) -> Option<String> {
        if let Some(tag) = policy.prefix_trie.lookup(ip) {
            return Some(tag.to_string());
        }
        self.state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .global_prefix_trie
            .lookup(ip)
            .map(str::to_string)
    }

    pub fn any_origin_allowed(&self, origin: &str) -> bool {
        let Some(normalized) = normalize_origin(origin) else {
            return false;
        };
        let guard = self
            .state
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard
            .by_site_key
            .values()
            .filter(|p| p.rum_enabled)
            .any(|p| policy_allows_normalized_origin(p, &normalized))
    }

    pub fn validate_origin(&self, policy: &CompiledPropertyPolicy, origin: Option<&str>) -> bool {
        let Some(raw_origin) = origin else {
            return false;
        };
        let Some(normalized) = normalize_origin(raw_origin) else {
            return false;
        };
        policy_allows_normalized_origin(policy, &normalized)
    }
}

fn compile_property(prop: WebPropertyRumPolicy) -> Option<CompiledPropertyPolicy> {
    let web_property_id = prop.web_property_id.trim().to_string();
    let rum_site_key = prop.rum_site_key.trim().to_string();
    if web_property_id.is_empty() || rum_site_key.is_empty() {
        return None;
    }

    let mut allowed_origins = Vec::new();
    if let Some(canon) = normalize_origin(&prop.canonical_origin) {
        allowed_origins.push(canon);
    }
    for raw in &prop.allowed_origins {
        if let Some(norm) = normalize_origin(raw)
            && !allowed_origins.contains(&norm)
        {
            allowed_origins.push(norm);
        }
    }

    Some(CompiledPropertyPolicy {
        web_property_id,
        name: prop.name,
        canonical_origin: normalize_origin(&prop.canonical_origin).unwrap_or(prop.canonical_origin),
        allowed_origins,
        allowed_query_keys: prop
            .allowed_query_keys
            .into_iter()
            .map(|k| k.trim().to_string())
            .filter(|k| !k.is_empty())
            .collect(),
        trace_propagate_origins: prop.trace_propagate_origins,
        rum_site_key,
        rum_enabled: prop.rum_enabled,
        rum_sample_rate: prop.rum_sample_rate.clamp(0.0, 1.0),
        anonymize_client_ip: prop.anonymize_client_ip,
        environment: prop.environment,
        prefix_trie: compile_trie(&prop.prefix_tags),
    })
}

fn compile_trie(rules: &[RumPrefixTagRule]) -> TagTrie {
    let mut trie = TagTrie::new();
    for rule in rules {
        trie.insert(&rule.cidr, &rule.tag);
    }
    trie
}

/// Normalizes an origin (`https://Shop.Example.com:443/` -> `https://shop.example.com`)
/// or single-label wildcard origin (`https://*.Example.com` -> `https://*.example.com`).
/// Rejects bare `"*"` wildcards and invalid schemes.
pub fn normalize_origin(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "*" {
        return None;
    }
    let (scheme, rest) = trimmed.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?.trim();
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = split_host_port(authority)?;
    let host_lower = host.to_ascii_lowercase();
    if host_lower.is_empty() || host_lower == "*" {
        return None;
    }
    let default_port = if scheme == "https" {
        Some(443)
    } else {
        Some(80)
    };
    match port {
        Some(p) if Some(p) != default_port => Some(format!("{scheme}://{host_lower}:{p}")),
        _ => Some(format!("{scheme}://{host_lower}")),
    }
}

fn split_host_port(authority: &str) -> Option<(&str, Option<u16>)> {
    if authority.starts_with('[') {
        let end = authority.find(']')?;
        let host = &authority[..=end];
        let after = &authority[end + 1..];
        if after.is_empty() {
            return Some((host, None));
        }
        let port = after.strip_prefix(':')?.parse::<u16>().ok()?;
        return Some((host, Some(port)));
    }
    match authority.rsplit_once(':') {
        Some((host, port_str)) if !host.contains(':') => {
            let port = port_str.parse::<u16>().ok()?;
            Some((host, Some(port)))
        }
        _ => Some((authority, None)),
    }
}

fn policy_allows_normalized_origin(policy: &CompiledPropertyPolicy, normalized: &str) -> bool {
    policy.allowed_origins.iter().any(|allowed| {
        if allowed == normalized {
            return true;
        }
        wildcard_origin_matches(allowed, normalized)
    })
}

/// Matches a single-label wildcard origin such as `https://*.example.com` against
/// `https://shop.example.com` (never matching multi-level `https://a.b.example.com`
/// or bare apex `https://example.com`).
fn wildcard_origin_matches(pattern: &str, candidate: &str) -> bool {
    let Some((pat_scheme, pat_rest)) = pattern.split_once("://") else {
        return false;
    };
    let Some((cand_scheme, cand_rest)) = candidate.split_once("://") else {
        return false;
    };
    if pat_scheme != cand_scheme {
        return false;
    }
    let Some((pat_host, pat_port)) = split_host_port(pat_rest) else {
        return false;
    };
    let Some((cand_host, cand_port)) = split_host_port(cand_rest) else {
        return false;
    };
    if pat_port != cand_port {
        return false;
    }
    let Some(suffix) = pat_host.strip_prefix("*.") else {
        return false;
    };
    if suffix.is_empty() || suffix.contains('*') {
        return false;
    }
    let Some(prefix_label) = cand_host.strip_suffix(&format!(".{suffix}")) else {
        return false;
    };
    !prefix_label.is_empty() && !prefix_label.contains('.')
}

/// Background NATS task keeping `RumPolicyCache` synchronized with `RumPolicySync`.
pub async fn run_policy_sync(
    nats_config: NATSConfig,
    cache: Arc<RumPolicyCache>,
    rum_config: RumConfig,
) {
    let mut backoff_secs: u64 = 1;
    let refresh_interval = Duration::from_secs(rum_config.policy_refresh_interval_secs.max(10));

    loop {
        match NATSOutput::connect(&nats_config).await {
            Ok((client, _js, _guard)) => {
                backoff_secs = 1;
                info!(
                    "RUM policy sync connected to NATS (updates: {}, snapshot: {})",
                    rum_config.policy_updates_subject, rum_config.policy_snapshot_subject
                );

                let mut sub = match client
                    .subscribe(rum_config.policy_updates_subject.clone())
                    .await
                {
                    Ok(sub) => sub,
                    Err(e) => {
                        warn!("RUM policy sync subscribe failed: {e}");
                        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                        backoff_secs = (backoff_secs * 2).min(30);
                        continue;
                    }
                };

                request_snapshot(&client, &rum_config.policy_snapshot_subject, &cache).await;

                let mut ticker = tokio::time::interval(refresh_interval);
                ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                ticker.tick().await;

                loop {
                    tokio::select! {
                        maybe_msg = sub.next() => {
                            match maybe_msg {
                                Some(msg) => {
                                    apply_snapshot_bytes(&cache, &msg.payload, "update");
                                }
                                None => {
                                    warn!("RUM policy updates subscription closed; reconnecting");
                                    break;
                                }
                            }
                        }
                        _ = ticker.tick() => {
                            request_snapshot(&client, &rum_config.policy_snapshot_subject, &cache).await;
                        }
                    }
                }
            }
            Err(e) => {
                warn!("RUM policy sync NATS connect failed (retry in {backoff_secs}s): {e}");
            }
        }

        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(30);
    }
}

async fn request_snapshot(client: &async_nats::Client, subject: &str, cache: &RumPolicyCache) {
    match tokio::time::timeout(
        Duration::from_secs(5),
        client.request(subject.to_string(), Vec::new().into()),
    )
    .await
    {
        Ok(Ok(reply)) => {
            apply_snapshot_bytes(cache, &reply.payload, "snapshot");
        }
        Ok(Err(e)) => {
            debug!("RUM policy snapshot request failed on '{subject}': {e}");
        }
        Err(_) => {
            debug!("RUM policy snapshot request timed out on '{subject}'");
        }
    }
}

fn apply_snapshot_bytes(cache: &RumPolicyCache, payload: &[u8], kind: &str) {
    if payload.is_empty() {
        return;
    }
    match WebPropertyRumPolicySnapshot::decode(payload) {
        Ok(snapshot) => {
            let prop_count = snapshot.properties.len();
            let version = snapshot.version;
            if cache.apply_snapshot(snapshot) {
                debug!("Applied RUM policy {kind} version={version} properties={prop_count}");
            }
        }
        Err(e) => {
            warn!("Failed to decode RUM policy {kind}: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_policy(id: &str, key: &str, origin: &str, enabled: bool) -> WebPropertyRumPolicy {
        WebPropertyRumPolicy {
            web_property_id: id.to_string(),
            name: "Shop".to_string(),
            canonical_origin: origin.to_string(),
            allowed_origins: vec!["https://*.shop.example.com".to_string()],
            allowed_query_keys: vec!["tab".to_string()],
            trace_propagate_origins: vec![],
            rum_site_key: key.to_string(),
            rum_enabled: enabled,
            rum_sample_rate: 1.0,
            anonymize_client_ip: true,
            environment: "production".to_string(),
            prefix_tags: vec![RumPrefixTagRule {
                cidr: "198.51.100.0/24".to_string(),
                tag: "site:branch-01".to_string(),
            }],
        }
    }

    #[test]
    fn snapshot_hydration_version_guard_and_key_rotation() {
        let cache = RumPolicyCache::new();
        let snap1 = WebPropertyRumPolicySnapshot {
            version: 10,
            generated_at_unix_ms: 10,
            properties: vec![sample_policy(
                "wp-1",
                "sr_rum_oldkey1234567890",
                "https://shop.example.com",
                true,
            )],
            global_prefix_tags: vec![RumPrefixTagRule {
                cidr: "203.0.113.0/24".to_string(),
                tag: "site:global-dc".to_string(),
            }],
        };
        assert!(cache.apply_snapshot(snap1));
        assert!(cache.lookup("sr_rum_oldkey1234567890").is_some());

        // Stale snapshot must be ignored.
        let stale = WebPropertyRumPolicySnapshot {
            version: 9,
            generated_at_unix_ms: 9,
            properties: vec![],
            global_prefix_tags: vec![],
        };
        assert!(!cache.apply_snapshot(stale));
        assert!(cache.lookup("sr_rum_oldkey1234567890").is_some());

        // Rotated key replaces old key immediately.
        let rotated = WebPropertyRumPolicySnapshot {
            version: 11,
            generated_at_unix_ms: 11,
            properties: vec![sample_policy(
                "wp-1",
                "sr_rum_newkey1234567890",
                "https://shop.example.com",
                true,
            )],
            global_prefix_tags: vec![],
        };
        assert!(cache.apply_snapshot(rotated));
        assert!(cache.lookup("sr_rum_oldkey1234567890").is_none());
        let policy = cache.lookup("sr_rum_newkey1234567890").unwrap();
        assert_eq!(
            cache.lookup_prefix_tag(&policy, "198.51.100.42".parse().unwrap()),
            Some("site:branch-01".to_string())
        );

        // Disabled property remains discoverable so HTTP gate returns 403.
        let disabled = WebPropertyRumPolicySnapshot {
            version: 12,
            generated_at_unix_ms: 12,
            properties: vec![sample_policy(
                "wp-1",
                "sr_rum_newkey1234567890",
                "https://shop.example.com",
                false,
            )],
            global_prefix_tags: vec![],
        };
        assert!(cache.apply_snapshot(disabled));
        assert!(!cache.lookup("sr_rum_newkey1234567890").unwrap().rum_enabled);
    }

    #[test]
    fn origin_validation_matches_exact_and_single_label_wildcard_only() {
        let cache = RumPolicyCache::from_snapshot(WebPropertyRumPolicySnapshot {
            version: 1,
            generated_at_unix_ms: 1,
            properties: vec![sample_policy(
                "wp-1",
                "sr_rum_testkey123456789",
                "https://shop.example.com:443",
                true,
            )],
            global_prefix_tags: vec![],
        });
        let policy = cache.lookup("sr_rum_testkey123456789").unwrap();

        assert!(cache.validate_origin(&policy, Some("https://shop.example.com")));
        assert!(cache.validate_origin(&policy, Some("https://checkout.shop.example.com")));
        assert!(!cache.validate_origin(&policy, Some("https://a.b.shop.example.com")));
        assert!(!cache.validate_origin(&policy, Some("https://evil.example")));
        assert!(!cache.validate_origin(&policy, Some("*")));
        assert!(!cache.validate_origin(&policy, None));
    }
}
