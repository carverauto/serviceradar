//! One bounded, exact-pair read of current IF-MIB rates. This is a typed internal
//! compiler API, not an alternate telemetry store or a public SQL entry point.
use std::collections::BTreeSet;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::{BindParam, PaginationMeta, TranslateResponse, counter_rate, starrocks};
use crate::{
    config::AppConfig,
    error::{Result, ServiceError},
};

pub const MAX_PAIRS: usize = 512;
pub const MAX_REQUEST_BYTES: usize = 1_048_576;
pub const FAMILY_COUNT: usize = 8;

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(deny_unknown_fields)]
pub struct InterfacePair {
    pub device_id: String,
    pub if_index: i32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InterfaceRateRequest {
    pub pairs: Vec<InterfacePair>,
    pub since: DateTime<Utc>,
    pub until: DateTime<Utc>,
    pub fresh_after: DateTime<Utc>,
}

impl InterfaceRateRequest {
    fn validate(&self) -> Result<()> {
        let invalid =
            || ServiceError::InvalidRequest("invalid bounded interface-rate request".into());
        if self.pairs.is_empty()
            || self.pairs.len() > MAX_PAIRS
            || self.since >= self.until
            || self.until - self.since > Duration::hours(1)
            || self.fresh_after < self.since
            || self.fresh_after > self.until
        {
            return Err(invalid());
        }
        let mut seen = BTreeSet::new();
        let mut bytes = 0usize;
        for pair in &self.pairs {
            bytes = bytes
                .checked_add(pair.device_id.len())
                .ok_or_else(invalid)?;
            if bytes > MAX_REQUEST_BYTES
                || pair.device_id.is_empty()
                || pair.device_id.contains('\0')
                || pair.if_index <= 0
                || !seen.insert(pair)
            {
                return Err(invalid());
            }
        }
        // The NIF checks before JSON decoding too. This public Rust entry point
        // enforces the same complete request budget, including escaped identities.
        if serde_json::to_vec(self).map_err(|_| invalid())?.len() > MAX_REQUEST_BYTES {
            return Err(invalid());
        }
        Ok(())
    }
}

/// Compile at most eight rows per requested interface. `observed_at` is the
/// actual newest sample, never a display bucket. A NULL rate is unknown or
/// ambiguous; a measured zero remains zero. HC preference applies only to a
/// fresh valid interval from the exact pair and family. Invalid HC can fall
/// back to valid legacy, and the returned metric_name records that choice.
pub fn translate_interface_rates(
    config: &AppConfig,
    request: InterfaceRateRequest,
    mode: Option<&str>,
) -> Result<TranslateResponse> {
    request.validate()?;
    let warehouse = match mode {
        None => false,
        Some("starrocks" | "starrocks_raw") => true,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "invalid interface-rate backend".into(),
            ));
        }
    };
    let (requested, table, since, until, fresh, ts, ceiling, rate, params) = if warehouse {
        starrocks::validate_identifier(&config.starrocks_database)?;
        let requested = request
            .pairs
            .iter()
            .map(|p| {
                format!(
                    "SELECT {} AS device_id, {} AS if_index",
                    starrocks::sql_literal(&p.device_id),
                    p.if_index
                )
            })
            .collect::<Vec<_>>()
            .join(" UNION ALL ");
        let literal = |t: DateTime<Utc>| {
            starrocks::sql_literal(&t.format("%Y-%m-%d %H:%M:%S%.6f").to_string())
        };
        let elapsed = "NULLIF(milliseconds_diff(observed_at, previous_observed_at) / 1000.0, 0)";
        (
            requested,
            format!("{}.timeseries_metrics", config.starrocks_database),
            literal(request.since),
            literal(request.until),
            literal(request.fresh_after),
            "t.`timestamp`",
            "NULL".to_string(),
            counter_rate::warehouse("value", "previous_value", elapsed),
            vec![],
        )
    } else {
        let elapsed = "NULLIF(EXTRACT(EPOCH FROM (observed_at - previous_observed_at)), 0)";
        (
            "SELECT * FROM unnest($1::text[], $2::integer[]) AS p(device_id, if_index)".into(),
            "platform.timeseries_metrics".into(),
            "$3".into(),
            "$4".into(),
            "$5".into(),
            "t.timestamp",
            counter_rate::postgres_ceiling("t.metadata"),
            counter_rate::postgres("value", "previous_value", elapsed),
            vec![
                BindParam::TextArray(request.pairs.iter().map(|p| p.device_id.clone()).collect()),
                BindParam::IntArray(
                    request
                        .pairs
                        .iter()
                        .map(|p| i64::from(p.if_index))
                        .collect(),
                ),
                BindParam::timestamptz(request.since),
                BindParam::timestamptz(request.until),
                BindParam::timestamptz(request.fresh_after),
            ],
        )
    };
    let families = [
        ("in", "octets", "ifInOctets", "ifHCInOctets"),
        ("out", "octets", "ifOutOctets", "ifHCOutOctets"),
        ("in", "unicast_packets", "ifInUcastPkts", "ifHCInUcastPkts"),
        ("out", "unicast_packets", "ifOutUcastPkts", "ifHCOutUcastPkts"),
        ("in", "multicast_packets", "ifInMulticastPkts", "ifHCInMulticastPkts"),
        ("out", "multicast_packets", "ifOutMulticastPkts", "ifHCOutMulticastPkts"),
        ("in", "broadcast_packets", "ifInBroadcastPkts", "ifHCInBroadcastPkts"),
        ("out", "broadcast_packets", "ifOutBroadcastPkts", "ifHCOutBroadcastPkts"),
    ].iter().map(|(direction, family, legacy, hc)| format!(
        "SELECT '{direction}' AS direction, '{family}' AS family, '{legacy}' AS legacy, '{hc}' AS hc"
    )).collect::<Vec<_>>().join(" UNION ALL ");
    let physical = "t.device_id, t.if_index, t.gateway_id, COALESCE(t.agent_id, ''), t.metric_type, t.metric_name, t.series_key";
    let group = "device_id, if_index, direction, family";
    let sql = format!(
        r#"WITH requested AS ({requested}),
families AS ({families}),
samples AS (
  SELECT t.device_id, t.if_index, f.direction, f.family, t.metric_name,
    t.gateway_id, t.agent_id, t.series_key,
    CASE WHEN split_part(t.metric_name, '::', 1) = f.hc THEN 0 ELSE 1 END AS preference,
    {ts} AS observed_at, t.value, t.counter_width, {ceiling} AS max_rate_per_second,
    LEAD(t.value) OVER (PARTITION BY {physical} ORDER BY {ts} DESC) AS previous_value,
    LEAD({ts}) OVER (PARTITION BY {physical} ORDER BY {ts} DESC) AS previous_observed_at,
    ROW_NUMBER() OVER (PARTITION BY {physical} ORDER BY {ts} DESC) AS sample_rank
  FROM {table} t
  JOIN requested p ON p.device_id = t.device_id AND p.if_index = t.if_index
  JOIN families f ON split_part(t.metric_name, '::', 1) IN (f.legacy, f.hc)
  WHERE t.metric_type = 'snmp' AND {ts} >= {since} AND {ts} <= {until}
), rated AS (
  SELECT *, CASE WHEN observed_at >= {fresh} AND observed_at > previous_observed_at
    AND value >= 0 AND previous_value >= 0
    AND value <= 18446744073709551616 AND previous_value <= 18446744073709551616 THEN {rate} ELSE NULL END AS rate_value
  FROM samples WHERE sample_rank = 1
), preferred AS (
  SELECT *, MIN(CASE WHEN rate_value IS NOT NULL THEN preference ELSE 2 END)
    OVER (PARTITION BY {group}) AS best_preference
  FROM rated
), candidates AS (
  SELECT *, SUM(CASE WHEN rate_value IS NOT NULL AND preference = best_preference THEN 1 ELSE 0 END)
    OVER (PARTITION BY {group}) AS eligible_producers,
    ROW_NUMBER() OVER (PARTITION BY {group} ORDER BY
      CASE WHEN rate_value IS NOT NULL THEN preference ELSE 2 END,
      observed_at DESC, COALESCE(gateway_id, ''), COALESCE(agent_id, ''), series_key, metric_name) AS candidate_rank
  FROM preferred
)
SELECT p.device_id, p.if_index, f.direction, f.family,
  c.metric_name, c.gateway_id, c.agent_id, c.series_key,
  c.observed_at, c.previous_observed_at,
  CASE WHEN c.eligible_producers = 1 THEN c.rate_value ELSE NULL END AS rate,
  CASE WHEN c.eligible_producers = 1 THEN 'measured'
    WHEN c.eligible_producers > 1 THEN 'ambiguous' ELSE 'unknown' END AS status,
  COALESCE(c.eligible_producers, 0) AS eligible_producers
FROM requested p CROSS JOIN families f
LEFT JOIN candidates c ON c.device_id = p.device_id AND c.if_index = p.if_index
  AND c.direction = f.direction AND c.family = f.family AND c.candidate_rank = 1
ORDER BY p.device_id, p.if_index, f.direction, f.family"#
    );
    Ok(TranslateResponse {
        read_model: None,
        sql,
        params,
        pagination: PaginationMeta {
            limit: Some((request.pairs.len() * FAMILY_COUNT) as i64),
            ..Default::default()
        },
        viz: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn request() -> InterfaceRateRequest {
        let since = Utc.with_ymd_and_hms(2001, 2, 3, 4, 5, 0).unwrap();
        InterfaceRateRequest {
            pairs: vec![InterfacePair {
                device_id: "sr:rate-alpha".into(),
                if_index: 7,
            }],
            since,
            until: since + Duration::minutes(1),
            fresh_after: since + Duration::seconds(30),
        }
    }

    // Request limits protect a native entry point before it compiles SQL. Rate
    // semantics are owned by InterfaceRatesDbTest, which executes this compiler.
    #[test]
    fn public_compiler_rejects_unbounded_and_incoherent_requests() {
        let config = AppConfig::embedded("postgres://unused/db".into());
        let valid = request();
        let mut invalid = vec![];
        let mut empty = valid.clone();
        empty.pairs.clear();
        invalid.push(empty);
        let mut duplicate = valid.clone();
        duplicate.pairs.push(valid.pairs[0].clone());
        invalid.push(duplicate);
        let mut count = valid.clone();
        count.pairs = (0..=MAX_PAIRS)
            .map(|i| InterfacePair {
                device_id: format!("sr:rate-{i}"),
                if_index: 1,
            })
            .collect();
        invalid.push(count);
        let mut bytes = valid.clone();
        bytes.pairs[0].device_id = "x".repeat(MAX_REQUEST_BYTES);
        invalid.push(bytes);
        let mut index = valid.clone();
        index.pairs[0].if_index = 0;
        invalid.push(index);
        let mut range = valid.clone();
        range.until = range.since + Duration::hours(2);
        invalid.push(range);
        let mut freshness = valid;
        freshness.fresh_after = freshness.until + Duration::seconds(1);
        invalid.push(freshness);
        for request in invalid {
            assert!(translate_interface_rates(&config, request, None).is_err());
        }
    }

    #[test]
    fn total_budget_preserves_long_exact_identities_and_backend_binding() {
        let config = AppConfig::embedded("postgres://unused/db".into());
        let mut request = request();
        request.pairs[0].device_id = format!("sr:{}'\\tail", "x".repeat(8_192));
        let compiled = translate_interface_rates(&config, request.clone(), None).unwrap();
        let BindParam::TextArray(ids) = &compiled.params[0] else {
            panic!("expected identity binds")
        };
        assert_eq!(ids, &[request.pairs[0].device_id.clone()]);
        assert_eq!(compiled.pagination.limit, Some(8));
        for mode in ["starrocks", "starrocks_raw"] {
            let compiled = translate_interface_rates(&config, request.clone(), Some(mode)).unwrap();
            assert!(compiled.params.is_empty());
            assert_eq!(compiled.pagination.limit, Some(8));
        }
        assert!(translate_interface_rates(&config, request, Some("unrecognized")).is_err());
    }
}
