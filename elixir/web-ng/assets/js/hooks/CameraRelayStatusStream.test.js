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
    ["transport-status", roleElement()],
    ["player-status", roleElement()],
    ["compatibility-status", roleElement()],
    ["relay-detail", roleElement()],
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

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.window = originalWindow
  globalThis.document = originalDocument
  globalThis.fetch = originalFetch
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
    globalThis.window = {
      location: new URL("https://example.com/devices/test"),
      RTCPeerConnection: MockPeerConnection,
      WebSocket: function WebSocket() {},
      VideoDecoder: function VideoDecoder() {},
      MediaSource: class MediaSource {
        static isTypeSupported() {
          return true
        }
      },
    }

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
    expect(fetchMock.mock.calls[0][0]).toBe("/api/camera-relay-sessions/test/webrtc/session")
    expect(fetchMock.mock.calls[1][0]).toBe("/api/camera-relay-sessions/test/webrtc/session/viewer-1/answer")
    expect(element.roles.get("transport-status").textContent).toBe("WebRTC answer applied")
    expect(element.roles.get("player-status").textContent).toBe("Waiting for WebRTC media...")
    expect(hook.socket).toBeNull()
    expect(hook.peerConnection).toBeInstanceOf(MockPeerConnection)
  })
})
