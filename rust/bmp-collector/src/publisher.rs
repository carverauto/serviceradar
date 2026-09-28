use crate::config::Config;
use crate::model;
use anyhow::{Context, Result};
use arancini_lib::sender::UpdateSender;
use arancini_lib::update::Update;
use async_nats::ConnectOptions;
use async_nats::jetstream::ErrorCode;
use async_nats::jetstream::context::{
    CreateStreamError, CreateStreamErrorKind, GetStreamError, GetStreamErrorKind,
};
use async_nats::jetstream::{
    self,
    stream::{DiscardPolicy, StorageType},
};
use log::{debug, info, warn};
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;
use std::sync::Once;
use std::time::Duration;
use tokio::time::timeout;

#[derive(Clone)]
pub struct Publisher {
    config: Arc<Config>,
    js: jetstream::Context,
}

impl Publisher {
    pub async fn connect(config: Arc<Config>) -> Result<Self> {
        ensure_rustls_provider_installed();
        let mut options = ConnectOptions::new();

        if let Some(creds_file) = &config.nats_creds_file {
            options = options
                .credentials_file(creds_file)
                .await
                .with_context(|| format!("failed loading NATS creds file {}", creds_file))?;
        }

        let has_tls_material = config.nats_tls_ca_cert_path.is_some()
            || (config.nats_tls_client_cert_path.is_some()
                && config.nats_tls_client_key_path.is_some());

        if config.nats_tls_first {
            options = options.tls_first();
        } else if config.nats_tls_required || has_tls_material {
            options = options.require_tls(true);
        }

        if let Some(path) = &config.nats_tls_ca_cert_path {
            options = options.add_root_certificates(path.clone().into());
        }

        if let Some((cert, key)) = resolved_client_cert_pair(&config) {
            options = options.add_client_certificate(cert.clone().into(), key.clone().into());
        }

        let client = options
            .connect(&config.nats_url)
            .await
            .with_context(|| format!("failed connecting to NATS {}", config.nats_url))?;

        let js = if let Some(domain) = &config.nats_domain {
            jetstream::with_domain(client, domain)
        } else {
            jetstream::new(client)
        };

        ensure_stream(&config, &js).await?;

        Ok(Self { config, js })
    }

    async fn publish_update(&self, update: &Update) -> Result<()> {
        match self.publish_update_once(update).await {
            Ok(()) => Ok(()),
            Err(err) if stream_missing(&err) => {
                warn!(
                    "JetStream stream {} missing while publishing; re-ensuring stream and retrying once",
                    self.config.stream_name
                );
                ensure_stream(&self.config, &self.js).await?;
                self.publish_update_once(update).await
            }
            Err(err) => Err(err),
        }
    }

    async fn publish_update_once(&self, update: &Update) -> Result<()> {
        let subject = subject_for_update(&self.config.subject_prefix, update);
        let payload = serde_json::to_vec(&model::to_payload(update))?;
        let ack = self
            .js
            .publish(subject.clone(), payload.into())
            .await
            .with_context(|| {
                format!(
                    "failed publishing update router={} peer={} prefix={}/{} to {}",
                    update.router_addr,
                    update.peer_addr,
                    update.prefix_addr,
                    update.prefix_len,
                    subject
                )
            })?;

        timeout(Duration::from_millis(self.config.publish_timeout_ms), ack)
            .await
            .with_context(|| {
                format!(
                    "publish ack timeout for subject {} after {}ms",
                    subject, self.config.publish_timeout_ms
                )
            })??;

        debug!(
            "published arancini update router={} peer={} prefix={}/{} to {}",
            update.router_addr, update.peer_addr, update.prefix_addr, update.prefix_len, subject
        );
        Ok(())
    }
}

fn resolved_client_cert_pair(config: &Config) -> Option<(String, String)> {
    let cert = config.nats_tls_client_cert_path.as_deref()?;
    let key = config.nats_tls_client_key_path.as_deref()?;

    if path_exists(cert) && path_exists(key) {
        return Some((cert.to_string(), key.to_string()));
    }

    let fallback_cert = "/etc/serviceradar/certs/client.pem";
    let fallback_key = "/etc/serviceradar/certs/client-key.pem";
    if path_exists(fallback_cert) && path_exists(fallback_key) {
        warn!(
            "configured NATS client cert/key missing (cert={}, key={}); falling back to cert={} key={}",
            cert, key, fallback_cert, fallback_key
        );
        return Some((fallback_cert.to_string(), fallback_key.to_string()));
    }

    warn!(
        "configured NATS client cert/key missing and fallback cert/key not found (configured cert={}, key={})",
        cert, key
    );
    Some((cert.to_string(), key.to_string()))
}

fn path_exists(path: &str) -> bool {
    Path::new(path).exists()
}

impl UpdateSender for Publisher {
    fn send<'a>(
        &'a self,
        update: Update,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move { self.publish_update(&update).await })
    }
}

fn stream_missing(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        cause
            .to_string()
            .contains("no stream found for given subject")
    })
}

fn subject_for_update(base_subject: &str, update: &Update) -> String {
    let router_ip = router_ip_subject_token(update.router_addr);
    let afi_safi = afi_safi_subject_token(update);
    format!(
        "{}.{}.{}.{}",
        base_subject.trim_end_matches('.'),
        router_ip,
        update.peer_asn,
        afi_safi
    )
}

fn router_ip_subject_token(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, d] = v4.octets();
            format!("v4_{}_{}_{}_{}", a, b, c, d)
        }
        IpAddr::V6(v6) => {
            if let Some(v4_mapped) = v6.to_ipv4_mapped() {
                return router_ip_subject_token(IpAddr::V4(v4_mapped));
            }

            let segments = v6.segments();
            format!(
                "v6_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}_{:x}",
                segments[0],
                segments[1],
                segments[2],
                segments[3],
                segments[4],
                segments[5],
                segments[6],
                segments[7]
            )
        }
    }
}

fn afi_safi_subject_token(update: &Update) -> String {
    let (afi, safi) = if update.announced {
        (update.attrs.mp_reach_afi, update.attrs.mp_reach_safi)
    } else {
        (update.attrs.mp_unreach_afi, update.attrs.mp_unreach_safi)
    };

    let afi = afi.unwrap_or(match update.prefix_addr {
        IpAddr::V4(_) => 1u16,
        IpAddr::V6(_) => 2u16,
    });
    let safi = safi.unwrap_or(1u8);

    format!("{}_{}", afi, safi)
}

/// Stream metadata key recording which component owns the shape of a multi-owner
/// stream (`events`, `flows`, `ARANCINI_CAUSAL`).
const OWNER_METADATA_KEY: &str = "serviceradar.owner";
/// The claim bmp-collector writes on its stream. It overrides an `event-writer`
/// claim and claims a legacy stream with no metadata.
const OWNER: &str = "bmp-collector";

/// The parts of a stream's shape that bmp-collector owns and reconciles.
#[derive(Debug, Clone, PartialEq, Eq)]
struct StreamShape {
    owner: Option<String>,
    max_bytes: i64,
    num_replicas: usize,
    discard: DiscardPolicy,
}

impl StreamShape {
    fn of(cfg: &jetstream::stream::Config) -> Self {
        Self {
            owner: cfg.metadata.get(OWNER_METADATA_KEY).cloned(),
            max_bytes: cfg.max_bytes,
            num_replicas: cfg.num_replicas,
            discard: cfg.discard,
        }
    }
}

impl std::fmt::Display for StreamShape {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "owner={} max_bytes={} replicas={} discard={:?}",
            self.owner.as_deref().unwrap_or("<none>"),
            self.max_bytes,
            self.num_replicas,
            self.discard
        )
    }
}

/// A stream update that claims and reconciles an existing stream.
#[derive(Debug)]
struct StreamReconcile {
    config: jetstream::stream::Config,
    before: StreamShape,
    after: StreamShape,
}

/// The config bmp-collector creates its stream with when it is absent: claimed, at
/// the configured size and replicas, discard-old.
fn desired_stream_config(config: &Config) -> jetstream::stream::Config {
    jetstream::stream::Config {
        name: config.stream_name.clone(),
        subjects: config.stream_subjects_resolved(),
        storage: StorageType::File,
        max_bytes: config.stream_max_bytes,
        max_age: Duration::from_secs(24 * 60 * 60),
        num_replicas: config.stream_replicas,
        discard: DiscardPolicy::Old,
        metadata: HashMap::from([(OWNER_METADATA_KEY.to_string(), OWNER.to_string())]),
        ..Default::default()
    }
}

/// Decides how to claim and reconcile an existing stream. bmp-collector owns
/// `ARANCINI_CAUSAL` while it runs, so it always writes its claim (whatever claim, if
/// any, the stream carries), keeps the union of existing and required subjects, and
/// sets `max_bytes` and `num_replicas` to the configured values. The stream is a
/// discard-old buffer, so `max_bytes` is reconciled even below the bytes stored: NATS
/// evicts the oldest messages. Every other setting, including other metadata keys, is
/// left as found. Returns `None` when the stream already matches.
fn plan_stream_reconcile(
    existing: &jetstream::stream::Config,
    config: &Config,
) -> Option<StreamReconcile> {
    let mut desired = existing.clone();

    for subject in config.stream_subjects_resolved() {
        if !desired.subjects.contains(&subject) {
            desired.subjects.push(subject);
        }
    }

    desired
        .metadata
        .insert(OWNER_METADATA_KEY.to_string(), OWNER.to_string());
    desired.max_bytes = config.stream_max_bytes;
    desired.num_replicas = config.stream_replicas;
    desired.discard = DiscardPolicy::Old;

    if desired == *existing {
        return None;
    }

    Some(StreamReconcile {
        before: StreamShape::of(existing),
        after: StreamShape::of(&desired),
        config: desired,
    })
}

async fn ensure_stream(config: &Config, js: &jetstream::Context) -> Result<()> {
    // Two passes: a stream created by another component between our lookup and our
    // create is claimed and reconciled on the second pass.
    for _ in 0..2 {
        match js.get_stream(&config.stream_name).await {
            Ok(mut stream) => {
                let info = stream.info().await.with_context(|| {
                    format!("failed reading JetStream stream {}", config.stream_name)
                })?;
                return reconcile_existing_stream(config, js, &info.config, info.state.bytes).await;
            }
            Err(err) if stream_not_found(&err) => {
                match js.create_stream(desired_stream_config(config)).await {
                    Ok(_) => {
                        info!(
                            "created JetStream stream {} owner={} max_bytes={} replicas={}",
                            config.stream_name,
                            OWNER,
                            config.stream_max_bytes,
                            config.stream_replicas
                        );
                        return Ok(());
                    }
                    Err(err) if stream_name_exists(&err) => continue,
                    Err(err) => {
                        return Err(err).with_context(|| {
                            format!("failed creating JetStream stream {}", config.stream_name)
                        });
                    }
                }
            }
            Err(err) => {
                return Err(err).with_context(|| {
                    format!("failed looking up JetStream stream {}", config.stream_name)
                });
            }
        }
    }

    anyhow::bail!(
        "JetStream stream {} was neither found nor creatable",
        config.stream_name
    )
}

async fn reconcile_existing_stream(
    config: &Config,
    js: &jetstream::Context,
    existing: &jetstream::stream::Config,
    stored_bytes: u64,
) -> Result<()> {
    let Some(plan) = plan_stream_reconcile(existing, config) else {
        debug!(
            "JetStream stream {} already claimed and reconciled ({})",
            config.stream_name,
            StreamShape::of(existing)
        );
        return Ok(());
    };

    if u64::try_from(plan.after.max_bytes).is_ok_and(|cap| stored_bytes > cap) {
        warn!(
            "JetStream stream {} stores {} bytes, above the configured max_bytes {}; \
             NATS will evict the oldest messages (discard-old)",
            config.stream_name, stored_bytes, plan.after.max_bytes
        );
    }
    info!(
        "reconciling JetStream stream {} stored_bytes={} before: {} after: {}",
        config.stream_name, stored_bytes, plan.before, plan.after
    );

    js.update_stream(plan.config)
        .await
        .with_context(|| format!("failed updating JetStream stream {}", config.stream_name))?;

    info!(
        "reconciled JetStream stream {} to {}",
        config.stream_name, plan.after
    );
    Ok(())
}

fn stream_not_found(err: &GetStreamError) -> bool {
    matches!(
        err.kind(),
        GetStreamErrorKind::JetStream(js_err) if js_err.error_code() == ErrorCode::STREAM_NOT_FOUND
    )
}

fn stream_name_exists(err: &CreateStreamError) -> bool {
    matches!(
        err.kind(),
        CreateStreamErrorKind::JetStream(js_err) if js_err.error_code() == ErrorCode::STREAM_NAME_EXIST
    )
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_nats::jetstream::stream::RetentionPolicy;

    const GIB: i64 = 1024 * 1024 * 1024;

    fn collector_config(max_bytes: i64, replicas: usize) -> Config {
        serde_json::from_value(serde_json::json!({
            "nats_url": "nats://nats.example.com:4222",
            "stream_max_bytes": max_bytes,
            "stream_replicas": replicas,
        }))
        .expect("valid synthetic config")
    }

    /// An existing `ARANCINI_CAUSAL` as another writer (or an older release) left it.
    fn existing_stream(
        max_bytes: i64,
        replicas: usize,
        owner: Option<&str>,
    ) -> jetstream::stream::Config {
        let mut metadata = HashMap::new();
        if let Some(owner) = owner {
            metadata.insert(OWNER_METADATA_KEY.to_string(), owner.to_string());
        }
        jetstream::stream::Config {
            name: "ARANCINI_CAUSAL".to_string(),
            subjects: vec!["arancini.updates.>".to_string()],
            storage: StorageType::File,
            retention: RetentionPolicy::Limits,
            max_bytes,
            max_age: Duration::from_secs(24 * 60 * 60),
            num_replicas: replicas,
            metadata,
            ..Default::default()
        }
    }

    #[test]
    fn existing_ten_gib_stream_is_reconciled_to_two_gib() {
        let existing = existing_stream(10 * GIB, 1, Some(OWNER));

        let plan = plan_stream_reconcile(&existing, &collector_config(2 * GIB, 1))
            .expect("a 10 GiB stream configured at 2 GiB must be updated");

        assert_eq!(plan.before.max_bytes, 10 * GIB);
        assert_eq!(plan.after.max_bytes, 2 * GIB);
        assert_eq!(plan.config.max_bytes, 2 * GIB);
        assert_eq!(plan.config.discard, DiscardPolicy::Old);
    }

    #[test]
    fn replicas_are_reconciled_on_an_existing_stream() {
        let existing = existing_stream(2 * GIB, 1, Some(OWNER));

        let plan = plan_stream_reconcile(&existing, &collector_config(2 * GIB, 3))
            .expect("a replica change must be applied");

        assert_eq!(plan.before.num_replicas, 1);
        assert_eq!(plan.config.num_replicas, 3);
    }

    #[test]
    fn claim_overrides_an_event_writer_claim() {
        let existing = existing_stream(GIB, 1, Some("event-writer"));

        let plan = plan_stream_reconcile(&existing, &collector_config(2 * GIB, 1))
            .expect("an event-writer claim must be overridden");

        assert_eq!(plan.before.owner.as_deref(), Some("event-writer"));
        assert_eq!(
            plan.config
                .metadata
                .get(OWNER_METADATA_KEY)
                .map(String::as_str),
            Some(OWNER)
        );
        assert_eq!(plan.config.max_bytes, 2 * GIB);

        // Converged: the next start finds its own claim and shape and issues no update.
        assert!(plan_stream_reconcile(&plan.config, &collector_config(2 * GIB, 1)).is_none());
    }

    #[test]
    fn claim_overrides_an_event_writer_claim_even_when_the_shape_matches() {
        let existing = existing_stream(2 * GIB, 1, Some("event-writer"));

        let plan = plan_stream_reconcile(&existing, &collector_config(2 * GIB, 1))
            .expect("the claim alone must trigger an update");

        assert_eq!(
            plan.config
                .metadata
                .get(OWNER_METADATA_KEY)
                .map(String::as_str),
            Some(OWNER)
        );
    }

    #[test]
    fn legacy_stream_without_metadata_is_claimed_without_waiting() {
        let existing = existing_stream(10 * GIB, 1, None);

        let plan = plan_stream_reconcile(&existing, &collector_config(2 * GIB, 1))
            .expect("a legacy stream must be claimed");

        assert_eq!(plan.before.owner, None);
        assert_eq!(plan.after.owner.as_deref(), Some(OWNER));
        assert_eq!(plan.config.max_bytes, 2 * GIB);
    }

    #[test]
    fn claim_and_shrink_preserve_existing_subjects_and_other_metadata() {
        let mut existing = existing_stream(10 * GIB, 1, Some("event-writer"));
        existing.subjects = vec![
            "bgp.causal.extra.>".to_string(),
            "arancini.updates.>".to_string(),
        ];
        existing
            .metadata
            .insert("example.note".to_string(), "kept".to_string());

        let mut config = collector_config(2 * GIB, 1);
        config.stream_subjects = Some(vec!["arancini.peer.>".to_string()]);

        let plan = plan_stream_reconcile(&existing, &config).expect("update planned");

        assert_eq!(plan.after.owner.as_deref(), Some(OWNER));
        assert_eq!(plan.config.max_bytes, 2 * GIB);
        assert_eq!(
            plan.config.subjects,
            vec![
                "bgp.causal.extra.>".to_string(),
                "arancini.updates.>".to_string(),
                "arancini.peer.>".to_string(),
            ]
        );
        assert_eq!(
            plan.config.metadata.get("example.note").map(String::as_str),
            Some("kept")
        );
        assert_eq!(plan.config.max_age, existing.max_age);
        assert_eq!(plan.config.retention, existing.retention);
    }

    #[test]
    fn absent_stream_is_created_claimed_at_the_configured_shape() {
        let created = desired_stream_config(&collector_config(2 * GIB, 3));

        assert_eq!(created.name, "ARANCINI_CAUSAL");
        assert_eq!(created.max_bytes, 2 * GIB);
        assert_eq!(created.num_replicas, 3);
        assert_eq!(created.discard, DiscardPolicy::Old);
        assert_eq!(
            created.metadata.get(OWNER_METADATA_KEY).map(String::as_str),
            Some(OWNER)
        );
        assert_eq!(created.subjects, vec!["arancini.updates.>".to_string()]);
    }
}
