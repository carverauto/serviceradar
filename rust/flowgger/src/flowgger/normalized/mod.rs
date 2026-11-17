//! Syslog normalized at the collector and published as OTLP log batches.
//!
//! In this mode a record is run through the Zen ruleset core publishes, turned
//! into the OTLP log record EventWriter stores ([`row`]), and published in
//! batches on `logs.normalized.<kind>`, where EventWriter stores it without
//! running the rules again. The JSON mode publishes each record as GELF on
//! `logs.<kind>` and leaves the rules to EventWriter.
//!
//! The collector never waits for a ruleset. Until the first one arrives a
//! record is published as JSON mode would publish it, so EventWriter applies
//! the rules; a ruleset once active stays active, so this only happens after
//! a start while datasvc cannot be reached.
//!
//! The encoder runs on the input threads and emits one [`frame`] per record:
//! the digest of the ruleset that normalized it, then a complete
//! `ExportLogsServiceRequest` holding that one record. Serialized protobuf
//! messages concatenate into their merge, so the NATS output builds a batch by
//! appending the frames' requests ([`batch`]) and never decodes one.

pub(crate) mod batch;
pub(crate) mod frame;
mod otlp;
mod row;

#[cfg(test)]
mod tests;

use crate::flowgger::config::Config;
use crate::flowgger::encoder::{Encoder, GelfEncoder};
use crate::flowgger::output::partition_remote_addr;
use crate::flowgger::record::{Record, SDValue};
use prost::Message;
use serviceradar_zen_normalize::{ActiveRules, Variable, float, number};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// The header naming the schema of a normalized batch, and its value.
pub(crate) const SCHEMA_HEADER: (&str, &str) = ("Sr-Log-Schema", "otlp-normalized-v1");
/// The header naming the version of the normalization contract.
pub(crate) const NORMALIZATION_VERSION_HEADER: (&str, &str) = ("Sr-Normalization-Version", "1");
/// The header carrying the digest of the ruleset a batch was normalized with.
pub(crate) const RULESET_HEADER: &str = "Sr-Ruleset-Id";
/// Routing epoch 0 is the single unsharded route.
pub(crate) const ROUTING_EPOCH_HEADER: (&str, &str) = ("Sr-Routing-Epoch", "0");

/// What the embedding collector supplies to normalize syslog itself.
#[derive(Clone)]
pub struct Normalization {
    /// The ruleset to normalize with, once one is active.
    pub rules: Arc<ActiveRules>,
}

impl Normalization {
    /// The subject normalized batches of `subject` are published on:
    /// `logs.syslog` becomes `logs.normalized.syslog`.
    pub fn subject(subject: &str) -> Result<String, String> {
        match subject.strip_prefix("logs.") {
            Some(kind) if !kind.is_empty() && !kind.starts_with("normalized.") => {
                Ok(format!("logs.normalized.{kind}"))
            }
            _ => Err(format!(
                "output.nats_subject {subject:?} has no normalized form; expected logs.<kind>"
            )),
        }
    }
}

/// Encodes a record as a [`frame`].
#[derive(Clone)]
pub(crate) struct NormalizedEncoder {
    rules: Arc<ActiveRules>,
    json_mode: GelfEncoder,
    partition: String,
    extra: Vec<(String, String)>,
    clock: fn() -> u64,
}

impl NormalizedEncoder {
    pub(crate) fn new(config: &Config, normalization: &Normalization) -> Self {
        let extra = match config.lookup("output.gelf_extra") {
            None => Vec::new(),
            Some(extra) => extra
                .as_table()
                .expect("output.gelf_extra must be a list of key/value pairs")
                .iter()
                .map(|(key, value)| {
                    (
                        key.to_owned(),
                        value
                            .as_str()
                            .expect("output.gelf_extra values must be strings")
                            .to_owned(),
                    )
                })
                .collect(),
        };
        let partition = config
            .lookup("output.partition")
            .map_or("default", |value| {
                value.as_str().expect("output.partition must be a string")
            })
            .to_owned();
        Self {
            rules: Arc::clone(&normalization.rules),
            json_mode: GelfEncoder::new(config),
            partition,
            extra,
            clock: unix_nanos_now,
        }
    }

    /// The record as the JSON mode publishes it: the GELF fields, with the
    /// sender address under its partition.
    fn gelf(&self, record: &Record) -> Variable {
        let fields = Variable::empty_object();
        let Variable::Object(map) = &fields else {
            unreachable!("an empty object is an object")
        };
        let mut map = map.borrow_mut();
        let string = |text: &str| Variable::String(Variable::key(text));
        map.insert(Variable::key("version"), string("1.1"));
        let host = if record.hostname.is_empty() {
            "unknown"
        } else {
            &record.hostname
        };
        map.insert(Variable::key("host"), string(host));
        map.insert(
            Variable::key("short_message"),
            string(record.msg.as_deref().unwrap_or("-")),
        );
        map.insert(Variable::key("timestamp"), float(record.ts));
        if let Some(severity) = record.severity {
            map.insert(Variable::key("level"), number(u64::from(severity)));
        }
        if let Some(full_msg) = &record.full_msg {
            map.insert(Variable::key("full_message"), string(full_msg));
        }
        if let Some(appname) = &record.appname {
            map.insert(Variable::key("application_name"), string(appname));
        }
        if let Some(procid) = &record.procid {
            map.insert(Variable::key("process_id"), string(procid));
        }
        for sd in record.sd.iter().flatten() {
            if let Some(sd_id) = &sd.sd_id {
                map.insert(Variable::key("sd_id"), string(sd_id));
            }
            for (name, value) in &sd.pairs {
                let value = match value {
                    SDValue::String(value) => string(value),
                    SDValue::Bool(value) => Variable::Bool(*value),
                    SDValue::F64(value) => float(*value),
                    SDValue::I64(value) => number(*value),
                    SDValue::U64(value) => number(*value),
                    SDValue::Null => Variable::Null,
                };
                map.insert(Variable::key(name), value);
            }
        }
        for (name, value) in &self.extra {
            map.insert(Variable::key(name), string(value));
        }
        // Transport provenance takes precedence over structured data and extras.
        match &record.remote_addr {
            Some(addr) => {
                let addr = format!("{}:{addr}", self.partition);
                map.insert(Variable::key("_remote_addr"), string(&addr));
            }
            None => {
                map.remove_str("_remote_addr");
            }
        }
        drop(map);
        fields
    }
}

impl Encoder for NormalizedEncoder {
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let Some(bundle) = self.rules.current() else {
            let published = partition_remote_addr(self.json_mode.encode(record)?, &self.partition);
            return frame::encode("", &published);
        };
        let received = (self.clock)();
        // A record the rules cannot evaluate, or turn into something that is
        // not an object, is stored as it arrived. EventWriter does the same.
        let normalized = match bundle.rules.normalize(self.gelf(&record)) {
            Ok(normalized) => normalized.to_value(),
            Err(error) => {
                report_rule_failure(&error);
                serde_json::Value::Null
            }
        };
        let normalized = match normalized {
            serde_json::Value::Object(fields) => fields,
            _ => match self.gelf(&record).to_value() {
                serde_json::Value::Object(fields) => fields,
                _ => return Err("A syslog record did not encode as an object"),
            },
        };
        let request = otlp::ExportLogsServiceRequest {
            resource_logs: vec![row::resource_logs(&normalized, received)],
        };
        frame::encode(&bundle.digest, &request.encode_to_vec())
    }
}

fn unix_nanos_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|elapsed| u64::try_from(elapsed.as_nanos()).ok())
        .unwrap_or_default()
}

/// Says that a rule is failing, at most once every ten seconds: a broken rule
/// fails for every record.
fn report_rule_failure(error: &serviceradar_zen_normalize::Error) {
    static LAST_REPORT: AtomicU64 = AtomicU64::new(0);
    let now = unix_nanos_now() / 1_000_000_000;
    let last = LAST_REPORT.load(Ordering::Relaxed);
    if now >= last.saturating_add(10)
        && LAST_REPORT
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
    {
        log::warn!("Storing syslog records without normalization: {error}");
    }
}
