import {
  DESKTOP_PAYLOAD_DIRTY_RECT,
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  parseDesktopMediaMetadata,
} from "./media_frame"

const DEFAULT_TILE_SIZE = 64
const DEFAULT_RENDER_QUEUE_MAX_FRAMES = 12
const ARROW_IPC_FORMAT = "arrow_ipc"
const METADATA_ATTACHMENT_ROLES = new Set(["metadata", "stats", "audit_stats", "overlay", "frame_manifest"])

function positiveInteger(value, fallback = 0) {
  return Number.isInteger(value) && value > 0 ? value : fallback
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function setMaskBit(words, index) {
  words[index >>> 5] |= 1 << (index & 31)
}

export function createDirtyTileMask({width = 0, height = 0, tileSize = DEFAULT_TILE_SIZE} = {}, dirtyRects = []) {
  const safeTileSize = positiveInteger(tileSize, DEFAULT_TILE_SIZE)
  const safeWidth = positiveInteger(width)
  const safeHeight = positiveInteger(height)
  const columns = Math.ceil(safeWidth / safeTileSize)
  const rows = Math.ceil(safeHeight / safeTileSize)
  const words = new Uint32Array(Math.ceil((columns * rows) / 32))

  if (columns === 0 || rows === 0 || !Array.isArray(dirtyRects)) {
    return {columns, rows, tileSize: safeTileSize, words}
  }

  for (const rect of dirtyRects) {
    const x = clamp(positiveInteger(rect?.x), 0, safeWidth)
    const y = clamp(positiveInteger(rect?.y), 0, safeHeight)
    const rectWidth = positiveInteger(rect?.width)
    const rectHeight = positiveInteger(rect?.height)

    if (rectWidth === 0 || rectHeight === 0 || x >= safeWidth || y >= safeHeight) {
      continue
    }

    const right = clamp(x + rectWidth, 0, safeWidth)
    const bottom = clamp(y + rectHeight, 0, safeHeight)
    const startColumn = Math.floor(x / safeTileSize)
    const endColumn = Math.max(startColumn, Math.ceil(right / safeTileSize) - 1)
    const startRow = Math.floor(y / safeTileSize)
    const endRow = Math.max(startRow, Math.ceil(bottom / safeTileSize) - 1)

    for (let row = startRow; row <= endRow; row += 1) {
      for (let column = startColumn; column <= endColumn; column += 1) {
        if (column >= 0 && column < columns && row >= 0 && row < rows) {
          setMaskBit(words, row * columns + column)
        }
      }
    }
  }

  return {columns, rows, tileSize: safeTileSize, words}
}

export function dirtyTileMaskHas(mask, column, row) {
  if (!mask || column < 0 || row < 0 || column >= mask.columns || row >= mask.rows) {
    return false
  }

  const index = row * mask.columns + column
  return (mask.words[index >>> 5] & (1 << (index & 31))) !== 0
}

export function desktopFrameUploadPlan(frame) {
  if (!frame || frame.payloadFamily === DESKTOP_PAYLOAD_METADATA) {
    return []
  }
  if (frame.payloadFamily !== DESKTOP_PAYLOAD_TILE && frame.payloadFamily !== DESKTOP_PAYLOAD_DIRTY_RECT) {
    return []
  }

  const metadata = parseDesktopMediaMetadata(frame) || {}
  if (isArrowIPCFormat(frame.encoding) || isArrowIPCFormat(metadata.format) || isArrowIPCFormat(metadata.payloadFormat)) {
    return []
  }

  const payload = frame.payload || new Uint8Array(0)
  const regions = Array.isArray(metadata.tiles)
    ? metadata.tiles
    : Array.isArray(metadata.dirtyRects)
      ? metadata.dirtyRects
      : []

  return regions.flatMap((region) => uploadDescriptor(region, payload, metadata.tileSize))
}

export function desktopMetadataAttachment(frame) {
  if (!frame || frame.payloadFamily !== DESKTOP_PAYLOAD_METADATA) {
    return null
  }

  const metadata = parseDesktopMediaMetadata(frame) || {}
  const role = normalizeMetadataRole(metadata.role || metadata.kind)

  if (!METADATA_ATTACHMENT_ROLES.has(role)) {
    return null
  }

  return {
    role,
    format: normalizeMetadataFormat(metadata.format || metadata.contentType || metadata.content_type),
    metadata,
    bytes: frame.payload || new Uint8Array(0),
  }
}

export function createDesktopRenderQueue({maxFrames = DEFAULT_RENDER_QUEUE_MAX_FRAMES} = {}) {
  const safeMaxFrames = positiveInteger(maxFrames, DEFAULT_RENDER_QUEUE_MAX_FRAMES)
  const frames = []

  return {
    push(frame) {
      if (!frame) {
        return {accepted: false, dropped: [], coalesced: false}
      }

      if (frames.length < safeMaxFrames) {
        frames.push(frame)
        return {accepted: true, dropped: [], coalesced: false}
      }

      if (isCriticalDesktopFrame(frame)) {
        const dropIndex = frames.findIndex((queuedFrame) => !isCriticalDesktopFrame(queuedFrame))

        if (dropIndex === -1) {
          return {accepted: false, dropped: [frame], coalesced: false}
        }

        const [dropped] = frames.splice(dropIndex, 1)
        frames.push(frame)

        return {accepted: true, dropped: [dropped], coalesced: false}
      }

      const replaceIndex = replaceableDesktopFrameIndex(frames, frame)

      if (replaceIndex === -1) {
        return {accepted: false, dropped: [frame], coalesced: false}
      }

      const dropped = frames[replaceIndex]
      frames[replaceIndex] = frame

      return {accepted: true, dropped: [dropped], coalesced: true}
    },

    shift() {
      return frames.shift() || null
    },

    clear() {
      frames.length = 0
    },

    state() {
      return {decodeQueueSize: frames.length, maxDecodeQueueSize: safeMaxFrames}
    },

    snapshot() {
      return frames.slice()
    },

    get length() {
      return frames.length
    },
  }
}

function isCriticalDesktopFrame(frame) {
  return Boolean(frame?.keyframe || frame?.fullFrame || frame?.endOfStream || frame?.payloadFamily === DESKTOP_PAYLOAD_METADATA)
}

function replaceableDesktopFrameIndex(frames, frame) {
  for (let index = frames.length - 1; index >= 0; index -= 1) {
    const queuedFrame = frames[index]

    if (
      !isCriticalDesktopFrame(queuedFrame) &&
      sameDesktopMediaBinding(queuedFrame, frame) &&
      queuedFrame.payloadFamily === frame.payloadFamily
    ) {
      return index
    }
  }

  return -1
}

function sameDesktopMediaBinding(left, right) {
  return left?.sessionBindingId === right?.sessionBindingId && left?.mediaSessionId === right?.mediaSessionId
}

function normalizeMetadataRole(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim().toLowerCase() : "metadata"
}

function normalizeMetadataFormat(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim().toLowerCase() : "json"
}

function isArrowIPCFormat(value) {
  return normalizeMetadataFormat(value).replaceAll("-", "_") === ARROW_IPC_FORMAT
}

function uploadDescriptor(region, payload, defaultTileSize) {
  const x = positiveInteger(region?.x)
  const y = positiveInteger(region?.y)
  const width = positiveInteger(region?.width, positiveInteger(defaultTileSize, DEFAULT_TILE_SIZE))
  const height = positiveInteger(region?.height, positiveInteger(defaultTileSize, DEFAULT_TILE_SIZE))
  const payloadOffset = positiveInteger(region?.payloadOffset)
  const payloadLength = positiveInteger(region?.payloadLength)
  const bytesPerRow = positiveInteger(region?.bytesPerRow, width * 4)
  const end = payloadOffset + payloadLength

  if (width === 0 || height === 0 || payloadLength === 0 || end > payload.byteLength) {
    return []
  }

  return [
    {
      x,
      y,
      width,
      height,
      bytesPerRow,
      payloadOffset,
      payloadLength,
      source: payload.subarray(payloadOffset, end),
    },
  ]
}

export function applyCanvasTileFrame(frame, context, createImageData = defaultImageDataFactory) {
  if (!context || typeof context.putImageData !== "function") {
    return 0
  }

  const uploads = desktopFrameUploadPlan(frame)

  for (const upload of uploads) {
    context.putImageData(createImageData(upload.source, upload.width, upload.height), upload.x, upload.y)
  }

  return uploads.length
}

function defaultImageDataFactory(bytes, width, height) {
  return new globalThis.ImageData(
    new Uint8ClampedArray(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    width,
    height
  )
}
