//! DDL for the two throwaway databases. Nothing here is a second copy of the product schema.
//!
//! StarRocks: every file under `elixir/serviceradar_core/priv/starrocks/`, split and retargeted
//! the way `ServiceRadar.Analytics.StarRocks.Schema` does it (`statements/1`, `retarget/3`)
//! and applied in version order the way `SchemaMigrator` applies them (an `ADD COLUMN` whose
//! column exists is skipped). That module is Elixir and this harness is Rust, so the two small
//! functions are restated here; `tests` pins them against the behaviours its moduledoc promises.
//!
//! CNPG: the table and function definitions come from the committed schema baseline
//! (`priv/repo/baseline/platform_schema.sql`, a `pg_dump --schema-only` of a migrated
//! database), extracted by name. What the baseline cannot carry is added explicitly, each item
//! naming the migration it restates: columns added by migrations newer than the baseline
//! (`POST_BASELINE_COLUMNS`), hypertables, and the continuous aggregates the CNPG dialect
//! reads (a pg_dump holds a CAGG only as views over `_timescaledb_internal` objects, which do
//! not replay; see `rust/integration-db/src/template.rs`). Replaying the real Ecto migrations
//! would need the Elixir application, which the fixture rules keep off workstations.

/// Splits a StarRocks schema file into statements, dropping `--` comment lines (the Frontend
/// rejects a comment sent as a statement of its own). Mirrors `Schema.statements/1`: split on
/// `;` at end of line.
pub fn starrocks_statements(sql: &str) -> Vec<String> {
    let without_comments: Vec<&str> = sql
        .lines()
        .filter(|line| !line.trim_start().starts_with("--"))
        .collect();
    let mut statements = Vec::new();
    let mut current = String::new();
    for line in without_comments {
        let trimmed_end = line.trim_end();
        if let Some(body) = trimmed_end.strip_suffix(';') {
            current.push_str(body);
            let statement = current.trim().to_string();
            if !statement.is_empty() {
                statements.push(statement);
            }
            current.clear();
        } else {
            current.push_str(line);
            current.push('\n');
        }
    }
    let tail = current.trim();
    if !tail.is_empty() {
        statements.push(tail.to_string());
    }
    statements
}

/// Rewrites the pinned database name `serviceradar` and `"replication_num" = "3"`.
pub fn starrocks_retarget(statement: &str, database: &str, replication_num: u32) -> String {
    assert!(
        valid_database_name(database),
        "invalid StarRocks database name: {database:?}"
    );
    let qualified = replace_word_before_dot(statement, "serviceradar", database);
    let created = replace_create_database(&qualified, database);
    created.replace(
        r#""replication_num" = "3""#,
        &format!(r#""replication_num" = "{replication_num}""#),
    )
}

pub fn valid_database_name(database: &str) -> bool {
    !database.is_empty()
        && database
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !database.starts_with(|c: char| c.is_ascii_digit())
}

/// `\bserviceradar(?=\.)` without a regex dependency.
fn replace_word_before_dot(statement: &str, word: &str, replacement: &str) -> String {
    let mut out = String::with_capacity(statement.len());
    let mut rest = statement;
    while let Some(at) = rest.find(word) {
        let before_ok = rest[..at]
            .chars()
            .next_back()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
        let after = &rest[at + word.len()..];
        out.push_str(&rest[..at]);
        if before_ok && after.starts_with('.') {
            out.push_str(replacement);
        } else {
            out.push_str(word);
        }
        rest = after;
    }
    out.push_str(rest);
    out
}

fn replace_create_database(statement: &str, database: &str) -> String {
    const PREFIX: &str = "CREATE DATABASE IF NOT EXISTS ";
    let upper = statement.to_ascii_uppercase();
    match upper.find(PREFIX) {
        Some(at) if statement[at + PREFIX.len()..].trim() == "serviceradar" => {
            format!("{}{database}", &statement[..at + PREFIX.len()])
        }
        _ => statement.to_string(),
    }
}

/// `ALTER TABLE t ADD COLUMN c ...` -> `(t, c)`. StarRocks has no `ADD COLUMN IF NOT EXISTS`
/// and the CREATE in 0001 already carries every later column, so -- like the production
/// migrator -- the caller has to ask before it adds.
pub fn starrocks_add_column(statement: &str) -> Option<(String, String)> {
    let words: Vec<&str> = statement.split_whitespace().collect();
    let keyword = |index: usize, expected: &str| {
        words
            .get(index)
            .is_some_and(|word| word.eq_ignore_ascii_case(expected))
    };
    if !(keyword(0, "ALTER") && keyword(1, "TABLE") && keyword(3, "ADD") && keyword(4, "COLUMN")) {
        return None;
    }
    let table = words[2].rsplit('.').next()?.trim_matches('`').to_string();
    let column = words.get(5)?.trim_matches('`').to_string();
    Some((table, column))
}

/// Async materialized views the StarRocks dialect reads; refreshed synchronously after seeding.
pub const STARROCKS_MATERIALIZED_VIEWS: &[&str] = &[
    "timeseries_metrics_hourly",
    "ocsf_network_activity_hourly",
    "events_hourly",
    "traces_stats_5m",
    "spans_red_1h",
];

/// Splits a pg_dump file into statements: `;` ends one outside quotes, dollar quotes and
/// comments.
pub fn dump_statements(sql: &str) -> Vec<String> {
    let bytes: Vec<char> = sql.chars().collect();
    let mut statements = Vec::new();
    let mut current = String::new();
    let mut index = 0;
    while index < bytes.len() {
        let c = bytes[index];
        if c == '-' && bytes.get(index + 1) == Some(&'-') {
            while index < bytes.len() && bytes[index] != '\n' {
                index += 1;
            }
            continue;
        }
        if c == '\'' {
            current.push(c);
            index += 1;
            while index < bytes.len() {
                current.push(bytes[index]);
                if bytes[index] == '\'' {
                    if bytes.get(index + 1) == Some(&'\'') {
                        current.push('\'');
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                index += 1;
            }
            continue;
        }
        if c == '$' {
            // A dollar-quote tag: `$$` or `$name$`.
            let mut end = index + 1;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == '_') {
                end += 1;
            }
            if end < bytes.len() && bytes[end] == '$' {
                let tag: String = bytes[index..=end].iter().collect();
                current.push_str(&tag);
                index = end + 1;
                let rest: String = bytes[index..].iter().collect();
                match rest.find(&tag) {
                    Some(at) => {
                        current.push_str(&rest[..at]);
                        current.push_str(&tag);
                        index += rest[..at].chars().count() + tag.chars().count();
                    }
                    None => {
                        current.push_str(&rest);
                        index = bytes.len();
                    }
                }
                continue;
            }
        }
        if c == ';' {
            let statement = current.trim().to_string();
            if !statement.is_empty() {
                statements.push(statement);
            }
            current.clear();
            index += 1;
            continue;
        }
        current.push(c);
        index += 1;
    }
    statements
}

/// Relations taken from the baseline by name: `CREATE TABLE platform.<name> (`.
pub const CNPG_BASELINE_TABLES: &[&str] = &[
    "timeseries_metrics",
    "ocsf_network_activity",
    "logs",
    "ocsf_events",
    "mtr_traces",
    "mtr_hops",
    "otel_metrics",
    "otel_metric_points",
    "otel_traces",
    "otel_trace_summaries",
    // Read by the CNPG flow `app` classifier; left empty, so both dialects fall back to the
    // same port-based labels.
    "netflow_app_classification_rules",
];

/// Functions the CNPG dialect's SQL or the continuous aggregates below call.
pub const CNPG_BASELINE_FUNCTIONS: &[&str] = &["try_inet", "serviceradar_log_severity_bucket"];

/// `(table, column, type, migration)`: columns added after the baseline was cut. `ADD COLUMN IF
/// NOT EXISTS`, so a regenerated baseline that already has them is a no-op here.
pub const POST_BASELINE_COLUMNS: &[(&str, &str, &str, &str)] = &[
    (
        "ocsf_network_activity",
        "flow_uid",
        "text",
        "20260919120000_add_flow_uid_dedup_key",
    ),
    (
        "mtr_hops",
        "target_ip",
        "text",
        "20260923120000_add_mtr_hop_target_attribution",
    ),
    (
        "mtr_hops",
        "device_id",
        "text",
        "20260923120000_add_mtr_hop_target_attribution",
    ),
    (
        "mtr_traces",
        "probed_hops",
        "integer",
        "20260924120000_add_mtr_trace_depth_fields",
    ),
    (
        "mtr_traces",
        "last_responding_hop",
        "integer",
        "20260924120000_add_mtr_trace_depth_fields",
    ),
    (
        "mtr_traces",
        "tcp_port",
        "integer",
        "20260924120000_add_mtr_trace_depth_fields",
    ),
    (
        "mtr_hops",
        "unreachable_code",
        "integer",
        "20260924120000_add_mtr_trace_depth_fields",
    ),
    (
        "mtr_traces",
        "tcp_handshake_ttl",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_handshake_attempts",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_syn_sent",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_synack_received",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_rst_received",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_syn_unanswered",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_syn_drop_pct",
        "double precision",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_syn_retransmits",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_answered_after_retx",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_ack_mismatch",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_synack_duplicates",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_handshake_rtt_min_us",
        "bigint",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_handshake_rtt_avg_us",
        "bigint",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_handshake_rtt_max_us",
        "bigint",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_traces",
        "tcp_server_response_us",
        "bigint",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_hops",
        "reply_time_exceeded",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_hops",
        "reply_unreachable",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_hops",
        "reply_synack",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
    (
        "mtr_hops",
        "reply_rst",
        "integer",
        "20260924130000_add_mtr_tcp_handshake_fields",
    ),
];

/// Hypertables and continuous aggregates, restated from the migrations named beside each.
pub const CNPG_TIMESCALE_DDL: &[&str] = &[
    // 20260909105000_ensure_timeseries_metrics_hypertable.exs
    "SELECT create_hypertable('platform.timeseries_metrics', 'timestamp', \
     create_default_indexes => false, if_not_exists => true)",
    "SELECT create_hypertable('platform.ocsf_network_activity', 'time', if_not_exists => true)",
    "SELECT create_hypertable('platform.logs', 'timestamp', if_not_exists => true)",
    "SELECT create_hypertable('platform.otel_traces', 'timestamp', if_not_exists => true)",
    // 20260220110000_add_srql_metric_hourly_caggs.exs
    "CREATE MATERIALIZED VIEW platform.timeseries_metrics_hourly
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('1 hour', timestamp) AS bucket,
       device_id,
       metric_type,
       metric_name,
       AVG(value)::float8 AS avg_value,
       MIN(value)::float8 AS min_value,
       MAX(value)::float8 AS max_value,
       COUNT(*)::bigint AS sample_count
     FROM platform.timeseries_metrics
     GROUP BY 1, 2, 3, 4
     WITH NO DATA",
    // 20260621143000_rebuild_flow_caggs_with_sampling_rate.exs (the sampled definitions).
    "CREATE MATERIALIZED VIEW platform.ocsf_network_activity_5m_traffic
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('5 minutes', time) AS bucket,
       COALESCE(SUM(bytes_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)::numeric), 0)::bigint AS bytes_total,
       COALESCE(SUM(packets_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)::numeric), 0)::bigint AS packets_total,
       COALESCE(COUNT(*), 0)::bigint AS flow_count
     FROM platform.ocsf_network_activity
     GROUP BY 1
     WITH NO DATA",
    "CREATE MATERIALIZED VIEW platform.ocsf_network_activity_hourly_talkers
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('1 hour', time) AS bucket,
       COALESCE(src_endpoint_ip, 'Unknown') AS src_endpoint_ip,
       COALESCE(SUM(bytes_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)::numeric), 0)::bigint AS bytes_total,
       COALESCE(SUM(packets_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1)::numeric), 0)::bigint AS packets_total,
       COALESCE(COUNT(*), 0)::bigint AS flow_count
     FROM platform.ocsf_network_activity
     GROUP BY 1, 2
     WITH NO DATA",
    // 20260621143000 create_hierarchical_flow_caggs/0: the hourly traffic rollup CNPG reads
    // for a >= 1h flow chart bucket, built over the 5-minute one.
    "CREATE MATERIALIZED VIEW platform.flow_traffic_1h
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('1 hour', bucket) AS bucket,
       SUM(bytes_total)::bigint AS bytes_total,
       SUM(packets_total)::bigint AS packets_total,
       SUM(flow_count)::bigint AS flow_count
     FROM platform.ocsf_network_activity_5m_traffic
     GROUP BY 1
     WITH NO DATA",
    // 20260812140000_ensure_logs_severity_stats_5m_cagg.exs (the classifier is the baseline's
    // `serviceradar_log_severity_bucket`, as redefined by 20260818180000).
    "CREATE MATERIALIZED VIEW platform.logs_severity_stats_5m
     WITH (timescaledb.continuous, timescaledb.create_group_indexes = false) AS
     SELECT
       time_bucket('5 minutes', timestamp) AS bucket,
       service_name,
       COUNT(*)::bigint AS total_count,
       COUNT(*) FILTER (WHERE platform.serviceradar_log_severity_bucket(severity_text, severity_number) = 'fatal')::bigint AS fatal_count,
       COUNT(*) FILTER (WHERE platform.serviceradar_log_severity_bucket(severity_text, severity_number) = 'error')::bigint AS error_count,
       COUNT(*) FILTER (WHERE platform.serviceradar_log_severity_bucket(severity_text, severity_number) = 'warning')::bigint AS warning_count,
       COUNT(*) FILTER (WHERE platform.serviceradar_log_severity_bucket(severity_text, severity_number) = 'info')::bigint AS info_count,
       COUNT(*) FILTER (WHERE platform.serviceradar_log_severity_bucket(severity_text, severity_number) = 'debug')::bigint AS debug_count
     FROM platform.logs
     GROUP BY 1, 2
     WITH NO DATA",
    // 20260611040000_align_otel_chunks_retention.exs (as the baseline states it).
    "CREATE MATERIALIZED VIEW platform.traces_stats_5m
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('5 minutes', timestamp) AS bucket,
       service_name,
       count(*) AS total_count,
       count(*) FILTER (WHERE status_code = 2) AS error_count,
       avg((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0) AS avg_duration_ms,
       percentile_cont(0.95) WITHIN GROUP (
         ORDER BY (end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0
       ) AS p95_duration_ms
     FROM platform.otel_traces
     WHERE parent_span_id IS NULL
     GROUP BY 1, 2
     WITH NO DATA",
    // 20260611080000_add_otel_span_fidelity_columns.exs (as the baseline states it).
    "CREATE MATERIALIZED VIEW platform.spans_red_1h
     WITH (timescaledb.continuous) AS
     SELECT
       time_bucket('1 hour', timestamp) AS bucket,
       COALESCE(service_name, '') AS service_name,
       COALESCE(service_namespace, '') AS service_namespace,
       COALESCE(deployment_environment, '') AS deployment_environment,
       count(*) AS total_count,
       count(*) FILTER (WHERE status_code = 2) AS error_count,
       count(*) FILTER (
         WHERE (end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0 > 100
       ) AS slow_count,
       avg((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0) AS avg_duration_ms,
       percentile_cont(0.5) WITHIN GROUP (
         ORDER BY (end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0
       ) FILTER (WHERE (end_time_unix_nano - start_time_unix_nano) IS NOT NULL) AS p50_duration_ms,
       percentile_cont(0.95) WITHIN GROUP (
         ORDER BY (end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0
       ) FILTER (WHERE (end_time_unix_nano - start_time_unix_nano) IS NOT NULL) AS p95_duration_ms,
       max((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0) AS max_duration_ms
     FROM platform.otel_traces
     GROUP BY 1, 2, 3, 4
     WITH NO DATA",
];

/// Continuous aggregates materialised after seeding: created `WITH NO DATA`, they are empty
/// until refreshed, and the CNPG dialect reads closed buckets only from them.
pub const CNPG_CONTINUOUS_AGGREGATES: &[&str] = &[
    "platform.timeseries_metrics_hourly",
    // Before flow_traffic_1h, which is built over it.
    "platform.ocsf_network_activity_5m_traffic",
    "platform.flow_traffic_1h",
    "platform.ocsf_network_activity_hourly_talkers",
    "platform.logs_severity_stats_5m",
    "platform.traces_stats_5m",
    "platform.spans_red_1h",
];

/// The CNPG DDL, in order, for a fresh database.
pub fn cnpg_ddl(baseline: &str) -> Result<Vec<String>, String> {
    let statements = dump_statements(baseline);
    // The product installs TimescaleDB into `platform` (the baseline's own CREATE EXTENSION),
    // so the dialect's unqualified `time_bucket` resolves through `search_path=platform`.
    let extension = statements
        .iter()
        .find(|s| s.starts_with("CREATE EXTENSION IF NOT EXISTS timescaledb"))
        .ok_or("baseline has no timescaledb extension")?;
    let mut ddl = vec![
        "CREATE SCHEMA IF NOT EXISTS platform".to_string(),
        extension.clone(),
    ];
    for function in CNPG_BASELINE_FUNCTIONS {
        let prefix = format!("CREATE FUNCTION platform.{function}(");
        let found: Vec<&String> = statements
            .iter()
            .filter(|s| s.starts_with(&prefix))
            .collect();
        if found.is_empty() {
            return Err(format!("baseline has no function platform.{function}"));
        }
        ddl.extend(found.into_iter().cloned());
    }
    for table in CNPG_BASELINE_TABLES {
        let prefix = format!("CREATE TABLE platform.{table} (");
        let found = statements
            .iter()
            .find(|s| s.starts_with(&prefix))
            .ok_or_else(|| format!("baseline has no table platform.{table}"))?;
        ddl.push(found.clone());
    }
    for (table, column, kind, _migration) in POST_BASELINE_COLUMNS {
        ddl.push(format!(
            "ALTER TABLE platform.{table} ADD COLUMN IF NOT EXISTS {column} {kind}"
        ));
    }
    ddl.extend(CNPG_TIMESCALE_DDL.iter().map(|s| s.to_string()));
    Ok(ddl)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statements_drop_comment_lines_and_split_on_terminators() {
        let sql = "-- a comment\nCREATE DATABASE IF NOT EXISTS serviceradar;\n\nCREATE TABLE x (\n  a INT -- not a line comment start\n);\n";
        let statements = starrocks_statements(sql);
        assert_eq!(statements.len(), 2);
        assert_eq!(statements[0], "CREATE DATABASE IF NOT EXISTS serviceradar");
        assert!(statements[1].starts_with("CREATE TABLE x"));
    }

    #[test]
    fn retarget_rewrites_database_and_replication_only() {
        let statement = "CREATE TABLE IF NOT EXISTS serviceradar.t (a INT) PROPERTIES (\"replication_num\" = \"3\") -- serviceradar_other.x myserviceradar.y";
        let out = starrocks_retarget(statement, "srql_parity_x", 1);
        assert!(out.contains("srql_parity_x.t"));
        assert!(out.contains(r#""replication_num" = "1""#));
        assert!(out.contains("serviceradar_other.x"));
        assert!(out.contains("myserviceradar.y"));
        assert_eq!(
            starrocks_retarget(
                "CREATE DATABASE IF NOT EXISTS serviceradar",
                "srql_parity_x",
                1
            ),
            "CREATE DATABASE IF NOT EXISTS srql_parity_x"
        );
    }

    #[test]
    fn add_column_is_recognised() {
        assert_eq!(
            starrocks_add_column("ALTER TABLE serviceradar.events ADD COLUMN `host` VARCHAR(256)"),
            Some(("events".into(), "host".into()))
        );
        assert_eq!(
            starrocks_add_column("DROP MATERIALIZED VIEW IF EXISTS x"),
            None
        );
    }

    #[test]
    fn dump_statements_respect_dollar_quotes_and_strings() {
        let sql = "-- c;\nCREATE FUNCTION platform.f(a text) RETURNS text\n    LANGUAGE sql\n    AS $_$ SELECT 'x;y' || $1; $_$;\n\nCREATE TABLE platform.t (\n    a text DEFAULT ';'::text\n);\n";
        let statements = dump_statements(sql);
        assert_eq!(statements.len(), 2, "{statements:?}");
        assert!(statements[0].ends_with("$_$ SELECT 'x;y' || $1; $_$"));
        assert!(statements[1].starts_with("CREATE TABLE platform.t ("));
    }
}
