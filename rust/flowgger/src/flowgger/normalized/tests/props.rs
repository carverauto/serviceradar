//! Properties of the normalized path, checked over generated input (Hegel).

use super::*;
use hegel::TestCase;
use hegel::generators as gs;

fn finite() -> gs::FloatGenerator<f64> {
    gs::floats::<f64>().allow_nan(false).allow_infinity(false)
}

fn sd_value(tc: &TestCase) -> SDValue {
    match tc.draw(gs::integers::<u8>().max_value(5)) {
        0 => SDValue::String(tc.draw(gs::text())),
        1 => SDValue::Bool(tc.draw(gs::booleans())),
        2 => SDValue::F64(tc.draw(finite())),
        3 => SDValue::I64(tc.draw(gs::integers::<i64>())),
        4 => SDValue::U64(tc.draw(gs::integers::<u64>())),
        _ => SDValue::Null,
    }
}

/// Field names a sender can collide on, and any other name.
fn field_name(tc: &TestCase) -> String {
    const KNOWN: [&str; 8] = [
        "_remote_addr",
        "host",
        "short_message",
        "timestamp",
        "level",
        "sd_id",
        "site",
        "version",
    ];
    if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(KNOWN.as_slice())).to_owned()
    } else {
        tc.draw(gs::text())
    }
}

fn structured_data(tc: &TestCase) -> StructuredData {
    let pairs = tc.draw(gs::integers::<usize>().max_value(4));
    StructuredData {
        sd_id: tc.draw(gs::optional(gs::text())),
        pairs: (0..pairs).map(|_| (field_name(tc), sd_value(tc))).collect(),
    }
}

fn any_record(tc: &TestCase) -> Record {
    let elements = tc.draw(gs::optional(gs::integers::<usize>().max_value(3)));
    Record {
        ts: tc.draw(finite()),
        hostname: tc.draw(gs::text()),
        remote_addr: tc.draw(gs::optional(gs::text())),
        facility: tc.draw(gs::optional(gs::integers::<u8>())),
        severity: tc.draw(gs::optional(gs::integers::<u8>())),
        appname: tc.draw(gs::optional(gs::text())),
        procid: tc.draw(gs::optional(gs::text())),
        msgid: tc.draw(gs::optional(gs::text())),
        msg: tc.draw(gs::optional(gs::text())),
        full_msg: tc.draw(gs::optional(gs::text())),
        sd: elements.map(|count| (0..count).map(|_| structured_data(tc)).collect()),
    }
}

fn copy(record: &Record) -> Record {
    let value = |value: &SDValue| match value {
        SDValue::String(value) => SDValue::String(value.clone()),
        SDValue::Bool(value) => SDValue::Bool(*value),
        SDValue::F64(value) => SDValue::F64(*value),
        SDValue::I64(value) => SDValue::I64(*value),
        SDValue::U64(value) => SDValue::U64(*value),
        SDValue::Null => SDValue::Null,
    };
    Record {
        ts: record.ts,
        hostname: record.hostname.clone(),
        remote_addr: record.remote_addr.clone(),
        facility: record.facility,
        severity: record.severity,
        appname: record.appname.clone(),
        procid: record.procid.clone(),
        msgid: record.msgid.clone(),
        msg: record.msg.clone(),
        full_msg: record.full_msg.clone(),
        sd: record.sd.as_ref().map(|elements| {
            elements
                .iter()
                .map(|sd| StructuredData {
                    sd_id: sd.sd_id.clone(),
                    pairs: sd
                        .pairs
                        .iter()
                        .map(|(name, pair)| (name.clone(), value(pair)))
                        .collect(),
                })
                .collect()
        }),
    }
}

/// The JSON text of `value`, read back: both sides of a comparison then pass
/// through the same number parser.
fn as_published(value: &Value) -> Value {
    serde_json::from_slice(&serde_json::to_vec(value).unwrap()).unwrap()
}

/// Custom rules read any field, so for every record a decoder can produce the
/// collector's rules get exactly the record JSON mode publishes.
#[hegel::test]
fn the_rules_see_what_json_mode_publishes_for_any_record(tc: TestCase) {
    let config = Config::from_string(
        "[output]\npartition = \"default\"\n[output.gelf_extra]\nsite = \"SITE01\"\n",
    )
    .unwrap();
    let record = any_record(&tc);
    let encoder = encoder(&config, active(&[]));

    assert_eq!(
        as_published(&encoder.gelf(&record).to_value()),
        gelf_mode(&config, copy(&record))
    );
}

fn framed_record(ruleset: &str, body: &str) -> Vec<u8> {
    framed(ruleset, &[body]).pop().unwrap()
}

/// Whatever arrives and whatever the limits, the batches hold every record
/// once and in order, each batch is of one ruleset and decodes to its
/// records, and a batch exceeds a limit only by being one oversized record.
#[hegel::test]
fn batches_keep_every_record_in_order_within_their_limits(tc: TestCase) {
    const RULESETS: [&str; 3] = ["sha256:a", "sha256:b", "sha256:c"];
    let limits = Limits {
        records: tc.draw(gs::integers::<usize>().min_value(1).max_value(8)),
        bytes: tc.draw(gs::integers::<usize>().min_value(1).max_value(200)),
        age: Duration::from_secs(1),
    };
    let count = tc.draw(gs::integers::<usize>().max_value(40));
    let arrived: Vec<(&str, String)> = (0..count)
        .map(|index| {
            let ruleset = tc.draw(gs::sampled_from(RULESETS.as_slice()));
            let padding = tc.draw(gs::integers::<usize>().max_value(60));
            (ruleset, format!("{index}:{}", "x".repeat(padding)))
        })
        .collect();

    let now = Instant::now();
    let mut batcher = Batcher::new(limits);
    let mut closed = Vec::new();
    for (ruleset, body) in &arrived {
        closed.extend(batcher.push(&framed_record(ruleset, body), now).unwrap());
    }
    closed.extend(batcher.flush());
    assert_eq!(batcher.flush(), None);

    let mut delivered = Vec::new();
    for batch in &closed {
        let records = bodies(batch);
        assert_eq!(records.len(), batch.records);
        assert!(batch.records >= 1 && batch.records <= limits.records);
        assert!(batch.payload.len() <= limits.bytes || batch.records == 1);
        delivered.extend(
            records
                .into_iter()
                .map(|body| (batch.ruleset.clone(), body)),
        );
    }
    let arrived: Vec<(String, String)> = arrived
        .into_iter()
        .map(|(ruleset, body)| (ruleset.to_owned(), body))
        .collect();
    assert_eq!(delivered, arrived);
}

/// Text the mapping parses: numbers of any length, times, and anything else.
fn any_text(tc: &TestCase) -> String {
    match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => tc.draw(gs::from_regex("[+-]?([0-9]{1,6}|[0-9]{36,45})[a-z .]?")),
        1 => tc.draw(gs::datetime_strings()),
        2 => tc.draw(gs::from_regex("[0-9a-fA-F]{0,40}")),
        _ => tc.draw(gs::text()),
    }
}

fn any_json(tc: &TestCase, depth: u8) -> Value {
    let kinds = if depth == 0 { 5 } else { 7 };
    match tc.draw(gs::integers::<u8>().max_value(kinds)) {
        0 => Value::Null,
        1 => Value::Bool(tc.draw(gs::booleans())),
        2 => json!(tc.draw(gs::integers::<i64>())),
        3 => json!(tc.draw(gs::integers::<u64>())),
        4 => json!(tc.draw(finite())),
        5 => Value::String(any_text(tc)),
        6 => {
            let items = tc.draw(gs::integers::<usize>().max_value(3));
            Value::Array((0..items).map(|_| any_json(tc, depth - 1)).collect())
        }
        _ => Value::Object(any_object(tc, depth - 1)),
    }
}

/// Fields the row mapping reads, and any other field.
fn any_object(tc: &TestCase, depth: u8) -> serde_json::Map<String, Value> {
    const READ: [&str; 22] = [
        "timestamp",
        "time_unix_nano",
        "observed_timestamp",
        "observedTimeUnixNano",
        "level",
        "severity",
        "severity_text",
        "severity_number",
        "short_message",
        "message",
        "body",
        "attributes",
        "resource_attributes",
        "scope_attributes",
        "service_name",
        "trace_id",
        "span_id",
        "trace_flags",
        "event_name",
        "_remote_addr",
        "_syslog_format",
        "serviceradar_remove_fields",
    ];
    let fields = tc.draw(gs::integers::<usize>().max_value(6));
    (0..fields)
        .map(|_| {
            let name = if tc.draw(gs::booleans()) {
                tc.draw(gs::sampled_from(READ.as_slice())).to_owned()
            } else {
                tc.draw(gs::text())
            };
            // A parsed field is text half the time: that is where the parsing is.
            let value = if tc.draw(gs::booleans()) {
                Value::String(any_text(tc))
            } else {
                any_json(tc, depth)
            };
            (name, value)
        })
        .collect()
}

/// A rule can return any JSON object. Each one maps to a single record that
/// survives the wire encoding; none makes the collector panic.
#[hegel::test(test_cases = 1000)]
fn any_object_a_rule_returns_maps_to_one_record(tc: TestCase) {
    let normalized = any_object(&tc, 2);
    let received = tc.draw(gs::integers::<u64>());

    let request = otlp::ExportLogsServiceRequest {
        resource_logs: vec![row::resource_logs(&normalized, received)],
    };
    let decoded =
        otlp::ExportLogsServiceRequest::decode(request.encode_to_vec().as_slice()).unwrap();

    assert_eq!(decoded, request);
    only_record(&decoded);
}

fn boolean(record: &otlp::LogRecord, key: &str) -> Option<bool> {
    match attribute(record, key) {
        Some(otlp::any_value::Value::Bool(value)) => Some(*value),
        None => None,
        other => panic!("unexpected {key} {other:?}"),
    }
}

/// The stored time is the sender's, or the receive time when the sender's
/// clock cannot be right; a record says it fell back exactly when it did.
/// The limits are the ones the log-normalization spec states: one hour either
/// way for RFC 3164, a day ahead and thirty days behind for zoned formats,
/// compared on whole seconds, and no time before 1970.
#[hegel::test]
fn the_stored_time_is_the_senders_unless_its_clock_is_wrong(tc: TestCase) {
    const HOUR: i64 = 3_600;
    let received_seconds = tc.draw(
        gs::integers::<i64>()
            .min_value(1_000_000_000)
            .max_value(4_000_000_000),
    );
    let received_nanos = tc.draw(gs::integers::<u64>().max_value(999_999_999));
    // Near each limit as often as far from all of them.
    let offset = match tc.draw(gs::integers::<u8>().max_value(4)) {
        0 => tc.draw(
            gs::integers::<i64>()
                .min_value(-HOUR - 3)
                .max_value(HOUR + 3),
        ),
        1 => 24 * HOUR + tc.draw(gs::integers::<i64>().min_value(-3).max_value(3)),
        2 => -30 * 24 * HOUR + tc.draw(gs::integers::<i64>().min_value(-3).max_value(3)),
        3 => -received_seconds + tc.draw(gs::integers::<i64>().min_value(-3).max_value(3)),
        _ => tc.draw(
            gs::integers::<i64>()
                .min_value(-5_000_000_000)
                .max_value(5_000_000_000),
        ),
    };
    let sender_seconds = received_seconds + offset;
    let format = tc.draw(gs::sampled_from(
        [None, Some("rfc3164"), Some("rfc5424")].as_slice(),
    ));

    let mut normalized = serde_json::Map::new();
    // Fractional seconds, as the collector writes a syslog time.
    normalized.insert("timestamp".to_owned(), json!(sender_seconds as f64));
    if let Some(format) = format {
        normalized.insert("_syslog_format".to_owned(), json!(format));
    }
    let received = u64::try_from(received_seconds).unwrap() * 1_000_000_000 + received_nanos;
    let resource = row::resource_logs(&normalized, received);
    let request = otlp::ExportLogsServiceRequest {
        resource_logs: vec![resource],
    };
    let record = only_record(&request);

    let wrong_clock = sender_seconds < 0
        || match format {
            None => false,
            Some("rfc3164") => offset.abs() > HOUR,
            Some(_) => !(-30 * 24 * HOUR..=24 * HOUR).contains(&offset),
        };
    if wrong_clock {
        assert_eq!(record.time_unix_nano, received);
        assert_eq!(boolean(record, "_syslog_timestamp_fallback"), Some(true));
        assert!(attribute(record, "_syslog_original_timestamp").is_some());
    } else {
        assert_eq!(
            record.time_unix_nano,
            u64::try_from(sender_seconds).unwrap() * 1_000_000_000
        );
        assert_eq!(boolean(record, "_syslog_timestamp_fallback"), None);
        assert_eq!(attribute(record, "_syslog_original_timestamp"), None);
    }
    assert_eq!(record.observed_time_unix_nano, received);
}
