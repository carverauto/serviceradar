import {describe, expect, it} from "vitest"

import {
  DESKTOP_PAYLOAD_DIRTY_RECT,
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  encodeDesktopMediaFrame,
  parseDesktopMediaFrame,
} from "./media_frame"
import {
  applyCanvasTileFrame,
  applyWebGPUTileFrame,
  createDirtyTileMask,
  createDesktopRenderQueue,
  desktopPolicyStatusItems,
  desktopMetadataAttachment,
  desktopFrameUploadPlan,
  dirtyTileMaskHas,
  normalizeDesktopPolicySnapshot,
} from "./renderer_state"

describe("remote desktop renderer state helpers", () => {
  it("normalizes sanitized desktop policy snapshots for renderer status display", () => {
    const snapshot = {
      target: {
        display_name: "Finance jump desktop",
        device_uid: "windows-1",
        protocol: "rdp",
      },
      route: {
        agent_id: "agent-1",
        gateway_id: "gateway-1",
      },
      credential: {
        custody_mode: "user_present",
        brokered_rule_bound: false,
      },
      authorization: {
        rbac_decision: "allowed",
      },
      desktop: {
        target_tls: {
          mode: "verify_ca",
          password: "must-not-survive",
        },
        nla: {
          required: "true",
          private_key: "must-not-survive",
        },
        screen_policy: {
          max_width: 1920,
          max_height: 1080,
          max_frame_rate: 30,
        },
        redirection_policy: {
          clipboard: "disabled",
          drive: "disabled",
          audio: "enabled",
        },
        approval_policy: {
          required: true,
          token: "must-not-survive",
        },
      },
      recording: {
        policy: {
          mode: "metadata",
          secret: "must-not-survive",
        },
      },
      timeouts: {
        idle_timeout_seconds: 900,
        absolute_timeout_seconds: 3600,
      },
    }

    const policy = normalizeDesktopPolicySnapshot(snapshot)

    expect(policy.target).toMatchObject({
      label: "Finance jump desktop",
      deviceUid: "windows-1",
      protocol: "rdp",
    })
    expect(policy.route.label).toBe("agent-1 / gateway-1")
    expect(policy.credential.custodyMode).toBe("user_present")
    expect(policy.transport).toMatchObject({tlsMode: "verify_ca", nlaRequired: true})
    expect(policy.screen).toMatchObject({maxWidth: 1920, maxHeight: 1080, maxFrameRate: 30})
    expect(policy.redirection).toMatchObject({
      clipboard: "disabled",
      drive: "disabled",
      audio: "enabled",
    })
    expect(policy.authorization.approvalRequired).toBe(true)
    expect(policy.recording.mode).toBe("metadata")
    expect(policy.timeouts).toMatchObject({idleTimeoutSeconds: 900, absoluteTimeoutSeconds: 3600})
    expect(JSON.stringify(policy)).not.toContain("must-not-survive")
  })

  it("builds stable desktop policy status items for the session shell", () => {
    const items = desktopPolicyStatusItems({
      target: {device_uid: "windows-1"},
      route: {agent_id: "agent-1"},
      credential: {custody_mode: "user_present"},
      authorization: {rbac_decision: "allowed"},
      desktop: {
        target_tls: {mode: "verify_ca"},
        nla: {required: true},
        screen_policy: {max_width: 1280, max_height: 720, max_frame_rate: 15},
        redirection_policy: {clipboard: "disabled", drive: "disabled"},
      },
      recording: {policy: {mode: "metadata"}},
    })

    expect(items).toEqual([
      {key: "target", label: "Target", value: "windows-1"},
      {key: "route", label: "Route", value: "agent-1"},
      {key: "credential", label: "Credential", value: "User Present"},
      {key: "redirection", label: "Redirection", value: "Disabled"},
      {key: "transport", label: "Transport", value: "Verify Ca / NLA Required"},
      {key: "quota", label: "Quota", value: "1280x720 / 15 fps"},
      {key: "approval", label: "Approval", value: "Allowed"},
      {key: "recording", label: "Recording", value: "Metadata"},
    ])
  })

  it("builds a dirty tile mask for changed rectangles", () => {
    const mask = createDirtyTileMask(
      {width: 256, height: 128, tileSize: 64},
      [
        {x: 63, y: 0, width: 2, height: 64},
        {x: 192, y: 64, width: 64, height: 64},
      ]
    )

    expect(mask.columns).toBe(4)
    expect(mask.rows).toBe(2)
    expect(dirtyTileMaskHas(mask, 0, 0)).toBe(true)
    expect(dirtyTileMaskHas(mask, 1, 0)).toBe(true)
    expect(dirtyTileMaskHas(mask, 2, 0)).toBe(false)
    expect(dirtyTileMaskHas(mask, 3, 1)).toBe(true)
    expect(dirtyTileMaskHas(mask, 4, 1)).toBe(false)
  })

  it("creates no-copy tile upload descriptors from renderer-owned metadata", () => {
    const payload = new Uint8Array(32)
    payload.set([1, 2, 3, 4], 16)
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-render",
        mediaSessionId: "media-render",
        sequence: 10,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba",
        metadata: {
          tileSize: 2,
          tiles: [
            {
              x: 4,
              y: 6,
              width: 2,
              height: 2,
              payloadOffset: 16,
              payloadLength: 16,
              bytesPerRow: 8,
            },
          ],
        },
        payload,
      })
    )

    const [upload] = desktopFrameUploadPlan(frame)

    expect(upload).toMatchObject({
      x: 4,
      y: 6,
      width: 2,
      height: 2,
      bytesPerRow: 8,
      payloadOffset: 16,
      payloadLength: 16,
    })
    expect(upload.source.byteOffset).toBe(frame.payload.byteOffset + 16)
    expect(upload.source.buffer).toBe(frame.payload.buffer)
  })

  it("applies tile frames to a Canvas-compatible harness", () => {
    const calls = []
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba",
        metadata: {
          tiles: [{x: 8, y: 12, width: 1, height: 1, payloadOffset: 0, payloadLength: 4}],
        },
        payload: new Uint8Array([9, 8, 7, 255]),
      })
    )

    const applied = applyCanvasTileFrame(
      frame,
      {
        putImageData(imageData, x, y) {
          calls.push({imageData, x, y})
        },
      },
      (bytes, width, height) => ({bytes, width, height})
    )

    expect(applied).toBe(1)
    expect(calls).toEqual([
      {
        imageData: {bytes: frame.payload, width: 1, height: 1},
        x: 8,
        y: 12,
      },
    ])
  })

  it("compacts sparse dirty rectangle rows for the Canvas fallback", () => {
    const payload = new Uint8Array([
      1, 2, 3, 255, 4, 5, 6, 255,
      0, 0, 0, 0, 0, 0, 0, 0,
      7, 8, 9, 255, 10, 11, 12, 255,
    ])
    const calls = []
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_DIRTY_RECT,
        encoding: "rgba",
        metadata: {
          dirtyRects: [{
            x: 4,
            y: 6,
            width: 2,
            height: 2,
            payloadOffset: 0,
            payloadLength: payload.byteLength,
            bytesPerRow: 16,
          }],
        },
        payload,
      })
    )

    const applied = applyCanvasTileFrame(
      frame,
      {
        putImageData(imageData, x, y) {
          calls.push({imageData, x, y})
        },
      },
      (bytes, width, height) => ({bytes, width, height})
    )

    expect(applied).toBe(1)
    expect(calls).toEqual([
      {
        imageData: {
          bytes: new Uint8Array([
            1, 2, 3, 255, 4, 5, 6, 255,
            7, 8, 9, 255, 10, 11, 12, 255,
          ]),
          width: 2,
          height: 2,
        },
        x: 4,
        y: 6,
      },
    ])
    expect(calls[0].imageData.bytes.buffer).not.toBe(frame.payload.buffer)
  })

  it("keeps metadata-only frames out of screen-pixel upload paths", () => {
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        metadata: {frameStats: {decodeQueueSize: 1}},
        payload: new Uint8Array(),
      })
    )
    const calls = []

    expect(desktopFrameUploadPlan(frame)).toEqual([])
    expect(
      applyCanvasTileFrame(frame, {
        putImageData(...args) {
          calls.push(args)
        },
      })
    ).toBe(0)
    expect(calls).toEqual([])
  })

  it("applies tile frames through a WebGPU queue-compatible harness", () => {
    const writes = []
    const texture = {label: "desktop-texture"}
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba",
        metadata: {
          tiles: [{x: 64, y: 128, width: 64, height: 1, payloadOffset: 16, payloadLength: 256, bytesPerRow: 256}],
        },
        payload: new Uint8Array(512),
      })
    )

    const applied = applyWebGPUTileFrame(frame, {
      writeTexture(destination, source, layout, size) {
        writes.push({destination, source, layout, size})
      },
    }, texture)

    expect(applied).toBe(1)
    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatchObject({
      destination: {texture, origin: {x: 64, y: 128, z: 0}},
      layout: {bytesPerRow: 256, rowsPerImage: 1},
      size: {width: 64, height: 1, depthOrArrayLayers: 1},
    })
    expect(writes[0].source.buffer).toBe(frame.payload.buffer)
    expect(writes[0].source.byteOffset).toBe(frame.payload.byteOffset + 16)
  })

  it("keeps Arrow IPC metadata attachments separate from screen-pixel upload paths", () => {
    const arrowBytes = new Uint8Array([255, 65, 82, 82, 79, 87])
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        metadata: {format: "arrow_ipc", role: "overlay", overlayId: "quota"},
        payload: arrowBytes,
      })
    )

    const attachment = desktopMetadataAttachment(frame)

    expect(desktopFrameUploadPlan(frame)).toEqual([])
    expect(attachment).toMatchObject({
      role: "overlay",
      format: "arrow_ipc",
      metadata: {format: "arrow_ipc", role: "overlay", overlayId: "quota"},
    })
    expect(attachment.bytes.buffer).toBe(frame.payload.buffer)
    expect(attachment.bytes.byteOffset).toBe(frame.payload.byteOffset)
  })

  it("rejects metadata attachments that try to masquerade as screen pixels", () => {
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        metadata: {format: "arrow_ipc", role: "screen_pixels"},
        payload: new Uint8Array([1, 2, 3, 4]),
      })
    )

    expect(desktopMetadataAttachment(frame)).toBeNull()
    expect(desktopFrameUploadPlan(frame)).toEqual([])
  })

  it("does not treat Arrow IPC tile payloads as renderer upload descriptors", () => {
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "arrow_ipc",
        metadata: {
          format: "arrow_ipc",
          tiles: [{x: 0, y: 0, width: 1, height: 1, payloadOffset: 0, payloadLength: 4}],
        },
        payload: new Uint8Array([1, 2, 3, 4]),
      })
    )

    expect(desktopFrameUploadPlan(frame)).toEqual([])
  })

  it("coalesces stale non-critical renderer frames when the queue is full", () => {
    const queue = createDesktopRenderQueue({maxFrames: 2})
    const first = rendererFrame({sequence: 1})
    const second = rendererFrame({sequence: 2})
    const replacement = rendererFrame({sequence: 3})

    expect(queue.push(first)).toMatchObject({accepted: true, coalesced: false, dropped: []})
    expect(queue.push(second)).toMatchObject({accepted: true, coalesced: false, dropped: []})

    const result = queue.push(replacement)

    expect(result).toMatchObject({accepted: true, coalesced: true})
    expect(result.dropped).toEqual([second])
    expect(queue.snapshot().map((frame) => frame.sequence)).toEqual([1, 3])
    expect(queue.state()).toEqual({decodeQueueSize: 2, maxDecodeQueueSize: 2})
  })

  it("preserves critical metadata frames by evicting non-critical queued frames", () => {
    const queue = createDesktopRenderQueue({maxFrames: 2})
    const first = rendererFrame({sequence: 1})
    const second = rendererFrame({sequence: 2})
    const metadata = rendererFrame({sequence: 3, payloadFamily: DESKTOP_PAYLOAD_METADATA})

    queue.push(first)
    queue.push(second)

    const result = queue.push(metadata)

    expect(result).toMatchObject({accepted: true, coalesced: false})
    expect(result.dropped).toEqual([first])
    expect(queue.snapshot().map((frame) => frame.sequence)).toEqual([2, 3])
  })

  it("does not coalesce stale renderer frames across media bindings", () => {
    const queue = createDesktopRenderQueue({maxFrames: 2})
    const first = rendererFrame({sequence: 1, mediaSessionId: "media-a"})
    const second = rendererFrame({sequence: 2, mediaSessionId: "media-b"})
    const otherBinding = rendererFrame({sequence: 3, mediaSessionId: "media-c"})

    queue.push(first)
    queue.push(second)

    const result = queue.push(otherBinding)

    expect(result).toMatchObject({accepted: false, coalesced: false})
    expect(result.dropped).toEqual([otherBinding])
    expect(queue.snapshot().map((frame) => frame.mediaSessionId)).toEqual(["media-a", "media-b"])
  })
})

function rendererFrame({
  sequence,
  payloadFamily = DESKTOP_PAYLOAD_TILE,
  sessionBindingId = "session-render-queue",
  mediaSessionId = "media-render-queue",
} = {}) {
  return {
    sequence,
    payloadFamily,
    sessionBindingId,
    mediaSessionId,
  }
}
