/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use std::collections::BTreeMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use addon_sdk::pb;
use addon_sdk::{
    Addon, CAPABILITY_NATIVE_TELEMETRY_V1, ConfigureResult, Health, HealthStatus, Info,
    SignalSchemaRef, TelemetryBatchBuilder, TelemetryStream, attach_signal_schema_ref,
    ocsf_event_record,
};
use anyhow::{Context, Result};
use async_trait::async_trait;
use prost::Message;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, broadcast};
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::BroadcastStream;

pub mod dnsmessage {
    include!(concat!(env!("OUT_DIR"), "/_.rs"));
}

const ADDON_ID: &str = "powerdns";
const ADDON_VERSION: &str = "0.1.7";
const SOURCE_TYPE: &str = "powerdns";
const DNS_ACTIVITY_SCHEMA_ID: &str = "com.carverauto.powerdns.dns_activity";
const DNS_ACTIVITY_SCHEMA_VERSION: &str = "1.0.0";
const DNS_ACTIVITY_DISPLAY_CONTRACT_ID: &str = "com.carverauto.powerdns.dns_activity.display";
const DNS_ACTIVITY_DISPLAY_CONTRACT_VERSION: &str = "1.1.0";
const DNS_ACTIVITY_DISPLAY_CONTRACT_PATH: &str = "display/dns_activity.display.json";
const DEFAULT_LISTEN_ADDR: &str = "127.0.0.1:6000";
const DEFAULT_SOURCE_INSTANCE: &str = "powerdns";
const DEFAULT_BATCH_QUEUE_SIZE: usize = 1024;
const PRODUCER_CONNECT_GRACE: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    pub enabled: bool,
    pub listen_addr: String,
    pub source_instance: String,
    pub rpz_only: bool,
    pub batch_queue_size: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: true,
            listen_addr: DEFAULT_LISTEN_ADDR.to_owned(),
            source_instance: DEFAULT_SOURCE_INSTANCE.to_owned(),
            rpz_only: true,
            batch_queue_size: DEFAULT_BATCH_QUEUE_SIZE,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct Counters {
    received: u64,
    filtered: u64,
    emitted: u64,
    dropped: u64,
    decode_failures: u64,
    listener_errors: u64,
}

#[derive(Debug, Default)]
struct Degradations {
    listener: Option<String>,
    producer: Option<String>,
    telemetry: Option<String>,
}

impl Degradations {
    fn reason(&self) -> Option<&str> {
        self.listener
            .as_deref()
            .or(self.telemetry.as_deref())
            .or(self.producer.as_deref())
    }
}

#[derive(Debug)]
struct State {
    config: Config,
    config_hash: String,
    listener: Option<tokio::task::JoinHandle<()>>,
    counters: Counters,
    degradations: Degradations,
    generation: u64,
    configured_at: Instant,
    last_producer_activity_at: Option<Instant>,
    active_producer_connections: u64,
}

#[derive(Clone)]
pub struct PowerDnsAddon {
    telemetry_tx: broadcast::Sender<pb::TelemetryBatch>,
    state: Arc<Mutex<State>>,
}

impl Default for PowerDnsAddon {
    fn default() -> Self {
        let config = Config::default();
        let (telemetry_tx, _) = broadcast::channel(config.batch_queue_size);
        Self {
            telemetry_tx,
            state: Arc::new(Mutex::new(State {
                config,
                config_hash: String::new(),
                listener: None,
                counters: Counters::default(),
                degradations: Degradations::default(),
                generation: 0,
                configured_at: Instant::now(),
                last_producer_activity_at: None,
                active_producer_connections: 0,
            })),
        }
    }
}

#[async_trait]
impl Addon for PowerDnsAddon {
    async fn info(&self) -> Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_owned(),
            version: ADDON_VERSION.to_owned(),
            capabilities: vec![CAPABILITY_NATIVE_TELEMETRY_V1.to_owned()],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> Result<ConfigureResult> {
        let config = if config_json.is_empty() {
            Config::default()
        } else {
            serde_json::from_slice(config_json).context("parse powerdns add-on config")?
        };

        let config_hash = hash_config(&config)?;
        let mut state = self.state.lock().await;
        if let Some(handle) = state.listener.take() {
            handle.abort();
        }

        state.config = config.clone();
        state.config_hash = config_hash.clone();
        state.degradations = Degradations::default();
        state.generation = state.generation.wrapping_add(1);
        state.configured_at = Instant::now();
        state.last_producer_activity_at = None;
        state.active_producer_connections = 0;
        let generation = state.generation;

        if config.enabled {
            state.listener = Some(spawn_listener(
                config,
                self.telemetry_tx.clone(),
                Arc::clone(&self.state),
                generation,
            ));
        }

        Ok(ConfigureResult {
            config_hash,
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> Result<Health> {
        let state = self.state.lock().await;
        let (status, degradation_reason) = health_status(&state, Instant::now());

        Ok(Health {
            status,
            version: ADDON_VERSION.to_owned(),
            degradation_reason,
            details: Default::default(),
        })
    }

    fn stream_telemetry(&self) -> TelemetryStream {
        let stream =
            BroadcastStream::new(self.telemetry_tx.subscribe()).filter_map(|item| match item {
                Ok(batch) => Some(Ok(batch)),
                Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(skipped)) => {
                    Some(Err(tonic::Status::resource_exhausted(format!(
                        "powerdns telemetry receiver lagged by {skipped} batches"
                    ))))
                }
            });

        Box::pin(stream)
    }
}

fn spawn_listener(
    config: Config,
    telemetry_tx: broadcast::Sender<pb::TelemetryBatch>,
    state: Arc<Mutex<State>>,
    generation: u64,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        if let Err(err) = run_listener(config, telemetry_tx, Arc::clone(&state), generation).await {
            let mut state = state.lock().await;
            if state.generation == generation {
                state.counters.listener_errors = state.counters.listener_errors.saturating_add(1);
                state.degradations.listener = Some(err.to_string());
            }
        }
    })
}

async fn run_listener(
    config: Config,
    telemetry_tx: broadcast::Sender<pb::TelemetryBatch>,
    state: Arc<Mutex<State>>,
    generation: u64,
) -> Result<()> {
    let listener = TcpListener::bind(&config.listen_addr)
        .await
        .with_context(|| format!("bind PowerDNS protobuf listener {}", config.listen_addr))?;

    loop {
        let (stream, _) = listener.accept().await?;
        {
            let mut state_guard = state.lock().await;
            if !register_producer_connection(&mut state_guard, generation, Instant::now()) {
                return Ok(());
            }
        }

        let config = config.clone();
        let telemetry_tx = telemetry_tx.clone();
        let state = Arc::clone(&state);

        tokio::spawn(async move {
            let result =
                handle_connection(stream, config, telemetry_tx, Arc::clone(&state), generation)
                    .await;

            let mut state_guard = state.lock().await;
            unregister_producer_connection(&mut state_guard, generation, Instant::now());
            if let Err(err) = result
                && state_guard.generation == generation
            {
                state_guard.counters.listener_errors =
                    state_guard.counters.listener_errors.saturating_add(1);
                state_guard.degradations.producer = Some(err.to_string());
            }
        });
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    config: Config,
    telemetry_tx: broadcast::Sender<pb::TelemetryBatch>,
    state: Arc<Mutex<State>>,
    generation: u64,
) -> Result<()> {
    loop {
        let mut length_bytes = [0_u8; 2];
        match stream.read_exact(&mut length_bytes).await {
            Ok(_) => {}
            Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(err) => return Err(err.into()),
        }

        let length = u16::from_be_bytes(length_bytes) as usize;
        if length == 0 {
            continue;
        }

        let mut frame = vec![0_u8; length];
        stream.read_exact(&mut frame).await?;

        let message = match dnsmessage::PbdnsMessage::decode(frame.as_slice()) {
            Ok(message) => message,
            Err(err) => {
                let mut state = state.lock().await;
                if state.generation == generation {
                    state.counters.decode_failures =
                        state.counters.decode_failures.saturating_add(1);
                    state.degradations.producer =
                        Some(format!("decode PowerDNS protobuf frame: {err}"));
                }
                continue;
            }
        };

        let mut state_guard = state.lock().await;
        if state_guard.generation != generation {
            return Ok(());
        }

        state_guard.last_producer_activity_at = Some(Instant::now());
        state_guard.degradations.producer = None;
        state_guard.counters.received = state_guard.counters.received.saturating_add(1);

        let Some(record) = map_message_to_record(&message, &config) else {
            state_guard.counters.filtered = state_guard.counters.filtered.saturating_add(1);
            continue;
        };

        let counters = telemetry_counters(&state_guard.counters, telemetry_tx.receiver_count());
        let batch = TelemetryBatchBuilder::new(SOURCE_TYPE, config.source_instance.clone())
            .source_metadata("listen_addr", config.listen_addr.clone())
            .source_metadata("rpz_only", config.rpz_only.to_string())
            .counters(counters)
            .push_record(record)
            .build();

        match telemetry_tx.send(batch) {
            Ok(_) => {
                state_guard.counters.emitted = state_guard.counters.emitted.saturating_add(1);
                state_guard.degradations.telemetry = None;
            }
            Err(_) => {
                state_guard.counters.dropped = state_guard.counters.dropped.saturating_add(1);
                state_guard.degradations.telemetry =
                    Some("no active telemetry receiver".to_owned());
            }
        }
    }
}

fn register_producer_connection(state: &mut State, generation: u64, now: Instant) -> bool {
    if state.generation != generation {
        return false;
    }

    state.active_producer_connections = state.active_producer_connections.saturating_add(1);
    state.last_producer_activity_at = Some(now);
    state.degradations.producer = None;
    true
}

fn unregister_producer_connection(state: &mut State, generation: u64, now: Instant) {
    if state.generation == generation {
        state.active_producer_connections = state.active_producer_connections.saturating_sub(1);
        if state.active_producer_connections == 0 {
            state.last_producer_activity_at = Some(now);
        }
    }
}

fn health_status(state: &State, now: Instant) -> (HealthStatus, String) {
    if !state.config.enabled {
        return (HealthStatus::Healthy, String::new());
    }

    if let Some(reason) = state.degradations.reason() {
        return (HealthStatus::Degraded, reason.to_owned());
    }

    if state.active_producer_connections > 0 {
        return (HealthStatus::Healthy, String::new());
    }

    let disconnected_since = state
        .last_producer_activity_at
        .unwrap_or(state.configured_at);
    if now.saturating_duration_since(disconnected_since) < PRODUCER_CONNECT_GRACE {
        return (HealthStatus::Healthy, String::new());
    }

    (
        HealthStatus::Degraded,
        format!(
            "no PowerDNS Recursor protobuf producer connected to {} for {}s; configure logging.protobuf_servers",
            state.config.listen_addr,
            PRODUCER_CONNECT_GRACE.as_secs()
        ),
    )
}

fn map_message_to_record(
    message: &dnsmessage::PbdnsMessage,
    config: &Config,
) -> Option<pb::TelemetryRecord> {
    let response = message.response.as_ref();
    if config.rpz_only && !has_policy_hit(response) {
        return None;
    }

    let event_time_unix_nano = message_time_unix_nano(message);
    let event = map_message_to_ocsf(message, config, event_time_unix_nano)?;
    let event_id = event
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let payload = serde_json::to_vec(&event).ok()?;

    let mut record = attach_signal_schema_ref(
        ocsf_event_record(event_id, event_time_unix_nano, now_unix_nano_i64(), payload),
        &SignalSchemaRef {
            producer_id: ADDON_ID.to_owned(),
            producer_version: ADDON_VERSION.to_owned(),
            schema_id: DNS_ACTIVITY_SCHEMA_ID.to_owned(),
            schema_version: DNS_ACTIVITY_SCHEMA_VERSION.to_owned(),
            display_contract_id: DNS_ACTIVITY_DISPLAY_CONTRACT_ID.to_owned(),
            display_contract_version: DNS_ACTIVITY_DISPLAY_CONTRACT_VERSION.to_owned(),
            display_contract: DNS_ACTIVITY_DISPLAY_CONTRACT_PATH.to_owned(),
            signal_type: "event".to_owned(),
            payload_kind: "ocsf_event".to_owned(),
        },
    );
    record.metadata.insert(
        "dns_id".to_owned(),
        message.id.unwrap_or_default().to_string(),
    );
    Some(record)
}

fn map_message_to_ocsf(
    message: &dnsmessage::PbdnsMessage,
    config: &Config,
    event_time_unix_nano: i64,
) -> Option<Value> {
    let activity_id = match message.r#type {
        value if value == dnsmessage::pbdns_message::Type::DnsQueryType as i32 => 1,
        value if value == dnsmessage::pbdns_message::Type::DnsResponseType as i32 => 2,
        _ => return None,
    };

    let response = message.response.as_ref();
    let (action_id, disposition_id, severity_id) = policy_control(response);
    let rcode = response.and_then(|r| r.rcode);
    let status_id = if rcode == Some(65536) { 2 } else { 1 };
    let event_message = dns_event_message(message, response, activity_id);
    let device_name = non_blank(message.device_name.as_deref())
        .or_else(|| non_blank(Some(config.source_instance.as_str())))
        .unwrap_or(SOURCE_TYPE);

    let mut event = json!({
        "id": stable_uuid(message, event_time_unix_nano),
        "time": event_time_unix_nano,
        "class_uid": 4003,
        "category_uid": 4,
        "type_uid": 400300 + activity_id,
        "activity_id": activity_id,
        "activity_name": if activity_id == 1 { "Query" } else { "Response" },
        "severity_id": severity_id,
        "severity": severity_name(severity_id),
        "message": event_message,
        "status_id": status_id,
        "status": if status_id == 1 { "Success" } else { "Failure" },
        "log_name": "pdns.ocsf",
        "log_provider": config.source_instance,
        "actor": {},
        "device": {
            "name": device_name
        },
        "observables": [],
        "query": dns_query(message),
        "src_endpoint": endpoint(message.from.as_deref(), message.from_port),
        "dst_endpoint": endpoint(message.to.as_deref(), message.to_port),
        "connection_info": connection_info(message),
        "metadata": {
            "version": "1.8.0",
            "product": {
                "name": "ServiceRadar PowerDNS Add-on",
                "vendor_name": "Carver Automation"
            }
        },
        "unmapped": source_extras(message)
    });

    if let Some(rcode_value) = rcode {
        event["rcode_id"] = json!(if rcode_value == 65536 {
            99
        } else {
            rcode_value
        });
        event["rcode"] = json!(rcode_name(rcode_value));
    }

    if let Some(response) = response {
        event["answers"] = json!(answers(response));
        event["firewall_rule"] = firewall_rule(response);
    }

    if let Some(object) = event.as_object_mut() {
        object.insert("action_id".to_owned(), json!(action_id));
        object.insert("disposition_id".to_owned(), json!(disposition_id));
    }

    Some(event)
}

fn dns_event_message(
    message: &dnsmessage::PbdnsMessage,
    response: Option<&dnsmessage::pbdns_message::DnsResponse>,
    activity_id: i32,
) -> String {
    let hostname = message
        .question
        .as_ref()
        .and_then(|question| question.q_name.as_deref())
        .map(trim_dns_name)
        .unwrap_or_else(|| "<unknown>".to_owned());

    if let Some(response) = response
        && has_policy_hit(Some(response))
    {
        let policy = non_blank(response.applied_policy.as_deref()).unwrap_or("unknown-policy");
        let kind = response
            .applied_policy_kind
            .and_then(policy_kind_name)
            .unwrap_or("policy");
        return format!("PowerDNS RPZ {kind} match for {hostname} via {policy}");
    }

    if activity_id == 1 {
        format!("PowerDNS DNS query for {hostname}")
    } else {
        let rcode = response
            .and_then(|response| response.rcode)
            .map(rcode_name)
            .unwrap_or("unknown rcode");
        format!("PowerDNS DNS response for {hostname} ({rcode})")
    }
}

fn dns_query(message: &dnsmessage::PbdnsMessage) -> Value {
    let question = message.question.as_ref();
    json!({
        "hostname": question.and_then(|q| q.q_name.as_ref()).map(|name| trim_dns_name(name)),
        "type": question.and_then(|q| q.q_type),
        "class": question.and_then(|q| q.q_class),
        "packet_uid": message.id.map(|id| id.to_string())
    })
}

fn endpoint(raw_ip: Option<&[u8]>, port: Option<u32>) -> Value {
    json!({
        "ip": raw_ip.and_then(ip_addr).map(|ip| ip.to_string()),
        "port": port
    })
}

fn connection_info(message: &dnsmessage::PbdnsMessage) -> Value {
    json!({
        "protocol_num": message.socket_protocol,
        "protocol_name": message.socket_protocol.and_then(protocol_name),
        "direction": "inbound",
        "family": message.socket_family.and_then(socket_family_name)
    })
}

fn answers(response: &dnsmessage::pbdns_message::DnsResponse) -> Vec<Value> {
    response
        .rrs
        .iter()
        .map(|rr| {
            json!({
                "name": rr.name.as_ref().map(|name| trim_dns_name(name)),
                "type": rr.r#type,
                "class": rr.class,
                "ttl": rr.ttl,
                "rdata": rr.rdata.as_ref().map(|data| rr_rdata(rr.r#type, data))
            })
        })
        .collect()
}

fn firewall_rule(response: &dnsmessage::pbdns_message::DnsResponse) -> Value {
    json!({
        "name": response.applied_policy,
        "category": response.applied_policy_type.and_then(policy_type_name),
        "type": response.applied_policy_kind.and_then(policy_kind_name),
        "condition": response.applied_policy_trigger,
        "match_details": match_details(response)
    })
}

fn match_details(response: &dnsmessage::pbdns_message::DnsResponse) -> Vec<Value> {
    response
        .applied_policy_hit
        .as_ref()
        .map(|hit| vec![json!({"value": hit})])
        .unwrap_or_default()
}

fn source_extras(message: &dnsmessage::PbdnsMessage) -> Value {
    let mut extras = BTreeMap::new();
    extras.insert("server_identity", bytes_to_string(&message.server_identity));
    extras.insert("message_id", message.message_id.as_ref().map(hex::encode));
    extras.insert("device_id", bytes_to_string(&message.device_id));
    extras.insert("device_name", message.device_name.clone());
    extras.insert(
        "newly_observed_domain",
        message.newly_observed_domain.map(|value| value.to_string()),
    );
    extras.insert("requestor_id", message.requestor_id.clone());
    json!(extras)
}

fn non_blank(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn policy_control(response: Option<&dnsmessage::pbdns_message::DnsResponse>) -> (u32, u32, u32) {
    match response.and_then(|r| r.applied_policy_kind) {
        Some(kind) if kind == dnsmessage::pbdns_message::PolicyKind::NoAction as i32 => (1, 1, 1),
        Some(kind) if kind == dnsmessage::pbdns_message::PolicyKind::Drop as i32 => (2, 6, 3),
        Some(kind)
            if kind == dnsmessage::pbdns_message::PolicyKind::Nxdomain as i32
                || kind == dnsmessage::pbdns_message::PolicyKind::Nodata as i32
                || kind == dnsmessage::pbdns_message::PolicyKind::Truncate as i32 =>
        {
            (2, 2, 3)
        }
        Some(kind) if kind == dnsmessage::pbdns_message::PolicyKind::Custom as i32 => (2, 7, 3),
        _ => (1, 1, 1),
    }
}

fn has_policy_hit(response: Option<&dnsmessage::pbdns_message::DnsResponse>) -> bool {
    response
        .map(|response| {
            response
                .applied_policy
                .as_ref()
                .is_some_and(|value| !value.is_empty())
                || response
                    .applied_policy_hit
                    .as_ref()
                    .is_some_and(|value| !value.is_empty())
                || response.applied_policy_kind.is_some()
        })
        .unwrap_or(false)
}

fn telemetry_counters(counters: &Counters, receiver_count: usize) -> pb::TelemetryCounters {
    pb::TelemetryCounters {
        received: counters.received,
        filtered: counters.filtered,
        emitted: counters.emitted,
        dropped: counters.dropped,
        queue_depth: receiver_count as u64,
    }
}

fn message_time_unix_nano(message: &dnsmessage::PbdnsMessage) -> i64 {
    let seconds = message.time_sec.unwrap_or_default() as i64;
    let micros = message.time_usec.unwrap_or_default() as i64;
    seconds
        .saturating_mul(1_000_000_000)
        .saturating_add(micros.saturating_mul(1_000))
}

fn now_unix_nano_i64() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
        .unwrap_or_default()
}

fn stable_uuid(message: &dnsmessage::PbdnsMessage, event_time_unix_nano: i64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(message.server_identity.as_deref().unwrap_or_default());
    hasher.update(message.message_id.as_deref().unwrap_or_default());
    hasher.update(message.id.unwrap_or_default().to_be_bytes());
    hasher.update(event_time_unix_nano.to_be_bytes());
    if let Some(question) = &message.question
        && let Some(qname) = &question.q_name
    {
        hasher.update(qname.as_bytes());
    }
    let digest = hasher.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

fn hash_config(config: &Config) -> Result<String> {
    let bytes = serde_json::to_vec(config)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn ip_addr(raw: &[u8]) -> Option<IpAddr> {
    match raw.len() {
        4 => Some(IpAddr::from([raw[0], raw[1], raw[2], raw[3]])),
        16 => {
            let mut bytes = [0_u8; 16];
            bytes.copy_from_slice(raw);
            Some(IpAddr::from(bytes))
        }
        _ => None,
    }
}

fn rr_rdata(rr_type: Option<u32>, data: &[u8]) -> String {
    match (rr_type, ip_addr(data)) {
        (Some(1 | 28), Some(ip)) => ip.to_string(),
        _ => String::from_utf8_lossy(data)
            .trim_end_matches('.')
            .to_owned(),
    }
}

fn trim_dns_name(name: &str) -> String {
    name.trim_end_matches('.').to_owned()
}

fn bytes_to_string(value: &Option<Vec<u8>>) -> Option<String> {
    value.as_ref().map(|bytes| {
        String::from_utf8(bytes.clone())
            .unwrap_or_else(|_| hex::encode(bytes))
            .trim_end_matches('\0')
            .to_owned()
    })
}

fn severity_name(severity_id: u32) -> &'static str {
    match severity_id {
        1 => "Informational",
        2 => "Low",
        3 => "Medium",
        4 => "High",
        5 => "Critical",
        _ => "Unknown",
    }
}

fn rcode_name(rcode: u32) -> &'static str {
    match rcode {
        0 => "NOERROR",
        1 => "FORMERR",
        2 => "SERVFAIL",
        3 => "NXDOMAIN",
        4 => "NOTIMP",
        5 => "REFUSED",
        65536 => "NETWORK_ERROR",
        _ => "UNKNOWN",
    }
}

fn socket_family_name(value: i32) -> Option<&'static str> {
    match value {
        1 => Some("INET"),
        2 => Some("INET6"),
        _ => None,
    }
}

fn protocol_name(value: i32) -> Option<&'static str> {
    match value {
        1 => Some("UDP"),
        2 => Some("TCP"),
        3 => Some("DOT"),
        4 => Some("DOH"),
        5 => Some("DNSCryptUDP"),
        6 => Some("DNSCryptTCP"),
        7 => Some("DOQ"),
        _ => None,
    }
}

fn policy_type_name(value: i32) -> Option<&'static str> {
    match value {
        1 => Some("UNKNOWN"),
        2 => Some("QNAME"),
        3 => Some("CLIENTIP"),
        4 => Some("RESPONSEIP"),
        5 => Some("NSDNAME"),
        6 => Some("NSIP"),
        _ => None,
    }
}

fn policy_kind_name(value: i32) -> Option<&'static str> {
    match value {
        1 => Some("NoAction"),
        2 => Some("Drop"),
        3 => Some("NXDOMAIN"),
        4 => Some("NODATA"),
        5 => Some("Truncate"),
        6 => Some("Custom"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use addon_sdk::{
        SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT, SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID,
        SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION, SIGNAL_SCHEMA_METADATA_PAYLOAD_KIND,
        SIGNAL_SCHEMA_METADATA_PRODUCER_ID, SIGNAL_SCHEMA_METADATA_PRODUCER_VERSION,
        SIGNAL_SCHEMA_METADATA_SCHEMA_ID, SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION,
        SIGNAL_SCHEMA_METADATA_SIGNAL_TYPE,
    };

    fn manifest_root_value<'a>(manifest: &'a str, key: &str) -> &'a str {
        let prefix = format!("{key}:");

        manifest
            .lines()
            .find_map(|line| {
                line.strip_prefix(&prefix)
                    .map(|value| value.trim().trim_matches('"'))
            })
            .unwrap_or_else(|| panic!("manifest is missing root key {key}"))
    }

    fn manifest_signal_value<'a>(manifest: &'a str, schema_id: &str, key: &str) -> &'a str {
        let schema_prefix = format!("  - id: {schema_id}");
        let value_prefix = format!("{key}:");
        let mut selected = false;

        for line in manifest.lines() {
            if line.starts_with("  - id:") {
                selected = line == schema_prefix;
                continue;
            }

            if selected {
                if !line.starts_with("    ") {
                    break;
                }

                if let Some(value) = line.trim().strip_prefix(&value_prefix) {
                    return value.trim().trim_matches('"');
                }
            }
        }

        panic!("manifest schema {schema_id} is missing key {key}")
    }

    #[test]
    fn emitted_dns_ref_matches_the_shipped_manifest_and_contract() {
        let manifest = include_str!("../../../addons/powerdns/addon.yaml");
        let contract: Value = serde_json::from_str(include_str!(
            "../../../addons/powerdns/display/dns_activity.display.json"
        ))
        .expect("dns display contract json");
        let message = dnsmessage::PbdnsMessage {
            r#type: dnsmessage::pbdns_message::Type::DnsResponseType as i32,
            time_sec: Some(1),
            response: Some(dnsmessage::pbdns_message::DnsResponse {
                applied_policy: Some("test-policy".to_owned()),
                applied_policy_kind: Some(dnsmessage::pbdns_message::PolicyKind::Nxdomain as i32),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = map_message_to_record(&message, &Config::default()).expect("record");
        let metadata = &record.metadata;

        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_PRODUCER_ID)
                .map(String::as_str),
            Some(manifest_root_value(manifest, "id"))
        );
        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_PRODUCER_VERSION)
                .map(String::as_str),
            Some(manifest_root_value(manifest, "version"))
        );

        let schema_id = metadata
            .get(SIGNAL_SCHEMA_METADATA_SCHEMA_ID)
            .expect("schema id");

        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION)
                .map(String::as_str),
            Some(manifest_signal_value(manifest, schema_id, "version"))
        );
        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT)
                .map(String::as_str),
            Some(manifest_signal_value(
                manifest,
                schema_id,
                "display_contract"
            ))
        );
        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID)
                .map(String::as_str),
            Some(manifest_signal_value(
                manifest,
                schema_id,
                "display_contract_id"
            ))
        );
        assert_eq!(
            metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION)
                .map(String::as_str),
            Some(manifest_signal_value(
                manifest,
                schema_id,
                "display_contract_version"
            ))
        );
        assert_eq!(contract["schema_id"].as_str(), Some(schema_id.as_str()));
        assert_eq!(
            contract["schema_version"].as_str(),
            metadata
                .get(SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION)
                .map(String::as_str)
        );
        assert_eq!(
            contract["id"].as_str(),
            metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID)
                .map(String::as_str)
        );
        assert_eq!(
            contract["version"].as_str(),
            metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION)
                .map(String::as_str)
        );
    }

    fn health_test_state(now: Instant) -> State {
        State {
            config: Config::default(),
            config_hash: String::new(),
            listener: None,
            counters: Counters::default(),
            degradations: Degradations::default(),
            generation: 7,
            configured_at: now,
            last_producer_activity_at: None,
            active_producer_connections: 0,
        }
    }

    #[test]
    fn health_allows_producer_connection_grace() {
        let now = Instant::now();
        let state = health_test_state(now);

        assert_eq!(health_status(&state, now).0, HealthStatus::Healthy);
    }

    #[test]
    fn health_degrades_when_no_producer_connects() {
        let now = Instant::now();
        let mut state = health_test_state(now);
        state.configured_at = now - PRODUCER_CONNECT_GRACE - Duration::from_secs(1);

        let (status, reason) = health_status(&state, now);

        assert_eq!(status, HealthStatus::Degraded);
        assert!(reason.contains("no PowerDNS Recursor protobuf producer connected"));
        assert!(reason.contains(DEFAULT_LISTEN_ADDR));
        assert!(reason.contains("logging.protobuf_servers"));
    }

    #[test]
    fn active_producer_keeps_health_healthy() {
        let now = Instant::now();
        let mut state = health_test_state(now);
        state.configured_at = now - PRODUCER_CONNECT_GRACE - Duration::from_secs(1);

        assert!(register_producer_connection(&mut state, 7, now));
        assert_eq!(health_status(&state, now).0, HealthStatus::Healthy);
    }

    #[test]
    fn producer_reconnect_clears_transient_error_without_policy_hit() {
        let now = Instant::now();
        let mut state = health_test_state(now);
        state.degradations.producer = Some("connection reset by peer".to_owned());

        assert_eq!(health_status(&state, now).0, HealthStatus::Degraded);
        assert!(register_producer_connection(&mut state, 7, now));

        assert_eq!(state.degradations.producer, None);
        assert_eq!(health_status(&state, now).0, HealthStatus::Healthy);
    }

    #[test]
    fn producer_reconnect_preserves_non_producer_degradations() {
        let now = Instant::now();
        let mut state = health_test_state(now);
        state.degradations.listener = Some("listener failed".to_owned());
        state.degradations.producer = Some("connection reset by peer".to_owned());
        state.degradations.telemetry = Some("no active telemetry receiver".to_owned());

        assert!(register_producer_connection(&mut state, 7, now));

        assert_eq!(state.degradations.producer, None);
        assert_eq!(
            state.degradations.listener.as_deref(),
            Some("listener failed")
        );
        assert_eq!(
            state.degradations.telemetry.as_deref(),
            Some("no active telemetry receiver")
        );
        assert_eq!(
            health_status(&state, now),
            (HealthStatus::Degraded, "listener failed".to_owned())
        );
    }

    #[test]
    fn producer_disconnect_gets_reconnect_grace() {
        let now = Instant::now();
        let mut state = health_test_state(now);
        state.configured_at = now - PRODUCER_CONNECT_GRACE - Duration::from_secs(1);
        assert!(register_producer_connection(&mut state, 7, now));

        unregister_producer_connection(&mut state, 7, now);

        assert_eq!(state.active_producer_connections, 0);
        assert_eq!(health_status(&state, now).0, HealthStatus::Healthy);
        assert_eq!(
            health_status(&state, now + PRODUCER_CONNECT_GRACE).0,
            HealthStatus::Degraded
        );
    }

    #[test]
    fn stale_listener_generation_cannot_change_connection_health() {
        let now = Instant::now();
        let mut state = health_test_state(now);

        assert!(!register_producer_connection(&mut state, 6, now));
        assert_eq!(state.active_producer_connections, 0);

        unregister_producer_connection(&mut state, 6, now);
        assert_eq!(state.active_producer_connections, 0);
        assert_eq!(state.last_producer_activity_at, None);
    }

    #[test]
    fn rpz_response_maps_to_ocsf_dns_activity() {
        let message = dnsmessage::PbdnsMessage {
            r#type: dnsmessage::pbdns_message::Type::DnsResponseType as i32,
            from: Some(vec![192, 168, 2, 10]),
            to: Some(vec![192, 168, 2, 44]),
            from_port: Some(53000),
            to_port: Some(53),
            time_sec: Some(1_812_456_000),
            time_usec: Some(42),
            id: Some(1234),
            question: Some(dnsmessage::pbdns_message::DnsQuestion {
                q_name: Some("bad.example.".to_owned()),
                q_type: Some(1),
                q_class: Some(1),
            }),
            response: Some(dnsmessage::pbdns_message::DnsResponse {
                rcode: Some(3),
                applied_policy: Some("hagezi-pro".to_owned()),
                applied_policy_type: Some(dnsmessage::pbdns_message::PolicyType::Qname as i32),
                applied_policy_trigger: Some("bad.example.".to_owned()),
                applied_policy_hit: Some("bad.example".to_owned()),
                applied_policy_kind: Some(dnsmessage::pbdns_message::PolicyKind::Nxdomain as i32),
                ..Default::default()
            }),
            ..Default::default()
        };

        let record = map_message_to_record(&message, &Config::default()).expect("record");
        let event: Value = serde_json::from_slice(&record.payload).expect("event json");

        assert_eq!(event["class_uid"], 4003);
        assert_eq!(event["category_uid"], 4);
        assert_eq!(event["type_uid"], 400_302);
        assert_eq!(event["query"]["hostname"], "bad.example");
        assert_eq!(event["src_endpoint"]["ip"], "192.168.2.10");
        assert_eq!(event["firewall_rule"]["name"], "hagezi-pro");
        assert_eq!(event["firewall_rule"]["category"], "QNAME");
        assert_eq!(event["firewall_rule"]["type"], "NXDOMAIN");
        assert_eq!(event["action_id"], 2);
        assert_eq!(event["disposition_id"], 2);
        assert_eq!(event["severity_id"], 3);
        assert_eq!(event["log_name"], "pdns.ocsf");
        assert_eq!(event["log_provider"], "powerdns");
        assert_eq!(
            event["message"],
            "PowerDNS RPZ NXDOMAIN match for bad.example via hagezi-pro"
        );
        assert_eq!(event["actor"], json!({}));
        assert_eq!(event["device"], json!({"name": "powerdns"}));
        assert_eq!(event["observables"], json!([]));

        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_PRODUCER_ID),
            Some(&ADDON_ID.to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_PRODUCER_VERSION),
            Some(&ADDON_VERSION.to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_SCHEMA_ID),
            Some(&DNS_ACTIVITY_SCHEMA_ID.to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION),
            Some(&DNS_ACTIVITY_SCHEMA_VERSION.to_owned())
        );
        assert_eq!(
            record
                .metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID),
            Some(&DNS_ACTIVITY_DISPLAY_CONTRACT_ID.to_owned())
        );
        assert_eq!(
            record
                .metadata
                .get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION),
            Some(&DNS_ACTIVITY_DISPLAY_CONTRACT_VERSION.to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT),
            Some(&DNS_ACTIVITY_DISPLAY_CONTRACT_PATH.to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_SIGNAL_TYPE),
            Some(&"event".to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_PAYLOAD_KIND),
            Some(&"ocsf_event".to_owned())
        );
    }

    #[test]
    fn rpz_only_filters_non_policy_messages() {
        let message = dnsmessage::PbdnsMessage {
            r#type: dnsmessage::pbdns_message::Type::DnsResponseType as i32,
            response: Some(dnsmessage::pbdns_message::DnsResponse::default()),
            ..Default::default()
        };

        assert!(map_message_to_record(&message, &Config::default()).is_none());
    }

    #[test]
    fn network_error_rcode_maps_to_failure() {
        let message = dnsmessage::PbdnsMessage {
            r#type: dnsmessage::pbdns_message::Type::DnsResponseType as i32,
            time_sec: Some(1),
            response: Some(dnsmessage::pbdns_message::DnsResponse {
                rcode: Some(65536),
                applied_policy_kind: Some(dnsmessage::pbdns_message::PolicyKind::Drop as i32),
                ..Default::default()
            }),
            ..Default::default()
        };

        let record = map_message_to_record(&message, &Config::default()).expect("record");
        let event: Value = serde_json::from_slice(&record.payload).expect("event json");
        assert_eq!(event["rcode_id"], 99);
        assert_eq!(event["status_id"], 2);
        assert_eq!(event["status"], "Failure");
    }

    #[test]
    fn policy_kinds_map_to_security_control_actions() {
        let cases = [
            (
                dnsmessage::pbdns_message::PolicyKind::NoAction,
                "NoAction",
                1,
                1,
                1,
            ),
            (dnsmessage::pbdns_message::PolicyKind::Drop, "Drop", 2, 6, 3),
            (
                dnsmessage::pbdns_message::PolicyKind::Nxdomain,
                "NXDOMAIN",
                2,
                2,
                3,
            ),
            (
                dnsmessage::pbdns_message::PolicyKind::Nodata,
                "NODATA",
                2,
                2,
                3,
            ),
            (
                dnsmessage::pbdns_message::PolicyKind::Truncate,
                "Truncate",
                2,
                2,
                3,
            ),
            (
                dnsmessage::pbdns_message::PolicyKind::Custom,
                "Custom",
                2,
                7,
                3,
            ),
        ];

        for (kind, kind_name, action_id, disposition_id, severity_id) in cases {
            let message = dnsmessage::PbdnsMessage {
                r#type: dnsmessage::pbdns_message::Type::DnsResponseType as i32,
                time_sec: Some(1),
                id: Some(kind as u32),
                response: Some(dnsmessage::pbdns_message::DnsResponse {
                    applied_policy: Some("test-policy".to_owned()),
                    applied_policy_kind: Some(kind as i32),
                    ..Default::default()
                }),
                ..Default::default()
            };

            let record = map_message_to_record(&message, &Config::default()).expect("record");
            let event: Value = serde_json::from_slice(&record.payload).expect("event json");

            assert_eq!(event["firewall_rule"]["type"], kind_name);
            assert_eq!(event["action_id"], action_id);
            assert_eq!(event["disposition_id"], disposition_id);
            assert_eq!(event["severity_id"], severity_id);
        }
    }
}
