import {describe, expect, it} from "vitest"

import {codecStringFromAnnexB, parseRelayChunkFrame} from "./player"

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
})
