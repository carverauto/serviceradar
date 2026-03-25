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

    constructor(url) {
      this.url = url
      this.handlers = {}
      this.closed = false
      MockWebSocket.instances.push(this)
    }

    addEventListener(event, callback) {
      this.handlers[event] = callback
    }

    emit(event, payload) {
      this.handlers[event]?.(payload)
    }

    close() {}
  }
}

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalFetch = globalThis.fetch
const originalWebSocket = globalThis.WebSocket

afterEach(() => {
  globalThis.window = originalWindow
  globalThis.document = originalDocument
  globalThis.fetch = originalFetch
  globalThis.WebSocket = originalWebSocket
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe("CameraRelayStatusStream", () => {
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

    CameraRelayStatusStream.mounted.call(hook)

    expect(element.roles.get("transport-status").textContent).toBe("Browser playback unsupported")
    expect(element.roles.get("player-status").textContent).toBe(
      "This browser cannot decode the current relay transport."
    )
    expect(element.roles.get("compatibility-status").textContent).toContain("Unsupported browser transport")
    expect(element.roles.get("relay-detail").textContent).toContain("either WebCodecs or an MSE-capable H264 browser")
    expect(hook.socket).toBeNull()
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

    CameraRelayStatusStream.mounted.call(hook)
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
    expect(hook.socket).toBeNull()
    expect(hook.peerConnection).toBeInstanceOf(MockPeerConnection)
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

    CameraRelayStatusStream.mounted.call(hook)
    await Promise.resolve()
    await Promise.resolve()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(element.roles.get("compatibility-status").textContent).toContain("WebRTC relay")
    expect(hook.peerConnection).toBeInstanceOf(MockPeerConnection)
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

      CameraRelayStatusStream.mounted.call(hook)
      await Promise.resolve()
      await vi.runAllTimersAsync()
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock).toHaveBeenCalledTimes(3)
      expect(MockWebSocket.instances).toHaveLength(1)
      expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[2][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-3/answer")
      expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
      expect(element.roles.get("player-status").textContent).toBe("Waiting for WebRTC media...")
      expect(hook.peerConnection).toBeInstanceOf(MockPeerConnection)
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

      CameraRelayStatusStream.mounted.call(hook)
      await Promise.resolve()
      await vi.runAllTimersAsync()
      await Promise.resolve()
      await Promise.resolve()

      expect(fetchMock).toHaveBeenCalledTimes(3)
      expect(MockWebSocket.instances).toHaveLength(1)
      expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
      expect(fetchMock.mock.calls[2][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-4/answer")
      expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
      expect(hook.peerConnection).toBeInstanceOf(MockPeerConnection)
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

    CameraRelayStatusStream.mounted.call(hook)
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
    expect(hook.socket).toBeNull()
  })
})
