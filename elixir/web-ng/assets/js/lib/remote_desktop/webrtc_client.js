import {createDesktopMediaFrameParser, shouldDropStaleDesktopFrame} from "./media_frame"

export const DESKTOP_MEDIA_CHANNEL = "desktop-media"
export const DESKTOP_CONTROL_CHANNEL = "desktop-control"
export const DESKTOP_MEDIA_ACK_MESSAGE = "desktop_media_ack"
export const DESKTOP_MEDIA_QUALITY_LOW = "low"
export const DESKTOP_MEDIA_QUALITY_AUTO = "auto"
export const DESKTOP_MEDIA_MAX_CLOSE_REASON = 256
const DEFAULT_DESKTOP_MEDIA_CLOSE_REASON = "viewer closed remote desktop WebRTC session"
const ALLOWED_SDP_MEDIA_TYPES = new Set(["application", "video"])
const ALLOWED_SDP_VIDEO_CODECS = new Set(["h264", "vp8", "vp9", "av1"])
const ALLOWED_SDP_VIDEO_REPAIR_CODECS = new Set(["rtx", "red", "ulpfec", "flexfec-03"])
const textEncoder = new TextEncoder()

function csrfHeaders(documentRef = globalThis.document) {
  const csrfToken = documentRef?.querySelector?.("meta[name='csrf-token']")?.getAttribute("content")

  return {
    Accept: "application/json",
    "Content-Type": "application/json",
    ...(csrfToken ? {"x-csrf-token": csrfToken} : {}),
  }
}

async function jsonResponse(response) {
  const body = await response.json()

  if (!response.ok) {
    throw new Error(body?.message || body?.error || "remote desktop WebRTC request failed")
  }

  return body
}

function normalizeChannelLabel(label) {
  return typeof label === "string" ? label.trim() : ""
}

function channelReady(channel) {
  return channel?.readyState === "open"
}

export function desktopMediaStreamFromTrackEvent(event, mediaStreamFactory = globalThis.MediaStream) {
  const track = event?.track

  if (track?.kind !== "video") {
    return null
  }

  if (event.streams?.[0]) {
    return event.streams[0]
  }

  if (typeof mediaStreamFactory !== "function") {
    return null
  }

  try {
    return new mediaStreamFactory([track])
  } catch (error) {
    if (error instanceof TypeError) {
      return mediaStreamFactory([track])
    }

    throw error
  }
}

export function validateDesktopOfferSdp(sdp) {
  if (typeof sdp !== "string" || sdp.trim() === "") {
    throw new Error("remote desktop WebRTC offer SDP is required")
  }

  const sections = mediaSections(sdp)

  if (sections.length === 0) {
    throw new Error("remote desktop WebRTC offer has no media sections")
  }

  for (const section of sections) {
    const mediaType = section.mediaType

    if (!ALLOWED_SDP_MEDIA_TYPES.has(mediaType)) {
      throw new Error(`remote desktop WebRTC offer media type is not allowed: ${mediaType}`)
    }

    if (mediaType === "video") {
      validateVideoMediaSection(section)
    }
  }

  return sdp
}

export function isAllowedDesktopIceCandidate(candidate) {
  const candidateText = typeof candidate === "string" ? candidate : candidate?.candidate

  if (typeof candidateText !== "string" || candidateText.trim() === "") {
    return false
  }

  const address = candidateAddress(candidateText)

  if (!address || address.endsWith(".local")) {
    return false
  }

  if (isIPv4Address(address)) {
    return !isBlockedIPv4(address)
  }

  if (address.includes(":")) {
    return !isBlockedIPv6(address)
  }

  return false
}

export function createDesktopMediaProcessor({
  frameParser = createDesktopMediaFrameParser(),
  queueState = () => ({}),
  shouldDropFrame = shouldDropStaleDesktopFrame,
} = {}) {
  const safeQueueState = typeof queueState === "function" ? queueState : () => ({})
  const safeShouldDropFrame = typeof shouldDropFrame === "function" ? shouldDropFrame : shouldDropStaleDesktopFrame

  return {
    process(data) {
      const frame = frameParser(data)
      const currentQueueState = safeQueueState()

      return {
        frame,
        dropped: safeShouldDropFrame(frame, currentQueueState),
        queueState: currentQueueState,
      }
    },
    queueState: safeQueueState,
    close() {},
  }
}

export class RemoteDesktopWebRTCClient {
  constructor({
    signalingPath,
    iceServers = [],
    // Preserve the Window receiver when fetchJson calls this.fetchImpl.
    // See the default-fetch receiver regression in webrtc_client.test.js.
    fetchImpl = (...args) => globalThis.fetch(...args),
    peerConnectionFactory = (config) => new globalThis.RTCPeerConnection(config),
    documentRef = globalThis.document,
    onStatus = () => {},
    onFrame = () => {},
    onFrameDropped = () => {},
    onControlMessage = () => {},
    onAck = () => {},
    onOpen = () => {},
    onClose = () => {},
    onError = () => {},
    onMediaStream = () => {},
    mediaAckCreditBytes = 262_144,
    mediaAckFrameInterval = 4,
    mediaAckMaxDelayMs = 25,
    mediaQueueState = () => ({}),
    mediaProcessorFactory = createDesktopMediaProcessor,
  } = {}) {
    this.signalingPath = signalingPath
    this.iceServers = iceServers
    this.fetchImpl = fetchImpl
    this.peerConnectionFactory = peerConnectionFactory
    this.documentRef = documentRef
    this.onStatus = onStatus
    this.onFrame = onFrame
    this.onFrameDropped = onFrameDropped
    this.onControlMessage = onControlMessage
    this.onAck = onAck
    this.onOpen = onOpen
    this.onClose = onClose
    this.onError = onError
    this.onMediaStream = onMediaStream
    this.mediaAckCreditBytes = Math.max(1, mediaAckCreditBytes)
    this.mediaAckFrameInterval = Math.max(1, mediaAckFrameInterval)
    this.mediaAckMaxDelayMs = Math.max(0, mediaAckMaxDelayMs)
    this.mediaQueueState = typeof mediaQueueState === "function" ? mediaQueueState : () => ({})
    this.mediaProcessor = mediaProcessorFactory({
      queueState: this.mediaQueueState,
    })
    this.peerConnection = null
    this.viewerSessionId = null
    this.channels = new Map()
    this.closed = false
    this.pendingMediaAck = null
    this.pendingMediaAckQueue = null
    this.lastMediaAckBinding = null
    this.mediaAckTimer = null
    this.mediaBackpressurePaused = false
    this.connectGeneration = 0
  }

  async connect() {
    if (!this.signalingPath) {
      throw new Error("remote desktop WebRTC signaling path is required")
    }

    this.closed = false
    const generation = ++this.connectGeneration
    this.onStatus("creating_viewer_session")

    const sessionBody = await this.fetchJson(this.signalingPath, {method: "POST"})
    const session = sessionBody?.data || {}
    const viewerSessionId = session.viewer_session_id
    const offerSdp = session.offer_sdp

    if (!viewerSessionId || !offerSdp) {
      if (viewerSessionId) {
        await this.closeReturnedViewer(viewerSessionId, "desktop viewer creation returned an incomplete offer")
      }
      throw new Error("remote desktop WebRTC offer was not returned")
    }

    if (this.closed || generation !== this.connectGeneration) {
      await this.closeReturnedViewer(viewerSessionId, "desktop viewer closed during creation")
      throw new Error("remote desktop WebRTC connection was closed")
    }

    this.viewerSessionId = viewerSessionId
    try {
      this.peerConnection = this.peerConnectionFactory({
        iceServers: session.ice_servers || this.iceServers || [],
      })
      this.attachPeerHandlers()

      await this.peerConnection.setRemoteDescription({type: "offer", sdp: validateDesktopOfferSdp(offerSdp)})
      this.assertActiveConnection(generation)
      const answer = await this.peerConnection.createAnswer()
      this.assertActiveConnection(generation)
      await this.peerConnection.setLocalDescription(answer)
      this.assertActiveConnection(generation)

      await this.fetchJson(`${this.signalingPath}/${viewerSessionId}/answer`, {
        method: "POST",
        body: JSON.stringify({sdp: answer.sdp}),
      })
      this.assertActiveConnection(generation)

      this.onStatus("answer_applied")

      return {
        viewerSessionId,
        transport: session.transport,
        expiresAt: session.expires_at,
      }
    } catch (error) {
      if (!this.closed) {
        this.close("desktop viewer connect failed")
      }
      throw error
    }
  }

  sendControl(message) {
    const channel = this.channels.get(DESKTOP_CONTROL_CHANNEL)

    if (!channelReady(channel)) {
      return false
    }

    channel.send(typeof message === "string" ? message : JSON.stringify(message))
    return true
  }

  sendBinaryControl(bytes) {
    const channel = this.channels.get(DESKTOP_CONTROL_CHANNEL)

    if (!channelReady(channel)) {
      return false
    }

    channel.send(bytes)
    return true
  }

  close(reason = DEFAULT_DESKTOP_MEDIA_CLOSE_REASON) {
    if (this.closed) {
      return
    }

    this.closed = true
    this.connectGeneration += 1
    const closeReason = normalizeDesktopMediaCloseReason(reason)
    const viewerSessionId = this.viewerSessionId
    this.viewerSessionId = null

    this.flushMediaCloseAck(closeReason)

    for (const channel of this.channels.values()) {
      channel.close?.()
    }

    this.clearMediaAckTimer()
    this.pendingMediaAck = null
    this.pendingMediaAckQueue = null
    this.lastMediaAckBinding = null
    this.mediaBackpressurePaused = false
    this.mediaProcessor?.close?.()
    this.channels.clear()
    this.peerConnection?.close?.()
    this.peerConnection = null

    if (viewerSessionId && this.signalingPath) {
      void this.fetchJson(`${this.signalingPath}/${viewerSessionId}`, {
        method: "DELETE",
        body: JSON.stringify({reason: closeReason}),
        keepalive: true,
      }).catch((error) => this.onError(error))
    }
  }

  attachPeerHandlers() {
    this.peerConnection.addEventListener("datachannel", (event) => this.attachDataChannel(event.channel))
    this.peerConnection.addEventListener("track", (event) => {
      if (this.closed) {
        return
      }

      const mediaStream = desktopMediaStreamFromTrackEvent(event)

      if (mediaStream) {
        this.onMediaStream(mediaStream, event)
      }
    })
    this.peerConnection.addEventListener("icecandidate", (event) => {
      if (this.closed || !event.candidate || !this.viewerSessionId) {
        return
      }

      const candidate = event.candidate.toJSON?.() || event.candidate
      if (!isAllowedDesktopIceCandidate(candidate)) {
        this.onStatus("ice_candidate_rejected")
        return
      }

      void this.fetchJson(`${this.signalingPath}/${this.viewerSessionId}/candidates`, {
        method: "POST",
        body: JSON.stringify({candidate}),
      }).catch((error) => this.onError(error))
    })
    this.peerConnection.addEventListener("connectionstatechange", () => {
      const state = this.peerConnection?.connectionState || "unknown"
      this.onStatus(`connection_${state}`)

      if (state === "failed" || state === "closed") {
        if (this.closed) {
          return
        }

        this.close(`desktop peer connection ${state}`)
        this.onClose(state)
      }
    })
  }

  attachDataChannel(channel) {
    const label = normalizeChannelLabel(channel?.label)

    if (!label) {
      channel?.close?.()
      return
    }

    if (label !== DESKTOP_MEDIA_CHANNEL && label !== DESKTOP_CONTROL_CHANNEL) {
      channel.close?.()
      return
    }

    channel.binaryType = "arraybuffer"
    this.channels.set(label, channel)
    channel.addEventListener("open", () => {
      this.onOpen(label)
      if (label === DESKTOP_CONTROL_CHANNEL) {
        this.flushPendingMediaAck()
      }
    })
    channel.addEventListener("close", () => {
      if (!this.closed) {
        this.close(`desktop ${label} channel closed`)
        this.onClose(label)
      }
    })
    channel.addEventListener("error", (event) => {
      if (!this.closed) {
        const error = event?.error || event
        this.close(`desktop ${label} channel failed`)
        this.onError(error)
      }
    })
    channel.addEventListener("message", (event) => this.handleChannelMessage(label, event.data))
  }

  handleChannelMessage(label, data) {
    if (this.closed) {
      return
    }

    if (label === DESKTOP_MEDIA_CHANNEL) {
      let result

      try {
        result = this.mediaProcessor.process(data)
      } catch (error) {
        this.onError(error)
        this.close("desktop media frame processing failed")
        return
      }

      const frame = result.frame

      if (result.dropped) {
        this.onFrameDropped(frame)
        this.queueMediaAck(frame, result.queueState)
        return
      }

      this.onFrame(frame)
      this.queueMediaAck(frame, this.mediaProcessor.queueState())

      return
    }

    if (typeof data === "string") {
      let message

      try {
        message = JSON.parse(data)
      } catch (error) {
        this.onError(error)
        this.close("desktop control frame processing failed")
        return
      }

      this.onControlMessage(message)
    } else {
      this.onControlMessage(data)
    }
  }

  queueMediaAck(frame, queueState = {}) {
    const creditBytes = desktopMediaFrameCreditBytes(frame)
    const backpressureSignal = this.updateMediaBackpressure(queueState)

    if (this.pendingMediaAck && !mediaAckBindingMatches(this.pendingMediaAck, frame)) {
      if (channelReady(this.channels.get(DESKTOP_CONTROL_CHANNEL))) {
        this.flushPendingMediaAck()
      }

      if (this.pendingMediaAck && !mediaAckBindingMatches(this.pendingMediaAck, frame)) {
        this.queueBlockedMediaAck(this.pendingMediaAck)
        this.pendingMediaAck = null
      }
    }

    if (!this.pendingMediaAck) {
      this.pendingMediaAck = newPendingMediaAck(frame)
    }

    appendMediaAck(this.pendingMediaAck, frame, creditBytes)
    this.lastMediaAckBinding = mediaAckBinding(this.pendingMediaAck)

    if (backpressureSignal) {
      applyMediaAckBackpressureSignal(this.pendingMediaAck, backpressureSignal)
      return this.flushPendingMediaAck()
    }

    if (frame.endOfStream) {
      this.pendingMediaAck.close_reason = "desktop media end of stream"
      return this.flushPendingMediaAck()
    }

    if (
      this.pendingMediaAck.credit_bytes >= this.mediaAckCreditBytes ||
      this.pendingMediaAck.frame_count >= this.mediaAckFrameInterval
    ) {
      return this.flushPendingMediaAck()
    }

    this.scheduleMediaAckFlush()
    return false
  }

  flushPendingMediaAck() {
    if (!this.pendingMediaAck && !this.pendingMediaAckQueue) {
      return false
    }

    const channel = this.channels.get(DESKTOP_CONTROL_CHANNEL)

    if (!channelReady(channel)) {
      this.scheduleMediaAckFlush()
      return false
    }

    this.clearMediaAckTimer()
    let sent = false

    if (this.pendingMediaAckQueue) {
      for (const pendingAck of this.pendingMediaAckQueue) {
        this.sendPendingMediaAck(channel, pendingAck)
        sent = true
      }

      this.pendingMediaAckQueue = null
    }

    if (this.pendingMediaAck) {
      this.sendPendingMediaAck(channel, this.pendingMediaAck)
      this.pendingMediaAck = null
      sent = true
    }

    return sent
  }

  sendMediaAck(frame) {
    const ack = {
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: frame.sessionBindingId,
      media_session_id: frame.mediaSessionId,
      last_accepted_seq: frame.sequence,
      credit_bytes: desktopMediaFrameCreditBytes(frame),
    }

    if (frame.endOfStream) {
      ack.close_reason = "desktop media end of stream"
    }

    if (this.sendControl(ack)) {
      this.lastMediaAckBinding = mediaAckBinding(ack)
      this.onAck(ack)
      return true
    }

    return false
  }

  scheduleMediaAckFlush() {
    if (
      this.mediaAckTimer ||
      this.mediaAckMaxDelayMs <= 0 ||
      !channelReady(this.channels.get(DESKTOP_CONTROL_CHANNEL))
    ) {
      return
    }

    this.mediaAckTimer = globalThis.setTimeout(() => {
      this.mediaAckTimer = null
      this.flushPendingMediaAck()
    }, this.mediaAckMaxDelayMs)
  }

  queueBlockedMediaAck(pendingAck) {
    if (this.pendingMediaAckQueue) {
      this.pendingMediaAckQueue.push(pendingAck)
    } else {
      this.pendingMediaAckQueue = [pendingAck]
    }
  }

  flushMediaCloseAck(reason) {
    if (this.pendingMediaAck) {
      this.pendingMediaAck.close_reason = reason
      return this.flushPendingMediaAck()
    }

    if (!this.lastMediaAckBinding) {
      return false
    }

    const ack = {
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: this.lastMediaAckBinding.session_binding_id,
      media_session_id: this.lastMediaAckBinding.media_session_id,
      last_accepted_seq: this.lastMediaAckBinding.last_accepted_seq,
      credit_bytes: 0,
      close_reason: reason,
    }

    if (!this.sendControl(ack)) {
      return false
    }

    this.onAck(ack)
    return true
  }

  updateMediaBackpressure({decodeQueueSize = 0, maxDecodeQueueSize = 0} = {}) {
    if (maxDecodeQueueSize <= 0) {
      return null
    }

    if (!this.mediaBackpressurePaused && decodeQueueSize >= maxDecodeQueueSize) {
      this.mediaBackpressurePaused = true
      return {
        pause: true,
        qualityLevel: DESKTOP_MEDIA_QUALITY_LOW,
      }
    }

    if (this.mediaBackpressurePaused && decodeQueueSize <= Math.floor(maxDecodeQueueSize / 2)) {
      this.mediaBackpressurePaused = false
      return {
        resume: true,
        qualityLevel: DESKTOP_MEDIA_QUALITY_AUTO,
      }
    }

    return null
  }

  sendPendingMediaAck(channel, pendingAck) {
    const ack = mediaAckPayload(pendingAck)
    channel.send(JSON.stringify(ack))
    this.onAck(ack)
  }

  clearMediaAckTimer() {
    if (!this.mediaAckTimer) {
      return
    }

    globalThis.clearTimeout(this.mediaAckTimer)
    this.mediaAckTimer = null
  }

  fetchJson(url, options = {}) {
    return this.fetchImpl(url, {
      credentials: "same-origin",
      headers: csrfHeaders(this.documentRef),
      ...options,
    }).then(jsonResponse)
  }

  assertActiveConnection(generation) {
    if (this.closed || generation !== this.connectGeneration) {
      throw new Error("remote desktop WebRTC connection was closed")
    }
  }

  closeReturnedViewer(viewerSessionId, reason) {
    if (!viewerSessionId || !this.signalingPath) {
      return Promise.resolve()
    }

    return this.fetchJson(`${this.signalingPath}/${viewerSessionId}`, {
      method: "DELETE",
      body: JSON.stringify({reason: normalizeDesktopMediaCloseReason(reason)}),
      keepalive: true,
    }).catch(() => {})
  }
}

function desktopMediaFrameCreditBytes(frame) {
  return byteLength(frame?.metadata) + byteLength(frame?.payload)
}

function newPendingMediaAck(frame) {
  return {
    type: DESKTOP_MEDIA_ACK_MESSAGE,
    session_binding_id: frame.sessionBindingId,
    media_session_id: frame.mediaSessionId,
    last_accepted_seq: frame.sequence,
    credit_bytes: 0,
    frame_count: 0,
  }
}

function mediaAckBindingMatches(ack, frame) {
  return (
    ack.session_binding_id === frame.sessionBindingId && ack.media_session_id === frame.mediaSessionId
  )
}

function appendMediaAck(ack, frame, creditBytes) {
  ack.last_accepted_seq = frame.sequence
  ack.credit_bytes += creditBytes
  ack.frame_count += 1
}

function mediaAckBinding(ack) {
  return {
    session_binding_id: ack.session_binding_id,
    media_session_id: ack.media_session_id,
    last_accepted_seq: ack.last_accepted_seq,
  }
}

function normalizeDesktopMediaCloseReason(reason) {
  const value = typeof reason === "string" ? reason : DEFAULT_DESKTOP_MEDIA_CLOSE_REASON
  const trimmed = value.trim()
  const normalized = trimmed.length > 0 ? trimmed : DEFAULT_DESKTOP_MEDIA_CLOSE_REASON
  const encoded = textEncoder.encode(normalized)

  if (encoded.byteLength <= DESKTOP_MEDIA_MAX_CLOSE_REASON) {
    return normalized
  }

  let truncated = ""
  let usedBytes = 0

  for (const char of normalized) {
    const charBytes = textEncoder.encode(char).byteLength
    if (usedBytes + charBytes > DESKTOP_MEDIA_MAX_CLOSE_REASON) {
      break
    }

    truncated += char
    usedBytes += charBytes
  }

  return truncated
}

function applyMediaAckBackpressureSignal(ack, signal) {
  ack.pause = signal.pause === true
  ack.resume = signal.resume === true
  ack.quality_level = signal.qualityLevel
}

function mediaAckPayload(ack) {
  const payload = {
    type: ack.type,
    session_binding_id: ack.session_binding_id,
    media_session_id: ack.media_session_id,
    last_accepted_seq: ack.last_accepted_seq,
    credit_bytes: ack.credit_bytes,
  }

  if (ack.close_reason) {
    payload.close_reason = ack.close_reason
  }
  if (ack.quality_level) {
    payload.quality_level = ack.quality_level
  }
  if (ack.pause) {
    payload.pause = true
  }
  if (ack.resume) {
    payload.resume = true
  }

  return payload
}

function mediaSections(sdp) {
  const sections = []
  let current = null

  for (const rawLine of sdp.split(/\r?\n/)) {
    const line = rawLine.trim()

    if (line.startsWith("m=")) {
      const mediaType = line.slice(2).split(/\s+/)[0]?.toLowerCase() || ""
      current = {mediaType, lines: [line]}
      sections.push(current)
    } else if (current && line) {
      current.lines.push(line)
    }
  }

  return sections
}

function validateVideoMediaSection(section) {
  const codecs = section.lines
    .map((line) => line.match(/^a=rtpmap:\d+\s+([^/\s]+)/i)?.[1]?.toLowerCase())
    .filter(Boolean)

  if (codecs.length === 0) {
    throw new Error("remote desktop WebRTC video offer has no codec map")
  }

  const unsupported = codecs.filter(
    (codec) => !ALLOWED_SDP_VIDEO_CODECS.has(codec) && !ALLOWED_SDP_VIDEO_REPAIR_CODECS.has(codec)
  )

  if (unsupported.length > 0) {
    throw new Error(`remote desktop WebRTC video codec is not allowed: ${unsupported[0]}`)
  }

  if (!codecs.some((codec) => ALLOWED_SDP_VIDEO_CODECS.has(codec))) {
    throw new Error("remote desktop WebRTC video offer has no supported primary codec")
  }
}

function candidateAddress(candidateText) {
  const normalized = candidateText.trim().replace(/^a=/, "")
  const parts = normalized.split(/\s+/)

  if (!parts[0]?.startsWith("candidate:") || parts.length < 6) {
    return null
  }

  return parts[4]?.toLowerCase() || null
}

function isIPv4Address(address) {
  const octets = address.split(".")
  return octets.length === 4 && octets.every((part) => /^\d+$/.test(part) && Number(part) >= 0 && Number(part) <= 255)
}

function isBlockedIPv4(address) {
  const [a, b] = address.split(".").map((part) => Number(part))

  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a >= 224 && a <= 255)
  )
}

function isBlockedIPv6(address) {
  const normalized = address.toLowerCase()

  if (normalized.startsWith("::ffff:")) {
    const mapped = normalized.slice("::ffff:".length)
    return isIPv4Address(mapped) ? isBlockedIPv4(mapped) : true
  }

  return (
    normalized === "::1" ||
    normalized.startsWith("fe80:") ||
    normalized.startsWith("fc") ||
    normalized.startsWith("fd") ||
    normalized.startsWith("ff")
  )
}

function byteLength(value) {
  return value?.byteLength || 0
}
