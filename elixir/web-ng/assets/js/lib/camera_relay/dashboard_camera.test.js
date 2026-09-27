import {afterEach, beforeEach, describe, expect, test, vi} from "vitest"

import {
  CAMERA_API_ERRORS,
  CAMERA_HANDLE_STATES,
  DashboardCameraError,
  createDashboardCameraApi,
} from "./dashboard_camera"

const SOURCE = "11111111-1111-4111-8111-111111111111"
const PROFILE = "22222222-2222-4222-8222-222222222222"

function fakeElement(tagName) {
  return {tagName, style: {}, remove: vi.fn()}
}

function fakeDocument() {
  return {createElement: (tagName) => fakeElement(tagName)}
}

function fakeContainer() {
  return {children: [], appendChild: vi.fn(function (child) { this.children.push(child) })}
}

function jsonResponse(status, body) {
  return {ok: status >= 200 && status < 300, status, json: async () => body}
}

function relaySession(id = "relay-1") {
  return {
    id,
    viewer_stream_path: `/v1/camera-relay-sessions/${id}/stream`,
    webrtc_signaling_path: `/api/camera-relay-sessions/${id}/webrtc/session`,
    webrtc_ice_servers: [{urls: ["stun:stun.example.com:3478"]}],
    webrtc_playback_transport: "membrane_webrtc",
    available_playback_transports: ["websocket_h264_annexb_webcodecs"],
  }
}

function fakeViewerFactory() {
  const viewers = []
  const createViewer = (options) => {
    const viewer = {options, start: vi.fn(), close: vi.fn()}
    viewers.push(viewer)
    return viewer
  }
  return {viewers, createViewer}
}

async function flush() {
  for (let i = 0; i < 5; i += 1) await Promise.resolve()
}

function fakeTimers() {
  const pending = new Map()
  let next = 1
  return {
    pending,
    setTimer: vi.fn((callback, delayMs) => {
      const id = next++
      pending.set(id, {callback, delayMs})
      return id
    }),
    clearTimer: vi.fn((id) => pending.delete(id)),
    fireAll() {
      const due = [...pending.values()]
      pending.clear()
      due.forEach(({callback}) => callback())
    },
  }
}

function build({allowed = true, permitted = true, fetchImpl, maxSessions, hiddenReleaseGraceMs, timers} = {}) {
  const factory = fakeViewerFactory()
  const api = createDashboardCameraApi({
    capabilityAllowed: (capability) => allowed && capability === "camera.stream.view",
    permitted,
    maxSessions,
    fetchImpl: fetchImpl || vi.fn(async (url) => (url.endsWith("/close") ? jsonResponse(200, {}) : jsonResponse(201, {data: relaySession()}))),
    createViewer: factory.createViewer,
    documentRef: fakeDocument(),
    hiddenReleaseGraceMs,
    ...(timers ? {setTimer: timers.setTimer, clearTimer: timers.clearTimer} : {}),
  })
  return {api, ...factory}
}

function openError(api, request = {camera_source_id: SOURCE, stream_profile_id: PROFILE}) {
  try {
    api.open(request)
  } catch (error) {
    return error
  }
  return null
}

describe("dashboard camera API", () => {
  beforeEach(() => {
    globalThis.document = {querySelector: () => null}
  })

  afterEach(() => {
    delete globalThis.document
  })

  test("rejects packages without the camera capability before any request", () => {
    const fetchImpl = vi.fn()
    const {api} = build({allowed: false, fetchImpl})

    const error = openError(api)

    expect(error).toBeInstanceOf(DashboardCameraError)
    expect(error.code).toBe(CAMERA_API_ERRORS.CAPABILITY_DENIED)
    expect(fetchImpl).not.toHaveBeenCalled()
  })

  test("rejects users without camera permission before any request", () => {
    const fetchImpl = vi.fn()
    const {api} = build({permitted: false, fetchImpl})

    expect(openError(api).code).toBe(CAMERA_API_ERRORS.PERMISSION_DENIED)
    expect(fetchImpl).not.toHaveBeenCalled()
    expect(api.publicApi().allowed()).toBe(false)
  })

  test("requires both ids", () => {
    const {api} = build()

    expect(openError(api, {camera_source_id: SOURCE}).code).toBe(CAMERA_API_ERRORS.INVALID_REQUEST)
  })

  test("caps sessions per renderer with a distinguishable error and keeps existing ones", () => {
    const {api} = build({maxSessions: 2})

    const first = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE})
    api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE})

    expect(openError(api).code).toBe(CAMERA_API_ERRORS.SESSION_LIMIT)
    expect(api.activeCount()).toBe(2)
    expect(first.state).toBe(CAMERA_HANDLE_STATES.REQUESTING)
  })

  test("defaults to nine sessions", () => {
    const {api} = build()

    for (let i = 0; i < 9; i += 1) api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE})

    expect(openError(api).code).toBe(CAMERA_API_ERRORS.SESSION_LIMIT)
  })

  test("opens a relay session and plays it once attached", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse(201, {data: relaySession()}))
    const {api, viewers} = build({fetchImpl})
    const states = []

    const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE})
    handle.onState((event) => states.push(event.state))
    await flush()

    expect(fetchImpl).toHaveBeenCalledWith(
      "/api/camera-relay-sessions",
      expect.objectContaining({method: "POST", body: JSON.stringify({camera_source_id: SOURCE, stream_profile_id: PROFILE})})
    )
    expect(viewers).toHaveLength(0)

    const container = fakeContainer()
    handle.attach(container)

    expect(container.children.map((child) => child.tagName)).toEqual(["video", "canvas"])
    expect(viewers).toHaveLength(1)
    expect(viewers[0].start).toHaveBeenCalled()
    expect(viewers[0].options.streamPath).toBe("/v1/camera-relay-sessions/relay-1/stream")
    expect(viewers[0].options.webrtcSignalingPath).toBe("/api/camera-relay-sessions/relay-1/webrtc/session")
    expect(viewers[0].options.getVideo()).toBe(container.children[0])

    viewers[0].options.onStateChange("playing", {transport: "membrane_webrtc"})
    expect(handle.state).toBe(CAMERA_HANDLE_STATES.PLAYING)
    expect(states).toEqual(["requesting", "playing"])
  })

  test("reports unauthorized when the API refuses the user", async () => {
    const {api, viewers} = build({fetchImpl: vi.fn(async () => jsonResponse(403, {message: "forbidden"}))})

    const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    await flush()

    expect(handle.state).toBe(CAMERA_HANDLE_STATES.UNAUTHORIZED)
    expect(viewers).toHaveLength(0)
  })

  test("close releases the relay session softly and frees the slot", async () => {
    const fetchImpl = vi.fn(async (url) => (url.endsWith("/close") ? jsonResponse(200, {}) : jsonResponse(201, {data: relaySession()})))
    const {api, viewers} = build({fetchImpl})

    const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    await flush()
    handle.close()
    await flush()

    expect(viewers[0].close).toHaveBeenCalled()
    expect(fetchImpl).toHaveBeenLastCalledWith(
      "/api/camera-relay-sessions/relay-1/close",
      expect.objectContaining({method: "POST", keepalive: true, body: JSON.stringify({reason: "dashboard viewer closed"})})
    )
    expect(handle.state).toBe(CAMERA_HANDLE_STATES.CLOSED)
    expect(api.activeCount()).toBe(0)
  })

  test("closeAll closes every session the renderer opened", async () => {
    const fetchImpl = vi.fn(async (url) => (url.endsWith("/close") ? jsonResponse(200, {}) : jsonResponse(201, {data: relaySession()})))
    const {api} = build({fetchImpl})

    api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    await flush()
    api.closeAll()
    await flush()

    const closeCalls = fetchImpl.mock.calls.filter(([url]) => url.endsWith("/close"))
    expect(closeCalls).toHaveLength(2)
    expect(api.activeCount()).toBe(0)
  })

  test("a session that arrives after close is released, not played", async () => {
    let resolveOpen
    const fetchImpl = vi.fn((url) =>
      url.endsWith("/close")
        ? Promise.resolve(jsonResponse(200, {}))
        : new Promise((resolve) => {
            resolveOpen = resolve
          })
    )
    const {api, viewers} = build({fetchImpl})

    const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    handle.close()
    resolveOpen(jsonResponse(201, {data: relaySession("late")}))
    await flush()

    expect(viewers).toHaveLength(0)
    expect(fetchImpl.mock.calls.some(([url]) => url === "/api/camera-relay-sessions/late/close")).toBe(true)
  })

  test("suspend releases the session and resume requests a new one", async () => {
    const fetchImpl = vi.fn(async (url) => (url.endsWith("/close") ? jsonResponse(200, {}) : jsonResponse(201, {data: relaySession()})))
    const {api, viewers} = build({fetchImpl})

    const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
    await flush()
    api.suspendAll()
    await flush()

    expect(handle.state).toBe(CAMERA_HANDLE_STATES.SUSPENDED)
    expect(viewers[0].close).toHaveBeenCalled()
    expect(api.activeCount()).toBe(1)

    api.resumeAll()
    await flush()

    expect(viewers).toHaveLength(2)
    expect(fetchImpl.mock.calls.filter(([url]) => url === "/api/camera-relay-sessions")).toHaveLength(2)
  })

  describe("page visibility", () => {
    const closeCalls = (fetchImpl) => fetchImpl.mock.calls.filter(([url]) => url.endsWith("/close"))
    const openCalls = (fetchImpl) => fetchImpl.mock.calls.filter(([url]) => url === "/api/camera-relay-sessions")

    function setup(hiddenReleaseGraceMs) {
      const fetchImpl = vi.fn(async (url) => (url.endsWith("/close") ? jsonResponse(200, {}) : jsonResponse(201, {data: relaySession()})))
      const timers = fakeTimers()
      const built = build({fetchImpl, timers, hiddenReleaseGraceMs})
      return {fetchImpl, timers, ...built}
    }

    test("a hidden page keeps its sessions for the default 30 second grace period", async () => {
      const {api, fetchImpl, timers, viewers} = setup(undefined)
      const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      await flush()

      expect(timers.setTimer).toHaveBeenCalledWith(expect.any(Function), 30_000)
      expect(handle.state).not.toBe(CAMERA_HANDLE_STATES.SUSPENDED)
      expect(viewers[0].close).not.toHaveBeenCalled()
      expect(closeCalls(fetchImpl)).toHaveLength(0)
    })

    test("sessions are released once the page stays hidden past the grace period", async () => {
      const {api, fetchImpl, timers, viewers} = setup(5_000)
      const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      timers.fireAll()
      await flush()

      expect(handle.state).toBe(CAMERA_HANDLE_STATES.SUSPENDED)
      expect(viewers[0].close).toHaveBeenCalled()
      expect(closeCalls(fetchImpl)).toHaveLength(1)
    })

    test("becoming visible within the grace period keeps the original session", async () => {
      const {api, fetchImpl, timers, viewers} = setup(5_000)
      const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      api.pageVisible()
      timers.fireAll()
      await flush()

      expect(timers.clearTimer).toHaveBeenCalled()
      expect(handle.state).not.toBe(CAMERA_HANDLE_STATES.SUSPENDED)
      expect(viewers).toHaveLength(1)
      expect(closeCalls(fetchImpl)).toHaveLength(0)
      expect(openCalls(fetchImpl)).toHaveLength(1)
    })

    test("becoming visible after release reopens the sessions", async () => {
      const {api, fetchImpl, timers, viewers} = setup(5_000)
      api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      timers.fireAll()
      await flush()
      api.pageVisible()
      await flush()

      expect(viewers).toHaveLength(2)
      expect(openCalls(fetchImpl)).toHaveLength(2)
    })

    test("a zero grace period releases immediately", async () => {
      const {api, timers, viewers} = setup(0)
      const handle = api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      await flush()

      expect(timers.setTimer).not.toHaveBeenCalled()
      expect(handle.state).toBe(CAMERA_HANDLE_STATES.SUSPENDED)
      expect(viewers[0].close).toHaveBeenCalled()
    })

    test("closing every session cancels a pending hidden release", async () => {
      const {api, timers} = setup(5_000)
      api.open({camera_source_id: SOURCE, stream_profile_id: PROFILE}).attach(fakeContainer())
      await flush()

      api.pageHidden()
      api.closeAll()

      expect(timers.pending.size).toBe(0)
    })
  })
})

