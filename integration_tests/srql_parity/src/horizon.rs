//! Storage, rollup, and SRQL contract checks for Horizon ISP accountability
//! (`priv/starrocks/0044_horizon_tables.sql` and `0045_horizon_isp_accountability_mv.sql`)
//! in the runner's disposable StarRocks warehouse.

use anyhow::{Result, ensure};
use mysql_async::{
    Conn,
    prelude::{FromRow, FromValue, Queryable},
};
use srql::{
    config::AppConfig,
    query::{QueryDirection, QueryRequest, translate_request},
};

const LIST_ALL_QUERY: &str = "in:horizon_isp_accountability sort:target_id:asc limit:20";
const FILTERED_DAY2_QUERY: &str = concat!(
    r#"in:horizon_isp_accountability as_org:"O'Reilly\\ISP" asn:(64519,64520) "#,
    "!mtu_blackhole_count:(99,100) time:[2026-11-23T14:00:00Z,2026-11-23T15:00:00Z] ",
    "sort:day:asc,forwarding_loss_pct:desc limit:10"
);
const DAY1_PRUNE_QUERY: &str =
    "in:horizon_isp_accountability time:[2026-11-22T10:00:00Z,2026-11-22T11:00:00Z] limit:10";
const LATE_TARGET_QUERY: &str =
    "in:horizon_isp_accountability target_id:tgt-late time:[2026-11-23T14:00:00Z,2026-11-23T15:00:00Z] limit:5";

pub(crate) async fn verify(conn: &mut Conn, database: &str) -> Result<()> {
    verify_mv_metadata(conn, database).await?;
    seed_initial_rows(conn, database).await?;
    refresh_mv(conn, database).await?;

    let list_sql = translate_starrocks(LIST_ALL_QUERY, database)?;
    let rows: Vec<AccountabilityRow> = conn.query(&list_sql).await?;
    verify_initial_rows(&rows)?;

    let filtered_sql = translate_starrocks(FILTERED_DAY2_QUERY, database)?;
    let filtered: Vec<AccountabilityRow> = conn.query(&filtered_sql).await?;
    ensure!(
        filtered.len() == 1
            && filtered[0].target_id == "tgt-transit"
            && filtered[0].as_org == r"O'Reilly\ISP"
            && filtered[0].first_blame_tier == "isp_transit",
        "filtered/escaped SRQL query returned unexpected rows: {filtered:?}"
    );

    verify_partition_pruning(conn, &filtered_sql, "day-2 lower/upper bound").await?;
    let day1_sql = translate_starrocks(DAY1_PRUNE_QUERY, database)?;
    verify_partition_pruning(conn, &day1_sql, "day-1 upper bound").await?;

    // Late correlated events on day 2 must invalidate and refresh day 2 without new hops.
    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_outages \
         (time, outage_id, status, severity, entity_type, entity_key, origin_asn, \
          corroborating_pop_count) VALUES \
         ('2026-11-23 14:25:00', 'out-late', 'active', 'major', 'asn', 'AS64520', 64520, 3)"
    ))
    .await?;
    refresh_mv(conn, database).await?;
    let late_sql = translate_starrocks(LATE_TARGET_QUERY, database)?;
    let after_outage: Vec<AccountabilityRow> = conn.query(&late_sql).await?;
    ensure!(
        after_outage.len() == 1
            && after_outage[0].active_outage_count == 1
            && after_outage[0].first_blame_tier == "active_outage",
        "late outage did not promote tgt-late to active_outage: {after_outage:?}"
    );

    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_bgp_events \
         (time, event_id, kind, level, prefix, origin_asn, rpki_status) VALUES \
         ('2026-11-23 14:30:00', 'bgp-late', 'anomaly', 'high', '198.51.100.0/24', \
          64520, 'invalid_length')"
    ))
    .await?;
    refresh_mv(conn, database).await?;
    let after_bgp: Vec<AccountabilityRow> = conn.query(&late_sql).await?;
    ensure!(
        after_bgp.len() == 1
            && after_bgp[0].active_outage_count == 1
            && after_bgp[0].bgp_anomaly_count == 1
            && after_bgp[0].first_blame_tier == "bgp_hijack",
        "late RPKI-invalid BGP event did not promote tgt-late to bgp_hijack: {after_bgp:?}"
    );

    // Replay migration 45 with data present: startup replay must be idempotent and retain rows.
    conn.query_drop(format!(
        "DELETE FROM {database}.schema_migrations WHERE version = 45"
    ))
    .await?;
    crate::runner::sr_migrate(database).await?;

    let after_replay: Vec<AccountabilityRow> = conn.query(&late_sql).await?;
    ensure!(
        after_replay.len() == 1 && after_replay[0].first_blame_tier == "bgp_hijack",
        "migration 0045 replay lost materialized rows: {after_replay:?}"
    );
    Ok(())
}

async fn verify_mv_metadata(conn: &mut Conn, database: &str) -> Result<()> {
    let show_create: Option<(String, String)> = conn
        .query_first(format!(
            "SHOW CREATE MATERIALIZED VIEW {database}.horizon_isp_accountability_mv"
        ))
        .await?;
    let (_name, ddl) = show_create
        .ok_or_else(|| anyhow::anyhow!("SHOW CREATE MATERIALIZED VIEW returned no rows"))?;
    ensure!(
        ddl.contains("PARTITION BY (`day`)")
            && ddl.contains("DISTRIBUTED BY HASH(`target_id`) BUCKETS 1")
            && ddl.contains("EVERY(INTERVAL 1 MINUTE)"),
        "unexpected horizon_isp_accountability_mv DDL:\n{ddl}"
    );

    let meta: Option<(String, String)> = conn
        .query_first(format!(
            "SELECT IS_ACTIVE, REFRESH_TYPE FROM information_schema.materialized_views \
             WHERE TABLE_SCHEMA = '{database}' AND TABLE_NAME = 'horizon_isp_accountability_mv'"
        ))
        .await?;
    let (active, refresh_type) =
        meta.ok_or_else(|| anyhow::anyhow!("horizon_isp_accountability_mv missing from catalog"))?;
    ensure!(
        active.eq_ignore_ascii_case("true") && refresh_type.eq_ignore_ascii_case("ASYNC"),
        "expected active ASYNC MV, got IS_ACTIVE={active:?} REFRESH_TYPE={refresh_type:?}"
    );
    Ok(())
}

async fn seed_initial_rows(conn: &mut Conn, database: &str) -> Result<()> {
    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_path_hops \
         (time, round_id, target_id, pop_id, hop_ttl, hop_ip, asn, as_org, is_cloud, \
          forwarding_loss_pct, avg_rtt_ms, effective_path_mtu, mtu_blackhole_detected, \
          blackhole_hop_ttl) VALUES \
         ('2026-11-22 10:15:00', 'r1', 'tgt-healthy', 'pop-test-a', 3, '198.51.100.1', 64512, 'Example HealthyNet', false, 0.25, 10.0, 1500, false, NULL), \
         ('2026-11-22 10:45:00', 'r2', 'tgt-healthy', 'pop-test-a', 3, '198.51.100.1', 64512, 'Example HealthyNet', false, 0.75, 20.0, 1480, false, NULL), \
         ('2026-11-23 14:10:00', 'r3', 'tgt-hijack', 'pop-test-a', 4, '198.51.100.2', 64513, 'Example HijackISP', false, 5.0, 30.0, 1400, true, 4), \
         ('2026-11-23 14:20:00', 'r4', 'tgt-hijack', 'pop-test-a', 4, '198.51.100.2', 64513, 'Example HijackISP', false, 15.0, 50.0, 0, false, NULL), \
         ('2026-11-23 14:15:00', 'r5', 'tgt-leak', 'pop-test-a', 4, '198.51.100.3', 64514, 'Example LeakISP', false, 0.0, 12.0, 1500, false, NULL), \
         ('2026-11-23 14:15:00', 'r6', 'tgt-anom', 'pop-test-a', 4, '198.51.100.4', 64515, 'Example AnomISP', false, 0.0, 12.0, 1500, false, NULL), \
         ('2026-11-23 14:15:00', 'r7', 'tgt-zombie', 'pop-test-a', 4, '198.51.100.5', 64516, 'Example ZombieISP', false, 0.0, 12.0, 1500, false, NULL), \
         ('2026-11-23 14:15:00', 'r8', 'tgt-outage', 'pop-test-a', 4, '198.51.100.6', 64517, 'Example OutageISP', false, 0.0, 12.0, 1500, false, NULL), \
         ('2026-11-23 14:15:00', 'r9', 'tgt-mtu', 'pop-test-a', 4, '198.51.100.7', 64518, 'Example MtuISP', false, 2.0, 15.0, 1380, true, 4), \
         ('2026-11-23 14:15:00', 'r10', 'tgt-lan', 'pop-test-a', 1, '192.0.2.1', NULL, NULL, false, 2.5, 1.5, 0, false, NULL), \
         ('2026-11-23 14:15:00', 'r11', 'tgt-transit', 'pop-test-a', 5, '198.51.100.8', 64519, 'O''Reilly\\\\ISP', false, 1.0, 25.0, 1500, false, NULL), \
         ('2026-11-23 14:15:00', 'r12', 'tgt-late', 'pop-test-a', 3, '198.51.100.9', 64520, 'Example LateNet', false, 0.1, 8.0, 1500, false, NULL)"
    ))
    .await?;

    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_outages \
         (time, outage_id, status, severity, entity_type, entity_key, origin_asn, \
          corroborating_pop_count) VALUES \
         ('2026-11-23 14:05:00', 'out-1', 'active', 'major', 'asn', 'AS64513', 64513, 3), \
         ('2026-11-23 14:10:00', 'out-2', 'ACTIVE', 'major', 'asn', 'AS64517', 64517, 2), \
         ('2026-11-23 14:20:00', 'out-3', 'resolved', 'minor', 'asn', 'AS64517', 64517, 2), \
         ('2026-11-23 14:30:00', 'out-4', 'CLEARED', 'minor', 'asn', 'AS64519', 64519, 2)"
    ))
    .await?;

    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_bgp_events \
         (time, event_id, kind, level, prefix, origin_asn, rpki_status, \
          caida_leak_inference) VALUES \
         ('2026-11-23 14:05:00', 'bgp-1', 'hijack', 'critical', '198.51.100.0/24', 64513, 'invalid_asn', 'valley_free_violation'), \
         ('2026-11-23 14:06:00', 'bgp-2', 'route_leak', 'high', '198.51.100.0/24', 64514, 'valid', 'valley_free_violation'), \
         ('2026-11-23 14:07:00', 'bgp-3', 'flap', 'medium', '198.51.100.0/24', 64515, 'valid', 'none')"
    ))
    .await?;

    conn.query_drop(format!(
        "INSERT INTO {database}.horizon_bgp_zombies \
         (time, episode_id, status, prefix, origin_asn, divergence_pct, is_beacon) VALUES \
         ('2026-11-23 14:05:00', 'z-1', 'active', '198.51.100.0/24', 64513, 50.0, false), \
         ('2026-11-23 14:05:00', 'z-2', 'active', '198.51.100.0/24', 64516, 40.0, false), \
         ('2026-11-23 14:25:00', 'z-3', 'resolved', '198.51.100.0/24', 64516, 40.0, false)"
    ))
    .await?;
    Ok(())
}

async fn refresh_mv(conn: &mut Conn, database: &str) -> Result<()> {
    conn.query_drop(format!(
        "REFRESH MATERIALIZED VIEW {database}.horizon_isp_accountability_mv WITH SYNC MODE"
    ))
    .await?;
    Ok(())
}

async fn verify_partition_pruning(conn: &mut Conn, sql: &str, label: &str) -> Result<()> {
    let lines: Vec<String> = conn.query(format!("EXPLAIN {sql}")).await?;
    let plan = lines.join("\n");
    ensure!(
        plan.contains("partitions=1/2") && plan.contains("MaterializedView: true"),
        "expected day partition pruning (partitions=1/2) for {label}, got:\n{plan}"
    );
    Ok(())
}

fn translate_starrocks(query: &str, database: &str) -> Result<String> {
    let mut config = AppConfig::embedded("postgres://parity.invalid/unused".into());
    config.starrocks_database = database.to_string();
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: Some("starrocks".to_string()),
        permitted_signals: None,
    };
    Ok(translate_request(&config, request)?.sql)
}

fn approx_eq(actual: f64, expected: f64) -> bool {
    (actual - expected).abs() < 1e-9
}

fn verify_initial_rows(rows: &[AccountabilityRow]) -> Result<()> {
    ensure!(
        rows.len() == 10,
        "expected 10 rolled-up rows, got {}: {rows:?}",
        rows.len()
    );

    let by_target = |id: &str| -> Result<&AccountabilityRow> {
        rows.iter()
            .find(|r| r.target_id == id)
            .ok_or_else(|| anyhow::anyhow!("missing target_id={id} in {rows:?}"))
    };

    let healthy = by_target("tgt-healthy")?;
    ensure!(
        healthy.day == "2026-11-22 00:00:00"
            && healthy.bucket_hour == "2026-11-22 10:00:00"
            && healthy.asn == 64512
            && healthy.as_org == "Example HealthyNet"
            && approx_eq(healthy.forwarding_loss_pct, 0.5)
            && healthy.avg_rtt_ms.is_some_and(|v| approx_eq(v, 15.0))
            && healthy.max_rtt_ms.is_some_and(|v| approx_eq(v, 20.0))
            && healthy.mtu_blackhole_count == 0
            && healthy.min_effective_mtu == Some(1480)
            && healthy.active_outage_count == 0
            && healthy.bgp_anomaly_count == 0
            && healthy.bgp_zombie_count == 0
            && healthy.first_blame_tier == "healthy"
            && healthy.sample_count == 2,
        "unexpected healthy rollup: {healthy:?}"
    );

    let hijack = by_target("tgt-hijack")?;
    ensure!(
        hijack.day == "2026-11-23 00:00:00"
            && hijack.bucket_hour == "2026-11-23 14:00:00"
            && hijack.asn == 64513
            && approx_eq(hijack.forwarding_loss_pct, 10.0)
            && hijack.avg_rtt_ms.is_some_and(|v| approx_eq(v, 40.0))
            && hijack.max_rtt_ms.is_some_and(|v| approx_eq(v, 50.0))
            && hijack.mtu_blackhole_count == 1
            && hijack.min_effective_mtu == Some(1400)
            && hijack.active_outage_count == 1
            && hijack.bgp_anomaly_count == 1
            && hijack.bgp_zombie_count == 1
            && hijack.first_blame_tier == "bgp_hijack"
            && hijack.sample_count == 2,
        "unexpected hijack rollup: {hijack:?}"
    );

    let lan = by_target("tgt-lan")?;
    ensure!(
        lan.asn == 0
            && lan.as_org.is_empty()
            && lan.min_effective_mtu.is_none()
            && lan.first_blame_tier == "customer_lan",
        "unexpected customer_lan rollup: {lan:?}"
    );

    for (target, tier, outages, anomalies, zombies, blackholes) in [
        ("tgt-leak", "bgp_route_leak", 0, 1, 0, 0),
        ("tgt-anom", "bgp_anomaly", 0, 1, 0, 0),
        ("tgt-zombie", "bgp_zombie", 0, 0, 1, 0),
        ("tgt-outage", "active_outage", 1, 0, 0, 0),
        ("tgt-mtu", "pmtud_blackhole", 0, 0, 0, 1),
        ("tgt-transit", "isp_transit", 0, 0, 0, 0),
        ("tgt-late", "healthy", 0, 0, 0, 0),
    ] {
        let row = by_target(target)?;
        ensure!(
            row.first_blame_tier == tier
                && row.active_outage_count == outages
                && row.bgp_anomaly_count == anomalies
                && row.bgp_zombie_count == zombies
                && row.mtu_blackhole_count == blackholes,
            "unexpected rollup for {target}: {row:?}"
        );
    }

    Ok(())
}

#[derive(Debug)]
struct AccountabilityRow {
    day: String,
    bucket_hour: String,
    asn: i64,
    as_org: String,
    target_id: String,
    forwarding_loss_pct: f64,
    avg_rtt_ms: Option<f64>,
    max_rtt_ms: Option<f64>,
    mtu_blackhole_count: i64,
    min_effective_mtu: Option<i32>,
    active_outage_count: i64,
    bgp_anomaly_count: i64,
    bgp_zombie_count: i64,
    first_blame_tier: String,
    sample_count: i64,
}

impl FromRow for AccountabilityRow {
    fn from_row_opt(row: mysql_async::Row) -> Result<Self, mysql_async::FromRowError> {
        read_row(&row).ok_or(mysql_async::FromRowError(row))
    }
}

fn read_row(row: &mysql_async::Row) -> Option<AccountabilityRow> {
    Some(AccountabilityRow {
        day: col(row, 0)?,
        bucket_hour: col(row, 1)?,
        asn: col(row, 2)?,
        as_org: col(row, 3)?,
        target_id: col(row, 4)?,
        forwarding_loss_pct: col(row, 5)?,
        avg_rtt_ms: col(row, 6)?,
        max_rtt_ms: col(row, 7)?,
        mtu_blackhole_count: col(row, 8)?,
        min_effective_mtu: col(row, 9)?,
        active_outage_count: col(row, 10)?,
        bgp_anomaly_count: col(row, 11)?,
        bgp_zombie_count: col(row, 12)?,
        first_blame_tier: col(row, 13)?,
        sample_count: col(row, 14)?,
    })
}

fn col<T: FromValue>(row: &mysql_async::Row, index: usize) -> Option<T> {
    row.get_opt(index).and_then(Result::ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parity_horizon_queries_compile_for_starrocks_with_day_partition_pruning() {
        let list_sql = translate_starrocks(LIST_ALL_QUERY, "srql_parity_ci")
            .expect("list query should compile");
        assert!(list_sql.contains("FROM srql_parity_ci.horizon_isp_accountability_mv"));
        assert!(list_sql.contains("ORDER BY `target_id` ASC"));

        let filtered_sql = translate_starrocks(FILTERED_DAY2_QUERY, "srql_parity_ci")
            .expect("filtered day-2 query should compile");
        assert!(filtered_sql.contains(r"`as_org` = 'O''Reilly\\ISP'"));
        assert!(filtered_sql.contains("`asn` IN (64519, 64520)"));
        assert!(filtered_sql.contains("`mtu_blackhole_count` NOT IN (99, 100)"));
        assert!(filtered_sql.contains("`day` >= date_trunc('day', '2026-11-23 14:00:00.000000')"));
        assert!(filtered_sql.contains("`day` <= '2026-11-23 15:00:00.000000'"));

        let day1_sql = translate_starrocks(DAY1_PRUNE_QUERY, "srql_parity_ci")
            .expect("day-1 query should compile");
        assert!(day1_sql.contains("`day` >= date_trunc('day', '2026-11-22 10:00:00.000000')"));
        assert!(day1_sql.contains("`day` <= '2026-11-22 11:00:00.000000'"));
    }
}
