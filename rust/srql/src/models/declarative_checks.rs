//! Declarative check instance verdict rows.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;
use uuid::Uuid;

/// One target's materialized verdict for one declarative check, joined to
/// `declarative_checks` so callers get `check_slug`, `check_name`, and `state`
/// alongside the per-target verdict and redacted `node_snapshots`.
///
/// Column order here must match `select_tuple()` in
/// `query/declarative_check_results.rs`.
#[derive(Debug, Clone, Queryable, Serialize)]
pub struct DeclarativeCheckResultRow {
    pub id: Uuid,
    pub check_id: Uuid,
    pub check_slug: String,
    pub check_name: String,
    pub state: String,
    pub target_key: String,
    pub target_kind: String,
    pub device_uid: Option<String>,
    pub service_target_id: Option<String>,
    pub verdict: String,
    pub status: String,
    pub summary: Option<String>,
    pub node_snapshots: DbJson,
    pub evaluated_at: DateTime<Utc>,
    pub changed_at: DateTime<Utc>,
}

impl DeclarativeCheckResultRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id,
            "check_id": self.check_id,
            "check_slug": self.check_slug,
            "check_name": self.check_name,
            "state": self.state,
            "target_key": self.target_key,
            "target_kind": self.target_kind,
            "device_uid": self.device_uid,
            "service_target_id": self.service_target_id,
            "verdict": self.verdict,
            "status": self.status,
            "summary": self.summary,
            "node_snapshots": self.node_snapshots,
            "evaluated_at": self.evaluated_at,
            "changed_at": self.changed_at,
        })
    }
}
