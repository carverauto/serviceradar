import {afterEach, describe, expect, it, vi} from "vitest"

import CameraRelayStatusStream from "./CameraRelayStatusStream"

function roleElement() {
  return {
    textContent: "",
    dataset: {},
    classList: {
      toggle() {},
    },
  }
}

function buildHookElement() {
  const roles = new Map([
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


async function mountWebRtcViewer() {
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
    }
    async setRemoteDescription() {}
    async createAnswer() { return {type: "answer", sdp: "v=0\r\nm=video"} }
    async setLocalDescription() {}
    close() { this.closed = true }
  }

  const MockWebSocket = createMockWebSocketClass()
  globalThis.WebSocket = MockWebSocket
  globalThis.window = {
    location: new URL("https://example.com/devices/test"),
    RTCPeerConnection: PeerConnection,
    WebSocket: MockWebSocket,
    VideoDecoder: function VideoDecoder() {},
  }
  globalThis.document = {querySelector: () => null}
  globalThis.fetch = vi.fn(async (_url, options) => ({
    ok: true,
    json: async () => options.method === "POST" && !options.body
      ? {data: {viewer_session_id: "viewer-ice-test", offer_sdp: "v=0\r\nm=video"}}
      : {data: {signaling_state: "answer_applied"}},
  }))
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

  it("keeps WebRTC once video starts playing and cancels the deadline on close", async () => {
    const {hook, peer, video, sockets} = await mountWebRtcViewer()
    const track = new Event("track")
    track.streams = [{}]
    peer.dispatchEvent(track)
    peer.connectionState = "connected"
    peer.dispatchEvent(new Event("connectionstatechange"))
    video.dispatchEvent(new Event("playing"))
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(1)
    expect(video.srcObject).toBe(track.streams[0])
    CameraRelayStatusStream.destroyed.call(hook)
    await vi.advanceTimersByTimeAsync(8000)
    expect(sockets).toHaveLength(1)
    expect(peer.closed).toBe(true)
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

    expect(fetchMock).toHaveBeenCalledTimes(2)
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
      await vi.advanceTimersByTimeAsync(1000)
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock).toHaveBeenCalledTimes(3)
      expect(MockWebSocket.instances).toHaveLength(1)
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
      await vi.advanceTimersByTimeAsync(1000)
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock).toHaveBeenCalledTimes(3)
      expect(MockWebSocket.instances).toHaveLength(1)
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
})
