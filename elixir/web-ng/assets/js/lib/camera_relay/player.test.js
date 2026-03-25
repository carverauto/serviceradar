import {describe, expect, it} from "vitest"

import {
  CAMERA_RELAY_WEBRTC_TRANSPORT,
  CAMERA_RELAY_MSE_TRANSPORT,
  CAMERA_RELAY_WEBCODECS_TRANSPORT,
  codecStringFromAnnexB,
  detectBrowserPlaybackCapabilities,
  parseRelayChunkFrame,
  selectRelayPlaybackTransport,
} from "./player"

function encodeFrame({
  sequence = 3,
  pts = 33_000_000,
  dts = 33_000_000,
  keyframe = true,
  codec = "h264",
  payloadFormat = "annexb",
  trackId = "video",
  payload,
} = {}) {
  const encoder = new TextEncoder()
  const codecBytes = encoder.encode(codec)
  const payloadFormatBytes = encoder.encode(payloadFormat)
  const trackBytes = encoder.encode(trackId)
  const mediaPayload =
    payload ||
    new Uint8Array([
      0x00,
      0x00,
      0x00,
      0x01,
      0x67,
      0x64,
      0x00,
      0x1f,
      0xac,
      0xd9,
      0x40,
      0x50,
      0x05,
      0xbb,
      0x01,
      0x10,
      0x00,
      0x00,
      0x00,
      0x01,
      0x68,
      0xee,
      0x06,
      0xf2,
      0x00,
      0x00,
      0x00,
      0x01,
      0x65,
      0x88,
      0x84,
    ])

  const totalLength =
    36 + codecBytes.length + payloadFormatBytes.length + trackBytes.length + mediaPayload.length
  const buffer = new Uint8Array(totalLength)
  const view = new DataView(buffer.buffer)

  buffer.set(encoder.encode("SRCM"), 0)
  view.setUint8(4, 1)
  view.setUint8(5, keyframe ? 0x01 : 0x00)
  view.setBigUint64(6, BigInt(sequence), false)
  view.setBigInt64(14, BigInt(pts), false)
  view.setBigInt64(22, BigInt(dts), false)
  view.setUint16(30, codecBytes.length, false)
  view.setUint16(32, payloadFormatBytes.length, false)
  view.setUint16(34, trackBytes.length, false)

  let offset = 36
  buffer.set(codecBytes, offset)
  offset += codecBytes.length
  buffer.set(payloadFormatBytes, offset)
  offset += payloadFormatBytes.length
  buffer.set(trackBytes, offset)
  offset += trackBytes.length
  buffer.set(mediaPayload, offset)

  return buffer.buffer
}

describe("camera relay player framing", () => {
  it("prefers the WebRTC relay transport when advertised and browser support is present", () => {
    const selection = selectRelayPlaybackTransport(
      {
        preferred_playback_transport: CAMERA_RELAY_WEBRTC_TRANSPORT,
        available_playback_transports: [
          CAMERA_RELAY_WEBRTC_TRANSPORT,
          CAMERA_RELAY_WEBCODECS_TRANSPORT,
        ],
      },
      {
        webrtc: true,
        rtc_peer_connection: true,
        websocket: true,
        webcodecs: true,
        video_decoder: true,
      }
    )

    expect(selection.supported).toBe(true)
    expect(selection.selectedTransport).toBe(CAMERA_RELAY_WEBRTC_TRANSPORT)
  })

  it("parses camera relay binary frames", () => {
    const frame = parseRelayChunkFrame(encodeFrame())

    expect(frame.sequence).toBe(3)
    expect(frame.pts).toBe(33_000_000)
    expect(frame.dts).toBe(33_000_000)
    expect(frame.keyframe).toBe(true)
    expect(frame.codec).toBe("h264")
    expect(frame.payloadFormat).toBe("annexb")
    expect(frame.trackId).toBe("video")
    expect(frame.payload).toBeInstanceOf(Uint8Array)
    expect(frame.payload.byteLength).toBeGreaterThan(0)
  })

  it("derives an avc1 codec string from annexb payloads", () => {
    const frame = parseRelayChunkFrame(encodeFrame())

    expect(codecStringFromAnnexB(frame.payload)).toBe("avc1.64001f")
  })

  it("selects the current websocket WebCodecs transport when browser capabilities are present", () => {
    const selection = selectRelayPlaybackTransport(
      {
        preferred_playback_transport: CAMERA_RELAY_WEBCODECS_TRANSPORT,
        available_playback_transports: [CAMERA_RELAY_WEBCODECS_TRANSPORT],
      },
      {
        websocket: true,
        webcodecs: true,
        video_decoder: true,
      }
    )

    expect(selection.supported).toBe(true)
    expect(selection.selectedTransport).toBe(CAMERA_RELAY_WEBCODECS_TRANSPORT)
  })

  it("falls back to the MSE transport when WebCodecs is unavailable", () => {
    const selection = selectRelayPlaybackTransport(
      {
        preferred_playback_transport: CAMERA_RELAY_WEBCODECS_TRANSPORT,
        available_playback_transports: [
          CAMERA_RELAY_WEBCODECS_TRANSPORT,
          CAMERA_RELAY_MSE_TRANSPORT,
        ],
      },
      {
        websocket: true,
        webcodecs: false,
        video_decoder: false,
        media_source: true,
        mse_h264: true,
      }
    )

    expect(selection.supported).toBe(true)
    expect(selection.selectedTransport).toBe(CAMERA_RELAY_MSE_TRANSPORT)
  })

  it("reports missing browser capabilities when no playback transport is usable", () => {
    const selection = selectRelayPlaybackTransport(
      {
        preferred_playback_transport: CAMERA_RELAY_WEBCODECS_TRANSPORT,
        available_playback_transports: [CAMERA_RELAY_WEBCODECS_TRANSPORT],
      },
      {
        websocket: true,
        webcodecs: false,
        video_decoder: false,
      }
    )

    expect(selection.supported).toBe(false)
    expect(selection.selectedTransport).toBeNull()
    expect(selection.missingCapabilities).toEqual(["webcodecs", "video_decoder"])
  })

  it("detects WebCodecs support from a browser-like global object", () => {
    function MediaSource() {}
    MediaSource.isTypeSupported = () => true

    expect(
      detectBrowserPlaybackCapabilities({
        RTCPeerConnection: function RTCPeerConnection() {},
        WebSocket: function WebSocket() {},
        VideoDecoder: function VideoDecoder() {},
        MediaSource,
      })
    ).toEqual({
      webrtc: true,
      rtc_peer_connection: true,
      websocket: true,
      webcodecs: true,
      video_decoder: true,
      media_source: true,
      mse_h264: true,
    })
  })
})
