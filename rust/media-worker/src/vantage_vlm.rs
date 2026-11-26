//! Ramp 1 declarative VLM runner (`media.jobs.vantage.vlm.v1` / `.backfill.v1`).
//!
//! Consumes `VantageJobEnvelope` jobs from JetStream `CAMERA_MEDIA_JOBS`, acquires
//! scoped Fragment Read Grants (`POST /v1/media/workers/read-grants`), verifies SHA-256
//! of `init.mp4` and sampled fragments via `HybridGrantStore`, decodes IDR keyframes at
//! native camera resolution, extracts bounded full-resolution padded crops via
//! `serviceradar_media_core::crop`, calls an OpenAI-compatible `camera_vlm` endpoint
//! with thinking disabled and strict JSON schema/regex validation, runs multi-frame
//! track consensus, and publishes `<= 960 KiB` `VantageResultEnvelope` payloads to
//! `media.results.vantage.v1` before acknowledging the source job message.

use crate::cmaf::{parse_init_segment_with_codec, parse_timed_fragment};
use crate::config::WorkerConfig;
use crate::errors::MediaWorkerError;
use crate::grants::{GrantClient, GrantResolution, ReadGrantRequest};
use crate::keyframe_decoder::{DefaultKeyframeDecoder, KeyframeDecoder};
use crate::metrics::WorkerMetrics;
use crate::range_reader::{FragmentStore, VerifiedKeyframeBlock};
use crate::vision::RgbFrame;
use crate::worker::{JobDelivery, ResultPublisher, spawn_wpi_heartbeat};
use regex_automata::meta::Regex;
use serde::{Deserialize, Serialize};
use serviceradar_media_core::{
    CropConfig, CropOutcome, EncodedCrop, InputMode, MAX_STORED_CROP_JPEG_BYTES,
    MAX_VANTAGE_RESULT_ENVELOPE_BYTES, MAX_VLM_MAX_TOKENS, SampledTarget, SourceMode,
    VANTAGE_JOB_SCHEMA_VERSION, VANTAGE_RESULT_SCHEMA_VERSION, VantageJobEnvelope,
    VantageObservationInput, VantageResultEnvelope, WorkerKind, crop_detection_in_rois_jpeg,
    crop_detection_jpeg, crop_roi_polygons_jpeg,
};
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tracing::{debug, warn};
use zeroize::Zeroizing;

const MAX_VLM_RESPONSE_BYTES: usize = 256 * 1024;
const DEFAULT_VLM_SYSTEM_PROMPT: &str = "You are a precision visual inspection analyzer. Respond with strict JSON only matching the requested schema. Do not include reasoning, markdown, or extra prose.";

/// Outcome of processing a single Vantage VLM JetStream job delivery.
#[derive(Debug, Clone, PartialEq)]
pub enum VantageJobOutcome {
    /// Result envelope published and confirmed on `media.results.vantage.v1` before ACK.
    Completed(Box<VantageResultEnvelope>),
    /// Control-plane read grant returned `410 Gone`; job ACKed cleanly without retry.
    Gone,
}

#[cfg(test)]
impl VantageJobOutcome {
    pub fn completed_envelope(&self) -> Option<&VantageResultEnvelope> {
        match self {
            Self::Completed(env) => Some(env),
            Self::Gone => None,
        }
    }
}

/// Request payload passed to a [`VlmClient`] for one full-resolution crop.
#[derive(Debug, Clone, PartialEq)]
pub struct VlmChatRequest {
    pub model: String,
    pub system_prompt: String,
    pub user_prompt: String,
    pub crop_jpeg_b64: String,
    pub max_tokens: u32,
    pub temperature: f32,
    pub json_schema: Option<serde_json::Value>,
    pub schema_name: String,
}

/// Transport or HTTP status error from calling the OpenAI-compatible VLM endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VlmCallError {
    HttpError { status: u16, body: String },
    Transport(String),
}

impl core::fmt::Display for VlmCallError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::HttpError { status, body } => {
                write!(f, "camera_vlm HTTP {status}: {body}")
            }
            Self::Transport(msg) => write!(f, "camera_vlm transport failure: {msg}"),
        }
    }
}

impl std::error::Error for VlmCallError {}

impl VlmCallError {
    pub const fn outcome_label(&self) -> &'static str {
        match self {
            Self::HttpError { .. } => "http_error",
            Self::Transport(_) => "transport_error",
        }
    }
}

/// Static-dispatch trait for OpenAI-compatible multimodal VLM completion calls.
pub trait VlmClient: Send + Sync {
    fn chat_completion(
        &self,
        request: &VlmChatRequest,
    ) -> impl Future<Output = Result<String, VlmCallError>> + Send;

    fn chat_completion_with_budget(
        &self,
        request: &VlmChatRequest,
        budget: Duration,
    ) -> impl Future<Output = Result<String, VlmCallError>> + Send {
        async move {
            tokio::time::timeout(budget, self.chat_completion(request))
                .await
                .map_err(|_| {
                    VlmCallError::Transport(format!(
                        "VLM call exceeded remaining job budget ({} ms)",
                        budget.as_millis()
                    ))
                })?
        }
    }
}

/// Production `ureq`-based OpenAI `/v1/chat/completions` client running inside `spawn_blocking`.
#[derive(Clone)]
pub struct HttpVlmClient {
    endpoint_url: String,
    default_model: String,
    api_key: Option<Zeroizing<String>>,
    timeout: Duration,
}

impl core::fmt::Debug for HttpVlmClient {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("HttpVlmClient")
            .field("endpoint_url", &self.endpoint_url)
            .field("default_model", &self.default_model)
            .field("api_key", &self.api_key.as_ref().map(|_| "[REDACTED]"))
            .field("timeout", &self.timeout)
            .finish()
    }
}

impl HttpVlmClient {
    pub fn new(
        endpoint_url: impl Into<String>,
        default_model: impl Into<String>,
        api_key: Option<Zeroizing<String>>,
        timeout: Duration,
    ) -> Self {
        Self {
            endpoint_url: endpoint_url.into(),
            default_model: default_model.into(),
            api_key,
            timeout,
        }
    }

    pub fn from_config(config: &WorkerConfig) -> Result<Self, MediaWorkerError> {
        let url = config
            .resolved_vantage_vlm_url()
            .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;
        Ok(Self::new(
            url,
            config.vantage_vlm_model(),
            config.vantage_vlm_api_key().map(|k| k.to_zeroizing()),
            Duration::from_millis(config.vantage_vlm_timeout_ms()),
        ))
    }

    pub fn endpoint_url(&self) -> &str {
        &self.endpoint_url
    }

    pub fn default_model(&self) -> &str {
        &self.default_model
    }
}

impl VlmClient for HttpVlmClient {
    async fn chat_completion(&self, request: &VlmChatRequest) -> Result<String, VlmCallError> {
        self.chat_completion_with_budget(request, self.timeout)
            .await
    }

    async fn chat_completion_with_budget(
        &self,
        request: &VlmChatRequest,
        budget: Duration,
    ) -> Result<String, VlmCallError> {
        let endpoint = self.endpoint_url.clone();
        let default_model = self.default_model.clone();
        let api_key = self.api_key.clone();
        let effective_timeout = self.timeout.min(budget);
        let req = request.clone();

        tokio::time::timeout(
            budget,
            tokio::task::spawn_blocking(move || {
                execute_vlm_http_post(
                    &endpoint,
                    &default_model,
                    api_key.as_ref(),
                    effective_timeout,
                    &req,
                )
            }),
        )
        .await
        .map_err(|_| {
            VlmCallError::Transport(format!(
                "VLM HTTP call exceeded remaining job budget ({} ms)",
                budget.as_millis()
            ))
        })?
        .map_err(|err| VlmCallError::Transport(format!("VLM blocking task panicked: {err}")))?
    }
}

fn ensure_no_think_suffix(prompt: &str) -> String {
    let trimmed = prompt.trim();
    if trimmed.contains("/no_think") {
        trimmed.to_string()
    } else {
        format!("{trimmed}\n/no_think")
    }
}

fn build_openai_chat_payload(default_model: &str, req: &VlmChatRequest) -> serde_json::Value {
    let model = if req.model.trim().is_empty() {
        default_model
    } else {
        req.model.trim()
    };
    let max_tokens = req.max_tokens.clamp(1, MAX_VLM_MAX_TOKENS);
    let response_format = match &req.json_schema {
        Some(schema) => serde_json::json!({
            "type": "json_schema",
            "json_schema": {
                "name": req.schema_name,
                "strict": true,
                "schema": schema
            }
        }),
        None => serde_json::json!({ "type": "json_object" }),
    };
    let data_url = format!("data:image/jpeg;base64,{}", req.crop_jpeg_b64);

    serde_json::json!({
        "model": model,
        "temperature": req.temperature,
        "max_tokens": max_tokens,
        "enable_thinking": false,
        "chat_template_kwargs": { "enable_thinking": false },
        "response_format": response_format,
        "messages": [
            {
                "role": "system",
                "content": req.system_prompt
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": ensure_no_think_suffix(&req.user_prompt)
                    },
                    {
                        "type": "image_url",
                        "image_url": { "url": data_url }
                    }
                ]
            }
        ]
    })
}

fn execute_vlm_http_post(
    endpoint: &str,
    default_model: &str,
    api_key: Option<&Zeroizing<String>>,
    timeout: Duration,
    req: &VlmChatRequest,
) -> Result<String, VlmCallError> {
    let agent = ureq::config::Config::builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(timeout))
        .build()
        .new_agent();

    let payload = build_openai_chat_payload(default_model, req);
    let mut http_req = agent
        .post(endpoint)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json");
    if let Some(key) = api_key {
        let bearer = Zeroizing::new(format!("Bearer {}", key.as_str()));
        http_req = http_req.header("Authorization", bearer.as_str());
    }

    let mut response = http_req
        .send_json(&payload)
        .map_err(|err| VlmCallError::Transport(format!("HTTP request failed: {err}")))?;

    let status = response.status().as_u16();
    let mut raw_body = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take((MAX_VLM_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut raw_body)
        .map_err(|err| VlmCallError::Transport(format!("failed reading VLM response: {err}")))?;

    if raw_body.len() > MAX_VLM_RESPONSE_BYTES {
        return Err(VlmCallError::Transport(
            "VLM response body exceeded 256 KiB bound".to_string(),
        ));
    }

    if !(200..=299).contains(&status) {
        let snippet = String::from_utf8_lossy(&raw_body);
        let bounded = snippet.chars().take(256).collect::<String>();
        return Err(VlmCallError::HttpError {
            status,
            body: bounded,
        });
    }

    let parsed: serde_json::Value = serde_json::from_slice(&raw_body).map_err(|err| {
        VlmCallError::Transport(format!("invalid JSON envelope from camera_vlm: {err}"))
    })?;

    extract_openai_message_content(&parsed)
        .ok_or_else(|| VlmCallError::Transport("missing choices[0].message.content".to_string()))
}

fn extract_openai_message_content(value: &serde_json::Value) -> Option<String> {
    let content = value
        .get("choices")?
        .as_array()?
        .first()?
        .get("message")?
        .get("content")?;

    if let Some(text) = content.as_str() {
        return Some(text.to_string());
    }
    if let Some(parts) = content.as_array() {
        let mut combined = String::new();
        for part in parts {
            if part.get("type").and_then(|t| t.as_str()) == Some("text")
                && let Some(text) = part.get("text").and_then(|t| t.as_str())
            {
                combined.push_str(text);
            }
        }
        if !combined.is_empty() {
            return Some(combined);
        }
    }
    None
}

/// Bounded parse/schema rejection reasons when validating raw VLM output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VlmParseFailure {
    TruncatedThinking,
    ParseError(String),
    SchemaRejected(String),
}

impl VlmParseFailure {
    pub const fn outcome_label(&self) -> &'static str {
        match self {
            Self::TruncatedThinking => "truncated_thinking",
            Self::ParseError(_) => "parse_error",
            Self::SchemaRejected(_) => "schema_rejected",
        }
    }
}

/// Validated per-frame structured observation extracted from VLM JSON output.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParsedVlmReading {
    pub label: String,
    pub category: String,
    pub confidence: f32,
    pub attributes: serde_json::Map<String, serde_json::Value>,
}

/// Strips closed `<think>...</think>` blocks, rejects unclosed `<think>` truncation,
/// parses strict JSON, and enforces `json_schema` constraints (including regex patterns).
pub fn parse_vlm_json_response(
    raw_content: &str,
    json_schema: Option<&serde_json::Value>,
    default_category: &str,
) -> Result<ParsedVlmReading, VlmParseFailure> {
    let stripped = strip_closed_think_blocks(raw_content)?;
    let cleaned = strip_markdown_code_fence(&stripped).trim();
    if cleaned.is_empty() {
        return Err(VlmParseFailure::ParseError(
            "empty VLM response".to_string(),
        ));
    }

    let mut obj = match serde_json::from_str::<serde_json::Value>(cleaned) {
        Ok(serde_json::Value::Object(map)) => map,
        Ok(_) => {
            return Err(VlmParseFailure::ParseError(
                "VLM response JSON must be an object".to_string(),
            ));
        }
        Err(err) => {
            return Err(VlmParseFailure::ParseError(format!(
                "invalid VLM JSON: {err}"
            )));
        }
    };

    // Normalize common string fields (e.g. trim whitespace; uppercase `plate_text` if present).
    if let Some(serde_json::Value::String(plate)) = obj.get_mut("plate_text") {
        *plate = plate.trim().to_ascii_uppercase();
    }

    if let Some(schema) = json_schema {
        validate_json_against_schema(&obj, schema)?;
    }

    let confidence = match obj.get("confidence") {
        Some(v) => {
            let c = v.as_f64().ok_or_else(|| {
                VlmParseFailure::SchemaRejected("confidence must be a number".to_string())
            })?;
            if !c.is_finite() || !(0.0..=1.0).contains(&c) {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "confidence {c} out of 0.0..=1.0 range"
                )));
            }
            c as f32
        }
        None => 0.85,
    };

    let label = extract_primary_label(&obj).ok_or_else(|| {
        VlmParseFailure::SchemaRejected(
            "missing non-empty primary label/plate_text field".to_string(),
        )
    })?;

    let category = obj
        .get("category")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(default_category)
        .to_string();

    Ok(ParsedVlmReading {
        label,
        category,
        confidence,
        attributes: obj,
    })
}

fn strip_closed_think_blocks(raw: &str) -> Result<String, VlmParseFailure> {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;

    loop {
        let lower = rest.to_ascii_lowercase();
        let Some(open_idx) = lower.find("<think") else {
            out.push_str(rest);
            break;
        };
        out.push_str(&rest[..open_idx]);
        let after_open = &rest[open_idx..];
        let after_open_lower = after_open.to_ascii_lowercase();
        let Some(gt_offset) = after_open_lower.find('>') else {
            return Err(VlmParseFailure::TruncatedThinking);
        };
        let body_start = gt_offset + 1;
        let Some(close_offset) = after_open_lower[body_start..].find("</think>") else {
            return Err(VlmParseFailure::TruncatedThinking);
        };
        rest = &after_open[body_start + close_offset + "</think>".len()..];
    }

    if out.to_ascii_lowercase().contains("</think>") {
        return Err(VlmParseFailure::TruncatedThinking);
    }
    Ok(out)
}

fn strip_markdown_code_fence(raw: &str) -> &str {
    let trimmed = raw.trim();
    let open_ticks = trimmed.bytes().take_while(|&b| b == b'`').count();
    if open_ticks >= 3 {
        let after_open = &trimmed[open_ticks..];
        let body = match after_open.find('\n') {
            Some(nl) => &after_open[nl + 1..],
            None => after_open.strip_prefix("json").unwrap_or(after_open),
        };
        let body_trimmed = body.trim_end();
        let close_ticks = body_trimmed
            .bytes()
            .rev()
            .take_while(|&b| b == b'`')
            .count();
        if close_ticks >= 3 {
            return body_trimmed[..body_trimmed.len() - close_ticks].trim();
        }
        if let Some(mut end) = body_trimmed.rfind("```") {
            while end > 0 && body_trimmed.as_bytes()[end - 1] == b'`' {
                end -= 1;
            }
            return body_trimmed[..end].trim();
        }
    }
    trimmed
}

fn extract_primary_label(obj: &serde_json::Map<String, serde_json::Value>) -> Option<String> {
    for key in ["label", "plate_text", "text", "value", "class", "status"] {
        if let Some(val) = obj.get(key).and_then(|v| v.as_str()) {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    for (key, value) in obj {
        if key == "category" {
            continue;
        }
        if let Some(val) = value.as_str() {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

const MAX_SCHEMA_DEPTH: usize = 32;

fn validate_json_against_schema(
    obj: &serde_json::Map<String, serde_json::Value>,
    schema: &serde_json::Value,
) -> Result<(), VlmParseFailure> {
    let root_val = serde_json::Value::Object(obj.clone());
    validate_value_against_schema("$", &root_val, schema, schema, 0)
}

fn resolve_json_pointer<'a>(
    root_schema: &'a serde_json::Value,
    ref_str: &str,
) -> Option<&'a serde_json::Value> {
    if ref_str == "#" {
        return Some(root_schema);
    }
    let pointer = ref_str.strip_prefix('#')?;
    if !pointer.starts_with('/') {
        return None;
    }
    root_schema.pointer(pointer)
}

fn schema_allows_null(
    schema: &serde_json::Value,
    root_schema: &serde_json::Value,
    depth: usize,
) -> bool {
    if depth > MAX_SCHEMA_DEPTH {
        return false;
    }
    if let Some(ref_str) = schema.get("$ref").and_then(|v| v.as_str())
        && let Some(target) = resolve_json_pointer(root_schema, ref_str)
    {
        return schema_allows_null(target, root_schema, depth + 1);
    }
    match schema.get("type") {
        Some(serde_json::Value::String(t)) => t == "null",
        Some(serde_json::Value::Array(arr)) => arr.iter().any(|t| t.as_str() == Some("null")),
        _ => {
            if let Some(any_of) = schema.get("anyOf").and_then(|v| v.as_array()) {
                return any_of
                    .iter()
                    .any(|sub| schema_allows_null(sub, root_schema, depth + 1));
            }
            if let Some(one_of) = schema.get("oneOf").and_then(|v| v.as_array()) {
                return one_of
                    .iter()
                    .any(|sub| schema_allows_null(sub, root_schema, depth + 1));
            }
            false
        }
    }
}

fn is_json_integer(n: &serde_json::Number) -> bool {
    n.is_i64()
        || n.is_u64()
        || n.as_f64().is_some_and(|f| {
            f.is_finite() && f.fract() == 0.0 && f >= i64::MIN as f64 && f <= i64::MAX as f64
        })
}

fn value_matches_schema_type(val: &serde_json::Value, expected_type: &str) -> bool {
    match expected_type {
        "null" => val.is_null(),
        "boolean" => val.is_boolean(),
        "string" => val.is_string(),
        "array" => val.is_array(),
        "object" => val.is_object(),
        "number" => val.as_f64().is_some_and(f64::is_finite),
        "integer" => val.as_number().is_some_and(is_json_integer),
        _ => true,
    }
}

fn validate_value_against_schema(
    path: &str,
    val: &serde_json::Value,
    schema: &serde_json::Value,
    root_schema: &serde_json::Value,
    depth: usize,
) -> Result<(), VlmParseFailure> {
    if depth > MAX_SCHEMA_DEPTH {
        return Err(VlmParseFailure::SchemaRejected(format!(
            "schema recursion depth exceeded at '{path}'"
        )));
    }

    if let Some(allowed) = schema.as_bool() {
        return if allowed {
            Ok(())
        } else {
            Err(VlmParseFailure::SchemaRejected(format!(
                "field '{path}' disallowed by boolean false schema"
            )))
        };
    }

    if let Some(ref_str) = schema.get("$ref").and_then(|v| v.as_str()) {
        let target = resolve_json_pointer(root_schema, ref_str).ok_or_else(|| {
            VlmParseFailure::SchemaRejected(format!(
                "unresolvable schema $ref '{ref_str}' at '{path}'"
            ))
        })?;
        validate_value_against_schema(path, val, target, root_schema, depth + 1)?;
    }

    if let Some(all_of) = schema.get("allOf").and_then(|v| v.as_array()) {
        for sub in all_of {
            validate_value_against_schema(path, val, sub, root_schema, depth + 1)?;
        }
    }

    if let Some(any_of) = schema.get("anyOf").and_then(|v| v.as_array())
        && !any_of.is_empty()
        && !any_of.iter().any(|sub| {
            validate_value_against_schema(path, val, sub, root_schema, depth + 1).is_ok()
        })
    {
        return Err(VlmParseFailure::SchemaRejected(format!(
            "field '{path}' did not satisfy anyOf schema"
        )));
    }

    if let Some(one_of) = schema.get("oneOf").and_then(|v| v.as_array())
        && !one_of.is_empty()
    {
        let matches = one_of
            .iter()
            .filter(|sub| {
                validate_value_against_schema(path, val, sub, root_schema, depth + 1).is_ok()
            })
            .count();
        if matches != 1 {
            return Err(VlmParseFailure::SchemaRejected(format!(
                "field '{path}' matched {matches} oneOf schemas (expected 1)"
            )));
        }
    }

    if let Some(const_val) = schema.get("const")
        && val != const_val
    {
        return Err(VlmParseFailure::SchemaRejected(format!(
            "field '{path}' did not match schema const"
        )));
    }

    if let Some(enum_vals) = schema.get("enum").and_then(|v| v.as_array())
        && !enum_vals.iter().any(|allowed| allowed == val)
    {
        return Err(VlmParseFailure::SchemaRejected(format!(
            "field '{path}' value not in schema enum"
        )));
    }

    if let Some(type_val) = schema.get("type") {
        let allowed_types: Vec<&str> = match type_val {
            serde_json::Value::String(s) => vec![s.as_str()],
            serde_json::Value::Array(arr) => arr.iter().filter_map(|v| v.as_str()).collect(),
            _ => Vec::new(),
        };
        if !allowed_types.is_empty()
            && !allowed_types
                .iter()
                .any(|t| value_matches_schema_type(val, t))
        {
            return Err(VlmParseFailure::SchemaRejected(format!(
                "field '{path}' has unexpected type (expected {allowed_types:?})"
            )));
        }
    }

    match val {
        serde_json::Value::Null => {}
        serde_json::Value::String(s) => {
            let char_len = s.chars().count();
            if let Some(min_len) = schema.get("minLength").and_then(|v| v.as_u64())
                && (char_len as u64) < min_len
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' shorter than minLength {min_len}"
                )));
            }
            if let Some(max_len) = schema.get("maxLength").and_then(|v| v.as_u64())
                && (char_len as u64) > max_len
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' longer than maxLength {max_len}"
                )));
            }
            if let Some(pattern) = schema.get("pattern").and_then(|v| v.as_str()) {
                let re = Regex::new(pattern).map_err(|err| {
                    VlmParseFailure::SchemaRejected(format!(
                        "invalid schema regex for '{path}': {err}"
                    ))
                })?;
                if !re.is_match(s) {
                    return Err(VlmParseFailure::SchemaRejected(format!(
                        "field '{path}' failed schema regex '{pattern}'"
                    )));
                }
            }
        }
        serde_json::Value::Number(num) => {
            let n = num.as_f64().ok_or_else(|| {
                VlmParseFailure::SchemaRejected(format!("field '{path}' must be finite"))
            })?;
            if !n.is_finite() {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' must be finite"
                )));
            }
            if let Some(min) = schema.get("minimum").and_then(|v| v.as_f64())
                && n < min
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' below minimum {min}"
                )));
            }
            if let Some(max) = schema.get("maximum").and_then(|v| v.as_f64())
                && n > max
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' exceeds maximum {max}"
                )));
            }
            if let Some(ex_min) = schema.get("exclusiveMinimum").and_then(|v| v.as_f64())
                && n <= ex_min
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' must be > exclusiveMinimum {ex_min}"
                )));
            }
            if let Some(ex_max) = schema.get("exclusiveMaximum").and_then(|v| v.as_f64())
                && n >= ex_max
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' must be < exclusiveMaximum {ex_max}"
                )));
            }
        }
        serde_json::Value::Bool(_) => {}
        serde_json::Value::Array(items) => {
            if let Some(min_items) = schema.get("minItems").and_then(|v| v.as_u64())
                && (items.len() as u64) < min_items
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' has {} items (< minItems {min_items})",
                    items.len()
                )));
            }
            if let Some(max_items) = schema.get("maxItems").and_then(|v| v.as_u64())
                && (items.len() as u64) > max_items
            {
                return Err(VlmParseFailure::SchemaRejected(format!(
                    "field '{path}' has {} items (> maxItems {max_items})",
                    items.len()
                )));
            }
            if let Some(item_schema) = schema.get("items") {
                if let Some(tuple_schemas) = item_schema.as_array() {
                    for (idx, (elem, elem_schema)) in
                        items.iter().zip(tuple_schemas.iter()).enumerate()
                    {
                        let item_path = format!("{path}[{idx}]");
                        validate_value_against_schema(
                            &item_path,
                            elem,
                            elem_schema,
                            root_schema,
                            depth + 1,
                        )?;
                    }
                } else {
                    for (idx, elem) in items.iter().enumerate() {
                        let item_path = format!("{path}[{idx}]");
                        validate_value_against_schema(
                            &item_path,
                            elem,
                            item_schema,
                            root_schema,
                            depth + 1,
                        )?;
                    }
                }
            }
        }
        serde_json::Value::Object(map) => {
            let props = schema.get("properties").and_then(|v| v.as_object());

            if let Some(required) = schema.get("required").and_then(|v| v.as_array()) {
                for req_key in required.iter().filter_map(|v| v.as_str()) {
                    let req_path = format!("{path}.{req_key}");
                    match map.get(req_key) {
                        None => {
                            return Err(VlmParseFailure::SchemaRejected(format!(
                                "missing required field '{req_path}'"
                            )));
                        }
                        Some(serde_json::Value::Null) => {
                            let null_ok = props
                                .and_then(|p| p.get(req_key))
                                .is_some_and(|ps| schema_allows_null(ps, root_schema, depth + 1));
                            if !null_ok {
                                return Err(VlmParseFailure::SchemaRejected(format!(
                                    "missing required field '{req_path}'"
                                )));
                            }
                        }
                        _ => {}
                    }
                }
            }

            if let Some(props_map) = props {
                for (prop_name, prop_schema) in props_map {
                    let Some(prop_val) = map.get(prop_name) else {
                        continue;
                    };
                    let prop_path = format!("{path}.{prop_name}");
                    validate_value_against_schema(
                        &prop_path,
                        prop_val,
                        prop_schema,
                        root_schema,
                        depth + 1,
                    )?;
                }
            }

            if let Some(addl) = schema.get("additionalProperties") {
                for (key, prop_val) in map {
                    let defined_in_props = props.is_some_and(|p| p.contains_key(key));
                    if defined_in_props {
                        continue;
                    }
                    let prop_path = format!("{path}.{key}");
                    match addl {
                        serde_json::Value::Bool(false) => {
                            return Err(VlmParseFailure::SchemaRejected(format!(
                                "unexpected additional property '{prop_path}'"
                            )));
                        }
                        serde_json::Value::Bool(true) => {}
                        addl_schema => {
                            validate_value_against_schema(
                                &prop_path,
                                prop_val,
                                addl_schema,
                                root_schema,
                                depth + 1,
                            )?;
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

struct PreparedTargetCrop {
    track_key: String,
    track_id: Option<String>,
    target: SampledTarget,
    vlm_crop: EncodedCrop,
    preview_jpeg_b64: Option<String>,
}

struct TrackFrameReading {
    target: SampledTarget,
    track_id: Option<String>,
    reading: ParsedVlmReading,
    preview_jpeg_b64: Option<String>,
}

/// Ramp 1 declarative VLM processor isolated from Stage 1/2 `VisualIndexProcessor`.
pub struct VantageVlmProcessor<G, S, P, V> {
    vantage_vlm_semaphore: Arc<Semaphore>,
    wpi_interval: Duration,
    worker_id: String,
    model_id: String,
    model_version: String,
    max_frames_per_track: usize,
    grant_client: Arc<G>,
    fragment_store: Arc<S>,
    publisher: Arc<P>,
    vlm_client: Arc<V>,
    metrics: Arc<WorkerMetrics>,
    keyframe_decoder: Arc<dyn KeyframeDecoder>,
}

impl<G, S, P, V> Clone for VantageVlmProcessor<G, S, P, V> {
    fn clone(&self) -> Self {
        Self {
            vantage_vlm_semaphore: Arc::clone(&self.vantage_vlm_semaphore),
            wpi_interval: self.wpi_interval,
            worker_id: self.worker_id.clone(),
            model_id: self.model_id.clone(),
            model_version: self.model_version.clone(),
            max_frames_per_track: self.max_frames_per_track,
            grant_client: Arc::clone(&self.grant_client),
            fragment_store: Arc::clone(&self.fragment_store),
            publisher: Arc::clone(&self.publisher),
            vlm_client: Arc::clone(&self.vlm_client),
            metrics: Arc::clone(&self.metrics),
            keyframe_decoder: Arc::clone(&self.keyframe_decoder),
        }
    }
}

impl<G, S, P, V> VantageVlmProcessor<G, S, P, V>
where
    G: GrantClient + 'static,
    S: FragmentStore + 'static,
    P: ResultPublisher + 'static,
    V: VlmClient + 'static,
{
    pub fn new(
        config: &WorkerConfig,
        grant_client: G,
        fragment_store: S,
        publisher: P,
        vlm_client: V,
        metrics: Arc<WorkerMetrics>,
    ) -> Self {
        Self {
            vantage_vlm_semaphore: Arc::new(Semaphore::new(
                config.vantage_vlm_concurrency().max(1),
            )),
            wpi_interval: Duration::from_secs(15),
            worker_id: config.worker_id().to_string(),
            model_id: config.vantage_vlm_model().to_string(),
            model_version: "1.0.0".to_string(),
            max_frames_per_track: 3,
            grant_client: Arc::new(grant_client),
            fragment_store: Arc::new(fragment_store),
            publisher: Arc::new(publisher),
            vlm_client: Arc::new(vlm_client),
            metrics,
            keyframe_decoder: Arc::new(DefaultKeyframeDecoder::new()),
        }
    }

    pub fn with_keyframe_decoder(mut self, decoder: Arc<dyn KeyframeDecoder>) -> Self {
        self.keyframe_decoder = decoder;
        self
    }

    pub fn with_wpi_interval(mut self, interval: Duration) -> Self {
        self.wpi_interval = interval.max(Duration::from_millis(5));
        self
    }

    pub fn with_max_frames_per_track(mut self, max_frames: usize) -> Self {
        self.max_frames_per_track = max_frames.clamp(1, 6);
        self
    }

    pub fn semaphore(&self) -> &Arc<Semaphore> {
        &self.vantage_vlm_semaphore
    }

    pub fn metrics(&self) -> &Arc<WorkerMetrics> {
        &self.metrics
    }

    pub async fn process_delivery<D: JobDelivery + 'static>(
        &self,
        delivery: Arc<D>,
    ) -> Result<VantageJobOutcome, MediaWorkerError> {
        let permit = Arc::clone(&self.vantage_vlm_semaphore)
            .acquire_owned()
            .await
            .map_err(|_| {
                MediaWorkerError::nats_error("vantage_vlm_concurrency semaphore closed")
            })?;
        let _inflight = self.metrics.guard_inflight_vantage_job();

        let job: VantageJobEnvelope = match serde_json::from_slice(delivery.payload()) {
            Ok(parsed) => parsed,
            Err(err) => {
                self.metrics.inc_vantage_jobs_failed();
                let _ = delivery.nak_failed().await;
                return Err(MediaWorkerError::invalid_job_envelope(format!(
                    "malformed VantageJobEnvelope JSON: {err}"
                )));
            }
        };

        let wpi_guard = spawn_wpi_heartbeat(
            Arc::clone(&delivery),
            self.wpi_interval,
            Duration::from_millis(job.budget_ms),
        );

        let execution_res = self.execute_job(&job, permit).await;
        wpi_guard.stop().await;

        match execution_res {
            Ok(VantageJobExecution::Gone) => {
                self.metrics.inc_vantage_jobs_gone();
                delivery.ack_completed().await?;
                Ok(VantageJobOutcome::Gone)
            }
            Ok(VantageJobExecution::ReadyResult(envelope)) => {
                let msg_id = format!("vantage-result:{}", job.job_id);
                if let Err(pub_err) = self
                    .publisher
                    .publish_vantage_result(&msg_id, &envelope)
                    .await
                {
                    self.metrics.inc_vantage_jobs_failed();
                    let _ = delivery.nak_failed().await;
                    return Err(pub_err);
                }

                delivery.ack_completed().await?;
                self.metrics.inc_vantage_jobs_completed();
                Ok(VantageJobOutcome::Completed(envelope))
            }
            Err(err) => {
                self.metrics.inc_vantage_jobs_failed();
                let _ = delivery.nak_failed().await;
                Err(err)
            }
        }
    }

    async fn execute_job(
        &self,
        job: &VantageJobEnvelope,
        permit: tokio::sync::OwnedSemaphorePermit,
    ) -> Result<VantageJobExecution, MediaWorkerError> {
        validate_vlm_job(job)?;
        let job_deadline = Instant::now() + Duration::from_millis(job.budget_ms);
        let catalog_entry_id = job.catalog_entry_id.ok_or_else(|| {
            MediaWorkerError::invalid_job_envelope("missing catalog_entry_id on recorded_block job")
        })?;
        let descriptor_sha256 = job.descriptor_sha256.as_deref().ok_or_else(|| {
            MediaWorkerError::invalid_job_envelope(
                "missing descriptor_sha256 on recorded_block job",
            )
        })?;
        let vlm_cfg = job.vlm_config.as_ref().ok_or_else(|| {
            MediaWorkerError::invalid_job_envelope("Ramp 1 VLM job requires vlm_config")
        })?;

        let grant_req = ReadGrantRequest::new(
            job.job_id.to_string(),
            catalog_entry_id.to_string(),
            descriptor_sha256,
        );
        let plan = match self.grant_client.acquire_read_grant(&grant_req).await? {
            GrantResolution::Gone => return Ok(VantageJobExecution::Gone),
            GrantResolution::Admitted(plan) => plan,
        };

        let verified_block = self.fragment_store.fetch_verified_block(&plan).await?;

        let processor = self.clone();
        let job_clone = job.clone();
        let dispatch = tracing::dispatcher::get_default(Clone::clone);
        let prepared_crops = tokio::task::spawn_blocking(move || {
            let _subscriber = tracing::dispatcher::set_default(&dispatch);
            processor.decode_and_extract_crops(&job_clone, &verified_block)
        })
        .await
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))??;

        let _permit = permit;
        let system_prompt = vlm_cfg
            .system_prompt
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(DEFAULT_VLM_SYSTEM_PROMPT)
            .to_string();
        let model = vlm_cfg
            .model_profile
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(&self.model_id)
            .to_string();
        let default_category = default_observation_category(job);

        let mut readings_by_track: BTreeMap<String, Vec<TrackFrameReading>> = BTreeMap::new();
        for prepared in prepared_crops {
            let Some(remaining_budget) = job_deadline.checked_duration_since(Instant::now()) else {
                self.metrics.inc_vantage_vlm_request("transport_error");
                return Err(MediaWorkerError::deadline_exceeded(format!(
                    "Vantage VLM job {} exceeded budget_ms={} before completing all crops",
                    job.job_id, job.budget_ms
                )));
            };
            if remaining_budget.is_zero() {
                self.metrics.inc_vantage_vlm_request("transport_error");
                return Err(MediaWorkerError::deadline_exceeded(format!(
                    "Vantage VLM job {} exhausted budget_ms={}",
                    job.job_id, job.budget_ms
                )));
            }

            let req = VlmChatRequest {
                model: model.clone(),
                system_prompt: system_prompt.clone(),
                user_prompt: vlm_cfg.prompt.clone(),
                crop_jpeg_b64: prepared.vlm_crop.to_base64(),
                max_tokens: vlm_cfg.max_tokens,
                temperature: vlm_cfg.temperature,
                json_schema: vlm_cfg.json_schema.clone(),
                schema_name: job.signal_schema_id.clone(),
            };

            let started = Instant::now();
            let call_res = self
                .vlm_client
                .chat_completion_with_budget(&req, remaining_budget)
                .await;
            self.metrics
                .observe_vantage_vlm_latency(started.elapsed().as_secs_f64());

            let raw_content = match call_res {
                Ok(content) => content,
                Err(err) => {
                    self.metrics.inc_vantage_vlm_request(err.outcome_label());
                    if Instant::now() >= job_deadline {
                        return Err(MediaWorkerError::deadline_exceeded(err.to_string()));
                    }
                    return Err(MediaWorkerError::inference_failed(err.to_string()));
                }
            };

            match parse_vlm_json_response(
                &raw_content,
                vlm_cfg.json_schema.as_ref(),
                &default_category,
            ) {
                Ok(reading) => {
                    self.metrics.inc_vantage_vlm_request("ok");
                    readings_by_track
                        .entry(prepared.track_key)
                        .or_default()
                        .push(TrackFrameReading {
                            target: prepared.target,
                            track_id: prepared.track_id,
                            reading,
                            preview_jpeg_b64: prepared.preview_jpeg_b64,
                        });
                }
                Err(failure) => {
                    self.metrics
                        .inc_vantage_vlm_request(failure.outcome_label());
                    warn!(
                        job_id = %job.job_id,
                        track_key = %prepared.track_key,
                        outcome = failure.outcome_label(),
                        "rejected malformed or non-compliant VLM output without fabricating observation"
                    );
                }
            }
        }

        let mut observations = Vec::with_capacity(readings_by_track.len());
        for (_, readings) in readings_by_track {
            if let Some(obs) = vote_track_observations(job, &readings) {
                observations.push(obs);
            }
        }

        let mut envelope = VantageResultEnvelope {
            schema_version: VANTAGE_RESULT_SCHEMA_VERSION.to_string(),
            job_id: Some(job.job_id),
            pack_id: job.resolved_pack_id(),
            pipeline_id: job.pipeline_id.clone(),
            pipeline_version: job.pipeline_version.clone(),
            worker_kind: WorkerKind::CameraVlm,
            worker_id: self.worker_id.clone(),
            model_id: model,
            model_version: self.model_version.clone(),
            capability: job.capability.clone(),
            source_mode: SourceMode::RecordedBlock,
            camera_source_id: job.camera_source_id,
            stream_profile_id: job.stream_profile_id,
            catalog_entry_id: job.catalog_entry_id,
            descriptor_sha256: job.descriptor_sha256.clone(),
            observations,
        };

        trim_result_crops_within_ceiling(&mut envelope, MAX_VANTAGE_RESULT_ENVELOPE_BYTES)?;
        envelope
            .validate()
            .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;

        debug!(
            job_id = %job.job_id,
            observations = envelope.observations.len(),
            "completed Ramp 1 Vantage VLM inference"
        );
        Ok(VantageJobExecution::ReadyResult(Box::new(envelope)))
    }

    fn decode_and_extract_crops(
        &self,
        job: &VantageJobEnvelope,
        verified_block: &VerifiedKeyframeBlock,
    ) -> Result<Vec<PreparedTargetCrop>, MediaWorkerError> {
        let (_codec, init_res) = parse_init_segment_with_codec(verified_block.init_bytes());
        let init_seg = init_res.and_then(|init| {
            self.keyframe_decoder.validate_init(&init)?;
            Ok(init)
        });

        let fragments_by_seq: BTreeMap<u32, &_> = verified_block
            .fragments()
            .iter()
            .map(|f| (f.sequence(), f))
            .collect();

        let needed_seqs: BTreeSet<u32> = job
            .sampled_targets
            .iter()
            .map(|t| t.fragment_sequence)
            .collect();

        let mut decoded_frames: BTreeMap<u32, RgbFrame> = BTreeMap::new();
        let mut missing_seqs: BTreeSet<u32> = BTreeSet::new();
        for seq in needed_seqs {
            let Some(frag) = fragments_by_seq.get(&seq) else {
                missing_seqs.insert(seq);
                continue;
            };
            let decoded = match &init_seg {
                Ok(init) => {
                    let (_pts, sample) = parse_timed_fragment(frag.bytes(), init);
                    sample.map_err(|err| err.error_class()).and_then(|parsed| {
                        self.keyframe_decoder
                            .decode_keyframe(init, &parsed)
                            .map_err(|err| err.reason())
                    })
                }
                Err(err) => Err(err.error_class()),
            };
            match decoded {
                Ok(frame) => {
                    self.metrics.inc_keyframes_decoded(1);
                    decoded_frames.insert(seq, frame);
                }
                Err(reason) => {
                    self.metrics.inc_keyframes_undecodable(reason);
                }
            }
        }

        let mut targets_by_track: BTreeMap<String, Vec<&SampledTarget>> = BTreeMap::new();
        for target in &job.sampled_targets {
            let track_key = target
                .track_id
                .clone()
                .unwrap_or_else(|| target.target_key.clone());
            targets_by_track.entry(track_key).or_default().push(target);
        }

        let vlm_crop_cfg = job.crop_policy.to_crop_config();
        let preview_crop_cfg = CropConfig {
            padding_ratio: vlm_crop_cfg.padding_ratio,
            min_bbox_width_px: vlm_crop_cfg.min_bbox_width_px,
            min_bbox_height_px: vlm_crop_cfg.min_bbox_height_px,
            ..CropConfig::for_stored_preview()
        };
        let full_frame_vlm_cfg = CropConfig {
            padding_ratio: 0.0,
            min_bbox_width_px: 1,
            min_bbox_height_px: 1,
            ..vlm_crop_cfg.clone()
        };
        let full_frame_preview_cfg = CropConfig {
            padding_ratio: 0.0,
            min_bbox_width_px: 1,
            min_bbox_height_px: 1,
            ..preview_crop_cfg.clone()
        };

        let mut prepared = Vec::new();
        for (track_key, mut track_targets) in targets_by_track {
            let mut scored: Vec<(f32, &SampledTarget)> = Vec::with_capacity(track_targets.len());
            for target in track_targets.drain(..) {
                if missing_seqs.contains(&target.fragment_sequence) {
                    self.metrics.inc_vantage_crops_skipped("missing_fragment");
                    continue;
                }
                let Some(frame) = decoded_frames.get(&target.fragment_sequence) else {
                    self.metrics.inc_vantage_crops_skipped("undecodable_frame");
                    continue;
                };
                let score_bbox = target.bbox.unwrap_or([0.0, 0.0, 1.0, 1.0]);
                let area = ((score_bbox[2] - score_bbox[0]).max(0.0)
                    * (score_bbox[3] - score_bbox[1]).max(0.0))
                .max(1e-4);
                let sharpness = frame
                    .as_media_core_frame()
                    .crop_sharpness_factor(score_bbox);
                let quality_score = target.confidence * area * sharpness;
                scored.push((quality_score, target));
            }

            scored.sort_by(|a, b| {
                b.0.total_cmp(&a.0)
                    .then_with(|| a.1.fragment_sequence.cmp(&b.1.fragment_sequence))
                    .then_with(|| a.1.target_key.cmp(&b.1.target_key))
            });

            let mut accepted_for_track = 0usize;
            for (_, target) in scored {
                if accepted_for_track >= self.max_frames_per_track {
                    break;
                }
                let frame = &decoded_frames[&target.fragment_sequence];
                let core_frame = frame.as_media_core_frame();

                let use_full_frame =
                    job.input_mode == InputMode::FullFrame || target.bbox.is_none();
                let outcome = if use_full_frame {
                    if job.roi_polygons.is_empty() {
                        crop_detection_jpeg(core_frame, [0.0, 0.0, 1.0, 1.0], &full_frame_vlm_cfg)
                    } else {
                        crop_roi_polygons_jpeg(
                            core_frame,
                            &job.roi_polygons,
                            &full_frame_vlm_cfg,
                            true,
                        )
                    }
                } else {
                    let bbox = target.bbox.expect("bbox checked non-None");
                    if job.roi_polygons.is_empty() {
                        crop_detection_jpeg(core_frame, bbox, &vlm_crop_cfg)
                    } else {
                        crop_detection_in_rois_jpeg(
                            core_frame,
                            bbox,
                            &job.roi_polygons,
                            &vlm_crop_cfg,
                        )
                    }
                }
                .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?;

                match outcome {
                    CropOutcome::Skipped { reason, .. } => {
                        self.metrics.inc_vantage_crops_skipped(reason.as_str());
                    }
                    CropOutcome::Encoded(vlm_crop) => {
                        let preview_jpeg_b64 =
                            if vlm_crop.jpeg_bytes.len() <= MAX_STORED_CROP_JPEG_BYTES {
                                Some(vlm_crop.to_base64())
                            } else {
                                let preview_outcome = if use_full_frame {
                                    if job.roi_polygons.is_empty() {
                                        crop_detection_jpeg(
                                            core_frame,
                                            [0.0, 0.0, 1.0, 1.0],
                                            &full_frame_preview_cfg,
                                        )
                                    } else {
                                        crop_roi_polygons_jpeg(
                                            core_frame,
                                            &job.roi_polygons,
                                            &full_frame_preview_cfg,
                                            true,
                                        )
                                    }
                                } else {
                                    let bbox = target.bbox.expect("bbox checked non-None");
                                    crop_detection_jpeg(core_frame, bbox, &preview_crop_cfg)
                                };
                                match preview_outcome {
                                    Ok(CropOutcome::Encoded(preview)) => Some(preview.to_base64()),
                                    _ => None,
                                }
                            };

                        prepared.push(PreparedTargetCrop {
                            track_key: track_key.clone(),
                            track_id: target.track_id.clone(),
                            target: target.clone(),
                            vlm_crop,
                            preview_jpeg_b64,
                        });
                        accepted_for_track += 1;
                    }
                }
            }
        }

        Ok(prepared)
    }
}

enum VantageJobExecution {
    Gone,
    ReadyResult(Box<VantageResultEnvelope>),
}

fn validate_vlm_job(job: &VantageJobEnvelope) -> Result<(), MediaWorkerError> {
    if job.schema_version != VANTAGE_JOB_SCHEMA_VERSION {
        return Err(MediaWorkerError::invalid_job_envelope(format!(
            "unsupported VantageJobEnvelope schema_version '{}'",
            job.schema_version
        )));
    }
    if job.source_mode != SourceMode::RecordedBlock {
        return Err(MediaWorkerError::invalid_job_envelope(
            "Ramp 1 media-worker VLM runner only supports source_mode=recorded_block",
        ));
    }
    job.validate()
        .map_err(|err| MediaWorkerError::invalid_job_envelope(err.to_string()))?;
    let vlm_cfg = job.vlm_config.as_ref().ok_or_else(|| {
        MediaWorkerError::invalid_job_envelope("Ramp 1 VLM job missing required vlm_config")
    })?;
    vlm_cfg
        .validate_for_vlm()
        .map_err(|err| MediaWorkerError::invalid_job_envelope(err.to_string()))?;
    Ok(())
}

fn default_observation_category(job: &VantageJobEnvelope) -> String {
    if job.signal_schema_id.contains("alpr") || job.signal_schema_id.contains("plate") {
        "license_plate".to_string()
    } else {
        job.signal_schema_id.clone()
    }
}

fn vote_track_observations(
    job: &VantageJobEnvelope,
    readings: &[TrackFrameReading],
) -> Option<VantageObservationInput> {
    if readings.is_empty() {
        return None;
    }

    struct LabelBucket<'a> {
        count: usize,
        confidence_sum: f64,
        best_confidence: f32,
        best_reading: &'a TrackFrameReading,
    }

    let mut buckets: BTreeMap<String, LabelBucket<'_>> = BTreeMap::new();
    for item in readings {
        let key = item.reading.label.clone();
        let conf = item.reading.confidence;
        buckets
            .entry(key)
            .and_modify(|b| {
                b.count += 1;
                b.confidence_sum += f64::from(conf);
                if conf > b.best_confidence {
                    b.best_confidence = conf;
                    b.best_reading = item;
                }
            })
            .or_insert_with(|| LabelBucket {
                count: 1,
                confidence_sum: f64::from(conf),
                best_confidence: conf,
                best_reading: item,
            });
    }

    let (winning_label, winner) = buckets.into_iter().max_by(|(la, a), (lb, b)| {
        a.count
            .cmp(&b.count)
            .then_with(|| a.confidence_sum.total_cmp(&b.confidence_sum))
            .then_with(|| a.best_confidence.total_cmp(&b.best_confidence))
            .then_with(|| lb.cmp(la))
    })?;

    let chosen = winner.best_reading;
    let observation_key = VantageObservationInput::compute_observation_key(
        &job.pipeline_id,
        Some(job.camera_source_id),
        job.catalog_entry_id,
        Some(chosen.target.fragment_sequence),
        Some(u64::from(chosen.target.fragment_sequence)),
        chosen
            .track_id
            .as_deref()
            .or(Some(chosen.target.target_key.as_str())),
        &chosen.reading.category,
    );

    let mut search_parts = vec![winning_label.clone(), chosen.reading.category.clone()];
    for val in chosen.reading.attributes.values() {
        if let Some(s) = val.as_str() {
            let trimmed = s.trim();
            if !trimmed.is_empty() && !search_parts.iter().any(|existing| existing == trimmed) {
                search_parts.push(trimmed.to_string());
            }
        }
    }

    Some(VantageObservationInput {
        observation_key,
        fragment_sequence: Some(chosen.target.fragment_sequence),
        frame_sequence: Some(u64::from(chosen.target.fragment_sequence)),
        media_pts_ns: Some(chosen.target.media_pts_ns),
        timeline_ts_us: chosen.target.timeline_ts_us,
        time_basis: chosen.target.time_basis,
        track_id: chosen.track_id.clone(),
        category: chosen.reading.category.clone(),
        label: winning_label,
        confidence: chosen.reading.confidence,
        bbox: chosen.target.bbox,
        crop_jpeg_b64: chosen.preview_jpeg_b64.clone(),
        attributes: serde_json::Value::Object(chosen.reading.attributes.clone()),
        signal_schema_id: job.signal_schema_id.clone(),
        signal_schema_version: job.signal_schema_version.clone(),
        display_contract_id: job.display_contract_id.clone(),
        search_text: Some(search_parts.join(" ")),
    })
}

fn trim_result_crops_within_ceiling(
    envelope: &mut VantageResultEnvelope,
    max_bytes: usize,
) -> Result<(), MediaWorkerError> {
    let cur_len = serde_json::to_vec(envelope)
        .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?
        .len();
    if cur_len <= max_bytes {
        return Ok(());
    }

    let mut drop_order: Vec<(usize, f32)> = envelope
        .observations
        .iter()
        .enumerate()
        .filter(|(_, obs)| obs.crop_jpeg_b64.is_some())
        .map(|(idx, obs)| (idx, obs.confidence))
        .collect();
    // Drop lowest-confidence crop previews first.
    drop_order.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0)));

    for (idx, _) in drop_order {
        envelope.observations[idx].crop_jpeg_b64 = None;
        let len = serde_json::to_vec(envelope)
            .map_err(|err| MediaWorkerError::inference_failed(err.to_string()))?
            .len();
        if len <= max_bytes {
            return Ok(());
        }
    }

    Err(MediaWorkerError::inference_failed(format!(
        "VantageResultEnvelope exceeds {max_bytes} bytes even after trimming all crop_jpeg_b64 previews"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cmaf::{assemble_cmaf_block, avcc_box, build_fragment_m4s, build_init_mp4};
    use crate::errors::MediaWorkerErrorKind;
    use crate::grants::{LocalGrantTarget, LocalPlanSpec, ReadGrantPlan};
    use crate::keyframe_decoder_tests::{annex_b_nals, encode_idr, nals_of_type};
    use crate::range_reader::{VerifiedKeyframeBlock, coalesce_fragment_ranges};
    use base64::Engine as _;
    use parking_lot::Mutex;
    use rusty_h264_common::YuvFrame;
    use rusty_h264_encoder::EncoderConfig;
    use serviceradar_media_core::TimeBasis;
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use uuid::Uuid;

    struct MockGrantClient {
        resolution: GrantResolution,
    }

    impl GrantClient for MockGrantClient {
        async fn acquire_read_grant(
            &self,
            _request: &ReadGrantRequest,
        ) -> Result<GrantResolution, MediaWorkerError> {
            Ok(self.resolution.clone())
        }
    }

    struct MockFragmentStore {
        block: VerifiedKeyframeBlock,
    }

    impl FragmentStore for MockFragmentStore {
        async fn fetch_verified_block(
            &self,
            _plan: &ReadGrantPlan,
        ) -> Result<VerifiedKeyframeBlock, MediaWorkerError> {
            Ok(self.block.clone())
        }
    }

    struct RecordingVantageDelivery {
        payload: Vec<u8>,
        events: Arc<Mutex<Vec<String>>>,
    }

    impl JobDelivery for RecordingVantageDelivery {
        fn payload(&self) -> &[u8] {
            &self.payload
        }

        async fn send_in_progress(&self) -> Result<(), MediaWorkerError> {
            self.events.lock().push("wpi".to_string());
            Ok(())
        }

        async fn ack_completed(&self) -> Result<(), MediaWorkerError> {
            self.events.lock().push("ack".to_string());
            Ok(())
        }

        async fn nak_failed(&self) -> Result<(), MediaWorkerError> {
            self.events.lock().push("nak".to_string());
            Ok(())
        }
    }

    struct RecordingVantagePublisher {
        events: Arc<Mutex<Vec<String>>>,
        published: Arc<Mutex<Vec<(String, VantageResultEnvelope)>>>,
        fail_publish: bool,
    }

    impl ResultPublisher for RecordingVantagePublisher {
        async fn publish_visual_result(
            &self,
            _msg_id: &str,
            _envelope: &crate::worker::VisualIndexResultEnvelope,
        ) -> Result<(), MediaWorkerError> {
            Ok(())
        }

        async fn publish_vantage_result(
            &self,
            msg_id: &str,
            envelope: &VantageResultEnvelope,
        ) -> Result<(), MediaWorkerError> {
            if self.fail_publish {
                self.events
                    .lock()
                    .push("publish_vantage_failed".to_string());
                return Err(MediaWorkerError::nats_error("simulated publish failure"));
            }
            self.events
                .lock()
                .push("publish_vantage_result".to_string());
            self.published
                .lock()
                .push((msg_id.to_string(), envelope.clone()));
            Ok(())
        }

        async fn publish_telemetry_snapshot(
            &self,
            _payload_json: &[u8],
        ) -> Result<(), MediaWorkerError> {
            Ok(())
        }
    }

    fn rgb_to_yuv420_limited(frame: &serviceradar_media_core::RgbFrame) -> YuvFrame {
        let w = frame.width() as usize;
        let h = frame.height() as usize;
        let mut y = Vec::with_capacity(w * h);
        let mut u = Vec::with_capacity((w / 2) * (h / 2));
        let mut v = Vec::with_capacity((w / 2) * (h / 2));
        for row in 0..h {
            for col in 0..w {
                let [r, g, b] = frame.pixel_at(col as u32, row as u32);
                let rf = f64::from(r);
                let gf = f64::from(g);
                let bf = f64::from(b);
                let y_val = (16.0 + (65.738 * rf + 129.057 * gf + 25.064 * bf) / 256.0)
                    .round()
                    .clamp(16.0, 235.0) as u8;
                y.push(y_val);
                if row % 2 == 0 && col % 2 == 0 {
                    let u_val = (128.0 + (-37.945 * rf - 74.494 * gf + 112.439 * bf) / 256.0)
                        .round()
                        .clamp(16.0, 240.0) as u8;
                    let v_val = (128.0 + (112.439 * rf - 94.154 * gf - 18.285 * bf) / 256.0)
                        .round()
                        .clamp(16.0, 240.0) as u8;
                    u.push(u_val);
                    v.push(v_val);
                }
            }
        }
        YuvFrame {
            width: w,
            height: h,
            y,
            u,
            v,
        }
    }

    fn build_1080p_synthetic_block(
        fragment_sequences: &[u32],
    ) -> (crate::SyntheticCmafBlock, VerifiedKeyframeBlock) {
        let mut rgb = serviceradar_media_core::RgbFrame::solid(1920, 1080, [35, 42, 54]);
        // Vehicle at [0.30, 0.45, 0.55, 0.80]
        rgb.fill_rect(576, 486, 1056, 864, [215, 220, 230]);
        // Synthetic license plate pattern inside vehicle
        rgb.fill_rect(730, 690, 900, 750, [245, 245, 245]);
        for stripe in (742..890).step_by(18) {
            rgb.fill_rect(stripe, 702, stripe + 8, 738, [20, 20, 25]);
        }

        let yuv = rgb_to_yuv420_limited(&rgb);
        let annex_b = encode_idr(EncoderConfig::baseline(1920, 1080), &yuv);
        let nals = annex_b_nals(&annex_b);
        let sps = nals_of_type(&nals, 7);
        let pps = nals_of_type(&nals, 8);
        let mut sample: Vec<&[u8]> = vec![&[0x09, 0x10]];
        sample.extend(nals_of_type(&nals, 5));

        let init_mp4 = build_init_mp4(1920, 1080, 90_000, b"avc1", &avcc_box(&sps, &pps));
        let mut fragments = Vec::with_capacity(fragment_sequences.len());
        for &seq in fragment_sequences {
            let start_ns = u64::from(seq) * 2_000_000_000;
            let bytes = build_fragment_m4s(seq, start_ns, 2_000_000_000, 90_000, &sample);
            fragments.push((seq, start_ns, 2_000_000_000, bytes));
        }

        let cmaf_block = assemble_cmaf_block(1920, 1080, 90_000, init_mp4, fragments.clone())
            .expect("assemble 1080p CMAF block");

        let raw_frags = cmaf_block
            .fragment_plans()
            .iter()
            .cloned()
            .zip(fragments.into_iter().map(|(_, _, _, bytes)| bytes))
            .collect();
        let verified_block = VerifiedKeyframeBlock::from_unverified(
            cmaf_block.init_mp4().to_vec(),
            cmaf_block.init_sha256(),
            raw_frags,
        )
        .expect("verify 1080p CMAF block");
        (cmaf_block, verified_block)
    }

    fn build_local_plan_for_job(
        job: &VantageJobEnvelope,
        block: &crate::SyntheticCmafBlock,
    ) -> ReadGrantPlan {
        ReadGrantPlan::from_local_spec(LocalPlanSpec {
            job_id: job.job_id.to_string(),
            catalog_entry_id: job.catalog_entry_id.unwrap().to_string(),
            camera_source_id: job.camera_source_id.to_string(),
            stream_profile_id: job.stream_profile_id.to_string(),
            storage_id: "00000000-0000-4000-8000-000000000301".to_string(),
            block_key: "22".repeat(32),
            descriptor_sha256: job.descriptor_sha256.clone().unwrap(),
            init: block.init_plan().clone(),
            fragments: block.fragment_plans().to_vec(),
            coalesced_ranges: coalesce_fragment_ranges(block.fragment_plans()).expect("coalesce"),
            local: LocalGrantTarget::new(
                Some("edge-nvr-01.example.invalid".to_string()),
                "00000000-0000-4000-8000-000000000301",
                "22".repeat(32),
            ),
        })
    }

    fn spawn_mock_vlm_server(
        responses: Vec<(u16, String)>,
    ) -> (
        String,
        Arc<Mutex<Vec<serde_json::Value>>>,
        std::thread::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock VLM server");
        let addr = listener.local_addr().expect("local_addr");
        let captured_reqs: Arc<Mutex<Vec<serde_json::Value>>> = Arc::new(Mutex::new(Vec::new()));
        let req_sink = Arc::clone(&captured_reqs);
        let mut queue: VecDeque<(u16, String)> = responses.into();

        let handle = std::thread::spawn(move || {
            while let Some((status, body)) = queue.pop_front() {
                let (mut sock, _) = listener.accept().expect("accept VLM request");
                let mut reader = BufReader::new(sock.try_clone().expect("clone sock"));
                let mut req_line = String::new();
                reader.read_line(&mut req_line).expect("read request line");
                assert!(req_line.starts_with("POST /v1/chat/completions "));

                let mut content_len = 0usize;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).expect("read header");
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        break;
                    }
                    if let Some((k, v)) = trimmed.split_once(':')
                        && k.trim().eq_ignore_ascii_case("content-length")
                    {
                        content_len = v.trim().parse().unwrap_or(0);
                    }
                }
                let mut req_body = vec![0u8; content_len];
                reader.read_exact(&mut req_body).expect("read body");
                let parsed: serde_json::Value =
                    serde_json::from_slice(&req_body).expect("parse request JSON");
                req_sink.lock().push(parsed);

                let reason = if status == 200 {
                    "OK"
                } else {
                    "Internal Server Error"
                };
                let http_resp = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                sock.write_all(http_resp.as_bytes())
                    .expect("write VLM response");
            }
        });

        (
            format!("http://{addr}/v1/chat/completions"),
            captured_reqs,
            handle,
        )
    }

    fn alpr_vlm_schema() -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["plate_text", "confidence"],
            "properties": {
                "plate_text": {
                    "type": "string",
                    "pattern": "^[A-Z0-9-]{2,12}$"
                },
                "region": { "type": "string" },
                "vehicle_color": { "type": "string" },
                "confidence": { "type": "number", "minimum": 0.0, "maximum": 1.0 }
            }
        })
    }

    fn parse_jpeg_sof0_dims(jpeg: &[u8]) -> Option<(u16, u16)> {
        if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
            return None;
        }
        let mut i = 2usize;
        while i + 3 < jpeg.len() {
            if jpeg[i] != 0xFF {
                return None;
            }
            let marker = jpeg[i + 1];
            if marker == 0xD9 {
                break;
            }
            let len = u16::from_be_bytes([jpeg[i + 2], jpeg[i + 3]]) as usize;
            if marker == 0xC0 && len >= 7 && i + 2 + len <= jpeg.len() {
                let h = u16::from_be_bytes([jpeg[i + 5], jpeg[i + 6]]);
                let w = u16::from_be_bytes([jpeg[i + 7], jpeg[i + 8]]);
                return Some((w, h));
            }
            if marker == 0xDA {
                break;
            }
            i += 2 + len;
        }
        None
    }

    fn make_synthetic_alpr_job(
        descriptor_sha256: String,
        targets: Vec<SampledTarget>,
    ) -> VantageJobEnvelope {
        serde_json::from_value(serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": Uuid::new_v4(),
            "pack_id": "io.serviceradar.vantage-alpr",
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "pipeline_version": "1.0.0",
            "capability": "vantage.alpr.v1",
            "source_mode": "recorded_block",
            "camera_source_id": Uuid::new_v4(),
            "stream_profile_id": Uuid::new_v4(),
            "catalog_entry_id": Uuid::new_v4(),
            "descriptor_sha256": descriptor_sha256,
            "input_mode": "detection_crop",
            "roi_polygons": [],
            "crop_policy": {
                "padding_ratio": 0.15,
                "min_bbox_width_px": 96,
                "max_dimension": 640,
                "max_bytes": 98304
            },
            "sampled_targets": targets,
            "signal_schema_id": "alpr_plate_read",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "alpr_plate_read",
            "vlm_config": {
                "prompt": "Read the license plate at Gate West 01",
                "model_profile": "qwen3.5-4b",
                "max_tokens": 256,
                "temperature": 0.0,
                "json_schema": alpr_vlm_schema()
            }
        }))
        .expect("construct synthetic ALPR job")
    }

    #[tokio::test]
    async fn ramp1_vlm_decodes_1080p_cmaf_skips_tiny_bbox_and_votes_multi_frame_consensus() {
        // 3 keyframes for track "1" (consensus: SR-0100 x2 vs SR-O100 x1) +
        // 1 keyframe for track "2" (TEST-742) + 1 tiny 58px bbox (track "3", skipped before VLM).
        let (cmaf_block, verified_block) = build_1080p_synthetic_block(&[1, 2, 3]);
        let targets = vec![
            SampledTarget {
                target_key: "t1-f1".to_string(),
                track_id: Some("1".to_string()),
                fragment_sequence: 1,
                media_pts_ns: 2_000_000_000,
                timeline_ts_us: 1_700_000_002_000_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.91,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
            SampledTarget {
                target_key: "t1-f2".to_string(),
                track_id: Some("1".to_string()),
                fragment_sequence: 2,
                media_pts_ns: 4_000_000_000,
                timeline_ts_us: 1_700_000_004_000_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.95,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
            SampledTarget {
                target_key: "t1-f3".to_string(),
                track_id: Some("1".to_string()),
                fragment_sequence: 3,
                media_pts_ns: 6_000_000_000,
                timeline_ts_us: 1_700_000_006_000_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.70,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
            SampledTarget {
                target_key: "t2-f1".to_string(),
                track_id: Some("2".to_string()),
                fragment_sequence: 1,
                media_pts_ns: 2_000_000_000,
                timeline_ts_us: 1_700_000_002_500_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.88,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
            // Distant tiny bbox: 0.03 * 1920 = 58 px < 96 px -> skipped BEFORE calling VLM.
            SampledTarget {
                target_key: "t3-tiny".to_string(),
                track_id: Some("3".to_string()),
                fragment_sequence: 1,
                media_pts_ns: 2_000_000_000,
                timeline_ts_us: 1_700_000_002_800_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.65,
                bbox: Some([0.05, 0.05, 0.08, 0.09]),
            },
        ];

        let job = make_synthetic_alpr_job(cmaf_block.descriptor_sha256().to_string(), targets);
        let plan = build_local_plan_for_job(&job, &cmaf_block);

        // Track keys iterate in BTreeMap order ("1" x3 frames, then "2" x1 frame = 4 VLM calls total).
        let mk_resp = |plate: &str, conf: f64| {
            serde_json::json!({
                "choices": [{
                    "message": {
                        "content": serde_json::json!({
                            "plate_text": plate,
                            "region": "US-CA",
                            "vehicle_color": "silver",
                            "confidence": conf
                        }).to_string()
                    }
                }]
            })
            .to_string()
        };
        let (vlm_url, captured_reqs, server_handle) = spawn_mock_vlm_server(vec![
            (200, mk_resp("SR-0100", 0.95)),
            (200, mk_resp("SR-0100", 0.91)),
            (200, mk_resp("SR-O100", 0.70)),
            (200, mk_resp("TEST-742", 0.92)),
        ]);

        let cfg = WorkerConfig::cpu_explicit_default()
            .with_vantage_vlm(true, Some(vlm_url.clone()), "qwen3.5-4b")
            .with_worker_id("media-worker-synthetic-01");
        let metrics = Arc::new(WorkerMetrics::new());
        let events = Arc::new(Mutex::new(Vec::new()));
        let published = Arc::new(Mutex::new(Vec::new()));

        let processor = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan)),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events),
                published: Arc::clone(&published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg).expect("vlm client"),
            Arc::clone(&metrics),
        );

        let delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("serialize job"),
            events: Arc::clone(&events),
        });
        let outcome = processor
            .process_delivery(delivery)
            .await
            .expect("Vantage VLM job should succeed");
        server_handle.join().expect("join mock VLM server");

        // Tiny bbox was skipped BEFORE calling VLM (4 requests, not 5).
        let reqs = captured_reqs.lock();
        assert_eq!(reqs.len(), 4);
        for req in reqs.iter() {
            assert_eq!(req["enable_thinking"], false);
            assert_eq!(req["chat_template_kwargs"]["enable_thinking"], false);
            assert_eq!(req["max_tokens"], 256);
            assert_eq!(req["response_format"]["type"], "json_schema");
            let url = req["messages"][1]["content"][1]["image_url"]["url"]
                .as_str()
                .expect("image data url");
            let b64 = url
                .strip_prefix("data:image/jpeg;base64,")
                .expect("jpeg data url");
            let jpeg = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .expect("valid base64");
            assert!(jpeg.len() <= 96 * 1024);
            let (w, h) = parse_jpeg_sof0_dims(&jpeg).expect("SOF0 Baseline JFIF");
            assert!(
                w > 480 && w <= 640,
                "expected full-res native crop width > 480, got {w}"
            );
            assert!(
                h > 270 && h <= 640,
                "expected native crop height > 270px thumbnail, got {h}"
            );
        }

        // Strict publish-before-ACK ordering and Nats-Msg-Id.
        assert_eq!(events.lock().as_slice(), &["publish_vantage_result", "ack"]);
        let pub_guard = published.lock();
        assert_eq!(pub_guard.len(), 1);
        assert_eq!(pub_guard[0].0, format!("vantage-result:{}", job.job_id));

        let env = outcome.completed_envelope().expect("completed envelope");
        assert_eq!(env.observations.len(), 2);

        let obs1 = env
            .observations
            .iter()
            .find(|o| o.track_id.as_deref() == Some("1"))
            .expect("track 1 observation");
        assert_eq!(obs1.label, "SR-0100");
        assert_eq!(obs1.category, "license_plate");
        assert!((obs1.confidence - 0.95).abs() < 1e-4);
        let crop1 = base64::engine::general_purpose::STANDARD
            .decode(obs1.crop_jpeg_b64.as_ref().expect("preview crop"))
            .expect("valid preview base64");
        assert!(crop1.len() <= 32 * 1024);

        let obs2 = env
            .observations
            .iter()
            .find(|o| o.track_id.as_deref() == Some("2"))
            .expect("track 2 observation");
        assert_eq!(obs2.label, "TEST-742");

        let prom = metrics.render_prometheus_text().expect("prometheus text");
        assert!(
            prom.contains(r#"vantage_crops_skipped_total{reason="crop_below_min_dimension"} 1"#),
            "expected crop_below_min_dimension skip metric in:\n{prom}"
        );
        assert_eq!(metrics.vantage_jobs_completed_count(), 1);
    }

    #[tokio::test]
    async fn rejects_truncated_thinking_malformed_json_schema_violations_and_http_500() {
        let (cmaf_block, verified_block) = build_1080p_synthetic_block(&[1, 2, 3]);
        let make_target = |seq: u32, track: &str| SampledTarget {
            target_key: format!("t-{track}-{seq}"),
            track_id: Some(track.to_string()),
            fragment_sequence: seq,
            media_pts_ns: u64::from(seq) * 2_000_000_000,
            timeline_ts_us: 1_700_000_000_000_000 + i64::from(seq) * 1_000_000,
            time_basis: TimeBasis::Received,
            category: "vehicle".to_string(),
            confidence: 0.90,
            bbox: Some([0.30, 0.45, 0.55, 0.80]),
        };
        let job = make_synthetic_alpr_job(
            cmaf_block.descriptor_sha256().to_string(),
            vec![
                make_target(1, "1"),
                make_target(2, "2"),
                make_target(3, "3"),
                make_target(99, "4"),
            ],
        );
        let plan = build_local_plan_for_job(&job, &cmaf_block);

        let mk_content = |content: &str| {
            serde_json::json!({
                "choices": [{ "message": { "content": content } }]
            })
            .to_string()
        };
        // 1) Truncated <think>, 2) malformed JSON, 3) schema regex violation -> zero observations!
        let (vlm_url, _, h1) = spawn_mock_vlm_server(vec![
            (
                200,
                mk_content("<think>Inspecting plate on Gate West 01..."),
            ),
            (200, mk_content("{not valid json")),
            (
                200,
                mk_content(r#"{"plate_text": "bad plate !@#", "confidence": 0.8}"#),
            ),
        ]);

        let cfg = WorkerConfig::cpu_explicit_default().with_vantage_vlm(
            true,
            Some(vlm_url),
            "qwen3.5-4b",
        );
        let metrics = Arc::new(WorkerMetrics::new());
        let events = Arc::new(Mutex::new(Vec::new()));
        let published = Arc::new(Mutex::new(Vec::new()));

        let processor = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan.clone())),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events),
                published: Arc::clone(&published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg).expect("vlm client"),
            Arc::clone(&metrics),
        );

        let delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&events),
        });
        let outcome = processor
            .process_delivery(delivery)
            .await
            .expect("bad VLM outputs reject cleanly without fabricating observations");
        h1.join().expect("join server");

        let env = outcome.completed_envelope().expect("envelope");
        assert!(
            env.observations.is_empty(),
            "zero fabricated observations may be published, got {:?}",
            env.observations
        );
        let prom = metrics.render_prometheus_text().expect("prom");
        assert!(prom.contains(r#"vantage_vlm_requests_total{outcome="truncated_thinking"} 1"#));
        assert!(prom.contains(r#"vantage_vlm_requests_total{outcome="parse_error"} 1"#));
        assert!(prom.contains(r#"vantage_vlm_requests_total{outcome="schema_rejected"} 1"#));
        assert!(prom.contains(r#"vantage_crops_skipped_total{reason="missing_fragment"} 1"#));

        // HTTP 500 -> NAK, vantage_jobs_failed_total incremented, zero results published.
        let (err_url, _, h2) =
            spawn_mock_vlm_server(vec![(500, r#"{"error":"backend_busy"}"#.to_string())]);
        let err_cfg = WorkerConfig::cpu_explicit_default().with_vantage_vlm(
            true,
            Some(err_url),
            "qwen3.5-4b",
        );
        let err_events = Arc::new(Mutex::new(Vec::new()));
        let err_published = Arc::new(Mutex::new(Vec::new()));
        let err_metrics = Arc::new(WorkerMetrics::new());
        let err_proc = VantageVlmProcessor::new(
            &err_cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan)),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&err_events),
                published: Arc::clone(&err_published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&err_cfg).expect("client"),
            Arc::clone(&err_metrics),
        );
        let err_delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&err_events),
        });
        let err = err_proc
            .process_delivery(err_delivery)
            .await
            .expect_err("HTTP 500 must fail and NAK");
        h2.join().expect("join 500 server");
        assert!(matches!(
            err.kind(),
            MediaWorkerErrorKind::InferenceFailed(_)
        ));
        assert_eq!(err_events.lock().as_slice(), &["nak"]);
        assert!(err_published.lock().is_empty());
        assert_eq!(err_metrics.vantage_jobs_failed_count(), 1);
    }

    #[tokio::test]
    async fn handles_410_gone_and_trims_crop_previews_under_960kib_ceiling() {
        let (cmaf_block, verified_block) = build_1080p_synthetic_block(&[1]);
        let job = make_synthetic_alpr_job(cmaf_block.descriptor_sha256().to_string(), vec![]);

        let cfg = WorkerConfig::cpu_explicit_default().with_vantage_vlm(
            true,
            Some("http://127.0.0.1:9/v1".to_string()),
            "qwen3.5-4b",
        );
        let metrics = Arc::new(WorkerMetrics::new());
        let events = Arc::new(Mutex::new(Vec::new()));
        let published = Arc::new(Mutex::new(Vec::new()));

        let gone_proc = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Gone,
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events),
                published: Arc::clone(&published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg).expect("client"),
            Arc::clone(&metrics),
        );
        let delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&events),
        });
        let outcome = gone_proc
            .process_delivery(delivery)
            .await
            .expect("410 Gone is a clean skip");
        assert_eq!(outcome, VantageJobOutcome::Gone);
        assert_eq!(metrics.vantage_jobs_gone_count(), 1);
        assert_eq!(events.lock().as_slice(), &["ack"]);
        assert!(published.lock().is_empty());

        // Publish failure MUST NAK and NEVER ACK the source job message.
        let pub_fail_events = Arc::new(Mutex::new(Vec::new()));
        let pub_fail_proc = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(build_local_plan_for_job(
                    &job,
                    &cmaf_block,
                ))),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&pub_fail_events),
                published: Arc::new(Mutex::new(Vec::new())),
                fail_publish: true,
            },
            HttpVlmClient::from_config(&cfg).expect("client"),
            Arc::new(WorkerMetrics::new()),
        );
        let pub_fail_delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("job json"),
            events: Arc::clone(&pub_fail_events),
        });
        assert!(
            pub_fail_proc
                .process_delivery(pub_fail_delivery)
                .await
                .is_err()
        );
        let pub_fail_log = pub_fail_events.lock().clone();
        assert!(!pub_fail_log.iter().any(|e| e == "ack"));
        assert!(pub_fail_log.iter().any(|e| e == "nak"));

        // Test 960 KiB envelope trimming drops lowest-confidence crop_jpeg_b64 first.
        let mut big_jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        big_jpeg.resize(28 * 1024, 0x22);
        big_jpeg[28 * 1024 - 2] = 0xFF;
        big_jpeg[28 * 1024 - 1] = 0xD9;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&big_jpeg);

        let mut observations = Vec::new();
        for i in 0..30usize {
            observations.push(VantageObservationInput {
                observation_key: format!("obs-{i:02}"),
                fragment_sequence: Some(1),
                frame_sequence: Some(1),
                media_pts_ns: Some(1_000_000),
                timeline_ts_us: 1_700_000_000_000_000,
                time_basis: TimeBasis::Received,
                track_id: Some(format!("{i}")),
                category: "license_plate".to_string(),
                label: format!("SR-{i:04}"),
                confidence: 0.50 + (i as f32) * 0.01,
                bbox: Some([0.3, 0.4, 0.5, 0.7]),
                crop_jpeg_b64: Some(b64.clone()),
                attributes: serde_json::json!({"plate_text": format!("SR-{i:04}")}),
                signal_schema_id: "alpr_plate_read".to_string(),
                signal_schema_version: "1.0.0".to_string(),
                display_contract_id: "alpr_plate_read".to_string(),
                search_text: None,
            });
        }

        let mut envelope = VantageResultEnvelope {
            schema_version: VANTAGE_RESULT_SCHEMA_VERSION.to_string(),
            job_id: Some(job.job_id),
            pack_id: "io.serviceradar.vantage-alpr".to_string(),
            pipeline_id: job.pipeline_id,
            pipeline_version: job.pipeline_version,
            worker_kind: WorkerKind::CameraVlm,
            worker_id: "worker-1".to_string(),
            model_id: "qwen3.5-4b".to_string(),
            model_version: "1.0.0".to_string(),
            capability: job.capability,
            source_mode: SourceMode::RecordedBlock,
            camera_source_id: job.camera_source_id,
            stream_profile_id: job.stream_profile_id,
            catalog_entry_id: job.catalog_entry_id,
            descriptor_sha256: job.descriptor_sha256,
            observations,
        };
        trim_result_crops_within_ceiling(&mut envelope, MAX_VANTAGE_RESULT_ENVELOPE_BYTES)
            .expect("trim should fit under 960 KiB");
        let serialized = serde_json::to_vec(&envelope).expect("serialize trimmed");
        assert!(serialized.len() <= MAX_VANTAGE_RESULT_ENVELOPE_BYTES);
        // Lowest confidence observations had crops dropped first, highest retained.
        assert!(envelope.observations[0].crop_jpeg_b64.is_none());
        assert!(envelope.observations[29].crop_jpeg_b64.is_some());
    }

    #[test]
    fn parses_4_backtick_fences_nullable_types_defs_refs_additional_properties_and_nested_structures()
     {
        let schema = serde_json::json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["plate_text", "confidence", "meta", "tags"],
            "$defs": {
                "PlateCode": {
                    "type": ["string", "null"],
                    "pattern": "^[A-Z0-9-]{2,12}$"
                }
            },
            "definitions": {
                "Tag": {
                    "type": "string",
                    "minLength": 2,
                    "maxLength": 16
                }
            },
            "properties": {
                "plate_text": { "$ref": "#/$defs/PlateCode" },
                "region": {
                    "type": ["string", "null"],
                    "pattern": "^[A-Z]{2}-[A-Z]{2}$"
                },
                "confidence": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
                "meta": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["gate"],
                    "properties": {
                        "gate": { "type": "string", "minLength": 2 }
                    }
                },
                "tags": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 3,
                    "items": { "$ref": "#/definitions/Tag" }
                }
            }
        });

        // 1) 4-backtick closing fence + nullable string matching pattern + nested object/array + $defs/$ref
        let valid_4tick = "<think>ok</think>```json\n{\"plate_text\":\"SR-0100\",\"region\":null,\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\"},\"tags\":[\"sedan\"]}\n````";
        let parsed = parse_vlm_json_response(valid_4tick, Some(&schema), "license_plate")
            .expect("4-backtick fence and nullable schema should parse");
        assert_eq!(parsed.label, "SR-0100");
        assert_eq!(parsed.attributes["region"], serde_json::Value::Null);

        // 2) Nullable array type MUST still enforce pattern on non-null strings
        let bad_nullable_pattern = "{\"plate_text\":\"SR-0100\",\"region\":\"INVALID !@#\",\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\"},\"tags\":[\"sedan\"]}";
        assert!(matches!(
            parse_vlm_json_response(bad_nullable_pattern, Some(&schema), "license_plate"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));

        // 3) additionalProperties: false on root and nested object MUST reject unknown keys
        let extra_root_key = "{\"plate_text\":\"SR-0100\",\"region\":\"US-CA\",\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\"},\"tags\":[\"sedan\"],\"unexpected\":true}";
        assert!(matches!(
            parse_vlm_json_response(extra_root_key, Some(&schema), "license_plate"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));
        let extra_nested_key = "{\"plate_text\":\"SR-0100\",\"region\":\"US-CA\",\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\",\"extra\":1},\"tags\":[\"sedan\"]}";
        assert!(matches!(
            parse_vlm_json_response(extra_nested_key, Some(&schema), "license_plate"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));

        // 4) Nested array items $ref & minItems/maxItems enforcement
        let bad_array_item = "{\"plate_text\":\"SR-0100\",\"region\":\"US-CA\",\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\"},\"tags\":[\"x\"]}";
        assert!(matches!(
            parse_vlm_json_response(bad_array_item, Some(&schema), "license_plate"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));
        let empty_array = "{\"plate_text\":\"SR-0100\",\"region\":\"US-CA\",\"confidence\":0.91,\"meta\":{\"gate\":\"Gate West 01\"},\"tags\":[]}";
        assert!(matches!(
            parse_vlm_json_response(empty_array, Some(&schema), "license_plate"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));

        // 5) Cyclic $ref hits bounded recursion depth instead of overflowing stack
        let cyclic_schema = serde_json::json!({
            "$defs": { "Loop": { "$ref": "#/$defs/Loop" } },
            "$ref": "#/$defs/Loop"
        });
        assert!(matches!(
            parse_vlm_json_response("{\"label\":\"SR-0100\"}", Some(&cyclic_schema), "bay"),
            Err(VlmParseFailure::SchemaRejected(_))
        ));
    }

    #[tokio::test]
    async fn ramp1_vlm_executes_full_frame_sealed_block_and_rejects_empty_vlm_config() {
        let (cmaf_block, verified_block) = build_1080p_synthetic_block(&[1]);
        let desc_sha = cmaf_block.descriptor_sha256().to_string();

        // M1 :on_sealed_block payload: input_mode=full_frame, roi_polygons as M1 map,
        // sampled_targets omitting time_basis/category/confidence/bbox.
        let full_frame_job_json = serde_json::json!({
            "schema_version": "vantage.job.v1",
            "job_id": Uuid::new_v4(),
            "pack_id": "io.serviceradar.bay-guidance",
            "pipeline_id": "io.serviceradar.bay-guidance.gate-occupancy",
            "pipeline_version": "1.0.0",
            "capability": "vantage.bay_guidance.v1",
            "source_mode": "recorded_block",
            "camera_source_id": Uuid::new_v4(),
            "stream_profile_id": Uuid::new_v4(),
            "catalog_entry_id": Uuid::new_v4(),
            "descriptor_sha256": desc_sha,
            "input_mode": "full_frame",
            "roi_polygons": [
                {"points": [[0.2, 0.3], [0.8, 0.3], [0.8, 0.9], [0.2, 0.9]]}
            ],
            "crop_policy": {
                "padding_ratio": 0.15,
                "min_bbox_width_px": 96,
                "max_dimension": 640,
                "max_bytes": 98304
            },
            "sampled_targets": [{
                "target_key": "block",
                "fragment_sequence": 1,
                "media_pts_ns": 2_000_000_000u64,
                "timeline_ts_us": 1_700_000_002_000_000i64
            }],
            "signal_schema_id": "bay_guidance_state",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "bay_guidance_state",
            "vlm_config": {
                "prompt": "Report bay occupancy at Gate West 01",
                "max_tokens": 256,
                "temperature": 0.0,
                "json_schema": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["label", "confidence"],
                    "properties": {
                        "label": {"type": "string", "minLength": 2},
                        "confidence": {"type": "number", "minimum": 0.0, "maximum": 1.0}
                    }
                }
            }
        });
        let job: VantageJobEnvelope =
            serde_json::from_value(full_frame_job_json).expect("deserialize full_frame job");
        let plan = build_local_plan_for_job(&job, &cmaf_block);

        let vlm_resp = serde_json::json!({
            "choices": [{
                "message": {
                    "content": "```json\n{\"label\":\"OCCUPIED\",\"confidence\":0.93}\n````"
                }
            }]
        })
        .to_string();
        let (vlm_url, captured_reqs, server_handle) = spawn_mock_vlm_server(vec![(200, vlm_resp)]);

        let cfg = WorkerConfig::cpu_explicit_default()
            .with_vantage_vlm(true, Some(vlm_url), "qwen3.5-4b")
            .with_worker_id("media-worker-synthetic-01");
        let metrics = Arc::new(WorkerMetrics::new());
        let events = Arc::new(Mutex::new(Vec::new()));
        let published = Arc::new(Mutex::new(Vec::new()));

        let processor = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan)),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events),
                published: Arc::clone(&published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg).expect("vlm client"),
            Arc::clone(&metrics),
        );

        let delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("serialize full_frame job"),
            events: Arc::clone(&events),
        });
        let outcome = processor
            .process_delivery(delivery)
            .await
            .expect("full_frame sealed_block job must succeed");
        server_handle.join().expect("join mock VLM server");

        {
            let reqs = captured_reqs.lock();
            assert_eq!(reqs.len(), 1);
            let url = reqs[0]["messages"][1]["content"][1]["image_url"]["url"]
                .as_str()
                .expect("image data url");
            let b64 = url.strip_prefix("data:image/jpeg;base64,").unwrap();
            let jpeg = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .unwrap();
            assert!(jpeg.len() <= 96 * 1024);
            let (w, h) = parse_jpeg_sof0_dims(&jpeg).expect("valid SOF0 JFIF");
            assert!(w <= 640 && h <= 640 && w > 0 && h > 0);
        }

        let env = outcome.completed_envelope().expect("completed envelope");
        assert_eq!(env.observations.len(), 1);
        assert_eq!(env.observations[0].label, "OCCUPIED");
        assert_eq!(env.observations[0].bbox, None);
        assert_eq!(env.observations[0].time_basis, TimeBasis::Received);

        // Also verify InputMode::FullFrame with empty roi_polygons crops full [0,0,1,1] (640x360)
        // without failing min_bbox_width_px even when min_bbox_width_px=1920.
        let mut no_roi_job = job.clone();
        no_roi_job.roi_polygons.clear();
        no_roi_job.crop_policy.min_bbox_width_px = 1920;
        let vlm_resp_2 = serde_json::json!({
            "choices": [{
                "message": {
                    "content": r#"{"label":"CLEAR","confidence":0.95}"#
                }
            }]
        })
        .to_string();
        let (vlm_url_2, reqs_2, server_handle_2) = spawn_mock_vlm_server(vec![(200, vlm_resp_2)]);
        let cfg_2 = WorkerConfig::cpu_explicit_default()
            .with_vantage_vlm(true, Some(vlm_url_2), "qwen3.5-4b")
            .with_worker_id("media-worker-synthetic-01");
        let events_2 = Arc::new(Mutex::new(Vec::new()));
        let proc_2 = VantageVlmProcessor::new(
            &cfg_2,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(build_local_plan_for_job(
                    &no_roi_job,
                    &cmaf_block,
                ))),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events_2),
                published: Arc::new(Mutex::new(Vec::new())),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg_2).expect("vlm client 2"),
            Arc::new(WorkerMetrics::new()),
        );
        let delivery_2 = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&no_roi_job).expect("serialize no-roi full_frame job"),
            events: Arc::clone(&events_2),
        });
        let outcome_2 = proc_2
            .process_delivery(delivery_2)
            .await
            .expect("full_frame without roi_polygons must succeed");
        server_handle_2.join().expect("join mock VLM server 2");
        assert_eq!(
            outcome_2.completed_envelope().unwrap().observations[0].label,
            "CLEAR"
        );
        {
            let guard = reqs_2.lock();
            let url = guard[0]["messages"][1]["content"][1]["image_url"]["url"]
                .as_str()
                .unwrap();
            let jpeg = base64::engine::general_purpose::STANDARD
                .decode(url.strip_prefix("data:image/jpeg;base64,").unwrap())
                .unwrap();
            assert_eq!(parse_jpeg_sof0_dims(&jpeg), Some((640, 360)));
        }

        // Ramp 1 VLM runner MUST reject empty "vlm_config": {} with InvalidJobEnvelope
        let mut empty_vlm_job = job.clone();
        empty_vlm_job.vlm_config = Some(serviceradar_media_core::VlmJobConfig::default());
        let empty_events = Arc::new(Mutex::new(Vec::new()));
        let empty_delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&empty_vlm_job).expect("serialize empty vlm job"),
            events: Arc::clone(&empty_events),
        });
        let err = processor
            .process_delivery(empty_delivery)
            .await
            .expect_err("Ramp 1 VLM runner must reject empty vlm_config");
        assert!(matches!(
            err.kind(),
            MediaWorkerErrorKind::InvalidJobEnvelope(_)
        ));
        assert_eq!(empty_events.lock().as_slice(), &["nak"]);
    }

    #[tokio::test]
    async fn untracked_detections_get_distinct_observation_keys_and_budget_ms_is_enforced() {
        let (cmaf_block, verified_block) = build_1080p_synthetic_block(&[1]);
        let targets = vec![
            SampledTarget {
                target_key: "frame:1:det:0".to_string(),
                track_id: None,
                fragment_sequence: 1,
                media_pts_ns: 2_000_000_000,
                timeline_ts_us: 1_700_000_002_000_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.92,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
            SampledTarget {
                target_key: "frame:1:det:1".to_string(),
                track_id: None,
                fragment_sequence: 1,
                media_pts_ns: 2_000_000_000,
                timeline_ts_us: 1_700_000_002_000_000,
                time_basis: TimeBasis::Received,
                category: "vehicle".to_string(),
                confidence: 0.88,
                bbox: Some([0.30, 0.45, 0.55, 0.80]),
            },
        ];
        let job = make_synthetic_alpr_job(cmaf_block.descriptor_sha256().to_string(), targets);
        let plan = build_local_plan_for_job(&job, &cmaf_block);

        let mk_resp = |plate: &str| {
            serde_json::json!({
                "choices": [{
                    "message": {
                        "content": serde_json::json!({
                            "plate_text": plate,
                            "confidence": 0.91
                        }).to_string()
                    }
                }]
            })
            .to_string()
        };
        let (vlm_url, _, server_handle) =
            spawn_mock_vlm_server(vec![(200, mk_resp("SR-0100")), (200, mk_resp("TEST-742"))]);

        let cfg = WorkerConfig::cpu_explicit_default().with_vantage_vlm(
            true,
            Some(vlm_url),
            "qwen3.5-4b",
        );
        let metrics = Arc::new(WorkerMetrics::new());
        let events = Arc::new(Mutex::new(Vec::new()));
        let published = Arc::new(Mutex::new(Vec::new()));
        let processor = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan.clone())),
            },
            MockFragmentStore {
                block: verified_block.clone(),
            },
            RecordingVantagePublisher {
                events: Arc::clone(&events),
                published: Arc::clone(&published),
                fail_publish: false,
            },
            HttpVlmClient::from_config(&cfg).expect("vlm client"),
            Arc::clone(&metrics),
        );

        let delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&job).expect("serialize job"),
            events: Arc::clone(&events),
        });
        let outcome = processor
            .process_delivery(delivery)
            .await
            .expect("untracked detections job should succeed");
        server_handle.join().expect("join server");

        let env = outcome.completed_envelope().expect("completed envelope");
        assert_eq!(env.observations.len(), 2);
        assert_ne!(
            env.observations[0].observation_key, env.observations[1].observation_key,
            "two untracked detections in the same fragment must have distinct observation_keys"
        );

        // Enforce job.budget_ms across VLM inference calls
        struct SlowVlmClient;
        impl VlmClient for SlowVlmClient {
            async fn chat_completion(
                &self,
                _request: &VlmChatRequest,
            ) -> Result<String, VlmCallError> {
                tokio::time::sleep(Duration::from_millis(250)).await;
                Ok(r#"{"plate_text":"SR-0100","confidence":0.9}"#.to_string())
            }
        }

        let mut short_budget_job = job;
        short_budget_job.budget_ms = 40;
        let budget_events = Arc::new(Mutex::new(Vec::new()));
        let budget_proc = VantageVlmProcessor::new(
            &cfg,
            MockGrantClient {
                resolution: GrantResolution::Admitted(Box::new(plan)),
            },
            MockFragmentStore {
                block: verified_block,
            },
            RecordingVantagePublisher {
                events: Arc::clone(&budget_events),
                published: Arc::new(Mutex::new(Vec::new())),
                fail_publish: false,
            },
            SlowVlmClient,
            Arc::new(WorkerMetrics::new()),
        );
        let budget_delivery = Arc::new(RecordingVantageDelivery {
            payload: serde_json::to_vec(&short_budget_job).expect("serialize short budget job"),
            events: Arc::clone(&budget_events),
        });
        let err = budget_proc
            .process_delivery(budget_delivery)
            .await
            .expect_err("slow VLM call exceeding job.budget_ms must fail with DeadlineExceeded");
        assert!(matches!(
            err.kind(),
            MediaWorkerErrorKind::DeadlineExceeded(_)
        ));
        assert_eq!(budget_events.lock().as_slice(), &["nak"]);
    }
}
