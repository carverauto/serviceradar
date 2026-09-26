import {tableFromIPC} from "apache-arrow"

/**
 * Snapshot schema this decoder reads. Version 3 widened `edge_source` / `edge_target` to
 * UInt32 (a frame can exceed 65535 nodes) and added the dense `node_id` column.
 */
export const GOD_VIEW_SNAPSHOT_SCHEMA_VERSION = 3

function metadataCount(table, key) {
  const raw = table?.schema?.metadata?.get?.(key)
  if (raw == null || raw === "") return null
  const value = Number(raw)
  return Number.isInteger(value) && value >= 0 ? value : null
}

/**
 * Node rows precede edge rows (the encoder writes them that way and records the split in
 * `node_count` / `edge_count`). A frame without those keys is counted from `row_type`,
 * which must still be node-first: every numeric column below is sliced, not scanned.
 */
function rowSplit(table) {
  const rowCount = Number(table?.numRows || 0)
  const nodeCount = metadataCount(table, "node_count")
  const edgeCount = metadataCount(table, "edge_count")
  if (nodeCount !== null && edgeCount !== null && nodeCount + edgeCount === rowCount) {
    return {nodeCount, edgeCount}
  }

  const rowType = table.getChild("row_type")?.toArray?.() || []
  let nodes = 0
  while (nodes < rowCount && Number(rowType[nodes]) === 0) nodes += 1
  for (let row = nodes; row < rowCount; row += 1) {
    if (Number(rowType[row]) !== 1) {
      throw new Error(`god view snapshot is not node-first at row ${row}`)
    }
  }
  return {nodeCount: nodes, edgeCount: rowCount - nodes}
}

function numericColumn(table, name) {
  const column = table.getChild(name)
  return column && typeof column.toArray === "function" ? column.toArray() : null
}

function packInto(Target, values, start, length, fallback = 0) {
  const out = new Target(length)
  if (!values) {
    if (fallback !== 0) out.fill(fallback)
    return out
  }
  for (let i = 0; i < length; i += 1) {
    const value = values[start + i]
    out[i] = value == null ? fallback : Number(value)
  }
  return out
}

function parseDetails(raw) {
  if (typeof raw !== "string" || raw.trim() === "") return {}
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
  } catch (_err) {
    return {}
  }
}

/**
 * Decodes a God View snapshot into typed columns without building a per-row object.
 *
 * Positions, node state, oper status, pps and both edge endpoints come out as typed arrays
 * sliced from the Arrow column buffers. `positions` is the UInt16 layout space packed once
 * into an interleaved `Float32Array` (`[x0, y0, x1, y1, ...]`), which is the shape deck.gl
 * uploads as a binary `getPosition` attribute.
 *
 * `node_details` / `edge_details` stay as Arrow strings. `nodeDetails(i)` / `edgeDetails(i)`
 * parse one row on first use and memoize it, and `parsedDetailCounts()` reports how many
 * rows have been parsed so far.
 */
export function decodeSnapshotColumns(bytes) {
  const table = tableFromIPC(bytes)
  const {nodeCount, edgeCount} = rowSplit(table)
  const edgeOffset = nodeCount

  const nodeX = packInto(Uint16Array, numericColumn(table, "node_x"), 0, nodeCount)
  const nodeY = packInto(Uint16Array, numericColumn(table, "node_y"), 0, nodeCount)
  const positions = new Float32Array(nodeCount * 2)
  for (let i = 0; i < nodeCount; i += 1) {
    positions[i * 2] = nodeX[i]
    positions[i * 2 + 1] = nodeY[i]
  }

  const nodeIdColumn = table.getChild("node_id")
  const nodeLabelColumn = table.getChild("node_label")
  const nodeDetailsColumn = table.getChild("node_details")
  const edgeDetailsColumn = table.getChild("edge_details")
  const nodeDetailCache = new Array(nodeCount)
  const edgeDetailCache = new Array(edgeCount)
  let parsedNodeDetails = 0
  let parsedEdgeDetails = 0

  return {
    table,
    schemaVersion: Number(table.schema?.metadata?.get?.("schema_version") || 0) || null,
    nodeCount,
    edgeCount,
    nodeX,
    nodeY,
    positions,
    nodeState: packInto(Uint8Array, numericColumn(table, "node_state"), 0, nodeCount, 3),
    nodeOperUp: packInto(Uint8Array, numericColumn(table, "node_oper_up"), 0, nodeCount),
    nodePps: packInto(Float64Array, numericColumn(table, "node_pps"), 0, nodeCount),
    edgeSource: packInto(Uint32Array, numericColumn(table, "edge_source"), edgeOffset, edgeCount),
    edgeTarget: packInto(Uint32Array, numericColumn(table, "edge_target"), edgeOffset, edgeCount),
    edgeColumn(name, Target = Float64Array, fallback = 0) {
      return packInto(Target, numericColumn(table, name), edgeOffset, edgeCount, fallback)
    },
    /** Returns a reader for one edge string column; the column is looked up once. */
    edgeStrings(name) {
      const column = table.getChild(name)
      return column ? (index) => column.get(edgeOffset + index) ?? null : () => null
    },
    nodeId(index) {
      // A frame from before schema 3 has no node_id column; its ids live in the details.
      if (!nodeIdColumn) return this.nodeDetails(index)?.id ?? null
      return nodeIdColumn.get(index) ?? null
    },
    nodeLabel(index) {
      return nodeLabelColumn?.get(index) ?? null
    },
    nodeDetails(index) {
      if (index < 0 || index >= nodeCount) return {}
      let details = nodeDetailCache[index]
      if (details === undefined) {
        details = parseDetails(nodeDetailsColumn?.get(index))
        nodeDetailCache[index] = details
        parsedNodeDetails += 1
      }
      return details
    },
    edgeDetails(index) {
      if (index < 0 || index >= edgeCount) return {}
      let details = edgeDetailCache[index]
      if (details === undefined) {
        details = parseDetails(edgeDetailsColumn?.get(edgeOffset + index))
        edgeDetailCache[index] = details
        parsedEdgeDetails += 1
      }
      return details
    },
    parsedDetailCounts() {
      return {nodes: parsedNodeDetails, edges: parsedEdgeDetails}
    },
  }
}

/**
 * Defines `key` as an enumerable property computed on first read.
 *
 * The first read (or a write) replaces the accessor with a plain data property, so a spread
 * copy, `JSON.stringify` and later reads all see an ordinary value. Until then nothing is
 * computed, which is what keeps a node's details JSON unparsed until something asks for it.
 */
export function defineLazyProperty(target, key, compute) {
  Object.defineProperty(target, key, {
    configurable: true,
    enumerable: true,
    get() {
      const value = compute()
      Object.defineProperty(target, key, {value, writable: true, enumerable: true, configurable: true})
      return value
    },
    set(value) {
      Object.defineProperty(target, key, {value, writable: true, enumerable: true, configurable: true})
    },
  })
  return target
}
