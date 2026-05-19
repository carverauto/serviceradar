import {describe, expect, it} from "vitest"

import {
  DESKTOP_PAYLOAD_DIRTY_RECT,
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  DESKTOP_PAYLOAD_VIDEO,
  DESKTOP_RENDERER_CANVAS_REGIONS,
  DESKTOP_RENDERER_WEBCODECS_VIDEO,
  DESKTOP_RENDERER_WEBGPU_REGIONS,
  DESKTOP_TRANSPORT_WEBRTC,
  createDesktopMediaFrameParser,
  detectDesktopRendererCapabilities,
  encodeDesktopMediaFrame,
  parseDesktopMediaFrame,
  parseDesktopMediaMetadata,
  selectDesktopMediaTransport,
  selectDesktopRendererMode,
  shouldDropStaleDesktopFrame,
} from "./media_frame"

describe("remote desktop media frame envelope", () => {
  it("round-trips a binary video frame", () => {
    const payload = new Uint8Array([0, 0, 0, 1, 0x65, 0x88, 0x84])
    const encoded = encodeDesktopMediaFrame({
      sessionBindingId: "session-compact-1",
      mediaSessionId: "media-1",
      sequence: 42,
      timestampUnixNano: 1_778_000_000,
      payloadFamily: DESKTOP_PAYLOAD_VIDEO,
      encoding: "h264_annexb",
      width: 1920,
      height: 1080,
      keyframe: true,
      fullFrame: true,
      metadata: {dirtyRegionCount: 0},
      payload,
    })

    const frame = parseDesktopMediaFrame(encoded)

    expect(frame.sessionBindingId).toBe("session-compact-1")
    expect(frame.mediaSessionId).toBe("media-1")
    expect(frame.sequence).toBe(42)
    expect(frame.timestampUnixNano).toBe(1_778_000_000)
    expect(frame.payloadFamily).toBe(DESKTOP_PAYLOAD_VIDEO)
    expect(frame.encoding).toBe("h264_annexb")
    expect(frame.width).toBe(1920)
    expect(frame.height).toBe(1080)
    expect(frame.keyframe).toBe(true)
    expect(frame.fullFrame).toBe(true)
    expect(Array.from(frame.payload)).toEqual(Array.from(payload))
    expect(parseDesktopMediaMetadata(frame)).toEqual({dirtyRegionCount: 0})
  })

  it("round-trips a dirty tile frame with metadata", () => {
    const frame = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        sessionBindingId: "s1",
        mediaSessionId: "m1",
        sequence: 7,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        width: 1280,
        height: 720,
        metadata: {
          tileSize: 64,
          roaringDirtyTiles: "base64-roaring-bitmap",
        },
        payload: new Uint8Array([1, 2, 3, 4]),
      })
    )

    expect(frame.payloadFamily).toBe(DESKTOP_PAYLOAD_TILE)
    expect(frame.keyframe).toBe(false)
    expect(parseDesktopMediaMetadata(frame)).toEqual({
      tileSize: 64,
      roaringDirtyTiles: "base64-roaring-bitmap",
    })
  })

  it("parses repeated media-session frames through a stable-field parser", () => {
    const parseFrame = createDesktopMediaFrameParser()
    const first = parseFrame(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-cache",
        mediaSessionId: "media-cache",
        sequence: 1,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        width: 1280,
        height: 720,
        payload: new Uint8Array([1]),
      })
    )
    const second = parseFrame(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-cache",
        mediaSessionId: "media-cache",
        sequence: 2,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba_zstd",
        width: 1280,
        height: 720,
        payload: new Uint8Array([2]),
      })
    )
    const changed = parseFrame(
      encodeDesktopMediaFrame({
        sessionBindingId: "session-cache",
        mediaSessionId: "media-cache-2",
        sequence: 3,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "bgra",
        width: 1280,
        height: 720,
        payload: new Uint8Array([3]),
      })
    )

    expect(first.sessionBindingId).toBe("session-cache")
    expect(second.sessionBindingId).toBe("session-cache")
    expect(second.mediaSessionId).toBe("media-cache")
    expect(second.encoding).toBe("rgba_zstd")
    expect(second.sequence).toBe(2)
    expect(Array.from(second.payload)).toEqual([2])
    expect(changed.mediaSessionId).toBe("media-cache-2")
    expect(changed.encoding).toBe("bgra")
  })

  it("rejects malformed frames", () => {
    expect(() => parseDesktopMediaFrame(new Uint8Array([1, 2, 3]))).toThrow("truncated")

    const badMagic = new Uint8Array(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        payload: new Uint8Array(),
      })
    )
    badMagic[0] = 0x58
    expect(() => parseDesktopMediaFrame(badMagic)).toThrow("magic mismatch")

    const truncated = new Uint8Array(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_VIDEO,
        payload: new Uint8Array([1, 2, 3]),
      })
    ).subarray(0, 50)
    expect(() => parseDesktopMediaFrame(truncated)).toThrow("payload is truncated")

    const valid = new Uint8Array(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_VIDEO,
        payload: new Uint8Array([1, 2, 3]),
      })
    )
    const trailing = new Uint8Array(valid.byteLength + 1)
    trailing.set(valid)
    trailing[valid.byteLength] = 0xff
    expect(() => parseDesktopMediaFrame(trailing)).toThrow("trailing bytes")

    const reservedByte = new Uint8Array(valid)
    reservedByte[7] = 1
    expect(() => parseDesktopMediaFrame(reservedByte)).toThrow("reserved header bytes")

    const reservedUint16 = new Uint8Array(valid)
    new DataView(reservedUint16.buffer).setUint16(46, 1, false)
    expect(() => parseDesktopMediaFrame(reservedUint16)).toThrow("reserved header bytes")

    const unknownFlags = new Uint8Array(valid)
    unknownFlags[5] = 0x20
    expect(() => parseDesktopMediaFrame(unknownFlags)).toThrow("flags are unsupported")
  })

  it("rejects unsupported flags during browser-side frame encoding", () => {
    expect(() =>
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        flags: 0x20,
        payload: new Uint8Array(),
      })
    ).toThrow("flags are unsupported")
  })

  it("selects renderer modes by payload family and browser capability", () => {
    expect(
      selectDesktopRendererMode([DESKTOP_PAYLOAD_VIDEO], {
        webcodecs: true,
        webgpu: false,
        canvas2d: true,
      })
    ).toBe(DESKTOP_RENDERER_WEBCODECS_VIDEO)

    expect(
      selectDesktopRendererMode([DESKTOP_PAYLOAD_DIRTY_RECT], {
        webcodecs: false,
        webgpu: true,
        canvas2d: true,
      })
    ).toBe(DESKTOP_RENDERER_WEBGPU_REGIONS)

    expect(
      selectDesktopRendererMode([DESKTOP_PAYLOAD_TILE], {
        webcodecs: false,
        webgpu: false,
        canvas2d: true,
      })
    ).toBe(DESKTOP_RENDERER_CANVAS_REGIONS)
  })

  it("detects desktop renderer capabilities from browser-like globals", () => {
    function Canvas() {}
    Canvas.prototype.getContext = () => ({})
    function PeerConnection() {}
    PeerConnection.prototype.createDataChannel = () => ({})

    expect(
      detectDesktopRendererCapabilities({
        VideoDecoder: function VideoDecoder() {},
        RTCPeerConnection: PeerConnection,
        HTMLCanvasElement: Canvas,
        navigator: {gpu: {}},
      })
    ).toEqual({
      webcodecs: true,
      webgpu: true,
      canvas2d: true,
      rtc_peer_connection: true,
      rtc_data_channel: true,
    })
  })

  it("selects WebRTC transport when peer connection and data channel are available", () => {
    const selection = selectDesktopMediaTransport(
      {
        available_transports: [DESKTOP_TRANSPORT_WEBRTC],
      },
      {
        rtc_peer_connection: true,
        rtc_data_channel: true,
      }
    )

    expect(selection.supported).toBe(true)
    expect(selection.selectedTransport).toBe(DESKTOP_TRANSPORT_WEBRTC)
  })

  it("rejects desktop media transport when WebRTC data channel support is unavailable", () => {
    const selection = selectDesktopMediaTransport(
      {
        preferred_transport: DESKTOP_TRANSPORT_WEBRTC,
        available_transports: [DESKTOP_TRANSPORT_WEBRTC],
      },
      {
        rtc_peer_connection: true,
        rtc_data_channel: false,
      }
    )

    expect(selection.supported).toBe(false)
    expect(selection.selectedTransport).toBeNull()
  })

  it("drops only stale non-critical frames when browser queues are saturated", () => {
    const delta = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_DIRTY_RECT,
        payload: new Uint8Array([1]),
      })
    )
    const keyframe = parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        payloadFamily: DESKTOP_PAYLOAD_VIDEO,
        keyframe: true,
        payload: new Uint8Array([1]),
      })
    )

    expect(shouldDropStaleDesktopFrame(delta, {decodeQueueSize: 13, maxDecodeQueueSize: 12})).toBe(true)
    expect(shouldDropStaleDesktopFrame(keyframe, {decodeQueueSize: 13, maxDecodeQueueSize: 12})).toBe(false)
    expect(shouldDropStaleDesktopFrame(delta, {decodeQueueSize: 2, maxDecodeQueueSize: 12})).toBe(false)
  })
})
