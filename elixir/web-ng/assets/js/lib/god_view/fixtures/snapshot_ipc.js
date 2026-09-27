import {
  Int8,
  RecordBatch,
  Schema,
  Table,
  Uint16,
  Uint32,
  Uint64,
  Uint8,
  Utf8,
  makeData,
  makeVector,
  tableToIPC,
  vectorFromArray,
} from "apache-arrow"

// The details keys the NIF encoder writes as columns (`snapshot_details.rs`), mirrored here
// so synthetic frames carry the same columns. Kinds: text (Utf8), number (Float64, NaN when
// absent) and flag (UInt8: 0 absent, 1 false, 2 true).
const NODE_DETAIL_FIELDS = [
  ["id", "text"],
  ["type", "text"],
  ["cluster_kind", "text"],
  ["cluster_id", "text"],
  ["cluster_anchor_id", "text"],
  ["cluster_panel_side", "text"],
  ["identity_source", "text"],
  ["topology_plane", "text"],
  ["cluster_expanded", "flag"],
  ["topology_unplaced", "flag"],
  ["cluster_member_count", "number"],
  ["geo_lat", "number"],
  ["geo_lon", "number"],
]
const EDGE_DETAIL_FIELDS = [
  ["id", "text"],
  ["represented_count", "number"],
  ["phase_start", "number"],
  ["phase_end", "number"],
  ["source_id", "text"],
  ["target_id", "text"],
  ["source_interface", "text"],
  ["target_interface", "text"],
  ["telemetry_source", "text"],
  ["telemetry_observed_at", "text"],
  ["observed_at", "text"],
  ["source_if_index", "number"],
  ["target_if_index", "number"],
]
const EDGE_METADATA_FIELDS = [
  ["relation_type", "text"],
  ["topology_plane", "text"],
  ["confidence_tier", "text"],
  ["confidence_reason", "text"],
  ["connectivity_forest_bridge", "flag"],
]
const METADATA_ALIASES = [
  "relation-type",
  "topology-plane",
  "confidence-tier",
  "confidence-reason",
  "connectivity-forest-bridge",
]

const encoder = new TextEncoder()

/** A Utf8 vector built straight from offsets; `null` entries are null. */
function utf8Vector(values) {
  const length = values.length
  const valueOffsets = new Int32Array(length + 1)
  const nullBitmap = new Uint8Array(Math.ceil(length / 8))
  const parts = []
  let offset = 0
  let nullCount = 0
  for (let i = 0; i < length; i += 1) {
    const value = values[i]
    if (value == null) {
      nullCount += 1
    } else {
      nullBitmap[i >> 3] |= 1 << (i & 7)
      const bytes = encoder.encode(value)
      parts.push(bytes)
      offset += bytes.length
    }
    valueOffsets[i + 1] = offset
  }
  const data = new Uint8Array(offset)
  let cursor = 0
  for (const bytes of parts) {
    data.set(bytes, cursor)
    cursor += bytes.length
  }
  return makeVector(makeData({type: new Utf8(), length, nullCount, nullBitmap, valueOffsets, data}))
}

function isAbsent(value) {
  return value === undefined || value === null
}

/** Pushes one row's value; returns false when the kind cannot carry it (an irregular row). */
function pushValue(kind, column, value) {
  if (isAbsent(value)) {
    column.push(kind === "text" ? null : kind === "number" ? NaN : 0)
    return true
  }
  if (kind === "text" && typeof value === "string") column.push(value)
  else if (kind === "number" && typeof value === "number") column.push(value)
  else if (kind === "flag" && typeof value === "boolean") column.push(value ? 2 : 1)
  else {
    column.push(kind === "text" ? null : kind === "number" ? NaN : 0)
    return false
  }
  return true
}

function columnVector(kind, values) {
  if (kind === "text") return utf8Vector(values)
  if (kind === "number") return makeVector(Float64Array.from(values))
  return makeVector(Uint8Array.from(values))
}

/**
 * The encoder's details columns for these rows. `nodeDetails` and `edgeDetails` are the
 * objects whose JSON the frame ships, nodes first.
 */
function detailColumnVectors(nodeDetails, edgeDetails) {
  const fieldsFor = (prefix, fields) => fields.map(([key, kind]) => ({name: `${prefix}${key}`, key, kind, values: []}))
  const node = fieldsFor("node_detail_", NODE_DETAIL_FIELDS)
  const edge = fieldsFor("edge_detail_", EDGE_DETAIL_FIELDS)
  const metadata = fieldsFor("edge_metadata_", EDGE_METADATA_FIELDS)
  const hasMetadata = []
  const hasSparkline = []
  const irregular = []
  const absent = (columns) => columns.forEach((column) => pushValue(column.kind, column.values, undefined))
  const object = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : {})

  for (const raw of nodeDetails) {
    const details = object(raw)
    let regular = true
    for (const column of node) regular = pushValue(column.kind, column.values, details[column.key]) && regular
    absent(edge)
    absent(metadata)
    hasMetadata.push(0)
    hasSparkline.push(0)
    irregular.push(regular ? 0 : 1)
  }

  for (const raw of edgeDetails) {
    const details = object(raw)
    let regular = true
    absent(node)
    for (const column of edge) regular = pushValue(column.kind, column.values, details[column.key]) && regular
    let meta = null
    if (!isAbsent(details.metadata)) {
      if (details.metadata && typeof details.metadata === "object" && !Array.isArray(details.metadata)) {
        meta = details.metadata
      } else {
        regular = false
      }
    }
    for (const column of metadata) regular = pushValue(column.kind, column.values, meta?.[column.key]) && regular
    if (meta && METADATA_ALIASES.some((alias) => Object.hasOwn(meta, alias))) regular = false
    hasMetadata.push(meta ? 1 : 0)
    hasSparkline.push(Array.isArray(details.interface_sparkline) && details.interface_sparkline.length > 0 ? 1 : 0)
    irregular.push(regular ? 0 : 1)
  }

  const vectors = {}
  for (const column of [...node, ...edge, ...metadata]) vectors[column.name] = columnVector(column.kind, column.values)
  vectors.edge_has_metadata = makeVector(Uint8Array.from(hasMetadata))
  vectors.edge_has_sparkline = makeVector(Uint8Array.from(hasSparkline))
  vectors.details_irregular = makeVector(Uint8Array.from(irregular))
  return vectors
}

function withMetadata(table, entries) {
  const schema = new Schema(table.schema.fields, new Map(entries))
  return new Table(schema, table.batches.map((batch) => new RecordBatch(schema, batch.data)))
}

/**
 * Builds a synthetic schema-3 God View snapshot as Arrow IPC bytes, with the same column
 * names, types, row order (nodes first, then edges), details columns and `node_count` /
 * `edge_count` metadata as the NIF encoder writes. Every value comes from the caller;
 * nothing here is captured from a deployment.
 *
 * A node's `details` defaults to `{id}`. `detailColumns: false` leaves out the details
 * columns, like a frame from before they existed.
 */
export function snapshotIpcBytes({
  nodes = [],
  edges = [],
  schemaVersion = 3,
  revision = 1,
  metadata = true,
  metadataEntries = [],
  detailColumns = true,
  omitColumns = [],
} = {}) {
  const nodeCount = nodes.length
  const edgeCount = edges.length
  const nodeDetails = nodes.map((node) => node.details ?? (node.id == null ? {} : {id: node.id}))
  const edgeDetails = edges.map((edge) => edge.details ?? {})
  const nodeColumn = (read) => [...nodes.map(read), ...edges.map(() => null)]
  const edgeColumn = (read) => [...nodes.map(() => null), ...edges.map(read)]
  const u64 = (value) => (value == null ? null : BigInt(value))

  const table = new Table({
    row_type: vectorFromArray([...nodes.map(() => 0), ...edges.map(() => 1)], new Int8()),
    node_x: vectorFromArray(nodeColumn((node) => node.x ?? 0), new Uint16()),
    node_y: vectorFromArray(nodeColumn((node) => node.y ?? 0), new Uint16()),
    node_state: vectorFromArray(nodeColumn((node) => node.state ?? 3), new Uint16()),
    node_label: vectorFromArray(nodeColumn((node) => node.label ?? ""), new Utf8()),
    node_pps: vectorFromArray(nodeColumn((node) => node.pps ?? 0), new Uint32()),
    node_oper_up: vectorFromArray(nodeColumn((node) => node.operUp ?? 0), new Uint8()),
    node_details: utf8Vector([...nodeDetails.map((details) => JSON.stringify(details)), ...edges.map(() => null)]),
    edge_source: vectorFromArray(edgeColumn((edge) => edge.source), new Uint32()),
    edge_target: vectorFromArray(edgeColumn((edge) => edge.target), new Uint32()),
    edge_pps: vectorFromArray(edgeColumn((edge) => edge.flowPps ?? 0), new Uint32()),
    edge_pps_ab: vectorFromArray(edgeColumn((edge) => edge.flowPpsAb ?? 0), new Uint32()),
    edge_pps_ba: vectorFromArray(edgeColumn((edge) => edge.flowPpsBa ?? 0), new Uint32()),
    edge_flow_bps: vectorFromArray(edgeColumn((edge) => u64(edge.flowBps ?? 0)), new Uint64()),
    edge_flow_bps_ab: vectorFromArray(edgeColumn((edge) => u64(edge.flowBpsAb ?? 0)), new Uint64()),
    edge_flow_bps_ba: vectorFromArray(edgeColumn((edge) => u64(edge.flowBpsBa ?? 0)), new Uint64()),
    edge_capacity_bps: vectorFromArray(edgeColumn((edge) => u64(edge.capacityBps ?? 0)), new Uint64()),
    edge_telemetry_eligible: vectorFromArray(
      edgeColumn((edge) => (edge.telemetryEligible === false ? 0 : 1)),
      new Uint8(),
    ),
    edge_label: vectorFromArray(edgeColumn((edge) => edge.label ?? ""), new Utf8()),
    edge_topology_class: vectorFromArray(edgeColumn((edge) => edge.topologyClass ?? "backbone"), new Utf8()),
    edge_protocol: vectorFromArray(edgeColumn((edge) => edge.protocol ?? ""), new Utf8()),
    edge_evidence_class: vectorFromArray(edgeColumn((edge) => edge.evidenceClass ?? "unknown"), new Utf8()),
    edge_details: utf8Vector([...nodes.map(() => null), ...edgeDetails.map((details) => JSON.stringify(details))]),
    ...(detailColumns ? detailColumnVectors(nodeDetails, edgeDetails) : {}),
  })

  const kept = omitColumns.length > 0 ? table.select(table.schema.names.filter((name) => !omitColumns.includes(name))) : table
  return tableToIPC(
    withMetadata(kept, [
      ["schema_version", String(schemaVersion)],
      ["revision", String(revision)],
      ...(metadata ? [["node_count", String(nodeCount)], ["edge_count", String(edgeCount)]] : []),
      ...metadataEntries,
    ]),
    "file",
  )
}

/**
 * Node `i` and edge `i` of the synthetic ring `syntheticRing` and `largeRingSnapshotIpcBytes`
 * describe: node `i` sits at `(i % 65536, (i * 7) % 65536)` with state `i % 4` and links to
 * node `(i + 1) % count`. Addresses are from 192.0.2.0/24 and names from example.com.
 */
function ringNodeDetails(i) {
  return {
    id: `n-${i}`,
    ip: `192.0.2.${i % 256}`,
    hostname: `host-${i}.example.com`,
    type: "switch",
    vendor: "ExampleCo",
    model: "X1",
    topology_plane: "backbone",
    topology_unplaced: false,
  }
}

function ringEdgeDetails(i, count) {
  return {
    source_id: `n-${i}`,
    target_id: `n-${(i + 1) % count}`,
    source_interface: "ge-0/0/1",
    target_interface: "ge-0/0/2",
    source_if_index: 1,
    target_if_index: 2,
    telemetry_source: "interface",
    telemetry_observed_at: "2026-01-01T00:00:00Z",
    interface_sparkline: [],
    metadata: {relation_type: "CONNECTS_TO", topology_plane: "physical"},
  }
}

/**
 * A schema-3 ring of `count` nodes built straight from typed arrays, for frames too large to
 * build row by row in a test, with details JSON and details columns for every row.
 */
export function largeRingSnapshotIpcBytes(count) {
  const rows = count * 2
  const rowType = new Int8Array(rows)
  const nodeX = new Uint16Array(rows)
  const nodeY = new Uint16Array(rows)
  const nodeState = new Uint16Array(rows)
  const edgeSource = new Uint32Array(rows)
  const edgeTarget = new Uint32Array(rows)
  const nodeDetails = new Array(count)
  const edgeDetails = new Array(count)
  for (let i = 0; i < count; i += 1) {
    nodeX[i] = i % 65536
    nodeY[i] = (i * 7) % 65536
    nodeState[i] = i % 4
    rowType[count + i] = 1
    edgeSource[count + i] = i
    edgeTarget[count + i] = (i + 1) % count
    nodeDetails[i] = ringNodeDetails(i)
    edgeDetails[i] = ringEdgeDetails(i, count)
  }
  const none = new Array(count).fill(null)

  const table = new Table({
    row_type: makeVector(rowType),
    node_x: makeVector(nodeX),
    node_y: makeVector(nodeY),
    node_state: makeVector(nodeState),
    node_label: utf8Vector([...nodeDetails.map((details) => details.hostname), ...none]),
    node_details: utf8Vector([...nodeDetails.map((details) => JSON.stringify(details)), ...none]),
    edge_source: makeVector(edgeSource),
    edge_target: makeVector(edgeTarget),
    edge_details: utf8Vector([...none, ...edgeDetails.map((details) => JSON.stringify(details))]),
    ...detailColumnVectors(nodeDetails, edgeDetails),
  })
  return tableToIPC(
    withMetadata(table, [["schema_version", "3"], ["node_count", String(count)], ["edge_count", String(count)]]),
    "file",
  )
}

/** A ring of `count` synthetic nodes, each linked to the next, ids `n-0` .. `n-<count-1>`. */
export function syntheticRing(count) {
  const nodes = new Array(count)
  const edges = new Array(count)
  for (let i = 0; i < count; i += 1) {
    nodes[i] = {id: `n-${i}`, label: `node ${i}`, x: i % 65536, y: (i * 7) % 65536, state: i % 4, operUp: 1, details: ringNodeDetails(i)}
    edges[i] = {source: i, target: (i + 1) % count, flowPps: i, details: ringEdgeDetails(i, count)}
  }
  return {nodes, edges}
}
