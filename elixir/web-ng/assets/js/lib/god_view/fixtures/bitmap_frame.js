import {FRAME_FIELDS} from "../bitmap_frame"

export const bitmapBinding = {
  dictionary_epoch: "synthetic-dictionary", index_epoch: "synthetic-index",
  query_digest: "synthetic-query", authority_fingerprint: "synthetic-authority", view_digest: "synthetic-view",
}
const encoder = new TextEncoder()

/** Independent synthetic wire writer; production encoding belongs to Elixir. */
export function bitmapFrame({kind = "baseline", sequence = 1n, total = 9002, binding = {}, tiles = []} = {}) {
  const parts = []
  const number = (size, value) => {
    const bytes = new Uint8Array(size)
    const view = new DataView(bytes.buffer)
    if (size === 1) view.setUint8(0, value)
    else if (size === 2) view.setUint16(0, value, true)
    else if (size === 4) view.setUint32(0, value, true)
    else view.setBigUint64(0, value, true)
    parts.push(bytes)
  }
  const text = value => {const bytes = encoder.encode(value); number(2, bytes.length); parts.push(bytes)}
  parts.push(encoder.encode("SRMO"))
  number(1, 1); number(1, kind === "reset" ? 1 : 0); number(2, 0); number(4, 0); number(8, sequence); number(4, total)
  const fields = {...bitmapBinding, source_revision: "9007199254740993", index_revision: "9007199254740995", ...binding}
  for (const field of FRAME_FIELDS) text(fields[field])
  if (kind !== "reset") {
    number(1, tiles.length)
    for (const tile of tiles) {
      number(1, tile.z); number(4, tile.x); number(4, tile.y); text(tile.revision); number(2, tile.mask.length)
      parts.push(Uint8Array.from(tile.mask), Uint8Array.from(tile.causal), Uint8Array.from(tile.availability))
      for (const count of tile.counts) number(4, count)
    }
  }
  const frame = new Uint8Array(parts.reduce((total, bytes) => total + bytes.length, 0))
  let offset = 0
  for (const bytes of parts) {frame.set(bytes, offset); offset += bytes.length}
  new DataView(frame.buffer).setUint32(8, frame.length, true)
  return frame
}
