//! Maps a normalized log record to the OTLP log record EventWriter stores.
//!
//! On the JSON path EventWriter runs the Zen rules and then decides every
//! stored column from the resulting record
//! (`ServiceRadar.EventWriter.Processors.Logs.parse_json_log/2`). Here the
//! collector has run the rules, so it makes the same decisions and sends the
//! outcome. A change to either side belongs in both; the shared cases in
//! `normalized_log_parity.json` are run by both test suites.
//!
//! OTLP has no field for four of the columns, and takes a fifth from the
//! resource. Those travel as record attributes under [`COLUMN_PREFIX`], which
//! EventWriter moves into the columns and does not store as attributes. A
//! record cannot set them itself: attributes it carries under that prefix are
//! dropped.
//!
//! What OTLP cannot carry is left out, not approximated: a severity number
//! outside 1 to `i32::MAX`, attributes or resource attributes that are not an
//! object, and the difference between an absent string and an empty one.

use super::otlp::{
    AnyValue, ArrayValue, InstrumentationScope, KeyValue, KeyValueList, LogRecord, Resource,
    ResourceLogs, ScopeLogs, any_value,
};
use base64::Engine;
use serde_json::{Map, Number, Value};
use std::borrow::Cow;
use std::net::IpAddr;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

type Json = Map<String, Value>;

/// Record attributes that carry a stored column, not an attribute.
pub const COLUMN_PREFIX: &str = "serviceradar.column.";

const NANOS_PER_SECOND: i128 = 1_000_000_000;
/// How far, in seconds, an RFC 3164 timestamp may be from the receive time.
/// That format has no zone, so a wrong assumed zone would otherwise file a
/// fresh log hours off.
const RFC3164_TOLERANCE_SECONDS: i128 = 3_600;
/// How far, in seconds, ahead of the receive time a zoned syslog timestamp may
/// be. Nothing is logged before it happens, so more than this is a wrong clock.
const SYSLOG_AHEAD_SECONDS: i128 = 24 * 3_600;
/// How far, in seconds, behind the receive time a zoned syslog timestamp may
/// be. A relay can hold logs through an outage, so this is generous.
const SYSLOG_BEHIND_SECONDS: i128 = 30 * 24 * 3_600;

/// Whether a syslog sender's time is too far from the receive time to file
/// the record under. `ahead` is the sender's whole second minus the receive
/// time's, the instants EventWriter keeps.
fn implausible_syslog_time(format: Option<&str>, ahead: i128) -> bool {
    match format {
        None => false,
        Some("rfc3164") => ahead.abs() > RFC3164_TOLERANCE_SECONDS,
        Some(_) => !(-SYSLOG_BEHIND_SECONDS..=SYSLOG_AHEAD_SECONDS).contains(&ahead),
    }
}

/// `record` is the normalized record and `received` the Unix time in
/// nanoseconds at which the collector took it from the socket.
pub fn resource_logs(record: &Json, received: u64) -> ResourceLogs {
    let resource_attributes = object(
        field(record, "resource_attributes", "resourceAttributes")
            .or_else(|| truthy(record.get("resource"))),
    );
    let resource_attributes = resource_attributes.as_deref();

    let mut attributes = object(record.get("attributes"))
        .map(|attributes| prune_object(&attributes))
        .unwrap_or_default();
    attributes.retain(|key, _| !key.starts_with(COLUMN_PREFIX));
    for key in ["_remote_addr", "_syslog_format", "_syslog_parse_fallback"] {
        if let Some(value) = record.get(key).and_then(prune) {
            attributes.insert(key.to_owned(), value);
        }
    }

    let sender_time = first(
        record,
        &[
            "timestamp",
            "time_unix_nano",
            "timeUnixNano",
            "observed_time_unix_nano",
            "observedTimeUnixNano",
        ],
    )
    .map_or(i128::from(received), |value| unix_nanos(value, received));
    // Whole seconds, which is what EventWriter keeps of a timestamp.
    let sender_seconds = sender_time.div_euclid(NANOS_PER_SECOND);
    let received_seconds = i128::from(received).div_euclid(NANOS_PER_SECOND);
    // A record filed under a wrong clock drops out of every recent view, so
    // it is filed under the receive time and keeps what the sender wrote.
    // OTLP cannot carry a time before 1970.
    let time_unix_nano = match u64::try_from(sender_time) {
        Ok(time)
            if !implausible_syslog_time(
                record.get("_syslog_format").and_then(Value::as_str),
                sender_seconds - received_seconds,
            ) =>
        {
            time
        }
        _ => {
            if let Some(original) = rfc3339(sender_seconds * NANOS_PER_SECOND) {
                attributes.insert("_syslog_original_timestamp".to_owned(), original.into());
            }
            attributes.insert("_syslog_timestamp_fallback".to_owned(), true.into());
            received
        }
    };
    let observed_time_unix_nano = first(
        record,
        &[
            "observed_timestamp",
            "observedTimestamp",
            "observed_time_unix_nano",
            "observedTimeUnixNano",
        ],
    )
    .and_then(|value| u64::try_from(unix_nanos(value, received)).ok())
    .unwrap_or(received);

    let service = |snake: &str, camel: &str, resource_key: &str| {
        field(record, snake, camel).or_else(|| {
            truthy(resource_attributes.and_then(|attributes| attributes.get(resource_key)))
        })
    };
    let service_name = service("service_name", "serviceName", "service.name")
        .or_else(|| field(record, "application_name", "applicationName"))
        .or_else(|| field(record, "app_name", "appName"))
        .or_else(|| field(record, "host", "hostname"))
        .or_else(|| {
            let attributes = resource_attributes?;
            truthy(attributes.get("host.name")).or_else(|| truthy(attributes.get("host_name")))
        });
    let columns = [
        ("source", truthy(record.get("source")).and_then(text)),
        ("source_ip", source_ip(record)),
        ("service_name", service_name.and_then(text)),
        (
            "service_version",
            service("service_version", "serviceVersion", "service.version").and_then(text),
        ),
        (
            "service_instance",
            service("service_instance", "serviceInstance", "service.instance.id").and_then(text),
        ),
    ];
    for (column, value) in columns {
        if let Some(value) = value {
            attributes.insert(format!("{COLUMN_PREFIX}{column}"), value.into());
        }
    }

    let (severity_text, severity_number) = severity(record);
    let log_record = LogRecord {
        time_unix_nano,
        observed_time_unix_nano,
        severity_number: severity_number
            .and_then(|number| i32::try_from(number).ok())
            .filter(|number| *number > 0)
            .unwrap_or_default(),
        severity_text: severity_text.unwrap_or_default(),
        body: body(record).map(|body| AnyValue {
            value: Some(any_value::Value::String(body)),
        }),
        attributes: key_values(&attributes),
        flags: trace_flags(record).unwrap_or_default(),
        trace_id: otel_id(field(record, "trace_id", "traceId"), 16),
        span_id: otel_id(field(record, "span_id", "spanId"), 8),
        event_name: field(record, "event_name", "eventName")
            .and_then(text)
            .unwrap_or_default(),
    };

    ResourceLogs {
        resource: resource_attributes.map(|attributes| Resource {
            attributes: key_values(attributes),
        }),
        scope_logs: vec![ScopeLogs {
            scope: scope(record),
            log_records: vec![log_record],
        }],
    }
}

/// Elixir's `||`: `null` and `false` fall through to the next choice.
fn truthy(value: Option<&Value>) -> Option<&Value> {
    value.filter(|value| !matches!(value, Value::Null | Value::Bool(false)))
}

fn field<'a>(record: &'a Json, snake: &str, camel: &str) -> Option<&'a Value> {
    truthy(record.get(snake)).or_else(|| truthy(record.get(camel)))
}

fn first<'a>(record: &'a Json, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| truthy(record.get(*key)))
}

/// A scalar as a text column stores it.
fn text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

/// An object field, which a sender may also give as JSON text.
fn object(value: Option<&Value>) -> Option<Cow<'_, Json>> {
    match value? {
        Value::Object(fields) => Some(Cow::Borrowed(fields)),
        Value::String(text) => match serde_json::from_str(text) {
            Ok(Value::Object(fields)) => Some(Cow::Owned(fields)),
            _ => None,
        },
        _ => None,
    }
}

/// Drops nulls, empty objects and empty arrays at every depth. `None` when
/// nothing is left.
fn prune(value: &Value) -> Option<Value> {
    match value {
        Value::Null => None,
        Value::Object(fields) => Some(prune_object(fields))
            .filter(|fields| !fields.is_empty())
            .map(Value::Object),
        Value::Array(items) => Some(items.iter().filter_map(prune).collect::<Vec<_>>())
            .filter(|items| !items.is_empty())
            .map(Value::Array),
        other => Some(other.clone()),
    }
}

fn prune_object(fields: &Json) -> Json {
    fields
        .iter()
        .filter_map(|(key, value)| Some((key.clone(), prune(value)?)))
        .collect()
}

/// A timestamp as Unix nanoseconds: RFC 3339 text, integer seconds,
/// milliseconds or nanoseconds told apart by magnitude, or fractional seconds.
/// Anything else is `fallback`. A time before 1970 is negative.
fn unix_nanos(value: &Value, fallback: u64) -> i128 {
    let parsed = match value {
        Value::String(text) => OffsetDateTime::parse(text, &Rfc3339)
            .ok()
            .map(OffsetDateTime::unix_timestamp_nanos),
        Value::Number(number) => match number.as_u64().map(i128::from) {
            Some(nanos) if nanos > 1_000_000_000_000_000_000 => Some(nanos),
            Some(millis) if millis > 1_000_000_000_000 => Some(millis * 1_000_000),
            Some(seconds) => Some(seconds * NANOS_PER_SECOND),
            // Whole microseconds: a double cannot hold more for a current time.
            None => number
                .as_f64()
                .filter(|seconds| number.is_f64() && (-1.0e10..1.0e10).contains(seconds))
                .map(|seconds| (seconds * 1.0e6).round() as i128 * 1_000),
        },
        _ => None,
    };
    parsed.unwrap_or(i128::from(fallback))
}

fn rfc3339(unix_nanos: i128) -> Option<String> {
    OffsetDateTime::from_unix_timestamp_nanos(unix_nanos)
        .ok()?
        .format(&Rfc3339)
        .ok()
}

/// Elixir's `Integer.parse/1`: an optional sign and the digits that follow,
/// whatever comes after them. Saturates at the `i64` bounds.
fn leading_integer(text: &str) -> Option<i64> {
    let (negative, digits) = match text.as_bytes().first()? {
        b'-' => (true, &text[1..]),
        b'+' => (false, &text[1..]),
        _ => (false, text),
    };
    let end = digits
        .bytes()
        .position(|byte| !byte.is_ascii_digit())
        .unwrap_or(digits.len());
    if end == 0 {
        return None;
    }
    let magnitude = digits[..end].parse::<i128>().unwrap_or(i128::MAX);
    let value = if negative { -magnitude } else { magnitude };
    Some(value.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64)
}

fn integer(number: &Number) -> Option<i64> {
    number
        .as_i64()
        .or_else(|| number.as_u64().map(|_| i64::MAX))
}

fn integer_field(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => integer(number),
        Value::String(text) => leading_integer(text),
        _ => None,
    }
}

/// An explicit severity text wins. Without one a syslog `level` decides both
/// columns, so a record no severity rule touched is still filed by severity.
fn severity(record: &Json) -> (Option<String>, Option<i64>) {
    let explicit =
        field(record, "severity_text", "severityText").or_else(|| truthy(record.get("severity")));
    let number = integer_field(field(record, "severity_number", "severityNumber"));
    match (explicit, record.get("level")) {
        (Some(Value::String(text)), _) if !text.is_empty() => (Some(text.clone()), number),
        (_, Some(level)) if !level.is_null() => {
            let (level_text, level_number) = level_severity(level);
            (Some(level_text.to_owned()), number.or(Some(level_number)))
        }
        _ => (explicit.and_then(text), number),
    }
}

fn level_severity(level: &Value) -> (&'static str, i64) {
    let numeric = match level {
        Value::Number(number) => {
            integer(number).or_else(|| number.as_f64().map(|level| level.round() as i64))
        }
        Value::String(text) => leading_integer(text.trim()),
        _ => None,
    };
    match numeric {
        Some(0..=2) => ("FATAL", 21),
        Some(3) => ("ERROR", 19),
        Some(4) => ("WARN", 15),
        Some(7) => ("DEBUG", 5),
        Some(_) => ("INFO", 9),
        None => {
            let name = text(level).unwrap_or_default().trim().to_lowercase();
            match name.as_str() {
                "fatal" | "critical" | "emergency" | "alert" | "very high" | "very_high" => {
                    ("FATAL", 23)
                }
                "high" | "error" => ("ERROR", 19),
                "medium" | "warn" | "warning" => ("WARN", 15),
                "debug" | "trace" => ("DEBUG", 7),
                _ => ("INFO", 11),
            }
        }
    }
}

fn body(record: &Json) -> Option<String> {
    match record.get("body") {
        Some(Value::String(body)) => return Some(body.clone()),
        Some(body @ (Value::Object(_) | Value::Array(_))) => {
            return serde_json::to_string(body).ok();
        }
        _ => {}
    }
    ["message", "msg", "short_message"]
        .iter()
        .find_map(|key| record.get(*key)?.as_str())
        .map(str::to_owned)
}

fn trace_flags(record: &Json) -> Option<u32> {
    integer_field(first(record, &["trace_flags", "traceFlags", "flags"]))
        .and_then(|flags| u32::try_from(flags).ok())
}

/// A trace or span id as OTLP bytes, from any encoding EventWriter accepts:
/// hex, hex of hex, the raw bytes, or base64. Empty when absent, invalid or
/// all zero.
fn otel_id(value: Option<&Value>, length: usize) -> Vec<u8> {
    let Some(Value::String(text)) = value else {
        return Vec::new();
    };
    let raw = text.as_bytes();
    let id = if raw.len() == length * 2 {
        unhex(raw)
    } else if raw.len() == length * 4 {
        unhex(raw).and_then(|inner| unhex(&inner))
    } else {
        None
    };
    let id = id.or_else(|| {
        if raw.len() == length {
            Some(raw.to_vec())
        } else {
            base64::engine::general_purpose::STANDARD
                .decode(raw)
                .ok()
                .filter(|decoded| decoded.len() == length)
        }
    });
    id.filter(|id| id.iter().any(|byte| *byte != 0))
        .unwrap_or_default()
}

fn unhex(text: &[u8]) -> Option<Vec<u8>> {
    let digit = |byte: u8| char::from(byte).to_digit(16).map(|digit| digit as u8);
    text.chunks(2)
        .map(|pair| match pair {
            [high, low] => Some((digit(*high)? << 4) | digit(*low)?),
            _ => None,
        })
        .collect()
}

/// The sender address, from the first of `source_ip`, `_remote_addr` and
/// `source` that holds one. Each may carry a partition prefix, a port or
/// IPv6 brackets around the address.
fn source_ip(record: &Json) -> Option<String> {
    [
        field(record, "source_ip", "sourceIp"),
        record.get("_remote_addr"),
        record.get("source"),
    ]
    .into_iter()
    .flatten()
    .filter_map(Value::as_str)
    .find_map(|value| {
        let value = value.trim();
        [value, bracketless(value)]
            .into_iter()
            .flat_map(|candidate| match candidate.split_once(':') {
                Some((prefix, address)) => {
                    vec![candidate, prefix, address, bracketless(address)]
                }
                None => vec![candidate],
            })
            .find(|candidate| candidate.parse::<IpAddr>().is_ok())
            .map(str::to_owned)
    })
}

/// `[address]` or `[address]:port` without the brackets and port.
fn bracketless(value: &str) -> &str {
    let Some((address, tail)) = value
        .strip_prefix('[')
        .and_then(|rest| rest.split_once(']'))
    else {
        return value;
    };
    let port = tail.strip_prefix(':');
    let tail_is_port = tail.is_empty()
        || port.is_some_and(|port| !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()));
    if !address.is_empty() && tail_is_port {
        address
    } else {
        value
    }
}

fn scope(record: &Json) -> Option<InstrumentationScope> {
    let described = record.get("scope");
    let scope_field = |keys: &[&str]| match described {
        Some(Value::Object(scope)) => first(scope, keys),
        _ => None,
    };
    let named = match described {
        Some(name @ Value::String(text)) if !text.is_empty() => Some(name),
        _ => None,
    };
    let name = field(record, "scope_name", "scopeName")
        .or_else(|| scope_field(&["name", "scopeName", "scope_name"]))
        .or(named);
    let version = field(record, "scope_version", "scopeVersion")
        .or_else(|| scope_field(&["version", "scopeVersion", "scope_version"]));
    let attributes = object(field(record, "scope_attributes", "scopeAttributes").or(described));

    let scope = InstrumentationScope {
        name: name.and_then(text).unwrap_or_default(),
        version: version.and_then(text).unwrap_or_default(),
        attributes: attributes.as_deref().map(key_values).unwrap_or_default(),
    };
    (scope != InstrumentationScope::default()).then_some(scope)
}

fn key_values(fields: &Json) -> Vec<KeyValue> {
    fields
        .iter()
        .map(|(key, value)| KeyValue {
            key: key.clone(),
            value: any_value(value),
        })
        .collect()
}

fn any_value(value: &Value) -> Option<AnyValue> {
    let value = match value {
        Value::Null => return None,
        Value::Bool(flag) => any_value::Value::Bool(*flag),
        Value::Number(number) => match number.as_i64() {
            Some(integer) => any_value::Value::Int(integer),
            None => any_value::Value::Double(number.as_f64().unwrap_or(f64::NAN)),
        },
        Value::String(text) => any_value::Value::String(text.clone()),
        Value::Array(items) => any_value::Value::Array(ArrayValue {
            values: items
                .iter()
                .map(|item| any_value(item).unwrap_or_default())
                .collect(),
        }),
        Value::Object(fields) => any_value::Value::Kvlist(KeyValueList {
            values: key_values(fields),
        }),
    };
    Some(AnyValue { value: Some(value) })
}
