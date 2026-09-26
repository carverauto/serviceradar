//! Task 1.4: seed CNPG and StarRocks with the same synthetic rows, run every inventory entry
//! through both SRQL dialects, diff the results.
//!
//! The SQL under test is the SRQL crate's own: `srql::query::translate_request` with the CNPG
//! mode and with `mode: "starrocks"`, exactly the entry point the product's NIF calls. The CNPG
//! statement is prepared and its parameters bound with the types the server infers; the
//! StarRocks statement is self-contained (its compiler inlines literals).
//!
//! Both databases are throwaway, named `srql_parity_<UTC timestamp>_<pid>`, and dropped when the
//! run ends however it ends. A sweep first drops any such database older than
//! `STALE_AFTER_HOURS` left by a killed run. Nothing here reads or writes any other database:
//! the names are validated against that exact pattern before any DROP, and a StarRocks query
//! that would read the `cnpg_platform` JDBC catalog -- which points at a live deployment's
//! database, not this run's -- is never executed.
//!
//! Configuration is environment only, so no credential is ever a Bazel action input or argv:
//!
//! | variable | meaning |
//! | --- | --- |
//! | `SRQL_PARITY_CNPG_ADMIN_URL` | `postgres://user:pass@host:port/postgres` for a role that may CREATE/DROP DATABASE |
//! | `SRQL_PARITY_CNPG_CA_PEM` | CA certificate PEM content (TLS is required when set) |
//! | `SRQL_PARITY_CNPG_SERVER_NAME` | the name the certificate is verified against |
//! | `SRQL_PARITY_STARROCKS_HOST` / `_PORT` / `_USER` / `_PASSWORD` | the StarRocks FE MySQL endpoint |
//! | `SRQL_PARITY_ONLY` | optional: run only entries whose id contains this text |
//! | `SRQL_PARITY_KEEP` | optional: `1` keeps both databases for inspection (the sweep drops them later) |

use crate::compare::{self, Row, Tolerance, Verdict};
use crate::fixture::{self, Anchor, Backend};
use crate::inventory::{
    DEFAULT_ABSOLUTE_TOLERANCE, DEFAULT_RELATIVE_TOLERANCE, Entry, Expect, Inventory, Recorded,
};
use crate::schema;
use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, NaiveDateTime, Utc};
use mysql_async::prelude::Queryable;
use serde_json::Value;
use srql::query::{BindParam, QueryDirection, QueryRequest};
use std::fmt::Write as _;
use std::path::Path;
use tokio_postgres::types::{ToSql, Type};

pub const DATABASE_PREFIX: &str = "srql_parity_";
pub const STALE_AFTER_HOURS: i64 = 6;
/// The JDBC catalog the StarRocks dialect joins for CNPG-owned inventory; see module docs.
const CNPG_CATALOG_REFERENCE: &str = "cnpg_platform.";

struct Settings {
    cnpg_admin_url: String,
    cnpg_ca_pem: Option<Vec<u8>>,
    cnpg_server_name: Option<String>,
    starrocks: mysql_async::Opts,
    only: Option<String>,
    keep: bool,
}

fn required(name: &str) -> Result<String> {
    match std::env::var(name) {
        Ok(value) if !value.trim().is_empty() => Ok(value),
        // Name the variable, never the value.
        _ => bail!("{name} is not set; see integration_tests/srql_parity/src/runner.rs"),
    }
}

fn optional(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

impl Settings {
    fn from_env() -> Result<Self> {
        let port: u16 = required("SRQL_PARITY_STARROCKS_PORT")?
            .trim()
            .parse()
            .context("SRQL_PARITY_STARROCKS_PORT must be a port number")?;
        let starrocks = mysql_async::OptsBuilder::default()
            .ip_or_hostname(required("SRQL_PARITY_STARROCKS_HOST")?)
            .tcp_port(port)
            .user(Some(required("SRQL_PARITY_STARROCKS_USER")?))
            .pass(optional("SRQL_PARITY_STARROCKS_PASSWORD"))
            // StarRocks does not implement COM_RESET_CONNECTION.
            .pool_opts(
                mysql_async::PoolOpts::default()
                    .with_reset_connection(false)
                    .with_constraints(mysql_async::PoolConstraints::new(1, 2).expect("pool")),
            )
            .prefer_socket(false)
            .into();
        Ok(Self {
            cnpg_admin_url: required("SRQL_PARITY_CNPG_ADMIN_URL")?,
            cnpg_ca_pem: optional("SRQL_PARITY_CNPG_CA_PEM").map(String::into_bytes),
            cnpg_server_name: optional("SRQL_PARITY_CNPG_SERVER_NAME"),
            starrocks,
            only: optional("SRQL_PARITY_ONLY"),
            keep: optional("SRQL_PARITY_KEEP").as_deref() == Some("1"),
        })
    }
}

/// `srql_parity_<yyyymmddHHMMSS>_<pid>`, the only names this harness creates or drops.
pub fn run_database_name(now: DateTime<Utc>, pid: u32) -> String {
    format!("{DATABASE_PREFIX}{}_{pid}", now.format("%Y%m%d%H%M%S"))
}

/// The creation time of a database this harness named, or `None` for any other name.
pub fn run_database_created(name: &str) -> Option<DateTime<Utc>> {
    let rest = name.strip_prefix(DATABASE_PREFIX)?;
    let (stamp, pid) = rest.split_once('_')?;
    if stamp.len() != 14
        || !stamp.chars().all(|c| c.is_ascii_digit())
        || pid.is_empty()
        || !pid.chars().all(|c| c.is_ascii_digit())
    {
        return None;
    }
    NaiveDateTime::parse_from_str(stamp, "%Y%m%d%H%M%S")
        .ok()
        .map(|naive| naive.and_utc())
}

// ---------------------------------------------------------------------------------------
// CNPG

struct Cnpg<'a> {
    settings: &'a Settings,
}

impl Cnpg<'_> {
    async fn connect(&self, database: Option<&str>) -> Result<tokio_postgres::Client> {
        let mut config = srql::db::parse_pg_config(&self.settings.cnpg_admin_url)
            .context("SRQL_PARITY_CNPG_ADMIN_URL is not a PostgreSQL URL")?;
        if let Some(database) = database {
            config.dbname(database);
        }
        config.options("-c search_path=platform,public");
        let client = match &self.settings.cnpg_ca_pem {
            Some(ca) => {
                let connector = srql::tls::postgres_connector(
                    ca,
                    None,
                    None,
                    self.settings.cnpg_server_name.as_deref(),
                )?;
                let (client, connection) = config.connect(connector).await?;
                tokio::spawn(async move {
                    let _ = connection.await;
                });
                client
            }
            None => {
                let (client, connection) = config.connect(tokio_postgres::NoTls).await?;
                tokio::spawn(async move {
                    let _ = connection.await;
                });
                client
            }
        };
        Ok(client)
    }

    async fn sweep(&self, now: DateTime<Utc>) -> Result<Vec<String>> {
        let admin = self.connect(None).await?;
        let rows = admin
            .query(
                "SELECT datname FROM pg_database WHERE datname LIKE 'srql\\_parity\\_%'",
                &[],
            )
            .await?;
        let mut dropped = Vec::new();
        for row in rows {
            let name: String = row.get(0);
            if let Some(created) = run_database_created(&name)
                && now - created > chrono::Duration::hours(STALE_AFTER_HOURS)
            {
                admin
                    .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
                    .await?;
                dropped.push(name);
            }
        }
        Ok(dropped)
    }

    async fn create(&self, database: &str, baseline: &str) -> Result<tokio_postgres::Client> {
        assert!(run_database_created(database).is_some());
        let admin = self.connect(None).await?;
        admin
            .batch_execute(&format!("CREATE DATABASE {database}"))
            .await
            .context("CREATE DATABASE on CNPG")?;
        let client = self.connect(Some(database)).await?;
        for statement in schema::cnpg_ddl(baseline).map_err(|e| anyhow!(e))? {
            client
                .batch_execute(&statement)
                .await
                .with_context(|| format!("CNPG DDL failed:\n{statement}"))?;
        }
        Ok(client)
    }

    async fn drop(&self, database: &str) -> Result<()> {
        assert!(run_database_created(database).is_some());
        let admin = self.connect(None).await?;
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {database} WITH (FORCE)"))
            .await?;
        Ok(())
    }
}

fn bind_param(param: &BindParam, kind: &Type) -> Result<Box<dyn ToSql + Sync + Send>> {
    let parse_instant = |text: &str| -> Result<DateTime<Utc>> {
        Ok(DateTime::parse_from_rfc3339(text)
            .with_context(|| format!("timestamp bind {text}"))?
            .with_timezone(&Utc))
    };
    Ok(match (param, kind) {
        (BindParam::Text(v), _) => Box::new(v.clone()),
        (BindParam::TextArray(v), _) => Box::new(v.clone()),
        (BindParam::IntArray(v), k) if *k == Type::INT4_ARRAY => {
            Box::new(v.iter().map(|x| *x as i32).collect::<Vec<i32>>())
        }
        (BindParam::IntArray(v), _) => Box::new(v.clone()),
        (BindParam::Bool(v), _) => Box::new(*v),
        (BindParam::Int(v), k) if *k == Type::INT4 => Box::new(*v as i32),
        (BindParam::Int(v), k) if *k == Type::INT2 => Box::new(*v as i16),
        (BindParam::Int(v), k) if *k == Type::FLOAT8 => Box::new(*v as f64),
        (BindParam::Int(v), _) => Box::new(*v),
        (BindParam::Float(v), k) if *k == Type::FLOAT4 => Box::new(*v as f32),
        (BindParam::Float(v), _) => Box::new(*v),
        (BindParam::Timestamptz(v), k) if *k == Type::TIMESTAMP => {
            Box::new(parse_instant(v)?.naive_utc())
        }
        (BindParam::Timestamptz(v), _) => Box::new(parse_instant(v)?),
        (BindParam::Date(v), _) => {
            Box::new(chrono::NaiveDate::parse_from_str(v, "%Y-%m-%d").context("date bind")?)
        }
        (BindParam::Uuid(v), _) => bail!("uuid bind {v} is not supported by the harness"),
    })
}

async fn cnpg_rows(
    client: &tokio_postgres::Client,
    sql: &str,
    params: &[BindParam],
) -> Result<Vec<Row>> {
    // row_to_json renders every type (numeric, arrays, jsonb, timestamptz) without a decoder
    // per type. The outer SELECT adds no operator that could reorder the inner result.
    let wrapped = format!("SELECT row_to_json(parity_q)::text FROM ({sql}) parity_q");
    let statement = client
        .prepare(&wrapped)
        .await
        .map_err(|e| anyhow!("prepare: {}", describe_pg_error(&e)))?;
    if statement.params().len() != params.len() {
        bail!(
            "the statement takes {} parameters, srql supplied {}",
            statement.params().len(),
            params.len()
        );
    }
    let boxed: Vec<Box<dyn ToSql + Sync + Send>> = params
        .iter()
        .zip(statement.params())
        .map(|(param, kind)| bind_param(param, kind))
        .collect::<Result<_>>()?;
    let refs: Vec<&(dyn ToSql + Sync)> = boxed
        .iter()
        .map(|b| b.as_ref() as &(dyn ToSql + Sync))
        .collect();
    let rows = client
        .query(&statement, &refs)
        .await
        .map_err(|e| anyhow!("execute: {}", describe_pg_error(&e)))?;
    rows.iter()
        .map(|row| {
            let text: String = row.get(0);
            match serde_json::from_str::<Value>(&text)? {
                Value::Object(map) => Ok(map),
                other => bail!("row_to_json gave {other}"),
            }
        })
        .collect()
}

fn describe_pg_error(error: &tokio_postgres::Error) -> String {
    match error.as_db_error() {
        Some(db) => format!("{}: {}", db.code().code(), db.message()),
        None => error.to_string(),
    }
}

// ---------------------------------------------------------------------------------------
// StarRocks

async fn sr_exec(conn: &mut mysql_async::Conn, sql: &str) -> Result<()> {
    conn.query_drop(sql)
        .await
        .with_context(|| format!("StarRocks statement failed:\n{sql}"))
}

async fn sr_rows(conn: &mut mysql_async::Conn, sql: &str) -> Result<Vec<Row>> {
    use mysql_async::consts::ColumnType as C;
    let mut result = conn.query_iter(sql).await?;
    let columns = result.columns().map(|c| c.to_vec()).unwrap_or_default();
    let raw: Vec<mysql_async::Row> = result.collect().await?;
    let mut rows = Vec::with_capacity(raw.len());
    for row in raw {
        let mut map = Row::new();
        for (index, column) in columns.iter().enumerate() {
            let value: mysql_async::Value = row
                .as_ref(index)
                .cloned()
                .unwrap_or(mysql_async::Value::NULL);
            let json = match value {
                mysql_async::Value::NULL => Value::Null,
                mysql_async::Value::Bytes(bytes) => {
                    let text = String::from_utf8_lossy(&bytes).to_string();
                    let numeric = matches!(
                        column.column_type(),
                        C::MYSQL_TYPE_TINY
                            | C::MYSQL_TYPE_SHORT
                            | C::MYSQL_TYPE_LONG
                            | C::MYSQL_TYPE_LONGLONG
                            | C::MYSQL_TYPE_INT24
                            | C::MYSQL_TYPE_FLOAT
                            | C::MYSQL_TYPE_DOUBLE
                            | C::MYSQL_TYPE_DECIMAL
                            | C::MYSQL_TYPE_NEWDECIMAL
                    );
                    match (numeric, text.parse::<f64>()) {
                        (true, Ok(number)) if number.is_finite() => Value::from(number),
                        _ => Value::String(text),
                    }
                }
                mysql_async::Value::Int(i) => Value::from(i as f64),
                mysql_async::Value::UInt(u) => Value::from(u as f64),
                mysql_async::Value::Float(f) => Value::from(f as f64),
                mysql_async::Value::Double(d) => Value::from(d),
                other => Value::String(other.as_sql(true)),
            };
            map.insert(column.name_str().to_string(), json);
        }
        rows.push(map);
    }
    Ok(rows)
}

async fn sr_sweep(conn: &mut mysql_async::Conn, now: DateTime<Utc>) -> Result<Vec<String>> {
    let names: Vec<String> = conn.query("SHOW DATABASES").await?;
    let mut dropped = Vec::new();
    for name in names {
        if let Some(created) = run_database_created(&name)
            && now - created > chrono::Duration::hours(STALE_AFTER_HOURS)
        {
            sr_exec(conn, &format!("DROP DATABASE IF EXISTS {name} FORCE")).await?;
            dropped.push(name);
        }
    }
    Ok(dropped)
}

async fn sr_create(conn: &mut mysql_async::Conn, database: &str, ddl_dir: &Path) -> Result<()> {
    assert!(run_database_created(database).is_some());
    sr_exec(conn, &format!("CREATE DATABASE {database}")).await?;
    let mut files: Vec<_> = std::fs::read_dir(ddl_dir)
        .with_context(|| format!("reading {}", ddl_dir.display()))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "sql"))
        .collect();
    files.sort();
    if files.is_empty() {
        bail!("no StarRocks DDL under {}", ddl_dir.display());
    }
    for file in files {
        let sql = std::fs::read_to_string(&file)?;
        for statement in schema::starrocks_statements(&sql) {
            let statement = schema::starrocks_retarget(&statement, database, 1);
            if let Some((table, column)) = schema::starrocks_add_column(&statement) {
                let exists: Option<i64> = conn
                    .query_first(format!(
                        "SELECT 1 FROM information_schema.columns WHERE table_schema = '{database}' \
                         AND table_name = '{table}' AND column_name = '{column}'"
                    ))
                    .await?;
                if exists.is_some() {
                    continue;
                }
            }
            sr_exec(conn, &statement)
                .await
                .with_context(|| format!("applying {}", file.display()))?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------
// The run

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Pass(String),
    Fail(String),
}

struct Translated {
    cnpg: srql::error::Result<srql::TranslateResponse>,
    starrocks: srql::error::Result<srql::TranslateResponse>,
}

fn translate(query: &str, starrocks_database: &str) -> Translated {
    let mut config = srql::config::AppConfig::embedded("postgres://parity.invalid/unused".into());
    config.starrocks_database = starrocks_database.to_string();
    let request = |mode: Option<&str>| QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: mode.map(str::to_string),
        permitted_signals: None,
    };
    Translated {
        cnpg: srql::query::translate_request(&config, request(None)),
        starrocks: srql::query::translate_request(&config, request(Some("starrocks"))),
    }
}

/// The columns an entry's query orders by, as result column names.
fn order_keys(entry: &Entry, query: &str) -> Vec<String> {
    if !entry.is_ordered() {
        return Vec::new();
    }
    let shape = entry.shape();
    if shape.clauses.contains_key("bucket") {
        return vec!["timestamp".into()];
    }
    // A stats query grouped by a time bucket is returned in bucket order on both backends;
    // its `sort:` only picks which buckets survive the limit.
    if shape
        .clauses
        .get("stats")
        .is_some_and(|stats| stats.contains("time:"))
    {
        return vec!["bucket".into()];
    }
    crate::shape::tokenize(query)
        .into_iter()
        .filter(|t| t.key == "sort")
        .flat_map(|t| {
            t.value
                .split(',')
                .map(|part| part.split(':').next().unwrap_or("").to_string())
                .collect::<Vec<_>>()
        })
        .filter(|k| !k.is_empty())
        .collect()
}

#[allow(clippy::too_many_arguments)]
async fn run_entry(
    inventory: &Inventory,
    entry: &Entry,
    anchor: Anchor,
    database: &str,
    cnpg: &tokio_postgres::Client,
    sr: &mut mysql_async::Conn,
    detail: &mut String,
) -> Outcome {
    let mut query = entry.query.clone();
    for (placeholder, window) in anchor.windows() {
        query = query.replace(placeholder, &window);
    }
    let _ = writeln!(detail, "\n=== {}\n{query}", entry.id);
    let translated = translate(&query, database);
    let sr_sql = match (&translated.starrocks, entry.expect) {
        (Err(err), Expect::StarrocksRefuses) => {
            let _ = writeln!(detail, "starrocks refuses (expected): {err}");
            return Outcome::Pass(format!("starrocks refuses: {err}"));
        }
        (Ok(ok), Expect::StarrocksRefuses) => {
            let _ = writeln!(detail, "starrocks SQL:\n{}", ok.sql);
            return Outcome::Fail(
                "expected the StarRocks dialect to refuse this shape, and it now compiles: \
                 compare it and change the entry"
                    .into(),
            );
        }
        (Err(err), _) => return Outcome::Fail(format!("StarRocks dialect refused: {err}")),
        (Ok(ok), _) => ok.sql.clone(),
    };
    let cnpg_tr = match (&translated.cnpg, entry.expect) {
        (Err(err), Expect::CnpgRefuses) => {
            let _ = writeln!(
                detail,
                "cnpg refuses (expected): {err}\nstarrocks SQL:\n{sr_sql}"
            );
            if sr_sql.contains(CNPG_CATALOG_REFERENCE) {
                return Outcome::Fail("the StarRocks SQL reads the cnpg_platform catalog".into());
            }
            return match sr_rows(sr, &sr_sql).await {
                Ok(rows) if !rows.is_empty() => {
                    let _ = writeln!(
                        detail,
                        "starrocks rows ({}), no reference to compare",
                        rows.len()
                    );
                    Outcome::Pass(format!(
                        "cnpg refuses ({err}); starrocks ran, {} rows, not compared",
                        rows.len()
                    ))
                }
                Ok(_) => Outcome::Fail("cnpg refuses and starrocks returned no rows".into()),
                Err(err) => Outcome::Fail(format!("StarRocks execution failed: {err:#}")),
            };
        }
        (Ok(_), Expect::CnpgRefuses) => {
            return Outcome::Fail(
                "recorded as a shape CNPG refuses, and CNPG now compiles it: compare it".into(),
            );
        }
        (Ok(ok), _) => ok,
        (Err(err), _) => return Outcome::Fail(format!("CNPG dialect refused: {err}")),
    };
    let _ = writeln!(
        detail,
        "cnpg SQL:\n{}\nparams: {:?}",
        cnpg_tr.sql, cnpg_tr.params
    );
    let _ = writeln!(detail, "starrocks SQL:\n{sr_sql}");
    if sr_sql.contains(CNPG_CATALOG_REFERENCE) {
        return Outcome::Fail(
            "the StarRocks SQL reads the cnpg_platform JDBC catalog, which points at a live \
             deployment, so the harness will not run it; give the fixture a shape that does \
             not need the catalog"
                .into(),
        );
    }
    let cnpg_rows = match cnpg_rows(cnpg, &cnpg_tr.sql, &cnpg_tr.params).await {
        Ok(rows) => rows,
        Err(err) => return Outcome::Fail(format!("CNPG execution failed: {err:#}")),
    };
    let sr_rows = match sr_rows(sr, &sr_sql).await {
        Ok(rows) => rows,
        Err(err) => return Outcome::Fail(format!("StarRocks execution failed: {err:#}")),
    };
    let cnpg_rows: Vec<Row> = cnpg_rows
        .into_iter()
        .map(|row| {
            compare::flatten_payload(row)
                .into_iter()
                .map(|(k, v)| (entry.cnpg_rename.get(&k).cloned().unwrap_or(k), v))
                .collect()
        })
        .collect();
    let cnpg_rows = compare::normalize_rows(cnpg_rows, &entry.ignore_columns);
    let sr_rows = compare::normalize_rows(sr_rows, &entry.ignore_columns);
    let tolerance = Tolerance {
        relative: DEFAULT_RELATIVE_TOLERANCE,
        absolute: DEFAULT_ABSOLUTE_TOLERANCE,
        wide_columns: entry
            .tolerance
            .as_ref()
            .map(|t| t.columns.clone())
            .unwrap_or_default(),
        wide: entry.tolerance.as_ref().map(|t| t.relative).unwrap_or(0.0),
    };
    let keys = order_keys(entry, &query);
    let verdict = compare::compare(&cnpg_rows, &sr_rows, &keys, &tolerance);
    let render = |rows: &[Row]| {
        rows.iter()
            .take(40)
            .map(|r| Value::Object(r.clone()).to_string())
            .collect::<Vec<_>>()
            .join("\n  ")
    };
    let _ = writeln!(
        detail,
        "cnpg rows ({}):\n  {}\nstarrocks rows ({}):\n  {}",
        cnpg_rows.len(),
        render(&cnpg_rows),
        sr_rows.len(),
        render(&sr_rows)
    );
    let reason = entry
        .deviation(inventory)
        .map(|d| d.reason.as_str())
        .unwrap_or("");
    match (verdict, entry.expect) {
        (Verdict::Equal, Expect::Match) if cnpg_rows.is_empty() && !entry.allow_empty => {
            Outcome::Fail(
                "both backends returned no rows: the fixture does not exercise this shape".into(),
            )
        }
        (Verdict::Equal, Expect::Match) => Outcome::Pass(format!("{} rows equal", cnpg_rows.len())),
        (Verdict::Different(diff), Expect::Match) => {
            Outcome::Fail(format!("results differ:\n    {diff}"))
        }
        (Verdict::Different(diff), Expect::Mismatch) => {
            let observed = Recorded {
                cnpg: compare::relative_to(cnpg_rows, anchor.0),
                starrocks: compare::relative_to(sr_rows, anchor.0),
            };
            match pinned_difference(entry.recorded.as_ref(), &observed, &keys, &tolerance) {
                Ok(()) => Outcome::Pass(format!(
                    "differs as recorded ({}): {}",
                    entry.deviation.as_deref().unwrap_or("?"),
                    diff.lines().next().unwrap_or("")
                )),
                Err(why) => Outcome::Fail(why),
            }
        }
        (Verdict::Equal, Expect::Mismatch) => Outcome::Fail(format!(
            "recorded as a mismatch ({reason}) but the backends now agree: make it a match"
        )),
        (_, Expect::StarrocksRefuses | Expect::CnpgRefuses) => unreachable!("handled above"),
    }
}

/// The rows an `expect: mismatch` entry must still return on each backend. `Err` says which side
/// moved, or, when nothing is recorded yet, the `recorded` block to add to the entry.
fn pinned_difference(
    recorded: Option<&Recorded>,
    observed: &Recorded,
    order_keys: &[String],
    tolerance: &Tolerance,
) -> Result<(), String> {
    let Some(recorded) = recorded else {
        return Err(format!(
            "the backends differ, but the entry pins no rows, so any difference would pass; \
             record what they return now, if that is the deviation the entry describes: \
             \"recorded\": {}",
            serde_json::to_string(observed).unwrap_or_default()
        ));
    };
    for (side, seen, pinned) in [
        ("cnpg", &observed.cnpg, &recorded.cnpg),
        ("starrocks", &observed.starrocks, &recorded.starrocks),
    ] {
        if let Verdict::Different(diff) = compare::compare(seen, pinned, order_keys, tolerance) {
            return Err(format!(
                "{side} no longer returns the recorded rows (observed on the left, recorded on \
                 the right):\n    {diff}"
            ));
        }
    }
    Ok(())
}

async fn seed(
    anchor: Anchor,
    database: &str,
    cnpg: &tokio_postgres::Client,
    sr: &mut mysql_async::Conn,
) -> Result<()> {
    let metrics = fixture::metrics(anchor);
    let flows = fixture::flows(anchor);
    let logs = fixture::logs::logs(anchor);
    let events = fixture::events::events(anchor);
    let (traces, hops) = fixture::mtr::traces_and_hops(anchor);

    let cnpg_statements = [
        fixture::metric_inserts(&metrics, Backend::Cnpg, "platform"),
        fixture::flow_inserts(&flows, Backend::Cnpg, "platform"),
        fixture::logs::inserts(&logs, Backend::Cnpg, "platform"),
        fixture::events::inserts(&events, Backend::Cnpg, "platform"),
        fixture::mtr::trace_inserts(&traces, Backend::Cnpg, "platform"),
        fixture::mtr::hop_inserts(&hops, Backend::Cnpg, "platform"),
    ];
    for statement in cnpg_statements.iter().flatten() {
        cnpg.batch_execute(statement)
            .await
            .map_err(|e| anyhow!("CNPG seed: {}", describe_pg_error(&e)))?;
    }
    for cagg in schema::CNPG_CONTINUOUS_AGGREGATES {
        cnpg.batch_execute(&format!(
            "CALL refresh_continuous_aggregate('{cagg}', NULL, NULL)"
        ))
        .await
        .map_err(|e| anyhow!("refresh {cagg}: {}", describe_pg_error(&e)))?;
    }

    let sr_statements = [
        fixture::metric_inserts(&metrics, Backend::StarRocks, database),
        fixture::flow_inserts(&flows, Backend::StarRocks, database),
        fixture::logs::inserts(&logs, Backend::StarRocks, database),
        fixture::events::inserts(&events, Backend::StarRocks, database),
        fixture::mtr::trace_inserts(&traces, Backend::StarRocks, database),
        fixture::mtr::hop_inserts(&hops, Backend::StarRocks, database),
    ];
    for statement in sr_statements.iter().flatten() {
        sr_exec(sr, statement).await?;
    }
    for view in schema::STARROCKS_MATERIALIZED_VIEWS {
        sr_exec(
            sr,
            &format!("REFRESH MATERIALIZED VIEW {database}.{view} WITH SYNC MODE"),
        )
        .await?;
    }

    // Row counts, so a silently filtered load cannot pass as agreement.
    for (table, cnpg_table, expected) in [
        ("timeseries_metrics", "timeseries_metrics", metrics.len()),
        (
            "ocsf_network_activity",
            "ocsf_network_activity",
            flows.len(),
        ),
        ("logs", "logs", logs.len()),
        ("events", "ocsf_events", events.len()),
        ("mtr_traces", "mtr_traces", traces.len()),
        ("mtr_hops", "mtr_hops", hops.len()),
    ] {
        let sr_count: Option<i64> = sr
            .query_first(format!("SELECT COUNT(*) FROM {database}.{table}"))
            .await?;
        let cnpg_count: i64 = cnpg
            .query_one(&format!("SELECT COUNT(*) FROM platform.{cnpg_table}"), &[])
            .await?
            .get(0);
        if sr_count != Some(expected as i64) || cnpg_count != expected as i64 {
            bail!(
                "{table}: seeded {expected} rows, StarRocks holds {sr_count:?}, CNPG holds {cnpg_count}"
            );
        }
    }
    Ok(())
}

/// Runs the whole harness. Returns the per-entry report; an `Err` is a setup failure.
pub async fn run() -> Result<Vec<(String, Outcome)>> {
    let settings = Settings::from_env()?;
    let inventory = Inventory::load();
    let root = crate::repo_root();
    let baseline = std::fs::read_to_string(
        root.join("elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql"),
    )
    .context("reading the CNPG baseline")?;
    let ddl_dir = root.join("elixir/serviceradar_core/priv/starrocks");

    let now = Utc::now();
    let anchor = Anchor::for_run(now);
    let database = run_database_name(now, std::process::id());
    println!(
        "srql-parity: run database {database}, fixture anchor {}",
        anchor.0
    );

    let pool = mysql_async::Pool::new(settings.starrocks.clone());
    let mut sr = pool.get_conn().await.context("connecting to StarRocks")?;
    let version: Option<String> = sr.query_first("SELECT current_version()").await?;
    let zone: Option<(String, String)> = sr.query_first("SHOW VARIABLES LIKE 'time_zone'").await?;
    println!("srql-parity: StarRocks {version:?}, session {zone:?}");
    let cnpg = Cnpg {
        settings: &settings,
    };
    let swept_sr = sr_sweep(&mut sr, now).await?;
    let swept_pg = cnpg.sweep(now).await?;
    if !swept_sr.is_empty() || !swept_pg.is_empty() {
        println!("srql-parity: swept stale databases {swept_sr:?} {swept_pg:?}");
    }

    let result = async {
        sr_create(&mut sr, &database, &ddl_dir).await?;
        let client = cnpg.create(&database, &baseline).await?;
        let zone: String = client.query_one("SHOW TimeZone", &[]).await?.get(0);
        println!("srql-parity: CNPG session TimeZone {zone}");
        seed(anchor, &database, &client, &mut sr).await?;

        let mut detail = String::new();
        let mut outcomes = Vec::new();
        for entry in &inventory.entries {
            if let Some(only) = &settings.only
                && !entry.id.contains(only.as_str())
            {
                continue;
            }
            let outcome = run_entry(
                &inventory,
                entry,
                anchor,
                &database,
                &client,
                &mut sr,
                &mut detail,
            )
            .await;
            let _ = writeln!(detail, "outcome: {outcome:?}");
            outcomes.push((entry.id.clone(), outcome));
        }
        write_detail(&detail);
        Ok::<_, anyhow::Error>(outcomes)
    }
    .await;

    if settings.keep {
        println!("srql-parity: SRQL_PARITY_KEEP=1, leaving {database} on both backends");
    } else {
        let sr_drop = sr_exec(
            &mut sr,
            &format!("DROP DATABASE IF EXISTS {database} FORCE"),
        )
        .await;
        let pg_drop = cnpg.drop(&database).await;
        // A DROP that returned OK is not evidence the database is gone: list both again.
        let verified = async {
            sr_drop?;
            pg_drop?;
            let sr_left: Vec<String> = sr.query("SHOW DATABASES").await?;
            let pg_left = cnpg
                .connect(None)
                .await?
                .query("SELECT 1 FROM pg_database WHERE datname = $1", &[&database])
                .await?;
            if sr_left.contains(&database) || !pg_left.is_empty() {
                bail!("{database} is still listed after its DROP");
            }
            Ok::<_, anyhow::Error>(())
        }
        .await;
        match verified {
            Ok(()) => {
                println!("srql-parity: dropped {database}; re-listed, absent on both backends")
            }
            Err(err) => {
                eprintln!("srql-parity: cleanup of {database} failed: {err:#}");
                if result.is_ok() {
                    drop(sr);
                    let _ = pool.disconnect().await;
                    return Err(err.context("cleanup"));
                }
            }
        }
    }
    drop(sr);
    let _ = pool.disconnect().await;
    result
}

/// Full SQL and rows per entry, into Bazel's undeclared outputs when available.
fn write_detail(detail: &str) {
    let dir = std::env::var("TEST_UNDECLARED_OUTPUTS_DIR")
        .ok()
        .unwrap_or_else(|| std::env::temp_dir().to_string_lossy().to_string());
    let path = Path::new(&dir).join("srql_parity_detail.txt");
    if std::fs::write(&path, detail).is_ok() {
        println!("srql-parity: per-entry SQL and rows in {}", path.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_run_database_names_are_ever_candidates_for_a_drop() {
        let now = DateTime::parse_from_rfc3339("2030-03-04T15:16:17Z")
            .unwrap()
            .with_timezone(&Utc);
        let name = run_database_name(now, 4242);
        assert_eq!(name, "srql_parity_20300304151617_4242");
        assert_eq!(run_database_created(&name), Some(now));
        for other in [
            "serviceradar",
            "srql_parity_",
            "srql_parity_2030030415161_1",
            "srql_parity_20300304151617_",
            "srql_parity_20300304151617_1; DROP DATABASE serviceradar",
            "srql_parity_20300304151617_1_x",
            "xsrql_parity_20300304151617_1",
        ] {
            assert_eq!(run_database_created(other), None, "{other}");
        }
    }

    fn recorded(cnpg: Value, starrocks: Value) -> Recorded {
        let rows = |value: Value| -> Vec<Row> {
            value
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r.as_object().unwrap().clone())
                .collect()
        };
        Recorded {
            cnpg: rows(cnpg),
            starrocks: rows(starrocks),
        }
    }

    fn exact() -> Tolerance {
        Tolerance {
            relative: DEFAULT_RELATIVE_TOLERANCE,
            absolute: DEFAULT_ABSOLUTE_TOLERANCE,
            wide_columns: Vec::new(),
            wide: 0.0,
        }
    }

    #[test]
    fn a_recorded_deviation_passes_only_while_both_sides_return_the_recorded_rows() {
        use serde_json::json;
        let pinned = recorded(
            json!([{"label": "", "flows": 3}]),
            json!([{"label": "none", "flows": 3}]),
        );
        let keys = ["flows".to_string()];
        assert!(pinned_difference(Some(&pinned), &pinned, &keys, &exact()).is_ok());

        // Same difference in kind, new wrong count on the warehouse: the entry must fail.
        let regressed = recorded(
            json!([{"label": "", "flows": 3}]),
            json!([{"label": "none", "flows": 2}]),
        );
        let why = pinned_difference(Some(&pinned), &regressed, &keys, &exact()).unwrap_err();
        assert!(why.starts_with("starrocks no longer returns"), "{why}");

        let moved = recorded(
            json!([{"label": "", "flows": 4}]),
            json!([{"label": "none", "flows": 3}]),
        );
        let why = pinned_difference(Some(&pinned), &moved, &keys, &exact()).unwrap_err();
        assert!(why.starts_with("cnpg no longer returns"), "{why}");
    }

    #[test]
    fn an_unpinned_mismatch_fails_and_says_what_to_record() {
        use serde_json::json;
        let observed = recorded(json!([{"v": 1}]), json!([{"v": 2}]));
        let why = pinned_difference(None, &observed, &[], &exact()).unwrap_err();
        assert!(
            why.contains("\"recorded\": {\"cnpg\":[{\"v\":1}],\"starrocks\":[{\"v\":2}]}"),
            "{why}"
        );
    }
}
