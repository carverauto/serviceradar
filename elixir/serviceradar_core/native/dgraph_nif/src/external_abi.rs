// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Rustler ABI types for Horizon external topology operations.

use dgraph_topology::{
    ExternalEdgeKind, ExternalEdgeWrite, ExternalNodeKind, ExternalNodeWrite,
    ExternalSnapshotWrite, ExternalStatusPatch, ExternalUpsertStats,
};
use rustler::{NifMap, NifTaggedEnum};

/// Elixir `{:ok, %{nodes_upserted: n, edges_upserted: e, edges_skipped: s}}` / `{:error, reason}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum ExternalUpsertResult {
    Ok(NifExternalUpsertStats),
    Error(String),
}

#[derive(Clone, Copy, Debug, NifMap)]
pub struct NifExternalUpsertStats {
    pub nodes_upserted: u64,
    pub edges_upserted: u64,
    pub edges_skipped: u64,
}

impl From<ExternalUpsertStats> for NifExternalUpsertStats {
    fn from(stats: ExternalUpsertStats) -> Self {
        Self {
            nodes_upserted: stats.nodes_upserted as u64,
            edges_upserted: stats.edges_upserted as u64,
            edges_skipped: stats.edges_skipped as u64,
        }
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifExternalNodeWrite {
    pub id: String,
    pub kind: String,
    pub asn: Option<i64>,
    pub label: Option<String>,
    pub region: Option<String>,
    pub ip: Option<String>,
    pub rpki_state: Option<String>,
    pub rtbh_active: Option<bool>,
    pub max_length: Option<i64>,
    pub irr_status: Option<String>,
    pub metro: Option<String>,
    pub iata: Option<String>,
    pub country_code: Option<String>,
    pub outage_state: Option<String>,
    pub last_seen: String,
    pub expires_at: Option<String>,
}

impl NifExternalNodeWrite {
    pub fn try_into_write(self) -> Result<ExternalNodeWrite, String> {
        let id = self.id.trim().to_string();
        if id.is_empty() {
            return Err("external node id must not be empty".to_string());
        }
        let kind = ExternalNodeKind::parse(&self.kind)
            .ok_or_else(|| format!("unknown external node kind: {}", self.kind))?;
        Ok(ExternalNodeWrite {
            id,
            kind,
            asn: self.asn,
            label: nonempty(self.label),
            region: nonempty(self.region),
            ip: nonempty(self.ip),
            rpki_state: nonempty(self.rpki_state),
            rtbh_active: self.rtbh_active,
            max_length: self.max_length,
            irr_status: nonempty(self.irr_status),
            metro: nonempty(self.metro),
            iata: nonempty(self.iata),
            country_code: nonempty(self.country_code),
            outage_state: nonempty(self.outage_state),
            last_seen: self.last_seen,
            expires_at: nonempty(self.expires_at),
        })
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifExternalEdgeWrite {
    pub src_id: String,
    pub dst_id: String,
    pub kind: String,
    pub border_asn: Option<i64>,
    pub as_boundary_confidence: Option<f64>,
    pub avg_rtt_us: Option<i64>,
    pub loss_pct: Option<f64>,
    pub last_seen: String,
    pub ttl_secs: Option<i64>,
    pub expires_at: Option<String>,
}

impl NifExternalEdgeWrite {
    pub fn try_into_write(self) -> Result<ExternalEdgeWrite, String> {
        let src_id = self.src_id.trim().to_string();
        let dst_id = self.dst_id.trim().to_string();
        if src_id.is_empty() || dst_id.is_empty() {
            return Err("external edge src_id and dst_id must not be empty".to_string());
        }
        let kind = ExternalEdgeKind::parse(&self.kind)
            .ok_or_else(|| format!("unknown external edge kind: {}", self.kind))?;
        Ok(ExternalEdgeWrite {
            src_id,
            dst_id,
            kind,
            border_asn: self.border_asn,
            as_boundary_confidence: self.as_boundary_confidence,
            avg_rtt_us: self.avg_rtt_us,
            loss_pct: self.loss_pct,
            last_seen: self.last_seen,
            ttl_secs: self.ttl_secs,
            expires_at: nonempty(self.expires_at),
        })
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifExternalSnapshotWrite {
    pub generated_at: String,
    pub ttl_secs: u64,
    pub nodes: Vec<NifExternalNodeWrite>,
    pub edges: Vec<NifExternalEdgeWrite>,
}

impl NifExternalSnapshotWrite {
    pub fn try_into_write(self) -> Result<ExternalSnapshotWrite, String> {
        let nodes = self
            .nodes
            .into_iter()
            .map(NifExternalNodeWrite::try_into_write)
            .collect::<Result<Vec<_>, _>>()?;
        let edges = self
            .edges
            .into_iter()
            .map(NifExternalEdgeWrite::try_into_write)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ExternalSnapshotWrite {
            generated_at: self.generated_at,
            ttl_secs: self.ttl_secs,
            nodes,
            edges,
        })
    }
}

#[derive(Clone, Debug, NifMap)]
pub struct NifExternalStatusPatch {
    pub entity_id: String,
    pub kind: Option<String>,
    pub outage_state: Option<String>,
    pub rpki_state: Option<String>,
    pub rtbh_active: Option<bool>,
    pub last_seen: String,
    pub expires_at: Option<String>,
}

impl NifExternalStatusPatch {
    pub fn try_into_write(self) -> Result<ExternalStatusPatch, String> {
        let entity_id = self.entity_id.trim().to_string();
        if entity_id.is_empty() {
            return Err("external status patch entity_id must not be empty".to_string());
        }
        let kind = match nonempty(self.kind) {
            Some(raw) => Some(
                ExternalNodeKind::parse(&raw)
                    .ok_or_else(|| format!("unknown external node kind: {raw}"))?,
            ),
            None => None,
        };
        Ok(ExternalStatusPatch {
            entity_id,
            kind,
            outage_state: nonempty(self.outage_state),
            rpki_state: nonempty(self.rpki_state),
            rtbh_active: self.rtbh_active,
            last_seen: self.last_seen,
            expires_at: nonempty(self.expires_at),
        })
    }
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.trim().is_empty())
}
