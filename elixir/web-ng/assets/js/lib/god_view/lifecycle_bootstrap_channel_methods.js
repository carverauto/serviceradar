import {godViewLifecycleBootstrapChannelEventMethods} from "./lifecycle_bootstrap_channel_event_methods"

const SNAPSHOT_MAGIC = "GVB1"
const SNAPSHOT_HEADER_BYTES = 53

function parseHeaderInt(headers, name) {
  const raw = headers?.get?.(name)
  const parsed = Number(raw)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
}

function parseGeneratedAtMs(headers, name) {
  const raw = headers?.get?.(name)
  if (typeof raw !== "string" || raw.trim() === "") return 0
  const parsed = Date.parse(raw)
  return Number.isFinite(parsed) ? parsed : 0
}

const godViewLifecycleBootstrapChannelCoreMethods = {
  buildSnapshotFrameFromHttpResponse(payloadBuffer, headers) {
    const payload = new Uint8Array(payloadBuffer || new ArrayBuffer(0))
    const out = new Uint8Array(SNAPSHOT_HEADER_BYTES + payload.byteLength)
    out[0] = SNAPSHOT_MAGIC.charCodeAt(0)
    out[1] = SNAPSHOT_MAGIC.charCodeAt(1)
    out[2] = SNAPSHOT_MAGIC.charCodeAt(2)
    out[3] = SNAPSHOT_MAGIC.charCodeAt(3)

    const schemaVersion = parseHeaderInt(headers, "x-sr-god-view-schema")
    const revision = parseHeaderInt(headers, "x-sr-god-view-revision")
    const generatedAtMs = parseGeneratedAtMs(headers, "x-sr-god-view-generated-at")
    const view = new DataView(out.buffer)

    view.setUint8(4, schemaVersion)
    view.setBigUint64(5, BigInt(revision), false)
    view.setBigInt64(13, BigInt(generatedAtMs), false)
    view.setUint32(21, parseHeaderInt(headers, "x-sr-god-view-bitmap-root-bytes"), false)
    view.setUint32(25, parseHeaderInt(headers, "x-sr-god-view-bitmap-affected-bytes"), false)
    view.setUint32(29, parseHeaderInt(headers, "x-sr-god-view-bitmap-healthy-bytes"), false)
    view.setUint32(33, parseHeaderInt(headers, "x-sr-god-view-bitmap-unknown-bytes"), false)
    view.setUint32(37, parseHeaderInt(headers, "x-sr-god-view-bitmap-root-count"), false)
    view.setUint32(41, parseHeaderInt(headers, "x-sr-god-view-bitmap-affected-count"), false)
    view.setUint32(45, parseHeaderInt(headers, "x-sr-god-view-bitmap-healthy-count"), false)
    view.setUint32(49, parseHeaderInt(headers, "x-sr-god-view-bitmap-unknown-count"), false)
    out.set(payload, SNAPSHOT_HEADER_BYTES)

    return out.buffer
  },
}

export const godViewLifecycleBootstrapChannelMethods = Object.assign(
  {},
  godViewLifecycleBootstrapChannelCoreMethods,
  godViewLifecycleBootstrapChannelEventMethods,
)
