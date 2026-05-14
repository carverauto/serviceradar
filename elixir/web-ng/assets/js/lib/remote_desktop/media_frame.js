const FRAME_MAGIC = "SRDP"
const FRAME_VERSION = 1
const FRAME_HEADER_SIZE = 48

const FLAG_KEYFRAME = 0x01
const FLAG_FULL_FRAME = 0x02
const FLAG_CURSOR_UPDATE = 0x04
const FLAG_END_OF_STREAM = 0x08
const FLAG_DISCONTINUITY = 0x10

export const DESKTOP_PAYLOAD_VIDEO = "video"
export const DESKTOP_PAYLOAD_DIRTY_RECT = "dirty_rect"
export const DESKTOP_PAYLOAD_TILE = "tile"
export const DESKTOP_PAYLOAD_CURSOR = "cursor"
export const DESKTOP_PAYLOAD_METADATA = "metadata"

export const DESKTOP_RENDERER_WEBCODECS_VIDEO = "webcodecs_video"
export const DESKTOP_RENDERER_WEBGPU_REGIONS = "webgpu_regions"
export const DESKTOP_RENDERER_CANVAS_REGIONS = "canvas_regions"

const PAYLOAD_FAMILY_TO_ID = {
  [DESKTOP_PAYLOAD_VIDEO]: 1,
  [DESKTOP_PAYLOAD_DIRTY_RECT]: 2,
  [DESKTOP_PAYLOAD_TILE]: 3,
  [DESKTOP_PAYLOAD_CURSOR]: 4,
  [DESKTOP_PAYLOAD_METADATA]: 5,
}

const PAYLOAD_ID_TO_FAMILY = Object.fromEntries(
  Object.entries(PAYLOAD_FAMILY_TO_ID).map(([family, id]) => [id, family])
)

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

function bytesFromString(value) {
  return textEncoder.encode(typeof value === "string" ? value : "")
}

function stringFromBytes(bytes) {
  return textDecoder.decode(bytes)
}

function bytesFromPayload(value) {
  if (!value) return new Uint8Array(0)
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  }

  throw new Error("desktop media payload must be bytes")
}

function metadataBytes(metadata) {
  if (!metadata) return new Uint8Array(0)
  if (metadata instanceof Uint8Array || metadata instanceof ArrayBuffer || ArrayBuffer.isView(metadata)) {
    return bytesFromPayload(metadata)
  }

  return bytesFromString(JSON.stringify(metadata))
}

function frameFlags(frame) {
  let flags = Number.isInteger(frame.flags) ? frame.flags & 0xff : 0
  if (frame.keyframe) flags |= FLAG_KEYFRAME
  if (frame.fullFrame) flags |= FLAG_FULL_FRAME
  if (frame.cursorUpdate) flags |= FLAG_CURSOR_UPDATE
  if (frame.endOfStream) flags |= FLAG_END_OF_STREAM
  if (frame.discontinuity) flags |= FLAG_DISCONTINUITY
  return flags
}

function checkedUint16Length(name, bytes) {
  if (bytes.byteLength > 0xffff) {
    throw new Error(`desktop media ${name} is too large`)
  }

  return bytes.byteLength
}

function checkedUint32Length(name, bytes) {
  if (bytes.byteLength > 0xffffffff) {
    throw new Error(`desktop media ${name} is too large`)
  }

  return bytes.byteLength
}

export function encodeDesktopMediaFrame(frame = {}) {
  const sessionBytes = bytesFromString(frame.sessionBindingId || frame.sessionId)
  const mediaSessionBytes = bytesFromString(frame.mediaSessionId)
  const encodingBytes = bytesFromString(frame.encoding)
  const metaBytes = metadataBytes(frame.metadata)
  const payloadBytes = bytesFromPayload(frame.payload)
  const payloadFamilyId = PAYLOAD_FAMILY_TO_ID[frame.payloadFamily]

  if (!payloadFamilyId) {
    throw new Error(`unsupported desktop media payload family: ${frame.payloadFamily}`)
  }

  const sessionLength = checkedUint16Length("session binding", sessionBytes)
  const mediaSessionLength = checkedUint16Length("media session", mediaSessionBytes)
  const encodingLength = checkedUint16Length("encoding", encodingBytes)
  const metadataLength = checkedUint32Length("metadata", metaBytes)
  const payloadLength = checkedUint32Length("payload", payloadBytes)
  const totalLength =
    FRAME_HEADER_SIZE +
    sessionLength +
    mediaSessionLength +
    encodingLength +
    metadataLength +
    payloadLength
  const bytes = new Uint8Array(totalLength)
  const view = new DataView(bytes.buffer)

  bytes.set(bytesFromString(FRAME_MAGIC), 0)
  view.setUint8(4, FRAME_VERSION)
  view.setUint8(5, frameFlags(frame))
  view.setUint8(6, payloadFamilyId)
  view.setUint8(7, 0)
  view.setBigUint64(8, BigInt(frame.sequence || 0), false)
  view.setBigInt64(16, BigInt(frame.timestampUnixNano || 0), false)
  view.setUint32(24, frame.width || 0, false)
  view.setUint32(28, frame.height || 0, false)
  view.setUint32(32, metadataLength, false)
  view.setUint32(36, payloadLength, false)
  view.setUint16(40, encodingLength, false)
  view.setUint16(42, sessionLength, false)
  view.setUint16(44, mediaSessionLength, false)
  view.setUint16(46, 0, false)

  let offset = FRAME_HEADER_SIZE
  bytes.set(sessionBytes, offset)
  offset += sessionLength
  bytes.set(mediaSessionBytes, offset)
  offset += mediaSessionLength
  bytes.set(encodingBytes, offset)
  offset += encodingLength
  bytes.set(metaBytes, offset)
  offset += metadataLength
  bytes.set(payloadBytes, offset)

  return bytes.buffer
}

export function parseDesktopMediaFrame(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data)

  if (bytes.byteLength < FRAME_HEADER_SIZE) {
    throw new Error("desktop media frame is truncated")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const magic = stringFromBytes(bytes.subarray(0, 4))

  if (magic !== FRAME_MAGIC) {
    throw new Error("desktop media frame magic mismatch")
  }

  const version = view.getUint8(4)
  if (version !== FRAME_VERSION) {
    throw new Error(`desktop media frame version ${version} is unsupported`)
  }

  const flags = view.getUint8(5)
  const payloadFamily = PAYLOAD_ID_TO_FAMILY[view.getUint8(6)]
  if (!payloadFamily) {
    throw new Error("desktop media frame payload family is unsupported")
  }

  const sequence = Number(view.getBigUint64(8, false))
  const timestampUnixNano = Number(view.getBigInt64(16, false))
  const width = view.getUint32(24, false)
  const height = view.getUint32(28, false)
  const metadataLength = view.getUint32(32, false)
  const payloadLength = view.getUint32(36, false)
  const encodingLength = view.getUint16(40, false)
  const sessionLength = view.getUint16(42, false)
  const mediaSessionLength = view.getUint16(44, false)
  const expectedLength =
    FRAME_HEADER_SIZE +
    sessionLength +
    mediaSessionLength +
    encodingLength +
    metadataLength +
    payloadLength

  if (expectedLength > bytes.byteLength) {
    throw new Error("desktop media frame payload is truncated")
  }

  let offset = FRAME_HEADER_SIZE
  const sessionBindingId = stringFromBytes(bytes.subarray(offset, offset + sessionLength))
  offset += sessionLength
  const mediaSessionId = stringFromBytes(bytes.subarray(offset, offset + mediaSessionLength))
  offset += mediaSessionLength
  const encoding = stringFromBytes(bytes.subarray(offset, offset + encodingLength))
  offset += encodingLength
  const metadata = bytes.subarray(offset, offset + metadataLength)
  offset += metadataLength
  const payload = bytes.subarray(offset, offset + payloadLength)

  return {
    version,
    flags,
    sequence,
    timestampUnixNano,
    width,
    height,
    payloadFamily,
    encoding,
    sessionBindingId,
    mediaSessionId,
    metadata,
    payload,
    keyframe: (flags & FLAG_KEYFRAME) !== 0,
    fullFrame: (flags & FLAG_FULL_FRAME) !== 0,
    cursorUpdate: (flags & FLAG_CURSOR_UPDATE) !== 0,
    endOfStream: (flags & FLAG_END_OF_STREAM) !== 0,
    discontinuity: (flags & FLAG_DISCONTINUITY) !== 0,
  }
}

export function parseDesktopMediaMetadata(frame) {
  if (!frame?.metadata || frame.metadata.byteLength === 0) return null
  return JSON.parse(stringFromBytes(frame.metadata))
}

export function detectDesktopRendererCapabilities(browser = globalThis) {
  const target = browser || {}
  const nav = target.navigator || globalThis.navigator || {}
  const canvas = target.HTMLCanvasElement?.prototype || globalThis.HTMLCanvasElement?.prototype

  return {
    webcodecs:
      typeof target.VideoDecoder === "function" ||
      (typeof globalThis !== "undefined" && typeof globalThis.VideoDecoder === "function"),
    webgpu: Boolean(nav.gpu),
    canvas2d: typeof canvas?.getContext === "function",
  }
}

export function selectDesktopRendererMode(
  payloadFamilies = [],
  capabilities = detectDesktopRendererCapabilities()
) {
  if (payloadFamilies.includes(DESKTOP_PAYLOAD_VIDEO) && capabilities.webcodecs) {
    return DESKTOP_RENDERER_WEBCODECS_VIDEO
  }

  const hasRegionPayload =
    payloadFamilies.includes(DESKTOP_PAYLOAD_DIRTY_RECT) || payloadFamilies.includes(DESKTOP_PAYLOAD_TILE)

  if (hasRegionPayload && capabilities.webgpu) {
    return DESKTOP_RENDERER_WEBGPU_REGIONS
  }

  if (hasRegionPayload && capabilities.canvas2d) {
    return DESKTOP_RENDERER_CANVAS_REGIONS
  }

  return null
}

export function shouldDropStaleDesktopFrame(frame, {decodeQueueSize = 0, maxDecodeQueueSize = 12} = {}) {
  if (decodeQueueSize <= maxDecodeQueueSize) return false
  if (frame?.keyframe || frame?.fullFrame || frame?.endOfStream || frame?.payloadFamily === DESKTOP_PAYLOAD_METADATA) {
    return false
  }

  return true
}
