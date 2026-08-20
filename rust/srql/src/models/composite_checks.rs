//! Composite check verdict rows.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;
use uuid::Uuid;

/// One device's current verdict for one composite check, joined to the check so
/// callers get the slug and name rather than an opaque id.
///
/// Selected via an explicit join rather than `Selectable`, because the row spans
/// two tables. Column order here must match the `.select(...)` tuple in
/// `query/composite_results.rs`.
#[derive(Debug, Clone, Queryable, Serialize)]
pub struct CompositeResultRow {
    pub device_uid: String,
    pub check_id: Uuid,
    pub check_slug: String,
    pub check_name: String,
    pub verdict: String,
    pub status: String,
    pub matched_rule_id: Option<Uuid>,
    pub inputs: DbJson,
    pub evaluated_at: DateTime<Utc>,
    pub changed_at: DateTime<Utc>,
}

impl CompositeResultRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "device_uid": self.device_uid,
            "check_id": self.check_id,
            "check_slug": self.check_slug,
            "check_name": self.check_name,
            "verdict": self.verdict,
            "status": self.status,
            "matched_rule_id": self.matched_rule_id,
            "inputs": self.inputs,
            "evaluated_at": self.evaluated_at,
            "changed_at": self.changed_at,
        })
    }
}
