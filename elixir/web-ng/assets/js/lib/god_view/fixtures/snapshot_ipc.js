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

/**
 * Builds a synthetic schema-3 God View snapshot as Arrow IPC bytes, with the same column
 * names, types, row order (nodes first, then edges) and `node_count` / `edge_count`
 * metadata as the NIF encoder writes. Every value comes from the caller; nothing here is
 * captured from a deployment.
 */
export function snapshotIpcBytes({
  nodes = [],
  edges = [],
  schemaVersion = 3,
  revision = 1,
  metadata = true,
  omitColumns = [],
} = {}) {
  const nodeCount = nodes.length
  const edgeCount = edges.length
  const nodeColumn = (read) => [...nodes.map(read), ...edges.map(() => null)]
  const edgeColumn = (read) => [...nodes.map(() => null), ...edges.map(read)]
  const u64 = (value) => (value == null ? null : BigInt(value))
  const json = (value) => (value == null ? null : JSON.stringify(value))

  const table = new Table({
    row_type: vectorFromArray([...nodes.map(() => 0), ...edges.map(() => 1)], new Int8()),
    node_x: vectorFromArray(nodeColumn((node) => node.x ?? 0), new Uint16()),
    node_y: vectorFromArray(nodeColumn((node) => node.y ?? 0), new Uint16()),
    node_state: vectorFromArray(nodeColumn((node) => node.state ?? 3), new Uint16()),
    node_label: vectorFromArray(nodeColumn((node) => node.label ?? ""), new Utf8()),
    node_pps: vectorFromArray(nodeColumn((node) => node.pps ?? 0), new Uint32()),
    node_oper_up: vectorFromArray(nodeColumn((node) => node.operUp ?? 0), new Uint8()),
    node_details: vectorFromArray(nodeColumn((node) => json(node.details ?? {})), new Utf8()),
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
    edge_details: vectorFromArray(edgeColumn((edge) => json(edge.details ?? {})), new Utf8()),
    node_id: vectorFromArray(nodeColumn((node) => node.id ?? ""), new Utf8()),
  })

  const kept = omitColumns.length > 0 ? table.select(table.schema.names.filter((name) => !omitColumns.includes(name))) : table
  const schema = new Schema(
    kept.schema.fields,
    new Map([
      ["schema_version", String(schemaVersion)],
      ["revision", String(revision)],
      ...(metadata ? [["node_count", String(nodeCount)], ["edge_count", String(edgeCount)]] : []),
    ]),
  )
  const withMetadata = new Table(schema, kept.batches.map((batch) => new RecordBatch(schema, batch.data)))
  return tableToIPC(withMetadata, "file")
}

/**
 * A schema-3 ring of `count` nodes built straight from typed arrays, for frames too large to
 * build row by row in a test: node `i` sits at `(i % 65536, (i * 7) % 65536)` with state
 * `i % 4`, is named `n-<i>`, and edge `i` runs from node `i` to node `(i + 1) % count`.
 * Only the columns a decoder needs for ids, positions, states and endpoints are written.
 */
export function largeRingSnapshotIpcBytes(count) {
  const rows = count * 2
  const rowType = new Int8Array(rows)
  const nodeX = new Uint16Array(rows)
  const nodeY = new Uint16Array(rows)
  const nodeState = new Uint16Array(rows)
  const edgeSource = new Uint32Array(rows)
  const edgeTarget = new Uint32Array(rows)
  // node_id as a raw Utf8 column: offsets plus bytes, empty for edge rows.
  const encoder = new TextEncoder()
  const idBytes = encoder.encode(Array.from({length: count}, (_, i) => `n-${i}`).join(""))
  const idOffsets = new Int32Array(rows + 1)
  let offset = 0
  for (let i = 0; i < count; i += 1) {
    nodeX[i] = i % 65536
    nodeY[i] = (i * 7) % 65536
    nodeState[i] = i % 4
    offset += 2 + String(i).length
    idOffsets[i + 1] = offset
    rowType[count + i] = 1
    edgeSource[count + i] = i
    edgeTarget[count + i] = (i + 1) % count
  }
  idOffsets.fill(offset, count + 1)
  const nodeIds = makeVector(makeData({type: new Utf8(), length: rows, valueOffsets: idOffsets, data: idBytes}))

  const table = new Table({
    row_type: makeVector(rowType),
    node_x: makeVector(nodeX),
    node_y: makeVector(nodeY),
    node_state: makeVector(nodeState),
    edge_source: makeVector(edgeSource),
    edge_target: makeVector(edgeTarget),
    node_id: nodeIds,
  })
  const schema = new Schema(
    table.schema.fields,
    new Map([["schema_version", "3"], ["node_count", String(count)], ["edge_count", String(count)]]),
  )
  return tableToIPC(new Table(schema, table.batches.map((batch) => new RecordBatch(schema, batch.data))), "file")
}

/** A ring of `count` synthetic nodes, each linked to the next, ids `n-0` .. `n-<count-1>`. */
export function syntheticRing(count) {
  const nodes = new Array(count)
  const edges = new Array(count)
  for (let i = 0; i < count; i += 1) {
    nodes[i] = {
      id: `n-${i}`,
      label: `node ${i}`,
      x: i % 65536,
      y: (i * 7) % 65536,
      state: i % 4,
      operUp: 1,
      details: {id: `n-${i}`, ip: `192.0.2.${i % 256}`},
    }
    edges[i] = {source: i, target: (i + 1) % count, flowPps: i, details: {source_id: `n-${i}`}}
  }
  return {nodes, edges}
}
