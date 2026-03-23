import {afterEach, describe, expect, it} from "vitest"

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

afterEach(() => {
  globalThis.window = originalWindow
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
})
