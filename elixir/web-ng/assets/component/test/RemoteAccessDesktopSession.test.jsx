import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it, vi} from "vitest"

import RemoteAccessDesktopSession, {
  Component as RemoteAccessDesktopRenderer,
  buildRdpSessionRequest,
  createRdpLauncherRuntime,
  rdpLaunchInProgress,
  readyForSession,
} from "../src/RemoteAccessDesktopSession.jsx"

const sensitiveValue = "must-not-render"

function desktopSession(overrides = {}) {
  return {
    id: "session-1",
    status: "ready",
    desktop_webrtc_enabled: true,
    desktop_webrtc_signaling_path: "/api/remote-access/sessions/session-1/webrtc-desktop-media",
    desktop_webrtc_ice_servers: [],
    desktop_policy_snapshot: {
      target: {
        display_name: "Finance desktop",
        device_uid: "windows-1",
        password: sensitiveValue,
      },
      route: {
        agent_id: "agent-1",
        gateway_id: "gateway-1",
      },
      credential: {
        custody_mode: "user_present",
        secret_payload: sensitiveValue,
      },
      authorization: {
        rbac_decision: "allowed",
      },
      desktop: {
        target_tls: {
          mode: "verify_ca",
          private_key: sensitiveValue,
        },
        nla: {
          required: true,
        },
        screen_policy: {
          max_width: 1920,
          max_height: 1080,
          max_frame_rate: 30,
        },
        redirection_policy: {
          clipboard: "disabled",
          drive: "disabled",
        },
      },
      recording: {
        policy: {
          mode: "metadata",
          token: sensitiveValue,
        },
      },
    },
    ...overrides,
  }
}

describe("RemoteAccessDesktopSession", () => {
  it("renders visible desktop policy posture without credential material", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopRenderer
        session={desktopSession()}
        title="RDP session"
      />
    )

    expect(html).toContain("RDP session")
    expect(html).toContain("Finance desktop")
    expect(html).toContain("Remote desktop display")
    expect(html).toContain("Remote desktop video track")
    expect(html).toContain("0 tile updates")
    expect(html).toContain("agent-1 / gateway-1")
    expect(html).toContain("User Present")
    expect(html).toContain("Verify Ca / NLA Required")
    expect(html).toContain("1920x1080 / 30 fps")
    expect(html).toContain("0/12 queued")
    expect(html).toContain("No frames")
    expect(html).toContain("Metadata")
    expect(html).not.toContain(sensitiveValue)
  })

  it("shows the unavailable media state when WebRTC metadata is missing", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopRenderer
        session={desktopSession({
          desktop_webrtc_enabled: false,
          desktop_webrtc_signaling_path: null,
        })}
      />
    )

    expect(html).toContain("Media unavailable.")
    expect(html).toContain("Not attached")
    expect(html).toContain("0 accepted / 0 dropped")
    expect(html).toContain("0/12 queued")
  })

  it("renders the configured desktop backpressure queue budget", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopRenderer
        queueMaxFrames={3}
        session={desktopSession()}
      />
    )

    expect(html).toContain("0/3 queued")
  })

  it("renders an empty selection state without creating a media client", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopRenderer
        clientFactory={() => {
          throw new Error("client factory should not run without a selected session")
        }}
      />
    )

    expect(html).toContain("No RDP session selected.")
  })

  it("renders the launcher credential handoff without rendering secret props", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopSession
        desktopTargetId="desktop-target-1"
        deviceUid="windows-1"
        password={sensitiveValue}
        title="Finance desktop"
      />
    )

    expect(html).toContain("rdp-credential-form")
    expect(html).toContain("rdp-windows-username")
    expect(html).toContain("rdp-windows-password")
    expect(html).toContain("card card-border")
    expect(html).toContain("fieldset")
    expect(html).toContain("Connect with RDP")
    expect(html).not.toContain(sensitiveValue)
  })
})

class FakeSocket {
  constructor() {
    this.readyState = 0
    this.listeners = new Map()
    this.send = vi.fn()
    this.close = vi.fn(() => {
      this.readyState = 3
    })
  }

  addEventListener(name, callback) {
    const callbacks = this.listeners.get(name) || []
    callbacks.push(callback)
    this.listeners.set(name, callbacks)
  }

  emit(name, payload = {}) {
    for (const callback of this.listeners.get(name) || []) {
      callback(payload)
    }
  }
}

describe("RDP launcher custody boundary", () => {
  it("builds the fixed server-selected session request", () => {
    expect(buildRdpSessionRequest(" desktop-target-1 ", " windows-1 ", " approval-1 ")).toEqual({
      protocol: "rdp",
      adapter: "rdp",
      desktop_target_id: "desktop-target-1",
      device_uid: "windows-1",
      approval_id: "approval-1",
    })
  })

  it("keeps the launcher disabled while waiting for the exact ready frame", () => {
    expect(rdpLaunchInProgress("opening")).toBe(true)
    expect(rdpLaunchInProgress("attaching")).toBe(true)
    expect(rdpLaunchInProgress("awaiting_ready")).toBe(true)
    expect(rdpLaunchInProgress("ready")).toBe(false)
    expect(rdpLaunchInProgress("failed")).toBe(false)
  })

  it("waits for the exact ready frame, clears credentials, and keeps the control socket alive", async () => {
    const socket = new FakeSocket()
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        data: desktopSession({
          id: "session-1",
          ticket: "single-use-ticket",
          websocket_path: "/v1/remote-access/sessions/session-1/stream",
        }),
      }),
    }))
    const onReady = vi.fn()
    const onStatus = vi.fn()
    const onCredentialCleared = vi.fn()
    const setTimeoutImpl = vi.fn(() => "launch-deadline")
    const clearTimeoutImpl = vi.fn()
    const runtime = createRdpLauncherRuntime({
      desktopTargetId: "desktop-target-1",
      deviceUid: "windows-1",
      fetchImpl,
      socketFactory: () => socket,
      csrfTokenProvider: () => "csrf-token",
      onReady,
      onStatus,
      onCredentialCleared,
      setTimeoutImpl,
      clearTimeoutImpl,
    })

    await runtime.open({username: " CARVER\\michael ", password: sensitiveValue})

    expect(fetchImpl).toHaveBeenCalledTimes(1)
    expect(fetchImpl.mock.calls[0][0]).toBe("/api/remote-access/sessions")
    expect(JSON.parse(fetchImpl.mock.calls[0][1].body)).toEqual({
      protocol: "rdp",
      adapter: "rdp",
      desktop_target_id: "desktop-target-1",
      device_uid: "windows-1",
    })

    socket.readyState = 1
    socket.emit("open")
    expect(JSON.parse(socket.send.mock.calls[0][0])).toEqual({
      type: "attach",
      ticket: "single-use-ticket",
      session_id: "session-1",
      credential: {username: "CARVER\\michael", password: sensitiveValue},
    })
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)
    expect(onStatus).toHaveBeenLastCalledWith("awaiting_ready")
    expect(setTimeoutImpl).toHaveBeenCalledTimes(1)

    socket.emit("message", {data: JSON.stringify({type: "ready", session_id: "different-session"})})
    expect(onReady).not.toHaveBeenCalled()
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)

    socket.emit("message", {data: JSON.stringify({type: "ready", session_id: "session-1"})})
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)
    expect(onReady).toHaveBeenCalledWith(expect.objectContaining({id: "session-1"}))
    expect(clearTimeoutImpl).toHaveBeenCalledWith("launch-deadline")
    expect(socket.close).not.toHaveBeenCalled()

    const dateNow = vi.spyOn(Date, "now").mockReturnValue(100_000)
    expect(runtime.recordActivity()).toBe(true)
    expect(runtime.recordActivity()).toBe(false)
    expect(JSON.parse(socket.send.mock.calls[1][0])).toEqual({
      type: "activity",
      session_id: "session-1",
    })

    dateNow.mockReturnValue(130_001)
    expect(runtime.recordActivity()).toBe(true)
    expect(JSON.parse(socket.send.mock.calls[2][0])).toEqual({
      type: "activity",
      session_id: "session-1",
    })
    dateNow.mockRestore()

    runtime.close("test teardown")
    await Promise.resolve()

    expect(socket.close).toHaveBeenCalledWith(1000, "test teardown")
    expect(fetchImpl).toHaveBeenCalledTimes(2)
    expect(fetchImpl.mock.calls[1][0]).toBe("/api/remote-access/sessions/session-1/close")
    expect(fetchImpl.mock.calls[1][1].body).not.toContain(sensitiveValue)
  })

  it("times out and aborts a late session POST without resurrecting the launch", async () => {
    let expireLaunch
    let resolveSessionPost
    let requestOptions
    const responseJson = vi.fn(async () => ({
      data: desktopSession({
        id: "late-session",
        ticket: "late-ticket",
        websocket_path: "/v1/remote-access/sessions/late-session/stream",
      }),
    }))
    const fetchImpl = vi.fn((path, options) => {
      if (path === "/api/remote-access/sessions") {
        requestOptions = options
        return new Promise((resolve) => {
          resolveSessionPost = resolve
        })
      }

      return Promise.resolve({
        ok: true,
        json: async () => ({data: {status: "closing"}}),
      })
    })
    const socketFactory = vi.fn()
    const onError = vi.fn()
    const onCredentialCleared = vi.fn()
    const clearTimeoutImpl = vi.fn()
    const runtime = createRdpLauncherRuntime({
      desktopTargetId: "desktop-target-1",
      deviceUid: "windows-1",
      fetchImpl,
      socketFactory,
      csrfTokenProvider: () => "csrf-token",
      onError,
      onCredentialCleared,
      launchTimeoutMs: 10_000,
      setTimeoutImpl(callback) {
        expireLaunch = callback
        return "launch-deadline"
      },
      clearTimeoutImpl,
    })

    const openPromise = runtime.open({username: "michael", password: sensitiveValue})

    expect(requestOptions.signal).toBeInstanceOf(AbortSignal)
    expireLaunch()
    expect(requestOptions.signal.aborted).toBe(true)
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(
      "The RDP session did not become ready before the launch deadline.",
    )

    resolveSessionPost({ok: true, json: responseJson})
    await openPromise

    expect(responseJson).toHaveBeenCalledTimes(1)
    expect(socketFactory).not.toHaveBeenCalled()
    expect(clearTimeoutImpl).toHaveBeenCalledWith("launch-deadline")
    expect(fetchImpl.mock.calls[1]).toEqual([
      "/api/remote-access/sessions/late-session/close",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({reason: "RDP launcher closed during session creation"}),
        keepalive: true,
      }),
    ])
  })

  it("closes a created session that misses the ready deadline", async () => {
    const socket = new FakeSocket()
    let expireLaunch
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        data: desktopSession({
          id: "session-1",
          ticket: "single-use-ticket",
          websocket_path: "/v1/remote-access/sessions/session-1/stream",
        }),
      }),
    }))
    const onError = vi.fn()
    const onCredentialCleared = vi.fn()
    const runtime = createRdpLauncherRuntime({
      desktopTargetId: "desktop-target-1",
      deviceUid: "windows-1",
      fetchImpl,
      socketFactory: () => socket,
      csrfTokenProvider: () => "csrf-token",
      onError,
      onCredentialCleared,
      setTimeoutImpl(callback) {
        expireLaunch = callback
        return "launch-deadline"
      },
      clearTimeoutImpl: vi.fn(),
    })

    await runtime.open({username: "michael", password: sensitiveValue})
    socket.readyState = 1
    socket.emit("open")
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)

    expireLaunch()
    await Promise.resolve()

    expect(socket.close).toHaveBeenCalledWith(1000, "RDP session failed")
    expect(onError).toHaveBeenCalledWith(
      "The RDP session did not become ready before the launch deadline.",
    )
    expect(fetchImpl.mock.calls[1][0]).toBe("/api/remote-access/sessions/session-1/close")
    expect(onCredentialCleared).toHaveBeenCalledTimes(1)
  })

  it("deterministically closes the API session when the ready control socket fails", async () => {
    const socket = new FakeSocket()
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        data: desktopSession({
          id: "session-1",
          ticket: "single-use-ticket",
          websocket_path: "/v1/remote-access/sessions/session-1/stream",
        }),
      }),
    }))
    const onError = vi.fn()
    const onClosed = vi.fn()
    const runtime = createRdpLauncherRuntime({
      desktopTargetId: "desktop-target-1",
      deviceUid: "windows-1",
      fetchImpl,
      socketFactory: () => socket,
      csrfTokenProvider: () => "csrf-token",
      onError,
      onClosed,
      setTimeoutImpl: vi.fn(() => "launch-deadline"),
      clearTimeoutImpl: vi.fn(),
    })

    await runtime.open({username: "michael", password: sensitiveValue})
    socket.readyState = 1
    socket.emit("open")
    socket.emit("message", {data: JSON.stringify({type: "ready", session_id: "session-1"})})
    socket.emit("error")
    await Promise.resolve()

    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith("The RDP control channel failed.")
    expect(onClosed).toHaveBeenCalledTimes(1)
    expect(socket.close).toHaveBeenCalledWith(1000, "RDP session failed")
    expect(fetchImpl.mock.calls[1][0]).toBe("/api/remote-access/sessions/session-1/close")
  })

  it("recognizes only ready frames bound to the created session", () => {
    expect(readyForSession({type: "ready", session_id: "session-1"}, "session-1")).toBe(true)
    expect(readyForSession({type: "ready", session_id: "session-2"}, "session-1")).toBe(false)
    expect(readyForSession({type: "connected", session_id: "session-1"}, "session-1")).toBe(false)
  })
})
