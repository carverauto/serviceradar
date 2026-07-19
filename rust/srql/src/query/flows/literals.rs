use super::*;

pub(super) fn normalize_cidr_literal(input: &str) -> Result<String> {
    let s = input.trim();
    let (ip_raw, prefix_raw) = s
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("CIDR must be like 10.0.0.0/24".into()))?;

    let ip: std::net::IpAddr = ip_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid IPv4/IPv6 address".into())
    })?;

    let prefix: u8 = prefix_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid prefix length".into())
    })?;

    let max = match ip {
        std::net::IpAddr::V4(_) => 32,
        std::net::IpAddr::V6(_) => 128,
    };
    if prefix > max {
        return Err(ServiceError::InvalidRequest(format!(
            "CIDR prefix length must be <= {max}"
        )));
    }

    Ok(format!("{ip}/{prefix}"))
}

pub(super) fn normalize_device_uid_literal(input: &str) -> Result<String> {
    let uid = input.trim();
    let valid = !uid.is_empty()
        && uid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '-' | '_' | '.'));

    if valid {
        Ok(uid.to_string())
    } else {
        Err(ServiceError::InvalidRequest(
            "device_id filter must be a canonical UID-like value".into(),
        ))
    }
}

/// Validate a prefix-tag literal for JSONB containment filters.
///
/// Tags are namespaced strings like `site:austin-dc` or `netbox:tag:iot`.
pub(in crate::query::flows) fn normalize_tag_literal(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ServiceError::InvalidRequest("tag literal is empty".into()));
    }
    if trimmed.len() > 128 {
        return Err(ServiceError::InvalidRequest(
            "tag literal exceeds 128 characters".into(),
        ));
    }
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '-' | '_' | '.' | '/' | '@' | '+'))
    {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid tag literal: {trimmed}"
        )));
    }
    Ok(trimmed.to_string())
}

/// Build a SQL boolean expression: `column @> '["tag"]'::jsonb`.
pub(in crate::query::flows) fn tag_contains_sql(column: &str, tag: &str) -> Result<String> {
    let tag = normalize_tag_literal(tag)?;
    let json = serde_json::to_string(&vec![&tag]).map_err(|err| {
        ServiceError::Internal(anyhow::anyhow!("failed to encode tag json: {err}"))
    })?;
    // JSON encoding never emits single quotes for our validated charset, but
    // escape defensively so the SQL string literal stays well-formed.
    let escaped = json.replace('\'', "''");
    Ok(format!("({column} @> '{escaped}'::jsonb)"))
}

/// OR of `tag_contains_sql` for each tag. Empty list yields `TRUE` (no-op).
pub(in crate::query::flows) fn tag_any_contains_sql(
    column: &str,
    tags: &[String],
) -> Result<String> {
    if tags.is_empty() {
        return Ok("TRUE".to_string());
    }
    let parts: Result<Vec<String>> = tags.iter().map(|t| tag_contains_sql(column, t)).collect();
    Ok(format!("({})", parts?.join(" OR ")))
}
