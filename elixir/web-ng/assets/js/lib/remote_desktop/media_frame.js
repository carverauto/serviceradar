const FRAME_VERSION = 1
const FRAME_HEADER_SIZE = 48
const FRAME_MAGIC_BYTES = new Uint8Array([0x53, 0x52, 0x44, 0x50])

const FLAG_KEYFRAME = 0x01
const FLAG_FULL_FRAME = 0x02
const FLAG_CURSOR_UPDATE = 0x04
const FLAG_END_OF_STREAM = 0x08
const FLAG_DISCONTINUITY = 0x10
const FLAG_ALLOWED =
  FLAG_KEYFRAME | FLAG_FULL_FRAME | FLAG_CURSOR_UPDATE | FLAG_END_OF_STREAM | FLAG_DISCONTINUITY

export const DESKTOP_PAYLOAD_VIDEO = "video"
export const DESKTOP_PAYLOAD_DIRTY_RECT = "dirty_rect"
export const DESKTOP_PAYLOAD_TILE = "tile"
export const DESKTOP_PAYLOAD_CURSOR = "cursor"
export const DESKTOP_PAYLOAD_METADATA = "metadata"

export const DESKTOP_RENDERER_WEBCODECS_VIDEO = "webcodecs_video"
export const DESKTOP_RENDERER_WEBGPU_REGIONS = "webgpu_regions"
export const DESKTOP_RENDERER_CANVAS_REGIONS = "canvas_regions"

export const DESKTOP_TRANSPORT_WEBRTC = "webrtc_desktop_media"

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

function sameBytes(left, right) {
  if (!left || left.byteLength !== right.byteLength) return false

  for (let index = 0; index < right.byteLength; index += 1) {
    if (left[index] !== right[index]) return false
  }

  return true
}

function stableStringFromBytes(bytes, cache, field) {
  if (!cache) return stringFromBytes(bytes)

  const cached = cache[field]
  if (cached && sameBytes(cached.bytes, bytes)) {
    return cached.value
  }

  const value = stringFromBytes(bytes)
  cache[field] = {bytes: bytes.slice(), value}

  return value
}

function hasFrameMagic(bytes) {
  return (
    bytes[0] === FRAME_MAGIC_BYTES[0] &&
    bytes[1] === FRAME_MAGIC_BYTES[1] &&
    bytes[2] === FRAME_MAGIC_BYTES[2] &&
    bytes[3] === FRAME_MAGIC_BYTES[3]
  )
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
  let flags = 0
  if (Number.isInteger(frame.flags)) {
    if (frame.flags < 0 || frame.flags > 0xff || (frame.flags & ~FLAG_ALLOWED) !== 0) {
      throw new Error("desktop media frame flags are unsupported")
    }

    flags = frame.flags
  }

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

  bytes.set(FRAME_MAGIC_BYTES, 0)
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
  return parseDesktopMediaFrameWithCache(data)
}

export function createDesktopMediaFrameParser() {
  const stableStringCache = {}

  return (data) => parseDesktopMediaFrameWithCache(data, stableStringCache)
}

function parseDesktopMediaFrameWithCache(data, stableStringCache = null) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data)

  if (bytes.byteLength < FRAME_HEADER_SIZE) {
    throw new Error("desktop media frame is truncated")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

  if (!hasFrameMagic(bytes)) {
    throw new Error("desktop media frame magic mismatch")
  }

  const version = view.getUint8(4)
  if (version !== FRAME_VERSION) {
    throw new Error(`desktop media frame version ${version} is unsupported`)
  }

  if (view.getUint8(7) !== 0 || view.getUint16(46, false) !== 0) {
    throw new Error("desktop media frame reserved header bytes are set")
  }

  const flags = view.getUint8(5)
  if ((flags & ~FLAG_ALLOWED) !== 0) {
    throw new Error("desktop media frame flags are unsupported")
  }

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

  if (expectedLength !== bytes.byteLength) {
    throw new Error("desktop media frame has trailing bytes")
  }

  let offset = FRAME_HEADER_SIZE
  const sessionBindingId = stableStringFromBytes(
    bytes.subarray(offset, offset + sessionLength),
    stableStringCache,
    "sessionBindingId"
  )
  offset += sessionLength
  const mediaSessionId = stableStringFromBytes(
    bytes.subarray(offset, offset + mediaSessionLength),
    stableStringCache,
    "mediaSessionId"
  )
  offset += mediaSessionLength
  const encoding = stableStringFromBytes(
    bytes.subarray(offset, offset + encodingLength),
    stableStringCache,
    "encoding"
  )
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
  const peerConnection =
    target.RTCPeerConnection ||
    (typeof globalThis !== "undefined" ? globalThis.RTCPeerConnection : undefined)
  let rtcDataChannel = false

  if (typeof peerConnection === "function") {
    try {
      rtcDataChannel = typeof peerConnection.prototype?.createDataChannel === "function"
    } catch (_error) {
      rtcDataChannel = false
    }
  }

  return {
    webcodecs:
      typeof target.VideoDecoder === "function" ||
      (typeof globalThis !== "undefined" && typeof globalThis.VideoDecoder === "function"),
    webgpu: Boolean(nav.gpu),
    canvas2d: typeof canvas?.getContext === "function",
    rtc_peer_connection: typeof peerConnection === "function",
    rtc_data_channel: rtcDataChannel,
  }
}

function normalizeTransportList(value) {
  if (!Array.isArray(value)) return []

  return value
    .map((transport) => (typeof transport === "string" ? transport.trim() : ""))
    .filter((transport) => transport.length > 0)
}

function transportSupported(transport, capabilities) {
  switch (transport) {
    case DESKTOP_TRANSPORT_WEBRTC:
      return capabilities.rtc_peer_connection === true && capabilities.rtc_data_channel === true

    default:
      return false
  }
}

export function selectDesktopMediaTransport(
  metadata = {},
  capabilities = detectDesktopRendererCapabilities()
) {
  const available = normalizeTransportList(metadata.availableTransports || metadata.available_transports)
  const preferred =
    typeof metadata.preferredTransport === "string"
      ? metadata.preferredTransport
      : typeof metadata.preferred_transport === "string"
        ? metadata.preferred_transport
        : null
  const defaults = [DESKTOP_TRANSPORT_WEBRTC]
  const candidates =
    available.length > 0
      ? [preferred, ...available.filter((transport) => transport !== preferred)].filter(Boolean)
      : [preferred, ...defaults.filter((transport) => transport !== preferred)].filter(Boolean)

  for (const transport of candidates) {
    if (transportSupported(transport, capabilities)) {
      return {
        supported: true,
        selectedTransport: transport,
        preferredTransport: preferred || DESKTOP_TRANSPORT_WEBRTC,
        availableTransports: available.length > 0 ? available : defaults,
      }
    }
  }

  return {
    supported: false,
    selectedTransport: null,
    preferredTransport: preferred || DESKTOP_TRANSPORT_WEBRTC,
    availableTransports: available.length > 0 ? available : defaults,
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
