import {afterEach, describe, expect, it, vi} from "vitest"

import CameraRelayStatusStream from "./CameraRelayStatusStream"

function roleElement() {
  const classes = new Set()
  return {
    textContent: "",
    dataset: {},
    classList: {
      add(...names) {
        for (const name of names) classes.add(name)
      },
      remove(...names) {
        for (const name of names) classes.delete(name)
      },
      contains(name) {
        return classes.has(name)
      },
      toggle(name, force) {
        if (force === undefined) {
          if (classes.has(name)) {
            classes.delete(name)
          } else {
            classes.add(name)
          }
        } else if (force) {
          classes.add(name)
        } else {
          classes.delete(name)
        }
      },
    },
  }
}

function buildHookElement() {
  const roles = new Map([
    ["video-poster", roleElement()],
    ["video-canvas", roleElement()],
    ["video-element", roleElement()],
    ["binary-stats", roleElement()],
    ["transport-status", roleElement()],
    ["player-status", roleElement()],
    ["compatibility-status", roleElement()],
    ["relay-detail", roleElement()],
    ["relay-status", roleElement()],
    ["playback-state", roleElement()],
    ["viewer-count", roleElement()],
    ["termination-kind", roleElement()],
    ["failure-reason", roleElement()],
    ["close-reason", roleElement()],
  ])

  return {
    dataset: {
      streamPath: "/v1/camera-relay-sessions/test/stream",
      preferredPlaybackTransport: "websocket_h264_annexb_webcodecs",
      availablePlaybackTransports: "websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse",
      playbackCodecHint: "h264",
      playbackContainerHint: "annexb",
    },
    querySelector(selector) {
      const match = selector.match(/\[data-role=['"]([^'"]+)['"]\]/)
      if (!match) {
        return null
      }

      return roles.get(match[1]) || null
    },
    roles,
  }
}

function createMockWebSocketClass() {
  return class MockWebSocket {
    static instances = []
    static OPEN = 1

    constructor(url) {
      this.url = url
      this.handlers = {}
      this.closed = false
      this.readyState = MockWebSocket.OPEN
      this.sent = []
      MockWebSocket.instances.push(this)
    }

    addEventListener(event, callback) {
      this.handlers[event] = callback
    }

    emit(event, payload) {
      this.handlers[event]?.(payload)
    }

    send(data) {
      this.sent.push(data)
    }

    close() {
      this.closed = true
      this.readyState = 3
    }
  }
}

const mountedHooks = []

function mountHook(hook) {
  mountedHooks.push(hook)
  CameraRelayStatusStream.mounted.call(hook)
}

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalFetch = globalThis.fetch
const originalWebSocket = globalThis.WebSocket

afterEach(() => {
  for (const hook of mountedHooks.splice(0)) {
    CameraRelayStatusStream.destroyed.call(hook)
  }
  globalThis.window = originalWindow
  globalThis.document = originalDocument
  globalThis.fetch = originalFetch
  globalThis.WebSocket = originalWebSocket
  vi.useRealTimers()
  vi.restoreAllMocks()
})


async function mountWebRtcViewer({fetchImpl, socketOpen = true} = {}) {
  vi.useFakeTimers()
  const element = buildHookElement()
  element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
  element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
  const video = new EventTarget()
  video.dataset = {}
  video.classList = {toggle() {}}
  video.play = vi.fn(() => Promise.resolve())
  element.roles.set("video-element", video)

  class PeerConnection extends EventTarget {
    constructor() {
      super()
      this.connectionState = "new"
      this.iceConnectionState = "new"
      this.closed = false
      this.addedCandidates = []
    }
    async setRemoteDescription() {}
    async addIceCandidate(candidate) { this.addedCandidates.push(candidate) }
    async createAnswer() { return {type: "answer", sdp: "v=0\r\nm=video"} }
    async setLocalDescription() {}
    close() { this.closed = true }
  }

  const MockWebSocket = createMockWebSocketClass()
  if (!socketOpen) {
    const BaseMockWebSocket = MockWebSocket
    const ClosedByDefaultWebSocket = class extends BaseMockWebSocket {
      constructor(url) {
        super(url)
        this.readyState = 0
      }
    }
    globalThis.WebSocket = ClosedByDefaultWebSocket
    globalThis.window = Object.assign(new EventTarget(), {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: PeerConnection,
      WebSocket: ClosedByDefaultWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaStream: class MediaStream {
        constructor(tracks) { this.tracks = tracks }
      },
    })
  } else {
    globalThis.WebSocket = MockWebSocket
    globalThis.window = Object.assign(new EventTarget(), {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: PeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaStream: class MediaStream {
        constructor(tracks) { this.tracks = tracks }
      },
    })
  }
  globalThis.document = {querySelector: () => null}
  globalThis.fetch = vi.fn(fetchImpl || (async (_url, options) => ({
    ok: true,
    json: async () => options.method === "POST" && !options.body
      ? {data: {viewer_session_id: "viewer-ice-test", offer_sdp: "v=0\r\nm=video"}}
      : {data: {signaling_state: "answer_applied"}},
  })))
  const hook = {...CameraRelayStatusStream, el: element}
  mountHook(hook)
  await vi.advanceTimersByTimeAsync(0)
  return {hook, video, peer: hook.viewer.peerConnection, sockets: MockWebSocket.instances, element}
}

describe("CameraRelayStatusStream", () => {
  it.each(["stalled", "connected_without_media", "negotiated_track_without_media"])(
    "opens websocket media within eight seconds when WebRTC is %s",
    async (scenario) => {
      const {hook, peer, sockets, video} = await mountWebRtcViewer()
      if (scenario === "connected_without_media") {
        peer.connectionState = "connected"
        peer.dispatchEvent(new Event("connectionstatechange"))
      } else if (scenario === "negotiated_track_without_media") {
        const track = new Event("track")
        track.streams = [{}]
        peer.dispatchEvent(track)
      }
      await vi.advanceTimersByTimeAsync(7999)
      expect(sockets).toHaveLength(1)
      await vi.advanceTimersByTimeAsync(1)
      expect(sockets).toHaveLength(2)
      expect(sockets[0].closed).toBe(true)
      expect(sockets[1].url).toBe("wss://example.com/v1/camera-relay-sessions/test/stream")
      expect(peer.closed).toBe(true)
      expect(video.srcObject).toBeNull()
      expect(hook.viewer.socket).toBe(sockets[1])
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test",
        expect.objectContaining({method: "DELETE"})
      )
    }
  )

  it("falls back immediately on ICE failure even while connectionState stays connecting", async () => {
    const {hook, peer, sockets} = await mountWebRtcViewer()
    peer.connectionState = "connecting"
    peer.iceConnectionState = "failed"
    peer.dispatchEvent(new Event("iceconnectionstatechange"))
    expect(sockets).toHaveLength(2)
    expect(hook.viewer.socket).toBe(sockets[1])
    peer.connectionState = "failed"
    peer.dispatchEvent(new Event("connectionstatechange"))
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(2)
  })

  it("falls back on its server-side viewer closure and ignores another viewer's closure", async () => {
    const {hook, peer, sockets} = await mountWebRtcViewer()
    const statusSocket = sockets[0]
    const closed = {
      type: "camera_relay_webrtc_closed",
      relay_session_id: "relay-test",
      viewer_session_id: "another-viewer",
      reason: "webrtc viewer connection failed",
    }
    statusSocket.emit("message", {data: JSON.stringify(closed)})
    expect(sockets).toHaveLength(1)
    closed.viewer_session_id = "viewer-ice-test"
    statusSocket.emit("message", {data: JSON.stringify(closed)})
    expect(sockets).toHaveLength(2)
    expect(hook.viewer.socket).toBe(sockets[1])
    expect(peer.closed).toBe(true)
  })

  // The core-elx offer declares its track with no stream (`a=msid:- <track>`), so the
  // browser fires `track` with empty `streams`; the viewer must still play it.
  it.each(["with_stream", "without_stream"])("keeps WebRTC once video starts playing (%s) and cancels the deadline on close", async (shape) => {
    const {hook, peer, video, sockets} = await mountWebRtcViewer()
    const track = new Event("track")
    track.track = {kind: "video"}
    track.streams = shape === "with_stream" ? [{}] : []
    peer.dispatchEvent(track)
    peer.connectionState = "connected"
    peer.dispatchEvent(new Event("connectionstatechange"))
    video.dispatchEvent(new Event("playing"))
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(1)
    if (shape === "with_stream") {
      expect(video.srcObject).toBe(track.streams[0])
    } else {
      expect(video.srcObject.tracks).toEqual([track.track])
    }
    CameraRelayStatusStream.destroyed.call(hook)
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(1)
    expect(peer.closed).toBe(true)
  })

  // A reload or tab close never runs the hook's destroyed(); without this the
  // relay keeps the viewer's sink until ICE times out and logs it as a crash.
  it("releases its WebRTC viewer session when the page is hidden", async () => {
    const {peer} = await mountWebRtcViewer()
    globalThis.window.dispatchEvent(new Event("pagehide"))
    expect(peer.closed).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test",
      expect.objectContaining({method: "DELETE", keepalive: true})
    )
  })

  it("never opens a fallback socket after the viewer is destroyed during stalled ICE", async () => {
    const {hook, peer, sockets} = await mountWebRtcViewer()
    CameraRelayStatusStream.destroyed.call(hook)
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(1)
    expect(sockets[0].closed).toBe(true)
    expect(peer.closed).toBe(true)
  })

  it("renders an explicit unsupported-browser state when no playback transport is usable", () => {
    const element = buildHookElement()

    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
    }

    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      socket: null,
      player: null,
    }

    mountHook(hook)

    expect(element.roles.get("transport-status").textContent).toBe("Browser playback unsupported")
    expect(element.roles.get("player-status").textContent).toBe(
      "This browser cannot decode the current relay transport."
    )
    expect(element.roles.get("compatibility-status").textContent).toContain("Unsupported browser transport")
    expect(element.roles.get("relay-detail").textContent).toContain("either WebCodecs or an MSE-capable H264 browser")
    expect(hook.viewer.socket).toBeNull()
  })

  // A relay-only server peer is unreachable until the browser installs a TURN
  // permission for its relay candidate, and it only does that for candidates
  // it was given. core-elx trickles them after the offer.
  it("adds every server ICE candidate from the answer and from polling until connected when statusSocket is not open", async () => {
    const host = {candidate: "candidate:1 1 UDP 2122252543 192.0.2.20 40000 typ host", sdpMid: "0"}
    const relay = {candidate: "candidate:2 1 UDP 16777215 198.51.100.30 49200 typ relay", sdpMid: "0"}
    const pollUrl = "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test"
    const {peer} = await mountWebRtcViewer({
      socketOpen: false,
      fetchImpl: async (url, options) => {
        let data = {signaling_state: "answer_applied"}
        if (options.method === "POST" && !options.body) {
          data = {viewer_session_id: "viewer-ice-test", offer_sdp: "v=0\r\nm=video", remote_ice_candidates: []}
        } else if (url.endsWith("/answer")) {
          data = {signaling_state: "answer_applied", remote_ice_candidates: [host]}
        } else if (url === pollUrl && options.method === "GET") {
          data = {signaling_state: "answer_applied", remote_ice_candidates: [host, relay]}
        }
        return {ok: true, json: async () => ({data})}
      },
    })
    const polls = () => globalThis.fetch.mock.calls.filter(([url, options]) => url === pollUrl && options.method === "GET")

    // First poll fires immediately (0ms) after POST /answer completes when WS is not open.
    expect(polls()).toHaveLength(1)
    expect(peer.addedCandidates).toEqual([host, relay])

    // Subsequent fast polls run every 50ms until ICE settles.
    await vi.advanceTimersByTimeAsync(50)
    expect(polls()).toHaveLength(2)

    peer.connectionState = "connected"
    peer.dispatchEvent(new Event("connectionstatechange"))
    const pollsWhenConnected = polls().length
    await vi.advanceTimersByTimeAsync(2000)
    expect(polls()).toHaveLength(pollsWhenConnected)
  })

  it("backs off remote ICE candidate polling from 50ms to 100ms to 250ms and stops when gathering completes when statusSocket is not open", async () => {
    const pollUrl = "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test"
    let pollResponses = 0
    await mountWebRtcViewer({
      socketOpen: false,
      fetchImpl: async (url, options) => {
        let data = {signaling_state: "answer_applied"}
        if (options.method === "POST" && !options.body) {
          data = {viewer_session_id: "viewer-ice-test", offer_sdp: "v=0\r\nm=video", remote_ice_candidates: []}
        } else if (url.endsWith("/answer")) {
          data = {signaling_state: "answer_applied", remote_ice_candidates: []}
        } else if (url === pollUrl && options.method === "GET") {
          pollResponses += 1
          data = {
            signaling_state: "answer_applied",
            remote_ice_candidates: [],
            ice_gathering_state: pollResponses >= 22 ? "complete" : "gathering",
          }
        }
        return {ok: true, json: async () => ({data})}
      },
    })
    const polls = () => globalThis.fetch.mock.calls.filter(([url, options]) => url === pollUrl && options.method === "GET")

    // Poll #1 ran immediately after answer.
    expect(polls()).toHaveLength(1)

    // Next 10 polls run at 50ms intervals (10 * 50ms = 500ms -> 11 total).
    await vi.advanceTimersByTimeAsync(500)
    expect(polls()).toHaveLength(11)

    // Next 10 polls run at 100ms intervals (10 * 100ms = 1000ms -> 21 total).
    await vi.advanceTimersByTimeAsync(1000)
    expect(polls()).toHaveLength(21)

    // After 20 adaptive polls, cadence slows to 250ms.
    await vi.advanceTimersByTimeAsync(249)
    expect(polls()).toHaveLength(21)
    await vi.advanceTimersByTimeAsync(1)
    expect(polls()).toHaveLength(22)

    // Poll #22 reported ice_gathering_state: "complete", so polling stops.
    await vi.advanceTimersByTimeAsync(2000)
    expect(polls()).toHaveLength(22)
  })

  it("applies server ICE candidates pushed over statusSocket immediately, deduplicates them, and stops backup polling on gathering complete", async () => {
    const host = {candidate: "candidate:1 1 UDP 2122252543 192.0.2.20 40000 typ host", sdpMid: "0"}
    const relay = {candidate: "candidate:2 1 UDP 16777215 198.51.100.30 49200 typ relay", sdpMid: "0"}
    const otherViewer = {candidate: "candidate:9 1 UDP 2122252543 192.0.2.99 40009 typ host", sdpMid: "0"}
    const pollUrl = "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test"

    const {peer, sockets} = await mountWebRtcViewer({
      fetchImpl: async (url, options) => {
        let data = {signaling_state: "answer_applied"}
        if (options.method === "POST" && !options.body) {
          data = {viewer_session_id: "viewer-ice-test", offer_sdp: "v=0\r\nm=video", remote_ice_candidates: []}
        } else if (url.endsWith("/answer")) {
          data = {signaling_state: "answer_applied", remote_ice_candidates: []}
        } else if (url === pollUrl && options.method === "GET") {
          data = {signaling_state: "answer_applied", remote_ice_candidates: [host, relay], ice_gathering_state: "gathering"}
        }
        return {ok: true, json: async () => ({data})}
      },
    })
    const statusSocket = sockets[0]
    const polls = () => globalThis.fetch.mock.calls.filter(([url, options]) => url === pollUrl && options.method === "GET")

    // While statusSocket is open, no immediate HTTP poll fires.
    expect(polls()).toHaveLength(0)

    // Candidate for a different viewer session is ignored.
    statusSocket.emit("message", {
      data: JSON.stringify({
        type: "webrtc_ice_candidate",
        viewer_session_id: "other-viewer",
        candidate: otherViewer,
        ice_gathering_state: "gathering",
      }),
    })
    expect(peer.addedCandidates).toEqual([])

    // Matching candidate is applied immediately without any HTTP poll.
    statusSocket.emit("message", {
      data: JSON.stringify({
        type: "webrtc_ice_candidate",
        viewer_session_id: "viewer-ice-test",
        candidate: host,
        ice_gathering_state: "gathering",
      }),
    })
    expect(peer.addedCandidates).toEqual([host])
    expect(polls()).toHaveLength(0)

    // Backup poll fires at 500ms and deduplicates `host` while adding `relay`.
    await vi.advanceTimersByTimeAsync(499)
    expect(polls()).toHaveLength(0)
    await vi.advanceTimersByTimeAsync(1)
    expect(polls()).toHaveLength(1)
    expect(peer.addedCandidates).toEqual([host, relay])

    // Duplicate WS push of `relay` is ignored, and `complete` cancels future backup polls.
    statusSocket.emit("message", {
      data: JSON.stringify({
        type: "webrtc_ice_candidate",
        viewer_session_id: "viewer-ice-test",
        candidate: relay,
        ice_gathering_state: "complete",
      }),
    })
    expect(peer.addedCandidates).toEqual([host, relay])

    await vi.advanceTimersByTimeAsync(2000)
    expect(polls()).toHaveLength(1)
  })

  it("cancels the initial 500ms backup poll when statusSocket reports ice_gathering_state complete before it fires", async () => {
    const host = {candidate: "candidate:1 1 UDP 2122252543 192.0.2.20 40000 typ host", sdpMid: "0"}
    const pollUrl = "/api/camera-relay-sessions/test/webrtc/session/viewer-ice-test"
    const {peer, sockets} = await mountWebRtcViewer()
    const statusSocket = sockets[0]
    const polls = () => globalThis.fetch.mock.calls.filter(([url, options]) => url === pollUrl && options.method === "GET")

    statusSocket.emit("message", {
      data: JSON.stringify({
        type: "webrtc_ice_candidate",
        viewer_session_id: "viewer-ice-test",
        candidate: host,
        ice_gathering_state: "gathering",
      }),
    })
    statusSocket.emit("message", {
      data: JSON.stringify({
        type: "webrtc_ice_candidate",
        viewer_session_id: "viewer-ice-test",
        candidate: null,
        ice_gathering_state: "complete",
      }),
    })

    expect(peer.addedCandidates).toEqual([host])
    await vi.advanceTimersByTimeAsync(2000)
    expect(polls()).toHaveLength(0)
  })

  it("wakes WebRTC session creation immediately when statusSocket reports active/ready", async () => {
    vi.useFakeTimers()
    const element = buildHookElement()
    element.dataset.preferredPlaybackTransport = "membrane_webrtc"
    element.dataset.availablePlaybackTransports =
      "membrane_webrtc,websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 409,
        json: async () => ({
          error: "relay_session_activating",
          message: "relay session is still activating",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-wake",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection extends EventTarget {
      constructor() {
        super()
        this.connectionState = "new"
        this.iceConnectionState = "new"
      }
      async setRemoteDescription() {}
      async createAnswer() { return {type: "answer", sdp: "v=0\r\nm=video"} }
      async setLocalDescription() {}
      close() {}
    }

    const MockWebSocket = createMockWebSocketClass()
    globalThis.fetch = fetchMock
    globalThis.document = {querySelector: () => ({getAttribute: () => "csrf-token"})}
    globalThis.window = Object.assign(new EventTarget(), {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
    })
    globalThis.WebSocket = MockWebSocket

    const hook = {...CameraRelayStatusStream, el: element}
    mountHook(hook)
    await Promise.resolve()
    await Promise.resolve()

    // First attempt got 409 and is now waiting for activation.
    expect(fetchMock).toHaveBeenCalledTimes(1)

    // Broadcast active/ready on statusSocket without advancing timers at all.
    MockWebSocket.instances[0].emit("message", {
      data: JSON.stringify({
        type: "camera_relay_snapshot",
        status: "active",
        playback_state: "ready",
        media_ingest_id: "ingest-wake",
      }),
    })

    // Flush microtasks (0ms timer advance) — retry fires immediately!
    await vi.advanceTimersByTimeAsync(0)

    expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(fetchMock.mock.calls[2][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-wake/answer")
    expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
  })

  it("fades out the video poster when WebRTC video starts playing", async () => {
    const {peer, video, element} = await mountWebRtcViewer()
    const poster = element.roles.get("video-poster")
    expect(poster.classList.contains("opacity-0")).toBe(false)

    const track = new Event("track")
    track.track = {kind: "video"}
    track.streams = [{}]
    peer.dispatchEvent(track)
    video.dispatchEvent(new Event("playing"))

    expect(poster.classList.contains("opacity-0")).toBe(true)
  })

  it("prefers the WebRTC relay path when advertised and supported", async () => {
    const element = buildHookElement()
    element.dataset.preferredPlaybackTransport = "membrane_webrtc"
    element.dataset.availablePlaybackTransports =
      "membrane_webrtc,websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const videoElement = element.roles.get("video-element")
    videoElement.play = vi.fn(() => Promise.resolve())

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-1",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection {
      constructor() {
        this.handlers = {}
        this.connectionState = "new"
      }

      addEventListener(event, callback) {
        this.handlers[event] = callback
      }

      async setRemoteDescription(description) {
        this.remoteDescription = description
      }

      async createAnswer() {
        return {type: "answer", sdp: "v=0\r\nm=video"}
      }

      async setLocalDescription(description) {
        this.localDescription = description
      }

      close() {}
    }

    globalThis.fetch = fetchMock
    globalThis.document = {
      querySelector() {
        return {getAttribute: () => "csrf-token"}
      },
    }
    const MockWebSocket = createMockWebSocketClass()
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      socket: null,
      player: null,
    }

    mountHook(hook)
    await Promise.resolve()
    await Promise.resolve()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(MockWebSocket.instances).toHaveLength(1)
    expect(MockWebSocket.instances[0].url).toBe("wss://example.com/v1/camera-relay-sessions/test/stream")
    expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-1/answer")
    expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
    expect(element.roles.get("player-status").textContent).toBe("Waiting for WebRTC media...")
    expect(hook.viewer.socket).toBeNull()
    expect(hook.viewer.peerConnection).toBeInstanceOf(MockPeerConnection)
  })

  it("upgrades websocket-preferred metadata to WebRTC when the relay advertises it", async () => {
    const element = buildHookElement()
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-2",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection {
      constructor() {
        this.handlers = {}
        this.connectionState = "new"
      }

      addEventListener(event, callback) {
        this.handlers[event] = callback
      }

      async setRemoteDescription(description) {
        this.remoteDescription = description
      }

      async createAnswer() {
        return {type: "answer", sdp: "v=0\r\nm=video"}
      }

      async setLocalDescription(description) {
        this.localDescription = description
      }

      close() {}
    }

    globalThis.fetch = fetchMock
    globalThis.document = {
      querySelector() {
        return {getAttribute: () => "csrf-token"}
      },
    }
    const MockWebSocket = createMockWebSocketClass()
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      socket: null,
      player: null,
    }

    mountHook(hook)
    await Promise.resolve()
    await Promise.resolve()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(element.roles.get("compatibility-status").textContent).toContain("WebRTC relay")
    expect(hook.viewer.peerConnection).toBeInstanceOf(MockPeerConnection)
    expect(MockWebSocket.instances).toHaveLength(1)
  })

  it("retries WebRTC viewer creation while the relay is still activating", async () => {
    const element = buildHookElement()
    element.dataset.preferredPlaybackTransport = "membrane_webrtc"
    element.dataset.availablePlaybackTransports =
      "membrane_webrtc,websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 404,
        json: async () => ({
          error: "relay_session_not_found",
          message: "relay session was not found",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-3",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection {
      constructor() {
        this.handlers = {}
        this.connectionState = "new"
      }

      addEventListener(event, callback) {
        this.handlers[event] = callback
      }

      async setRemoteDescription(description) {
        this.remoteDescription = description
      }

      async createAnswer() {
        return {type: "answer", sdp: "v=0\r\nm=video"}
      }

      async setLocalDescription(description) {
        this.localDescription = description
      }

      close() {}
    }

    globalThis.fetch = fetchMock
    globalThis.document = {
      querySelector() {
        return {getAttribute: () => "csrf-token"}
      },
    }
    const MockWebSocket = createMockWebSocketClass()
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    vi.useFakeTimers()

    try {
      const hook = {
        ...CameraRelayStatusStream,
        el: element,
        socket: null,
        player: null,
      }

      mountHook(hook)
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(150)
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[2][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-3/answer")
      expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
      expect(element.roles.get("player-status").textContent).toBe("Waiting for WebRTC media...")
      expect(hook.viewer.peerConnection).toBeInstanceOf(MockPeerConnection)
    } finally {
      vi.useRealTimers()
    }
  })

  it("retries WebRTC viewer creation when the server reports an activating relay", async () => {
    const element = buildHookElement()
    element.dataset.preferredPlaybackTransport = "membrane_webrtc"
    element.dataset.availablePlaybackTransports =
      "membrane_webrtc,websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 409,
        json: async () => ({
          error: "relay_session_activating",
          message: "relay session is still activating",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-4",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection {
      constructor() {
        this.handlers = {}
        this.connectionState = "new"
      }

      addEventListener(event, callback) {
        this.handlers[event] = callback
      }

      async setRemoteDescription(description) {
        this.remoteDescription = description
      }

      async createAnswer() {
        return {type: "answer", sdp: "v=0\r\nm=video"}
      }

      async setLocalDescription(description) {
        this.localDescription = description
      }

      close() {}
    }

    globalThis.fetch = fetchMock
    globalThis.document = {
      querySelector() {
        return {getAttribute: () => "csrf-token"}
      },
    }
    const MockWebSocket = createMockWebSocketClass()
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    vi.useFakeTimers()

    try {
      const hook = {
        ...CameraRelayStatusStream,
        el: element,
        socket: null,
        player: null,
      }

      mountHook(hook)
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(150)
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[2][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-4/answer")
      expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
      expect(hook.viewer.peerConnection).toBeInstanceOf(MockPeerConnection)
    } finally {
      vi.useRealTimers()
    }
  })

  it("updates relay status from the status websocket while using the WebRTC path", async () => {
    const element = buildHookElement()
    element.dataset.preferredPlaybackTransport = "membrane_webrtc"
    element.dataset.availablePlaybackTransports =
      "membrane_webrtc,websocket_h264_annexb_webcodecs,websocket_h264_annexb_jmuxer_mse"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    element.dataset.webrtcIceServers = JSON.stringify([{urls: ["stun:stun.example.com"]}])

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          data: {
            viewer_session_id: "viewer-5",
            offer_sdp: "v=0\r\nm=video",
            ice_servers: [{urls: ["stun:stun.example.com"]}],
          },
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied"}}),
      })
      .mockResolvedValue({
        ok: true,
        json: async () => ({data: {signaling_state: "answer_applied", ice_gathering_state: "complete"}}),
      })

    class MockPeerConnection {
      constructor() {
        this.handlers = {}
        this.connectionState = "new"
      }

      addEventListener(event, callback) {
        this.handlers[event] = callback
      }

      async setRemoteDescription(description) {
        this.remoteDescription = description
      }

      async createAnswer() {
        return {type: "answer", sdp: "v=0\r\nm=video"}
      }

      async setLocalDescription(description) {
        this.localDescription = description
      }

      close() {}
    }

    globalThis.fetch = fetchMock
    globalThis.document = {
      querySelector() {
        return {getAttribute: () => "csrf-token"}
      },
    }
    const MockWebSocket = createMockWebSocketClass()
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      socket: null,
      player: null,
    }

    mountHook(hook)
    await Promise.resolve()
    await Promise.resolve()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(MockWebSocket.instances).toHaveLength(1)

    MockWebSocket.instances[0].emit("message", {
      data: JSON.stringify({
        type: "camera_relay_snapshot",
        status: "active",
        playback_state: "ready",
        viewer_count: 2,
        media_ingest_id: "media-123",
      }),
    })

    expect(element.roles.get("relay-status").textContent).toBe("Relay status: active")
    expect(element.roles.get("playback-state").textContent).toBe("Playback state: ready")
    expect(element.roles.get("viewer-count").textContent).toBe("Viewer count: 2")
    expect(element.roles.get("relay-detail").textContent).toContain("Ingress media-123 is attached")
    expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
    expect(hook.viewer.socket).toBeNull()
  })

  it("sends websocket keepalive pings while the browser viewer is open", async () => {
    const element = buildHookElement()
    const MockWebSocket = createMockWebSocketClass()

    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }
    globalThis.WebSocket = MockWebSocket

    vi.useFakeTimers()

    try {
      const hook = {
        ...CameraRelayStatusStream,
        el: element,
        socket: null,
        player: {close() {}},
      }

      mountHook(hook)

      expect(MockWebSocket.instances).toHaveLength(1)

      const socket = MockWebSocket.instances[0]
      socket.emit("open")

      await vi.advanceTimersByTimeAsync(20_000)
      await vi.advanceTimersByTimeAsync(20_000)

      expect(socket.sent).toEqual(["ping", "ping"])

      CameraRelayStatusStream.destroyed.call(hook)

      await vi.advanceTimersByTimeAsync(20_000)

      expect(socket.sent).toEqual(["ping", "ping"])
    } finally {
      vi.useRealTimers()
    }
  })

  it("uses a preloaded WebRTC offer delivered via LiveView push_event without calling POST /webrtc/session", async () => {
    vi.useFakeTimers()
    const element = buildHookElement()
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/test/webrtc/session"
    const video = new EventTarget()
    video.dataset = {}
    video.classList = {toggle() {}}
    video.play = vi.fn(() => Promise.resolve())
    element.roles.set("video-element", video)

    const peerConfigs = []
    class PeerConnection extends EventTarget {
      constructor(config) {
        super()
        peerConfigs.push(config)
        this.connectionState = "new"
        this.iceConnectionState = "new"
        this.closed = false
        this.addedCandidates = []
      }
      async setRemoteDescription() {}
      async addIceCandidate(candidate) { this.addedCandidates.push(candidate) }
      async createAnswer() { return {type: "answer", sdp: "v=0\r\nm=video"} }
      async setLocalDescription() {}
      close() { this.closed = true }
    }

    const MockWebSocket = createMockWebSocketClass()
    globalThis.WebSocket = MockWebSocket
    globalThis.window = Object.assign(new EventTarget(), {
      location: new URL("https://example.com/cameras/test/recordings?mode=live"),
      RTCPeerConnection: PeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaStream: class MediaStream {
        constructor(tracks) { this.tracks = tracks }
      },
    })
    globalThis.document = {querySelector: () => null}
    globalThis.fetch = vi.fn(async (_url, _options) => ({
      ok: true,
      json: async () => ({data: {signaling_state: "answer_applied", remote_ice_candidates: []}}),
    }))

    const eventHandlers = new Map()
    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      handleEvent(name, cb) {
        eventHandlers.set(name, cb)
      },
    }

    // LiveView mounts the hook and dispatches push_event synchronously right after in the same patch turn.
    mountHook(hook)
    eventHandlers.get("camera-relay:webrtc-offer")({
      signaling_path: "/api/camera-relay-sessions/test/webrtc/session",
      data: {
        viewer_session_id: "viewer-preloaded-1",
        offer_sdp: "v=0\r\nm=video",
        ice_servers: [{urls: ["turn:turn.example.com:3478"], username: "u", credential: "p"}],
        remote_ice_candidates: [{candidate: "candidate:1 1 UDP 2122252543 192.0.2.20 40000 typ host", sdpMid: "0"}],
      },
    })

    await vi.advanceTimersByTimeAsync(0)

    const createCalls = globalThis.fetch.mock.calls.filter(
      ([url, options]) => url === "/api/camera-relay-sessions/test/webrtc/session" && options.method === "POST"
    )
    const answerCalls = globalThis.fetch.mock.calls.filter(
      ([url, options]) =>
        url === "/api/camera-relay-sessions/test/webrtc/session/viewer-preloaded-1/answer" && options.method === "POST"
    )

    expect(createCalls).toHaveLength(0)
    expect(answerCalls).toHaveLength(1)
    expect(peerConfigs[0].iceServers).toEqual([
      {urls: ["turn:turn.example.com:3478"], username: "u", credential: "p"},
    ])
    expect(hook.viewer.peerConnection.addedCandidates).toHaveLength(1)
  })

  it("coalesces browser ICE candidates into a single batched POST and flushes immediately on end-of-candidates", async () => {
    const {peer} = await mountWebRtcViewer()
    const candidateCalls = () =>
      globalThis.fetch.mock.calls.filter(
        ([url, options]) => url.endsWith("/candidates") && options.method === "POST"
      )

    const c1 = {candidate: "candidate:1 1 UDP 1234 192.0.2.1 4000 typ host", sdpMid: "0"}
    const c2 = {candidate: "candidate:2 1 UDP 5678 198.51.100.2 5000 typ relay", sdpMid: "0"}

    const ev1 = new Event("icecandidate")
    ev1.candidate = {toJSON: () => c1}
    const ev2 = new Event("icecandidate")
    ev2.candidate = {toJSON: () => c2}

    peer.dispatchEvent(ev1)
    peer.dispatchEvent(ev2)

    // Still coalescing before 25ms window elapses.
    expect(candidateCalls()).toHaveLength(0)

    // End-of-candidates (candidate: null) flushes immediately in a single batched request.
    const evEnd = new Event("icecandidate")
    evEnd.candidate = null
    peer.dispatchEvent(evEnd)

    expect(candidateCalls()).toHaveLength(1)
    expect(JSON.parse(candidateCalls()[0][1].body)).toEqual({candidates: [c1, c2]})

    // A single candidate after the batch flushes after 25ms using the single-candidate payload.
    const c3 = {candidate: "candidate:3 1 UDP 9999 203.0.113.3 6000 typ srflx", sdpMid: "0"}
    const ev3 = new Event("icecandidate")
    ev3.candidate = {toJSON: () => c3}
    peer.dispatchEvent(ev3)

    await vi.advanceTimersByTimeAsync(24)
    expect(candidateCalls()).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(candidateCalls()).toHaveLength(2)
    expect(JSON.parse(candidateCalls()[1][1].body)).toEqual({candidate: c3})
  })

  it("sends WebRTC answer, batched ICE candidates, and viewer-ready over LiveView pushEvent when enabled", async () => {
    vi.useFakeTimers()
    const element = buildHookElement()
    element.dataset.relaySessionId = "relay-lv-1"
    element.dataset.webrtcPlaybackTransport = "membrane_webrtc"
    element.dataset.webrtcSignalingPath = "/api/camera-relay-sessions/relay-lv-1/webrtc/session"
    element.dataset.liveviewWebrtcSignaling = "true"
    element.dataset.notifyViewerReady = "true"
    const video = new EventTarget()
    video.dataset = {}
    video.classList = {toggle() {}}
    video.play = vi.fn(() => Promise.resolve())
    element.roles.set("video-element", video)

    class PeerConnection extends EventTarget {
      constructor() {
        super()
        this.connectionState = "new"
        this.iceConnectionState = "new"
        this.closed = false
        this.addedCandidates = []
      }
      async setRemoteDescription() {}
      async addIceCandidate(candidate) { this.addedCandidates.push(candidate) }
      async createAnswer() { return {type: "answer", sdp: "v=0\r\nanswer-lv"} }
      async setLocalDescription() {}
      close() { this.closed = true }
    }

    const MockWebSocket = createMockWebSocketClass()
    globalThis.WebSocket = MockWebSocket
    globalThis.window = Object.assign(new EventTarget(), {
      location: new URL("https://example.com/cameras/test/recordings?mode=live"),
      RTCPeerConnection: PeerConnection,
      WebSocket: MockWebSocket,
      VideoDecoder: function VideoDecoder() {},
      MediaStream: class MediaStream {
        constructor(tracks) { this.tracks = tracks }
      },
    })
    globalThis.document = {querySelector: () => null}
    globalThis.fetch = vi.fn(async () => ({ok: true, json: async () => ({data: {}})}))

    const eventHandlers = new Map()
    const pushedEvents = []
    const hook = {
      ...CameraRelayStatusStream,
      el: element,
      handleEvent(name, cb) {
        eventHandlers.set(name, cb)
      },
      pushEvent(name, payload, replyCb) {
        pushedEvents.push({name, payload})
        if (name === "camera_webrtc_answer" && replyCb) {
          replyCb({
            ok: true,
            data: {
              signaling_state: "answer_applied",
              remote_ice_candidates: [
                {candidate: "candidate:9 1 UDP 16777215 198.51.100.30 49200 typ relay", sdpMid: "0"},
              ],
            },
          })
        }
      },
    }

    mountHook(hook)
    eventHandlers.get("camera-relay:webrtc-offer")({
      signaling_path: "/api/camera-relay-sessions/relay-lv-1/webrtc/session",
      data: {
        relay_session_id: "relay-lv-1",
        viewer_session_id: "viewer-lv-1",
        offer_sdp: "v=0\r\nm=video",
        remote_ice_candidates: [],
      },
    })

    await vi.advanceTimersByTimeAsync(0)

    // Zero HTTP POSTs for create or answer — all handled over LiveView pushEvent.
    expect(globalThis.fetch).not.toHaveBeenCalled()
    expect(pushedEvents).toContainEqual({
      name: "camera_webrtc_answer",
      payload: {
        relay_session_id: "relay-lv-1",
        viewer_session_id: "viewer-lv-1",
        sdp: "v=0\r\nanswer-lv",
      },
    })
    expect(hook.viewer.peerConnection.addedCandidates).toHaveLength(1)

    // Browser ICE candidates are also batched over LiveView pushEvent.
    const c1 = {candidate: "candidate:1 1 UDP 1234 192.0.2.1 4000 typ host", sdpMid: "0"}
    const ev1 = new Event("icecandidate")
    ev1.candidate = {toJSON: () => c1}
    const evEnd = new Event("icecandidate")
    evEnd.candidate = null
    hook.viewer.peerConnection.dispatchEvent(ev1)
    hook.viewer.peerConnection.dispatchEvent(evEnd)

    expect(globalThis.fetch).not.toHaveBeenCalled()
    expect(pushedEvents).toContainEqual({
      name: "camera_webrtc_candidates",
      payload: {
        relay_session_id: "relay-lv-1",
        viewer_session_id: "viewer-lv-1",
        candidates: [c1],
      },
    })

    // When video starts playing, viewer notifies LiveView once to unlock deferred timeline load.
    const track = new Event("track")
    track.track = {kind: "video"}
    track.streams = [{}]
    hook.viewer.peerConnection.dispatchEvent(track)
    video.dispatchEvent(new Event("playing"))

    expect(pushedEvents.filter((e) => e.name === "camera_live_viewer_ready")).toHaveLength(1)
  })
})
