const FRAME_MAGIC = "SRCM"
const FRAME_VERSION = 1
const FRAME_HEADER_SIZE = 36
const FRAME_KEYFRAME_FLAG = 0x01
const ANNEXB_START_CODE_3 = [0x00, 0x00, 0x01]
const ANNEXB_START_CODE_4 = [0x00, 0x00, 0x00, 0x01]
const H264_SPS_NAL_TYPE = 7
const DEFAULT_FRAME_DURATION_US = 33_333
const MAX_DECODE_QUEUE_SIZE = 12

function decodeUtf8(bytes) {
  return new TextDecoder().decode(bytes)
}

function hexByte(value) {
  return value.toString(16).padStart(2, "0")
}

function startCodeLength(bytes, offset) {
  if (
    offset + 3 < bytes.length &&
    bytes[offset] === ANNEXB_START_CODE_4[0] &&
    bytes[offset + 1] === ANNEXB_START_CODE_4[1] &&
    bytes[offset + 2] === ANNEXB_START_CODE_4[2] &&
    bytes[offset + 3] === ANNEXB_START_CODE_4[3]
  ) {
    return 4
  }

  if (
    offset + 2 < bytes.length &&
    bytes[offset] === ANNEXB_START_CODE_3[0] &&
    bytes[offset + 1] === ANNEXB_START_CODE_3[1] &&
    bytes[offset + 2] === ANNEXB_START_CODE_3[2]
  ) {
    return 3
  }

  return 0
}

export function parseRelayChunkFrame(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data)

  if (bytes.byteLength < FRAME_HEADER_SIZE) {
    throw new Error("camera relay media frame is truncated")
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const magic = decodeUtf8(bytes.subarray(0, 4))
  const version = view.getUint8(4)

  if (magic !== FRAME_MAGIC) {
    throw new Error("camera relay media frame magic mismatch")
  }

  if (version !== FRAME_VERSION) {
    throw new Error(`camera relay media frame version ${version} is unsupported`)
  }

  const flags = view.getUint8(5)
  const sequence = Number(view.getBigUint64(6, false))
  const pts = Number(view.getBigInt64(14, false))
  const dts = Number(view.getBigInt64(22, false))
  const codecLength = view.getUint16(30, false)
  const payloadFormatLength = view.getUint16(32, false)
  const trackIdLength = view.getUint16(34, false)

  let offset = FRAME_HEADER_SIZE
  const metadataLength = codecLength + payloadFormatLength + trackIdLength

  if (offset + metadataLength > bytes.byteLength) {
    throw new Error("camera relay media frame metadata is truncated")
  }

  const codec = decodeUtf8(bytes.subarray(offset, offset + codecLength))
  offset += codecLength

  const payloadFormat = decodeUtf8(bytes.subarray(offset, offset + payloadFormatLength))
  offset += payloadFormatLength

  const trackId = decodeUtf8(bytes.subarray(offset, offset + trackIdLength))
  offset += trackIdLength

  return {
    sequence,
    pts,
    dts,
    keyframe: (flags & FRAME_KEYFRAME_FLAG) !== 0,
    codec,
    payloadFormat,
    trackId,
    payload: bytes.subarray(offset),
  }
}

export function findAnnexBNalUnits(payload) {
  const bytes = payload instanceof Uint8Array ? payload : new Uint8Array(payload)
  const units = []
  let offset = 0

  while (offset < bytes.length) {
    const codeLength = startCodeLength(bytes, offset)

    if (codeLength === 0) {
      offset += 1
      continue
    }

    const nalStart = offset + codeLength
    let nalEnd = nalStart

    while (nalEnd < bytes.length && startCodeLength(bytes, nalEnd) === 0) {
      nalEnd += 1
    }

    if (nalEnd > nalStart) {
      units.push(bytes.subarray(nalStart, nalEnd))
    }

    offset = nalEnd
  }

  return units
}

export function codecStringFromAnnexB(payload) {
  const units = findAnnexBNalUnits(payload)

  for (const unit of units) {
    if (unit.length < 4) {
      continue
    }

    const nalType = unit[0] & 0x1f

    if (nalType === H264_SPS_NAL_TYPE) {
      return `avc1.${hexByte(unit[1])}${hexByte(unit[2])}${hexByte(unit[3])}`
    }
  }

  return null
}

function frameTimestampUs(frame, lastTimestampUs) {
  if (Number.isFinite(frame.pts) && frame.pts > 0) {
    return Math.floor(frame.pts / 1000)
  }

  if (Number.isFinite(frame.dts) && frame.dts > 0) {
    return Math.floor(frame.dts / 1000)
  }

  if (Number.isFinite(lastTimestampUs) && lastTimestampUs >= 0) {
    return lastTimestampUs + DEFAULT_FRAME_DURATION_US
  }

  return 0
}

export class CameraRelayCanvasPlayer {
  constructor({canvas, setStatus}) {
    this.canvas = canvas
    this.setStatus = typeof setStatus === "function" ? setStatus : () => {}
    this.decoder = null
    this.context = null
    this.codec = null
    this.lastTimestampUs = null
    this.decodedFrameCount = 0
    this.droppedFrameCount = 0
  }

  close() {
    if (this.decoder) {
      this.decoder.close()
      this.decoder = null
    }
  }

  consume(data) {
    if (!window.VideoDecoder) {
      this.setStatus("Browser video decoder unavailable")
      return {decoded: false, reason: "video_decoder_unavailable"}
    }

    const frame = parseRelayChunkFrame(data)

    if (frame.trackId && frame.trackId !== "video") {
      return {decoded: false, reason: "non_video_track"}
    }

    if (frame.codec && frame.codec !== "h264") {
      this.setStatus(`Unsupported camera codec ${frame.codec}`)
      return {decoded: false, reason: "unsupported_codec"}
    }

    if (frame.payloadFormat && frame.payloadFormat !== "annexb") {
      this.setStatus(`Unsupported camera payload format ${frame.payloadFormat}`)
      return {decoded: false, reason: "unsupported_payload_format"}
    }

    if (!this.ensureDecoder(frame)) {
      return {decoded: false, reason: "decoder_not_ready"}
    }

    if (this.decoder.decodeQueueSize > MAX_DECODE_QUEUE_SIZE && !frame.keyframe) {
      this.droppedFrameCount += 1
      this.setStatus(`Dropping delayed video frames (${this.droppedFrameCount})`)
      return {decoded: false, reason: "decoder_backpressure"}
    }

    const timestamp = frameTimestampUs(frame, this.lastTimestampUs)
    const duration =
      Number.isFinite(this.lastTimestampUs) && timestamp > this.lastTimestampUs
        ? timestamp - this.lastTimestampUs
        : DEFAULT_FRAME_DURATION_US

    this.lastTimestampUs = timestamp

    this.decoder.decode(
      new EncodedVideoChunk({
        type: frame.keyframe ? "key" : "delta",
        timestamp,
        duration,
        data: frame.payload,
      })
    )

    return {decoded: true, frame}
  }

  ensureDecoder(frame) {
    const codec = codecStringFromAnnexB(frame.payload)

    if (!this.decoder) {
      if (!frame.keyframe || !codec) {
        this.setStatus("Waiting for H264 keyframe and SPS")
        return false
      }

      this.context = this.canvas?.getContext("2d", {alpha: false, desynchronized: true})
      this.codec = codec
      this.decoder = new VideoDecoder({
        output: (videoFrame) => this.render(videoFrame),
        error: (error) => this.setStatus(`Video decode error: ${error.message}`),
      })
      this.decoder.configure({
        codec,
        optimizeForLatency: true,
        hardwareAcceleration: "prefer-hardware",
      })
      this.setStatus(`Decoding ${codec} video`)
      return true
    }

    if (codec && codec !== this.codec) {
      this.close()
      this.codec = null
      this.lastTimestampUs = null
      return this.ensureDecoder(frame)
    }

    return true
  }

  render(videoFrame) {
    try {
      if (!this.context || !this.canvas) {
        this.setStatus("Video surface unavailable")
        return
      }

      if (this.canvas.width !== videoFrame.codedWidth || this.canvas.height !== videoFrame.codedHeight) {
        this.canvas.width = videoFrame.codedWidth
        this.canvas.height = videoFrame.codedHeight
      }

      this.context.drawImage(videoFrame, 0, 0, this.canvas.width, this.canvas.height)
      this.decodedFrameCount += 1
      this.setStatus(`Rendering live video (${this.decodedFrameCount} frames)`)
    } finally {
      videoFrame.close()
    }
  }
}
