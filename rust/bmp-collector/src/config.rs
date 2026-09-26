use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
    #[serde(default = "default_read_buffer_bytes")]
    pub read_buffer_bytes: usize,
    #[serde(default = "default_max_frame_size_bytes")]
    pub max_frame_size_bytes: usize,
    pub nats_url: String,
    #[serde(default)]
    pub nats_domain: Option<String>,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
    #[serde(default = "default_nats_tls_required")]
    pub nats_tls_required: bool,
    #[serde(default)]
    pub nats_tls_first: bool,
    #[serde(default)]
    pub nats_tls_ca_cert_path: Option<String>,
    #[serde(default)]
    pub nats_tls_client_cert_path: Option<String>,
    #[serde(default)]
    pub nats_tls_client_key_path: Option<String>,
    #[serde(default = "default_stream_name")]
    pub stream_name: String,
    #[serde(default = "default_subject_prefix")]
    pub subject_prefix: String,
    #[serde(default)]
    pub stream_subjects: Option<Vec<String>>,
    #[serde(default = "default_stream_max_bytes")]
    pub stream_max_bytes: i64,
    #[serde(default = "default_stream_replicas")]
    pub stream_replicas: usize,
    #[serde(default = "default_publish_timeout_ms")]
    pub publish_timeout_ms: u64,
}

impl Config {
    /// Loads the JSON config, applies the `SERVICERADAR_JS_<STREAM>_*` environment
    /// overrides and validates the result. Precedence is environment, then JSON, then
    /// the compiled default.
    pub fn from_file(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        Self::from_json_with_env(&content, |name| std::env::var(name).ok())
    }

    fn from_json_with_env(
        content: &str,
        env: impl Fn(&str) -> Option<String>,
    ) -> anyhow::Result<Self> {
        let mut cfg: Config = serde_json::from_str(content)?;
        if cfg.stream_max_bytes <= 0 {
            log::warn!(
                "stream_max_bytes={} is not a finite size; using the default of {} bytes",
                cfg.stream_max_bytes,
                default_stream_max_bytes()
            );
            cfg.stream_max_bytes = default_stream_max_bytes();
        }
        cfg.apply_stream_env_overrides(env)?;
        cfg.validate()?;
        Ok(cfg)
    }

    /// Overrides `stream_max_bytes` and `stream_replicas` from
    /// `SERVICERADAR_JS_<STREAM>_MAX_BYTES` and `SERVICERADAR_JS_<STREAM>_REPLICAS`,
    /// where `<STREAM>` is `stream_name` upper-cased with every non-alphanumeric
    /// character replaced by `_`. An empty or whitespace-only value counts as unset; any
    /// other value that is not a positive integer is an error naming the variable.
    fn apply_stream_env_overrides(
        &mut self,
        env: impl Fn(&str) -> Option<String>,
    ) -> anyhow::Result<()> {
        let prefix = stream_env_prefix(&self.stream_name);

        let max_bytes_var = format!("{prefix}_MAX_BYTES");
        if let Some(raw) = env(&max_bytes_var).filter(|raw| !raw.trim().is_empty()) {
            self.stream_max_bytes = parse_positive_env::<i64>(&max_bytes_var, &raw)?;
        }

        let replicas_var = format!("{prefix}_REPLICAS");
        if let Some(raw) = env(&replicas_var).filter(|raw| !raw.trim().is_empty()) {
            self.stream_replicas = parse_positive_env::<usize>(&replicas_var, &raw)?;
        }

        Ok(())
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen_addr.trim().is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.listen_addr_parsed().is_err() {
            anyhow::bail!("listen_addr must be a valid host:port socket address");
        }
        if self.read_buffer_bytes == 0 {
            anyhow::bail!("read_buffer_bytes must be > 0");
        }
        if self.max_frame_size_bytes < 6 {
            anyhow::bail!("max_frame_size_bytes must be >= 6");
        }
        if self.nats_url.trim().is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.stream_name.trim().is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.subject_prefix.trim().is_empty() {
            anyhow::bail!("subject_prefix is required");
        }
        if self.stream_replicas == 0 {
            anyhow::bail!("stream_replicas must be > 0");
        }
        Ok(())
    }

    pub fn listen_addr_parsed(&self) -> anyhow::Result<SocketAddr> {
        self.listen_addr
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid listen_addr '{}': {}", self.listen_addr, e))
    }

    pub fn stream_subjects_resolved(&self) -> Vec<String> {
        let wildcard = format!("{}.>", self.subject_prefix.trim_end_matches('.'));
        let mut subjects = self
            .stream_subjects
            .clone()
            .unwrap_or_else(|| vec![wildcard.clone()]);

        if !subjects.iter().any(|v| v == &wildcard) {
            subjects.push(wildcard);
        }

        subjects.sort();
        subjects.dedup();
        subjects
    }
}

fn stream_env_prefix(stream_name: &str) -> String {
    let stream: String = stream_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect();
    format!("SERVICERADAR_JS_{stream}")
}

fn parse_positive_env<T>(var: &str, raw: &str) -> anyhow::Result<T>
where
    T: std::str::FromStr + PartialOrd + Default,
{
    match raw.trim().parse::<T>() {
        Ok(value) if value > T::default() => Ok(value),
        _ => anyhow::bail!("{var} must be a positive integer, got {raw:?}"),
    }
}

fn default_listen_addr() -> String {
    "0.0.0.0:11019".to_string()
}

fn default_read_buffer_bytes() -> usize {
    64 * 1024
}

fn default_max_frame_size_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_stream_name() -> String {
    "ARANCINI_CAUSAL".to_string()
}

fn default_subject_prefix() -> String {
    "arancini.updates".to_string()
}

fn default_stream_max_bytes() -> i64 {
    10 * 1024 * 1024 * 1024
}

fn default_stream_replicas() -> usize {
    1
}

fn default_publish_timeout_ms() -> u64 {
    5_000
}

fn default_nats_tls_required() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const GIB: i64 = 1024 * 1024 * 1024;

    fn json_with_stream(max_bytes: Option<i64>, replicas: Option<usize>) -> String {
        let mut value = serde_json::json!({ "nats_url": "nats://nats.example.com:4222" });
        if let Some(max_bytes) = max_bytes {
            value["stream_max_bytes"] = max_bytes.into();
        }
        if let Some(replicas) = replicas {
            value["stream_replicas"] = replicas.into();
        }
        value.to_string()
    }

    fn load(json: &str, vars: &[(&str, &str)]) -> anyhow::Result<Config> {
        let vars: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Config::from_json_with_env(json, |name| vars.get(name).cloned())
    }

    /// Environment, then JSON, then the compiled default, for each field on its own.
    #[test]
    fn stream_size_precedence_is_env_then_json_then_default() {
        let env_over_json = load(
            &json_with_stream(Some(GIB), Some(1)),
            &[
                ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "3221225472"),
                ("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", "3"),
            ],
        )
        .expect("config loads");
        assert_eq!(env_over_json.stream_max_bytes, 3 * GIB);
        assert_eq!(env_over_json.stream_replicas, 3);

        let env_over_default = load(
            &json_with_stream(None, None),
            &[("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", "3")],
        )
        .expect("config loads");
        assert_eq!(env_over_default.stream_replicas, 3);
        assert_eq!(
            env_over_default.stream_max_bytes,
            default_stream_max_bytes()
        );

        let json_over_default =
            load(&json_with_stream(Some(2 * GIB), Some(3)), &[]).expect("config loads");
        assert_eq!(json_over_default.stream_max_bytes, 2 * GIB);
        assert_eq!(json_over_default.stream_replicas, 3);
    }

    #[test]
    fn env_variable_name_follows_configured_stream_name() {
        let json = serde_json::json!({
            "nats_url": "nats://nats.example.com:4222",
            "stream_name": "bgp-updates.v2",
            "stream_max_bytes": GIB,
        })
        .to_string();

        let cfg = load(
            &json,
            &[
                ("SERVICERADAR_JS_BGP_UPDATES_V2_MAX_BYTES", "4096"),
                ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "8192"),
            ],
        )
        .expect("config loads");

        assert_eq!(cfg.stream_max_bytes, 4096);
    }

    #[test]
    fn invalid_env_values_fail_naming_the_variable() {
        for (var, raw) in [
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "abc"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "0"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "-1"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "2G"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", "1.5"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", "abc"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", "0"),
            ("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", "-3"),
        ] {
            let err = load(&json_with_stream(Some(GIB), Some(1)), &[(var, raw)])
                .expect_err(&format!("{var}={raw:?} must fail"));
            assert!(
                err.to_string().contains(var),
                "error for {var}={raw:?} must name the variable, got: {err}"
            );
        }
    }

    #[test]
    fn empty_env_values_count_as_unset() {
        for raw in ["", "   "] {
            let cfg = load(
                &json_with_stream(Some(2 * GIB), Some(3)),
                &[
                    ("SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", raw),
                    ("SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS", raw),
                ],
            )
            .expect("config loads");
            assert_eq!(cfg.stream_max_bytes, 2 * GIB);
            assert_eq!(cfg.stream_replicas, 3);
        }
    }

    #[test]
    fn non_positive_json_stream_size_falls_back_to_the_default() {
        for max_bytes in [-1, 0] {
            let cfg = load(&json_with_stream(Some(max_bytes), None), &[]).expect("config loads");
            assert_eq!(cfg.stream_max_bytes, default_stream_max_bytes());
        }
    }
}
