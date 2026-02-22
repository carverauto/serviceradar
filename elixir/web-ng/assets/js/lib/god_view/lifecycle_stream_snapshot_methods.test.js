import {describe, expect, it} from "vitest"

import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

function buildFrame(payloadBytes) {
  const payload = Uint8Array.from(payloadBytes)
  const out = new Uint8Array(53 + payload.length)
  out[0] = "G".charCodeAt(0)
  out[1] = "V".charCodeAt(0)
  out[2] = "B".charCodeAt(0)
  out[3] = "1".charCodeAt(0)

  const view = new DataView(out.buffer)
  view.setUint8(4, 2)
  view.setBigUint64(5, 42n, false)
  view.setBigInt64(13, 1_700_000_000_000n, false)
  view.setUint32(21, 11, false)
  view.setUint32(25, 12, false)
  view.setUint32(29, 13, false)
  view.setUint32(33, 14, false)
  view.setUint32(37, 3, false)
  view.setUint32(41, 4, false)
  view.setUint32(45, 5, false)
  view.setUint32(49, 6, false)
  out.set(payload, 53)

  return out.buffer
}

describe("lifecycle_stream_snapshot_methods", () => {
  it("parseBinarySnapshotFrame decodes header and payload", () => {
    const frame = buildFrame([7, 8, 9])
    const parsed = godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame)

    expect(parsed.schemaVersion).toEqual(2)
    expect(parsed.revision).toEqual(42)
    expect(parsed.bitmapMetadata.root_cause.bytes).toEqual(11)
    expect(parsed.bitmapMetadata.unknown.count).toEqual(6)
    expect(Array.from(parsed.payload)).toEqual([7, 8, 9])
  })

  it("parseSnapshotMessage supports binary tuple payload", () => {
    const methods = {...godViewLifecycleStreamSnapshotMethods}
    const frame = buildFrame([1, 2])
    const encoded = Buffer.from(new Uint8Array(frame)).toString("base64")

    const parsed = methods.parseSnapshotMessage(["binary", encoded])
    expect(Array.from(parsed.payload)).toEqual([1, 2])
  })

  it("parseBinarySnapshotFrame rejects invalid magic", () => {
    const frame = new Uint8Array(buildFrame([1]))
    frame[0] = "X".charCodeAt(0)

    expect(() => godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame.buffer)).toThrow(
      /unexpected binary snapshot magic/,
    )
  })
})
