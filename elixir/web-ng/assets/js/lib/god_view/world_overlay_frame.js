import {tileId} from "./world_tile_cache"

export const WORLD_OVERLAY_MIME = "application/vnd.serviceradar.world-overlay"
export const WORLD_OVERLAY_MAX_BYTES = 262144
const HEALTH_STRIDE = 40
const EDGE_STRIDE = 220
const NIL_TIME = -9223372036854775808n
const healthFields = ["healthy", "unavailable", "unknown", "observed", "total"]
const eligibilityFields = ["physical", "ineligible", "not_physical_evidence", "excluded_role", "missing_interface_binding", "shared_interface", "unselected"]
const rateFields = ["packets_per_second", "observed_packets_per_second", "observed_octets_per_second", "octets_per_second"]
const timeFields = ["previous_observed_at", "earliest_observed_at", "observed_at"]
const invalid = () => {throw new Error("Invalid topology telemetry frame")}

// Includes the maximum metadata strings, fixed header and CPU/GPU attributes.
export function worldOverlayReservation(geometry) {
  return 815 + geometry.nodes.length * HEALTH_STRIDE + geometry.edges.length * EDGE_STRIDE + 8192 + geometry.edges.length * 128
}

/** Exact receipt + row order replaces repeated IDs. Records stay in their byte buffer. */
export function decodeWorldOverlay(input, geometry) {
  let bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  if (bytes.byteLength < 12 || bytes.byteLength > WORLD_OVERLAY_MAX_BYTES) invalid()
  if (bytes.buffer.byteLength > WORLD_OVERLAY_MAX_BYTES) bytes = bytes.slice()
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let offset = 0
  const take = size => {const at = offset; offset += size; if (offset > bytes.byteLength) invalid(); return at}
  const u8 = () => view.getUint8(take(1))
  const u16 = () => view.getUint16(take(2), true)
  const u32 = () => view.getUint32(take(4), true)
  const u64 = () => view.getBigUint64(take(8), true)
  const count = value => {if (value > BigInt(Number.MAX_SAFE_INTEGER)) invalid(); return Number(value)}
  const timeAt = at => {const value = view.getBigInt64(at, true); return value === NIL_TIME ? null : value}
  const timestamp = () => timeAt(take(8))
  const boolean = () => {const value = u8(); if (value > 1) invalid(); return value === 1}
  const enumeration = values => {const value = values[u8()]; if (value === undefined) invalid(); return value}
  const text = () => {
    const size = u16()
    if (size < 1 || size > 128) invalid()
    const at = take(size)
    const value = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(bytes.subarray(at, at + size))
    if (value.includes("\0")) invalid()
    return value
  }
  const nullableCount = () => {const present = boolean(); const value = count(u64()); if (!present && value !== 0) invalid(); return present ? value : null}
  if (u32() !== 0x4f545253 || u8() !== 1 || u8() !== 0 || u16() !== 0 || u32() !== bytes.byteLength) invalid()
  const overlay = {layout_version: text(), tile_id: text(), revision: text()}
  const health = {world_revision: text(), tile_revision: text()}
  overlay.generation = count(u64())
  if (overlay.layout_version !== geometry.key.layout_version || overlay.tile_id !== tileId(geometry.key) ||
      overlay.revision !== geometry.revision || overlay.generation !== geometry.generation) invalid()
  health.epoch = u64().toString(16).padStart(16, "0")
  for (const name of ["revision", "observation_sequence"]) health[name] = u64().toString()
  overlay.sampled_at = timestamp()
  health.sampled_at = timestamp()
  health.source = {source_status: enumeration(["stale", "seeding", "refreshing", "current"]), reconciling: boolean(), pending: u32(),
    last_read_at: timestamp(), reconciled_since: timestamp(), observed: nullableCount(), total: nullableCount()}
  const coverage = {}
  for (const name of ["rendered_relations", "selected_relations", "candidates_examined", "requested_pairs", "queried_pairs", "omitted_pairs"]) coverage[name] = u32()
  coverage.scan_complete = boolean()
  const query = {since: timestamp(), until: timestamp(), fresh_after: timestamp(), window_seconds: u32(), freshness_seconds: u32(), timeout_ms: u32()}
  const nodeCount = u16(), edgeCount = u16()
  if (nodeCount > 128 || edgeCount > 512 || nodeCount !== geometry.nodes.length || edgeCount !== geometry.edges.length) invalid()
  const healthOffset = take(nodeCount * HEALTH_STRIDE), edgeOffset = take(edgeCount * EDGE_STRIDE)
  if (offset !== bytes.byteLength) invalid()

  const healthAt = row => {
    if (!Number.isInteger(row) || row < 0 || row >= nodeCount) return null
    return Object.fromEntries(healthFields.map((name, index) => [name, count(view.getBigUint64(healthOffset + row * HEALTH_STRIDE + index * 8, true))]))
  }
  const intervalAt = at => {
    const values = timeFields.map((name, index) => [name, timeAt(at + index * 8)])
    if (values.every(([, value]) => value === null)) return null
    if (values.some(([, value]) => value === null)) invalid()
    return Object.fromEntries(values)
  }
  const directionAt = at => {
    const status = ["unknown", "partial", "measured"][view.getUint8(at)], animate = view.getUint8(at + 1)
    if (!status || animate > 1 || view.getUint16(at + 2, true) !== 0) invalid()
    const direction = {status, animate: animate === 1}
    rateFields.forEach((field, index) => {
      const position = at + 4 + index * 8, rate = view.getFloat64(position, true)
      if (Number.isNaN(rate) && view.getBigUint64(position, true) === 0x7ff8000000000000n) direction[field] = null
      else if (!Number.isFinite(rate) || rate < 0) invalid()
      else direction[field] = rate
    })
    direction.packet_observed_relations = view.getUint32(at + 36, true)
    direction.octet_observed_relations = view.getUint32(at + 40, true)
    direction.packet_interval = intervalAt(at + 44)
    direction.octet_interval = intervalAt(at + 68)
    return direction
  }
  const flowAt = row => {
    if (!Number.isInteger(row) || row < 0 || row >= edgeCount) return null
    const at = edgeOffset + row * EDGE_STRIDE
    const edge = {total_relations: view.getUint32(at, true), selected_relations: view.getUint32(at + 4, true),
      eligibility: Object.fromEntries(eligibilityFields.map((name, index) => [name, view.getUint32(at + 8 + index * 4, true)])),
      forward: directionAt(at + 36), reverse: directionAt(at + 128)}
    if (edge.total_relations !== geometry.edges[row].count || edge.selected_relations > edge.total_relations) invalid()
    return edge
  }
  // Validate every record before publishing, without retaining expanded row objects.
  for (let row = 0; row < nodeCount; row += 1) healthAt(row)
  for (let row = 0; row < edgeCount; row += 1) flowAt(row)
  return Object.assign(overlay, {health, flow: {coverage, query}, healthAt, flowAt,
    // Bounded metadata plus 64 bytes/edge each for CPU and GPU packet attributes.
    retainedBytes: bytes.buffer.byteLength + 8192 + edgeCount * 128})
}
