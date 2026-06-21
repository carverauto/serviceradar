use super::{
    filters::{build_filter_clause, extract_latest_filter},
    order::build_order_clause,
};
use crate::{
    error::Result,
    query::{BindParam, QueryPlan},
    time::TimeRange,
};

pub(super) struct SqlBuildResult {
    pub(super) sql: String,
    pub(super) binds: Vec<BindParam>,
}

fn interface_select_columns(alias: &str) -> String {
    format!(
        "{alias}.timestamp, {alias}.agent_id, {alias}.gateway_id, {alias}.device_ip, \
        {alias}.device_id, {alias}.interface_uid, {alias}.if_index, {alias}.if_name, \
        {alias}.if_descr, {alias}.if_alias, {alias}.if_type, {alias}.if_type_name, \
        {alias}.interface_kind, {alias}.if_speed, {alias}.speed_bps, {alias}.mtu, \
        {alias}.duplex, {alias}.if_phys_address, {alias}.ip_addresses, \
        {alias}.if_admin_status, {alias}.if_oper_status, {alias}.metadata, \
        {alias}.available_metrics, {alias}.created_at"
    )
}

pub(super) fn interface_settings_join(alias: &str) -> String {
    format!(
        " LEFT JOIN interface_settings ifs ON ifs.device_id = {alias}.device_id AND ifs.interface_uid = {alias}.interface_uid"
    )
}

fn interface_settings_columns(alias: &str) -> String {
    format!("{alias}.favorited, {alias}.metrics_enabled")
}

fn interface_settings_projection() -> &'static str {
    "COALESCE(ifs.favorited, false) AS favorited, COALESCE(ifs.metrics_enabled, false) AS metrics_enabled"
}

fn interface_error_metric_joins(alias: &str) -> String {
    format!(
        " LEFT JOIN LATERAL ( \
          SELECT tm.value \
          FROM timeseries_metrics tm \
          WHERE tm.device_id = {alias}.device_id \
            AND tm.if_index = {alias}.if_index \
            AND tm.metric_name = 'ifInErrors' \
            AND tm.metric_type = 'snmp' \
          ORDER BY tm.timestamp DESC \
          LIMIT 1 \
        ) tm_in ON true \
        LEFT JOIN LATERAL ( \
          SELECT tm.value \
          FROM timeseries_metrics tm \
          WHERE tm.device_id = {alias}.device_id \
            AND tm.if_index = {alias}.if_index \
            AND tm.metric_name = 'ifOutErrors' \
            AND tm.metric_type = 'snmp' \
          ORDER BY tm.timestamp DESC \
          LIMIT 1 \
        ) tm_out ON true"
    )
}

pub(super) fn build_query_sql(plan: &QueryPlan) -> Result<SqlBuildResult> {
    let (latest_only, filters) = extract_latest_filter(&plan.filters)?;
    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "di.timestamp >= ${} AND di.timestamp <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    let mut discovered_interfaces_from = String::from("FROM discovered_interfaces di");
    discovered_interfaces_from.push_str(&interface_settings_join("di"));
    if !clauses.is_empty() {
        discovered_interfaces_from.push_str(" WHERE ");
        discovered_interfaces_from.push_str(&clauses.join(" AND "));
    }

    let (sql, binds) = if latest_only {
        let mut inner = String::from("SELECT DISTINCT ON (di.device_id, di.interface_uid) ");
        inner.push_str(&interface_select_columns("di"));
        inner.push_str(", ");
        inner.push_str(interface_settings_projection());
        inner.push(' ');
        inner.push_str(&discovered_interfaces_from);
        inner.push_str(
            " ORDER BY di.device_id, di.interface_uid, di.timestamp DESC, di.created_at DESC",
        );

        let mut page = String::from("SELECT * FROM (");
        page.push_str(&inner);
        page.push_str(") AS latest");
        if let Some(order_clause) = build_order_clause(&plan.order, false, Some("latest")) {
            page.push(' ');
            page.push_str(&order_clause);
        }
        page.push_str(&format!(" LIMIT ${} OFFSET ${}", bind_idx, bind_idx + 1));

        let mut outer = String::from("SELECT ");
        outer.push_str(&interface_select_columns("paged"));
        outer.push_str(", tm_in.value AS in_errors, tm_out.value AS out_errors, ");
        outer.push_str(&interface_settings_columns("paged"));
        outer.push_str(" FROM (");
        outer.push_str(&page);
        outer.push_str(") AS paged");
        outer.push_str(&interface_error_metric_joins("paged"));
        if let Some(order_clause) = build_order_clause(&plan.order, false, Some("paged")) {
            outer.push(' ');
            outer.push_str(&order_clause);
        }

        let mut binds = binds;
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        (outer, binds)
    } else {
        let mut page = String::from("SELECT ");
        page.push_str(&interface_select_columns("di"));
        page.push_str(", ");
        page.push_str(interface_settings_projection());
        page.push(' ');
        page.push_str(&discovered_interfaces_from);
        if let Some(order_clause) = build_order_clause(&plan.order, true, Some("di")) {
            page.push(' ');
            page.push_str(&order_clause);
        }
        page.push_str(&format!(" LIMIT ${} OFFSET ${}", bind_idx, bind_idx + 1));

        let mut outer = String::from("SELECT ");
        outer.push_str(&interface_select_columns("paged"));
        outer.push_str(", tm_in.value AS in_errors, tm_out.value AS out_errors, ");
        outer.push_str(&interface_settings_columns("paged"));
        outer.push_str(" FROM (");
        outer.push_str(&page);
        outer.push_str(") AS paged");
        outer.push_str(&interface_error_metric_joins("paged"));
        if let Some(order_clause) = build_order_clause(&plan.order, true, Some("paged")) {
            outer.push(' ');
            outer.push_str(&order_clause);
        }

        let mut binds = binds;
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        (outer, binds)
    };

    Ok(SqlBuildResult { sql, binds })
}
