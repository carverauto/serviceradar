export const BITMAP_FRAME_BYTES = 256 * 1024
export const BINDING_FIELDS = Object.freeze([
  "dictionary_epoch", "query_digest", "authority_fingerprint", "view_digest",
])
export const FRAME_FIELDS = Object.freeze([
  "dictionary_epoch", "index_epoch", "query_digest", "authority_fingerprint", "view_digest", "source_revision", "index_revision",
])
const decoder = new TextDecoder("utf-8", {fatal: true})

function valid(condition, field) {
  if (!condition) throw new Error(`Invalid topology membership: ${field}`)
}

class Reader {
  constructor(bytes) {
    this.bytes = bytes
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    this.offset = 0
  }
  take(length) {
    valid(length >= 0 && this.offset + length <= this.bytes.length, "truncated frame")
    const value = this.bytes.subarray(this.offset, this.offset + length)
    this.offset += length
    return value
  }
  number(size) {
    const offset = this.offset
    this.take(size)
    return size === 1 ? this.view.getUint8(offset) : size === 2 ? this.view.getUint16(offset, true) : this.view.getUint32(offset, true)
  }
  sequence() {
    const offset = this.offset
    this.take(8)
    return this.view.getBigUint64(offset, true)
  }
  text() {
    const length = this.number(2)
    valid(length > 0 && length <= 128, "string length")
    const text = decoder.decode(this.take(length))
    valid(!text.includes("\0"), "string encoding")
    return text
  }
  done() {valid(this.offset === this.bytes.length, "trailing bytes")}
}

/** Complete admitted-row overlays. Three u8 columns retain views of wire bytes. */
export function decodeBitmapFrame(input) {
  valid(input instanceof Uint8Array || input instanceof ArrayBuffer, "binary frame required")
  let bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  valid(bytes.byteLength >= 20 && bytes.byteLength <= BITMAP_FRAME_BYTES, "frame byte budget")
  // Do not pin an oversized transport backing buffer through a small subview.
  if (bytes.buffer.byteLength > BITMAP_FRAME_BYTES) bytes = bytes.slice()
  const reader = new Reader(bytes)
  valid(decoder.decode(reader.take(4)) === "SRMO", "magic")
  valid(reader.number(1) === 1, "protocol")
  const kind = ["baseline", "reset"][reader.number(1)]
  valid(kind, "payload kind")
  valid(reader.number(2) === 0, "reserved bytes")
  valid(reader.number(4) === bytes.length, "frame length")
  const frame = {kind, sequence: reader.sequence(), byteLength: bytes.length}
  for (const field of FRAME_FIELDS) frame[field] = reader.text()
  frame.tiles = new Map()
  if (kind === "baseline") {
    const count = reader.number(1)
    valid(count <= 64, "tile count")
    for (let index = 0; index < count; index += 1) {
      const z = reader.number(1)
      const x = reader.number(4)
      const y = reader.number(4)
      valid(z <= 24 && x < 2 ** z && y < 2 ** z, "tile key")
      const key = `${z}/${x}/${y}`
      valid(!frame.tiles.has(key), "duplicate tile")
      const revision = reader.text()
      const rows = reader.number(2)
      valid(rows <= 128, "row budget")
      const mask = reader.take(rows)
      const causal = reader.take(rows)
      const availability = reader.take(rows)
      // Count bytes are not necessarily aligned in Phoenix's payload view.
      const counts = new Uint32Array(rows)
      for (let row = 0; row < rows; row += 1) {
        counts[row] = reader.number(4)
        valid(mask[row] <= 1 && causal[row] <= 3 && availability[row] <= 2, "row state")
        valid(mask[row] === Number(counts[row] > 0), "row count")
      }
      frame.tiles.set(key, {key, revision, mask, causal, availability, counts})
    }
  }
  reader.done()
  return frame
}
