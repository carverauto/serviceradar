import {
  CAMERA_RELAY_MSE_TRANSPORT,
  CAMERA_RELAY_WEBCODECS_TRANSPORT,
  CameraRelayCanvasPlayer,
  CameraRelayMsePlayer,
  detectBrowserPlaybackCapabilities,
  playbackTransportLabel,
  selectRelayPlaybackTransport,
} from "../lib/camera_relay/player"

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
  return {
    preferred_playback_transport: root.dataset.preferredPlaybackTransport,
    available_playback_transports: parseTransportList(root.dataset.availablePlaybackTransports),
    playback_codec_hint: root.dataset.playbackCodecHint,
    playback_container_hint: root.dataset.playbackContainerHint,
  }
}

function playbackMetadataFromSnapshot(payload, previous) {
  return {
    preferred_playback_transport:
      payload.preferred_playback_transport || previous?.preferred_playback_transport || null,
    available_playback_transports:
      payload.available_playback_transports || previous?.available_playback_transports || [],
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
    this.socket = null
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

    if (!this.streamPath) {
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

    this.player = this.buildPlayer()

    this.connect()
  },

  destroyed() {
    if (this.socket) {
      this.socket.close()
      this.socket = null
    }

    if (this.player) {
      this.player.close()
      this.player = null
    }
  },

  connect() {
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

      let payload = null

      try {
        payload = JSON.parse(event.data)
      } catch (_error) {
        setText(this.el, "transport-status", "Browser stream sent invalid payload")
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
    })
  },

  buildPlayer() {
    this.setSurfaceVisibility(this.transportSelection.selectedTransport)

    switch (this.transportSelection.selectedTransport) {
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
      canvas.classList.toggle("hidden", transport === CAMERA_RELAY_MSE_TRANSPORT || transport == null)
    }

    if (video) {
      video.classList.toggle("hidden", transport !== CAMERA_RELAY_MSE_TRANSPORT)
    }
  },
}
