//! Endpoint SBOM inventory rows: per-device packages, the normalized package
//! catalog, and inventory scan freshness state.

use crate::jsonb::DbJson;
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use serde::Serialize;
use uuid::Uuid;

/// Endpoint package inventory row collected by the native endpoint inventory add-on.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_inventory_packages,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointPackageRow {
    pub id: Uuid,
    pub scan_ref: Uuid,
    pub device_uid: Option<String>,
    pub agent_id: String,
    pub name: String,
    pub version: Option<String>,
    pub architecture: Option<String>,
    pub package_manager: String,
    pub ecosystem: Option<String>,
    pub purl: Option<String>,
    pub purl_canonical: String,
    pub endpoint_package_ref: Uuid,
    pub cpes: Vec<String>,
    pub supplier: Option<String>,
    pub license: Option<String>,
    pub source: Option<String>,
    pub evidence: DbJson,
    pub current: bool,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointPackageRow {
    pub fn into_json(self) -> serde_json::Value {
        let device_uid = self.device_uid;
        let device_id = device_uid.clone();
        let manager = self.package_manager.clone();
        let canonical_purl = self.purl_canonical.clone();

        serde_json::json!({
            "id": self.id.to_string(),
            "scan_ref": self.scan_ref.to_string(),
            "device_uid": device_uid,
            "device_id": device_id,
            "agent_id": self.agent_id,
            "name": self.name,
            "version": self.version,
            "architecture": self.architecture,
            "package_manager": self.package_manager,
            "manager": manager,
            "ecosystem": self.ecosystem,
            "purl": self.purl,
            "purl_canonical": self.purl_canonical,
            "canonical_purl": canonical_purl,
            "endpoint_package_ref": self.endpoint_package_ref.to_string(),
            "package_id": self.endpoint_package_ref.to_string(),
            "has_package": {
                "device_uid": device_id,
                "package_id": self.endpoint_package_ref.to_string(),
                "relation": "HAS_PACKAGE",
            },
            "cpes": self.cpes,
            "supplier": self.supplier,
            "license": self.license,
            "source": self.source,
            "evidence": serde_json::Value::from(self.evidence),
            "current": self.current,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

/// Normalized endpoint-side package coordinate catalog row.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_packages,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointPackageCatalogRow {
    pub id: Uuid,
    pub coordinate_key: String,
    pub purl_canonical: Option<String>,
    pub primary_cpe: Option<String>,
    pub cpes: Vec<String>,
    pub package_manager: String,
    pub name: String,
    pub version: Option<String>,
    pub architecture: Option<String>,
    pub ecosystem: Option<String>,
    pub source_scope: String,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointPackageCatalogRow {
    pub fn into_json(self) -> serde_json::Value {
        let canonical_purl = self.purl_canonical.clone();

        serde_json::json!({
            "id": self.id.to_string(),
            "package_id": self.id.to_string(),
            "coordinate_key": self.coordinate_key,
            "purl_canonical": self.purl_canonical,
            "canonical_purl": canonical_purl,
            "primary_cpe": self.primary_cpe,
            "cpes": self.cpes,
            "package_manager": self.package_manager,
            "manager": self.package_manager,
            "name": self.name,
            "version": self.version,
            "architecture": self.architecture,
            "ecosystem": self.ecosystem,
            "source_scope": self.source_scope,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

/// Endpoint inventory scan metadata and freshness state.
#[derive(Debug, Clone, Queryable, Selectable, Serialize)]
#[diesel(
    table_name = crate::schema::endpoint_inventory_scans,
    check_for_backend(diesel::pg::Pg)
)]
pub struct EndpointInventoryScanRow {
    pub id: Uuid,
    pub device_uid: Option<String>,
    pub agent_id: String,
    pub scan_id: String,
    pub collector_name: Option<String>,
    pub collector_version: Option<String>,
    pub state: String,
    pub coverage_state: String,
    pub package_count: i32,
    pub enabled_sources: Vec<String>,
    pub manager_counts: DbJson,
    pub source_summaries: Vec<DbJson>,
    pub artifact_count: i32,
    pub current: bool,
    pub last_successful_scan_at: Option<DateTime<Utc>>,
    pub last_scan_at: Option<DateTime<Utc>>,
    pub last_changed_scan_at: Option<DateTime<Utc>>,
    pub ingested_at: Option<DateTime<Utc>>,
    pub package_set_hash: Option<String>,
    pub artifact_hash: Option<String>,
    pub hash_algorithm: Option<String>,
    pub upload_reason: Option<String>,
    pub server_package_set_hash: Option<String>,
    pub package_set_hash_mismatch: bool,
    pub unchanged_scan_count: i32,
    pub reconcile_floor_due: bool,
    pub metadata: DbJson,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl EndpointInventoryScanRow {
    pub fn into_json(self) -> serde_json::Value {
        let device_uid = self.device_uid;
        let device_id = device_uid.clone();
        let freshness = endpoint_inventory_freshness(self.last_successful_scan_at);
        let freshness_verdict = freshness
            .get("verdict")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string();

        serde_json::json!({
            "id": self.id.to_string(),
            "device_uid": device_uid,
            "device_id": device_id,
            "agent_id": self.agent_id,
            "scan_id": self.scan_id,
            "collector_name": self.collector_name,
            "collector_version": self.collector_version,
            "state": self.state,
            "coverage_state": self.coverage_state,
            "package_count": self.package_count,
            "enabled_sources": self.enabled_sources,
            "manager_counts": serde_json::Value::from(self.manager_counts),
            "source_summaries": self.source_summaries.into_iter().map(serde_json::Value::from).collect::<Vec<_>>(),
            "artifact_count": self.artifact_count,
            "current": self.current,
            "last_successful_scan_at": self.last_successful_scan_at,
            "last_scan_at": self.last_scan_at,
            "last_changed_scan_at": self.last_changed_scan_at,
            "ingested_at": self.ingested_at,
            "package_set_hash": self.package_set_hash,
            "artifact_hash": self.artifact_hash,
            "hash_algorithm": self.hash_algorithm,
            "upload_reason": self.upload_reason,
            "server_package_set_hash": self.server_package_set_hash,
            "package_set_hash_mismatch": self.package_set_hash_mismatch,
            "unchanged_scan_count": self.unchanged_scan_count,
            "reconcile_floor_due": self.reconcile_floor_due,
            "freshness_verdict": freshness_verdict,
            "freshness": freshness,
            "metadata": serde_json::Value::from(self.metadata),
            "inserted_at": self.inserted_at,
            "updated_at": self.updated_at,
        })
    }
}

const ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS: i64 = 26 * 60 * 60;

fn endpoint_inventory_freshness(
    last_successful_scan_at: Option<DateTime<Utc>>,
) -> serde_json::Value {
    let Some(last_successful) = last_successful_scan_at else {
        return serde_json::json!({
            "verdict": "unknown",
            "age_seconds": null,
            "stale_threshold_seconds": ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS,
            "last_successful_scan_at": null,
        });
    };

    let age_seconds = (Utc::now() - last_successful).num_seconds().max(0);
    let verdict = if age_seconds > ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS {
        "stale"
    } else {
        "fresh"
    };

    serde_json::json!({
        "verdict": verdict,
        "age_seconds": age_seconds,
        "stale_threshold_seconds": ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS,
        "last_successful_scan_at": last_successful,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn endpoint_inventory_freshness_allows_daily_timer_grace() {
        let now = Utc::now();
        let fresh = endpoint_inventory_freshness(Some(now - Duration::hours(25)));
        let stale = endpoint_inventory_freshness(Some(now - Duration::hours(27)));

        assert_eq!(
            fresh["stale_threshold_seconds"],
            ENDPOINT_INVENTORY_STALE_THRESHOLD_SECONDS
        );
        assert_eq!(fresh["verdict"], "fresh");
        assert_eq!(stale["verdict"], "stale");
    }
}
