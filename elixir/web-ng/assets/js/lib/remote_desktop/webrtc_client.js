import {createDesktopMediaFrameParser, shouldDropStaleDesktopFrame} from "./media_frame"

export const DESKTOP_MEDIA_CHANNEL = "desktop-media"
export const DESKTOP_CONTROL_CHANNEL = "desktop-control"
export const DESKTOP_MEDIA_ACK_MESSAGE = "desktop_media_ack"
export const DESKTOP_MEDIA_QUALITY_LOW = "low"
export const DESKTOP_MEDIA_QUALITY_AUTO = "auto"

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

export class RemoteDesktopWebRTCClient {
  constructor({
    signalingPath,
    iceServers = [],
    fetchImpl = globalThis.fetch,
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
    mediaAckCreditBytes = 262_144,
    mediaAckFrameInterval = 4,
    mediaAckMaxDelayMs = 25,
    mediaQueueState = () => ({}),
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
    this.mediaAckCreditBytes = Math.max(1, mediaAckCreditBytes)
    this.mediaAckFrameInterval = Math.max(1, mediaAckFrameInterval)
    this.mediaAckMaxDelayMs = Math.max(0, mediaAckMaxDelayMs)
    this.mediaQueueState = typeof mediaQueueState === "function" ? mediaQueueState : () => ({})
    this.mediaFrameParser = createDesktopMediaFrameParser()
    this.peerConnection = null
    this.viewerSessionId = null
    this.channels = new Map()
    this.closed = false
    this.pendingMediaAck = null
    this.pendingMediaAckQueue = null
    this.lastMediaAckBinding = null
    this.mediaAckTimer = null
    this.mediaBackpressurePaused = false
  }

  async connect() {
    if (!this.signalingPath) {
      throw new Error("remote desktop WebRTC signaling path is required")
    }

    this.closed = false
    this.onStatus("creating_viewer_session")

    const sessionBody = await this.fetchJson(this.signalingPath, {method: "POST"})
    const session = sessionBody?.data || {}
    const viewerSessionId = session.viewer_session_id
    const offerSdp = session.offer_sdp

    if (!viewerSessionId || !offerSdp) {
      throw new Error("remote desktop WebRTC offer was not returned")
    }

    this.viewerSessionId = viewerSessionId
    this.peerConnection = this.peerConnectionFactory({
      iceServers: session.ice_servers || this.iceServers || [],
    })
    this.attachPeerHandlers()

    await this.peerConnection.setRemoteDescription({type: "offer", sdp: offerSdp})
    const answer = await this.peerConnection.createAnswer()
    await this.peerConnection.setLocalDescription(answer)

    await this.fetchJson(`${this.signalingPath}/${viewerSessionId}/answer`, {
      method: "POST",
      body: JSON.stringify({sdp: answer.sdp}),
    })

    this.onStatus("answer_applied")

    return {
      viewerSessionId,
      transport: session.transport,
      expiresAt: session.expires_at,
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

  close(reason = "viewer closed remote desktop WebRTC session") {
    if (this.closed) {
      return
    }

    this.closed = true
    const viewerSessionId = this.viewerSessionId
    this.viewerSessionId = null

    this.flushMediaCloseAck(reason)

    for (const channel of this.channels.values()) {
      channel.close?.()
    }

    this.clearMediaAckTimer()
    this.pendingMediaAck = null
    this.pendingMediaAckQueue = null
    this.lastMediaAckBinding = null
    this.mediaBackpressurePaused = false
    this.channels.clear()
    this.peerConnection?.close?.()
    this.peerConnection = null

    if (viewerSessionId && this.signalingPath) {
      void this.fetchJson(`${this.signalingPath}/${viewerSessionId}`, {
        method: "DELETE",
        body: JSON.stringify({reason}),
        keepalive: true,
      }).catch((error) => this.onError(error))
    }
  }

  attachPeerHandlers() {
    this.peerConnection.addEventListener("datachannel", (event) => this.attachDataChannel(event.channel))
    this.peerConnection.addEventListener("icecandidate", (event) => {
      if (!event.candidate || !this.viewerSessionId) {
        return
      }

      void this.fetchJson(`${this.signalingPath}/${this.viewerSessionId}/candidates`, {
        method: "POST",
        body: JSON.stringify({candidate: event.candidate.toJSON?.() || event.candidate}),
      }).catch((error) => this.onError(error))
    })
    this.peerConnection.addEventListener("connectionstatechange", () => {
      const state = this.peerConnection?.connectionState || "unknown"
      this.onStatus(`connection_${state}`)

      if (state === "failed" || state === "closed") {
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
    channel.addEventListener("close", () => this.onClose(label))
    channel.addEventListener("error", (event) => this.onError(event?.error || event))
    channel.addEventListener("message", (event) => this.handleChannelMessage(label, event.data))
  }

  handleChannelMessage(label, data) {
    if (label === DESKTOP_MEDIA_CHANNEL) {
      const frame = this.mediaFrameParser(data)
      const queueState = this.mediaQueueState()

      if (shouldDropStaleDesktopFrame(frame, queueState)) {
        this.onFrameDropped(frame)
        this.queueMediaAck(frame, queueState)
        return
      }

      this.onFrame(frame)
      this.queueMediaAck(frame, queueState)

      return
    }

    if (typeof data === "string") {
      this.onControlMessage(JSON.parse(data))
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

    if (!this.mediaBackpressurePaused && decodeQueueSize > maxDecodeQueueSize) {
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

function byteLength(value) {
  return value?.byteLength || 0
}
