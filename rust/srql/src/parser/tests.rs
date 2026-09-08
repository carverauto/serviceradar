use super::*;
use crate::error::ServiceError;

#[test]
fn parses_basic_query() {
    let ast = parse("in:devices hostname:%cam% limit:50 sort:last_seen:desc").unwrap();
    assert_eq!(ast.limit, Some(50));
    assert_eq!(ast.order.len(), 1);
    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.entity, Entity::Devices));
    assert!(matches!(ast.filters[0].op, FilterOp::Like));
}

#[test]
fn parses_canonical_mtr_traces_query() {
    let ast = parse("in:mtr_traces time:last_1h sort:time:desc limit:1")
        .expect("mtr_traces is a catalog-advertised SRQL entity");

    assert_eq!(
        serde_json::to_value(&ast.entity).unwrap(),
        serde_json::json!("mtr_traces")
    );
    assert!(ast.time_filter.is_some());
    assert_eq!(ast.order.len(), 1);
    assert_eq!(ast.order[0].field, "time");
    assert!(matches!(ast.order[0].direction, OrderDirection::Desc));
    assert_eq!(ast.limit, Some(1));
}

#[test]
fn parses_lists() {
    let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.filters[0].value, FilterValue::List(_)));
}

#[test]
fn parses_bracket_lists() {
    let ast = parse("in:devices if_index:[1,2]").unwrap();
    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.filters[0].value, FilterValue::List(_)));
    assert!(matches!(ast.filters[0].op, FilterOp::In));
}

#[test]
fn rejects_empty_list_filters() {
    let err = parse("in:logs service:()").unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));

    let err = parse("in:logs service:[]").unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn implicitly_promotes_wildcard_text_filters_to_like() {
    let ast = parse("in:devices hostname:%cam%").unwrap();

    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.filters[0].op, FilterOp::Like));
}

fn assert_implicit_wildcard_filter_is_like(field: &str) {
    // Filter parsing is entity-independent. Use an existing entity here so a
    // missing mtr_traces registration cannot mask a missing text-field rule.
    let query = format!("in:devices {field}:%needle%");
    let ast = parse(&query).unwrap();

    assert_eq!(ast.filters.len(), 1, "{query}");
    assert_eq!(ast.filters[0].field, field, "{query}");
    assert!(matches!(ast.filters[0].op, FilterOp::Like), "{query}");
    assert_eq!(ast.filters[0].value.as_scalar().unwrap(), "%needle%");
}

#[test]
fn implicitly_promotes_mtr_target_ip_wildcards_to_like() {
    assert_implicit_wildcard_filter_is_like("target_ip");
}

#[test]
fn implicitly_promotes_mtr_check_name_wildcards_to_like() {
    assert_implicit_wildcard_filter_is_like("check_name");
}

#[test]
fn implicitly_promotes_mtr_error_wildcards_to_like() {
    assert_implicit_wildcard_filter_is_like("error");
}

#[test]
fn implicitly_promotes_device_type_wildcards_to_like() {
    for query in ["in:devices type:%rids%", "in:devices device_type:%rids%"] {
        let ast = parse(query).unwrap();

        assert_eq!(ast.filters.len(), 1, "{query}");
        assert!(matches!(ast.filters[0].op, FilterOp::Like), "{query}");
        assert_eq!(
            ast.filters[0].value.as_scalar().unwrap(),
            "%rids%",
            "{query}"
        );
    }
}

#[test]
fn implicitly_promotes_supported_device_jsonb_wildcards_to_like() {
    for query in [
        "in:devices os.name:%OS%",
        "in:devices os.version:%17%",
        "in:devices os.type:%network%",
        "in:devices hw_info.serial_number:%ABC%",
        "in:devices hw_info.cpu_type:%arm%",
        "in:devices hw_info.cpu_architecture:%x86%",
        "in:devices switch_port_attachment.switch_hostname:%asw%",
        "in:devices vlan_uid:%56%",
    ] {
        let ast = parse(query).unwrap();

        assert_eq!(ast.filters.len(), 1, "{query}");
        assert!(matches!(ast.filters[0].op, FilterOp::Like), "{query}");
    }
}

#[test]
fn implicitly_promotes_dynamic_jsonb_wildcards_to_like() {
    let ast = parse("in:devices tags.Role:%edge% !metadata.Zone:%legacy%").unwrap();

    assert_eq!(ast.filters.len(), 2);
    assert_eq!(ast.filters[0].field, "tags.Role");
    assert!(matches!(ast.filters[0].op, FilterOp::Like));
    assert_eq!(ast.filters[1].field, "metadata.Zone");
    assert!(matches!(ast.filters[1].op, FilterOp::NotLike));
}

#[test]
fn parses_threat_intel_matches_entity() {
    let ast =
        parse("in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100")
            .unwrap();
    assert!(matches!(
        ast.entity,
        crate::parser::Entity::ThreatIntelMatches
    ));
    assert_eq!(ast.filters[0].field, "source");
    assert_eq!(ast.order[0].field, "evaluated_at");
}

#[test]
fn parses_ioc_matches_alias() {
    let ast = parse("in:ioc_matches ip:198.51.100.10").unwrap();
    assert!(matches!(
        ast.entity,
        crate::parser::Entity::ThreatIntelMatches
    ));
}

#[test]
fn parses_source_fact_disagreement_entity() {
    let ast = parse(
        "in:source_fact_disagreements fact_key:switch_port_attachment status:open sort:last_detected_at:desc",
    )
    .unwrap();
    assert!(matches!(
        ast.entity,
        crate::parser::Entity::SourceFactDisagreements
    ));
    assert_eq!(ast.filters[0].field, "fact_key");
    assert_eq!(ast.filters[1].field, "status");
}

#[test]
fn parses_every_identity_diagnostic_entity_alias() {
    use crate::parser::Entity;

    // Every alias here must ALSO appear in the web-ng SRQL EntityAccess map.
    // `permission_for_query/1` returns :passthrough for entities it does not
    // know, so an alias the parser accepts but the map omits is an ungated
    // entity on the HTTP and MCP paths, failing open and silently.
    let cases: &[(&str, Entity)] = &[
        ("merge_audit", Entity::MergeAudit),
        ("device_merges", Entity::MergeAudit),
        ("merges", Entity::MergeAudit),
        ("device_revival_audit", Entity::DeviceRevivalAudit),
        ("device_revivals", Entity::DeviceRevivalAudit),
        ("revivals", Entity::DeviceRevivalAudit),
        ("device_identifiers", Entity::DeviceIdentifiers),
        ("identifiers", Entity::DeviceIdentifiers),
        ("device_identity", Entity::DeviceIdentifiers),
        (
            "identity_reconciliation_runs",
            Entity::IdentityReconciliationRuns,
        ),
        ("reconciliation_runs", Entity::IdentityReconciliationRuns),
        ("dire_runs", Entity::IdentityReconciliationRuns),
        ("identity_evidence_edges", Entity::IdentityEvidenceEdges),
        ("identity_evidence", Entity::IdentityEvidenceEdges),
        ("evidence_edges", Entity::IdentityEvidenceEdges),
    ];

    for (alias, expected) in cases {
        let ast = parse(&format!("in:{alias} limit:5"))
            .unwrap_or_else(|err| panic!("alias {alias} failed to parse: {err:?}"));
        assert_eq!(
            std::mem::discriminant(&ast.entity),
            std::mem::discriminant(expected),
            "alias {alias} resolved to the wrong entity"
        );
    }
}

#[test]
fn parses_advisory_entity_aliases() {
    let cases = [
        ("vulnerability_advisories", Entity::VulnerabilityAdvisories),
        ("vulnerability_advisory", Entity::VulnerabilityAdvisories),
        ("advisories", Entity::VulnerabilityAdvisories),
        ("cves", Entity::VulnerabilityAdvisories),
        ("advisory_coordinates", Entity::AdvisoryCoordinates),
        ("advisory_cpes", Entity::AdvisoryCoordinates),
        ("cpe_coordinates", Entity::AdvisoryCoordinates),
        (
            "endpoint_vulnerability_assessments",
            Entity::EndpointVulnerabilityAssessments,
        ),
        (
            "endpoint_vulnerability_assessment",
            Entity::EndpointVulnerabilityAssessments,
        ),
        (
            "package_vulnerabilities",
            Entity::EndpointVulnerabilityAssessments,
        ),
        (
            "endpoint_vulnerability_matches",
            Entity::EndpointVulnerabilityAssessments,
        ),
        (
            "vulnerability_matches",
            Entity::EndpointVulnerabilityAssessments,
        ),
        ("cve_matches", Entity::EndpointVulnerabilityAssessments),
        ("advisory_matches", Entity::EndpointVulnerabilityAssessments),
    ];
    for (raw, expected) in cases {
        let ast = parse(&format!("in:{raw} limit:1")).unwrap();
        assert_eq!(ast.entity, expected, "entity alias {raw}");
    }
}

#[test]
fn identity_entities_reject_unknown_aliases() {
    // `identity_merges` and `device_evidence` look plausible and are not real.
    for alias in ["identity_merges", "device_evidence", "revival_audit"] {
        assert!(
            parse(&format!("in:{alias} limit:5")).is_err(),
            "{alias} must not parse"
        );
    }
}

#[test]
fn parses_merge_audit_chain_and_evidence_seed_tokens() {
    let ast = parse("in:merge_audit chain:sr:aaa depth:8").unwrap();
    assert!(matches!(ast.entity, crate::parser::Entity::MergeAudit));
    assert_eq!(ast.filters[0].field, "chain");
    assert_eq!(ast.filters[1].field, "depth");

    let ast = parse("in:identity_evidence_edges device:sr:bbb").unwrap();
    assert!(matches!(
        ast.entity,
        crate::parser::Entity::IdentityEvidenceEdges
    ));
    assert_eq!(ast.filters[0].field, "device");
}

#[test]
fn promotes_vulnerability_assessment_text_wildcards_to_like() {
    for field in [
        "device_uid",
        "device_id",
        "agent_id",
        "cve",
        "cve_id",
        "advisory_id",
        "provider",
        "feed_key",
        "status",
        "assessment",
        "disposition",
        "authority",
        "applicability_reason",
        "freshness",
        "source_scope",
        "package_identity_key",
        "package_type",
        "package_manager",
        "ecosystem",
        "package_namespace",
        "namespace",
        "package_release",
        "release",
        "distro",
        "package_name",
        "name",
        "package_version",
        "installed_version",
        "version",
        "package_purl",
        "purl",
        "purl_canonical",
        "source_package",
        "source_version",
        "binary_package",
        "architecture",
        "version_scheme",
        "fixed_version",
        "severity",
        "coordinate_type",
        "coordinate_value",
        "cpe",
        "cpes",
        "confidence",
        "due_date",
        "ransomware_use",
    ] {
        let query = format!("in:endpoint_vulnerability_assessments {field}:%needle%");
        let ast = parse(&query).unwrap();

        assert!(
            matches!(ast.filters[0].op, FilterOp::Like),
            "{field} must preserve contains/wildcard semantics: {query}"
        );
    }

    let ast = parse("in:endpoint_vulnerability_assessments !package_name:%needle%").unwrap();
    assert!(matches!(ast.filters[0].op, FilterOp::NotLike));
}

#[test]
fn rejects_cpes_as_an_advisory_entity_alias() {
    let err = parse("in:cpes limit:1").unwrap_err();
    assert!(
        matches!(err, ServiceError::InvalidRequest(ref message) if message.contains("unsupported entity")),
        "in:cpes must not alias advisory coordinates, got {err:?}"
    );
}

#[test]
fn preserves_dynamic_jsonb_key_casing_in_sort_fields() {
    let ast = parse("in:devices stats:count() as total by tags.Gate,tags.gate sort:tags.gate:asc")
        .unwrap();

    assert_eq!(ast.order.len(), 1);
    assert_eq!(ast.order[0].field, "tags.gate");

    let ast = parse("in:devices stats:count() as total by tags.Gate,tags.gate sort:tags.Gate:asc")
        .unwrap();
    assert_eq!(ast.order[0].field, "tags.Gate");
}

#[test]
fn implicitly_promotes_flow_ip_wildcards_to_like() {
    for query in [
        "in:flows src_ip:%34.98.126.%",
        "in:flows src_endpoint_ip:%34.98.126.%",
        "in:flows dst_ip:%34.98.126.%",
        "in:flows dst_endpoint_ip:%34.98.126.%",
    ] {
        let ast = parse(query).unwrap();

        assert_eq!(ast.filters.len(), 1, "{query}");
        assert!(matches!(ast.filters[0].op, FilterOp::Like), "{query}");
    }

    for query in [
        "in:flows !src_ip:%34.98.126.%",
        "in:flows !dst_ip:%34.98.126.%",
    ] {
        let ast = parse(query).unwrap();

        assert_eq!(ast.filters.len(), 1, "{query}");
        assert!(matches!(ast.filters[0].op, FilterOp::NotLike), "{query}");
    }
}

// A wildcard-free IP must stay an equality match so it keeps hitting the
// `ocsf_network_activity` src/dst indexes instead of degrading to an ILIKE scan.
#[test]
fn keeps_wildcard_free_flow_ip_filters_as_equality() {
    for query in [
        "in:flows src_ip:34.98.126.170",
        "in:flows dst_endpoint_ip:34.98.126.170",
    ] {
        let ast = parse(query).unwrap();

        assert_eq!(ast.filters.len(), 1, "{query}");
        assert!(matches!(ast.filters[0].op, FilterOp::Eq), "{query}");
    }
}

#[test]
fn does_not_implicitly_promote_exact_filters_to_like() {
    let ast = parse("in:interfaces if_index:%1%").unwrap();

    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.filters[0].op, FilterOp::Eq));

    let ast = parse("in:interfaces !if_index:%1%").unwrap();
    assert_eq!(ast.filters.len(), 1);
    assert!(matches!(ast.filters[0].op, FilterOp::NotEq));
}

#[test]
fn parses_time() {
    let ast = parse("in:devices time:last_7d").unwrap();
    assert!(ast.time_filter.is_some());
}

#[test]
fn rejects_multibyte_bucket_suffix_without_panic() {
    let err = parse("in:timeseries_metrics time:last_1h bucket:5µ agg:avg").unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn parses_device_graph_entity() {
    let ast = parse("in:device_graph device_id:sr:device-1").unwrap();
    assert!(matches!(ast.entity, Entity::DeviceGraph));
}

#[test]
fn parses_wifi_map_entities() {
    let cases = [
        ("wifi_sites", Entity::WifiSites),
        ("wifi_site_map", Entity::WifiSites),
        ("wifi_site_snapshots", Entity::WifiSiteSnapshots),
        ("wifi_aps", Entity::WifiAccessPoints),
        ("wifi_access_points", Entity::WifiAccessPoints),
        ("wifi_wlcs", Entity::WifiControllers),
        ("wifi_controllers", Entity::WifiControllers),
        ("wifi_radius_groups", Entity::WifiRadiusGroups),
        ("wifi_fleet_history", Entity::WifiFleetHistory),
        ("wifi_site_references", Entity::WifiSiteReferences),
        ("wifi_airport_references", Entity::WifiSiteReferences),
    ];

    for (raw, expected) in cases {
        let ast = parse(&format!("in:{raw} limit:1")).unwrap();
        assert_eq!(ast.entity, expected, "entity alias {raw}");
    }
}

#[test]
fn parses_virtualization_entities() {
    let cases = [
        ("virtualization_clusters", Entity::VirtualizationClusters),
        ("hypervisors", Entity::VirtualizationHosts),
        ("virtualization_guests", Entity::VirtualizationGuests),
        ("vms", Entity::VirtualizationGuests),
        (
            "virtualization_datastores",
            Entity::VirtualizationDatastores,
        ),
        ("virtualization_disks", Entity::VirtualizationHostDisks),
        (
            "virtualization_nics",
            Entity::VirtualizationNetworkInterfaces,
        ),
        (
            "virtualization_storage_systems",
            Entity::VirtualizationStorageSystems,
        ),
        ("ceph", Entity::VirtualizationStorageSystems),
    ];

    for (raw, expected) in cases {
        let ast = parse(&format!("in:{raw} provider:proxmox limit:1")).unwrap();
        assert_eq!(ast.entity, expected, "entity alias {raw}");
    }
}

#[test]
fn parses_dashboard_entity_aliases() {
    for raw in ["dashboards", "dashboard", "authored_dashboards"] {
        let ast = parse(&format!("in:{raw} status:active limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::Dashboards, "entity alias {raw}");
    }
}

#[test]
fn parses_endpoint_inventory_scan_entity_aliases() {
    for raw in [
        "endpoint_inventory_scans",
        "endpoint_inventory_status",
        "endpoint_inventory_freshness",
    ] {
        let ast = parse(&format!("in:{raw} freshness:fresh limit:10")).unwrap();
        assert_eq!(
            ast.entity,
            Entity::EndpointInventoryScans,
            "entity alias {raw}"
        );
    }
}

#[test]
fn parses_sweep_groups_aliases() {
    for alias in ["sweep_groups", "sweep_group", "sweeps"] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::SweepGroups),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_sweep_profiles_aliases() {
    for alias in [
        "sweep_profiles",
        "sweep_profile",
        "scanner_profiles",
        "scanner_profile",
    ] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::SweepProfiles),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_sweep_executions_aliases() {
    for alias in [
        "sweep_executions",
        "sweep_execution",
        "sweep_group_executions",
    ] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::SweepExecutions),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_sweep_results_aliases() {
    for alias in ["sweep_results", "sweep_result", "sweep_host_results"] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::SweepResults),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_sweep_coverage_aliases() {
    for alias in ["sweep_coverage", "sweep_coverage_daily"] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::SweepCoverage),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_device_sweep_overlap_aliases() {
    for alias in ["device_sweep_overlap", "sweep_overlap"] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(
            matches!(ast.entity, Entity::DeviceSweepOverlap),
            "alias {alias} failed"
        );
    }
}

#[test]
fn parses_security_signal_entity_aliases() {
    for raw in [
        "security_findings",
        "security_finding",
        "findings",
        "finding",
    ] {
        let ast = parse(&format!("in:{raw} severity:High limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::SecurityFindings, "entity alias {raw}");
    }

    for raw in [
        "scan_activity",
        "scan_activities",
        "security_scans",
        "scanner_activity",
    ] {
        let ast = parse(&format!("in:{raw} status:Success limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::ScanActivity, "entity alias {raw}");
    }

    for raw in [
        "dns_activity",
        "dns_activities",
        "dns_security_activity",
        "powerdns",
        "pdns",
    ] {
        let ast = parse(&format!("in:{raw} status:Success limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::DnsActivity, "entity alias {raw}");
    }
}

#[test]
fn parses_capacity_forecast_entity_aliases() {
    for raw in [
        "capacity_forecasts",
        "capacity_forecast",
        "forecasts",
        "forecast",
    ] {
        let ast = parse(&format!("in:{raw} status:projected limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::CapacityForecasts, "entity alias {raw}");
    }
}

#[test]
fn parses_composite_results_entity_aliases() {
    for raw in [
        "composite_results",
        "composite_check_results",
        "composite_verdicts",
    ] {
        let ast = parse(&format!("in:{raw} check:pci-isolation limit:10")).unwrap();
        assert_eq!(ast.entity, Entity::CompositeResults, "entity alias {raw}");
    }
}

#[test]
fn parses_dashboard_service_view_entities() {
    let cases = [
        ("service_availability", Entity::ServiceAvailability),
        ("monitored_services", Entity::MonitoredServices),
        ("service_inventory", Entity::MonitoredServices),
        ("slo_evaluations", Entity::SloEvaluations),
        ("service_slos", Entity::SloEvaluations),
    ];

    for (raw, expected) in cases {
        let ast = parse(&format!("in:{raw} status:ok limit:10")).unwrap();
        assert_eq!(ast.entity, expected, "entity alias {raw}");
    }
}

#[test]
fn parses_list_values() {
    let ast = parse("in:devices discovery_sources:(sweep,armis)").unwrap();
    assert_eq!(ast.filters.len(), 1);
    match &ast.filters[0].value {
        FilterValue::List(items) => {
            assert_eq!(items.len(), 2);
            assert_eq!(items[0], "sweep");
            assert_eq!(items[1], "armis");
        }
        _ => panic!("expected list value"),
    }
}

#[test]
fn parses_stats_expression() {
    let ast = parse("in:logs stats:\"count() as total\" time:last_24h").unwrap();
    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(stats.raw, "count() as total");
    assert_eq!(stats.aggregations.len(), 1);
    assert!(matches!(
        stats.aggregations[0].agg_type,
        StatsAggType::Count
    ));
    assert_eq!(stats.aggregations[0].alias, "total");
}

#[test]
fn parses_unquoted_stats_alias() {
    let ast = parse("in:devices stats:count() as total").unwrap();
    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(stats.raw, "count() as total");
    assert_eq!(stats.aggregations.len(), 1);
    assert!(matches!(
        stats.aggregations[0].agg_type,
        StatsAggType::Count
    ));
}

#[test]
fn parses_unquoted_stats_alias_with_following_tokens() {
    let ast = parse("in:devices stats:count() as total time:last_7d").unwrap();
    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(stats.raw, "count() as total");
    assert!(ast.time_filter.is_some());
}

#[test]
fn parses_stats_with_field() {
    let ast = parse("in:devices stats:\"sum(value) as total_value\"").unwrap();
    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(stats.aggregations.len(), 1);
    assert!(matches!(stats.aggregations[0].agg_type, StatsAggType::Sum));
    assert_eq!(stats.aggregations[0].field.as_deref(), Some("value"));
    assert_eq!(stats.aggregations[0].alias, "total_value");
}

#[test]
fn parses_multiple_stats() {
    let ast = parse("in:devices stats:\"count() as total, sum(value) as sum_val\"").unwrap();
    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(stats.aggregations.len(), 2);
    assert!(matches!(
        stats.aggregations[0].agg_type,
        StatsAggType::Count
    ));
    assert!(matches!(stats.aggregations[1].agg_type, StatsAggType::Sum));
}

#[test]
fn parses_repeated_stats_tokens_by_merging_aggregations() {
    let ast = parse(
        "in:flows stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by src_endpoint_ip",
    )
    .unwrap();

    let stats = ast.stats.as_ref().unwrap();
    assert_eq!(
        stats.raw,
        "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by src_endpoint_ip"
    );
    assert_eq!(stats.aggregations.len(), 2);
    assert_eq!(stats.aggregations[0].alias, "bytes_total");
    assert_eq!(stats.aggregations[1].alias, "packets_total");
}

#[test]
fn parses_other_rollup_flag() {
    let ast = parse(
        "in:flows stats:sum(bytes_total) as bytes_total by src_endpoint_ip sort:bytes_total:desc limit:10 other:true",
    )
    .unwrap();

    assert!(ast.other);
}

#[test]
fn rejects_invalid_other_rollup_flag() {
    let err = parse("in:flows stats:count() as total by src_endpoint_ip other:maybe").unwrap_err();

    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn rejects_repeated_stats_tokens_with_conflicting_group_by() {
    let err = parse(
        "in:flows stats:sum(bytes_total) as bytes_total by src_endpoint_ip stats:sum(packets_total) as packets_total by dst_endpoint_ip",
    )
    .unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn rejects_stats_alias_missing_identifier() {
    let err = parse("in:devices stats:count() as").unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn parses_interfaces_entity() {
    let ast = parse("in:interfaces time:last_24h").unwrap();
    assert!(matches!(ast.entity, Entity::Interfaces));
}

#[test]
fn parses_bmp_events_entity() {
    let ast = parse("in:bmp_events router_ip:10.42.68.85 time:last_24h").unwrap();
    assert!(matches!(ast.entity, Entity::BmpEvents));
    assert_eq!(ast.filters.len(), 1);
    assert_eq!(ast.filters[0].field, "router_ip");
}

#[test]
fn rejects_overly_long_stats_expression() {
    let query = format!(
        "in:logs stats:{}",
        "x".repeat(super::stats::MAX_STATS_EXPR_LEN + 1)
    );
    let err = parse(&query).unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn rejects_list_filters_over_limit() {
    let values = (0..=super::filters::MAX_FILTER_LIST_VALUES)
        .map(|i| format!("value{i}"))
        .collect::<Vec<_>>()
        .join(",");
    let query = format!("in:logs service:({values})");
    let err = parse(&query).unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn parses_rollup_stats_keyword() {
    let ast = parse("in:logs time:last_24h rollup_stats:severity").unwrap();
    assert!(matches!(ast.entity, Entity::Logs));
    assert_eq!(ast.rollup_stats.as_deref(), Some("severity"));
    assert!(ast.time_filter.is_some());
}

#[test]
fn parses_rollup_stats_with_filters() {
    let ast = parse("in:logs service_name:core time:last_24h rollup_stats:severity").unwrap();
    assert_eq!(ast.rollup_stats.as_deref(), Some("severity"));
    assert_eq!(ast.filters.len(), 1);
    assert_eq!(ast.filters[0].field, "service_name");
}

#[test]
fn rejects_empty_rollup_stats() {
    let err = parse("in:logs rollup_stats:").unwrap_err();
    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}
