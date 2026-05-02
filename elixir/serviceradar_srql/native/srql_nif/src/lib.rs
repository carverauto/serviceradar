use arrow_array::{ArrayRef, BooleanArray, Float64Array, Int64Array, RecordBatch, StringArray};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use capnp::message::{Builder, ReaderOptions};
use capnp::serialize;
use chrono::{TimeZone, Utc};
use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use serde_json::{Map, Value};
use std::io::Cursor;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;
use std::sync::Arc;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

mod update_capnp {
    include!(concat!(env!("OUT_DIR"), "/update_capnp.rs"));
}

/// Parse an SRQL query and return the AST as JSON.
/// This allows Elixir to consume the structured query without re-parsing.
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_ast(env: Env, srql_query: String) -> Term {
    match srql::parser::parse(&srql_query) {
        Ok(ast) => match serde_json::to_string(&ast) {
            Ok(json) => (atoms::ok(), json).encode(env),
            Err(err) => (atoms::error(), format!("failed to encode SRQL AST: {err}")).encode(env),
        },
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn translate(
    env: Env,
    srql_query: String,
    limit: Option<i64>,
    cursor: Option<String>,
    direction: Option<String>,
    mode: Option<String>,
) -> Term {
    let direction = match direction.as_deref() {
        Some("prev") => srql::QueryDirection::Prev,
        _ => srql::QueryDirection::Next,
    };

    let request = srql::QueryRequest {
        query: srql_query,
        limit,
        cursor,
        direction,
        mode,
    };

    let config = srql::config::AppConfig::embedded("postgres://unused/db".to_string());

    let response = match srql::query::translate_request(&config, request) {
        Ok(response) => response,
        Err(err) => return (atoms::error(), err.to_string()).encode(env),
    };

    match serde_json::to_string(&response) {
        Ok(json) => (atoms::ok(), json).encode(env),
        Err(err) => (
            atoms::error(),
            format!("failed to encode SRQL translation: {err}"),
        )
            .encode(env),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ColumnKind {
    Bool,
    Int64,
    Float64,
    Utf8,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_arrow_json<'a>(env: Env<'a>, columns: Vec<String>, rows_json: String) -> Term<'a> {
    match encode_arrow_json_impl(env, columns, rows_json) {
        Ok(binary) => (atoms::ok(), binary).encode(env),
        Err(err) => (atoms::error(), err).encode(env),
    }
}

fn encode_arrow_json_impl<'a>(
    env: Env<'a>,
    columns: Vec<String>,
    rows_json: String,
) -> Result<Binary<'a>, String> {
    let rows: Vec<Value> =
        serde_json::from_str(&rows_json).map_err(|err| format!("invalid rows JSON: {err}"))?;

    let column_kinds = columns
        .iter()
        .map(|column| infer_column_kind(column, &rows))
        .collect::<Vec<_>>();

    let fields = columns
        .iter()
        .zip(column_kinds.iter())
        .map(|(column, kind)| Field::new(column, data_type_for(*kind), true))
        .collect::<Vec<_>>();

    let schema = Arc::new(Schema::new(fields));
    let arrays = columns
        .iter()
        .zip(column_kinds.iter())
        .map(|(column, kind)| build_array(column, *kind, &rows))
        .collect::<Result<Vec<_>, _>>()?;

    let batch = RecordBatch::try_new(Arc::clone(&schema), arrays)
        .map_err(|err| format!("failed to build Arrow record batch: {err}"))?;

    let mut payload = Vec::new();
    {
        let mut writer = FileWriter::try_new(&mut payload, &schema)
            .map_err(|err| format!("failed to create Arrow writer: {err}"))?;
        writer
            .write(&batch)
            .map_err(|err| format!("failed to write Arrow batch: {err}"))?;
        writer
            .finish()
            .map_err(|err| format!("failed to finish Arrow payload: {err}"))?;
    }

    let mut out = OwnedBinary::new(payload.len()).ok_or("failed to allocate Arrow payload")?;
    out.as_mut_slice().copy_from_slice(&payload);

    Ok(Binary::from_owned(out, env))
}

fn infer_column_kind(column: &str, rows: &[Value]) -> ColumnKind {
    let mut kind: Option<ColumnKind> = None;

    for row in rows {
        let Some(value) = row.get(column) else {
            continue;
        };

        let Some(value_kind) = value_kind(value) else {
            continue;
        };

        kind = Some(match (kind, value_kind) {
            (None, next) => next,
            (Some(ColumnKind::Utf8), _) | (_, ColumnKind::Utf8) => ColumnKind::Utf8,
            (Some(ColumnKind::Float64), _) | (_, ColumnKind::Float64) => ColumnKind::Float64,
            (Some(ColumnKind::Int64), ColumnKind::Int64) => ColumnKind::Int64,
            (Some(ColumnKind::Bool), ColumnKind::Bool) => ColumnKind::Bool,
            _ => ColumnKind::Utf8,
        });
    }

    kind.unwrap_or(ColumnKind::Utf8)
}

fn value_kind(value: &Value) -> Option<ColumnKind> {
    match value {
        Value::Null => None,
        Value::Bool(_) => Some(ColumnKind::Bool),
        Value::Number(number) if number.is_i64() || number.is_u64() => Some(ColumnKind::Int64),
        Value::Number(_) => Some(ColumnKind::Float64),
        Value::String(_) => Some(ColumnKind::Utf8),
        Value::Array(_) | Value::Object(_) => Some(ColumnKind::Utf8),
    }
}

fn data_type_for(kind: ColumnKind) -> DataType {
    match kind {
        ColumnKind::Bool => DataType::Boolean,
        ColumnKind::Int64 => DataType::Int64,
        ColumnKind::Float64 => DataType::Float64,
        ColumnKind::Utf8 => DataType::Utf8,
    }
}

fn build_array(column: &str, kind: ColumnKind, rows: &[Value]) -> Result<ArrayRef, String> {
    match kind {
        ColumnKind::Bool => Ok(Arc::new(BooleanArray::from(
            rows.iter()
                .map(|row| row.get(column).and_then(Value::as_bool))
                .collect::<Vec<_>>(),
        ))),
        ColumnKind::Int64 => Ok(Arc::new(Int64Array::from(
            rows.iter()
                .map(|row| row.get(column).and_then(value_as_i64))
                .collect::<Vec<_>>(),
        ))),
        ColumnKind::Float64 => Ok(Arc::new(Float64Array::from(
            rows.iter()
                .map(|row| row.get(column).and_then(value_as_f64))
                .collect::<Vec<_>>(),
        ))),
        ColumnKind::Utf8 => {
            let values = rows
                .iter()
                .map(|row| row.get(column).and_then(value_as_string))
                .collect::<Vec<_>>();

            Ok(Arc::new(StringArray::from(values)))
        }
    }
}

fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|v| i64::try_from(v).ok()))
}

fn value_as_f64(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value_as_i64(value).map(|v| v as f64))
}

fn value_as_string(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(value) => Some(value.clone()),
        Value::Bool(value) => Some(value.to_string()),
        Value::Number(value) => Some(value.to_string()),
        Value::Array(_) | Value::Object(_) => Some(value.to_string()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_arancini_update_capnp<'a>(env: Env<'a>, payload: Binary<'a>) -> Term<'a> {
    match decode_capnp_payload(payload.as_slice()) {
        Ok(value) => match serde_json::to_string(&value) {
            Ok(json) => (atoms::ok(), json).encode(env),
            Err(err) => (
                atoms::error(),
                format!("failed to encode decoded Cap'n Proto payload: {err}"),
            )
                .encode(env),
        },
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_arancini_update_capnp(env: Env, json_payload: String) -> Term {
    let value: Value = match serde_json::from_str(&json_payload) {
        Ok(v) => v,
        Err(err) => {
            return (
                atoms::error(),
                format!("failed to parse JSON payload for Cap'n Proto encoding: {err}"),
            )
                .encode(env);
        }
    };

    match encode_capnp_payload(&value) {
        Ok(bytes) => {
            let mut out = match OwnedBinary::new(bytes.len()) {
                Some(buf) => buf,
                None => return (atoms::error(), "failed to allocate output binary").encode(env),
            };
            out.as_mut_slice().copy_from_slice(&bytes);
            (atoms::ok(), out.release(env)).encode(env)
        }
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

fn decode_capnp_payload(bytes: &[u8]) -> anyhow::Result<Value> {
    let mut cursor = Cursor::new(bytes);
    let reader = serialize::read_message(&mut cursor, ReaderOptions::new())
        .map_err(|err| anyhow::anyhow!("failed to read Cap'n Proto message: {err}"))?;
    let update = reader
        .get_root::<update_capnp::update::Reader>()
        .map_err(|err| anyhow::anyhow!("failed to read Cap'n Proto update root: {err}"))?;

    let router_addr = decode_ip(update.get_router_addr().unwrap_or_default())
        .map(|ip| ip.to_string())
        .ok_or_else(|| anyhow::anyhow!("missing or invalid routerAddr"))?;
    let peer_addr = decode_ip(update.get_peer_addr().unwrap_or_default())
        .map(|ip| ip.to_string())
        .ok_or_else(|| anyhow::anyhow!("missing or invalid peerAddr"))?;
    let prefix_addr = decode_ip(update.get_prefix_addr().unwrap_or_default())
        .map(|ip| ip.to_string())
        .ok_or_else(|| anyhow::anyhow!("missing or invalid prefixAddr"))?;

    let mut payload = Map::new();
    payload.insert(
        "time_received_ns".to_string(),
        Value::String(nanos_to_iso8601(update.get_time_received_ns())),
    );
    payload.insert(
        "time_bmp_header_ns".to_string(),
        Value::String(nanos_to_iso8601(update.get_time_bmp_header_ns())),
    );
    payload.insert("router_addr".to_string(), Value::String(router_addr));
    payload.insert("peer_addr".to_string(), Value::String(peer_addr));
    payload.insert(
        "peer_asn".to_string(),
        Value::Number(serde_json::Number::from(update.get_peer_asn() as u64)),
    );
    payload.insert("prefix_addr".to_string(), Value::String(prefix_addr));
    payload.insert(
        "prefix_len".to_string(),
        Value::Number(serde_json::Number::from(update.get_prefix_len() as u64)),
    );
    payload.insert("announced".to_string(), Value::Bool(update.get_announced()));
    payload.insert("synthetic".to_string(), Value::Bool(update.get_synthetic()));

    Ok(Value::Object(payload))
}

fn encode_capnp_payload(value: &Value) -> anyhow::Result<Vec<u8>> {
    let obj = value
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("payload must be a JSON object"))?;

    let router_addr = required_ip_bytes(obj, "router_addr")?;
    let peer_addr = required_ip_bytes(obj, "peer_addr")?;
    let prefix_addr = required_ip_bytes(obj, "prefix_addr")?;

    let peer_asn = required_u64(obj, "peer_asn")? as u32;
    let prefix_len = required_u64(obj, "prefix_len")? as u8;
    let announced = required_bool(obj, "announced")?;
    let synthetic = optional_bool(obj, "synthetic").unwrap_or(false);

    let time_received_ns = optional_u64(obj, "time_received_ns")
        .or_else(|| optional_iso8601_to_nanos(obj, "time_received_ns"))
        .unwrap_or_else(now_nanos);
    let time_bmp_header_ns = optional_u64(obj, "time_bmp_header_ns")
        .or_else(|| optional_iso8601_to_nanos(obj, "time_bmp_header_ns"))
        .unwrap_or(time_received_ns);

    let mut message = Builder::new_default();
    {
        let mut u = message.init_root::<update_capnp::update::Builder>();
        u.set_time_received_ns(time_received_ns);
        u.set_time_bmp_header_ns(time_bmp_header_ns);
        u.set_router_addr(&router_addr);
        u.set_router_port(0);
        u.set_peer_addr(&peer_addr);
        u.set_peer_bgp_id(0);
        u.set_peer_asn(peer_asn);
        u.set_prefix_addr(&prefix_addr);
        u.set_prefix_len(prefix_len);
        u.set_is_post_policy(false);
        u.set_is_adj_rib_out(false);
        u.set_announced(announced);
        u.set_synthetic(synthetic);
    }

    let mut out = Vec::with_capacity(256);
    serialize::write_message(&mut out, &message)
        .map_err(|err| anyhow::anyhow!("failed to write Cap'n Proto message: {err}"))?;
    Ok(out)
}

fn decode_ip(bytes: &[u8]) -> Option<IpAddr> {
    match bytes.len() {
        4 => Some(IpAddr::V4(Ipv4Addr::new(
            bytes[0], bytes[1], bytes[2], bytes[3],
        ))),
        16 => {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(bytes);
            let v6 = Ipv6Addr::from(octets);
            Some(
                v6.to_ipv4_mapped()
                    .map(IpAddr::V4)
                    .unwrap_or(IpAddr::V6(v6)),
            )
        }
        _ => None,
    }
}

fn ip_to_wire_bytes(ip: IpAddr) -> [u8; 16] {
    match ip {
        IpAddr::V4(v4) => v4.to_ipv6_mapped().octets(),
        IpAddr::V6(v6) => v6.octets(),
    }
}

fn required_ip_bytes(obj: &Map<String, Value>, key: &str) -> anyhow::Result<[u8; 16]> {
    let value = required_string(obj, key)?;
    let ip =
        IpAddr::from_str(value).map_err(|err| anyhow::anyhow!("invalid IP for {key}: {err}"))?;
    Ok(ip_to_wire_bytes(ip))
}

fn required_string<'a>(obj: &'a Map<String, Value>, key: &str) -> anyhow::Result<&'a str> {
    obj.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("missing required string field {key}"))
}

fn required_u64(obj: &Map<String, Value>, key: &str) -> anyhow::Result<u64> {
    obj.get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow::anyhow!("missing required numeric field {key}"))
}

fn required_bool(obj: &Map<String, Value>, key: &str) -> anyhow::Result<bool> {
    obj.get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| anyhow::anyhow!("missing required boolean field {key}"))
}

fn optional_u64(obj: &Map<String, Value>, key: &str) -> Option<u64> {
    obj.get(key).and_then(Value::as_u64)
}

fn optional_bool(obj: &Map<String, Value>, key: &str) -> Option<bool> {
    obj.get(key).and_then(Value::as_bool)
}

fn optional_iso8601_to_nanos(obj: &Map<String, Value>, key: &str) -> Option<u64> {
    obj.get(key).and_then(Value::as_str).and_then(|value| {
        chrono::DateTime::parse_from_rfc3339(value)
            .ok()
            .map(|dt| dt.with_timezone(&Utc).timestamp_nanos_opt())
            .and_then(|n| n)
            .map(|n| n as u64)
    })
}

fn nanos_to_iso8601(ns: u64) -> String {
    let secs = (ns / 1_000_000_000) as i64;
    let nanos = (ns % 1_000_000_000) as u32;
    Utc.timestamp_opt(secs, nanos)
        .single()
        .map(|dt| dt.to_rfc3339_opts(chrono::SecondsFormat::Nanos, true))
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

fn now_nanos() -> u64 {
    Utc::now()
        .timestamp_nanos_opt()
        .map(|n| n as u64)
        .unwrap_or(0)
}

rustler::init!("Elixir.ServiceRadarSRQL.Native");
