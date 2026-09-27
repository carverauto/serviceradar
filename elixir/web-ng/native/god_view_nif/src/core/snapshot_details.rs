//! Dense columns for the details keys the God View client reads on every row.
//!
//! `node_details` and `edge_details` travel as JSON strings, and the client only parses one
//! when an operator picks that node or edge. Everything the client reads for *every* node or
//! edge -- to decide visibility, clustering, labels, relation identity and layout -- is written
//! here as its own column instead, derived from the exact JSON string shipped in the same row,
//! so the column and the JSON cannot disagree.
//!
//! A row whose value for one of these keys has a type the column cannot carry exactly (say a
//! boolean sent as the string `"true"`) is flagged in `details_irregular`, and the client
//! parses that row's JSON rather than trusting the columns for it.
//!
//! Column names are the contract: `node_detail_<key>`, `edge_detail_<key>` and
//! `edge_metadata_<key>`, typed Utf8 (text), Float64 (number) or UInt8 (flag). The client
//! serves whichever of these columns a frame carries and parses the JSON for any other key, so
//! adding a key here needs no client change.

use std::sync::Arc;

use arrow_array::{ArrayRef, Float64Array, StringArray, UInt8Array};
use arrow_schema::{DataType, Field};
use serde_json::{Map, Value};

/// How a key's value is carried.
#[derive(Clone, Copy)]
pub(crate) enum DetailKind {
    /// JSON string or absent/null. Utf8, null when absent.
    Text,
    /// JSON number or absent/null. Float64, `NaN` when absent (JSON has no NaN).
    Number,
    /// JSON boolean or absent/null. UInt8: 0 absent, 1 false, 2 true.
    Flag,
}

pub(crate) struct DetailField {
    pub(crate) key: &'static str,
    pub(crate) kind: DetailKind,
}

const fn field(key: &'static str, kind: DetailKind) -> DetailField {
    DetailField { key, kind }
}

/// Node details keys read for every node (`node_detail_<key>`).
pub(crate) const NODE_DETAIL_FIELDS: &[DetailField] = &[
    field("id", DetailKind::Text),
    field("type", DetailKind::Text),
    field("cluster_kind", DetailKind::Text),
    field("cluster_id", DetailKind::Text),
    field("cluster_anchor_id", DetailKind::Text),
    field("cluster_panel_side", DetailKind::Text),
    field("identity_source", DetailKind::Text),
    field("topology_plane", DetailKind::Text),
    field("cluster_expanded", DetailKind::Flag),
    field("topology_unplaced", DetailKind::Flag),
    field("cluster_member_count", DetailKind::Number),
    field("geo_lat", DetailKind::Number),
    field("geo_lon", DetailKind::Number),
];

/// Edge details keys read for every edge (`edge_detail_<key>`).
pub(crate) const EDGE_DETAIL_FIELDS: &[DetailField] = &[
    field("id", DetailKind::Text),
    field("represented_count", DetailKind::Number),
    field("phase_start", DetailKind::Number),
    field("phase_end", DetailKind::Number),
    field("source_id", DetailKind::Text),
    field("target_id", DetailKind::Text),
    field("source_interface", DetailKind::Text),
    field("target_interface", DetailKind::Text),
    field("telemetry_source", DetailKind::Text),
    field("telemetry_observed_at", DetailKind::Text),
    field("observed_at", DetailKind::Text),
    field("source_if_index", DetailKind::Number),
    field("target_if_index", DetailKind::Number),
];

/// Edge `details.metadata` keys read for every edge (`edge_metadata_<key>`).
pub(crate) const EDGE_METADATA_FIELDS: &[DetailField] = &[
    field("relation_type", DetailKind::Text),
    field("topology_plane", DetailKind::Text),
    field("confidence_tier", DetailKind::Text),
    field("confidence_reason", DetailKind::Text),
    field("connectivity_forest_bridge", DetailKind::Flag),
];

/// Hyphenated spellings the client also accepts for metadata keys. A row carrying one is
/// irregular, because the columns hold only the underscore spelling.
const EDGE_METADATA_ALIASES: &[&str] = &[
    "relation-type",
    "topology-plane",
    "confidence-tier",
    "confidence-reason",
    "connectivity-forest-bridge",
];

enum Values {
    Text(Vec<Option<String>>),
    Number(Vec<f64>),
    Flag(Vec<u8>),
}

struct FieldColumn {
    name: String,
    kind: DetailKind,
    values: Values,
}

impl FieldColumn {
    fn new(prefix: &str, field: &DetailField, capacity: usize) -> Self {
        let values = match field.kind {
            DetailKind::Text => Values::Text(Vec::with_capacity(capacity)),
            DetailKind::Number => Values::Number(Vec::with_capacity(capacity)),
            DetailKind::Flag => Values::Flag(Vec::with_capacity(capacity)),
        };
        Self {
            name: format!("{prefix}{}", field.key),
            kind: field.kind,
            values,
        }
    }

    fn push_absent(&mut self) {
        match &mut self.values {
            Values::Text(values) => values.push(None),
            Values::Number(values) => values.push(f64::NAN),
            Values::Flag(values) => values.push(0),
        }
    }

    /// Pushes `value` and returns false when its JSON type does not fit this column.
    fn push(&mut self, value: Option<&Value>) -> bool {
        let value = match value {
            None | Some(Value::Null) => {
                self.push_absent();
                return true;
            }
            Some(value) => value,
        };
        match (&mut self.values, self.kind, value) {
            (Values::Text(values), _, Value::String(text)) => values.push(Some(text.clone())),
            (Values::Number(values), _, Value::Number(number)) => match number.as_f64() {
                Some(number) => values.push(number),
                None => {
                    values.push(f64::NAN);
                    return false;
                }
            },
            (Values::Flag(values), _, Value::Bool(flag)) => values.push(if *flag { 2 } else { 1 }),
            _ => {
                self.push_absent();
                return false;
            }
        }
        true
    }

    fn into_field_and_array(self) -> (Field, ArrayRef) {
        match self.values {
            Values::Text(values) => (
                Field::new(self.name, DataType::Utf8, true),
                Arc::new(StringArray::from(values)) as ArrayRef,
            ),
            Values::Number(values) => (
                Field::new(self.name, DataType::Float64, false),
                Arc::new(Float64Array::from(values)) as ArrayRef,
            ),
            Values::Flag(values) => (
                Field::new(self.name, DataType::UInt8, false),
                Arc::new(UInt8Array::from(values)) as ArrayRef,
            ),
        }
    }
}

/// Column builders for every row of a snapshot, node rows first and then edge rows.
pub(crate) struct DetailColumns {
    node: Vec<FieldColumn>,
    edge: Vec<FieldColumn>,
    metadata: Vec<FieldColumn>,
    metadata_present: Vec<u8>,
    sparkline_present: Vec<u8>,
    irregular: Vec<u8>,
}

impl DetailColumns {
    pub(crate) fn with_capacity(rows: usize) -> Self {
        let build = |prefix: &str, fields: &[DetailField]| {
            fields
                .iter()
                .map(|field| FieldColumn::new(prefix, field, rows))
                .collect::<Vec<_>>()
        };
        Self {
            node: build("node_detail_", NODE_DETAIL_FIELDS),
            edge: build("edge_detail_", EDGE_DETAIL_FIELDS),
            metadata: build("edge_metadata_", EDGE_METADATA_FIELDS),
            metadata_present: Vec::with_capacity(rows),
            sparkline_present: Vec::with_capacity(rows),
            irregular: Vec::with_capacity(rows),
        }
    }

    pub(crate) fn push_node(&mut self, details_json: &str) {
        let parsed = parse_object(details_json);
        let mut regular = true;
        for (column, field) in self.node.iter_mut().zip(NODE_DETAIL_FIELDS) {
            regular &= column.push(parsed.as_ref().and_then(|object| object.get(field.key)));
        }
        absent(&mut self.edge);
        absent(&mut self.metadata);
        self.metadata_present.push(0);
        self.sparkline_present.push(0);
        self.irregular.push(u8::from(!regular));
    }

    pub(crate) fn push_edge(&mut self, details_json: &str) {
        let parsed = parse_object(details_json);
        let mut regular = true;
        absent(&mut self.node);
        for (column, field) in self.edge.iter_mut().zip(EDGE_DETAIL_FIELDS) {
            regular &= column.push(parsed.as_ref().and_then(|object| object.get(field.key)));
        }

        // `metadata` must be an object or absent: the client exposes it as an object.
        let metadata = match parsed.as_ref().and_then(|object| object.get("metadata")) {
            None => None,
            Some(Value::Object(metadata)) => Some(metadata),
            Some(_) => {
                regular = false;
                None
            }
        };
        self.metadata_present.push(u8::from(metadata.is_some()));
        for (column, field) in self.metadata.iter_mut().zip(EDGE_METADATA_FIELDS) {
            regular &= column.push(metadata.and_then(|object| object.get(field.key)));
        }
        if let Some(metadata) = metadata {
            regular &= !EDGE_METADATA_ALIASES
                .iter()
                .any(|alias| metadata.contains_key(*alias));
        }

        let sparkline = parsed
            .as_ref()
            .and_then(|object| object.get("interface_sparkline"))
            .and_then(Value::as_array)
            .is_some_and(|points| !points.is_empty());
        self.sparkline_present.push(u8::from(sparkline));
        self.irregular.push(u8::from(!regular));
    }

    /// Schema fields and arrays, in a fixed order.
    pub(crate) fn into_fields_and_arrays(self) -> Vec<(Field, ArrayRef)> {
        let mut out: Vec<(Field, ArrayRef)> = self
            .node
            .into_iter()
            .chain(self.edge)
            .chain(self.metadata)
            .map(FieldColumn::into_field_and_array)
            .collect();
        out.push((
            Field::new("edge_has_metadata", DataType::UInt8, false),
            Arc::new(UInt8Array::from(self.metadata_present)),
        ));
        // Whether `interface_sparkline` is a non-empty array: presentation ranking needs only
        // that, not the points.
        out.push((
            Field::new("edge_has_sparkline", DataType::UInt8, false),
            Arc::new(UInt8Array::from(self.sparkline_present)),
        ));
        out.push((
            Field::new("details_irregular", DataType::UInt8, false),
            Arc::new(UInt8Array::from(self.irregular)),
        ));
        out
    }
}

fn absent(columns: &mut [FieldColumn]) {
    for column in columns {
        column.push_absent();
    }
}

/// The details object, or `None` when the JSON is invalid or not an object. The client
/// treats both as `{}`, which is what all-absent columns describe.
fn parse_object(details_json: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(details_json) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}
