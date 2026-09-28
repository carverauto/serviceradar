// Mock of the host camera API (`api.camera`) for the dashboard dev harness.
// Tiles attach to a generated canvas test pattern instead of a relay session,
// so camera dashboards run offline. It keeps the production contract: the same
// states, the nine-session cap and the same error codes.

export const DEFAULT_MAX_CAMERA_SESSIONS = 9

export const CAMERA_API_ERRORS = Object.freeze({
  CAPABILITY_DENIED: "capability_denied",
  PERMISSION_DENIED: "permission_denied",
  SESSION_LIMIT: "session_limit",
  INVALID_REQUEST: "invalid_request",
})

export const CAMERA_HANDLE_STATES = Object.freeze({
  REQUESTING: "requesting",
  CONNECTING: "connecting",
  ACTIVATING: "activating",
  PLAYING: "playing",
  SUSPENDED: "suspended",
  UNAUTHORIZED: "unauthorized",
  FAILED: "failed",
  CLOSED: "closed",
})

function cameraError(code, message) {
  const error = new Error(message)
  error.name = "DashboardCameraError"
  error.code = code
  return error
}

function drawTestPattern(context, width, height, label, frame) {
  const bars = ["#e5e5e5", "#e5e500", "#00e5e5", "#00e500", "#e500e5", "#e50000", "#0000e5"]
  const barWidth = width / bars.length
  bars.forEach((color, index) => {
    context.fillStyle = color
    context.fillRect(index * barWidth, 0, barWidth + 1, height)
  })

  const sweep = (frame * 4) % width
  context.fillStyle = "rgba(0, 0, 0, 0.55)"
  context.fillRect(sweep, 0, 6, height)
  context.fillRect(0, height - 28, width, 28)
  context.fillStyle = "#ffffff"
  context.font = "14px monospace"
  context.fillText(`${label}  ${new Date().toISOString().slice(11, 19)}  (dev harness)`, 8, height - 9)
}

export function createHarnessCameraApi({onCall = () => {}, maxSessions = DEFAULT_MAX_CAMERA_SESSIONS, documentRef = globalThis.document} = {}) {
  const handles = new Set()

  const open = (request = {}) => {
    const cameraSourceId = String(request.camera_source_id || "").trim()
    const streamProfileId = String(request.stream_profile_id || "").trim()

    if (!cameraSourceId || !streamProfileId) {
      throw cameraError(CAMERA_API_ERRORS.INVALID_REQUEST, "camera.open requires camera_source_id and stream_profile_id")
    }

    if (handles.size >= maxSessions) {
      throw cameraError(CAMERA_API_ERRORS.SESSION_LIMIT, `a dashboard may hold at most ${maxSessions} camera sessions`)
    }

    const listeners = new Set()
    let state = null
    let canvas = null
    let animation = null
    let frame = 0

    const emit = (nextState) => {
      state = nextState
      for (const listener of listeners) listener({state, relay_session_id: `harness-${cameraSourceId}`})
    }

    const stopAnimation = () => {
      if (animation !== null) globalThis.cancelAnimationFrame?.(animation)
      animation = null
    }

    const animate = () => {
      const context = canvas?.getContext?.("2d")
      if (!context || state !== CAMERA_HANDLE_STATES.PLAYING) return
      drawTestPattern(context, canvas.width, canvas.height, request.label || cameraSourceId, frame)
      frame += 1
      animation = globalThis.requestAnimationFrame?.(animate) ?? null
    }

    const handle = {
      camera_source_id: cameraSourceId,
      stream_profile_id: streamProfileId,
      get state() {
        return state
      },
      get relaySessionId() {
        return state && state !== CAMERA_HANDLE_STATES.CLOSED ? `harness-${cameraSourceId}` : null
      },
      attach(element) {
        if (state === CAMERA_HANDLE_STATES.CLOSED) return handle
        if (!element || typeof element.appendChild !== "function") {
          throw cameraError(CAMERA_API_ERRORS.INVALID_REQUEST, "camera handle attach requires an element")
        }

        if (!canvas && documentRef?.createElement) {
          canvas = documentRef.createElement("canvas")
          canvas.width = 640
          canvas.height = 360
          canvas.style.width = "100%"
          canvas.style.height = "100%"
          element.appendChild(canvas)
        }

        emit(CAMERA_HANDLE_STATES.PLAYING)
        animate()
        return handle
      },
      onState(listener) {
        if (typeof listener !== "function") return () => {}
        listeners.add(listener)
        if (state) listener({state, relay_session_id: `harness-${cameraSourceId}`})
        return () => listeners.delete(listener)
      },
      suspend() {
        if (state === CAMERA_HANDLE_STATES.CLOSED) return
        stopAnimation()
        emit(CAMERA_HANDLE_STATES.SUSPENDED)
      },
      resume() {
        if (state !== CAMERA_HANDLE_STATES.SUSPENDED) return
        emit(canvas ? CAMERA_HANDLE_STATES.PLAYING : CAMERA_HANDLE_STATES.REQUESTING)
        animate()
      },
      close() {
        if (state === CAMERA_HANDLE_STATES.CLOSED) return
        stopAnimation()
        canvas?.remove?.()
        canvas = null
        handles.delete(handle)
        onCall(`camera close ${cameraSourceId}`)
        emit(CAMERA_HANDLE_STATES.CLOSED)
        listeners.clear()
      },
    }

    handles.add(handle)
    onCall(`camera open ${cameraSourceId}`)
    emit(CAMERA_HANDLE_STATES.REQUESTING)
    return handle
  }

  return {
    maxSessions,
    errors: CAMERA_API_ERRORS,
    states: CAMERA_HANDLE_STATES,
    allowed: () => true,
    open,
    activeCount: () => handles.size,
    closeAll: () => [...handles].forEach((handle) => handle.close()),
  }
}
