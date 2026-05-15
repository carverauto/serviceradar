import {
  DESKTOP_PAYLOAD_DIRTY_RECT,
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  parseDesktopMediaMetadata,
} from "./media_frame"

const DEFAULT_TILE_SIZE = 64

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
  const payload = frame.payload || new Uint8Array(0)
  const regions = Array.isArray(metadata.tiles)
    ? metadata.tiles
    : Array.isArray(metadata.dirtyRects)
      ? metadata.dirtyRects
      : []

  return regions.flatMap((region) => uploadDescriptor(region, payload, metadata.tileSize))
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
