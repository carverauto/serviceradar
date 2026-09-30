import {tableFromIPC} from "apache-arrow"
import {decodeSnapshotTable} from "./snapshot_columns"

export const WORLD_EXTENT = 2 ** 24
export const WORLD_TILE_SIZE = 512
export const MAX_TILE_BYTES = 262144

const requiredColumns = {
  row_type: "Int8",
  node_x: "Uint16",
  node_y: "Uint16",
  node_label: "Utf8",
  node_detail_id: "Utf8",
  node_detail_type: "Utf8",
  node_detail_cluster_member_count: "Float64",
  edge_source: "Uint32",
  edge_target: "Uint32",
  edge_topology_class: "Utf8",
  edge_detail_id: "Utf8",
  edge_detail_represented_count: "Float64",
  edge_detail_phase_start: "Float64",
  edge_detail_phase_end: "Float64",
  details_irregular: "Uint8",
}

function requireValue(condition, message) {
  if (!condition) throw new Error(`Invalid topology tile: ${message}`)
}

function integer(metadata, name, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = metadata.get(name)
  requireValue(typeof raw === "string" && /^(0|[1-9][0-9]*)$/.test(raw), name)
  const value = Number(raw)
  requireValue(Number.isSafeInteger(value) && value <= maximum, name)
  return value
}

/** Validate the bounded wire contract before allocating render arrays or reading details. */
export function decodeWorldTile(bytes, expected) {
  requireValue(bytes.byteLength <= MAX_TILE_BYTES, "byte budget")
  const table = tableFromIPC(bytes)
  const metadata = table.schema.metadata
  requireValue(table.batches.length === 1, "one batch required")
  requireValue(metadata.get("schema_version") === "3" && metadata.get("payload_kind") === "tile", "schema")
  requireValue(metadata.get("layout_version") === expected.layout_version, "layout")
  for (const name of ["z", "x", "y"]) {
    requireValue(integer(metadata, name, WORLD_EXTENT - 1) === expected[name], name)
  }
  requireValue(expected.z >= 0 && expected.z <= 24 && expected.x < 2 ** expected.z && expected.y < 2 ** expected.z, "key")
  const revision = metadata.get("tile_revision")
  requireValue(typeof revision === "string" && /^[0-9a-f]{64}$/.test(revision), "revision")
  if (expected.revision) requireValue(revision === expected.revision, "response revision")
  const nodeCount = integer(metadata, "node_count", 128)
  const edgeCount = integer(metadata, "edge_count", 256)
  requireValue(table.numRows === nodeCount + edgeCount, "row count")
  requireValue(nodeCount <= integer(metadata, "max_nodes", 128), "node budget")
  requireValue(edgeCount <= integer(metadata, "max_edges", 256), "edge budget")
  requireValue(bytes.byteLength <= integer(metadata, "max_encoded_bytes", MAX_TILE_BYTES), "encoded budget")
  requireValue(integer(metadata, "world_extent") === WORLD_EXTENT, "world extent")
  requireValue(metadata.get("coordinate_space") === "tile-local-u16", "coordinate space")
  const width = WORLD_EXTENT / 2 ** expected.z
  const originX = integer(metadata, "origin_x")
  const originY = integer(metadata, "origin_y")
  const scale = Number(metadata.get("coordinate_scale"))
  requireValue(originX === expected.x * width && originY === expected.y * width && scale === width / 65535, "transform")
  for (const [name, type] of Object.entries(requiredColumns)) {
    requireValue(table.schema.fields.filter(field => field.name === name).length === 1, `column ${name}`)
    requireValue(String(table.getChild(name)?.type) === type, `type ${name}`)
  }
  for (let row = 0; row < table.numRows; row += 1) {
    requireValue(table.getChild("row_type").get(row) === (row < nodeCount ? 0 : 1), "row order")
    requireValue(table.getChild("details_irregular").get(row) === 0, "typed details")
    for (const name of Object.keys(requiredColumns)) {
      if (name.startsWith(row < nodeCount ? "node_" : "edge_")) {
        requireValue(table.getChild(name).get(row) !== null, `null ${name}`)
      }
    }
  }
  const columns = decodeSnapshotTable(table)
  const positions = new Float64Array(nodeCount * 2)
  const nodes = new Array(nodeCount)
  const ids = new Set()
  let represented = 0
  const unit = WORLD_TILE_SIZE / WORLD_EXTENT
  for (let index = 0; index < nodeCount; index += 1) {
    const id = columns.nodeDetail(index, "id")
    const kind = columns.nodeDetail(index, "type")
    const count = columns.nodeDetail(index, "cluster_member_count")
    requireValue(typeof id === "string" && id.length > 0 && !ids.has(id), "node identity")
    requireValue(["device", "aggregate", "boundary"].includes(kind), "node kind")
    requireValue(Number.isSafeInteger(count) && count >= 0 && (kind === "boundary" ? count === 0 : count > 0), "membership")
    ids.add(id)
    represented += count
    positions[index * 2] = (originX + columns.nodeX[index] * scale) * unit
    positions[index * 2 + 1] = (originY + columns.nodeY[index] * scale) * unit
    nodes[index] = {id, kind, count, index, label: columns.nodeLabel(index)}
  }
  requireValue(represented === integer(metadata, "device_count"), "device conservation")
  const edges = new Array(edgeCount)
  const edgeIds = new Set()
  const edgeClass = columns.edgeStrings("edge_topology_class")
  for (let index = 0; index < edgeCount; index += 1) {
    const source = columns.edgeSource[index]
    const target = columns.edgeTarget[index]
    const details = columns.edgeDetails(index)
    const id = details.id
    const count = details.represented_count
    const start = details.phase_start
    const end = details.phase_end
    const topologyClass = edgeClass(index)
    requireValue(["backbone", "logical", "hosted", "endpoints", "inferred", "unknown"].includes(topologyClass), "edge class")
    requireValue(source < nodeCount && target < nodeCount, "endpoint")
    requireValue(typeof id === "string" && id.length > 0 && !edgeIds.has(id), "edge identity")
    requireValue(Number.isSafeInteger(count) && count > 0, "relation count")
    requireValue(Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end <= 1 && start < end, "flow phase")
    edgeIds.add(id)
    edges[index] = {id, index, source, target, count, start, end, topologyClass}
  }
  return {key: {...expected}, revision, columns, positions, nodes, edges, byteLength: bytes.byteLength}
}
