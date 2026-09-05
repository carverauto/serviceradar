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
    assert!(
        lower.contains("coalesce(di.ip_addresses, array[]::text[]) &&"),
        "expected ip_addresses to use overlap semantics, got: {sql}"
    );
    assert!(
        !lower.contains("@>"),
        "ip_addresses should not require contains-all semantics, got: {sql}"
    );
    assert!(
        lower.contains("order by di.timestamp asc, di.device_id asc, di.interface_uid asc"),
        "expected page-forming order before metrics joins, got: {sql}"
    );
    assert!(
        lower
            .contains("order by paged.timestamp asc, paged.device_id asc, paged.interface_uid asc"),
        "expected final order after metrics joins, got: {sql}"
    );
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
fn addon_fleet_example_category_reason_and_freshness() {
    let query = "in:addon_fleet category:action_required reason_code:unsupported_platform evidence_age_seconds:<180 sort:agent_uid:asc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::AddonFleet));
    let (sql, params) =
        addon_fleet::to_sql_and_params(&plan).expect("should build addon_fleet SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("from platform.addon_fleet as fleet"),
        "expected query against addon_fleet view, got: {sql}"
    );
    assert!(
        lower.contains("fleet.category = $1")
            && lower.contains("fleet.reason_code = $2")
            && lower.contains("fleet.evidence_age_seconds < $3"),
        "expected category, reason, and freshness filters, got: {sql}"
    );
    assert!(
        lower.contains("order by fleet.agent_uid asc"),
        "expected agent ordering, got: {sql}"
    );
    assert_eq!(params.len(), 5);
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
    // 5 filter binds (device_uid, name, package_manager, current, cpes) + limit + offset.
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
    let query = "in:endpoint_inventory_status device_id:device-alpha current:true freshness:fresh package_set_hash:sha256:abc sort:last_scan_at:desc";
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
            && lower.contains("\"endpoint_inventory_scans\".\"last_successful_scan_at\" > now() - interval '26 hours'"),
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
        lower.contains("order by \"ocsf_events\".\"time\" desc, \"ocsf_events\".\"id\" asc"),
        "expected stable time desc ordering, got: {sql}"
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
    // A canonical `sr:` uid leads with the anchored, index-served equality on the
    // canonical device-key paths (the fast path) AND keeps the inventory-alias
    // EXISTS so historical raw-keyed / alias-keyed findings still resolve. Only the
    // leading-wildcard multi-column ::text ILIKE over the events table is dropped.
    assert!(
        lower.contains("metadata #>> '{service_radar,device_uid}' = 'sr:device-1'")
            && lower.contains("device ->> 'uid' = 'sr:device-1'"),
        "expected source_device_uid filter to anchor on the canonical device key, got: {sql}"
    );
    assert!(
        lower.contains("from platform.ocsf_devices as d"),
        "canonical sr: lookup must keep the inventory-alias EXISTS so alias-keyed events resolve, got: {sql}"
    );
    // The dropped leading-wildcard multi-column ::text ILIKE bakes the lookup value
    // directly into an `%"key"%"value"%` pattern; the kept alias-EXISTS instead
    // interpolates `device_alias.alias_value`. So the value never appears inside an
    // ILIKE pattern for a canonical uid.
    assert!(
        !lower.contains("sr:device-1\"%"),
        "canonical sr: lookup should drop the leading-wildcard events ::text ILIKE, got: {sql}"
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
            && lower.contains("metadata #>> '{detection_finding,type}' = 'anomaly'")
            && lower.contains("capacity_forecast"),
        "expected anomaly/capacity summary payload, got: {sql}"
    );
    assert!(
        lower.contains("and not ((metadata ->> 'event_type' = 'capacity_forecast'"),
        "expected anomaly counts to exclude capacity forecast rows, got: {sql}"
    );
    assert!(
        !lower.contains("metadata #>> '{service_radar,ocsf_class}' = 'detection_finding'"),
        "generic OCSF detection_finding metadata must not count capacity rows as anomalies, got: {sql}"
    );
    assert_eq!(params.len(), 2);
}

#[test]
fn events_rollup_stats_anomaly_findings_scopes_severity_counts_to_anomalies() {
    let query = "in:events time:last_24h rollup_stats:anomaly_findings";
    let plan = plan_for(query);

    let (sql, _) = events::to_sql_and_params(&plan).expect("should build events rollup SQL");
    let lower = sql.to_lowercase();

    // The class_uid/category_uid gate is now hoisted to a leading top-level AND so
    // the planner can use idx_ocsf_events_class_category_time; the severity FILTERs
    // scope to the anomaly *source* clause over that already-narrowed partition.
    assert!(
        lower.contains("where \"class_uid\" = 2004 and \"category_uid\" = 2 and (("),
        "expected class/category gate hoisted to a leading WHERE term, got: {sql}"
    );
    assert!(
        lower.contains("'critical', coalesce(count(*) filter (where (")
            && lower.contains("and coalesce(severity_id, 0) >= 5"),
        "expected critical severity count to be scoped to anomaly findings, got: {sql}"
    );
    assert!(
        lower.contains("'high', coalesce(count(*) filter (where (")
            && lower.contains("and coalesce(severity_id, 0) = 4"),
        "expected high severity count to be scoped to anomaly findings, got: {sql}"
    );
}

#[test]
fn events_finding_rollup_filter_matches_anomaly_rollup_predicate() {
    let query = "in:events finding_rollup:anomaly time:last_24h sort:time:desc";
    let plan = plan_for(query);

    let (sql, params) =
        events::to_sql_and_params(&plan).expect("should build anomaly finding filter SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 2004")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 2")
            && lower.contains("anomaly_detection")
            && lower.contains("metadata #>> '{detection_finding,type}' = 'anomaly'")
            && lower.contains("and not ((metadata ->> 'event_type' = 'capacity_forecast'"),
        "expected anomaly finding filter to mirror rollup anomaly predicate, got: {sql}"
    );
    assert_eq!(params.len(), 4);
}

#[test]
fn events_finding_rollup_filter_matches_capacity_at_risk_rollup_predicate() {
    let query = "in:events finding_rollup:capacity_at_risk time:last_24h sort:time:desc";
    let plan = plan_for(query);

    let (sql, params) =
        events::to_sql_and_params(&plan).expect("should build capacity finding filter SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 2004")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 2")
            && lower.contains("metadata ->> 'event_type' = 'capacity_forecast'")
            && lower.contains("unmapped #>> '{capacity_forecast,status}' in")
            && lower.contains("projected_exhaustion_at"),
        "expected capacity finding filter to mirror rollup at-risk predicate, got: {sql}"
    );
    assert_eq!(params.len(), 4);
}

#[test]
fn events_finding_rollup_filter_matches_health_rollup_predicate() {
    let query = "in:events finding_rollup:health time:last_24h sort:time:desc";
    let plan = plan_for(query);

    let (sql, params) =
        events::to_sql_and_params(&plan).expect("should build health finding filter SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("\"ocsf_events\".\"class_uid\" = 2004")
            && lower.contains("\"ocsf_events\".\"category_uid\" = 2")
            && lower.contains("anomaly_detection")
            && lower.contains("metadata ->> 'event_type' = 'capacity_forecast'")
            && lower.contains("projected_exhaustion_at"),
        "expected health finding filter to combine anomaly and at-risk capacity predicates, got: {sql}"
    );
    assert_eq!(params.len(), 4);
}

#[test]
fn events_count_stats_builds_filtered_count_without_page_limit() {
    let query = r#"in:events class_uid:2004 source_type:anomaly_detection service_radar_device_uid:"sr:device-1" time:last_7d status:(active,open,anomaly_open,inactive,cleared,resolved) stats:"count() as total" limit:5"#;
    let plan = plan_for(query);

    let (sql, params) = events::to_sql_and_params(&plan).expect("should build events count SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.starts_with("select count(*) from"),
        "expected count query, got: {sql}"
    );
    assert!(
        lower.contains("source_type")
            && lower.contains("service_radar")
            && lower.contains("status")
            && lower.contains("class_uid"),
        "expected event filters to be preserved, got: {sql}"
    );
    assert!(
        !lower.contains("limit"),
        "count query must ignore page limit, got: {sql}"
    );
    assert!(
        !lower.contains("order by"),
        "count query must ignore event ordering, got: {sql}"
    );
    assert_eq!(params.len(), 4);
}

#[test]
fn events_stats_rejects_unsupported_aggregations() {
    let query = r#"in:events time:last_7d stats:"sum(severity_id) as severity_sum""#;
    let plan = plan_for(query);

    let err = events::to_sql_and_params(&plan).expect_err("unsupported events stats should fail");

    assert!(
        err.to_string()
            .contains("events stats only support count() as total"),
        "unexpected error: {err}"
    );
}

#[test]
fn events_event_type_filter_matches_metadata_and_unmapped_contracts() {
    let query = "in:events event_type:(anomaly,anomaly_detection) time:last_24h sort:time:desc";
    let plan = plan_for(query);

    let (sql, params) = events::to_sql_and_params(&plan).expect("should build event type SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("metadata ->> 'event_type' = 'anomaly'")
            && lower.contains("metadata #>> '{service_radar,event_type}' = 'anomaly_detection'")
            && lower.contains("unmapped ->> 'event_type' = 'anomaly_detection'"),
        "expected event_type filter to match metadata and unmapped event type paths, got: {sql}"
    );
    assert!(params.len() >= 2);
}

#[test]
fn events_agent_and_host_filters_match_exact_identity_paths() {
    let agent_plan =
        plan_for(r#"in:events agent_id:"agent-sr-test-pve04" event_type:anomaly limit:25"#);
    let host_plan = plan_for(r#"in:events host_id:"sr-test-pve04" event_type:anomaly limit:25"#);
    let device_plan =
        plan_for(r#"in:events device_uid_exact:"sr:device-1" event_type:anomaly limit:25"#);
    let indexed_device_plan =
        plan_for(r#"in:events service_radar_device_uid:"sr:device-1" event_type:anomaly limit:25"#);

    let (agent_sql, _) = events::to_sql_and_params(&agent_plan).expect("agent filter SQL");
    let (host_sql, _) = events::to_sql_and_params(&host_plan).expect("host filter SQL");
    let (device_sql, _) = events::to_sql_and_params(&device_plan).expect("device filter SQL");
    let (indexed_device_sql, _) =
        events::to_sql_and_params(&indexed_device_plan).expect("indexed device filter SQL");

    assert!(
        agent_sql.contains("metadata #>> '{service_radar,agent_id}' = 'agent-sr-test-pve04'")
            && agent_sql
                .contains("metadata #>> '{service_radar,device_uid}' = 'agent-sr-test-pve04'"),
        "expected agent_id filter to match agent and legacy device uid paths, got: {agent_sql}"
    );
    assert!(
        host_sql.contains("metadata #>> '{service_radar,device_hostname}' = 'sr-test-pve04'")
            && host_sql.contains("metadata #>> '{service_radar,device_uid}' = 'sr-test-pve04'"),
        "expected host_id filter to match host and legacy device uid paths, got: {host_sql}"
    );
    assert!(
        device_sql.contains("metadata #>> '{service_radar,device_uid}' = 'sr:device-1'")
            && !device_sql.contains("EXISTS ("),
        "expected device_uid_exact filter to avoid inventory alias fallback, got: {device_sql}"
    );
    assert!(
        indexed_device_sql.contains("metadata #>> '{service_radar,device_uid}' = 'sr:device-1'")
            && !indexed_device_sql.contains("device ->> 'uid'")
            && !indexed_device_sql.contains("unmapped ->> 'device_uid'")
            && !indexed_device_sql.contains("EXISTS ("),
        "expected service_radar_device_uid filter to stay on the indexed service_radar device path, got: {indexed_device_sql}"
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
    // Canonical `sr:` uid: anchored, index-served equality on the canonical key,
    // scoped to the scan-activity class, plus the inventory-alias EXISTS so
    // alias-keyed / historical scan rows still resolve. Only the leading-wildcard
    // multi-column events ::text ILIKE is dropped for canonical uids.
    assert!(
        lower.contains("metadata #>> '{service_radar,device_uid}' = 'sr:device-1'")
            && lower.contains("device ->> 'uid' = 'sr:device-1'")
            && lower.contains("\"ocsf_events\".\"class_uid\" = 6007"),
        "expected scan_activity device filter to anchor on the canonical device key, got: {sql}"
    );
    assert!(
        lower.contains("from platform.ocsf_devices as d"),
        "canonical sr: lookup must keep the inventory-alias EXISTS so alias-keyed events resolve, got: {sql}"
    );
    assert!(
        !lower.contains("sr:device-1\"%"),
        "canonical sr: lookup should drop the leading-wildcard events ::text ILIKE, got: {sql}"
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

#[test]
fn composite_results_joins_the_check_for_slug_access() {
    let query = "in:composite_results check:pci-isolation limit:25";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::CompositeResults));
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build composite results SQL");
    let lower = sql.to_lowercase();

    // This entity defines its own FromClause, so unlike the device filter it
    // joins rather than correlating.
    assert!(
        lower.contains("inner join"),
        "expected a join onto composite_checks, got: {sql}"
    );
    assert!(
        lower.contains("composite_checks"),
        "expected the checks table, got: {sql}"
    );
    assert!(
        lower.contains("\"composite_checks\".\"slug\" = "),
        "expected the slug filter, got: {sql}"
    );
}

#[test]
fn composite_results_filters_by_verdict_and_status() {
    let plan = plan_for("in:composite_results verdict:not_isolated status:down");
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build filtered SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("\"device_composite_check_results\".\"verdict\" = "),
        "expected verdict filter, got: {sql}"
    );
    assert!(
        lower.contains("\"device_composite_check_results\".\"status\" = "),
        "expected status filter, got: {sql}"
    );
}

#[test]
fn composite_results_defaults_to_most_recently_evaluated_first() {
    let plan = plan_for("in:composite_results check:pci-isolation");
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build default order SQL");

    assert!(
        sql.to_lowercase()
            .contains("order by \"device_composite_check_results\".\"evaluated_at\" desc"),
        "expected evaluated_at desc default ordering, got: {sql}"
    );
}

#[test]
fn composite_results_aliases_the_joined_check_columns() {
    // Three consumers read this row and two of them key by column name: the
    // Elixir SRQL runner reads whatever Postgres returns, and the viz metadata
    // declares check_slug/check_name. Selecting composite_checks.slug bare gives
    // the Elixir path a `slug` key while the Rust path serializes `check_slug`
    // from the struct -- the same query returning two shapes.
    let plan = plan_for("in:composite_results check:pci-isolation");
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build composite results SQL");

    assert!(
        sql.contains("AS check_slug"),
        "expected the slug column to be aliased, got: {sql}"
    );
    assert!(
        sql.contains("AS check_name"),
        "expected the name column to be aliased, got: {sql}"
    );
}

#[test]
fn composite_results_rejects_an_unsupported_filter_field() {
    let plan = plan_for("in:composite_results hostname:anything");
    assert!(
        composite_results::to_sql_and_params(&plan).is_err(),
        "composite results should not accept device fields"
    );
}

#[test]
fn composite_results_stats_groups_by_check_and_verdict() {
    // Unquoted stats tokens cannot contain spaces. Comma-separated group
    // fields are `by check,verdict`; quote the expression to write them
    // with spaces (`stats:"count() as n by check, verdict"`).
    let plan = plan_for("in:composite_results stats:count() as n by check,verdict");
    let (sql, params) =
        composite_results::to_sql_and_params(&plan).expect("should build composite results stats");
    let lower = sql.to_lowercase();

    assert!(lower.contains("group by"), "expected GROUP BY, got: {sql}");
    assert!(
        lower.contains("jsonb_build_object"),
        "expected jsonb_build_object payload, got: {sql}"
    );
    assert!(
        sql.contains("'check'") && sql.contains("composite_checks.slug"),
        "expected check to alias composite_checks.slug, got: {sql}"
    );
    assert!(
        !lower.contains("as check_slug"),
        "stats payload must use the 'check' key, not check_slug, got: {sql}"
    );
    assert!(
        !lower.contains("device_uid"),
        "stats query must not select row columns, got: {sql}"
    );
    assert!(
        params.is_empty(),
        "unfiltered stats should have no binds, got {params:?}"
    );
}

#[test]
fn composite_results_stats_filter_then_group() {
    let plan = plan_for("in:composite_results check:pci-isolation stats:count() as n by verdict");
    let (sql, params) =
        composite_results::to_sql_and_params(&plan).expect("should build filtered stats");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("composite_checks.slug = $1") || lower.contains("composite_checks.slug = ?"),
        "expected slug filter bind, got: {sql}"
    );
    assert_eq!(params.len(), 1);
    assert!(
        lower.contains("group by device_composite_check_results.verdict"),
        "expected group by verdict, got: {sql}"
    );
}

#[test]
fn composite_results_stats_unnests_inputs_for_vantage_rollups() {
    let plan = plan_for(
        r#"in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value, input_stale""#,
    );
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build vantage stats");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("jsonb_each"),
        "expected jsonb_each unnest, got: {sql}"
    );
    assert!(
        lower.contains("input.key") && lower.contains("input.value->>'value'"),
        "expected input key/value projections, got: {sql}"
    );
    assert!(
        lower.contains("input_stale") || sql.contains("'input_stale'"),
        "expected input_stale in the payload, got: {sql}"
    );
}

#[test]
fn composite_results_stats_without_by_counts_the_matching_set() {
    let plan = plan_for("in:composite_results check:pci-isolation stats:count() as n");
    let (sql, _params) =
        composite_results::to_sql_and_params(&plan).expect("should build ungrouped count");
    let lower = sql.to_lowercase();

    assert!(
        !lower.contains("group by"),
        "ungrouped count must not GROUP BY, got: {sql}"
    );
    assert!(
        sql.contains("'n'"),
        "expected alias n in the payload, got: {sql}"
    );
}

#[test]
fn composite_results_stats_rejects_unsupported_group_field() {
    let plan = plan_for("in:composite_results stats:count() as n by hostname");
    let err = composite_results::to_sql_and_params(&plan)
        .expect_err("hostname is not a composite_results stats group field");
    assert!(
        err.to_string().contains("hostname"),
        "error should name the field, got: {err}"
    );
}

#[test]
fn composite_results_stats_rejects_unsupported_aggregation() {
    let plan = plan_for("in:composite_results stats:sum(bytes) as n by verdict");
    let err = composite_results::to_sql_and_params(&plan)
        .expect_err("sum() is not supported on composite_results");
    assert!(
        err.to_string().contains("count()"),
        "error should say only count() is supported, got: {err}"
    );
}

#[test]
fn sweep_groups_example_partition_and_enabled() {
    let query = "in:sweep_groups partition:default enabled:true sort:name:asc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepGroups));
    let (sql, _) = sweep_groups::to_sql_and_params(&plan).expect("should build sweep_groups SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_groups\""),
        "expected query against sweep_groups, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_groups\".\"partition\" =")
            && lower.contains("\"sweep_groups\".\"enabled\" ="),
        "expected partition + enabled filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_groups\".\"name\" asc"),
        "expected name asc ordering, got: {sql}"
    );
}

#[test]
fn sweep_profiles_example_name_and_enabled() {
    // `admin_only` is not an accepted caller filter (see the authorization
    // bypass fix in `sweep_profiles::apply_filter`): every query is already
    // unconditionally restricted to `admin_only = false`, asserted below.
    let query = "in:sweep_profiles name:default enabled:true";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepProfiles));
    let (sql, _) =
        sweep_profiles::to_sql_and_params(&plan).expect("should build sweep_profiles SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_profiles\""),
        "expected query against sweep_profiles, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_profiles\".\"name\" =")
            && lower.contains("\"sweep_profiles\".\"enabled\" =")
            && lower.contains("\"sweep_profiles\".\"admin_only\" = false"),
        "expected name + enabled filters and the unconditional admin_only restriction in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_profiles\".\"name\" asc"),
        "expected default name asc ordering, got: {sql}"
    );
}

#[test]
fn sweep_executions_example_status_and_agent() {
    let query = "in:sweep_executions status:success agent_id:agent-01";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepExecutions));
    let (sql, _) =
        sweep_executions::to_sql_and_params(&plan).expect("should build sweep_executions SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_group_executions\""),
        "expected query against sweep_group_executions, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_group_executions\".\"status\" =")
            && lower.contains("\"sweep_group_executions\".\"agent_id\" ="),
        "expected status + agent_id filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_group_executions\".\"started_at\" desc"),
        "expected default started_at desc ordering, got: {sql}"
    );
}

#[test]
fn sweep_results_example_ip_and_status() {
    let query = "in:sweep_results ip:192.0.2.10 status:up";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepResults));
    let (sql, _) = sweep_results::to_sql_and_params(&plan).expect("should build sweep_results SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_host_results\""),
        "expected query against sweep_host_results, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_host_results\".\"ip\" =")
            && lower.contains("\"sweep_host_results\".\"status\" ="),
        "expected ip + status filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_host_results\".\"inserted_at\" desc"),
        "expected default inserted_at desc ordering, got: {sql}"
    );
}

#[test]
fn sweep_coverage_example_device_uid_and_ip() {
    let query = "in:sweep_coverage device_uid:dev-1 ip:192.0.2.10";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepCoverage));
    let (sql, _) =
        sweep_coverage::to_sql_and_params(&plan).expect("should build sweep_coverage SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_coverage_daily\""),
        "expected query against sweep_coverage_daily, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_coverage_daily\".\"device_uid\" =")
            && lower.contains("\"sweep_coverage_daily\".\"ip\" ="),
        "expected device_uid + ip filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_coverage_daily\".\"day\" desc"),
        "expected default day desc ordering, got: {sql}"
    );
}

#[test]
fn device_sweep_overlap_example_declared_not_observed() {
    let query = "in:device_sweep_overlap relationship:declared_not_observed limit:10";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::DeviceSweepOverlap));
    let (sql, binds) = device_sweep_overlap::to_sql_and_params(&plan)
        .expect("should build device_sweep_overlap SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from platform.device_sweep_overlap as overlap"),
        "expected query against the view, got: {sql}"
    );
    assert!(
        lower.contains("overlap.relationship = $1"),
        "expected relationship filter as the first bind, got: {sql}"
    );
    // The alert rows carry no last_seen_at, so the default sort surfaces them
    // ahead of recency rather than behind every ordinary row.
    assert!(
        lower.contains(
            "order by (overlap.relationship = 'declared_not_observed') desc, \
             overlap.last_seen_at desc nulls last"
        ),
        "expected alert-first default ordering, got: {sql}"
    );
    assert!(!sql.contains('?'), "no literal '?' should survive rewrite: {sql}");
    // relationship filter, then LIMIT, then OFFSET.
    assert_eq!(binds.len(), 3);
}

#[test]
fn sweep_overlap_alias_resolves_to_device_sweep_overlap() {
    let plan = plan_for("in:sweep_overlap limit:1");
    assert!(matches!(plan.entity, Entity::DeviceSweepOverlap));
}
