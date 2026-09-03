use super::*;

#[test]
fn devices_kev_pivot_uses_actionable_assessments_and_keeps_device_grain() {
    let query = "in:devices kev:true";
    let plan = plan_for(query);
    let (sql, params) = devices::to_sql_and_params(&plan).expect("sql");
    assert!(
        sql.contains("endpoint_vulnerability_assessments"),
        "expected EXISTS against assessments, got {sql}"
    );
    assert!(
        sql.to_lowercase().contains("from \"ocsf_devices\""),
        "device grain must be preserved, got {sql}"
    );
    assert!(
        sql.contains("EXISTS (SELECT 1 FROM endpoint_vulnerability_assessments"),
        "expected EXISTS subquery, got {sql}"
    );
    assert!(sql.contains("a.status = 'active'"));
    assert!(sql.contains("a.assessment = 'confirmed'"));
    assert!(sql.contains("a.disposition = 'affected'"));
    assert!(
        params
            .iter()
            .any(|param| matches!(param, crate::query::BindParam::Bool(true))),
        "kev EXISTS must bind true, got {params:?}"
    );
}

#[test]
fn devices_cve_pivot_binds_uppercase_cve() {
    let query = "in:devices cve:cve-2026-0001";
    let plan = plan_for(query);
    let (sql, params) = devices::to_sql_and_params(&plan).expect("sql");
    assert!(sql.contains("a.cve_id"));
    assert!(
        params.iter().any(|param| matches!(param, crate::query::BindParam::TextArray(values) if values == &["CVE-2026-0001".to_string()])),
        "CVE must be bound uppercased, got {params:?}"
    );
}

#[test]
fn devices_docs_example_available_true() {
    let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.limit, 20);
    assert_eq!(plan.offset, 0);
    assert!(plan.time_range.is_some());
    assert_eq!(plan.order.len(), 1);
    assert_eq!(plan.order[0].field, "last_seen");
    assert!(matches!(plan.order[0].direction, OrderDirection::Desc));
    assert!(has_availability_filter(&plan, true));

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
    assert!(
        sql.to_lowercase()
            .contains("\"ocsf_devices\".\"is_available\" = $3"),
        "expected SQL to include availability predicate, got: {sql}"
    );
}

#[test]
fn devices_docs_example_available_false() {
    let query = "in:devices time:last_7d sort:last_seen:desc limit:20 is_available:false";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.limit, 20);
    assert!(plan.time_range.is_some());
    assert!(has_availability_filter(&plan, false));

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build SQL for docs query");
    assert!(
        sql.to_lowercase()
            .contains("\"ocsf_devices\".\"is_available\" = $3"),
        "expected SQL to include availability predicate, got: {sql}"
    );
}

#[test]
fn devices_docs_example_discovery_sources_matches_any_source() {
    let query = "in:devices discovery_sources:(sweep,armis) time:last_7d sort:last_seen:desc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert_eq!(plan.order[0].field, "last_seen");
    let range = plan
        .time_range
        .as_ref()
        .expect("docs example includes explicit time window");
    let span = range.end.signed_duration_since(range.start);
    assert_eq!(span, ChronoDuration::days(7));

    let discovery_filters: Vec<_> = plan
        .filters
        .iter()
        .filter(|filter| filter.field == "discovery_sources")
        .collect();
    assert_eq!(
        discovery_filters.len(),
        1,
        "expected one discovery_sources filter"
    );
    assert!(
        matches!(&discovery_filters[0].value, FilterValue::List(values) if values == &vec!["sweep".to_string(), "armis".to_string()])
    );

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("coalesce(discovery_sources, ARRAY[]::text[]) &&"),
        "expected discovery_sources overlap filter, got: {sql}"
    );
    assert!(
        !sql.contains("@>"),
        "discovery_sources should not require contains-all semantics, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["sweep".to_string(), "armis".to_string()])),
        "expected sweep/armis text-array bind param, got: {params:?}"
    );
}

#[test]
fn devices_external_inventory_source_and_metadata_filters_are_bound() {
    let query = r#"in:devices discovery_sources:(example-inventory) metadata.source_instance:"example-prod" metadata.site:IAD"#;
    let plan = plan_for(query);

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build external inventory device query");

    assert!(sql.contains("coalesce(discovery_sources, ARRAY[]::text[]) &&"));
    assert!(sql.contains("metadata"));
    assert!(sql.contains("source_instance"));
    assert!(sql.contains("site"));
    assert!(params.iter().any(
        |param| matches!(param, BindParam::TextArray(values) if values == &vec!["example-inventory".to_string()])
    ));
    assert!(params
        .iter()
        .any(|param| matches!(param, BindParam::Text(value) if value == "example-prod")));
    assert!(params
        .iter()
        .any(|param| matches!(param, BindParam::Text(value) if value == "IAD")));
}

#[test]
fn devices_discovery_sources_negation_builds_negative_array_filter() {
    let query = "in:devices !discovery_sources:(armis)";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert!(plan.filters.iter().any(|filter| {
            filter.field == "discovery_sources"
                && matches!(filter.op, FilterOp::NotIn)
                && matches!(&filter.value, FilterValue::List(values) if values == &vec!["armis".to_string()])
        }));

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("NOT (coalesce(discovery_sources, ARRAY[]::text[]) &&"),
        "expected SQL to negate discovery_sources overlap, got: {sql}"
    );
    assert!(
            params
                .iter()
                .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["armis".to_string()])),
            "expected an armis text-array bind param, got: {params:?}"
        );
}

#[test]
fn devices_awx_managed_true_builds_metadata_predicate() {
    let query = "in:devices awx_managed:true";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert!(plan
        .filters
        .iter()
        .any(|filter| filter.field == "awx_managed" && matches!(filter.op, FilterOp::Eq)));

    // to_sql_and_params reconciles diesel bind count against collected params, so
    // a successful build proves the derived predicate contributes zero binds.
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("metadata -> 'awx' ->> 'host_id' IS NOT NULL")
            && sql.contains("metadata -> 'awx' ->> 'controller_id' IS NOT NULL")
            && sql.contains(
                "COALESCE(discovery_sources, ARRAY[]::text[]) && ARRAY['awx', 'ansible']"
            ),
        "expected awx_managed metadata predicate, got: {sql}"
    );
    assert!(
        !sql.contains("NOT (metadata -> 'awx'"),
        "awx_managed:true should not negate the predicate, got: {sql}"
    );
}

#[test]
fn devices_awx_managed_false_negates_predicate() {
    let query = "in:devices awx_managed:false";
    let plan = plan_for(query);

    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("NOT (") && sql.contains("metadata -> 'awx' ->> 'host_id' IS NOT NULL"),
        "expected awx_managed:false to negate the metadata predicate, got: {sql}"
    );
}

#[test]
fn devices_awx_managed_negation_operator_matches_false() {
    // `!awx_managed:true` should be equivalent to `awx_managed:false`.
    let plan = plan_for("in:devices !awx_managed:true");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    assert!(
        sql.contains("NOT (") && sql.contains("metadata -> 'awx' ->> 'host_id' IS NOT NULL"),
        "expected !awx_managed:true to negate the metadata predicate, got: {sql}"
    );
}

#[test]
fn devices_stats_awx_managed_uses_metadata_predicate() {
    let query = "in:devices awx_managed:true stats:count() as total by type limit:10";
    let plan = plan_for(query);

    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("metadata -> 'awx' ->> 'host_id' is not null"),
        "expected grouped stats awx_managed predicate, got: {sql}"
    );
}

#[test]
fn devices_stats_discovery_sources_uses_overlap() {
    let query =
        "in:devices discovery_sources:(sweep,armis) stats:count() as total by type limit:10";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("coalesce(discovery_sources, array[]::text[]) &&"),
        "expected grouped stats discovery_sources overlap filter, got: {sql}"
    );
    assert!(
        !lower.contains("@>"),
        "grouped stats discovery_sources should not require contains-all semantics, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["sweep".to_string(), "armis".to_string()])),
        "expected sweep/armis text-array bind param, got: {params:?}"
    );
}

#[test]
fn devices_negative_uid_filter_keeps_null_population_in_rows_and_stats() {
    let row_plan = plan_for("in:devices !uid:sr:device-1");
    let (row_sql, row_params) =
        devices::to_sql_and_params(&row_plan).expect("should build devices SQL");
    let row_lower = row_sql.to_lowercase();

    assert!(
        row_lower.contains("\"ocsf_devices\".\"uid\" is null"),
        "negative row filter should keep NULL uid rows, got: {row_sql}"
    );
    assert!(
        row_lower.contains("\"ocsf_devices\".\"uid\" != $1"),
        "negative row filter should still exclude matching uid rows, got: {row_sql}"
    );
    assert!(
        matches!(row_params.first(), Some(BindParam::Text(value)) if value == "sr:device-1"),
        "expected uid bind param, got: {row_params:?}"
    );

    let stats_plan =
        plan_for("in:devices !uid:sr:device-1 stats:count() as total by type limit:10");
    let (stats_sql, stats_params) =
        devices::to_sql_and_params(&stats_plan).expect("should build grouped stats SQL");
    let stats_lower = stats_sql.to_lowercase();

    assert!(
        stats_lower.contains("(uid is null or uid <> $1)"),
        "negative stats filter should keep NULL uid rows, got: {stats_sql}"
    );
    assert!(
        matches!(stats_params.first(), Some(BindParam::Text(value)) if value == "sr:device-1"),
        "expected stats uid bind param, got: {stats_params:?}"
    );
}

#[test]
fn devices_not_like_filter_keeps_null_population_in_rows_and_stats() {
    let row_plan = plan_for("in:devices !hostname:%edge%");
    let (row_sql, row_params) =
        devices::to_sql_and_params(&row_plan).expect("should build devices SQL");
    let row_lower = row_sql.to_lowercase();

    assert!(
        row_lower.contains("\"ocsf_devices\".\"hostname\" is null"),
        "negative row filter should keep NULL hostname rows, got: {row_sql}"
    );
    assert!(
        row_lower.contains("\"ocsf_devices\".\"hostname\" not ilike $1"),
        "negative row filter should still exclude matching hostname rows, got: {row_sql}"
    );
    assert!(
        matches!(row_params.first(), Some(BindParam::Text(value)) if value == "%edge%"),
        "expected hostname bind param, got: {row_params:?}"
    );

    let stats_plan =
        plan_for("in:devices !hostname:%edge% stats:count() as total by type limit:10");
    let (stats_sql, stats_params) =
        devices::to_sql_and_params(&stats_plan).expect("should build grouped stats SQL");
    let stats_lower = stats_sql.to_lowercase();

    assert!(
        stats_lower.contains("(hostname is null or hostname not ilike $1)"),
        "negative stats filter should keep NULL hostname rows, got: {stats_sql}"
    );
    assert!(
        matches!(stats_params.first(), Some(BindParam::Text(value)) if value == "%edge%"),
        "expected stats hostname bind param, got: {stats_params:?}"
    );
}

#[test]
fn devices_default_order_uses_safe_ip_cast() {
    let query = "in:devices";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(\"ocsf_devices\".\"is_active\", true) = true"),
        "expected default active-device predicate, got: {sql}"
    );
    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        !lower.contains("try_inet(nullif(ip, ''))"),
        "expected default device ordering to tolerate malformed IP strings, got: {sql}"
    );
    assert!(
        !lower.contains("nullif(ip, '')::inet"),
        "default device ordering should not cast malformed IP strings directly, got: {sql}"
    );
}

#[test]
fn devices_include_inactive_suppresses_default_active_filter() {
    let query = "in:devices include_inactive:true";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        !lower.contains("coalesce(\"ocsf_devices\".\"is_active\", true) = true"),
        "include_inactive:true should not add default active predicate, got: {sql}"
    );
    assert!(
        params
            .iter()
            .all(|param| !matches!(param, BindParam::Bool(_))),
        "include_inactive is a control token and should not bind a bool param, got: {params:?}"
    );
}

#[test]
fn devices_ip_cidr_filter_generates_inet_clause() {
    let query = "in:devices ip:10.0.0.0/8";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        lower.contains("<<="),
        "expected CIDR inet containment, got: {sql}"
    );

    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.0/8") }));
}

#[test]
fn devices_ip_range_filter_generates_range_clause() {
    let query = "in:devices ip:10.0.0.10-10.0.0.50";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        lower.contains(">= $1::inet") && lower.contains("<= $2::inet"),
        "expected IP range inet comparison, got: {sql}"
    );

    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.10") }));
    assert!(params
        .iter()
        .any(|param| { matches!(param, BindParam::Text(value) if value == "10.0.0.50") }));
}

#[test]
fn devices_vendor_filter_default_order_uses_safe_ip_cast() {
    let query = r#"in:devices vendor_name:"Axis Communications""#;
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(lower.contains("vendor_name"));
    assert!(lower.contains("split_part(ip, ',', 1)"));
    assert!(lower.contains("pg_input_is_valid"));
    assert!(
        !lower.contains("nullif(ip, '')::inet"),
        "default device ordering must not cast raw comma-separated ip values: {sql}"
    );
}

#[test]
fn devices_stats_group_by_type() {
    let query = "in:devices stats:count() as count by type";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    assert!(plan.stats.is_some());

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("group by"),
        "expected GROUP BY in SQL, got: {sql}"
    );
    assert!(
        lower.contains("jsonb_build_object"),
        "expected jsonb_build_object in SQL, got: {sql}"
    );
    assert!(
        lower.contains("device_type") || lower.contains("type"),
        "expected type column in SQL, got: {sql}"
    );
    assert!(
        lower.contains("count(*)"),
        "expected COUNT(*) in SQL, got: {sql}"
    );
    assert!(
        params.is_empty(),
        "grouped stats without filters should have no params"
    );
}

#[test]
fn devices_inventory_summary_rollup_returns_all_type_and_vendor_buckets() {
    let query = "in:devices rollup_stats:inventory_summary";
    let plan = plan_for(query);

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build inventory summary SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("device_inventory_type_counts"),
        "expected type rollup table in SQL, got: {sql}"
    );
    assert!(
        lower.contains("device_inventory_vendor_counts"),
        "expected vendor rollup table in SQL, got: {sql}"
    );
    assert!(
        !lower.contains("limit 10"),
        "inventory summary should not truncate facet buckets, got: {sql}"
    );
    assert!(params.is_empty(), "rollup summary should not bind params");
}

#[test]
fn devices_type_like_filter_uses_normalized_ilike() {
    let query = "in:devices include_inactive:true type:%rids% sort:last_seen:desc limit:100";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(\"ocsf_devices\".\"type\"), ''), 'unknown') ilike $1"),
        "expected normalized type ILIKE in SQL, got: {sql}"
    );
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "%rids%"),
        "expected %rids% bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_type_like_filter_uses_normalized_ilike() {
    let query = r#"in:devices type:%rids% stats:"count() as count by type""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(type), ''), 'unknown') ilike $1"),
        "expected normalized type ILIKE in grouped SQL, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one type filter param");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "%rids%"),
        "expected %rids% bind, got: {params:?}"
    );
}

#[test]
fn devices_partition_filter_uses_partition_column() {
    let query = "in:devices partition:rids sort:hostname:asc limit:500";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("\"ocsf_devices\".\"partition\" = $"),
        "expected partition equality in SQL, got: {sql}"
    );
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "rids"),
        "expected rids partition bind, got: {params:?}"
    );
}

#[test]
fn devices_type_unknown_filter_matches_normalized_type_bucket() {
    let query = r#"in:devices type:"Unknown""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build devices SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(\"ocsf_devices\".\"type\"), ''), 'unknown')"),
        "expected normalized type expression in SQL, got: {sql}"
    );
    assert_eq!(params.len(), 3, "expected type, limit, and offset params");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "Unknown"),
        "expected Unknown type bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_type_filter_uses_normalized_type_column() {
    let query = r#"in:devices type:"Unknown" stats:"count() as count by type""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(type), ''), 'unknown') = $1"),
        "expected normalized type filter in grouped SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by coalesce(nullif(trim(type), ''), 'unknown')"),
        "expected grouped stats to use normalized type bucket, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one type filter param");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "Unknown"),
        "expected Unknown type bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_supports_metadata_like_filter() {
    let query =
        r#"in:devices metadata.armis_tags:%development% stats:"count() as count by is_available""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("metadata->>'armis_tags' ilike $1"),
        "expected metadata JSONB filter in grouped SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by coalesce(is_available, false)"),
        "expected availability grouping, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one metadata filter param");
    assert!(
        matches!(params.first(), Some(BindParam::Text(value)) if value == "%development%"),
        "expected development LIKE bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_supports_type_list_filter() {
    let query = r#"in:devices type:(Router,Switch) stats:"count() as count by is_available""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("coalesce(nullif(trim(type), ''), 'unknown') = any($1)"),
        "expected normalized type list filter in grouped SQL, got: {sql}"
    );
    assert_eq!(params.len(), 1, "expected one type-list param");
    assert!(
        matches!(params.first(), Some(BindParam::TextArray(values)) if values == &vec!["Router".to_string(), "Switch".to_string()]),
        "expected Router/Switch bind, got: {params:?}"
    );
}

#[test]
fn devices_stats_group_by_vendor() {
    let query = "in:devices stats:count() as count by vendor_name";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));
    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("vendor_name"),
        "expected vendor_name column in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by count(*) desc"),
        "expected ORDER BY COUNT(*) DESC in SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_vendor_and_type_for_pivot_tables() {
    let query = "in:devices stats:count() as count by vendor_name,type";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("'vendor_name'") && lower.contains("'type'"),
        "expected both pivot dimensions in payload, got: {sql}"
    );
    assert!(
        lower.contains("group by")
            && lower.contains("coalesce(vendor_name, 'unknown')")
            && lower.contains("coalesce(nullif(trim(type), ''), 'unknown')"),
        "expected GROUP BY for both pivot dimensions, got: {sql}"
    );
    assert!(
        lower.contains("count(*)"),
        "expected COUNT(*) measure in pivot stats SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_availability() {
    let query = "in:devices stats:count() as count by is_available";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("is_available"),
        "expected is_available column in SQL, got: {sql}"
    );
}

#[test]
fn devices_docs_example_active_false() {
    let query = "in:devices is_active:false";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::Devices));

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build SQL for active state query");
    assert!(
        sql.to_lowercase()
            .contains("coalesce(\"ocsf_devices\".\"is_active\", true) = $1"),
        "expected SQL to include active lifecycle predicate, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::Bool(false))),
        "expected false active-state bind param, got: {params:?}"
    );
}

#[test]
fn devices_stats_group_by_active_state() {
    let query = "in:devices stats:count() as count by is_active";
    let plan = plan_for(query);

    let (sql, _) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("coalesce(is_active, true)"),
        "expected active lifecycle column in SQL, got: {sql}"
    );
}

#[test]
fn devices_stats_group_by_with_filter() {
    let query = "in:devices vendor_name:Cisco stats:count() as count by type";
    let plan = plan_for(query);

    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build filtered grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("where") && lower.contains("vendor_name"),
        "expected WHERE clause with vendor_name filter in SQL, got: {sql}"
    );
    assert!(
        lower.contains("group by") && lower.contains("coalesce(nullif(trim(type)"),
        "expected GROUP BY with type column in SQL, got: {sql}"
    );
    assert_eq!(
        params.len(),
        1,
        "should have one param for vendor_name filter"
    );
}

#[test]
fn devices_stats_group_by_unsupported_field_returns_error() {
    let query = "in:devices stats:count() as count by hostname";
    let plan = plan_for(query);

    let result = devices::to_sql_and_params(&plan);
    assert!(result.is_err(), "grouping by hostname should fail");
    let err = result.unwrap_err();
    assert!(
        err.to_string().contains("unsupported"),
        "error should mention unsupported field, got: {err}"
    );
}

// This is the exact query the Device Details "find similar devices" links emit:
// an equality filter on an arbitrary metadata sub-key. It must translate to a
// parameterized `metadata->>'<key>' = $n` predicate with the value bound (never
// concatenated), so it is safe to feed operator-supplied metadata values in.
#[test]
fn devices_supports_metadata_equality_filter() {
    let query = r#"in:devices metadata.proxmox_node:"pve-01""#;
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build metadata SQL");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("metadata->>'proxmox_node' = $"),
        "expected parameterized metadata equality predicate, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|p| matches!(p, BindParam::Text(v) if v == "pve-01")),
        "expected metadata value bound as a parameter, got: {params:?}"
    );
}

// The metadata KEY is interpolated into the SQL fragment (Postgres has no bind
// placeholder for a JSONB key), so it must be whitelisted. A key carrying a SQL
// metacharacter (here a single quote that would otherwise close the `->>'...'`
// string) has to be rejected outright rather than reaching the database.
#[test]
fn devices_rejects_unsafe_metadata_key() {
    let plan = plan_for(r#"in:devices metadata.node'or'1:x"#);

    let result = devices::to_sql_and_params(&plan);
    assert!(result.is_err(), "unsafe metadata key must be rejected");
    let err = result.unwrap_err().to_string();
    assert!(
        err.contains("invalid metadata key"),
        "error should flag the invalid metadata key, got: {err}"
    );
}

#[test]
fn devices_stats_groups_by_tag_subkey() {
    let query = "in:devices stats:count() as total by tags.gate limit:100";
    let plan = plan_for(query);

    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("coalesce(tags->>'gate', 'unknown')"),
        "expected group expression over the tags sub-key, got: {sql}"
    );
    assert!(
        lower.contains("group by coalesce(tags->>'gate'"),
        "tag sub-key should appear in GROUP BY, got: {sql}"
    );
    assert!(
        sql.contains("'tags.gate'"),
        "response key should name the full tag path, got: {sql}"
    );
}

// The dashboard case: narrow to one airport, then count devices per gate.
#[test]
fn devices_stats_filters_and_groups_by_different_tags() {
    let query = "in:devices tags.site:ZZA stats:count() as total by tags.gate limit:100";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("tags->>'site' = $"),
        "expected the tags.site filter in the stats path, got: {sql}"
    );
    assert!(
        lower.contains("coalesce(tags->>'gate', 'unknown')"),
        "expected the tags.gate group expression, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::Text(value) if value == "ZZA")),
        "tag value must be bound, not interpolated, got: {params:?}"
    );
}

// `?` is both a bind placeholder in the grouped-stats SQL builder and the
// Postgres JSONB existence operator. If the key-existence check is spelled with
// the operator, `rewrite_placeholders` turns it into a `$n` and the query no
// longer parses -- so this path must use jsonb_exists.
#[test]
fn devices_stats_tag_existence_does_not_collide_with_placeholders() {
    let query = "in:devices tags:gate stats:count() as total by type limit:10";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    assert!(
        sql.contains("jsonb_exists(coalesce(tags, '{}'::jsonb), $"),
        "expected jsonb_exists rather than the ? operator, got: {sql}"
    );
    assert_eq!(
        sql.matches('?').count(),
        0,
        "no raw ? may survive placeholder rewriting, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::Text(value) if value == "gate")),
        "expected the tag key bound as a parameter, got: {params:?}"
    );
}

#[test]
fn devices_tag_subkey_supports_list_form() {
    let query = "in:devices tags.gate:(B40,B41)";
    let plan = plan_for(query);

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build SQL");
    assert!(
        sql.to_lowercase().contains("tags->>'gate' = any("),
        "expected an ANY(...) membership test, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["B40".to_string(), "B41".to_string()])),
        "expected the gate list bound as a text array, got: {params:?}"
    );
}

#[test]
fn devices_negated_tag_subkey_list_keeps_devices_missing_the_tag() {
    let query = "in:devices !tags.gate:(B40,B41)";
    let plan = plan_for(query);

    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("tags->>'gate' is null or not"),
        "a device with no gate tag is 'not in' the list, got: {sql}"
    );
}

// Same whitelist reasoning as the metadata key test above: the tag key is
// interpolated, so an unsafe one must never reach SQL -- via a filter or a
// GROUP BY.
#[test]
fn devices_rejects_unsafe_tag_key() {
    let plan = plan_for(r#"in:devices tags.node'or'1:x"#);
    let result = devices::to_sql_and_params(&plan);
    assert!(result.is_err(), "unsafe tag key must be rejected");
    assert!(
        result.unwrap_err().to_string().contains("invalid tags key"),
        "error should flag the invalid tag key"
    );

    let plan = plan_for(r#"in:devices stats:count() as total by tags.a'b"#);
    let result = devices::to_sql_and_params(&plan);
    assert!(
        result.is_err(),
        "unsafe tag key must be rejected in a group-by too"
    );
}

// JSONB keys are case-sensitive in Postgres and tag ingestion preserves the
// operator's casing, so `tags.Gate` must not be folded to `tags->>'gate'` --
// in a filter or in a GROUP BY, and identically in both.
#[test]
fn devices_preserves_tag_key_casing() {
    let plan = plan_for("in:devices tags.Gate:B40");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build SQL");
    assert!(
        sql.contains("tags->>'Gate'"),
        "filter must probe the key as written, got: {sql}"
    );

    let plan = plan_for("in:devices stats:count() as total by tags.Gate");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    assert!(
        sql.contains("tags->>'Gate'"),
        "group-by must probe the key as written, got: {sql}"
    );

    // The namespace itself stays case-insensitive.
    let plan = plan_for("in:devices TAGS.Gate:B40");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build SQL");
    assert!(
        sql.contains("tags->>'Gate'"),
        "namespace should fold while the key does not, got: {sql}"
    );
}

// os.* / hw_info.* share apply_jsonb_text_filter with tags.*, so the row filter
// and its separate bind-param collector must accept the same operator set.
#[test]
fn devices_fixed_jsonb_fields_support_list_form() {
    let plan = plan_for("in:devices os.name:(Linux,Windows)");
    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build SQL");
    assert!(
        sql.to_lowercase().contains("os->>'name' = any("),
        "expected an ANY(...) membership test, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["Linux".to_string(), "Windows".to_string()])),
        "expected the os.name list bound as a text array, got: {params:?}"
    );
}

#[test]
fn devices_grouped_stats_fixed_jsonb_filters_match_row_query_operators() {
    let plan =
        plan_for("in:devices os.name:(Linux,Windows) stats:count() as total by type limit:10");
    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("grouped stats should accept the list filter");

    assert!(
        sql.to_lowercase().contains("os->>'name' = any("),
        "expected grouped stats to use JSONB list membership, got: {sql}"
    );
    assert!(
        params
            .iter()
            .any(|param| matches!(param, BindParam::TextArray(values) if values == &vec!["Linux".to_string(), "Windows".to_string()])),
        "expected the grouped query to bind the OS list as a text array, got: {params:?}"
    );
}

#[test]
fn devices_tag_wildcards_generate_like_clauses() {
    for (query, expected) in [
        ("in:devices tags.Role:%edge%", "tags->>'Role' ILIKE"),
        ("in:devices !tags.Role:%edge%", "tags->>'Role' NOT ILIKE"),
    ] {
        let plan = plan_for(query);
        let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build SQL");
        assert!(
            sql.contains(expected),
            "expected `{expected}` for `{query}`, got: {sql}"
        );
    }
}

#[test]
fn devices_jsonb_group_sort_keeps_sub_key_casing() {
    for (sort_field, expected_key, unexpected_key) in
        [("tags.Gate", "Gate", "gate"), ("tags.gate", "gate", "Gate")]
    {
        let plan = plan_for(&format!(
            "in:devices stats:count() as total by tags.Gate,tags.gate sort:{sort_field}:asc"
        ));
        let (sql, _params) =
            devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
        let order = sql
            .split("ORDER BY ")
            .nth(1)
            .expect("grouped SQL should include ORDER BY")
            .split("\nLIMIT")
            .next()
            .expect("ORDER BY should precede LIMIT");

        assert!(
            order.contains(&format!("tags->>'{expected_key}'")),
            "sort:{sort_field} selected the wrong JSONB expression: {order}"
        );
        assert!(
            !order.contains(&format!("tags->>'{unexpected_key}'")),
            "sort:{sort_field} must not fold onto a different key: {order}"
        );
    }
}

// The grouped-stats builder emits `?`; Postgres wants `$n`. Translation always
// rewrote, execution did not -- so a *filtered* grouped query was a syntax
// error in production while these tests passed. Both paths now share the
// rewrite, and no raw `?` may survive on either.
#[test]
fn devices_grouped_stats_sql_never_leaks_a_raw_placeholder() {
    for query in [
        "in:devices vendor_name:Cisco stats:count() as total by type limit:10",
        "in:devices tags.site:ZZA stats:count() as total by tags.gate limit:100",
        "in:devices hostname:%core% stats:count() as total by is_available limit:10",
    ] {
        let plan = plan_for(query);
        let (sql, params) =
            devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
        assert_eq!(
            sql.matches('?').count(),
            0,
            "raw ? survived rewriting for `{query}`, got: {sql}"
        );
        assert!(
            sql.contains("$1"),
            "expected a rewritten $n placeholder for `{query}`, got: {sql}"
        );
        assert!(
            !params.is_empty(),
            "expected bind params for `{query}`, got none"
        );
    }
}

#[test]
fn devices_grouped_stats_apply_the_documented_limits() {
    let plan = plan_for("in:devices stats:count() as total by type");
    assert_eq!(plan.limit, 20, "grouped stats default to twenty groups");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    assert!(sql.contains("LIMIT 20"), "unexpected default limit: {sql}");

    let plan = plan_for("in:devices stats:count() as total by type limit:101");
    assert_eq!(plan.limit, 100, "grouped stats cap explicit limits at 100");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build grouped stats SQL");
    assert!(sql.contains("LIMIT 100"), "unexpected capped limit: {sql}");

    let plan = plan_for("in:devices stats:count() as by");
    assert_eq!(
        plan.limit, 100,
        "an ungrouped query whose alias is `by` must retain the global default"
    );
}

#[test]
fn devices_first_seen_relative_window_filters_first_seen_time() {
    let query = "in:devices first_seen:last_7d sort:first_seen:desc limit:20";
    let plan = plan_for(query);

    assert!(plan.time_range.is_none(), "first_seen must not reuse time:");
    assert!(plan
        .filters
        .iter()
        .any(|filter| filter.field == "first_seen" && matches!(filter.op, FilterOp::Eq)));
    assert_eq!(plan.order[0].field, "first_seen");

    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build first_seen SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("\"first_seen_time\" >= $1") && lower.contains("\"first_seen_time\" <= $2"),
        "expected first_seen_time window, got: {sql}"
    );
    assert!(
        !lower.contains("\"last_seen_time\" >=") && !lower.contains("\"last_seen_time\" <="),
        "first_seen must not filter last_seen_time, got: {sql}"
    );

    let timestamps: Vec<_> = params
        .iter()
        .filter_map(|param| match param {
            BindParam::Timestamptz(value) => Some(value.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        timestamps.len(),
        2,
        "expected start/end first_seen binds, got: {params:?}"
    );

    let start = chrono::DateTime::parse_from_rfc3339(timestamps[0])
        .expect("start bind should be rfc3339")
        .with_timezone(&chrono::Utc);
    let end = chrono::DateTime::parse_from_rfc3339(timestamps[1])
        .expect("end bind should be rfc3339")
        .with_timezone(&chrono::Utc);
    assert_eq!(end.signed_duration_since(start), ChronoDuration::days(7));
}

#[test]
fn devices_first_seen_time_alias_matches_first_seen() {
    let plan = plan_for("in:devices first_seen_time:last_30d");
    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build first_seen_time SQL");
    assert!(
        sql.to_lowercase().contains("first_seen_time"),
        "expected first_seen_time window, got: {sql}"
    );
    let timestamps = params
        .iter()
        .filter(|param| matches!(param, BindParam::Timestamptz(_)))
        .count();
    assert_eq!(
        timestamps, 2,
        "expected two first_seen binds, got: {params:?}"
    );
}

#[test]
fn devices_stats_first_seen_filters_grouped_query() {
    let plan = plan_for("in:devices first_seen:last_7d stats:count() as total by type limit:10");
    let (sql, params) =
        devices::to_sql_and_params(&plan).expect("should build grouped first_seen SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("first_seen_time >= $") && lower.contains("first_seen_time <= $"),
        "expected grouped stats first_seen window, got: {sql}"
    );
    assert!(
        params
            .iter()
            .filter(|param| matches!(param, BindParam::Timestamptz(_)))
            .count()
            >= 2,
        "expected first_seen timestamp binds, got: {params:?}"
    );
}

#[test]
fn devices_first_seen_rejects_comparison_operators() {
    let plan = plan_for("in:devices first_seen:>=last_7d");
    let err =
        devices::to_sql_and_params(&plan).expect_err("comparison ops are not first_seen windows");
    assert!(
        err.to_string().contains("first_seen"),
        "expected first_seen operator error, got: {err}"
    );
}

#[test]
fn composite_verdict_filter_compiles_to_a_correlated_exists() {
    let plan = plan_for("in:devices composite.pci-isolation:not_isolated");
    let (sql, _params) =
        devices::to_sql_and_params(&plan).expect("should build composite filter SQL");

    assert!(sql.contains("EXISTS"), "expected EXISTS, got: {sql}");
    assert!(
        sql.contains("device_composite_check_results"),
        "expected the results table, got: {sql}"
    );
    assert!(
        sql.contains("composite_checks"),
        "expected the checks table, got: {sql}"
    );
    assert!(
        sql.contains("r.device_uid = ocsf_devices.uid"),
        "expected the correlation predicate, got: {sql}"
    );
    // DeviceQuery is boxed over ocsf_devices alone; a join on the outer query
    // would change its type across the module.
    assert!(
        !sql.contains("JOIN device_composite_check_results"),
        "composite results must be correlated, not joined onto the device query: {sql}"
    );
}

#[test]
fn composite_verdict_filter_binds_slug_then_values() {
    let plan = plan_for("in:devices composite.pci-isolation:not_isolated");
    let (_sql, params) =
        devices::to_sql_and_params(&plan).expect("should build composite filter SQL");

    // apply_filter binds the slug then the value array; collect_filter_params
    // must push them in the same order. A drift here fails at query time rather
    // than at compile time, so the positions are asserted explicitly. The
    // trailing binds are the standard limit/offset.
    assert!(
        matches!(&params[0], BindParam::Text(slug) if slug == "pci-isolation"),
        "first bind must be the slug, got: {params:?}"
    );
    assert!(
        matches!(&params[1], BindParam::TextArray(values) if values == &["not_isolated"]),
        "second bind must be the value array, got: {params:?}"
    );
}

#[test]
fn composite_status_filter_targets_the_status_column() {
    let plan = plan_for("in:devices composite.pci-isolation.status:degraded");
    let (sql, _params) = devices::to_sql_and_params(&plan).expect("should build status filter SQL");

    assert!(sql.contains("r.status"), "expected r.status, got: {sql}");
    assert!(
        !sql.contains("r.verdict"),
        "status filter must not compare the verdict column: {sql}"
    );
}

#[test]
fn composite_verdict_filter_supports_lists() {
    let plan = plan_for("in:devices composite.pci-isolation:(not_isolated,inverted_reachability)");
    let (sql, params) = devices::to_sql_and_params(&plan).expect("should build list filter SQL");

    assert!(sql.contains("ANY("), "expected ANY(), got: {sql}");
    assert!(
        matches!(
            &params[1],
            BindParam::TextArray(values)
                if values == &["not_isolated", "inverted_reachability"]
        ),
        "a list must bind as one array, not one param per value: {params:?}"
    );
}

#[test]
fn a_negated_composite_filter_compiles_to_not_exists() {
    let plan = plan_for("in:devices !composite.pci-isolation:not_isolated");
    let (sql, _params) =
        devices::to_sql_and_params(&plan).expect("should build negated composite SQL");

    let lower = sql.to_lowercase();
    assert!(lower.contains("not"), "expected a negation, got: {sql}");
    assert!(lower.contains("exists"), "expected EXISTS, got: {sql}");
    // NOT EXISTS also matches devices with no result row for this check. That is
    // the intended reading of "does not hold that verdict" -- a device outside
    // the check's scope does not hold it either. Changing this is a behaviour
    // change, not a refactor.
}

#[test]
fn a_malformed_composite_field_is_a_query_error() {
    for query in [
        "in:devices composite.:x",
        "in:devices composite.-leading:x",
        "in:devices composite.trailing-:x",
        "in:devices composite.a.b.c:x",
    ] {
        let plan = plan_for(query);
        assert!(
            devices::to_sql_and_params(&plan).is_err(),
            "expected a query error for {query}"
        );
    }
}

#[test]
fn a_mixed_case_composite_field_is_normalized_rather_than_rejected() {
    // normalize_field_name lowercases any field outside the tags/metadata
    // namespaces, and slugs are lowercase by construction, so `composite.PCI`
    // addresses the check slugged `pci` rather than failing.
    let plan = plan_for("in:devices composite.PCI-Isolation:not_isolated");
    let (_sql, params) =
        devices::to_sql_and_params(&plan).expect("mixed case should normalize, not error");

    assert!(
        matches!(&params[0], BindParam::Text(slug) if slug == "pci-isolation"),
        "expected the slug to be lowercased, got: {params:?}"
    );
}
