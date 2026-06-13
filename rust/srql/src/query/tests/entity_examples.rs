use super::*;

#[test]
fn services_docs_example_service_type_timeframe() {
    let query = r#"in:services service_type:(ssh,sftp) timeFrame:"14 Days" sort:timestamp:desc"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Services));
    let filter = plan
        .filters
        .iter()
        .find(|filter| filter.field == "service_type")
        .expect("query must contain service_type filter");
    assert!(matches!(filter.op, FilterOp::In));
    match &filter.value {
        FilterValue::List(values) => {
            assert_eq!(values, &vec!["ssh".to_string(), "sftp".to_string()]);
        }
        _ => panic!("service_type filter must be a list"),
    }

    let range = plan
        .time_range
        .expect("timeFrame should resolve to a time range");
    let span = range.end.signed_duration_since(range.start);
    assert_eq!(span, ChronoDuration::days(14));

    assert_eq!(plan.order[0].field, "timestamp");
    assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
}

#[test]
fn interfaces_docs_example_ip_addresses_contains_any() {
    let query =
        "in:interfaces time:last_24h ip_addresses:(10.0.0.1,10.0.0.2) sort:timestamp:asc limit:5";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Interfaces));
    assert_eq!(plan.limit, 5);
    let (sql, _) = interfaces::to_sql_and_params(&plan).expect("should build interfaces SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("discovered_interfaces") && lower.contains("ip_addresses"),
        "expected interface query against discovered_interfaces, got: {sql}"
    );
    assert!(lower.contains("order by timestamp asc"));
}

#[test]
fn gateways_docs_example_health_and_status() {
    let query = "in:gateways is_healthy:true status:ready sort:agent_count:desc limit:10";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Gateways));
    assert_eq!(plan.limit, 10);
    assert_eq!(plan.order[0].field, "agent_count");
    let (sql, _) = gateways::to_sql_and_params(&plan).expect("should build gateways SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"gateways\".\"is_healthy\" =")
            && lower.contains("\"gateways\".\"status\" ="),
        "expected bool + status filters in SQL, got: {sql}"
    );
}

#[test]
fn addon_statuses_example_agent_and_state() {
    let query = "in:addon_statuses agent_uid:agent-1 state:unhealthy sort:reported_at:desc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::AddonStatuses));
    let (sql, _) =
        addon_statuses::to_sql_and_params(&plan).expect("should build addon_statuses SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"addon_statuses\""),
        "expected query against addon_statuses, got: {sql}"
    );
    assert!(
        lower.contains("\"addon_statuses\".\"agent_uid\" =")
            && lower.contains("\"addon_statuses\".\"state\" ="),
        "expected agent_uid + state filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"addon_statuses\".\"reported_at\" desc"),
        "expected reported_at desc ordering, got: {sql}"
    );
}

#[test]
fn endpoint_packages_example_name_manager_and_cpe() {
    let query = r#"in:endpoint_packages device_id:device-alpha name:nginx manager:dpkg cpe:"cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*" current:true sort:name:asc"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::EndpointPackages));
    let (sql, params) =
        endpoint_packages::to_sql_and_params(&plan).expect("should build endpoint package SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"endpoint_inventory_packages\""),
        "expected query against endpoint_inventory_packages, got: {sql}"
    );
    assert!(
        lower.contains("\"endpoint_inventory_packages\".\"device_uid\" =")
            && lower.contains("\"endpoint_inventory_packages\".\"name\" =")
            && lower.contains("\"endpoint_inventory_packages\".\"package_manager\" =")
            && lower.contains("\"endpoint_inventory_packages\".\"current\" =")
            && lower.contains("\"endpoint_inventory_packages\".\"cpes\" &&"),
        "expected device/name/manager/current/cpe filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"endpoint_inventory_packages\".\"name\" asc"),
        "expected name asc ordering, got: {sql}"
    );
    assert_eq!(params.len(), 7);
}

#[test]
fn endpoint_package_catalog_example_purl_and_cpe() {
    let query = r#"in:endpoint_package_catalog canonical_purl:pkg:deb/nginx@1.24.0-2ubuntu7 cpe:"cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*" source_scope:host sort:name:asc"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::EndpointPackageCatalog));
    let (sql, params) = endpoint_package_catalog::to_sql_and_params(&plan)
        .expect("should build endpoint package catalog SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"endpoint_packages\""),
        "expected query against endpoint_packages, got: {sql}"
    );
    assert!(
        lower.contains("\"endpoint_packages\".\"purl_canonical\" =")
            && lower.contains("\"endpoint_packages\".\"cpes\" &&")
            && lower.contains("\"endpoint_packages\".\"source_scope\" ="),
        "expected purl/cpe/source_scope filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"endpoint_packages\".\"name\" asc"),
        "expected name asc ordering, got: {sql}"
    );
    assert_eq!(params.len(), 5);
}

#[test]
fn endpoint_inventory_scans_example_freshness_and_hash() {
    let query =
        "in:endpoint_inventory_status device_id:device-alpha current:true freshness:fresh package_set_hash:sha256:abc sort:last_scan_at:desc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::EndpointInventoryScans));
    let (sql, params) = endpoint_inventory_scans::to_sql_and_params(&plan)
        .expect("should build endpoint inventory scan SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"endpoint_inventory_scans\""),
        "expected query against endpoint_inventory_scans, got: {sql}"
    );
    assert!(
        lower.contains("\"endpoint_inventory_scans\".\"device_uid\" =")
            && lower.contains("\"endpoint_inventory_scans\".\"current\" =")
            && lower.contains("\"endpoint_inventory_scans\".\"package_set_hash\" =")
            && lower.contains("\"endpoint_inventory_scans\".\"last_successful_scan_at\" > now() - interval '24 hours'"),
        "expected device/current/hash/freshness filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"endpoint_inventory_scans\".\"last_scan_at\" desc"),
        "expected last_scan_at desc ordering, got: {sql}"
    );
    assert_eq!(params.len(), 5);
}

#[test]
fn security_findings_alias_filters_to_ocsf_findings_category() {
    let query = "in:security_findings severity:High sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SecurityFindings));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build security findings SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"category_uid\" = 2"),
        "expected security_findings to constrain OCSF Findings category, got: {sql}"
    );
    assert!(
        lower.contains("order by \"ocsf_events\".\"time\" desc"),
        "expected time desc ordering, got: {sql}"
    );
}

#[test]
fn security_findings_source_device_uid_matches_service_radar_metadata() {
    let query = r#"in:security_findings source_device_uid:"sr:device-1" sort:time:desc limit:25"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SecurityFindings));
    let (sql, _) =
        events::to_sql_and_params(&plan).expect("should build security findings device SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("service\\_radar.device\\_uid")
            && lower.contains("service\\_radar.device.uid")
            && lower.contains("service\\_radar.device\\_id")
            && lower.contains("from platform.ocsf_devices as d"),
        "expected source_device_uid filter to include service_radar identity metadata, got: {sql}"
    );
}

#[test]
fn security_findings_source_matches_service_radar_source_metadata() {
    let query = "in:security_findings source:bumblebee sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SecurityFindings));
    let (sql, _) =
        events::to_sql_and_params(&plan).expect("should build security findings source SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"category_uid\" = 2")
            && lower.contains("metadata #>> '{service_radar,source_type}'")
            && lower.contains("metadata #>> '{service_radar,addon_id}'")
            && lower.contains("bumblebee"),
        "expected source filter to include service_radar source metadata, got: {sql}"
    );
}

#[test]
fn security_findings_finding_uid_matches_metadata_contract() {
    let query = r#"in:security_findings finding_uid:"finding-1" sort:time:desc limit:25"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SecurityFindings));
    let (sql, _) =
        events::to_sql_and_params(&plan).expect("should build security findings finding SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("metadata #>> '{finding_info,uid}'")
            && lower.contains("metadata #>> '{security_signal,finding_uid}'")
            && lower.contains("metadata #>> '{uid}'")
            && lower.contains("metadata #>> '{event_id}'")
            && lower.contains("finding-1"),
        "expected finding_uid filter to include canonical and legacy finding metadata contracts, got: {sql}"
    );
}

#[test]
fn events_rollup_stats_anomaly_findings_builds_summary_payload() {
    let query = "in:events time:last_24h rollup_stats:anomaly_findings";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Events));
    let (sql, params) = events::to_sql_and_params(&plan).expect("should build events rollup SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("jsonb_build_object")
            && lower.contains("'anomalies'")
            && lower.contains("'at_risk'")
            && lower.contains("anomaly_detection")
            && lower.contains("capacity_forecast"),
        "expected anomaly/capacity summary payload, got: {sql}"
    );
    assert_eq!(params.len(), 2);
}

#[test]
fn events_rollup_stats_anomaly_findings_scopes_severity_counts_to_anomalies() {
    let query = "in:events time:last_24h rollup_stats:anomaly_findings";
    let plan = plan_for(query);

    let (sql, _) = events::to_sql_and_params(&plan).expect("should build events rollup SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("'critical', coalesce(count(*) filter (where (\"class_uid\" = 2004")
            && lower.contains("and coalesce(severity_id, 0) >= 5"),
        "expected critical severity count to be scoped to anomaly findings, got: {sql}"
    );
    assert!(
        lower.contains("'high', coalesce(count(*) filter (where (\"class_uid\" = 2004")
            && lower.contains("and coalesce(severity_id, 0) = 4"),
        "expected high severity count to be scoped to anomaly findings, got: {sql}"
    );
}

#[test]
fn logs_source_device_uid_matches_service_radar_attributes() {
    let query = r#"in:logs source_device_uid:"sr:device-1" time:last_24h sort:timestamp:desc"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Logs));
    let (sql, _) = logs::to_sql_and_params(&plan).expect("should build logs device SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("service\\_radar.device\\_uid")
            && lower.contains("service\\_radar.device.uid")
            && lower.contains("service\\_radar.device\\_id"),
        "expected logs source_device_uid filter to include service_radar identity attributes, got: {sql}"
    );
}

#[test]
fn scan_activity_alias_filters_to_ocsf_scan_activity_class() {
    let query = "in:scan_activity status:Success sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::ScanActivity));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build scan activity SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 6007")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 6"),
        "expected scan_activity to constrain OCSF Scan Activity class/category, got: {sql}"
    );
    assert!(
        lower.contains("order by \"ocsf_events\".\"time\" desc"),
        "expected time desc ordering, got: {sql}"
    );
}

#[test]
fn scan_activity_source_device_uid_matches_service_radar_metadata() {
    let query = r#"in:scan_activity source_device_uid:"sr:device-1" sort:time:desc limit:25"#;
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::ScanActivity));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build scan activity device SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("service\\_radar.device\\_uid")
            && lower.contains("\"ocsf_events\".\"class_uid\" = 6007")
            && lower.contains("from platform.ocsf_devices as d"),
        "expected scan_activity device filter to include service_radar identity metadata, got: {sql}"
    );
}

#[test]
fn scan_activity_source_matches_service_radar_source_metadata() {
    let query = "in:scan_activity source:trivy sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::ScanActivity));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build scan activity source SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 6007")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 6")
            && lower.contains("metadata #>> '{service_radar,source_type}'")
            && lower.contains("trivy"),
        "expected scan_activity source filter to include service_radar source metadata, got: {sql}"
    );
}

#[test]
fn dns_activity_alias_filters_to_ocsf_dns_activity_class() {
    let query = "in:dns_activity status:Success sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::DnsActivity));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build DNS activity SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 4003")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 4"),
        "expected dns_activity to constrain OCSF DNS Activity class/category, got: {sql}"
    );
    assert!(
        lower.contains("order by \"ocsf_events\".\"time\" desc"),
        "expected time desc ordering, got: {sql}"
    );
}

#[test]
fn dns_activity_source_matches_log_provider_or_service_radar_source_metadata() {
    let query = "in:dns_activity source:powerdns sort:time:desc limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::DnsActivity));
    let (sql, _) = events::to_sql_and_params(&plan).expect("should build dns activity source SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 4003")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 4")
            && lower.contains("\"ocsf_events\".\"log_provider\" = 'powerdns'")
            && lower.contains("metadata #>> '{service_radar,source_type}'"),
        "expected dns_activity source filter to include log provider and service_radar source metadata, got: {sql}"
    );
}
