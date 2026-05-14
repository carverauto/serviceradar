import {parseDesktopMediaFrame, parseDesktopMediaMetadata} from "./media_frame"

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
    onControlMessage = () => {},
    onAck = () => {},
    onOpen = () => {},
    onClose = () => {},
    onError = () => {},
    mediaAckCreditBytes = 262_144,
  } = {}) {
    this.signalingPath = signalingPath
    this.iceServers = iceServers
    this.fetchImpl = fetchImpl
    this.peerConnectionFactory = peerConnectionFactory
    this.documentRef = documentRef
    this.onStatus = onStatus
    this.onFrame = onFrame
    this.onControlMessage = onControlMessage
    this.onAck = onAck
    this.onOpen = onOpen
    this.onClose = onClose
    this.onError = onError
    this.mediaAckCreditBytes = mediaAckCreditBytes
    this.peerConnection = null
    this.viewerSessionId = null
    this.channels = new Map()
    this.closed = false
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
    channel.addEventListener("open", () => this.onOpen(label))
    channel.addEventListener("close", () => this.onClose(label))
    channel.addEventListener("error", (event) => this.onError(event?.error || event))
    channel.addEventListener("message", (event) => this.handleChannelMessage(label, event.data))
  }

  handleChannelMessage(label, data) {
    if (label === DESKTOP_MEDIA_CHANNEL) {
      const frame = parseDesktopMediaFrame(data)
      const metadata = parseDesktopMediaMetadata(frame)

      this.onFrame(frame, metadata)
      this.sendMediaAck(frame)

      return
    }

    if (typeof data === "string") {
      this.onControlMessage(JSON.parse(data))
    } else {
      this.onControlMessage(data)
    }
  }

  sendMediaAck(frame) {
    const ack = {
      type: DESKTOP_MEDIA_ACK_MESSAGE,
      session_binding_id: frame.sessionBindingId,
      media_session_id: frame.mediaSessionId,
      last_accepted_seq: frame.sequence,
      credit_bytes: this.mediaAckCreditBytes,
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

  fetchJson(url, options = {}) {
    return this.fetchImpl(url, {
      credentials: "same-origin",
      headers: csrfHeaders(this.documentRef),
      ...options,
    }).then(jsonResponse)
  }
}
