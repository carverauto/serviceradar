import {describe, expect, it, vi} from "vitest"

import {
  buildDesktopFocusFrame,
  buildDesktopKeyFrame,
  buildDesktopPointerFrame,
  buildDesktopResizeFrame,
  sendDesktopControlFrame,
} from "./control_frame"

const session = {
  id: "desktop-session-1",
  desktop_policy_snapshot: {target: {protocol: "rdp"}},
}

describe("remote desktop browser control frames", () => {
  it("builds Go-compatible keyboard input frames", () => {
    expect(buildDesktopKeyFrame(session, {key: "Enter", down: true})).toEqual({
      session_id: "desktop-session-1",
      protocol: "rdp",
      frame_type: "desktop.input",
      input: {kind: "key", key: "Enter", down: true},
    })
  })

  it("rejects missing sessions and oversized input tokens before send", () => {
    expect(buildDesktopKeyFrame({}, {key: "Enter", down: true})).toBeNull()
    expect(buildDesktopKeyFrame(session, {key: "x".repeat(129), down: true})).toBeNull()
  })

  it("maps browser pointer coordinates into the remote desktop pixel space", () => {
    const frame = buildDesktopPointerFrame(
      session,
      {button: 0, clientX: 150, clientY: 100},
      {
        width: 1920,
        height: 1080,
        getBoundingClientRect: () => ({left: 50, top: 20, width: 960, height: 540}),
      },
      {down: true}
    )

    expect(frame).toEqual({
      session_id: "desktop-session-1",
      protocol: "rdp",
      frame_type: "desktop.input",
      input: {kind: "pointer", x: 200, y: 160, button: "left", down: true},
    })
  })

  it("builds focus and resize frames without browser-only fields", () => {
    expect(buildDesktopFocusFrame(session, true)).toEqual({
      session_id: "desktop-session-1",
      protocol: "rdp",
      frame_type: "desktop.input",
      input: {kind: "focus", focused: true},
    })

    expect(buildDesktopResizeFrame(session, {width: 1600, height: 900})).toEqual({
      session_id: "desktop-session-1",
      protocol: "rdp",
      frame_type: "desktop.resize",
      width: 1600,
      height: 900,
    })
  })

  it("sends frames through the WebRTC client control channel only when available", () => {
    const client = {sendControl: vi.fn(() => true)}
    const frame = buildDesktopFocusFrame(session, false)

    expect(sendDesktopControlFrame(client, frame)).toBe(true)
    expect(client.sendControl).toHaveBeenCalledWith(frame)
    expect(sendDesktopControlFrame(null, frame)).toBe(false)
    expect(sendDesktopControlFrame(client, null)).toBe(false)
  })
})
