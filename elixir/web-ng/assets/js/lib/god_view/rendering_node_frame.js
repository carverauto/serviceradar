/**
 * Per-graph node render records and the typed columns drawn from them.
 *
 * The render path used to spread every node into a fresh object twice per render (once to
 * attach visibility, once more for the deck layers), so a filter toggle, a hover, a click or
 * a camera move rebuilt the whole node set. Here each node of a laid-out graph gets one
 * record, built once and cached against that graph's `nodes` array. A render only writes the
 * per-node visibility into a reused `Uint8Array` and selects records by reference.
 *
 * A record carries the node's own fields plus `index`, `position` and `zHeight`. Fields that
 * change between renders -- `selected`, `visible` and `stateReason` -- are read from the
 * frame's current state rather than stored, so nothing per node is rewritten when they change.
 */

const frames = new WeakMap()
const nodeLayerData = new WeakMap()

class GodViewNodeRecord {
  get selected() {
    return this.frame.selectedNodeIndex === this.index
  }

  get visible() {
    const mask = this.frame.mask
    return Boolean(mask) && mask[this.index] === 1
  }

  get stateReason() {
    return this.frame.stateReason(this)
  }
}

function copyNodeFields(record, node) {
  for (const key of Object.keys(node)) {
    const descriptor = Object.getOwnPropertyDescriptor(node, key)
    if (typeof descriptor?.get === "function") {
      // Keep the decoder's lazy fields (details and what derives from it) lazy.
      Object.defineProperty(record, key, {
        configurable: true,
        enumerable: true,
        get() {
          return node[key]
        },
        set(value) {
          Object.defineProperty(record, key, {value, writable: true, enumerable: true, configurable: true})
        },
      })
    } else if (key !== "selected" && key !== "visible" && key !== "stateReason") {
      record[key] = descriptor.value
    }
  }
  // Inspect the descriptor rather than the value, so a lazy `details` accessor is not forced.
  const details = Object.getOwnPropertyDescriptor(record, "details")
  if (!details || (!details.get && !details.value)) record.details = {}
}

function lazyValue(record, key, compute) {
  Object.defineProperty(record, key, {
    configurable: true,
    enumerable: true,
    get() {
      const value = compute()
      Object.defineProperty(record, key, {value, writable: true, enumerable: true, configurable: true})
      return value
    },
  })
}

function buildFrame(context, nodes, shape) {
  const count = nodes.length
  const frame = {
    owner: context,
    shape,
    records: new Array(count),
    states: new Uint8Array(count),
    mask: new Uint8Array(count),
    incidentFlags: new Uint8Array(count),
    byId: new Map(),
    byNormalizedId: new Map(),
    selectedNodeIndex: null,
    edgeData: [],
    stateReason: () => "",
  }

  for (let index = 0; index < count; index += 1) {
    const node = nodes[index] || {}
    const record = new GodViewNodeRecord()
    copyNodeFields(record, node)
    record.frame = frame
    record.index = index
    record.zHeight = 0
    record.pps = Number(node.pps || 0)
    record.operUp = Number(node.operUp || 0)
    record.label = context.normalizeDisplayLabel(node.label, node.id || `node-${index + 1}`)
    record.position = [node.x, node.y, 0]
    record.statusIcon = context.nodeStatusIcon(record.operUp)
    lazyValue(record, "metricText", () => context.nodeMetricText(record, shape))
    // `frame` is bookkeeping, not node data: keep it out of spreads and serialization.
    Object.defineProperty(record, "frame", {enumerable: false})

    frame.records[index] = record
    frame.states[index] = Number(node.state)
    frame.byId.set(record.id, record)
    frame.byNormalizedId.set(String(record.id || ""), record)
  }

  return frame
}

/**
 * Returns the cached render frame for a graph's node array, building it on first use.
 * The frame is rebuilt only when the node array itself changes (a new snapshot, layout
 * or recluster), never for a filter, hover, selection or camera change.
 */
export function nodeRenderFrame(context, nodes, shape) {
  const safeNodes = Array.isArray(nodes) ? nodes : []
  const cached = frames.get(safeNodes)
  if (cached && cached.owner === context && cached.shape === shape) return cached
  const frame = buildFrame(context, safeNodes, shape)
  frames.set(safeNodes, frame)
  return frame
}

/**
 * Deck.gl binary data for the node glyph layers: `data.length` plus a packed `getPosition`
 * attribute, so luma uploads the Float32Array as-is instead of walking objects.
 *
 * Cached per `nodeData` array, so a camera refresh that reuses the frame's node list hands
 * deck the same data object and nothing is re-packed or re-uploaded.
 */
export function nodeGlyphLayerData(nodeData) {
  const nodes = Array.isArray(nodeData) ? nodeData : []
  const cached = nodeLayerData.get(nodes)
  if (cached) return cached

  const positions = new Float32Array(nodes.length * 2)
  for (let i = 0; i < nodes.length; i += 1) {
    const position = nodes[i]?.position
    positions[i * 2] = Number(position?.[0])
    positions[i * 2 + 1] = Number(position?.[1])
  }
  const data = {
    length: nodes.length,
    attributes: {getPosition: {value: positions, size: 2}},
    nodes,
  }
  nodeLayerData.set(nodes, data)
  return data
}

/** Resolves the node a binary node layer picked, since deck only reports its index. */
export function pickedNodeObject(info) {
  if (!info || info.object || !Number.isInteger(info.index) || info.index < 0) return info
  const nodes = info.layer?.props?.data?.nodes
  const object = Array.isArray(nodes) ? nodes[info.index] : undefined
  return object ? {...info, object} : info
}
