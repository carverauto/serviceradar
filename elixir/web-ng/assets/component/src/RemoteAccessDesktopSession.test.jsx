import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {Component as RemoteAccessDesktopSession} from "./RemoteAccessDesktopSession.jsx"

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
      <RemoteAccessDesktopSession
        session={desktopSession()}
        title="RDP session"
      />
    )

    expect(html).toContain("RDP session")
    expect(html).toContain("Finance desktop")
    expect(html).toContain("Remote desktop display")
    expect(html).toContain("0 tile updates")
    expect(html).toContain("agent-1 / gateway-1")
    expect(html).toContain("User Present")
    expect(html).toContain("1920x1080 / 30 fps")
    expect(html).toContain("0/12 queued")
    expect(html).toContain("No frames")
    expect(html).toContain("Metadata")
    expect(html).not.toContain(sensitiveValue)
  })

  it("shows the unavailable media state when WebRTC metadata is missing", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopSession
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
      <RemoteAccessDesktopSession
        queueMaxFrames={3}
        session={desktopSession()}
      />
    )

    expect(html).toContain("0/3 queued")
  })

  it("renders an empty selection state without creating a media client", () => {
    const html = renderToStaticMarkup(
      <RemoteAccessDesktopSession
        clientFactory={() => {
          throw new Error("client factory should not run without a selected session")
        }}
      />
    )

    expect(html).toContain("No RDP session selected.")
  })
})
