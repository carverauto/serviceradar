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

//! Banner matching served over the generic `AddonService.RunCommand` contract.
//!
//! This is the same corpus matcher the legacy `NetprobeFrame.BannerBatch` IPC arm
//! calls; only the transport differs. It exists so the bespoke IPC socket can be
//! retired -- `BannerBatch` is its last functional request/response arm.
//!
//! ## Why the observation is not carried whole
//!
//! [`crate::proto::netprobe::BannerObservation`] has seven fields; three travel.
//! The matcher reads exactly `observation_id`, `protocol` and the banner bytes --
//! `host`, `port`, `source` and `observed_at` are never consulted. The agent
//! re-attaches those from its own record when it builds the fingerprint event, so
//! sending them would create a second source of truth for the same observation
//! and an `observed_at` in JSON is a silent precision hazard besides (nanoseconds
//! since epoch exceed 2^53, so any consumer that parses JSON numbers as doubles
//! truncates it). Adding a field later is additive and costs no schema bump.
//!
//! ## Why base64 rather than a JSON string
//!
//! Banners are bytes, not text: SMB, RDP, DNS and NTP banners are binary. The
//! matcher lossily converts to UTF-8 itself, so a string *looks* equivalent -- but
//! Go replaces each invalid BYTE with U+FFFD while Rust's `from_utf8_lossy`
//! replaces each invalid SEQUENCE with one U+FFFD. The two disagree on exactly the
//! binary banners this path exists to identify, and the disagreement would show up
//! as a corpus match quietly changing rather than as an error.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use serde::{Deserialize, Serialize};

use crate::{
    ipc::match_banner::match_banner_batch,
    proto::netprobe::{BannerBatch, BannerObservation},
};

/// The package-declared producer action this handler serves.
pub const MATCH_BANNERS_ACTION: &str = "match_banners";

/// Names the payload contract below. Changing it is a contract break, not a
/// rename: the agent sends this string and an unrecognized one is refused.
pub const MATCH_BANNERS_SCHEMA: &str = "serviceradar.netprobe.banner_match.v1";

#[derive(Debug, Deserialize)]
pub struct MatchBannersRequest {
    #[serde(default)]
    pub observations: Vec<RequestObservation>,
}

#[derive(Debug, Deserialize)]
pub struct RequestObservation {
    pub observation_id: u64,
    #[serde(default)]
    pub protocol: String,
    /// Standard base64 (with padding) of the raw banner bytes.
    #[serde(default)]
    pub banner_b64: String,
}

#[derive(Debug, Default, Serialize)]
pub struct MatchBannersResponse {
    /// Only observations that matched a corpus appear here, so the response is
    /// NOT positionally aligned with the request. The agent joins on
    /// `observation_id`, which it already did when the IPC arm padded misses.
    pub matches: Vec<ResponseMatch>,
    /// How many observations were considered, so the caller can meter hit rate
    /// without inferring it from a length that no longer means "all of them".
    pub observations: usize,
}

#[derive(Debug, Serialize)]
pub struct ResponseMatch {
    pub observation_id: u64,
    pub corpus_label: String,
    pub os_family: String,
    pub product: String,
    pub version: String,
    pub confidence: f64,
    pub raw_pattern_id: String,
}

/// Decodes a `RunCommand` payload, matches it, and encodes the response.
///
/// Returns `Err` only for a payload this handler cannot interpret. The caller
/// turns that into an unsuccessful `CommandResult` rather than a transport error:
/// a malformed payload is a durable answer that retrying cannot improve.
pub fn handle_match_banners(payload_json: &[u8]) -> Result<Vec<u8>, String> {
    let request: MatchBannersRequest = serde_json::from_slice(payload_json)
        .map_err(|err| format!("could not parse match_banners payload: {err}"))?;

    let observations = request.observations.len();
    let batch = BannerBatch {
        observations: request
            .observations
            .into_iter()
            .map(decode_observation)
            .collect::<Result<Vec<_>, String>>()?,
    };

    let response = MatchBannersResponse {
        matches: match_banner_batch(&batch)
            .matches
            .into_iter()
            .map(|matched| ResponseMatch {
                observation_id: matched.observation_id,
                corpus_label: matched.corpus_label,
                os_family: matched.os_family,
                product: matched.product,
                version: matched.version,
                confidence: matched.confidence,
                raw_pattern_id: matched.raw_pattern_id,
            })
            .collect(),
        observations,
    };

    serde_json::to_vec(&response)
        .map_err(|err| format!("could not encode match_banners response: {err}"))
}

fn decode_observation(observation: RequestObservation) -> Result<BannerObservation, String> {
    let banner_bytes = BASE64
        .decode(observation.banner_b64.as_bytes())
        .map_err(|err| {
            format!(
                "observation {}: banner_b64 is not valid base64: {err}",
                observation.observation_id
            )
        })?;

    Ok(BannerObservation {
        observation_id: observation.observation_id,
        // Deliberately defaulted: the matcher does not read these, and the agent
        // owns the authoritative values. See the module docs.
        host: String::new(),
        port: 0,
        protocol: observation.protocol,
        banner_bytes,
        observed_at: 0,
        source: String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response_of(payload: &str) -> serde_json::Value {
        let encoded = handle_match_banners(payload.as_bytes()).expect("payload is handled");
        serde_json::from_slice(&encoded).expect("response is json")
    }

    fn request(protocol: &str, banner: &[u8]) -> String {
        format!(
            r#"{{"observations":[{{"observation_id":7,"protocol":"{protocol}","banner_b64":"{}"}}]}}"#,
            BASE64.encode(banner)
        )
    }

    #[test]
    fn matches_a_recog_banner_over_the_command_contract() {
        let response = response_of(&request("http", b"Apache/2.4.58 (Ubuntu)"));

        assert_eq!(response["observations"], 1);
        assert_eq!(response["matches"].as_array().expect("array").len(), 1);
        assert_eq!(response["matches"][0]["observation_id"], 7);
        assert_eq!(response["matches"][0]["product"], "HTTPD");
        assert_eq!(response["matches"][0]["version"], "2.4.58");
        assert!(
            response["matches"][0]["corpus_label"]
                .as_str()
                .expect("label")
                .starts_with("recog:")
        );
    }

    #[test]
    fn an_unmatched_observation_is_absent_rather_than_padded() {
        // The filter the agent used to apply now lives here. A miss must not
        // travel as a zero-confidence "unknown" the caller has to strip.
        let response = response_of(&request("ssh", b"not-a-known-banner"));

        assert_eq!(response["observations"], 1);
        assert!(response["matches"].as_array().expect("array").is_empty());
    }

    #[test]
    fn a_binary_banner_survives_the_transport_byte_for_byte() {
        // 0x80 is a continuation byte with no lead: invalid UTF-8, and exactly
        // where Go's per-byte replacement and Rust's per-sequence replacement
        // disagree. Encoded as base64 the matcher sees the same bytes either way.
        let banner = [b'S', b'S', b'H', b'-', b'2', b'.', b'0', b'-', 0x80, 0xFF];
        let payload = request("ssh", &banner);
        let decoded: MatchBannersRequest =
            serde_json::from_str(&payload).expect("payload round-trips");

        let observation = decode_observation(decoded.observations.into_iter().next().expect("one"))
            .expect("observation decodes");

        assert_eq!(observation.banner_bytes, banner);
    }

    #[test]
    fn only_the_matcher_inputs_cross_the_wire() {
        let decoded: MatchBannersRequest =
            serde_json::from_str(&request("ssh", b"SSH-2.0-OpenSSH_8.9p1")).expect("parses");
        let observation = decode_observation(decoded.observations.into_iter().next().expect("one"))
            .expect("decodes");

        // Asserted rather than assumed: if these ever start carrying values, the
        // agent's copy and netprobe's copy can disagree about the same observation.
        assert_eq!(observation.host, "");
        assert_eq!(observation.port, 0);
        assert_eq!(observation.observed_at, 0);
        assert_eq!(observation.source, "");
    }

    #[test]
    fn a_malformed_payload_is_reported_not_panicked() {
        let err = handle_match_banners(b"{not json").expect_err("refused");
        assert!(
            err.contains("could not parse match_banners payload"),
            "{err}"
        );

        let err = handle_match_banners(
            br#"{"observations":[{"observation_id":3,"protocol":"ssh","banner_b64":"!!!"}]}"#,
        )
        .expect_err("refused");
        assert!(err.contains("observation 3"), "{err}");
        assert!(err.contains("not valid base64"), "{err}");
    }

    #[test]
    fn an_empty_batch_is_a_successful_empty_answer() {
        let response = response_of(r#"{"observations":[]}"#);

        assert_eq!(response["observations"], 0);
        assert!(response["matches"].as_array().expect("array").is_empty());
    }
}
