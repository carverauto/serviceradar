use super::*;

/// Normalize and validate a CIDR string (e.g. `10.0.0.0/8`).
///
/// Shared by the row, stats, and downsample filter paths.
pub(crate) fn normalize_cidr_literal(input: &str) -> Result<String> {
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

/// Build a SQL boolean expression: `COALESCE(column, '[]') @> '["tag"]'::jsonb`.
///
/// COALESCE is required so `NOT (tag_contains …)` keeps untagged rows (NULL
/// columns). Without it, SQL three-valued logic makes `NOT (NULL @> …)` drop
/// the untagged majority of flow rows.
pub(in crate::query::flows) fn tag_contains_sql(column: &str, tag: &str) -> Result<String> {
    let tag = normalize_tag_literal(tag)?;
    let json = serde_json::to_string(&vec![&tag]).map_err(|err| {
        ServiceError::Internal(anyhow::anyhow!("failed to encode tag json: {err}"))
    })?;
    // JSON encoding never emits single quotes for our validated charset, but
    // escape defensively so the SQL string literal stays well-formed.
    let escaped = json.replace('\'', "''");
    Ok(format!(
        "(COALESCE({column}, '[]'::jsonb) @> '{escaped}'::jsonb)"
    ))
}

/// OR of `tag_contains_sql` for each tag.
///
/// Empty list yields `FALSE` so `tag in ()` matches no rows. Callers that
/// wrap with NOT (NotIn) then match every row — same convention as
/// `trace_summaries` empty-list handling.
pub(in crate::query::flows) fn tag_any_contains_sql(
    column: &str,
    tags: &[String],
) -> Result<String> {
    if tags.is_empty() {
        return Ok("FALSE".to_string());
    }
    let parts: Result<Vec<String>> = tags.iter().map(|t| tag_contains_sql(column, t)).collect();
    Ok(format!("({})", parts?.join(" OR ")))
}

/// Shared tag filter SQL for both row and stats paths.
///
/// `src_col` / `dst_col` are the fully qualified column expressions
/// (e.g. `src_prefix_tags` or `f.src_prefix_tags`).
pub(in crate::query::flows) fn tag_filter_sql(
    field: &str,
    op: &crate::parser::FilterOp,
    value: &crate::parser::FilterValue,
    src_col: &str,
    dst_col: &str,
) -> Result<String> {
    use crate::parser::FilterOp;

    match field {
        "src_tag" => match op {
            FilterOp::Eq | FilterOp::NotEq => tag_contains_sql(src_col, value.as_scalar()?),
            FilterOp::In | FilterOp::NotIn => tag_any_contains_sql(src_col, value.as_list()?),
            _ => Err(ServiceError::InvalidRequest(
                "src_tag filter only supports equality or list matching".into(),
            )),
        },
        "dst_tag" => match op {
            FilterOp::Eq | FilterOp::NotEq => tag_contains_sql(dst_col, value.as_scalar()?),
            FilterOp::In | FilterOp::NotIn => tag_any_contains_sql(dst_col, value.as_list()?),
            _ => Err(ServiceError::InvalidRequest(
                "dst_tag filter only supports equality or list matching".into(),
            )),
        },
        "tag" => match op {
            FilterOp::Eq | FilterOp::NotEq => {
                let tag = value.as_scalar()?;
                let src = tag_contains_sql(src_col, tag)?;
                let dst = tag_contains_sql(dst_col, tag)?;
                Ok(format!("({src} OR {dst})"))
            }
            FilterOp::In | FilterOp::NotIn => {
                let values = value.as_list()?;
                let src = tag_any_contains_sql(src_col, values)?;
                let dst = tag_any_contains_sql(dst_col, values)?;
                Ok(format!("({src} OR {dst})"))
            }
            _ => Err(ServiceError::InvalidRequest(
                "tag filter only supports equality or list matching".into(),
            )),
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported tag filter field: '{other}'"
        ))),
    }
}

/// Parsed proximity term: latitude, longitude, radius in meters.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(in crate::query::flows) struct NearPoint {
    pub lat: f64,
    pub lng: f64,
    pub radius_m: f64,
}

/// Parse `near` filter values like `30.2672,-97.7431,50km` or `30.27,-97.74,5000m`.
///
/// Default unit when omitted is kilometers. Supported suffixes: `km`, `m`, `mi`.
pub(in crate::query::flows) fn normalize_near_literal(raw: &str) -> Result<NearPoint> {
    let trimmed = raw.trim().trim_matches('"').trim_matches('\'').trim();
    if trimmed.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "near filter requires lat,lng,radius (e.g. 30.27,-97.74,50km)".into(),
        ));
    }

    let parts: Vec<&str> = trimmed.split(',').map(str::trim).collect();
    if parts.len() != 3 {
        return Err(ServiceError::InvalidRequest(
            "near filter must be lat,lng,radius (exactly three comma-separated fields)".into(),
        ));
    }

    let lat: f64 = parts[0].parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("near latitude is not a number: {}", parts[0]))
    })?;
    let lng: f64 = parts[1].parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("near longitude is not a number: {}", parts[1]))
    })?;

    if !(-90.0..=90.0).contains(&lat) {
        return Err(ServiceError::InvalidRequest(
            "near latitude must be between -90 and 90".into(),
        ));
    }
    if !(-180.0..=180.0).contains(&lng) {
        return Err(ServiceError::InvalidRequest(
            "near longitude must be between -180 and 180".into(),
        ));
    }

    let radius_m = parse_radius_meters(parts[2])?;
    if !(radius_m.is_finite() && radius_m > 0.0 && radius_m <= 20_000_000.0) {
        return Err(ServiceError::InvalidRequest(
            "near radius must be a positive distance (max ~20000 km)".into(),
        ));
    }

    Ok(NearPoint { lat, lng, radius_m })
}

fn parse_radius_meters(raw: &str) -> Result<f64> {
    let s = raw.trim().to_ascii_lowercase();
    let (num_str, factor) = if let Some(rest) = s.strip_suffix("km") {
        (rest.trim(), 1_000.0)
    } else if let Some(rest) = s.strip_suffix("mi") {
        (rest.trim(), 1_609.344)
    } else if let Some(rest) = s.strip_suffix('m') {
        (rest.trim(), 1.0)
    } else {
        // default kilometers
        (s.as_str(), 1_000.0)
    };

    let value: f64 = num_str
        .parse()
        .map_err(|_| ServiceError::InvalidRequest(format!("near radius is not a number: {raw}")))?;
    Ok(value * factor)
}

/// SQL boolean: src and/or dst IP is within radius of the point via geo cache GiST.
///
/// Spatial work runs only on `ip_geo_enrichment_cache.location`; flow rows are
/// filtered by IP membership (no per-flow geometry).
pub(in crate::query::flows) fn near_exists_sql(point: NearPoint, side: NearSide) -> String {
    match side {
        NearSide::Either => format!(
            "({} OR {})",
            near_exists_sql(point, NearSide::Src),
            near_exists_sql(point, NearSide::Dst)
        ),
        NearSide::Src | NearSide::Dst => {
            let (ip_col, alias) = match side {
                NearSide::Src => ("src_endpoint_ip", "gs"),
                NearSide::Dst => ("dst_endpoint_ip", "gd"),
                NearSide::Either => unreachable!(),
            };

            format!(
                "EXISTS (\
                    SELECT 1 FROM ip_geo_enrichment_cache {alias} \
                    WHERE {alias}.ip = NULLIF({ip_col}, '') \
                      AND {alias}.location IS NOT NULL \
                      AND ({alias}.expires_at IS NULL OR {alias}.expires_at > now()) \
                      AND ST_DWithin(\
                            {alias}.location, \
                            ST_SetSRID(ST_MakePoint({lng}, {lat}), 4326)::geography, \
                            {radius_m}\
                      )\
                 )",
                alias = alias,
                ip_col = ip_col,
                lng = point.lng,
                lat = point.lat,
                radius_m = point.radius_m
            )
        }
    }
}

/// Which flow endpoint(s) the proximity filter applies to.
#[derive(Debug, Clone, Copy)]
pub(in crate::query::flows) enum NearSide {
    Src,
    Dst,
    Either,
}
