/** Synthetic SRTO wire fixture, independently written from the Elixir encoder. */
export const telemetryGeometry = {
  key: {layout_version: "synthetic-layout", z: 0, x: 0, y: 0}, generation: 7, revision: "synthetic-tile",
  nodes: [{index: 0}, {index: 1}], edges: [{index: 0, count: 3}],
}
export const telemetryTime = 1893456000123456n

export function telemetryFrame(geometry = telemetryGeometry, {complete = false, health = null} = {}) {
  const parts = []
  const integer = (size, value) => {
    const bytes = new Uint8Array(size), view = new DataView(bytes.buffer)
    if (size === 1) view.setUint8(0, value)
    else if (size === 2) view.setUint16(0, value, true)
    else if (size === 4) view.setUint32(0, value, true)
    else view.setBigInt64(0, BigInt(value), true)
    parts.push(bytes)
  }
  const text = value => {const bytes = new TextEncoder().encode(value); integer(2, bytes.length); parts.push(bytes)}
  const time = (value = telemetryTime) => integer(8, value)
  const rate = value => {const bytes = new Uint8Array(8); new DataView(bytes.buffer).setFloat64(0, value, true); parts.push(bytes)}
  parts.push(new TextEncoder().encode("SRTO"))
  integer(1, 1); integer(1, 0); integer(2, 0); integer(4, 0)
  for (const value of [geometry.key.layout_version, `${geometry.key.z}/${geometry.key.x}/${geometry.key.y}`, geometry.revision, "synthetic-world", "synthetic-selection"]) text(value)
  for (const value of [geometry.generation, 9007199254740993n, 9007199254740995n, 9007199254740997n]) integer(8, value)
  time(); time(); integer(1, 2); integer(1, 1); integer(4, 4); time(); time(-9223372036854775808n)
  integer(1, 1); integer(8, 2); integer(1, 0); integer(8, 0)
  const total = complete ? geometry.edges.reduce((sum, edge) => sum + edge.count, 0) : 3
  for (const value of [total, complete ? total : 2, 9, 4, 3, 1]) integer(4, value)
  integer(1, 0)
  time(telemetryTime - 900000000n); time(); time(telemetryTime - 120000000n)
  for (const value of [900, 120, 5000]) integer(4, value)
  integer(2, geometry.nodes.length); integer(2, geometry.edges.length)
  for (let row = 0; row < geometry.nodes.length; row += 1) {
    const total = geometry.nodes[row].count ?? 2, healthy = Math.min(row % 2, total)
    for (const count of health?.[row] || [healthy, 0, total - healthy, healthy, total]) integer(8, count)
  }
  for (const edge of geometry.edges) {
    for (const count of [edge.count, complete ? edge.count : 2, complete ? edge.count : 1, 0, 0, 0, 0,
      complete ? 0 : 1, complete ? 0 : edge.count - 2]) integer(4, count)
    for (let direction = 0; direction < 2; direction += 1) {
      integer(1, direction === 0 ? 1 : 0); integer(1, direction === 0 ? 1 : 0); integer(2, 0)
      for (const value of [NaN, direction === 0 ? 12.5 : NaN, direction === 0 ? 0 : NaN, NaN]) rate(value)
      integer(4, direction === 0 ? 1 : 0); integer(4, direction === 0 ? 1 : 0)
      for (let index = 0; index < 6; index += 1) time(direction === 0 ? telemetryTime + BigInt(index % 3) : -9223372036854775808n)
    }
  }
  const frame = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0))
  let offset = 0
  for (const part of parts) {frame.set(part, offset); offset += part.length}
  new DataView(frame.buffer).setUint32(8, frame.length, true)
  return frame
}
