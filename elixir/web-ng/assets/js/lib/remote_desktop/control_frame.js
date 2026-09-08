const DEFAULT_PROTOCOL = "rdp"
const MAX_INPUT_TOKEN_BYTES = 128
const textEncoder = new TextEncoder()

export const DESKTOP_FRAME_INPUT = "desktop.input"
export const DESKTOP_FRAME_RESIZE = "desktop.resize"
export const DESKTOP_INPUT_KEY = "key"
export const DESKTOP_INPUT_POINTER = "pointer"
export const DESKTOP_INPUT_FOCUS = "focus"

function stringValue(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : ""
}

function sessionID(session = {}) {
  return stringValue(session.id) || stringValue(session.session_id)
}

function protocol(session = {}) {
  return stringValue(session.protocol) || stringValue(session?.desktop_policy_snapshot?.target?.protocol) || DEFAULT_PROTOCOL
}

function boundedToken(value) {
  const token = stringValue(value)

  if (!token || textEncoder.encode(token).byteLength > MAX_INPUT_TOKEN_BYTES) {
    return ""
  }

  return token
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0 ? value : 0
}

function clampCoordinate(value, max) {
  if (!Number.isFinite(value) || max <= 0) {
    return 0
  }

  return Math.max(0, Math.min(Math.floor(value), max))
}

function baseFrame(session, frameType) {
  const id = sessionID(session)

  if (!id) {
    return null
  }

  return {
    session_id: id,
    protocol: protocol(session),
    frame_type: frameType,
  }
}

export function buildDesktopKeyFrame(session, {key, down = false} = {}) {
  const frame = baseFrame(session, DESKTOP_FRAME_INPUT)
  const safeKey = boundedToken(key)

  if (!frame || !safeKey) {
    return null
  }

  return {
    ...frame,
    input: {
      kind: DESKTOP_INPUT_KEY,
      key: safeKey,
      down: down === true,
    },
  }
}

export function buildDesktopFocusFrame(session, focused) {
  const frame = baseFrame(session, DESKTOP_FRAME_INPUT)

  if (!frame) {
    return null
  }

  return {
    ...frame,
    input: {
      kind: DESKTOP_INPUT_FOCUS,
      focused: focused === true,
    },
  }
}

export function buildDesktopResizeFrame(session, {width, height} = {}) {
  const frame = baseFrame(session, DESKTOP_FRAME_RESIZE)
  const safeWidth = positiveInteger(width)
  const safeHeight = positiveInteger(height)

  if (!frame || safeWidth === 0 || safeHeight === 0) {
    return null
  }

  return {
    ...frame,
    width: safeWidth,
    height: safeHeight,
  }
}

export function buildDesktopPointerFrame(session, event, canvas, {down = false, button = null} = {}) {
  const frame = baseFrame(session, DESKTOP_FRAME_INPUT)
  const rect = canvas?.getBoundingClientRect?.()
  const width = positiveInteger(canvas?.width)
  const height = positiveInteger(canvas?.height)

  if (!frame || !rect || width === 0 || height === 0 || rect.width <= 0 || rect.height <= 0) {
    return null
  }

  const safeButton = boundedToken(button || pointerButton(event?.button))

  return {
    ...frame,
    input: {
      kind: DESKTOP_INPUT_POINTER,
      x: clampCoordinate((event.clientX - rect.left) * (width / rect.width), width),
      y: clampCoordinate((event.clientY - rect.top) * (height / rect.height), height),
      ...(safeButton ? {button: safeButton} : {}),
      down: down === true,
    },
  }
}

export function sendDesktopControlFrame(client, frame) {
  if (!frame || typeof client?.sendControl !== "function") {
    return false
  }

  return client.sendControl(frame)
}

function pointerButton(button) {
  switch (button) {
    case 0:
      return "left"
    case 1:
      return "middle"
    case 2:
      return "right"
    default:
      return ""
  }
}
