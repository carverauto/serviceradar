import {
  CAMERA_RELAY_WEBRTC_TRANSPORT,
  CAMERA_RELAY_MSE_TRANSPORT,
  CAMERA_RELAY_WEBCODECS_TRANSPORT,
  CameraRelayCanvasPlayer,
  CameraRelayMsePlayer,
  detectBrowserPlaybackCapabilities,
  playbackTransportLabel,
  selectRelayPlaybackTransport,
} from "../lib/camera_relay/player"

const WEBRTC_CREATE_RETRY_DELAY_MS = 500
const WEBRTC_CREATE_MAX_ATTEMPTS = 10

function setText(root, role, value) {
  const element = root.querySelector(`[data-role="${role}"]`)
  if (element) {
    element.textContent = value
  }
}

function setDataset(root, role, value) {
  const element = root.querySelector(`[data-role="${role}"]`)
  if (element) {
    element.dataset.state = value
  }
}

function websocketUrl(path) {
  const url = new URL(path, window.location.href)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  return url.toString()
}

function parseTransportList(value) {
  if (typeof value !== "string") {
    return []
  }

  return value
    .split(",")
    .map((transport) => transport.trim())
    .filter((transport) => transport.length > 0)
}

function playbackMetadataFromDataset(root) {
  const availablePlaybackTransports = parseTransportList(root.dataset.availablePlaybackTransports)
  const webrtcTransport = root.dataset.webrtcPlaybackTransport

  if (webrtcTransport && !availablePlaybackTransports.includes(webrtcTransport)) {
    availablePlaybackTransports.unshift(webrtcTransport)
  }

  return {
    preferred_playback_transport: webrtcTransport || root.dataset.preferredPlaybackTransport,
    available_playback_transports: availablePlaybackTransports,
    playback_codec_hint: root.dataset.playbackCodecHint,
    playback_container_hint: root.dataset.playbackContainerHint,
  }
}

function playbackMetadataFromSnapshot(payload, previous) {
  const snapshotTransports = payload.available_playback_transports || previous?.available_playback_transports || []
  const webrtcTransport = payload.webrtc_playback_transport || previous?.webrtc_playback_transport || null
  const availablePlaybackTransports = Array.isArray(snapshotTransports) ? [...snapshotTransports] : []

  if (webrtcTransport && !availablePlaybackTransports.includes(webrtcTransport)) {
    availablePlaybackTransports.unshift(webrtcTransport)
  }

  return {
    preferred_playback_transport:
      payload.webrtc_playback_transport ||
      payload.preferred_playback_transport ||
      previous?.preferred_playback_transport ||
      null,
    available_playback_transports: availablePlaybackTransports,
    webrtc_playback_transport: webrtcTransport,
    playback_codec_hint: payload.playback_codec_hint || previous?.playback_codec_hint || "h264",
    playback_container_hint:
      payload.playback_container_hint || previous?.playback_container_hint || "annexb",
  }
}

function compatibilityStatus(selection, playbackMetadata) {
  if (!selection?.supported) {
    const missing = selection?.missingCapabilities?.join(", ") || "browser media support"
    return `Unsupported browser transport for ${playbackMetadata?.playback_codec_hint || "camera"} playback (${missing})`
  }

  return `Browser playback transport: ${playbackTransportLabel(selection.selectedTransport)}`
}

function parseJsonDataset(value, fallback) {
  if (typeof value !== "string" || value.trim() === "") {
    return fallback
  }

  try {
    return JSON.parse(value)
  } catch (_error) {
    return fallback
  }
}

function jsonHeaders() {
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

  return {
    Accept: "application/json",
    "Content-Type": "application/json",
    ...(csrfToken ? {"x-csrf-token": csrfToken} : {}),
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function terminationLabel(kind) {
  switch (kind) {
    case "failure":
      return "Failure"
    case "viewer_idle":
      return "Viewer idle stop"
    case "transport_drain":
      return "Transport drain"
    case "manual_stop":
      return "Manual stop"
    case "source_complete":
      return "Source complete"
    case "closed":
      return "Closed"
    default:
      return ""
  }
}

export default {
  mounted() {
    this.streamPath = this.el.dataset.streamPath
    this.webrtcSignalingPath = this.el.dataset.webrtcSignalingPath
    this.webrtcIceServers = parseJsonDataset(this.el.dataset.webrtcIceServers, [])
    this.socket = null
    this.statusSocket = null
    this.peerConnection = null
    this.webrtcViewerSessionId = null
    this.chunkCount = 0
    this.byteCount = 0
    this.receivedRelaySnapshot = false
    this.receivedMediaChunk = false
    this.playbackMetadata = playbackMetadataFromDataset(this.el)
    this.transportSelection = selectRelayPlaybackTransport(
      this.playbackMetadata,
      detectBrowserPlaybackCapabilities(window)
    )
    this.player = null

    setText(this.el, "compatibility-status", compatibilityStatus(this.transportSelection, this.playbackMetadata))

    if (!this.streamPath && !this.webrtcSignalingPath) {
      setText(this.el, "transport-status", "Browser stream unavailable")
      return
    }

    if (!this.transportSelection.supported) {
      this.setSurfaceVisibility(null)
      setText(this.el, "transport-status", "Browser playback unsupported")
      setText(this.el, "player-status", "This browser cannot decode the current relay transport.")
      setText(
        this.el,
        "relay-detail",
        "This viewer requires a supported relay playback transport. The current relay path needs either WebCodecs or an MSE-capable H264 browser."
      )
      return
    }

    if (this.transportSelection.selectedTransport === CAMERA_RELAY_WEBRTC_TRANSPORT) {
      this.setSurfaceVisibility(CAMERA_RELAY_WEBRTC_TRANSPORT)
      this.connectStatusWebsocket()
      this.connectWebRtc()
      return
    }

    this.player = this.buildPlayer()
    this.connectWebsocket()
  },

  destroyed() {
    if (this.socket) {
      this.socket.close()
      this.socket = null
    }

    if (this.statusSocket) {
      this.statusSocket.close()
      this.statusSocket = null
    }

    if (this.player) {
      this.player.close()
      this.player = null
    }

    this.destroyWebRtc()
  },

  connectWebsocket() {
    setText(
      this.el,
      "transport-status",
      `Connecting browser stream via ${playbackTransportLabel(this.transportSelection.selectedTransport)}...`
    )

    this.socket = new WebSocket(websocketUrl(this.streamPath))
    this.socket.binaryType = "arraybuffer"

    this.socket.addEventListener("open", () => {
      setText(
        this.el,
        "transport-status",
        `Browser stream connected via ${playbackTransportLabel(this.transportSelection.selectedTransport)}`
      )
    })

    this.socket.addEventListener("close", () => {
      if (!this.receivedRelaySnapshot && !this.receivedMediaChunk) {
        setText(this.el, "transport-status", "Browser stream unavailable or unauthorized")
        setText(
          this.el,
          "relay-detail",
          "The browser viewer could not attach to this relay session. Check viewer permissions and relay session state."
        )
      } else {
        setText(this.el, "transport-status", "Browser stream closed")
      }
    })

    this.socket.addEventListener("error", () => {
      setText(this.el, "transport-status", "Browser stream error")

      if (!this.receivedRelaySnapshot && !this.receivedMediaChunk) {
        setText(
          this.el,
          "relay-detail",
          "The browser viewer failed before media attach. The relay may be unavailable or this viewer may not be authorized."
        )
      }
    })

    this.socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") {
        this.receivedMediaChunk = true
        const bytes = event.data?.byteLength || event.data?.size || 0
        this.chunkCount += 1
        this.byteCount += bytes

        let playerResult = null

        try {
          playerResult = this.player ? this.player.consume(event.data) : null
        } catch (error) {
          setText(this.el, "player-status", `Browser playback error: ${error.message}`)
        }

        setText(
          this.el,
          "transport-status",
          playerResult?.decoded ? "Browser stream decoding live media" : "Browser stream receiving media chunks"
        )
        setText(this.el, "binary-stats", `Chunks: ${this.chunkCount}  Bytes: ${this.byteCount}`)
        return
      }

      this.handleSnapshotMessage(event.data)
    })
  },

  connectStatusWebsocket() {
    if (!this.streamPath) {
      return
    }

    this.statusSocket = new WebSocket(websocketUrl(this.streamPath))

    this.statusSocket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") {
        return
      }

      this.handleSnapshotMessage(event.data)
    })

    this.statusSocket.addEventListener("error", () => {
      if (!this.receivedRelaySnapshot) {
        setText(this.el, "relay-detail", "Waiting for relay state updates from core.")
      }
    })
  },

  async connectWebRtc() {
    if (!this.webrtcSignalingPath) {
      this.useWebsocketFallback("WebRTC signaling unavailable for this relay session")
      return
    }

    if (typeof window.RTCPeerConnection !== "function") {
      this.useWebsocketFallback("This browser cannot create a WebRTC peer connection")
      return
    }

    setText(this.el, "transport-status", "Creating WebRTC viewer session...")
    setText(this.el, "player-status", "Waiting for WebRTC offer...")

    try {
      const createBody = await this.createWebRtcViewerSession()

      const session = createBody?.data || {}
      const viewerSessionId = session.viewer_session_id
      const offerSdp = session.offer_sdp

      if (!viewerSessionId || !offerSdp) {
        throw new Error("WebRTC offer was not returned for this relay session")
      }

      this.webrtcViewerSessionId = viewerSessionId
      this.peerConnection = new window.RTCPeerConnection({
        iceServers: session.ice_servers || this.webrtcIceServers || [],
      })

      this.peerConnection.addEventListener("track", (event) => {
        const video = this.el.querySelector("[data-role='video-element']")

        if (video && event.streams?.[0]) {
          video.srcObject = event.streams[0]
          video.play?.().catch(() => {})
        }

        setText(this.el, "player-status", "WebRTC media track attached")
      })

      this.peerConnection.addEventListener("connectionstatechange", () => {
        const connectionState = this.peerConnection?.connectionState || "unknown"
        setText(this.el, "transport-status", `WebRTC connection state: ${connectionState}`)

        if (connectionState === "connected") {
          setText(this.el, "player-status", "WebRTC relay connected")
        }

        if (connectionState === "failed" || connectionState === "disconnected") {
          this.useWebsocketFallback(`WebRTC ${connectionState}; falling back to websocket viewer`)
        }
      })

      this.peerConnection.addEventListener("icecandidate", (event) => {
        if (!event.candidate || !this.webrtcViewerSessionId) {
          return
        }

        void fetch(`${this.webrtcSignalingPath}/${this.webrtcViewerSessionId}/candidates`, {
          method: "POST",
          headers: jsonHeaders(),
          credentials: "same-origin",
          body: JSON.stringify({candidate: event.candidate.toJSON()}),
        })
      })

      await this.peerConnection.setRemoteDescription({type: "offer", sdp: offerSdp})
      const answer = await this.peerConnection.createAnswer()
      await this.peerConnection.setLocalDescription(answer)

      const answerResponse = await fetch(
        `${this.webrtcSignalingPath}/${this.webrtcViewerSessionId}/answer`,
        {
          method: "POST",
          headers: jsonHeaders(),
          credentials: "same-origin",
          body: JSON.stringify({sdp: answer.sdp}),
        }
      )

      const answerBody = await answerResponse.json()

      if (!answerResponse.ok) {
        throw new Error(answerBody?.message || "WebRTC answer was rejected")
      }

      setText(this.el, "transport-status", "WebRTC answer applied")
      setText(this.el, "player-status", "Waiting for WebRTC media...")
    } catch (error) {
      this.useWebsocketFallback(error.message || "WebRTC viewer setup failed")
    }
  },

  async createWebRtcViewerSession() {
    let lastError = null

    for (let attempt = 1; attempt <= WEBRTC_CREATE_MAX_ATTEMPTS; attempt += 1) {
      const createResponse = await fetch(this.webrtcSignalingPath, {
        method: "POST",
        headers: jsonHeaders(),
        credentials: "same-origin",
      })

      const createBody = await createResponse.json()

      if (createResponse.ok) {
        return createBody
      }

      const retryableNotReady =
        attempt < WEBRTC_CREATE_MAX_ATTEMPTS &&
        ((createResponse.status === 404 && createBody?.error === "relay_session_not_found") ||
          (createResponse.status === 409 && createBody?.error === "relay_session_activating"))

      if (!retryableNotReady) {
        throw new Error(createBody?.message || "WebRTC viewer session could not be created")
      }

      lastError = createBody?.message || "relay session is still activating"
      setText(this.el, "transport-status", "Waiting for relay activation...")
      setText(this.el, "player-status", lastError)
      await sleep(WEBRTC_CREATE_RETRY_DELAY_MS)
      setText(this.el, "transport-status", "Creating WebRTC viewer session...")
      setText(this.el, "player-status", "Waiting for WebRTC offer...")
    }

    throw new Error(lastError || "WebRTC viewer session could not be created")
  },

  destroyWebRtc() {
    const viewerSessionId = this.webrtcViewerSessionId

    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }

    this.webrtcViewerSessionId = null

    if (viewerSessionId && this.webrtcSignalingPath) {
      void fetch(`${this.webrtcSignalingPath}/${viewerSessionId}`, {
        method: "DELETE",
        headers: jsonHeaders(),
        credentials: "same-origin",
        keepalive: true,
      })
    }
  },

  useWebsocketFallback(reason) {
    if (this.statusSocket) {
      this.statusSocket.close()
      this.statusSocket = null
    }

    const fallbackSelection = selectRelayPlaybackTransport(
      {
        ...this.playbackMetadata,
        preferred_playback_transport: CAMERA_RELAY_WEBCODECS_TRANSPORT,
        available_playback_transports: (this.playbackMetadata.available_playback_transports || []).filter(
          (transport) => transport !== CAMERA_RELAY_WEBRTC_TRANSPORT
        ),
      },
      detectBrowserPlaybackCapabilities(window)
    )

    if (!fallbackSelection.supported || !this.streamPath) {
      setText(this.el, "transport-status", "WebRTC viewer unavailable")
      setText(this.el, "player-status", reason)
      return
    }

    this.destroyWebRtc()
    this.transportSelection = fallbackSelection
    this.player = this.buildPlayer()
    setText(this.el, "player-status", reason)
    setText(this.el, "compatibility-status", compatibilityStatus(this.transportSelection, this.playbackMetadata))
    this.connectWebsocket()
  },

  handleSnapshotMessage(data) {
    let payload = null

    try {
      payload = JSON.parse(data)
    } catch (_error) {
      if (this.socket) {
        setText(this.el, "transport-status", "Browser stream sent invalid payload")
      }

      return
    }

    if (payload.type !== "camera_relay_snapshot") {
      return
    }

    this.playbackMetadata = playbackMetadataFromSnapshot(payload, this.playbackMetadata)
    setText(this.el, "compatibility-status", compatibilityStatus(this.transportSelection, this.playbackMetadata))
    this.receivedRelaySnapshot = true
    const termination = terminationLabel(payload.termination_kind)

    setText(this.el, "relay-status", `Relay status: ${payload.status}`)
    setText(this.el, "playback-state", `Playback state: ${payload.playback_state}`)
    setText(this.el, "viewer-count", `Viewer count: ${payload.viewer_count ?? 0}`)
    setText(this.el, "termination-kind", termination ? `Termination: ${termination}` : "")
    setText(this.el, "failure-reason", payload.failure_reason ? `Failure reason: ${payload.failure_reason}` : "")
    setText(this.el, "close-reason", payload.close_reason ? `Close reason: ${payload.close_reason}` : "")
    setText(
      this.el,
      "relay-detail",
      payload.media_ingest_id
        ? `Ingress ${payload.media_ingest_id} is attached and browser playback is bound to this relay session.`
        : "Waiting for core ingest to activate the relay session."
    )
    setDataset(this.el, "playback-state", payload.playback_state)
  },

  buildPlayer() {
    this.setSurfaceVisibility(this.transportSelection.selectedTransport)

    switch (this.transportSelection.selectedTransport) {
      case CAMERA_RELAY_WEBRTC_TRANSPORT:
        return null
      case CAMERA_RELAY_WEBCODECS_TRANSPORT:
        return new CameraRelayCanvasPlayer({
          canvas: this.el.querySelector("[data-role='video-canvas']"),
          setStatus: (value) => setText(this.el, "player-status", value),
        })

      case CAMERA_RELAY_MSE_TRANSPORT:
        return new CameraRelayMsePlayer({
          video: this.el.querySelector("[data-role='video-element']"),
          setStatus: (value) => setText(this.el, "player-status", value),
        })

      default:
        return null
    }
  },

  setSurfaceVisibility(transport) {
    const canvas = this.el.querySelector("[data-role='video-canvas']")
    const video = this.el.querySelector("[data-role='video-element']")

    if (canvas) {
      canvas.classList.toggle(
        "hidden",
        transport === CAMERA_RELAY_MSE_TRANSPORT ||
          transport === CAMERA_RELAY_WEBRTC_TRANSPORT ||
          transport == null
      )
    }

    if (video) {
      video.classList.toggle(
        "hidden",
        transport !== CAMERA_RELAY_MSE_TRANSPORT && transport !== CAMERA_RELAY_WEBRTC_TRANSPORT
      )
    }
  },
}
