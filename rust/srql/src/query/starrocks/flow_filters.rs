use super::{cidr_hex_bounds, field_sql, flow_cidr_filter_sql, sql_literal, text_predicate_on};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::{
        QueryPlan,
        flows::literals::{NearPoint, normalize_near_literal, normalize_tag_literal},
    },
};

/// Resolve flow aliases and JSON metadata without expanding the shared dataset dispatcher.
pub(super) fn row_field(field: &str, column: &impl Fn(&str) -> String) -> Option<String> {
    let alias = match field {
        "proto" => Some("protocol_num"),
        "in_if_index" => Some("input_snmp"),
        "out_if_index" => Some("output_snmp"),
        "process_pid" => Some("pid"),
        "process" | "process_name" => Some("comm"),
        "redacted_cmdline" => Some("cmdline"),
        _ => None,
    };
    if let Some(alias) = alias {
        return Some(column(alias));
    }
    match field {
        "flow_source" | "collector" => {
            return Some(format!("COALESCE({}, 'Unknown')", column("flow_source")));
        }
        "image" | "image_ref" => {
            return Some(format!(
                "COALESCE(get_json_string({0}, '$.image'), get_json_string({0}, '$.image_ref'))",
                column("workload_identity")
            ));
        }
        "attribution_status" | "status" => {
            return Some(format!(
                "CASE WHEN {} IS NULL THEN 'unmatched' ELSE 'attributed' END",
                column("pid")
            ));
        }
        _ => {}
    }
    let (document, key) = match field {
        "pod_name" | "pod_namespace" | "pod_uid" | "container_name" | "runtime_source" => {
            ("workload_identity", field)
        }
        "namespace" => ("workload_identity", "pod_namespace"),
        "service_name" | "public_endpoint_service" | "k8s_service" => {
            ("public_endpoint", "service_name")
        }
        "gateway_name" | "public_endpoint_gateway" => ("public_endpoint", "gateway_name"),
        "exposure_class" | "public_endpoint_class" => ("public_endpoint", "exposure_class"),
        "public_endpoint_namespace" => ("public_endpoint", "namespace"),
        "route_name" | "public_endpoint_route" => ("public_endpoint", "route_name"),
        _ => return None,
    };
    Some(format!("get_json_string({}, '$.{key}')", column(document)))
}

/// Flow row filters use the CNPG field and operator contract, independently
/// of the physical warehouse columns also available to stats and sorting.
pub(super) fn predicate(plan: &QueryPlan, filter: &Filter) -> Result<Option<String>> {
    let sql = match filter.field.as_str() {
        "device_id" => super::device_scope_sql(plan, filter)?,
        "src_cidr" => flow_cidr_filter_sql(filter, "src")?,
        "dst_cidr" => flow_cidr_filter_sql(filter, "dst")?,
        "device_addr" | "device_address" => device_addresses(plan, filter)?,
        "ip" | "endpoint_ip" => bidirectional_text(plan, filter)?,
        "port" | "endpoint_port" => bidirectional_port(plan, filter)?,
        "cidr" => {
            let src = flow_cidr_filter_sql(filter, "src")?;
            let dst = flow_cidr_filter_sql(filter, "dst")?;
            let join = if negative(&filter.op) { "AND" } else { "OR" };
            format!("({src} {join} {dst})")
        }
        "tag" | "src_tag" | "dst_tag" => tags(plan, filter)?,
        "near" | "src_near" | "dst_near" => proximity(plan, filter)?,
        "threat_matched" | "threat_source" | "threat_observed_ip" | "threat_indicator"
        | "threat_severity" => threat(plan, filter)?,
        "protocol_num" | "proto" => {
            require_op(filter, &[FilterOp::Eq, FilterOp::NotEq])?;
            integer_predicate(&field_sql(plan, &filter.field)?, filter, false)?
        }
        "src_port" | "src_endpoint_port" | "dst_port" | "dst_endpoint_port" => {
            let column = field_sql(plan, &filter.field)?;
            if matches!(filter.op, FilterOp::Like | FilterOp::NotLike) {
                text_predicate_on(&format!("CAST({column} AS STRING)"), filter, false)?
                    .unwrap_or_else(|| "TRUE".into())
            } else {
                require_op(
                    filter,
                    &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
                )?;
                integer_predicate(&column, filter, false)?
            }
        }
        "input_snmp" | "in_if_index" | "output_snmp" | "out_if_index" => {
            require_op(
                filter,
                &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
            )?;
            integer_predicate(&field_sql(plan, &filter.field)?, filter, true)?
        }
        "src_country_iso2" | "src_country" | "dst_country_iso2" | "dst_country" => {
            require_op(filter, &[FilterOp::Eq, FilterOp::NotEq])?;
            let value = filter.value.as_scalar()?.trim().to_ascii_uppercase();
            if value.len() != 2 || !value.bytes().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "country must be a two-letter ISO code".into(),
                ));
            }
            let column = field_sql(plan, &filter.field)?;
            let eq = format!("COALESCE({column} = {}, FALSE)", sql_literal(&value));
            if negative(&filter.op) {
                format!("NOT ({eq})")
            } else {
                eq
            }
        }
        "pid" | "process_pid" | "uid" | "in_if_speed_bps" | "out_if_speed_bps" => {
            let column = format!("CAST({} AS STRING)", field_sql(plan, &filter.field)?);
            text_predicate_on(&column, filter, plan.stats.is_none())?
                .unwrap_or_else(|| "TRUE".into())
        }
        "src_ip"
        | "src_endpoint_ip"
        | "dst_ip"
        | "dst_endpoint_ip"
        | "protocol_name"
        | "protocol_group"
        | "proto_group"
        | "direction_label"
        | "dst_service_label"
        | "sampler_address"
        | "exporter_name"
        | "in_if_name"
        | "out_if_name"
        | "flow_source"
        | "collector"
        | "event_type"
        | "attribution_status"
        | "status"
        | "comm"
        | "process"
        | "process_name"
        | "cmdline"
        | "redacted_cmdline"
        | "container_id"
        | "agent_id"
        | "pod_name"
        | "pod_namespace"
        | "namespace"
        | "pod_uid"
        | "container_name"
        | "image"
        | "image_ref"
        | "runtime_source"
        | "service_name"
        | "public_endpoint_service"
        | "k8s_service"
        | "gateway_name"
        | "public_endpoint_gateway"
        | "exposure_class"
        | "public_endpoint_class"
        | "public_endpoint_namespace"
        | "route_name"
        | "public_endpoint_route"
        | "app" => text_predicate_on(
            &field_sql(plan, &filter.field)?,
            filter,
            plan.stats.is_none(),
        )?
        .unwrap_or_else(|| "TRUE".into()),
        _ => return Ok(None),
    };
    Ok(Some(sql))
}

fn device_addresses(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(filter, &[FilterOp::Eq, FilterOp::In])?;
    if matches!(filter.op, FilterOp::In) && filter.value.as_list()?.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "device_addr requires a non-empty address list".into(),
        ));
    }
    let predicates = ["src_endpoint_ip", "dst_endpoint_ip", "sampler_address"]
        .iter()
        .map(|field| {
            super::filter_sql(
                plan,
                &Filter {
                    field: (*field).into(),
                    ..filter.clone()
                },
            )
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!("({})", predicates.join(" OR ")))
}

fn negative(op: &FilterOp) -> bool {
    matches!(op, FilterOp::NotEq | FilterOp::NotIn | FilterOp::NotLike)
}

fn require_op(filter: &Filter, allowed: &[FilterOp]) -> Result<()> {
    if allowed
        .iter()
        .any(|op| std::mem::discriminant(op) == std::mem::discriminant(&filter.op))
    {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for {}: {:?}",
            filter.field, filter.op
        )))
    }
}

fn integer_predicate(column: &str, filter: &Filter, snmp: bool) -> Result<String> {
    let parse = |value: &str| -> Result<String> {
        let value = value.parse::<i64>().map_err(|_| {
            ServiceError::InvalidRequest(format!("{} must be an integer", filter.field))
        })?;
        if (snmp && value < 0) || (!snmp && i32::try_from(value).is_err()) {
            return Err(ServiceError::InvalidRequest(format!(
                "{} integer is out of range",
                filter.field
            )));
        }
        Ok(value.to_string())
    };
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = parse(filter.value.as_scalar()?)?;
            let op = if negative(&filter.op) { "<>" } else { "=" };
            Ok(format!("{column} {op} {}", sql_literal(&value)))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|v| parse(v))
                .collect::<Result<Vec<_>>>()?;
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            let op = if negative(&filter.op) { "NOT IN" } else { "IN" };
            Ok(format!("{column} {op} ({})", values.join(", ")))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported integer operator for {}",
            filter.field
        ))),
    }
}

fn bidirectional_text(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    let predicates = ["src_endpoint_ip", "dst_endpoint_ip"]
        .iter()
        .map(|field| {
            text_predicate_on(&field_sql(plan, field)?, filter, true)
                .map(|sql| sql.unwrap_or_else(|| "TRUE".into()))
        })
        .collect::<Result<Vec<_>>>()?;
    let join = if negative(&filter.op) {
        " AND "
    } else {
        " OR "
    };
    Ok(format!("({})", predicates.join(join)))
}

fn bidirectional_port(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(
        filter,
        &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
    )?;
    let predicates = ["src_endpoint_port", "dst_endpoint_port"]
        .iter()
        .map(|field| {
            let column = field_sql(plan, field)?;
            let sql = integer_predicate(&column, filter, false)?;
            Ok(if negative(&filter.op) {
                format!("({column} IS NULL OR {sql})")
            } else {
                sql
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let join = if negative(&filter.op) {
        " AND "
    } else {
        " OR "
    };
    Ok(format!("({})", predicates.join(join)))
}

fn tags(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(
        filter,
        &[FilterOp::Eq, FilterOp::NotEq, FilterOp::In, FilterOp::NotIn],
    )?;
    let raw = if matches!(filter.op, FilterOp::In | FilterOp::NotIn) {
        filter
            .value
            .as_list()?
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
    } else {
        vec![filter.value.as_scalar()?]
    };
    let values = raw
        .into_iter()
        .map(normalize_tag_literal)
        .collect::<Result<Vec<_>>>()?;
    let fields: &[&str] = match filter.field.as_str() {
        "src_tag" => &["src_prefix_tags"],
        "dst_tag" => &["dst_prefix_tags"],
        _ => &["src_prefix_tags", "dst_prefix_tags"],
    };
    let mut predicates = Vec::new();
    for field in fields {
        let column = field_sql(plan, field)?;
        for value in &values {
            predicates.push(format!("COALESCE(ARRAY_CONTAINS(CAST(PARSE_JSON({column}) AS ARRAY<VARCHAR(65533)>), {}), FALSE)", sql_literal(value)));
        }
    }
    let sql = if predicates.is_empty() {
        "FALSE".into()
    } else {
        format!("({})", predicates.join(" OR "))
    };
    Ok(if negative(&filter.op) {
        format!("NOT ({sql})")
    } else {
        sql
    })
}

/// Flows whose endpoint is in a CNPG current-state IP set, read through the
/// `cnpg_platform` JDBC catalog. StarRocks 4.1 has no JDBC pass-through
/// (`native_query` first ships in 4.2) and cannot read PostgreSQL `text[]`,
/// `inet`/`cidr` or `geography` columns, so `source` selects only scalar
/// columns: the plain caches, or the `_catalog` views that flatten the rest.
/// StarRocks pushes those scalar predicates into the remote PostgreSQL query,
/// so only matching rows cross the catalog; flow telemetry stays in the
/// warehouse.
fn catalog_membership(plan: &QueryPlan, source: &str, sides: &[&str]) -> Result<String> {
    let predicates = sides
        .iter()
        .map(|field| {
            let endpoint = field_sql(plan, field)?;
            Ok(format!("COALESCE({endpoint} IN ({source}), FALSE)"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!("({})", predicates.join(" OR ")))
}

/// The mean-radius sphere StarRocks' `st_distance_sphere` measures on (S2's
/// 6371.01 km) is larger than the WGS84 polar radius, so an angular radius
/// computed with the polar radius can only over-cover. The bounding box is a
/// pushdown prefilter; `st_distance_sphere` makes the decision.
const POLAR_RADIUS_M: f64 = 6_356_752.0;
const BOX_SLACK_DEG: f64 = 1e-6;

/// A latitude/longitude box that contains every point within `radius_m` of the
/// center on the sphere. Longitude is left unbounded when the circle reaches a
/// pole or crosses the antimeridian.
fn proximity_box(point: &NearPoint) -> ((f64, f64), (f64, f64)) {
    let angular = (point.radius_m / POLAR_RADIUS_M).to_degrees() * 1.001 + BOX_SLACK_DEG;
    let lat = (
        (point.lat - angular).max(-90.0),
        (point.lat + angular).min(90.0),
    );
    let full_lng = (-180.0, 180.0);
    if point.lat - angular <= -90.0 || point.lat + angular >= 90.0 {
        return (lat, full_lng);
    }
    let spread = (angular.to_radians().sin() / point.lat.to_radians().cos())
        .min(1.0)
        .asin()
        .to_degrees()
        * 1.001
        + BOX_SLACK_DEG;
    if point.lng - spread < -180.0 || point.lng + spread > 180.0 {
        return (lat, full_lng);
    }
    (lat, (point.lng - spread, point.lng + spread))
}

/// `near` is "within the radius" of the coordinate on StarRocks' sphere. The
/// PostgreSQL definition measured the WGS84 spheroid, so the two can disagree
/// within a fraction of a percent of the radius; that edge difference is
/// accepted. The box bounds also exclude coordinates PostGIS would not have
/// turned into a `location`.
fn proximity(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    require_op(filter, &[FilterOp::Eq, FilterOp::NotEq])?;
    let point = normalize_near_literal(filter.value.as_scalar()?)?;
    let ((lat_lo, lat_hi), (lng_lo, lng_hi)) = proximity_box(&point);
    let source = format!(
        "SELECT g.ip FROM cnpg_platform.platform.ip_geo_enrichment_cache g \
         WHERE (g.expires_at IS NULL OR g.expires_at > UTC_TIMESTAMP()) \
         AND g.latitude BETWEEN {lat_lo:.7} AND {lat_hi:.7} \
         AND g.longitude BETWEEN {lng_lo:.7} AND {lng_hi:.7} \
         AND st_distance_sphere(g.longitude, g.latitude, {}, {}) <= {}",
        point.lng, point.lat, point.radius_m
    );
    let sides: &[&str] = match filter.field.as_str() {
        "src_near" => &["src_endpoint_ip"],
        "dst_near" => &["dst_endpoint_ip"],
        _ => &["src_endpoint_ip", "dst_endpoint_ip"],
    };
    let predicate = catalog_membership(plan, &source, sides)?;
    Ok(if negative(&filter.op) {
        format!("NOT ({predicate})")
    } else {
        predicate
    })
}

/// Hex bounds of an indicator, as `cidr_hex_bounds` encodes them: 8 digits for
/// IPv4, 32 for IPv6, so address order is string order within a family.
fn indicator_condition(raw: &str) -> Result<String> {
    if raw.contains('/') {
        let (first, last) = cidr_hex_bounds(raw)?;
        return Ok(format!(
            "c.first_ip_hex = {} AND c.last_ip_hex = {}",
            sql_literal(&first),
            sql_literal(&last)
        ));
    }
    let ip: std::net::IpAddr = raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("threat_indicator must be an IP or CIDR".into())
    })?;
    let (family, bits) = match ip {
        std::net::IpAddr::V4(_) => (4, 32),
        std::net::IpAddr::V6(_) => (6, 128),
    };
    let (hex, _) = cidr_hex_bounds(&format!("{ip}/{bits}"))?;
    let hex = sql_literal(&hex);
    Ok(format!(
        "c.indicator_family = {family} AND c.first_ip_hex <= {hex} AND c.last_ip_hex >= {hex}"
    ))
}

fn threat(plan: &QueryPlan, filter: &Filter) -> Result<String> {
    let mut relation = "ip_threat_intel_cache";
    let mut invert = false;
    let condition = match filter.field.as_str() {
        "threat_matched" => {
            require_op(filter, &[FilterOp::Eq])?;
            invert = match filter.value.as_scalar()?.to_ascii_lowercase().as_str() {
                "true" | "t" | "yes" | "1" => false,
                "false" | "f" | "no" | "0" => true,
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "threat_matched requires true or false, got '{other}'"
                    )));
                }
            };
            None
        }
        "threat_source" => {
            require_op(filter, &[FilterOp::Eq, FilterOp::In])?;
            let values = match &filter.value {
                crate::parser::FilterValue::Scalar(value) => vec![value.as_str()],
                crate::parser::FilterValue::List(values) => {
                    values.iter().map(String::as_str).collect()
                }
            };
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            relation = "ip_threat_intel_sources_catalog";
            Some(format!(
                "c.source IN ({})",
                values
                    .into_iter()
                    .map(sql_literal)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        }
        "threat_observed_ip" => {
            require_op(filter, &[FilterOp::Eq])?;
            let value = filter.value.as_scalar()?;
            value.parse::<std::net::IpAddr>().map_err(|_| {
                ServiceError::InvalidRequest("threat_observed_ip must be an IP address".into())
            })?;
            Some(format!("c.ip = {}", sql_literal(value)))
        }
        "threat_indicator" => {
            require_op(filter, &[FilterOp::Eq])?;
            relation = "threat_intel_indicator_members_catalog";
            Some(format!(
                "(c.indicator_expires_at IS NULL OR c.indicator_expires_at > UTC_TIMESTAMP()) AND {}",
                indicator_condition(filter.value.as_scalar()?)?
            ))
        }
        "threat_severity" => {
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Gt => ">",
                FilterOp::Gte => ">=",
                FilterOp::Lt => "<",
                FilterOp::Lte => "<=",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "threat_severity requires a scalar comparison".into(),
                    ));
                }
            };
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("threat_severity must be an integer".into())
            })?;
            Some(format!("c.max_severity {op} {value}"))
        }
        _ => unreachable!("threat field checked by predicate"),
    };
    // Every threat relation carries the cache row's `matched` and `expires_at`,
    // so a current match is the same test whichever relation answers.
    let mut source = format!(
        "SELECT c.ip FROM cnpg_platform.platform.{relation} c \
         WHERE c.matched AND c.expires_at > UTC_TIMESTAMP()"
    );
    if let Some(condition) = condition {
        source.push_str(" AND ");
        source.push_str(&condition);
    }
    let predicate = catalog_membership(plan, &source, &["src_endpoint_ip", "dst_endpoint_ip"])?;
    Ok(if invert {
        format!("NOT ({predicate})")
    } else {
        predicate
    })
}

#[cfg(test)]
mod tests {
    use super::{NearPoint, proximity_box};

    /// S2's mean Earth radius, the sphere `st_distance_sphere` measures on.
    const S2_RADIUS_M: f64 = 6_371_010.0;

    /// The point `distance_m` from `(lat, lng)` along `bearing_deg` on S2's sphere.
    fn destination(lat: f64, lng: f64, bearing_deg: f64, distance_m: f64) -> (f64, f64) {
        let (lat, lng, bearing) = (lat.to_radians(), lng.to_radians(), bearing_deg.to_radians());
        let angular = distance_m / S2_RADIUS_M;
        let dest_lat =
            (lat.sin() * angular.cos() + lat.cos() * angular.sin() * bearing.cos()).asin();
        let dest_lng = lng
            + (bearing.sin() * angular.sin() * lat.cos())
                .atan2(angular.cos() - lat.sin() * dest_lat.sin());
        let dest_lng = (dest_lng.to_degrees() + 540.0) % 360.0 - 180.0;
        (dest_lat.to_degrees(), dest_lng)
    }

    // The box is a pushdown prefilter: a point the sphere distance accepts but
    // the box excludes would silently drop matching flows.
    #[test]
    fn proximity_box_contains_every_point_on_the_sphere_circle() {
        for (lat, lng, radius_m) in [
            (0.0, 0.0, 5_000.0),
            (12.34, 56.78, 5_000.0),
            (-33.9, 151.2, 50_000.0),
            (70.0, 25.0, 500_000.0),
            (-89.5, 0.0, 100_000.0),
            (10.0, 179.9, 50_000.0),
            (45.0, -120.0, 2_000_000.0),
        ] {
            let point = NearPoint { lat, lng, radius_m };
            let ((lat_lo, lat_hi), (lng_lo, lng_hi)) = proximity_box(&point);
            for step in 0..720 {
                let bearing = f64::from(step) * 0.5;
                let (p_lat, p_lng) = destination(lat, lng, bearing, radius_m);
                assert!(
                    (lat_lo..=lat_hi).contains(&p_lat) && (lng_lo..=lng_hi).contains(&p_lng),
                    "{lat},{lng},{radius_m}m bearing {bearing}: ({p_lat}, {p_lng}) outside \
                     lat {lat_lo}..{lat_hi} lng {lng_lo}..{lng_hi}"
                );
            }
        }
    }

    #[test]
    fn proximity_box_bounds_longitude_away_from_poles_and_antimeridian() {
        let ((lat_lo, lat_hi), (lng_lo, lng_hi)) = proximity_box(&NearPoint {
            lat: 12.34,
            lng: 56.78,
            radius_m: 5_000.0,
        });
        assert!(lat_hi - lat_lo < 0.1 && lng_hi - lng_lo < 0.1);
        for point in [
            NearPoint {
                lat: -89.5,
                lng: 0.0,
                radius_m: 100_000.0,
            },
            NearPoint {
                lat: 10.0,
                lng: 179.9,
                radius_m: 50_000.0,
            },
        ] {
            assert_eq!(proximity_box(&point).1, (-180.0, 180.0), "{point:?}");
        }
    }
}
