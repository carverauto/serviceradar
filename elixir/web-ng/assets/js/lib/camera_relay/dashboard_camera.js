// Camera API exposed to dashboard packages (`api.camera`). A dashboard opens a
// handle per tile; the handle requests a relay session through the camera relay
// REST API, plays it through CameraRelayViewer into host-owned surfaces inside
// the element the dashboard attaches, and releases the session on close. The
// REST API authorizes every request; the capability and permission checks here
// only keep a package from asking for what it cannot have.

import {
  CAMERA_RELAY_MSE_TRANSPORT,
  CAMERA_RELAY_WEBRTC_TRANSPORT,
} from "./player"
import {CameraRelayViewer, jsonHeaders, playbackMetadataFromSnapshot} from "./viewer"

export const DEFAULT_MAX_CAMERA_SESSIONS = 9
export const CAMERA_STREAM_VIEW_CAPABILITY = "camera.stream.view"
const RELAY_SESSIONS_PATH = "/api/camera-relay-sessions"
const RELEASE_REASON = "dashboard viewer closed"

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

export class DashboardCameraError extends Error {
  constructor(code, message) {
    super(message)
    this.name = "DashboardCameraError"
    this.code = code
  }
}

function requiredId(value, field) {
  const id = String(value || "").trim()
  if (!id) {
    throw new DashboardCameraError(CAMERA_API_ERRORS.INVALID_REQUEST, `camera.open requires ${field}`)
  }
  return id
}

function surfaceElement(documentRef, tagName) {
  const element = documentRef.createElement(tagName)
  element.style.width = "100%"
  element.style.height = "100%"
  element.style.display = "none"

  if (tagName === "video") {
    element.autoplay = true
    element.muted = true
    element.playsInline = true
    element.style.objectFit = "contain"
  }

  return element
}

export function createDashboardCameraApi({
  capabilityAllowed = () => false,
  permitted = false,
  maxSessions = DEFAULT_MAX_CAMERA_SESSIONS,
  fetchImpl = (...args) => globalThis.fetch(...args),
  createViewer = (options) => new CameraRelayViewer(options),
  documentRef = globalThis.document,
} = {}) {
  const handles = new Set()

  const releaseSession = (relaySessionId) => {
    if (!relaySessionId) return

    void Promise.resolve()
      .then(() =>
        fetchImpl(`${RELAY_SESSIONS_PATH}/${relaySessionId}/close`, {
          method: "POST",
          headers: jsonHeaders(),
          credentials: "same-origin",
          keepalive: true,
          body: JSON.stringify({reason: RELEASE_REASON}),
        })
      )
      .catch(() => {})
  }

  const open = (request = {}) => {
    if (!capabilityAllowed(CAMERA_STREAM_VIEW_CAPABILITY)) {
      throw new DashboardCameraError(
        CAMERA_API_ERRORS.CAPABILITY_DENIED,
        `dashboard capability is not approved: ${CAMERA_STREAM_VIEW_CAPABILITY}`
      )
    }

    if (!permitted) {
      throw new DashboardCameraError(CAMERA_API_ERRORS.PERMISSION_DENIED, "camera viewing is not permitted for this user")
    }

    const cameraSourceId = requiredId(request.camera_source_id, "camera_source_id")
    const streamProfileId = requiredId(request.stream_profile_id, "stream_profile_id")

    if (handles.size >= maxSessions) {
      throw new DashboardCameraError(
        CAMERA_API_ERRORS.SESSION_LIMIT,
        `a dashboard may hold at most ${maxSessions} camera sessions`
      )
    }

    const listeners = new Set()
    let state = null
    let detail = {}
    let container = null
    let surfaces = null
    let relaySession = null
    let viewer = null
    let requestToken = 0

    const emit = (nextState, nextDetail = {}) => {
      state = nextState
      detail = nextDetail
      for (const listener of listeners) {
        try {
          listener({state, ...detail})
        } catch (_error) {}
      }
    }

    const setSurfaceVisibility = (transport) => {
      if (!surfaces) return
      const videoTransport = transport === CAMERA_RELAY_MSE_TRANSPORT || transport === CAMERA_RELAY_WEBRTC_TRANSPORT
      surfaces.video.style.display = videoTransport ? "block" : "none"
      surfaces.canvas.style.display = transport && !videoTransport ? "block" : "none"
    }

    const startViewer = () => {
      if (!relaySession || !container || viewer || state === CAMERA_HANDLE_STATES.CLOSED) return

      viewer = createViewer({
        streamPath: relaySession.viewer_stream_path,
        webrtcSignalingPath: relaySession.webrtc_signaling_path,
        iceServers: relaySession.webrtc_ice_servers || [],
        playbackMetadata: playbackMetadataFromSnapshot(relaySession),
        getCanvas: () => surfaces?.canvas || null,
        getVideo: () => surfaces?.video || null,
        setSurfaceVisibility,
        onStateChange: (viewerState, viewerDetail = {}) => {
          if (viewerState === CAMERA_HANDLE_STATES.CLOSED) return
          emit(viewerState, {...viewerDetail, relay_session_id: relaySession?.id || null})
        },
      })
      viewer.start()
    }

    const requestSession = async () => {
      const token = ++requestToken
      emit(CAMERA_HANDLE_STATES.REQUESTING)

      try {
        const response = await fetchImpl(RELAY_SESSIONS_PATH, {
          method: "POST",
          headers: jsonHeaders(),
          credentials: "same-origin",
          body: JSON.stringify({camera_source_id: cameraSourceId, stream_profile_id: streamProfileId}),
        })
        const body = await response.json().catch(() => ({}))

        if (token !== requestToken || state === CAMERA_HANDLE_STATES.CLOSED || state === CAMERA_HANDLE_STATES.SUSPENDED) {
          if (response.ok) releaseSession(body?.data?.id)
          return
        }

        if (response.status === 401 || response.status === 403) {
          emit(CAMERA_HANDLE_STATES.UNAUTHORIZED, {message: body?.message || "camera viewing is not permitted"})
          return
        }

        if (!response.ok || !body?.data?.id) {
          emit(CAMERA_HANDLE_STATES.FAILED, {
            reason: body?.error || "relay_session_unavailable",
            message: body?.message || "camera relay session could not be opened",
          })
          return
        }

        relaySession = body.data
        startViewer()
      } catch (error) {
        if (token !== requestToken || state === CAMERA_HANDLE_STATES.CLOSED) return
        emit(CAMERA_HANDLE_STATES.FAILED, {reason: "request_failed", message: error?.message || "request failed"})
      }
    }

    const release = () => {
      requestToken += 1

      if (viewer) {
        viewer.close()
        viewer = null
      }

      if (relaySession) {
        releaseSession(relaySession.id)
        relaySession = null
      }
    }

    const handle = {
      camera_source_id: cameraSourceId,
      stream_profile_id: streamProfileId,
      get state() {
        return state
      },
      get relaySessionId() {
        return relaySession?.id || null
      },
      attach(element) {
        if (state === CAMERA_HANDLE_STATES.CLOSED) return handle
        if (!element || typeof element.appendChild !== "function") {
          throw new DashboardCameraError(CAMERA_API_ERRORS.INVALID_REQUEST, "camera handle attach requires an element")
        }

        if (container !== element) {
          if (surfaces) {
            surfaces.video.remove?.()
            surfaces.canvas.remove?.()
          }

          container = element
          surfaces = {video: surfaceElement(documentRef, "video"), canvas: surfaceElement(documentRef, "canvas")}
          container.appendChild(surfaces.video)
          container.appendChild(surfaces.canvas)
        }

        startViewer()
        return handle
      },
      onState(listener) {
        if (typeof listener !== "function") return () => {}
        listeners.add(listener)
        if (state) {
          try {
            listener({state, ...detail})
          } catch (_error) {}
        }
        return () => listeners.delete(listener)
      },
      suspend() {
        if (state === CAMERA_HANDLE_STATES.CLOSED || state === CAMERA_HANDLE_STATES.SUSPENDED) return
        release()
        emit(CAMERA_HANDLE_STATES.SUSPENDED)
      },
      resume() {
        if (state !== CAMERA_HANDLE_STATES.SUSPENDED) return
        void requestSession()
      },
      close() {
        if (state === CAMERA_HANDLE_STATES.CLOSED) return
        release()

        if (surfaces) {
          surfaces.video.remove?.()
          surfaces.canvas.remove?.()
          surfaces = null
        }

        container = null
        handles.delete(handle)
        emit(CAMERA_HANDLE_STATES.CLOSED)
        listeners.clear()
      },
    }

    handles.add(handle)
    void requestSession()
    return handle
  }

  return {
    maxSessions,
    open,
    activeCount: () => handles.size,
    suspendAll: () => handles.forEach((handle) => handle.suspend()),
    resumeAll: () => handles.forEach((handle) => handle.resume()),
    closeAll: () => [...handles].forEach((handle) => handle.close()),
    // The part handed to dashboard packages.
    publicApi() {
      return {
        maxSessions,
        errors: CAMERA_API_ERRORS,
        states: CAMERA_HANDLE_STATES,
        allowed: () => capabilityAllowed(CAMERA_STREAM_VIEW_CAPABILITY) && permitted,
        open,
        activeCount: () => handles.size,
      }
    },
  }
}
