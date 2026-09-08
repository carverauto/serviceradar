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
const SENSITIVE_POLICY_KEYS = new Set([
  "certificate_envelope",
  "credentials",
  "passphrase",
  "password",
  "private_key",
  "secret",
  "secret_payload",
  "ticket",
  "token",
])
const SENSITIVE_POLICY_SUFFIXES = ["_credential", "_password", "_secret", "_ticket", "_token"]

function positiveInteger(value, fallback = 0) {
  return Number.isInteger(value) && value > 0 ? value : fallback
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function setMaskBit(words, index) {
  words[index >>> 5] |= 1 << (index & 31)
}

export function normalizeDesktopPolicySnapshot(snapshot = {}) {
  const safeSnapshot = scrubDesktopPolicyValue(snapshot) || {}
  const target = safeObject(safeSnapshot.target)
  const route = safeObject(safeSnapshot.route)
  const credential = safeObject(safeSnapshot.credential)
  const authorization = safeObject(safeSnapshot.authorization)
  const timeouts = safeObject(safeSnapshot.timeouts)
  const desktop = safeObject(safeSnapshot.desktop)
  const recording = safeObject(safeSnapshot.recording)
  const targetTLS = safeObject(desktop.target_tls)
  const nla = safeObject(desktop.nla)
  const screenPolicy = safeObject(desktop.screen_policy)
  const redirectionPolicy = safeObject(desktop.redirection_policy)
  const approvalPolicy = safeObject(desktop.approval_policy)
  const recordingPolicy = safeObject(recording.policy)
  const enhancedRecordingPolicy = safeObject(recording.enhanced_policy)

  return {
    target: {
      label: stringValue(target.display_name) || stringValue(target.device_uid) || "Remote desktop",
      deviceUid: stringValue(target.device_uid),
      targetKind: stringValue(target.target_kind),
      protocol: stringValue(target.protocol) || "rdp",
    },
    route: {
      agentId: stringValue(route.agent_id),
      gatewayId: stringValue(route.gateway_id),
      label: routeLabel(route),
    },
    credential: {
      custodyMode: stringValue(credential.custody_mode) || "unknown",
      brokeredRuleBound: credential.brokered_rule_bound === true,
    },
    authorization: {
      rbacDecision: stringValue(authorization.rbac_decision) || "unknown",
      approvalId: stringValue(authorization.approval_id),
      approvalRequired: booleanValue(approvalPolicy.required),
    },
    transport: {
      tlsMode: stringValue(targetTLS.mode) || stringValue(targetTLS.trust_mode) || stringValue(targetTLS.policy),
      nlaRequired: booleanValue(nla.required),
    },
    screen: {
      maxWidth: integerValue(screenPolicy.max_width || screenPolicy.maxWidth),
      maxHeight: integerValue(screenPolicy.max_height || screenPolicy.maxHeight),
      maxFrameRate: integerValue(screenPolicy.max_frame_rate || screenPolicy.maxFrameRate),
      maxBitrateBps: integerValue(screenPolicy.max_bitrate_bps || screenPolicy.maxBitrateBps),
    },
    redirection: {
      clipboard: policyValue(redirectionPolicy.clipboard),
      drive: policyValue(redirectionPolicy.drive),
      printer: policyValue(redirectionPolicy.printer),
      audio: policyValue(redirectionPolicy.audio),
      smartCard: policyValue(redirectionPolicy.smart_card || redirectionPolicy.smartCard),
    },
    recording: {
      mode: stringValue(recordingPolicy.mode) || "metadata",
      enhancedEnabled: enhancedRecordingPolicy.enabled === true,
    },
    timeouts: {
      idleTimeoutSeconds: integerValue(timeouts.idle_timeout_seconds || timeouts.idleTimeoutSeconds),
      absoluteTimeoutSeconds: integerValue(timeouts.absolute_timeout_seconds || timeouts.absoluteTimeoutSeconds),
    },
  }
}

export function desktopPolicyStatusItems(snapshot = {}) {
  const policy = normalizeDesktopPolicySnapshot(snapshot)

  return [
    {key: "target", label: "Target", value: policy.target.label},
    {key: "route", label: "Route", value: policy.route.label},
    {key: "credential", label: "Credential", value: displayPolicyValue(policy.credential.custodyMode)},
    {
      key: "redirection",
      label: "Redirection",
      value: redirectionLabel(policy.redirection),
    },
    {
      key: "transport",
      label: "Transport",
      value: transportLabel(policy.transport),
    },
    {
      key: "quota",
      label: "Quota",
      value: screenQuotaLabel(policy.screen),
    },
    {
      key: "approval",
      label: "Approval",
      value: approvalLabel(policy.authorization),
    },
    {
      key: "recording",
      label: "Recording",
      value: displayPolicyValue(policy.recording.mode),
    },
  ]
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

function scrubDesktopPolicyValue(value) {
  if (Array.isArray(value)) {
    return value.map(scrubDesktopPolicyValue)
  }

  if (!value || typeof value !== "object") {
    return value
  }

  return Object.entries(value).reduce((acc, [key, nestedValue]) => {
    if (sensitivePolicyKey(key)) {
      return acc
    }

    const scrubbed = scrubDesktopPolicyValue(nestedValue)

    if (!emptyPolicyValue(scrubbed)) {
      acc[key] = scrubbed
    }

    return acc
  }, {})
}

function sensitivePolicyKey(key) {
  const normalized = String(key || "").toLowerCase()
  return SENSITIVE_POLICY_KEYS.has(normalized) || SENSITIVE_POLICY_SUFFIXES.some((suffix) => normalized.endsWith(suffix))
}

function emptyPolicyValue(value) {
  return value == null || (Array.isArray(value) && value.length === 0) || (isPlainObject(value) && Object.keys(value).length === 0)
}

function safeObject(value) {
  return isPlainObject(value) ? value : {}
}

function isPlainObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value))
}

function stringValue(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null
}

function integerValue(value) {
  return Number.isInteger(value) && value > 0 ? value : null
}

function booleanValue(value) {
  if (value === true || value === false) {
    return value
  }

  if (typeof value !== "string") {
    return false
  }

  return ["1", "true", "yes", "on", "required", "enabled"].includes(value.trim().toLowerCase())
}

function policyValue(value) {
  if (typeof value === "string" && value.trim().length > 0) {
    return value.trim().toLowerCase()
  }

  if (value === true) {
    return "enabled"
  }

  return "disabled"
}

function routeLabel(route) {
  return [stringValue(route.agent_id), stringValue(route.gateway_id)].filter(Boolean).join(" / ") || "Policy selected route"
}

function redirectionLabel(redirection) {
  const enabled = Object.entries(redirection)
    .filter(([, value]) => value !== "disabled" && value !== "deny" && value !== "denied")
    .map(([key]) => displayPolicyValue(key))

  return enabled.length > 0 ? enabled.join(", ") : "Disabled"
}

function transportLabel(transport) {
  const tls = displayPolicyValue(transport.tlsMode)
  const nla = transport.nlaRequired ? "NLA Required" : "NLA Not Required"

  return [tls === "Unknown" ? null : tls, nla].filter(Boolean).join(" / ")
}

function screenQuotaLabel(screen) {
  const dimensions =
    screen.maxWidth && screen.maxHeight
      ? `${screen.maxWidth}x${screen.maxHeight}`
      : null
  const frameRate = screen.maxFrameRate ? `${screen.maxFrameRate} fps` : null
  const bitrate = screen.maxBitrateBps ? `${screen.maxBitrateBps} bps` : null

  return [dimensions, frameRate, bitrate].filter(Boolean).join(" / ") || "Policy default"
}

function approvalLabel(authorization) {
  if (authorization.approvalRequired || authorization.approvalId) {
    return authorization.approvalId ? "Approved" : "Approval required"
  }

  return displayPolicyValue(authorization.rbacDecision)
}

function displayPolicyValue(value) {
  const normalized = stringValue(value)

  if (!normalized) {
    return "Unknown"
  }

  return normalized
    .replaceAll("_", " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase())
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
  let applied = 0

  for (const upload of uploads) {
    const source = compactCanvasUploadSource(upload)

    if (!source) {
      continue
    }

    context.putImageData(createImageData(source, upload.width, upload.height), upload.x, upload.y)
    applied += 1
  }

  return applied
}

export function applyWebGPUTileFrame(frame, queue, texture) {
  if (!queue || typeof queue.writeTexture !== "function" || !texture) {
    return 0
  }

  const uploads = desktopFrameUploadPlan(frame)

  for (const upload of uploads) {
    queue.writeTexture(
      {
        texture,
        origin: {x: upload.x, y: upload.y, z: 0},
      },
      upload.source,
      {
        bytesPerRow: upload.bytesPerRow,
        rowsPerImage: upload.height,
      },
      {
        width: upload.width,
        height: upload.height,
        depthOrArrayLayers: 1,
      }
    )
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

function compactCanvasUploadSource(upload) {
  const rowBytes = upload.width * 4
  const expectedBytes = rowBytes * upload.height

  if (upload.bytesPerRow === rowBytes && upload.source.byteLength === expectedBytes) {
    return upload.source
  }

  if (upload.bytesPerRow < rowBytes || upload.source.byteLength < rowBytes) {
    return null
  }

  const compacted = new Uint8Array(expectedBytes)

  for (let row = 0; row < upload.height; row += 1) {
    const sourceOffset = row * upload.bytesPerRow
    const sourceEnd = sourceOffset + rowBytes

    if (sourceEnd > upload.source.byteLength) {
      return null
    }

    compacted.set(upload.source.subarray(sourceOffset, sourceEnd), row * rowBytes)
  }

  return compacted
}
