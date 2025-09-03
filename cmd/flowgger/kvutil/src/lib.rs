use serde::{Deserialize, Serialize};
use std::fs;
use thiserror::Error;
use tokio_stream::StreamExt;
use tonic::transport::{Channel, ClientTlsConfig, Certificate, Identity};

pub mod kvproto { tonic::include_proto!("proto"); }

#[derive(Error, Debug)]
pub enum KvError {
    #[error("not found")] NotFound,
    #[error(transparent)] Other(#[from] Box<dyn std::error::Error + Send + Sync>),
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
        if std::env::var("KV_SEC_MODE").ok().as_deref() == Some("mtls") {
            let cert = fs::read(std::env::var("KV_CERT_FILE").map_err(|e| KvError::Other(e.into()))?)
                .map_err(|e| KvError::Other(e.into()))?;
            let key = fs::read(std::env::var("KV_KEY_FILE").map_err(|e| KvError::Other(e.into()))?)
                .map_err(|e| KvError::Other(e.into()))?;
            let ca = fs::read(std::env::var("KV_CA_FILE").map_err(|e| KvError::Other(e.into()))?)
                .map_err(|e| KvError::Other(e.into()))?;
            let server_name = std::env::var("KV_SERVER_NAME").unwrap_or_else(|_| "kv.serviceradar".to_string());
            let tls = ClientTlsConfig::new()
                .ca_certificate(Certificate::from_pem(ca))
                .identity(Identity::from_pem(cert, key))
                .domain_name(server_name);
            endpoint = endpoint.tls_config(tls).map_err(|e| KvError::Other(e.into()))?;
        }
        let channel = endpoint.connect().await.map_err(|e| KvError::Other(e.into()))?;
        Ok(Self { inner: kvproto::kv_service_client::KvServiceClient::new(channel) })
    }

    pub async fn get(&mut self, key: &str) -> Result<Option<Vec<u8>>> {
        let resp = self.inner.get(kvproto::GetRequest{ key: key.to_string() })
            .await.map_err(|e| KvError::Other(e.into()))?
            .into_inner();
        if resp.found { Ok(Some(resp.value)) } else { Ok(None) }
    }

    pub async fn put_if_absent(&mut self, key: &str, value: Vec<u8>) -> Result<()> {
        if let Some(_) = self.get(key).await? { return Ok(()); }
        self.inner.put(kvproto::PutRequest{ key: key.to_string(), value, ttl_seconds: 0 })
            .await.map_err(|e| KvError::Other(e.into()))?;
        Ok(())
    }

    pub async fn watch_apply<F>(&mut self, key: &str, mut apply: F) -> Result<()>
    where F: FnMut(&[u8]) + Send + 'static {
        let resp = self.inner.watch(kvproto::WatchRequest{ key: key.to_string() })
            .await.map_err(|e| KvError::Other(e.into()))?;
        let mut stream = resp.into_inner();
        tokio::spawn(async move {
            while let Ok(Some(item)) = stream.next().await.transpose() {
                apply(&item.value);
            }
        });
        Ok(())
    }
}

// Deep-merge JSON overlay into a Serialize/Deserialize config object.
pub fn overlay_json<T>(dst: &mut T, overlay: &[u8]) -> Result<()>
where T: Serialize + for<'de> Deserialize<'de> {
    let base_bytes = serde_json::to_vec(dst).map_err(|e| KvError::Other(e.into()))?;
    let mut base: serde_json::Value = serde_json::from_slice(&base_bytes).map_err(|e| KvError::Other(e.into()))?;
    let over: serde_json::Value = serde_json::from_slice(overlay).map_err(|e| KvError::Other(e.into()))?;
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
                    None => { d.insert(k.clone(), v.clone()); }
                }
            }
        }
        (d, s) => { *d = s.clone(); }
    }
}

// Overlay TOML onto an existing config by converting to JSON values and deep-merging.
pub fn overlay_toml<T>(dst: &mut T, overlay: &[u8]) -> Result<()>
where T: Serialize + for<'de> Deserialize<'de> {
    // Parse overlay TOML into T first to ensure schema alignment
    let overlay_str = std::str::from_utf8(overlay).map_err(|e| KvError::Other(e.into()))?;
    let overlay_cfg: T = toml::from_str(overlay_str).map_err(|e| KvError::Other(e.into()))?;
    let base_json = serde_json::to_value(&mut *dst).map_err(|e| KvError::Other(e.into()))?;
    let overlay_json_val = serde_json::to_value(&overlay_cfg).map_err(|e| KvError::Other(e.into()))?;
    let mut merged = base_json;
    merge_values(&mut merged, &overlay_json_val);
    *dst = serde_json::from_value(merged).map_err(|e| KvError::Other(e.into()))?;
    Ok(())
}

