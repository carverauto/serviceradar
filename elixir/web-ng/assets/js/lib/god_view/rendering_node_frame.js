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
 * change between renders -- `selected`, `visible` and `stateReason` -- and the display-only
 * `metricText` / `statusIcon` are prototype getters over the frame's current state, so
 * nothing per node is rewritten when they change.
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

  get metricText() {
    return this.frame.metricText(this)
  }

  get statusIcon() {
    return this.frame.statusIcon(this.operUp)
  }
}

const COMPUTED_FIELDS = new Set(["selected", "visible", "stateReason", "metricText", "statusIcon"])

function copyNodeFields(record, node) {
  for (const key of Object.keys(node)) {
    if (!COMPUTED_FIELDS.has(key)) record[key] = node[key]
  }
  // Reading `details` hands back the (possibly lazy) object without parsing it.
  if (!record.details || typeof record.details !== "object") record.details = {}
}

function buildFrame(context, nodes, shape) {
  const count = nodes.length
  const frame = {
    owner: context,
    shape,
    records: new Array(count),
    states: new Uint8Array(count),
    mask: new Uint8Array(count),
    maskVersion: 0,
    glyphData: null,
    incidentFlags: new Uint8Array(count),
    byId: new Map(),
    byNormalizedId: new Map(),
    selectedNodeIndex: null,
    edgeData: [],
    stateReason: () => "",
    metricText: (record) => context.nodeMetricText(record, shape),
    statusIcon: (operUp) => context.nodeStatusIcon(operUp),
  }
  // `frame` lives on this graph's record prototype: every record reaches it, and it stays out
  // of spreads and serialization without a per-record property definition.
  class FrameNodeRecord extends GodViewNodeRecord {}
  FrameNodeRecord.prototype.frame = frame

  for (let index = 0; index < count; index += 1) {
    const node = nodes[index] || {}
    const record = new FrameNodeRecord()
    copyNodeFields(record, node)
    record.index = index
    record.zHeight = 0
    record.pps = Number(node.pps || 0)
    record.operUp = Number(node.operUp || 0)
    record.label = context.normalizeDisplayLabel(node.label, node.id || `node-${index + 1}`)
    record.position = [node.x, node.y, 0]

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

function packGlyphData(nodes) {
  const positions = new Float32Array(nodes.length * 2)
  for (let i = 0; i < nodes.length; i += 1) {
    const position = nodes[i]?.position
    positions[i * 2] = Number(position?.[0])
    positions[i * 2 + 1] = Number(position?.[1])
  }
  return {
    length: nodes.length,
    attributes: {getPosition: {value: positions, size: 2}},
    nodes,
  }
}

/**
 * Deck.gl binary data for the node glyph layers: `data.length` plus a packed `getPosition`
 * attribute, so luma uploads the Float32Array as-is instead of walking objects.
 *
 * When `nodeFrame` is given (the real render path), positions are packed once for every
 * node the accepted layout produced and cached on the frame itself, so a filter, hover,
 * selection or camera change reuses the exact same `Float32Array` -- only `frame.mask`
 * (rewritten in place) says which glyphs a render should actually draw. Without a frame
 * (direct calls, e.g. in tests, with a plain node array) positions are packed for just the
 * given nodes and cached per that array, so a camera refresh that reuses the same node list
 * still hands deck the same data object.
 */
export function nodeGlyphLayerData(nodeData, nodeFrame = null) {
  if (nodeFrame) {
    if (!nodeFrame.glyphData) nodeFrame.glyphData = packGlyphData(nodeFrame.records)
    return nodeFrame.glyphData
  }

  const nodes = Array.isArray(nodeData) ? nodeData : []
  const cached = nodeLayerData.get(nodes)
  if (cached) return cached

  const data = packGlyphData(nodes)
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
