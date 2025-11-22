use serde::{Deserialize, Serialize};
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::error::GrpcClientError;
use spiffe::workload_api::x509_source::X509SourceError;
use spiffe::{
    BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source, X509SourceBuilder,
};
use std::fs;
use std::sync::Arc;
use thiserror::Error;
use tokio::time::{sleep, Duration};
use tokio_stream::StreamExt;
use tonic::transport::{Certificate, Channel, ClientTlsConfig, Identity};

pub mod kvproto {
    tonic::include_proto!("proto");
}

#[derive(Error, Debug)]
pub enum KvError {
    #[error("not found")]
    NotFound,
    #[error(transparent)]
    Other(#[from] Box<dyn std::error::Error + Send + Sync>),
}

pub type Result<T> = std::result::Result<T, KvError>;

pub struct KvClient {
    inner: kvproto::kv_service_client::KvServiceClient<Channel>,
}

impl KvClient {
    pub async fn connect_from_env() -> Result<Self> {
        let addr = std::env::var("KV_ADDRESS").map_err(|e| KvError::Other(e.into()))?;
        let mut endpoint = Channel::from_shared(format!("https://{}", addr))
            .map_err(|e| KvError::Other(e.into()))?;
        let sec_mode = std::env::var("KV_SEC_MODE")
            .unwrap_or_else(|_| String::from("none"))
            .to_lowercase();

        endpoint = match sec_mode.as_str() {
            "mtls" => {
                let cert =
                    fs::read(std::env::var("KV_CERT_FILE").map_err(|e| KvError::Other(e.into()))?)
                        .map_err(|e| KvError::Other(e.into()))?;
                let key =
                    fs::read(std::env::var("KV_KEY_FILE").map_err(|e| KvError::Other(e.into()))?)
                        .map_err(|e| KvError::Other(e.into()))?;
                let ca =
                    fs::read(std::env::var("KV_CA_FILE").map_err(|e| KvError::Other(e.into()))?)
                        .map_err(|e| KvError::Other(e.into()))?;
                let server_name = std::env::var("KV_SERVER_NAME")
                    .unwrap_or_else(|_| "datasvc.serviceradar".to_string());
                let tls = ClientTlsConfig::new()
                    .ca_certificate(Certificate::from_pem(ca))
                    .identity(Identity::from_pem(cert, key))
                    .domain_name(server_name);
                endpoint
                    .tls_config(tls)
                    .map_err(|e| KvError::Other(e.into()))?
            }
            "spiffe" => {
                let trust_domain =
                    std::env::var("KV_TRUST_DOMAIN").map_err(|e| KvError::Other(e.into()))?;
                let workload_socket = std::env::var("KV_WORKLOAD_SOCKET")
                    .unwrap_or_else(|_| "unix:/run/spire/sockets/agent.sock".to_string());
                let tls = load_spiffe_tls(&workload_socket, &trust_domain).await?;
                endpoint
                    .tls_config(tls)
                    .map_err(|e| KvError::Other(e.into()))?
            }
            "none" => endpoint,
            _ => endpoint,
        };

        let channel = endpoint
            .connect()
            .await
            .map_err(|e| KvError::Other(e.into()))?;
        Ok(Self {
            inner: kvproto::kv_service_client::KvServiceClient::new(channel),
        })
    }

    pub async fn get(&mut self, key: &str) -> Result<Option<Vec<u8>>> {
        let resp = self
            .inner
            .get(kvproto::GetRequest {
                key: key.to_string(),
            })
            .await
            .map_err(|e| KvError::Other(e.into()))?
            .into_inner();
        if resp.found {
            Ok(Some(resp.value))
        } else {
            Ok(None)
        }
    }

    pub async fn put(&mut self, key: &str, value: Vec<u8>) -> Result<()> {
        self.inner
            .put(kvproto::PutRequest {
                key: key.to_string(),
                value,
                ttl_seconds: 0,
            })
            .await
            .map_err(|e| KvError::Other(e.into()))?;
        Ok(())
    }

    pub async fn put_if_absent(&mut self, key: &str, value: Vec<u8>) -> Result<()> {
        if self.get(key).await?.is_some() {
            return Ok(());
        }
        self.put(key, value).await
    }

    pub async fn watch_apply<F>(&mut self, key: &str, mut apply: F) -> Result<()>
    where
        F: FnMut(&[u8]) + Send + 'static,
    {
        let resp = self
            .inner
            .watch(kvproto::WatchRequest {
                key: key.to_string(),
            })
            .await
            .map_err(|e| KvError::Other(e.into()))?;
        let mut stream = resp.into_inner();
        tokio::spawn(async move {
            while let Ok(Some(item)) = stream.next().await.transpose() {
                apply(&item.value);
            }
        });
        Ok(())
    }
}

async fn load_spiffe_tls(workload_socket: &str, trust_domain: &str) -> Result<ClientTlsConfig> {
    let retry_delay = Duration::from_secs(2);
    let trust_domain = TrustDomain::try_from(trust_domain).map_err(|e| KvError::Other(e.into()))?;

    loop {
        let client = match WorkloadApiClient::new_from_path(workload_socket).await {
            Ok(client) => client,
            Err(err) => {
                if should_retry_grpc(&err) {
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(KvError::Other(err.into()));
            }
        };

        let source = match X509SourceBuilder::new().with_client(client).build().await {
            Ok(source) => source,
            Err(X509SourceError::GrpcError(grpc_err)) => {
                if should_retry_grpc(&grpc_err) {
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(KvError::Other(grpc_err.into()));
            }
            Err(other) => {
                if is_retryable_source_error(&other) {
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(KvError::Other(other.into()));
            }
        };

        let guard = SpiffeSourceGuard {
            source,
            trust_domain: trust_domain.clone(),
        };

        match guard.tls_materials() {
            Ok((identity, ca)) => {
                let mut tls = ClientTlsConfig::new().ca_certificate(ca).identity(identity);
                if let Ok(server_name) = std::env::var("KV_SERVER_NAME") {
                    if !server_name.trim().is_empty() {
                        tls = tls.domain_name(server_name);
                    }
                }
                return Ok(tls);
            }
            Err(err) if is_retryable_tls_error(&err) => {
                sleep(retry_delay).await;
                continue;
            }
            Err(err) => return Err(KvError::Other(err.into())),
        }
    }
}

struct SpiffeSourceGuard {
    source: Arc<X509Source>,
    trust_domain: TrustDomain,
}

impl SpiffeSourceGuard {
    fn tls_materials(&self) -> std::result::Result<(Identity, Certificate), anyhow::Error> {
        let svid = self
            .source
            .get_svid()
            .map_err(|err| anyhow::anyhow!("failed to fetch default X.509 SVID: {err}"))?
            .ok_or_else(|| anyhow::anyhow!("workload API returned no default X.509 SVID"))?;

        let bundle = self
            .source
            .get_bundle_for_trust_domain(&self.trust_domain)
            .map_err(|err| anyhow::anyhow!("failed to fetch X.509 bundle: {err}"))?
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "no X.509 bundle available for trust domain {}",
                    self.trust_domain
                )
            })?;

        let cert_pem = encode_chain(svid.cert_chain());
        let key_pem = encode_block("PRIVATE KEY", svid.private_key().as_ref());
        let ca_pem = encode_chain(bundle.authorities());

        Ok((
            Identity::from_pem(cert_pem.into_bytes(), key_pem.into_bytes()),
            Certificate::from_pem(ca_pem.into_bytes()),
        ))
    }
}

fn encode_chain(items: &[SpiffeCertificate]) -> String {
    items
        .iter()
        .map(|cert| encode_block("CERTIFICATE", cert.as_ref()))
        .collect()
}

fn encode_block(tag: &str, der: &[u8]) -> String {
    pem::encode(&pem::Pem::new(tag.to_string(), der.to_vec()))
}

fn should_retry_grpc(err: &GrpcClientError) -> bool {
    matches!(
        err,
        GrpcClientError::Grpc(_) | GrpcClientError::Transport(_)
    )
}

fn is_retryable_source_error(err: &X509SourceError) -> bool {
    matches!(err, X509SourceError::NoSuitableSvid)
}

fn is_retryable_tls_error(err: &anyhow::Error) -> bool {
    let msg = err.to_string();
    msg.contains("no default X.509 SVID")
        || msg.contains("failed to fetch default X.509 SVID")
        || msg.contains("no X.509 bundle available")
        || msg.contains("failed to fetch X.509 bundle")
}

// Deep-merge JSON overlay into a Serialize/Deserialize config object.
pub fn overlay_json<T>(dst: &mut T, overlay: &[u8]) -> Result<()>
where
    T: Serialize + for<'de> Deserialize<'de>,
{
    let base_bytes = serde_json::to_vec(dst).map_err(|e| KvError::Other(e.into()))?;
    let mut base: serde_json::Value =
        serde_json::from_slice(&base_bytes).map_err(|e| KvError::Other(e.into()))?;
    let over: serde_json::Value =
        serde_json::from_slice(overlay).map_err(|e| KvError::Other(e.into()))?;
    merge_values(&mut base, &over);
    *dst = serde_json::from_value(base).map_err(|e| KvError::Other(e.into()))?;
    Ok(())
}

fn merge_values(dst: &mut serde_json::Value, src: &serde_json::Value) {
    match (dst, src) {
        (serde_json::Value::Object(d), serde_json::Value::Object(s)) => {
            for (k, v) in s {
                match d.get_mut(k) {
                    Some(dv) => merge_values(dv, v),
                    None => {
                        d.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        (d, s) => {
            *d = s.clone();
        }
    }
}

// Overlay TOML onto an existing config by converting to JSON values and deep-merging.
pub fn overlay_toml<T>(dst: &mut T, overlay: &[u8]) -> Result<()>
where
    T: Serialize + for<'de> Deserialize<'de>,
{
    // Parse overlay TOML into T first to ensure schema alignment
    let overlay_str = std::str::from_utf8(overlay).map_err(|e| KvError::Other(e.into()))?;
    let overlay_cfg: T = toml::from_str(overlay_str).map_err(|e| KvError::Other(e.into()))?;
    let base_json = serde_json::to_value(&mut *dst).map_err(|e| KvError::Other(e.into()))?;
    let mut overlay_json_val =
        serde_json::to_value(&overlay_cfg).map_err(|e| KvError::Other(e.into()))?;
    prune_nulls(&mut overlay_json_val);
    let mut merged = base_json;
    merge_values(&mut merged, &overlay_json_val);
    *dst = serde_json::from_value(merged).map_err(|e| KvError::Other(e.into()))?;
    Ok(())
}

fn prune_nulls(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            let null_keys: Vec<String> = map
                .iter_mut()
                .filter_map(|(k, v)| {
                    prune_nulls(v);
                    if v.is_null() {
                        Some(k.clone())
                    } else {
                        None
                    }
                })
                .collect();
            for k in null_keys {
                map.remove(&k);
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                prune_nulls(v);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize, PartialEq, Serialize)]
    struct SampleCfg {
        foo: String,
        bar: Option<u32>,
    }

    #[test]
    fn overlay_toml_updates_fields_without_clobbering_missing_values() {
        let mut cfg = SampleCfg {
            foo: "hello".into(),
            bar: Some(7),
        };

        overlay_toml(&mut cfg, br#"foo = "world""#).expect("overlay should apply");

        assert_eq!(cfg.foo, "world");
        assert_eq!(cfg.bar, Some(7));
    }

    #[tokio::test]
    async fn spiffe_rejects_invalid_trust_domain() {
        let err = load_spiffe_tls("unix:/nonexistent.sock", "not a trust domain")
            .await
            .unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("invalid trust domain") || msg.contains("BadTrustDomainChar"),
            "expected invalid trust domain error, got {msg}"
        );
    }
}
