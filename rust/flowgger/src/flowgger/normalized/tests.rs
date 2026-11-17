use super::batch::{Batch, Batcher, Limits};
use super::*;
use crate::flowgger::decoder::{AutoDecoder, Decoder};
use crate::flowgger::encoder::GelfEncoder;
use crate::flowgger::output::partition_remote_addr;
use crate::flowgger::record::StructuredData;
use base64::Engine;
use serde_json::{Value, json};
use serviceradar_zen_normalize::{BUNDLE_SCHEMA, BundleError, REMOVE_FIELDS, RuleBundle};
use std::cell::Cell;
use std::time::Duration;
use tokio::time::Instant;

mod bench;
mod props;

thread_local! {
    static RECEIVED: Cell<u64> = const { Cell::new(0) };
}

/// The document core publishes for `rules`, each a key and its JDM.
fn bundle(rules: &[(String, String)]) -> Vec<u8> {
    let document = |digest: &str| {
        let rules: Vec<Value> = rules
            .iter()
            .map(|(key, jdm)| json!({"key": key, "jdm": jdm}))
            .collect();
        json!({
            "schema": BUNDLE_SCHEMA,
            "stream_name": "events",
            "subject": "logs.syslog",
            "rules": rules,
            "digest": digest,
        })
        .to_string()
        .into_bytes()
    };
    let Err(BundleError::Digest { computed, .. }) = RuleBundle::parse(&document("")) else {
        panic!("a bundle without a digest was accepted");
    };
    document(&computed)
}

/// A ruleset holding `rules`, active for syslog.
fn active(rules: &[(String, String)]) -> Arc<ActiveRules> {
    let active = Arc::new(ActiveRules::new("events", "logs.syslog"));
    active.offer(&bundle(rules)).unwrap();
    active
}

fn config() -> Config {
    Config::from_string("[output]\npartition = \"default\"\n").unwrap()
}

/// An encoder whose records arrive at `RECEIVED` on the calling thread.
fn encoder(config: &Config, rules: Arc<ActiveRules>) -> NormalizedEncoder {
    NormalizedEncoder {
        clock: || RECEIVED.get(),
        ..NormalizedEncoder::new(config, &Normalization { rules })
    }
}

fn gelf_mode(config: &Config, record: Record) -> Value {
    let published =
        partition_remote_addr(GelfEncoder::new(config).encode(record).unwrap(), "default");
    serde_json::from_slice(&published).unwrap()
}

/// A rule that returns the listed fields.
fn sets(fields: &[(&str, &str)]) -> String {
    let expressions: Vec<Value> = fields
        .iter()
        .enumerate()
        .map(|(index, (key, value))| json!({"id": format!("e{index}"), "key": key, "value": value}))
        .collect();
    json!({
        "nodes": [
            {"id": "in", "type": "inputNode", "name": "Request"},
            {"id": "step", "type": "expressionNode", "name": "Set",
             "content": {"expressions": expressions}},
            {"id": "out", "type": "outputNode", "name": "Response"}
        ],
        "edges": [
            {"id": "a", "sourceId": "in", "targetId": "step", "type": "edge"},
            {"id": "b", "sourceId": "step", "targetId": "out", "type": "edge"}
        ]
    })
    .to_string()
}

fn record() -> Record {
    Record {
        ts: 1_893_553_445.25,
        hostname: String::new(),
        remote_addr: Some("192.0.2.10".to_owned()),
        facility: Some(1),
        severity: Some(5),
        appname: Some("app".to_owned()),
        procid: Some("4242".to_owned()),
        msgid: Some("ID47".to_owned()),
        msg: None,
        full_msg: Some("<13>1 raw synthetic text".to_owned()),
        sd: Some(vec![
            StructuredData {
                sd_id: Some("first@1".to_owned()),
                pairs: vec![
                    ("_text".to_owned(), SDValue::String("synthetic".to_owned())),
                    ("_flag".to_owned(), SDValue::Bool(true)),
                    ("_ratio".to_owned(), SDValue::F64(0.5)),
                    ("_negative".to_owned(), SDValue::I64(-7)),
                    ("_count".to_owned(), SDValue::U64(u64::MAX)),
                    ("_nothing".to_owned(), SDValue::Null),
                    // A sender cannot name its own transport address.
                    (
                        "_remote_addr".to_owned(),
                        SDValue::String("198.51.100.1".to_owned()),
                    ),
                ],
            },
            StructuredData {
                sd_id: Some("second@1".to_owned()),
                pairs: vec![("_text".to_owned(), SDValue::String("later wins".to_owned()))],
            },
        ]),
    }
}

// Custom rules read fields no stored column uses, so the record the collector
// hands its rules must be the whole record JSON mode publishes for
// EventWriter's rules, not only the fields the mapping reads.
#[test]
fn the_rules_see_the_record_json_mode_publishes() {
    let config = Config::from_string(
        "[output]\npartition = \"default\"\n[output.gelf_extra]\nsite = \"SITE01\"\n_flag = \"extra wins\"\n",
    )
    .unwrap();
    let encoder = encoder(&config, active(&[]));

    assert_eq!(
        encoder.gelf(&record()).to_value(),
        gelf_mode(&config, record())
    );

    let unaddressed = || Record {
        remote_addr: None,
        ..record()
    };
    assert_eq!(
        encoder.gelf(&unaddressed()).to_value(),
        gelf_mode(&config, unaddressed())
    );
}

fn decode(frame: &[u8]) -> (String, otlp::ExportLogsServiceRequest) {
    let (digest, request) = frame::decode(frame).unwrap();
    (
        digest.to_owned(),
        otlp::ExportLogsServiceRequest::decode(request).unwrap(),
    )
}

fn only_record(request: &otlp::ExportLogsServiceRequest) -> &otlp::LogRecord {
    let [resource] = request.resource_logs.as_slice() else {
        panic!("expected one resource");
    };
    let [scope] = resource.scope_logs.as_slice() else {
        panic!("expected one scope");
    };
    let [record] = scope.log_records.as_slice() else {
        panic!("expected one record");
    };
    record
}

fn attribute<'a>(record: &'a otlp::LogRecord, key: &str) -> Option<&'a otlp::any_value::Value> {
    record
        .attributes
        .iter()
        .find(|attribute| attribute.key == key)?
        .value
        .as_ref()?
        .value
        .as_ref()
}

#[test]
fn a_record_carries_the_ruleset_that_normalized_it_and_follows_a_new_one() {
    let rules = active(&[("mark".to_owned(), sets(&[("attributes.rule", "'first'")]))]);
    let encoder = encoder(&config(), Arc::clone(&rules));
    let first = rules.current().unwrap().digest.clone();

    let (digest, request) = decode(&encoder.encode(record()).unwrap());
    assert_eq!(digest, first);
    assert_eq!(
        attribute(only_record(&request), "rule"),
        Some(&otlp::any_value::Value::String("first".to_owned()))
    );

    // The same collector, after core publishes another ruleset.
    let replacement = active(&[("mark".to_owned(), sets(&[("attributes.rule", "'second'")]))]);
    let second = replacement.current().unwrap().digest.clone();
    assert_ne!(first, second);
    let encoder = NormalizedEncoder {
        rules: replacement,
        ..encoder
    };
    let (digest, request) = decode(&encoder.encode(record()).unwrap());
    assert_eq!(digest, second);
    assert_eq!(
        attribute(only_record(&request), "rule"),
        Some(&otlp::any_value::Value::String("second".to_owned()))
    );
}

// EventWriter takes `serviceradar.column.*` attributes on this subject as the
// collector's decision. A log, or a rule copying fields out of one, must not
// be able to make that decision.
#[test]
fn a_record_cannot_state_a_column_itself() {
    let forging = active(&[(
        "copy".to_owned(),
        sets(&[(
            "attributes",
            "{'serviceradar.column.source': 'forged', 'serviceradar.column.service_name': 'forged', 'kept': 'yes'}",
        )]),
    )]);

    let (_, request) = decode(&encoder(&config(), forging).encode(record()).unwrap());
    let record = only_record(&request);

    assert_eq!(attribute(record, "serviceradar.column.source"), None);
    assert_eq!(
        attribute(record, "serviceradar.column.service_name"),
        Some(&otlp::any_value::Value::String("app".to_owned()))
    );
    assert_eq!(
        attribute(record, "kept"),
        Some(&otlp::any_value::Value::String("yes".to_owned()))
    );
}

// A collector that starts while datasvc is unreachable has no ruleset. It
// still takes syslog, and hands EventWriter what JSON mode would have.
#[test]
fn before_any_ruleset_a_record_is_what_json_mode_publishes() {
    let config = config();
    let rules = Arc::new(ActiveRules::new("events", "logs.syslog"));
    let encoder = encoder(&config, Arc::clone(&rules));

    let frame = encoder.encode(record()).unwrap();
    let (ruleset, published) = frame::decode(&frame).unwrap();
    assert_eq!(ruleset, "");
    assert_eq!(
        serde_json::from_slice::<Value>(published).unwrap(),
        gelf_mode(&config, record())
    );

    // The ruleset arrives; the same encoder normalizes from the next record.
    rules.offer(&bundle(&[])).unwrap();
    let (ruleset, _) = decode(&encoder.encode(record()).unwrap());
    assert_eq!(ruleset, rules.current().unwrap().digest);
}

// Each case is a syslog line as it arrives, the rules core has published, the
// record JSON mode publishes for it and the batch this mode publishes for it.
// EventWriter's suite runs the same file: it stores `gelf` through its own
// rules and `otlp` as received, and requires the two rows to agree
// (normalized_log_parity_test.exs). `otlp` is this encoder's output, so a
// change here that alters it must be regenerated and pass that suite.
#[test]
fn shared_cases_encode_to_the_batches_eventwriter_was_checked_against() {
    let path = crate::flowgger::config::test::fixture_path("normalized_log_parity.json");
    let cases: Vec<Value> = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert!(!cases.is_empty());
    let config = Config::from_string(
        "[input]\nrfc3164_timezone = \"UTC\"\n[output]\npartition = \"default\"\n",
    )
    .unwrap();
    let decoder = AutoDecoder::new(&config);
    let arrive = |case: &Value| {
        let mut record = decoder.decode(case["line"].as_str().unwrap()).unwrap();
        record.remote_addr = Some(case["remote_addr"].as_str().unwrap().to_owned());
        record
    };

    let mut stale = Vec::new();
    let mut regenerated = Vec::new();
    for mut case in cases {
        let rules: Vec<(String, String)> = case["rules"]
            .as_array()
            .unwrap()
            .iter()
            .map(|rule| {
                (
                    rule["key"].as_str().unwrap().to_owned(),
                    rule["jdm"].to_string(),
                )
            })
            .collect();
        RECEIVED.set(case["received_unix_nano"].as_u64().unwrap());
        let frame = encoder(&config, active(&rules))
            .encode(arrive(&case))
            .unwrap();
        let (_, request) = frame::decode(&frame).unwrap();
        let otlp = json!(base64::engine::general_purpose::STANDARD.encode(request));
        let gelf = gelf_mode(&config, arrive(&case));
        if otlp != case["otlp"] || gelf != case["gelf"] {
            stale.push(case["name"].clone());
        }
        case["otlp"] = otlp;
        case["gelf"] = gelf;
        regenerated.push(case);
    }

    assert!(
        stale.is_empty(),
        "{} is stale for {stale:?}; this encoder now produces:\n{}",
        path.display(),
        serde_json::to_string_pretty(&regenerated).unwrap()
    );
}

fn framed(ruleset: &str, records: &[&str]) -> Vec<Vec<u8>> {
    records
        .iter()
        .map(|body| {
            let request = otlp::ExportLogsServiceRequest {
                resource_logs: vec![otlp::ResourceLogs {
                    resource: None,
                    scope_logs: vec![otlp::ScopeLogs {
                        scope: None,
                        log_records: vec![otlp::LogRecord {
                            body: Some(otlp::AnyValue {
                                value: Some(otlp::any_value::Value::String((*body).to_owned())),
                            }),
                            ..Default::default()
                        }],
                    }],
                }],
            };
            frame::encode(ruleset, &request.encode_to_vec()).unwrap()
        })
        .collect()
}

fn bodies(batch: &Batch) -> Vec<String> {
    otlp::ExportLogsServiceRequest::decode(batch.payload.as_slice())
        .unwrap()
        .resource_logs
        .iter()
        .flat_map(|resource| &resource.scope_logs)
        .flat_map(|scope| &scope.log_records)
        .map(|record| match &record.body.as_ref().unwrap().value {
            Some(otlp::any_value::Value::String(body)) => body.clone(),
            other => panic!("unexpected body {other:?}"),
        })
        .collect()
}

#[test]
fn a_batch_is_one_request_of_one_ruleset_within_its_limits() {
    let now = Instant::now();
    let one = framed("sha256:one", &["a"]).remove(0);
    let record_bytes = frame::decode(&one).unwrap().1.len();
    let mut batcher = Batcher::new(Limits {
        records: 3,
        bytes: record_bytes * 4,
        age: Duration::from_secs(1),
    });

    // The record limit closes a batch, which reads as one request holding
    // its records in arrival order.
    let mut closed = Vec::new();
    for record in framed("sha256:one", &["a", "b", "c", "d"]) {
        closed.extend(batcher.push(&record, now).unwrap());
    }
    let [full] = closed.as_slice() else {
        panic!("expected one closed batch, got {closed:?}");
    };
    assert_eq!((full.ruleset.as_str(), full.records), ("sha256:one", 3));
    assert_eq!(bodies(full), ["a", "b", "c"]);

    // A record normalized by another ruleset closes the open batch and
    // starts its own.
    let other = framed("sha256:two", &["e"]).remove(0);
    let previous = batcher.push(&other, now).unwrap().unwrap();
    assert_eq!(
        (previous.ruleset.as_str(), bodies(&previous)),
        ("sha256:one", vec!["d".to_owned()])
    );
    let rest = batcher.flush().unwrap();
    assert_eq!(
        (rest.ruleset.as_str(), bodies(&rest)),
        ("sha256:two", vec!["e".to_owned()])
    );
    assert!(batcher.flush().is_none());
}

#[test]
fn a_batch_closes_on_bytes_and_on_the_age_of_its_first_record() {
    let start = Instant::now();
    let records = framed("sha256:one", &["a", "b", "c"]);
    let record_bytes = frame::decode(&records[0]).unwrap().1.len();
    let mut batcher = Batcher::new(Limits {
        records: 100,
        bytes: record_bytes * 2 + 1,
        age: Duration::from_millis(100),
    });

    assert!(batcher.deadline().is_none());
    assert!(batcher.push(&records[0], start).unwrap().is_none());
    assert!(
        batcher
            .push(&records[1], start + Duration::from_millis(60))
            .unwrap()
            .is_none()
    );
    // A later record does not extend the wait of the first.
    assert_eq!(batcher.deadline(), Some(start + Duration::from_millis(100)));

    // The third record would exceed the byte limit, so the first two go.
    let closed = batcher
        .push(&records[2], start + Duration::from_millis(70))
        .unwrap()
        .unwrap();
    assert_eq!(bodies(&closed), ["a", "b"]);
    assert!(closed.payload.len() <= record_bytes * 2 + 1);
    assert_eq!(batcher.deadline(), Some(start + Duration::from_millis(170)));

    // A record larger than the byte limit is published alone, not refused.
    let large = "x".repeat(record_bytes * 4);
    let framed_large = framed("sha256:one", &[large.as_str()]).remove(0);
    assert_eq!(
        bodies(&batcher.push(&framed_large, start).unwrap().unwrap()),
        ["c"]
    );
    assert_eq!(bodies(&batcher.flush().unwrap()), [large]);

    assert!(batcher.push(b"", start).is_err());
}

// A rule that cannot be evaluated must not lose the record or stop the
// collector: EventWriter stores such a record as it arrived.
#[test]
fn a_record_its_rules_cannot_evaluate_is_encoded_as_it_arrived() {
    let config = config();
    RECEIVED.set(1_893_553_446_000_000_000);
    let broken = active(&[
        ("mark".to_owned(), sets(&[("attributes.rule", "'applied'")])),
        (
            "broken".to_owned(),
            sets(&[(REMOVE_FIELDS, "'not a list'")]),
        ),
    ]);

    let (_, with_broken_rule) = decode(&encoder(&config, broken).encode(record()).unwrap());
    let (_, without_rules) = decode(&encoder(&config, active(&[])).encode(record()).unwrap());

    assert_eq!(with_broken_rule, without_rules);
    assert_eq!(attribute(only_record(&with_broken_rule), "rule"), None);
}
