//! Storage contract checks against the production DDL in the runner's disposable warehouse.
//! These do not claim to test conditional Stream Load or the transition consumer.

use anyhow::{Result, ensure};
use mysql_async::{
    Conn,
    prelude::{FromRow, FromValue, Queryable},
};
use std::path::Path;

use crate::schema;

pub(crate) async fn verify(conn: &mut Conn, database: &str, ddl_dir: &Path) -> Result<()> {
    conn.query_drop(format!(
        "INSERT INTO {database}.exposure_facts \
         (device_ord, cve_ord, pkg_ord, pkgver_ord, state, updated_at, transition_seq, transition_xid) \
         VALUES (2147483648, 1000000000000, 41, 51, 1, NOW(), 11, 101), \
                (4294967295, 1000000000000, 41, 52, 1, NOW(), 12, 102)"
    ))
    .await?;
    let initial: Vec<(i64, i64, i64, i64)> = conn
        .query(format!(
            "SELECT device_ord, cve_ord, pkgver_ord, snapshot_generation \
             FROM {database}.exposure_facts ORDER BY device_ord"
        ))
        .await?;
    ensure!(
        initial
            == vec![
                (2147483648, 1000000000000, 51, 0),
                (4294967295, 1000000000000, 52, 0)
            ],
        "large ordinals or default snapshot markers changed: {initial:?}"
    );

    // A version change replaces the fact at the version-independent identity key.
    conn.query_drop(format!(
        "INSERT INTO {database}.exposure_facts \
         (device_ord, cve_ord, pkg_ord, pkgver_ord, state, source_scope, updated_at, \
          transition_seq, transition_xid, snapshot_generation) \
         VALUES (2147483648, 1000000000000, 41, 53, 0, 'host', NOW(), 13, 103, 7)"
    ))
    .await?;
    // Tombstone payload compaction must leave the permanent key and ordering markers.
    conn.query_drop(format!(
        "UPDATE {database}.exposure_facts SET source_scope = NULL, severity_rank = NULL, \
         cvss_score = NULL, kev = NULL, exploit_available = NULL, fix_available = NULL, \
         first_exposed_at = NULL, resolved_at = NULL WHERE device_ord = 2147483648"
    ))
    .await?;

    conn.query_drop(format!(
        "INSERT INTO {database}.exposure_package_dim \
         (pkgver_ord, pkg_ord, package_identity_key, package_name, installed_version, updated_at) VALUES \
         (52, 41, 'synthetic:example-package', 'example-package', '1.0', NOW()), \
         (53, 41, 'synthetic:example-package', 'example-package', '2.0', NOW())"
    ))
    .await?;
    conn.query_drop(format!(
        "INSERT INTO {database}.exposure_cve_dim (cve_ord, cve_id, epss_score, updated_at) VALUES \
         (1000000000000, 'EXAMPLE-ADVISORY-1', NULL, NOW())"
    ))
    .await?;
    // Equal duplicate keys must retain both transitions, rather than upsert history.
    conn.query_drop(format!(
        "INSERT INTO {database}.exposure_transitions_log VALUES \
         (CURRENT_DATE(), 2147483648, 1000000000000, 41, 11, 101, 51, 1, \
          CURRENT_DATE(), NULL, PARSE_JSON('{{\"reason\":\"created\"}}')), \
         (CURRENT_DATE(), 2147483648, 1000000000000, 41, 13, 103, 53, 0, \
          CURRENT_DATE(), NOW(), PARSE_JSON('{{\"reason\":\"resolved\"}}'))"
    ))
    .await?;

    // Execute the real migration again with data present: startup replay must preserve it.
    let sql = std::fs::read_to_string(ddl_dir.join("0032_exposure_facts.sql"))?;
    for statement in schema::starrocks_statements(&sql) {
        conn.query_drop(schema::starrocks_retarget(&statement, database, 1))
            .await?;
    }

    let facts: Vec<StoredFact> = conn
        .query(format!(
            "SELECT device_ord, pkgver_ord, state, transition_seq, transition_xid, \
             snapshot_generation, source_scope FROM {database}.exposure_facts ORDER BY device_ord"
        ))
        .await?;
    ensure!(
        facts
            == vec![
                StoredFact {
                    device_ord: 2147483648,
                    pkgver_ord: 53,
                    state: 0,
                    transition_seq: 13,
                    transition_xid: 103,
                    snapshot_generation: 7,
                    source_scope: None,
                },
                StoredFact {
                    device_ord: 4294967295,
                    pkgver_ord: 52,
                    state: 1,
                    transition_seq: 12,
                    transition_xid: 102,
                    snapshot_generation: 0,
                    source_scope: None,
                },
            ],
        "version replacement, terminal marker retention, or DDL replay failed: {facts:?}"
    );
    let versions: Vec<String> = conn
        .query(format!(
            "SELECT p.installed_version FROM {database}.exposure_facts f \
             JOIN {database}.exposure_package_dim p ON p.pkgver_ord = f.pkgver_ord \
             AND p.pkg_ord = f.pkg_ord ORDER BY f.device_ord"
        ))
        .await?;
    ensure!(
        versions == vec!["2.0", "1.0"],
        "package versions collapsed: {versions:?}"
    );
    let advisory: Option<(String, Option<f64>)> = conn
        .query_first(format!(
            "SELECT cve_id, epss_score FROM {database}.exposure_cve_dim WHERE cve_ord = 1000000000000"
        ))
        .await?;
    ensure!(
        advisory == Some(("EXAMPLE-ADVISORY-1".into(), None)),
        "advisory or unavailable EPSS lost"
    );
    let history: Vec<(i64, i8, String)> = conn
        .query(format!(
            "SELECT transition_seq, state, get_json_string(payload, '$.reason') \
             FROM {database}.exposure_transitions_log ORDER BY transition_seq"
        ))
        .await?;
    ensure!(
        history == vec![(11, 1, "created".into()), (13, 0, "resolved".into())],
        "history did not retain both after-images: {history:?}"
    );
    Ok(())
}

/// One `exposure_facts` row after version replacement and DDL replay.
#[derive(Debug, Eq, PartialEq)]
struct StoredFact {
    device_ord: i64,
    pkgver_ord: i64,
    state: i8,
    transition_seq: i64,
    transition_xid: i64,
    snapshot_generation: i64,
    source_scope: Option<String>,
}

impl FromRow for StoredFact {
    fn from_row_opt(row: mysql_async::Row) -> Result<Self, mysql_async::FromRowError> {
        read_stored_fact(&row).ok_or(mysql_async::FromRowError(row))
    }
}

fn read_stored_fact(row: &mysql_async::Row) -> Option<StoredFact> {
    // Column order is the SELECT list in `verify`: device, pkgver, state,
    // transition sequence, transition xid, snapshot generation, source scope.
    Some(StoredFact {
        device_ord: fact_column(row, 0)?,
        pkgver_ord: fact_column(row, 1)?,
        state: fact_column(row, 2)?,
        transition_seq: fact_column(row, 3)?,
        transition_xid: fact_column(row, 4)?,
        snapshot_generation: fact_column(row, 5)?,
        source_scope: fact_column(row, 6)?,
    })
}

fn fact_column<T: FromValue>(row: &mysql_async::Row, index: usize) -> Option<T> {
    row.get_opt(index).and_then(Result::ok)
}
