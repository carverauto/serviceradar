//! Shared literal normalizers for flow queries (`in:flows` and `in:attributed_flows`
//! compile exclusively through the StarRocks dialect).

pub(super) mod literals {
    use crate::error::{Result, ServiceError};

    /// Normalize and validate a CIDR string (e.g. `10.0.0.0/8`).
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

    /// Validate a prefix-tag literal for tag containment filters.
    ///
    /// Tags are namespaced strings like `site:austin-dc` or `netbox:tag:iot`.
    pub(in crate::query) fn normalize_tag_literal(raw: &str) -> Result<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err(ServiceError::InvalidRequest("tag literal is empty".into()));
        }
        if trimmed.len() > 128 {
            return Err(ServiceError::InvalidRequest(
                "tag literal exceeds 128 characters".into(),
            ));
        }
        if !trimmed.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, ':' | '-' | '_' | '.' | '/' | '@' | '+')
        }) {
            return Err(ServiceError::InvalidRequest(format!(
                "invalid tag literal: {trimmed}"
            )));
        }
        Ok(trimmed.to_string())
    }

    /// Parsed proximity term: latitude, longitude, radius in meters.
    #[derive(Debug, Clone, Copy, PartialEq)]
    pub(in crate::query) struct NearPoint {
        pub lat: f64,
        pub lng: f64,
        pub radius_m: f64,
    }

    /// Parse `near` filter values like `30.2672,-97.7431,50km` or `30.27,-97.74,5000m`.
    ///
    /// Default unit when omitted is kilometers. Supported suffixes: `km`, `m`, `mi`.
    pub(in crate::query) fn normalize_near_literal(raw: &str) -> Result<NearPoint> {
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

        let value: f64 = num_str.parse().map_err(|_| {
            ServiceError::InvalidRequest(format!("near radius is not a number: {raw}"))
        })?;
        Ok(value * factor)
    }
}

pub(crate) use self::literals::normalize_cidr_literal;

#[cfg(test)]
mod tests {
    #[test]
    fn flow_detail_and_device_filters_compile_for_starrocks() {
        let cases = [
            ("proto", "6", "protocol_num"),
            ("src_ip", "192.0.2.10", "src_endpoint_ip"),
            ("dst_ip", "198.51.100.20", "dst_endpoint_ip"),
            ("src_port", "42000", "src_endpoint_port"),
            ("dst_port", "443", "dst_endpoint_port"),
            ("protocol_num", "6", "protocol_num"),
            ("src_endpoint_ip", "192.0.2.10", "src_endpoint_ip"),
            ("dst_endpoint_ip", "198.51.100.20", "dst_endpoint_ip"),
            ("dst_endpoint_port", "443", "dst_endpoint_port"),
            ("protocol_name", "TCP", "protocol_name"),
            ("protocol_group", "tcp", "protocol_num"),
            ("direction_label", "ingress", "direction_label"),
            ("dst_service_label", "https", "dst_service_label"),
            ("app", "https", "app"),
            ("sampler_address", "192.0.2.1", "sampler_address"),
            ("flow_source", "netflow", "flow_source"),
            ("collector", "netflow", "flow_source"),
            ("event_type", "network_activity", "event_type"),
            ("pid", "42", "pid"),
            ("container_id", "example-container", "container_id"),
            ("agent_id", "agent-example", "agent_id"),
            ("pod_name", "example-pod", "workload_identity"),
            ("pod_namespace", "example", "workload_identity"),
            ("pod_uid", "pod-example", "workload_identity"),
            ("container_name", "example-container", "workload_identity"),
            ("image", "example/image", "workload_identity"),
            ("runtime_source", "example-runtime", "workload_identity"),
            ("service_name", "example-service", "public_endpoint"),
            ("gateway_name", "example-gateway", "public_endpoint"),
            ("exposure_class", "public", "public_endpoint"),
            ("public_endpoint_namespace", "example", "public_endpoint"),
            ("route_name", "example-route", "public_endpoint"),
        ];
        for mode in [Some("starrocks"), Some("starrocks_raw")] {
            for (field, value, column) in cases {
                let response = compile_filter_request(&format!("{field}:\"{value}\""), mode);
                let predicate = response.sql.split_once(" WHERE ").expect("WHERE").1;
                assert!(predicate.contains(column), "{mode:?} {field}: {predicate}");
                assert!(predicate.contains(&format!("'{value}'")), "{predicate}");
            }
            let details = compile_filter_request(
                "src_ip:192.0.2.10 dst_ip:198.51.100.20 src_port:42000 dst_port:443 proto:6",
                mode,
            );
            let predicate = details.sql.split(" WHERE ").nth(1).expect("WHERE");
            for column in [
                "src_endpoint_ip",
                "dst_endpoint_ip",
                "src_endpoint_port",
                "dst_endpoint_port",
                "protocol_num",
            ] {
                assert!(predicate.contains(column), "{mode:?}: {predicate}");
            }
        }
    }

    #[test]
    fn flow_interface_and_process_aliases_compile_for_starrocks() {
        for mode in [Some("starrocks"), Some("starrocks_raw")] {
            for (field, canonical, value) in [
                ("in_if_index", "input_snmp", "7"),
                ("out_if_index", "output_snmp", "9"),
                ("status", "attribution_status", "attributed"),
                ("process_pid", "pid", "42"),
                ("process", "comm", "worker"),
                ("process_name", "comm", "worker"),
                ("redacted_cmdline", "cmdline", "worker"),
                ("namespace", "pod_namespace", "example"),
                ("image_ref", "image", "example/image"),
                ("uid", "device_id", "device-example"),
            ] {
                let alias = compile_filter_request(&format!("{field}:\"{value}\""), mode);
                let canonical = compile_filter_request(&format!("{canonical}:\"{value}\""), mode);
                assert_eq!(alias.sql, canonical.sql, "{mode:?} {field}");
                assert_eq!(
                    serde_json::to_value(alias.params).unwrap(),
                    serde_json::to_value(canonical.params).unwrap(),
                    "{mode:?} {field}"
                );
            }
        }
    }

    #[test]
    fn flow_endpoint_and_catalog_filters_compile_for_starrocks() {
        // StarRocks 4.1 has no JDBC pass-through table function and cannot
        // read PostgreSQL text[], cidr or geography columns, so every catalog
        // filter reads scalar columns of a plain cache or a `_catalog` view.
        let live = "WHERE c.matched AND c.expires_at > UTC_TIMESTAMP()";
        let cache = "cnpg_platform.platform.ip_threat_intel_cache c";
        let sources = "cnpg_platform.platform.ip_threat_intel_sources_catalog c";
        let members = "cnpg_platform.platform.threat_intel_indicator_members_catalog c";
        let indicator_live =
            "AND (c.indicator_expires_at IS NULL OR c.indicator_expires_at > UTC_TIMESTAMP()) AND ";
        let geo = "IN (SELECT g.ip FROM cnpg_platform.platform.ip_geo_enrichment_cache g \
                   WHERE (g.expires_at IS NULL OR g.expires_at > UTC_TIMESTAMP()) \
                   AND g.latitude BETWEEN ";
        let distance = "st_distance_sphere(g.longitude, g.latitude, 56.78, 12.34) <= 5000)";
        let threat_cases = [
            ("threat_matched:true", cache, String::new()),
            ("threat_matched:false", cache, String::new()),
            (
                "threat_source:example_feed",
                sources,
                " AND c.source IN ('example_feed')".to_string(),
            ),
            (
                "threat_source:(example_feed,other_feed)",
                sources,
                " AND c.source IN ('example_feed', 'other_feed')".to_string(),
            ),
            (
                "threat_observed_ip:192.0.2.10",
                cache,
                " AND c.ip = '192.0.2.10'".to_string(),
            ),
            (
                "threat_indicator:198.51.100.0/24",
                members,
                format!(
                    " {indicator_live}c.first_ip_hex = 'c6336400' AND c.last_ip_hex = 'c63364ff'"
                ),
            ),
            (
                "threat_indicator:198.51.100.20",
                members,
                format!(
                    " {indicator_live}c.indicator_family = 4 \
                     AND c.first_ip_hex <= 'c6336414' AND c.last_ip_hex >= 'c6336414'"
                ),
            ),
            (
                "threat_indicator:\"2001:db8::/32\"",
                members,
                format!(
                    " {indicator_live}c.first_ip_hex = '20010db8000000000000000000000000' \
                     AND c.last_ip_hex = '20010db8ffffffffffffffffffffffff'"
                ),
            ),
            (
                "threat_severity:>3",
                cache,
                " AND c.max_severity > 3".to_string(),
            ),
        ];
        for mode in [Some("starrocks"), Some("starrocks_raw")] {
            for (filter, contract) in [
                ("ip:192.0.2.10", "src_endpoint_ip"),
                ("endpoint_ip:198.51.100.20", "dst_endpoint_ip"),
                ("port:443", "src_endpoint_port"),
                ("endpoint_port:443", "dst_endpoint_port"),
                ("cidr:192.0.2.0/24", "dst_ip_hex"),
                ("src_tag:site:example", "src_prefix_tags"),
                ("dst_tag:site:example", "dst_prefix_tags"),
                ("tag:site:example", "src_prefix_tags"),
            ] {
                let response = compile_filter_request(filter, mode);
                let predicate = response.sql.split_once(" WHERE ").expect("WHERE").1;
                assert!(
                    predicate.contains(contract),
                    "{mode:?} {filter}: {predicate}"
                );
            }
            for (filter, relation, condition) in &threat_cases {
                let predicate = compile_predicate(filter, mode);
                assert!(!predicate.contains("TABLE("), "{predicate}");
                let subquery =
                    format!("IN (SELECT c.ip FROM {relation} {live}{condition}), FALSE)");
                for side in ["src_endpoint_ip", "dst_endpoint_ip"] {
                    assert!(
                        predicate.contains(&format!("COALESCE({side} {subquery}")),
                        "{mode:?} {filter}: {predicate}"
                    );
                }
                assert_eq!(
                    predicate.contains("NOT ("),
                    *filter == "threat_matched:false",
                    "{mode:?} {filter}: {predicate}"
                );
            }
            for (filter, sides) in [
                (
                    "near:12.34,56.78,5km",
                    &["src_endpoint_ip", "dst_endpoint_ip"][..],
                ),
                ("src_near:12.34,56.78,5km", &["src_endpoint_ip"][..]),
                ("dst_near:12.34,56.78,5km", &["dst_endpoint_ip"][..]),
                (
                    "!near:12.34,56.78,5km",
                    &["src_endpoint_ip", "dst_endpoint_ip"][..],
                ),
            ] {
                let predicate = compile_predicate(filter, mode);
                assert!(
                    predicate.contains(distance),
                    "{mode:?} {filter}: {predicate}"
                );
                for side in ["src_endpoint_ip", "dst_endpoint_ip"] {
                    assert_eq!(
                        predicate.contains(&format!("COALESCE({side} {geo}")),
                        sides.contains(&side),
                        "{mode:?} {filter}: {predicate}"
                    );
                }
                assert_eq!(
                    predicate.contains("NOT ("),
                    filter.starts_with('!'),
                    "{mode:?} {filter}: {predicate}"
                );
            }
        }
    }

    #[test]
    fn threat_indicator_rejects_values_postgres_would_reject() {
        for filter in [
            "threat_indicator:198.51.100.5/24",
            "threat_indicator:not-an-address",
            "threat_indicator:198.51.100.0/33",
        ] {
            let error = try_compile_filter_request(filter, Some("starrocks"))
                .expect_err("an invalid indicator must be refused");
            assert!(
                matches!(error, crate::error::ServiceError::InvalidRequest(_)),
                "{filter}: {error:?}"
            );
        }
    }

    fn compile_predicate(filter: &str, mode: Option<&str>) -> String {
        let response = compile_filter_request(filter, mode);
        response
            .sql
            .split_once(" WHERE ")
            .expect("WHERE")
            .1
            .to_string()
    }

    #[test]
    fn flow_port_lists_compile_for_starrocks() {
        let series = "bucket:1m agg:sum value_field:bytes_total series:dst_endpoint_port";
        for mode in [Some("starrocks"), Some("starrocks_raw")] {
            for (field, column) in [
                ("src_port", "src_endpoint_port"),
                ("src_endpoint_port", "src_endpoint_port"),
                ("dst_port", "dst_endpoint_port"),
                ("dst_endpoint_port", "dst_endpoint_port"),
            ] {
                for suffix in ["", series] {
                    for negated in [false, true] {
                        let bang = if negated { "!" } else { "" };
                        let filters = format!("{bang}{field}:(443,8443) {suffix}");
                        let response = compile_filter_request(&filters, mode);
                        let predicate = response.sql.split_once("WHERE ").expect("WHERE").1;
                        let op = if negated { "NOT IN" } else { "IN" };
                        assert!(
                            predicate.contains(&format!("{column} {op} (443, 8443)")),
                            "{mode:?} {filters}: {predicate}"
                        );
                        assert_eq!(
                            predicate.contains("NOT IN"),
                            negated,
                            "{mode:?} {filters}: {predicate}"
                        );
                    }
                }
            }
            for suffix in ["", series] {
                let filters = format!("dst_port:(443,https) {suffix}");
                let error = try_compile_filter_request(&filters, mode)
                    .expect_err("a non-integer port list item must be rejected");
                assert!(
                    error.to_string().contains("integer"),
                    "{mode:?} {filters}: {error}"
                );
            }
        }
    }

    fn compile_filter_request(
        filters: &str,
        mode: Option<&str>,
    ) -> crate::query::TranslateResponse {
        try_compile_filter_request(filters, mode)
            .unwrap_or_else(|error| panic!("{mode:?} {filters}: {error}"))
    }

    fn try_compile_filter_request(
        filters: &str,
        mode: Option<&str>,
    ) -> crate::error::Result<crate::query::TranslateResponse> {
        let config = crate::config::AppConfig::embedded("postgres://unused/db".into());
        let request = serde_json::from_value(serde_json::json!({
            "query": format!("in:flows time:[2000-01-01T00:00:00Z,2000-01-02T00:00:00Z] {filters} sort:time:desc limit:5"),
            "mode": mode,
        }))
        .expect("request");
        crate::query::translate_request(&config, request)
    }
}
