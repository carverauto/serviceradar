use anyhow::{Context, Result};
use clap::Parser;
use env_logger::Env;
use log::{debug, info, warn};
use serde::Deserialize;
use serde_json::Value;
use std::{fs, path::PathBuf, time::Duration};

use async_nats::jetstream::{
    self,
    consumer::pull::Config as PullConfig,
    stream::{Config as StreamConfig, StorageType},
    Message,
};
use async_nats::{Client, ConnectOptions};
use futures::StreamExt;
use zen_engine::handler::custom_node_adapter::NoopCustomNode;

use cloudevents::{EventBuilder, EventBuilderV10};
use tonic::{
    transport::{Certificate, Identity, Server, ServerTlsConfig},
    Request, Response, Status,
};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;
use url::Url;
use uuid::Uuid;
use zen_engine::DecisionEngine;

pub mod monitoring {
    tonic::include_proto!("monitoring");
}
use monitoring::agent_service_server::{AgentService, AgentServiceServer};

const FILE_DESCRIPTOR_SET_MONITORING: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/monitoring_descriptor.bin"));

mod kv_loader;
use kv_loader::KvLoader;

type EngineType = DecisionEngine<KvLoader, NoopCustomNode>;
type SharedEngine = std::sync::Arc<EngineType>;

const BATCH_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_RETRIES: i64 = 3;

#[derive(Parser, Debug)]
#[command(name = "serviceradar-zen")]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "ZEN_CONFIG")]
    config: String,
}

#[derive(Debug, Deserialize, Clone)]
struct SecurityConfig {
    cert_file: Option<String>,
    key_file: Option<String>,
    ca_file: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct RuleEntry {
    order: u32,
    key: String,
}

#[derive(Debug, Deserialize, Clone)]
struct DecisionGroupConfig {
    name: String,
    #[serde(default)]
    subjects: Vec<String>,
    #[serde(default)]
    rules: Vec<RuleEntry>,
}

#[derive(Debug, Deserialize, Clone)]
struct Config {
    nats_url: String,
    #[serde(default)]
    domain: Option<String>,
    stream_name: String,
    consumer_name: String,
    #[serde(default)]
    subjects: Vec<String>,
    result_subject: Option<String>,
    result_subject_suffix: Option<String>,
    #[serde(default)]
    decision_keys: Vec<String>,
    #[serde(default)]
    decision_groups: Vec<DecisionGroupConfig>,
    #[serde(default = "default_kv_bucket")]
    kv_bucket: String,
    agent_id: String,
    #[serde(default = "default_listen_addr")]
    listen_addr: String,
    security: Option<SecurityConfig>,
    grpc_security: Option<SecurityConfig>,
}

fn default_kv_bucket() -> String {
    "serviceradar-kv".to_string()
}

fn default_listen_addr() -> String {
    "0.0.0.0:50055".to_string()
}

impl Config {
    fn from_file<P: AsRef<std::path::Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read config file")?;
        let cfg: Config = serde_json::from_str(&content).context("Failed to parse config file")?;
        cfg.validate()?;
        Ok(cfg)
    }

    fn validate(&self) -> Result<()> {
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.consumer_name.is_empty() {
            anyhow::bail!("consumer_name is required");
        }
        if self.decision_keys.is_empty() && self.decision_groups.is_empty() {
            anyhow::bail!("at least one decision_key or decision_group is required");
        }
        if self.agent_id.is_empty() {
            anyhow::bail!("agent_id is required");
        }
        if self.subjects.is_empty() {
            anyhow::bail!("at least one subject is required");
        }
        if let Some(sec) = &self.grpc_security {
            if sec.cert_file.is_none() || sec.key_file.is_none() || sec.ca_file.is_none() {
                anyhow::bail!("grpc_security requires cert_file, key_file, and ca_file");
            }
        }
        Ok(())
    }

    fn ordered_rules_for_subject(&self, subject: &str) -> Vec<String> {
        if !self.decision_groups.is_empty() {
            if let Some(group) = self
                .decision_groups
                .iter()
                .find(|g| g.subjects.is_empty() || g.subjects.iter().any(|s| s == subject))
            {
                let mut rules = group.rules.clone();
                rules.sort_by_key(|r| r.order);
                return rules.into_iter().map(|r| r.key).collect();
            }
        }
        self.decision_keys.clone()
    }
}

async fn connect_nats(cfg: &Config) -> Result<(Client, jetstream::Context)> {
    let mut opts = ConnectOptions::new();
    if let Some(sec) = &cfg.security {
        if let Some(ca) = &sec.ca_file {
            opts = opts.add_root_certificates(PathBuf::from(ca));
        }
        if let (Some(cert), Some(key)) = (&sec.cert_file, &sec.key_file) {
            opts = opts.add_client_certificate(PathBuf::from(cert), PathBuf::from(key));
        }
    }
    let client = opts.connect(&cfg.nats_url).await?;
    info!("connected to nats at {}", cfg.nats_url);
    let js = if let Some(domain) = &cfg.domain {
        jetstream::with_domain(client.clone(), domain)
    } else {
        jetstream::new(client.clone())
    };
    Ok((client, js))
}

async fn build_engine(cfg: &Config, js: &jetstream::Context) -> Result<SharedEngine> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}", cfg.agent_id);
    let loader = KvLoader::new(store, prefix);
    info!("initialized decision engine with bucket {}", cfg.kv_bucket);
    Ok(std::sync::Arc::new(DecisionEngine::new(
        std::sync::Arc::new(loader),
        std::sync::Arc::new(NoopCustomNode::default()),
    )))
}

async fn process_message(
    engine: &SharedEngine,
    cfg: &Config,
    js: &jetstream::Context,
    msg: &Message,
) -> Result<()> {
    debug!("processing message on subject {}", msg.subject);
    let mut context: serde_json::Value = serde_json::from_slice(&msg.payload)?;

    let rules = cfg.ordered_rules_for_subject(&msg.subject);
    let event_type = rules.last().map(String::as_str).unwrap_or("processed");

    for key in &rules {
        let dkey = format!("{}/{}/{}", cfg.stream_name, msg.subject, key);
        let resp = match engine.evaluate(&dkey, context.clone().into()).await {
            Ok(r) => r,
            Err(e) => {
                if let zen_engine::EvaluationError::LoaderError(le) = e.as_ref() {
                    if let zen_engine::loader::LoaderError::NotFound(_) = le.as_ref() {
                        debug!("rule {} not found, skipping", dkey);
                        continue;
                    }
                }
                return Err(anyhow::anyhow!(e.to_string()));
            }
        };
        debug!("decision {} evaluated", dkey);
        context = Value::from(resp.result);
    }

    if !rules.is_empty() {
        let ce = EventBuilderV10::new()
            .id(Uuid::new_v4().to_string())
            .source(Url::parse(&format!(
                "nats://{}/{}",
                cfg.stream_name, msg.subject
            ))?)
            .ty(event_type.to_string())
            .data("application/json", context)
            .build()?;

        let data = serde_json::to_vec(&ce)?;
        if let Some(suffix) = &cfg.result_subject_suffix {
            let result_subject = format!("{}.{}", msg.subject, suffix.trim_start_matches('.'));
            debug!("published result to {}", result_subject);
            js.publish(result_subject, data.into()).await?.await?;
        } else if let Some(subject) = &cfg.result_subject {
            debug!("published result to {}", subject);
            js.publish(subject.clone(), data.into()).await?.await?;
        }
    }

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let (_client, js) = connect_nats(&cfg).await?;
    let stream = match js.get_stream(&cfg.stream_name).await {
        Ok(s) => s,
        Err(_) => {
            let mut subjects = cfg.subjects.clone();
            if let Some(res) = &cfg.result_subject {
                subjects.push(res.clone());
            }
            if let Some(suffix) = &cfg.result_subject_suffix {
                for s in &cfg.subjects {
                    subjects.push(format!("{}.{}", s, suffix.trim_start_matches('.')));
                }
            }
            let sc = StreamConfig {
                name: cfg.stream_name.clone(),
                subjects,
                storage: StorageType::File,
                ..Default::default()
            };
            js.get_or_create_stream(sc).await?
        }
    };
    info!("using stream {}", cfg.stream_name);
    let desired_cfg = PullConfig {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: cfg.subjects.clone(),
        ..Default::default()
    };
    let consumer = match stream.consumer_info(&cfg.consumer_name).await {
        Ok(info) => {
            if info.config.filter_subjects != cfg.subjects {
                warn!(
                    "consumer {} configuration changed, recreating",
                    cfg.consumer_name
                );
                stream
                    .delete_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                stream
                    .create_consumer(desired_cfg.clone())
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            } else {
                stream
                    .get_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            }
        }
        Err(_) => stream
            .create_consumer(desired_cfg.clone())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?,
    };
    info!("using consumer {}", cfg.consumer_name);

    let engine = build_engine(&cfg, &js).await?;
    let watch_engine = engine.clone();
    let watch_cfg = cfg.clone();
    let watch_js = js.clone();
    tokio::spawn(async move {
        if let Err(e) = watch_rules(watch_engine, watch_cfg, watch_js).await {
            warn!("rule watch failed: {e}");
        }
    });

    let grpc_cfg = cfg.clone();
    tokio::spawn(async move {
        if let Err(e) = start_grpc_server(grpc_cfg).await {
            warn!("gRPC server failed: {e}");
        }
    });

    info!("waiting for messages on subjects: {:?}", cfg.subjects);

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(BATCH_TIMEOUT)
            .messages()
            .await?;
        debug!(
            "waiting for up to 10 messages or {:?} timeout",
            BATCH_TIMEOUT
        );
        while let Some(message) = messages.next().await {
            let message = message.map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if let Err(e) = process_message(&engine, &cfg, &js, &message).await {
                warn!("processing failed: {e}");
                match message.info() {
                    Ok(info) if info.delivered >= MAX_RETRIES => {
                        if let Err(e) = message.ack().await {
                            warn!("failed to Ack: {e}");
                        } else {
                            debug!(
                                "acknowledged message {} after {} retries",
                                info.stream_sequence, info.delivered
                            );
                        }
                    }
                    Ok(info) => {
                        if let Err(e) = message.ack_with(jetstream::AckKind::Nak(None)).await {
                            warn!("failed to NAK: {e}");
                        } else {
                            debug!("nacked message {}", info.stream_sequence);
                        }
                    }
                    Err(_) => {
                        if let Err(e) = message.ack_with(jetstream::AckKind::Nak(None)).await {
                            warn!("failed to NAK: {e}");
                        }
                    }
                }
            } else {
                message
                    .ack()
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                if let Ok(info) = message.info() {
                    debug!("acknowledged message {}", info.stream_sequence);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_from_file() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/zen-consumer.json");
        let cfg = Config::from_file(path).unwrap();
        assert_eq!(cfg.nats_url, "nats://127.0.0.1:4222");
        assert_eq!(cfg.domain.as_deref(), Some("edge"));
        assert_eq!(cfg.stream_name, "events");
        assert_eq!(cfg.consumer_name, "zen-consumer");
        assert_eq!(cfg.subjects, vec!["events.syslog", "events.snmp"]);
        assert_eq!(cfg.decision_groups.len(), 2);
        assert_eq!(cfg.decision_groups[0].name, "syslog");
        assert_eq!(cfg.decision_groups[0].subjects, vec!["events.syslog"]);
        assert_eq!(cfg.decision_groups[0].rules[0].key, "strip_full_message");
        assert_eq!(cfg.decision_groups[0].rules[1].key, "cef_severity");
        assert_eq!(cfg.decision_groups[1].name, "snmp");
        assert_eq!(cfg.decision_groups[1].subjects, vec!["events.snmp"]);
        assert_eq!(cfg.decision_groups[1].rules[0].key, "cef_severity");
        assert_eq!(cfg.agent_id, "agent-01");
        assert_eq!(cfg.kv_bucket, "serviceradar-kv");
        assert_eq!(cfg.result_subject_suffix.as_deref(), Some(".processed"));
        assert_eq!(cfg.listen_addr, "0.0.0.0:50055");
        assert!(cfg.grpc_security.is_some());
    }

    #[test]
    fn test_config_validate_missing_fields() {
        let cfg = Config {
            nats_url: String::new(),
            domain: None,
            stream_name: String::new(),
            consumer_name: String::new(),
            subjects: Vec::new(),
            result_subject: None,
            result_subject_suffix: None,
            decision_keys: Vec::new(),
            decision_groups: Vec::new(),
            kv_bucket: String::new(),
            agent_id: String::new(),
            listen_addr: String::new(),
            security: None,
            grpc_security: None,
        };
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_host_switch_testdata_parses() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/host_switch.json");
        let data = fs::read_to_string(path).unwrap();
        let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data).unwrap();
        assert!(!parsed.nodes.is_empty());
    }
}

async fn watch_rules(engine: SharedEngine, cfg: Config, js: jetstream::Context) -> Result<()> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}/{}/", cfg.agent_id, cfg.stream_name);
    let mut watcher = store.watch(format!("{}>", prefix)).await?;
    info!("watching rules under {}", prefix);
    while let Some(entry) = watcher.next().await {
        if let Ok(ref e) = entry {
            debug!(
                "watch event key={} op={:?} rev={}",
                e.key, e.operation, e.revision
            );
        }
        match entry {
            Ok(e) if matches!(e.operation, jetstream::kv::Operation::Put) => {
                let key = e.key.trim_start_matches(&prefix).trim_end_matches(".json");
                if let Err(err) = engine.get_decision(key).await {
                    warn!("failed to reload rule {}: {}", key, err);
                } else {
                    info!("reloaded rule {} revision {}", key, e.revision);
                }
            }
            Ok(_) => {}
            Err(err) => {
                warn!("watch error: {err}");
                break;
            }
        }
    }
    Ok(())
}

#[derive(Debug, Default)]
struct ZenAgentService;

#[tonic::async_trait]
impl AgentService for ZenAgentService {
    async fn get_status(
        &self,
        request: Request<monitoring::StatusRequest>,
    ) -> Result<Response<monitoring::StatusResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        let msg = serde_json::json!({
            "status": "operational",
            "message": "zen-consumer is operational",
        });
        let data = serde_json::to_vec(&msg).unwrap_or_default();
        Ok(Response::new(monitoring::StatusResponse {
            available: true,
            message: data,
            service_name: req.service_name,
            service_type: req.service_type,
            response_time: start.elapsed().as_nanos() as i64,
            agent_id: req.agent_id,
            poller_id: req.poller_id,
        }))
    }

    async fn get_results(
        &self,
        request: Request<monitoring::ResultsRequest>,
    ) -> Result<Response<monitoring::ResultsResponse>, Status> {
        let req = request.into_inner();
        let start = std::time::Instant::now();
        Ok(Response::new(monitoring::ResultsResponse {
            available: true,
            data: vec![],
            service_name: req.service_name,
            service_type: req.service_type,
            response_time: start.elapsed().as_nanos() as i64,
            agent_id: req.agent_id,
            poller_id: req.poller_id,
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64,
        }))
    }
}

async fn start_grpc_server(cfg: Config) -> Result<()> {
    let addr: std::net::SocketAddr = cfg.listen_addr.parse()?;
    let service = ZenAgentService::default();
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter
        .set_serving::<AgentServiceServer<ZenAgentService>>()
        .await;

    let reflection_service = ReflectionBuilder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET_MONITORING)
        .build()?;

    let mut server_builder = Server::builder();
    if let Some(sec) = &cfg.grpc_security {
        if let (Some(cert), Some(key), Some(ca)) = (&sec.cert_file, &sec.key_file, &sec.ca_file) {
            let cert = std::fs::read_to_string(cert)?;
            let key = std::fs::read_to_string(key)?;
            let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
            let ca_cert = std::fs::read_to_string(ca)?;
            let ca = Certificate::from_pem(ca_cert.as_bytes());
            let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
            server_builder = server_builder.tls_config(tls)?;
        }
    }

    server_builder
        .add_service(health_service)
        .add_service(AgentServiceServer::new(service))
        .add_service(reflection_service)
        .serve(addr)
        .await?;

    Ok(())
}
