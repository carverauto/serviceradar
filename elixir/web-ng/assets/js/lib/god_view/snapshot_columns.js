import {tableFromIPC} from "apache-arrow"

const NODE_DETAIL_PREFIX = "node_detail_"
const EDGE_DETAIL_PREFIX = "edge_detail_"
const EDGE_METADATA_PREFIX = "edge_metadata_"
const LAZY_DETAILS = Symbol("godViewSnapshotDetails")

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

const utf8 = new TextDecoder()

/**
 * Row reader for a Utf8 column. `Vector.get` decodes UTF-8 on every call; for a single-chunk
 * ASCII column (ids, labels, enum-like values) the whole value buffer is decoded once and a
 * row is a substring of it.
 */
function stringReader(vector) {
  if (!vector) return () => null
  const data = vector.data?.length === 1 ? vector.data[0] : null
  const values = data?.values
  const offsets = data?.valueOffsets
  if (!(values instanceof Uint8Array) || !offsets) return (row) => vector.get(row) ?? null
  for (let i = 0; i < values.length; i += 1) {
    if (values[i] > 0x7f) return (row) => vector.get(row) ?? null
  }
  const text = utf8.decode(values)
  const bitmap = data.nullCount > 0 ? data.nullBitmap : null
  const base = data.offset || 0
  return (row) => {
    const index = base + row
    if (bitmap && (bitmap[index >> 3] & (1 << (index & 7))) === 0) return null
    return text.substring(offsets[index], offsets[index + 1])
  }
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
 * A reader for one details-key column, returning the JSON value (`undefined` when absent).
 * The encoder types each column: Utf8 is text, Float64 a number (`NaN` = absent), UInt8 a
 * flag (0 absent, 1 false, 2 true).
 */
function fieldReader(table, field, offset, length) {
  const type = String(field.type)
  if (type === "Utf8") {
    // Cached per row, so reading the same key on every render does not allocate.
    let read = null
    let cache = null
    return (index) => {
      if (cache === null) {
        read = stringReader(table.getChild(field.name))
        cache = new Array(length)
      }
      let value = cache[index]
      if (value === undefined) {
        value = read(offset + index)
        cache[index] = value
      }
      return value === null ? undefined : value
    }
  }

  const values = numericColumn(table, field.name)?.subarray?.(offset, offset + length)
  if (!values) return null
  if (type === "Float64") {
    return (index) => {
      const value = values[index]
      return Number.isNaN(value) ? undefined : value
    }
  }
  if (type === "Uint8") {
    return (index) => {
      const value = values[index]
      return value === 0 ? undefined : value === 2
    }
  }
  return null
}

function fieldReaders(table, prefix, offset, length) {
  const readers = new Map()
  for (const field of table.schema.fields) {
    if (!field.name.startsWith(prefix)) continue
    const reader = fieldReader(table, field, offset, length)
    if (reader) readers.set(field.name.slice(prefix.length), reader)
  }
  return readers
}

/**
 * The details of one kind of row (node or edge): which keys have their own column, and the
 * JSON for everything else. `parse(i)` parses row `i` once and caches it.
 */
function detailsSource(table, {jsonColumn, prefix, offset, length}) {
  const column = table.getChild(jsonColumn)
  const cache = new Array(length)
  const source = {
    fields: fieldReaders(table, prefix, offset, length),
    parsedCount: 0,
    raw(index) {
      // Rarely needed (a parse, or a fingerprint), so decode one value rather than the column.
      return column?.get(offset + index) ?? null
    },
    parse(index) {
      let details = cache[index]
      if (details === undefined) {
        details = parseDetails(source.raw(index))
        cache[index] = details
        source.parsedCount += 1
      }
      return details
    },
  }
  return source
}

function materialize(target) {
  if (target.parsed === undefined) {
    const parsed = target.source.parse(target.index)
    // A copy writes to its own object, the way `{...details}` would.
    target.parsed = target.copy ? {...parsed} : parsed
  }
  return target.parsed
}

function materializeMetadata(target) {
  if (target.parsed === undefined) {
    const details = materialize(target.details)
    target.parsed = details.metadata && typeof details.metadata === "object" ? details.metadata : {}
  }
  return target.parsed
}

function lazyHandler(resolve) {
  return {
    get(target, key) {
      if (key === LAZY_DETAILS) return target
      if (target.parsed === undefined) {
        if (typeof key === "symbol") return undefined
        const reader = target.fields.get(key)
        if (reader) return reader(target.index)
        if (key === "metadata" && target.metadata !== undefined) return target.metadata ?? undefined
      }
      return resolve(target)[key]
    },
    set(target, key, value) {
      resolve(target)[key] = value
      return true
    },
    has: (target, key) => key in resolve(target),
    deleteProperty: (target, key) => delete resolve(target)[key],
    defineProperty: (target, key, descriptor) => Reflect.defineProperty(resolve(target), key, descriptor),
    ownKeys: (target) => Reflect.ownKeys(resolve(target)),
    getOwnPropertyDescriptor(target, key) {
      const descriptor = Reflect.getOwnPropertyDescriptor(resolve(target), key)
      if (descriptor) descriptor.configurable = true
      return descriptor
    },
    // Freezing would pin the proxy target and break the ownKeys invariant; the callers that
    // deep-freeze or deep-clone a graph skip these objects instead (isLazySnapshotDetails).
    preventExtensions: () => false,
  }
}

const detailsHandler = lazyHandler(materialize)
const metadataHandler = lazyHandler(materializeMetadata)

function lazyDetails(source, index, copy = false) {
  return new Proxy({source, fields: source.fields, index, parsed: undefined, copy, metadata: undefined}, detailsHandler)
}

function lazyMetadata(details, fields, index) {
  return new Proxy({details, fields, index, parsed: undefined}, metadataHandler)
}

/** True for a details (or metadata) object that still defers to its snapshot row. */
export function isLazySnapshotDetails(value) {
  return Boolean(value) && typeof value === "object" && value[LAZY_DETAILS] !== undefined
}

/**
 * A copy of a details object, like `{...details}`, that does not parse a snapshot row
 * to make it: the copy reads the same columns and parses its own row only on demand.
 */
export function copyDetails(details) {
  const target = isLazySnapshotDetails(details) ? details[LAZY_DETAILS] : null
  if (!target || target.source === undefined) return {...(details || {})}
  const copy = lazyDetails(target.source, target.index, true)
  const copyTarget = copy[LAZY_DETAILS]
  copyTarget.metadata = target.metadata === undefined
    ? undefined
    : target.metadata && lazyMetadata(copyTarget, target.metadata[LAZY_DETAILS].fields, target.index)
  if (target.parsed !== undefined) copyTarget.parsed = {...target.parsed}
  return copy
}

/** Whether `details.interface_sparkline` is a non-empty array, without parsing the row. */
export function detailsHaveSparkline(details) {
  const target = isLazySnapshotDetails(details) ? details[LAZY_DETAILS] : null
  if (target && target.parsed === undefined && target.source?.hasSparkline) {
    return target.source.hasSparkline(target.index)
  }
  return Array.isArray(details?.interface_sparkline) && details.interface_sparkline.length > 0
}

/**
 * The shipped JSON of a snapshot row's details, or null for any other object. Stands in for
 * the parsed details wherever a stable fingerprint of the content is enough.
 */
export function snapshotDetailsJson(details) {
  const target = isLazySnapshotDetails(details) ? details[LAZY_DETAILS] : null
  return target?.source ? target.source.raw(target.index) ?? "" : null
}

/**
 * Decodes a God View snapshot into typed columns without building a per-row object.
 *
 * `nodeX`/`nodeY` (the quantized UInt16 layout space) and node state, oper status, pps and
 * both edge endpoints come out as typed arrays sliced from the Arrow column buffers. The ELK
 * layout the render path draws from packs its own laid-out positions into one `Float32Array`
 * once the layout is accepted (see `rendering_node_frame.js`); this decoder does not.
 *
 * `nodeDetails(i)` / `edgeDetails(i)` return the row's details object. For a key the
 * encoder wrote a column for (`node_detail_<key>`, `edge_detail_<key>`,
 * `edge_metadata_<key>`) it answers from that column; any other key, a spread, or a write
 * parses the row's JSON once. A row marked `details_irregular` is parsed up front.
 * `parsedDetailCounts()` reports how many rows have been parsed.
 */
export function decodeSnapshotColumns(bytes) {
  const table = tableFromIPC(bytes)
  const {nodeCount, edgeCount} = rowSplit(table)
  const edgeOffset = nodeCount

  const nodeX = packInto(Uint16Array, numericColumn(table, "node_x"), 0, nodeCount)
  const nodeY = packInto(Uint16Array, numericColumn(table, "node_y"), 0, nodeCount)

  const irregular = numericColumn(table, "details_irregular")
  const nodeSource = detailsSource(table, {
    jsonColumn: "node_details",
    prefix: NODE_DETAIL_PREFIX,
    offset: 0,
    length: nodeCount,
  })
  const edgeSource = detailsSource(table, {
    jsonColumn: "edge_details",
    prefix: EDGE_DETAIL_PREFIX,
    offset: edgeOffset,
    length: edgeCount,
  })
  const metadataFields = fieldReaders(table, EDGE_METADATA_PREFIX, edgeOffset, edgeCount)
  // Readers also accept a hyphenated spelling of each metadata key. The encoder marks a row
  // that uses one irregular, so on every other row the hyphenated key is simply absent.
  for (const key of [...metadataFields.keys()]) {
    const alias = key.replaceAll("_", "-")
    if (alias !== key && !metadataFields.has(alias)) metadataFields.set(alias, () => undefined)
  }
  const hasMetadata = numericColumn(table, "edge_has_metadata")?.subarray?.(edgeOffset, edgeOffset + edgeCount)
  const hasSparkline = numericColumn(table, "edge_has_sparkline")?.subarray?.(edgeOffset, edgeOffset + edgeCount)
  if (hasSparkline) edgeSource.hasSparkline = (index) => hasSparkline[index] === 1

  // Without the irregular column this frame has no details columns at all: every key parses.
  const nodeRegular = (index) => Boolean(irregular) && irregular[index] === 0
  const edgeRegular = (index) => Boolean(irregular) && irregular[edgeOffset + index] === 0

  const readNodeLabel = stringReader(table.getChild("node_label"))

  return {
    table,
    schemaVersion: Number(table.schema?.metadata?.get?.("schema_version") || 0) || null,
    nodeCount,
    edgeCount,
    nodeX,
    nodeY,
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
      const read = stringReader(table.getChild(name))
      return (index) => read(edgeOffset + index)
    },
    nodeLabel(index) {
      return readNodeLabel(index)
    },
    /** A node details key, from its column when the row allows it. */
    nodeDetail(index, key) {
      const reader = nodeSource.fields.get(key)
      return reader && nodeRegular(index) ? reader(index) : nodeSource.parse(index)[key]
    },
    nodeDetails(index) {
      if (index < 0 || index >= nodeCount) return {}
      return nodeRegular(index) ? lazyDetails(nodeSource, index) : nodeSource.parse(index)
    },
    /** The edge's details and its `metadata` object, sharing one row. */
    edgeDetailsAndMetadata(index) {
      if (index < 0 || index >= edgeCount) return {details: {}, metadata: {}}
      if (!edgeRegular(index)) {
        const details = edgeSource.parse(index)
        const metadata = details.metadata && typeof details.metadata === "object" ? details.metadata : {}
        return {details, metadata}
      }
      const details = lazyDetails(edgeSource, index)
      const target = details[LAZY_DETAILS]
      const metadata = lazyMetadata(target, metadataFields, index)
      target.metadata = hasMetadata && hasMetadata[index] === 1 ? metadata : null
      return {details, metadata}
    },
    edgeDetails(index) {
      return this.edgeDetailsAndMetadata(index).details
    },
    parsedDetailCounts() {
      return {nodes: nodeSource.parsedCount, edges: edgeSource.parsedCount}
    },
  }
}
