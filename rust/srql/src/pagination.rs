//! Cursor encoding helpers for SRQL pagination.

use crate::error::{Result, ServiceError};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Serialize, Deserialize)]
struct CursorPayload {
    v: u8,
    offset: i64,
    sig: String,
}

/// The unique, indexed keys an entity declares for keyset paging, as
/// `(entity, column)`. A query whose effective order is one of these columns
/// alone pages by key position instead of by row offset.
pub const KEYSET_KEYS: &[(&str, &str)] = &[("devices", "uid"), ("agents", "uid")];

/// Direction of a keyset walk; the wire form is `"asc"` or `"desc"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeysetDirection {
    Asc,
    Desc,
}

impl KeysetDirection {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Asc => "asc",
            Self::Desc => "desc",
        }
    }

    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "asc" => Ok(Self::Asc),
            "desc" => Ok(Self::Desc),
            _ => Err(ServiceError::InvalidRequest(
                "keyset direction must be asc or desc".into(),
            )),
        }
    }
}

/// A position in a keyset walk: the last key a page returned, bound to the
/// entity, key column and direction it was read under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeysetPosition {
    pub entity: String,
    pub column: String,
    pub direction: KeysetDirection,
    pub key: String,
}

/// What a cursor points at: a row offset (v2) or a key position (v3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CursorPosition {
    Offset(i64),
    Keyset(KeysetPosition),
}

/// The signed content of a v3 cursor. Field order is the canonical order the
/// signature covers: `v`, `entity`, `col`, `dir`, `key`.
#[derive(Serialize)]
struct KeysetSigned<'a> {
    v: u8,
    entity: &'a str,
    col: &'a str,
    dir: &'a str,
    key: &'a str,
}

#[derive(Serialize, Deserialize)]
struct KeysetPayload {
    v: u8,
    entity: String,
    col: String,
    dir: String,
    key: String,
    sig: String,
}

#[derive(Deserialize)]
struct CursorVersion {
    v: u8,
}

/// Decodes a v2 offset cursor or a v3 keyset cursor. `max_offset` bounds
/// offsets only; a keyset position has no ceiling.
pub fn decode_position(cursor: &str, secret: &str, max_offset: i64) -> Result<CursorPosition> {
    let bytes = cursor_bytes(cursor)?;
    let version: CursorVersion = serde_json::from_slice(&bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    match version.v {
        3 => decode_keyset_payload(&bytes, secret).map(CursorPosition::Keyset),
        _ => decode_offset_payload(&bytes, secret, max_offset).map(CursorPosition::Offset),
    }
}

/// Signs a v3 keyset cursor for a declared keyset key.
pub fn encode_keyset_cursor(
    entity: &str,
    column: &str,
    direction: KeysetDirection,
    key: &str,
    secret: &str,
) -> Result<String> {
    if !is_declared_keyset_key(entity, column) {
        return Err(ServiceError::InvalidRequest(format!(
            "{entity}.{column} is not a keyset key"
        )));
    }
    let payload = KeysetPayload {
        v: 3,
        entity: entity.to_string(),
        col: column.to_string(),
        dir: direction.as_str().to_string(),
        key: key.to_string(),
        sig: URL_SAFE_NO_PAD.encode(
            keyset_mac(entity, column, direction.as_str(), key, secret)?
                .finalize()
                .into_bytes(),
        ),
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| ServiceError::InvalidRequest("failed to encode cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

pub fn is_declared_keyset_key(entity: &str, column: &str) -> bool {
    KEYSET_KEYS
        .iter()
        .any(|(declared_entity, declared_column)| {
            *declared_entity == entity && *declared_column == column
        })
}

fn decode_keyset_payload(bytes: &[u8], secret: &str) -> Result<KeysetPosition> {
    let payload: KeysetPayload = serde_json::from_slice(bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    let signature = URL_SAFE_NO_PAD
        .decode(payload.sig.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))?;
    keyset_mac(
        &payload.entity,
        &payload.col,
        &payload.dir,
        &payload.key,
        secret,
    )?
    .verify_slice(&signature)
    .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))?;
    Ok(KeysetPosition {
        direction: KeysetDirection::parse(&payload.dir)
            .map_err(|_| ServiceError::InvalidRequest("invalid cursor".into()))?,
        entity: payload.entity,
        column: payload.col,
        key: payload.key,
    })
}

fn keyset_mac(entity: &str, col: &str, dir: &str, key: &str, secret: &str) -> Result<HmacSha256> {
    let canonical = serde_json::to_vec(&KeysetSigned {
        v: 3,
        entity,
        col,
        dir,
        key,
    })
    .map_err(|_| ServiceError::InvalidRequest("failed to encode cursor".into()))?;
    let mut mac = new_mac(secret)?;
    mac.update(&canonical);
    Ok(mac)
}

fn cursor_bytes(cursor: &str) -> Result<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor".into()))
}

pub fn decode_cursor(cursor: &str, secret: &str, max_offset: i64) -> Result<i64> {
    decode_offset_payload(&cursor_bytes(cursor)?, secret, max_offset)
}

fn decode_offset_payload(bytes: &[u8], secret: &str, max_offset: i64) -> Result<i64> {
    let payload: CursorPayload = serde_json::from_slice(bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    if payload.v != 2 {
        return Err(ServiceError::InvalidRequest(
            "unsupported cursor version".into(),
        ));
    }
    if payload.offset < 0 {
        return Err(ServiceError::InvalidRequest(
            "cursor offset must be non-negative".into(),
        ));
    }
    if payload.offset > max_offset {
        return Err(ServiceError::InvalidRequest(format!(
            "cursor offset exceeds maximum of {max_offset}"
        )));
    }
    verify_offset_signature(payload.offset, secret, &payload.sig)?;
    Ok(payload.offset)
}

pub fn encode_cursor(offset: i64, secret: &str) -> Result<String> {
    let offset = offset.max(0);
    let payload = CursorPayload {
        v: 2,
        offset,
        sig: sign_offset(offset, secret)?,
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| ServiceError::InvalidRequest("failed to encode cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn sign_offset(offset: i64, secret: &str) -> Result<String> {
    Ok(URL_SAFE_NO_PAD.encode(cursor_mac(offset, secret)?.finalize().into_bytes()))
}

fn verify_offset_signature(offset: i64, secret: &str, signature: &str) -> Result<()> {
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(signature.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))?;

    cursor_mac(offset, secret)?
        .verify_slice(&signature_bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))
}

fn cursor_mac(offset: i64, secret: &str) -> Result<HmacSha256> {
    let mut mac = new_mac(secret)?;
    mac.update(b"srql-cursor-v2:");
    mac.update(offset.to_string().as_bytes());
    Ok(mac)
}

fn new_mac(secret: &str) -> Result<HmacSha256> {
    if secret.trim().is_empty() {
        return Err(ServiceError::InvalidRequest(
            "cursor signing secret must not be empty".into(),
        ));
    }
    HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signing secret".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_cursor() {
        let encoded = encode_cursor(250, "secret").unwrap();
        let decoded = decode_cursor(&encoded, "secret", 1_000).unwrap();
        assert_eq!(decoded, 250);
    }

    #[test]
    fn decode_rejects_bad_data() {
        let err = decode_cursor("$$$", "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_tampered_signature() {
        let encoded = encode_cursor(250, "secret").unwrap();
        let err = decode_cursor(&encoded, "other-secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_offset_above_bound() {
        let encoded = encode_cursor(1_001, "secret").unwrap();
        let err = decode_cursor(&encoded, "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_malformed_signature_encoding() {
        let payload = CursorPayload {
            v: 2,
            offset: 250,
            sig: "$$$".to_string(),
        };
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());

        let err = decode_cursor(&encoded, "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn keyset_cursor_round_trips_without_an_offset_ceiling() {
        let encoded = encode_keyset_cursor(
            "devices",
            "uid",
            KeysetDirection::Desc,
            "sr:dev-0042",
            "secret",
        )
        .unwrap();
        assert_eq!(
            decode_position(&encoded, "secret", 0).unwrap(),
            CursorPosition::Keyset(KeysetPosition {
                entity: "devices".into(),
                column: "uid".into(),
                direction: KeysetDirection::Desc,
                key: "sr:dev-0042".into(),
            })
        );
    }

    #[test]
    fn offset_cursor_still_decodes_as_an_offset() {
        let encoded = encode_cursor(250, "secret").unwrap();
        assert_eq!(
            decode_position(&encoded, "secret", 1_000).unwrap(),
            CursorPosition::Offset(250)
        );
        let err = decode_position(&encoded, "secret", 100).unwrap_err();
        assert!(err.to_string().contains("exceeds maximum"));
    }

    /// The signature covers the canonical JSON the cursor format specifies:
    /// compact, keys in the order v, entity, col, dir, key.
    #[test]
    fn keyset_signature_covers_the_canonical_json() {
        let encoded =
            encode_keyset_cursor("devices", "uid", KeysetDirection::Asc, "dev-1", "secret")
                .unwrap();
        let payload: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(encoded).unwrap()).unwrap();

        let mut mac = HmacSha256::new_from_slice(b"secret").unwrap();
        mac.update(br#"{"v":3,"entity":"devices","col":"uid","dir":"asc","key":"dev-1"}"#);
        let expected = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        assert_eq!(payload["sig"], expected);
    }

    #[test]
    fn keyset_cursor_rejects_tampering() {
        let encoded = encode_keyset_cursor(
            "devices",
            "uid",
            KeysetDirection::Asc,
            "sr:dev-0042",
            "secret",
        )
        .unwrap();
        assert!(decode_position(&encoded, "other-secret", 0).is_err());

        for (field, value) in [
            ("key", "sr:dev-9999"),
            ("dir", "desc"),
            ("entity", "agents"),
        ] {
            let mut payload: serde_json::Value =
                serde_json::from_slice(&URL_SAFE_NO_PAD.decode(&encoded).unwrap()).unwrap();
            payload[field] = serde_json::Value::String(value.into());
            let forged = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
            let err = decode_position(&forged, "secret", 0).unwrap_err();
            assert!(matches!(err, ServiceError::InvalidRequest(_)), "{field}");
        }
    }

    #[test]
    fn keyset_cursor_is_minted_only_for_a_declared_key() {
        assert!(
            encode_keyset_cursor("devices", "hostname", KeysetDirection::Asc, "h", "secret")
                .is_err()
        );
        assert!(
            encode_keyset_cursor("interfaces", "uid", KeysetDirection::Asc, "i", "secret").is_err()
        );
    }

    #[test]
    fn encode_rejects_empty_secret() {
        let err = encode_cursor(250, "   ").unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
