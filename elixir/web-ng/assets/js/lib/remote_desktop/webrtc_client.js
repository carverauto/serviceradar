import {parseDesktopMediaFrame, parseDesktopMediaMetadata, shouldDropStaleDesktopFrame} from "./media_frame"

export const DESKTOP_MEDIA_CHANNEL = "desktop-media"
export const DESKTOP_CONTROL_CHANNEL = "desktop-control"
export const DESKTOP_MEDIA_ACK_MESSAGE = "desktop_media_ack"

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
    eagerMediaMetadata = true,
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
    this.eagerMediaMetadata = eagerMediaMetadata !== false
    this.peerConnection = null
    this.viewerSessionId = null
    this.channels = new Map()
    this.closed = false
    this.pendingMediaAck = null
    this.mediaAckTimer = null
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

    for (const channel of this.channels.values()) {
      channel.close?.()
    }

    this.clearMediaAckTimer()
    this.pendingMediaAck = null
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
      const frame = parseDesktopMediaFrame(data)

      if (shouldDropStaleDesktopFrame(frame, this.mediaQueueState())) {
        this.onFrameDropped(frame)
        this.queueMediaAck(frame)
        return
      }

      this.onFrame(frame, this.eagerMediaMetadata ? parseDesktopMediaMetadata(frame) : null)
      this.queueMediaAck(frame)

      return
    }

    if (typeof data === "string") {
      this.onControlMessage(JSON.parse(data))
    } else {
      this.onControlMessage(data)
    }
  }

  queueMediaAck(frame) {
    const creditBytes = desktopMediaFrameCreditBytes(frame)

    if (
      this.pendingMediaAck &&
      (this.pendingMediaAck.session_binding_id !== frame.sessionBindingId ||
        this.pendingMediaAck.media_session_id !== frame.mediaSessionId)
    ) {
      this.flushPendingMediaAck()
    }

    if (!this.pendingMediaAck) {
      this.pendingMediaAck = {
        type: DESKTOP_MEDIA_ACK_MESSAGE,
        session_binding_id: frame.sessionBindingId,
        media_session_id: frame.mediaSessionId,
        last_accepted_seq: frame.sequence,
        credit_bytes: 0,
        frame_count: 0,
      }
    }

    this.pendingMediaAck.last_accepted_seq = frame.sequence
    this.pendingMediaAck.credit_bytes += creditBytes
    this.pendingMediaAck.frame_count += 1

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
    if (!this.pendingMediaAck) {
      return false
    }

    this.clearMediaAckTimer()
    const {frame_count: _frameCount, ...ack} = this.pendingMediaAck

    if (!this.sendControl(ack)) {
      this.scheduleMediaAckFlush()
      return false
    }

    this.pendingMediaAck = null
    this.onAck(ack)
    return true
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

function byteLength(value) {
  return value?.byteLength || 0
}
