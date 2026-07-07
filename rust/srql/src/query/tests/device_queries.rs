use super::*;

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
