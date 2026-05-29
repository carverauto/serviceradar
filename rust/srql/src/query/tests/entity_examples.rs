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
