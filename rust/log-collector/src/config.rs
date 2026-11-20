use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub flowgger: FlowggerInput,

    #[serde(default)]
    pub otel: OtelInput,

    #[serde(default)]
    pub health: HealthConfig,

    /// When present, the collector keeps the Zen ruleset for one stream and
    /// subject fetched from the store `[rules.nats]` or `[rules.datasvc]` names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rules: Option<RulesConfig>,
}

/// The ruleset the collector follows and the store it reads it from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RulesConfig {
    #[serde(default = "default_rules_stream")]
    pub stream_name: String,

    #[serde(default = "default_rules_subject")]
    pub subject: String,

    /// Whether the collector runs these rules on syslog itself and publishes
    /// normalized batches, instead of leaving the rules to EventWriter. On
    /// unless set to `false`; the `LOG_COLLECTOR_NORMALIZE_SYSLOG` environment
    /// variable overrides it.
    #[serde(default = "default_true")]
    pub normalize: bool,

    /// The NATS rule bucket. Used whenever it is present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nats: Option<NatsRulesConfig>,

    /// The datasvc read when `[rules.nats]` is absent. Supported for one more
    /// release; configure `[rules.nats]` instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub datasvc: Option<DatasvcConfig>,
}

/// Where the collector reads its ruleset from.
#[derive(Debug, Clone)]
pub enum RulesSource<'a> {
    Nats(&'a NatsRulesConfig),
    Datasvc(&'a DatasvcConfig),
}

impl RulesConfig {
    /// The NATS bucket when `[rules.nats]` is present, otherwise datasvc. A
    /// `[rules]` section naming neither cannot be followed.
    pub fn source(&self) -> anyhow::Result<RulesSource<'_>> {
        match (&self.nats, &self.datasvc) {
            (Some(nats), _) => Ok(RulesSource::Nats(nats)),
            (None, Some(datasvc)) => Ok(RulesSource::Datasvc(datasvc)),
            (None, None) => anyhow::bail!(
                "the [rules] section names no store to read the Zen ruleset from; add [rules.nats] with the NATS url"
            ),
        }
    }
}

/// The NATS key-value bucket core publishes rule bundles to, read with the
/// same connection settings as the `[nats]` output of the OTEL collector.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NatsRulesConfig {
    /// NATS server URL, such as `tls://nats.example.com:4222`.
    pub url: String,

    /// The JetStream domain that holds the rules bucket. Leave it unset for a
    /// collector connected to the hub; an edge collector, which reaches the
    /// hub through its leaf, sets the hub's JetStream domain (edge support is
    /// delivered later).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,

    #[serde(default = "default_rules_bucket")]
    pub bucket: String,

    /// NATS credentials file (JWT and seed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creds_file: Option<String>,

    /// Client certificate and the CA that verifies the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls: Option<NatsTlsConfig>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NatsTlsConfig {
    pub cert_file: String,
    pub key_file: String,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ca_file: Option<String>,
}

/// The environment variable that overrides [`RulesConfig::normalize`].
pub const NORMALIZE_SYSLOG_ENV: &str = "LOG_COLLECTOR_NORMALIZE_SYSLOG";

impl Config {
    /// Whether syslog is normalized here. `override_value` is the value of
    /// [`NORMALIZE_SYSLOG_ENV`], if set. Normalizing needs a ruleset to follow.
    pub fn normalize_syslog(&self, override_value: Option<&str>) -> anyhow::Result<bool> {
        let normalize = match override_value.map(str::trim) {
            None | Some("") => self.rules.as_ref().is_some_and(|rules| rules.normalize),
            Some("true") => true,
            Some("false") => false,
            Some(other) => {
                anyhow::bail!("{NORMALIZE_SYSLOG_ENV} must be true or false, not {other:?}")
            }
        };
        if normalize && self.rules.is_none() {
            anyhow::bail!(
                "normalizing syslog needs a [rules] section naming the store to read the ruleset from"
            );
        }
        Ok(normalize)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatasvcConfig {
    /// `host:port` of the datasvc gRPC listener.
    pub address: String,

    /// Client certificate settings. Without them the connection is plaintext.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls: Option<DatasvcTlsConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatasvcTlsConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: String,

    /// The name the datasvc certificate must carry.
    #[serde(default = "default_datasvc_server_name")]
    pub server_name: String,
}

impl DatasvcConfig {
    pub fn endpoint(&self) -> kvutil::KvEndpoint {
        kvutil::KvEndpoint {
            address: self.address.clone(),
            tls: self.tls.as_ref().map(|tls| kvutil::KvTls {
                cert_file: tls.cert_file.clone(),
                key_file: tls.key_file.clone(),
                ca_file: tls.ca_file.clone(),
                server_name: tls.server_name.clone(),
            }),
        }
    }
}

fn default_rules_stream() -> String {
    "events".to_string()
}

fn default_rules_subject() -> String {
    "logs.syslog".to_string()
}

/// The bucket core writes rule bundles to (`ServiceRadar.Observability.Zen.RuleBucket`).
fn default_rules_bucket() -> String {
    "serviceradar-zen-rules".to_string()
}

fn default_datasvc_server_name() -> String {
    "datasvc.serviceradar".to_string()
}

/// Configuration for the unified gRPC health check server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthConfig {
    /// gRPC health server listen address (default "0.0.0.0:50044").
    #[serde(default = "default_health_listen")]
    pub listen_addr: String,
}

impl Default for HealthConfig {
    fn default() -> Self {
        Self {
            listen_addr: default_health_listen(),
        }
    }
}

fn default_health_listen() -> String {
    "0.0.0.0:50044".to_string()
}

/// Configuration for the Flowgger syslog/GELF pipeline.
/// When enabled, Flowgger is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowggerInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the Flowgger TOML config file (its native format).
    #[serde(default = "default_flowgger_config")]
    pub config_file: String,
}

impl Default for FlowggerInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_flowgger_config(),
        }
    }
}

/// Configuration for the OTEL gRPC collector.
/// When enabled, the OTEL collector is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OtelInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the OTEL TOML config file (its native format).
    #[serde(default = "default_otel_config")]
    pub config_file: String,
}

impl Default for OtelInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_otel_config(),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_flowgger_config() -> String {
    "/etc/serviceradar/flowgger.toml".to_string()
}

fn default_otel_config() -> String {
    "/etc/serviceradar/otel.toml".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let config: Config = toml::from_str("").unwrap();
        assert!(config.flowgger.enabled);
        assert!(config.otel.enabled);
        assert_eq!(
            config.flowgger.config_file,
            "/etc/serviceradar/flowgger.toml"
        );
        assert_eq!(config.otel.config_file, "/etc/serviceradar/otel.toml");
        assert_eq!(config.health.listen_addr, "0.0.0.0:50044");
        assert!(config.rules.is_none());
    }

    #[test]
    fn syslog_is_normalized_here_whenever_a_ruleset_is_followed_unless_switched_off() {
        let rules = |normalize: &str| -> Config {
            toml::from_str(&format!(
                "[rules]\n{normalize}\n[rules.datasvc]\naddress = \"datasvc.example.com:50057\"\n"
            ))
            .unwrap()
        };
        let without_rules: Config = toml::from_str("").unwrap();

        // On with a ruleset to follow, unless the file or the override says no.
        assert!(rules("").normalize_syslog(None).unwrap());
        assert!(!rules("normalize = false").normalize_syslog(None).unwrap());
        assert!(!rules("").normalize_syslog(Some("false")).unwrap());
        assert!(
            rules("normalize = false")
                .normalize_syslog(Some("true"))
                .unwrap()
        );
        // No ruleset to follow: syslog goes to EventWriter as before.
        assert!(!without_rules.normalize_syslog(None).unwrap());

        // Asking for it without a ruleset to follow, or unclearly, stops the start.
        assert!(without_rules.normalize_syslog(Some("true")).is_err());
        assert!(rules("").normalize_syslog(Some("yes")).is_err());
    }

    #[test]
    fn a_rules_section_names_the_bundle_and_the_datasvc_to_read_it_from() {
        let config: Config = toml::from_str(
            r#"
            [rules.datasvc]
            address = "datasvc.example.com:50057"

            [rules.datasvc.tls]
            cert_file = "/certs/client.pem"
            key_file = "/certs/client-key.pem"
            ca_file = "/certs/root.pem"
            "#,
        )
        .unwrap();

        let rules = config.rules.unwrap();
        assert_eq!(rules.stream_name, "events");
        assert_eq!(rules.subject, "logs.syslog");
        let RulesSource::Datasvc(datasvc) = rules.source().unwrap() else {
            panic!("a [rules] section with only [rules.datasvc] reads datasvc");
        };
        assert_eq!(
            datasvc.endpoint(),
            kvutil::KvEndpoint {
                address: "datasvc.example.com:50057".to_string(),
                tls: Some(kvutil::KvTls {
                    cert_file: "/certs/client.pem".to_string(),
                    key_file: "/certs/client-key.pem".to_string(),
                    ca_file: "/certs/root.pem".to_string(),
                    server_name: "datasvc.serviceradar".to_string(),
                }),
            }
        );
    }

    #[test]
    fn rules_are_read_from_the_nats_bucket_whenever_one_is_configured() {
        let config: Config = toml::from_str(
            r#"
            [rules.nats]
            url = "tls://nats.example.com:4222"
            domain = "edge_site01"
            creds_file = "/creds/collector.creds"

            [rules.nats.tls]
            cert_file = "/certs/client.pem"
            key_file = "/certs/client-key.pem"
            ca_file = "/certs/root.pem"

            [rules.datasvc]
            address = "datasvc.example.com:50057"
            "#,
        )
        .unwrap();

        let rules = config.rules.unwrap();
        let RulesSource::Nats(nats) = rules.source().unwrap() else {
            panic!("[rules.nats] takes precedence over [rules.datasvc]");
        };
        assert_eq!(
            nats,
            &NatsRulesConfig {
                url: "tls://nats.example.com:4222".to_string(),
                domain: Some("edge_site01".to_string()),
                bucket: "serviceradar-zen-rules".to_string(),
                creds_file: Some("/creds/collector.creds".to_string()),
                tls: Some(NatsTlsConfig {
                    cert_file: "/certs/client.pem".to_string(),
                    key_file: "/certs/client-key.pem".to_string(),
                    ca_file: Some("/certs/root.pem".to_string()),
                }),
            }
        );
    }

    #[test]
    fn a_rules_section_naming_no_store_cannot_be_followed() {
        let config: Config = toml::from_str("[rules]\nsubject = \"logs.syslog\"\n").unwrap();

        let error = config.rules.unwrap().source().unwrap_err().to_string();

        assert!(error.contains("[rules.nats]"), "{error}");
    }

    #[test]
    fn test_disable_otel() {
        let config: Config = toml::from_str(
            r#"
            [otel]
            enabled = false
            "#,
        )
        .unwrap();
        assert!(config.flowgger.enabled);
        assert!(!config.otel.enabled);
    }

    #[test]
    fn test_custom_paths() {
        let config: Config = toml::from_str(
            r#"
            [flowgger]
            config_file = "/custom/flowgger.toml"

            [otel]
            config_file = "/custom/otel.toml"
            "#,
        )
        .unwrap();
        assert_eq!(config.flowgger.config_file, "/custom/flowgger.toml");
        assert_eq!(config.otel.config_file, "/custom/otel.toml");
    }
}
