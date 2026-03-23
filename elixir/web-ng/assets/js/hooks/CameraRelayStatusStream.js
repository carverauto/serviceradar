import {CameraRelayCanvasPlayer} from "../lib/camera_relay/player"

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
    this.player = new CameraRelayCanvasPlayer({
      canvas: this.el.querySelector("[data-role='video-canvas']"),
      setStatus: (value) => setText(this.el, "player-status", value),
    })

    if (!this.streamPath) {
      setText(this.el, "transport-status", "Browser stream unavailable")
      return
    }

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
    setText(this.el, "transport-status", "Connecting browser stream…")

    this.socket = new WebSocket(websocketUrl(this.streamPath))
    this.socket.binaryType = "arraybuffer"

    this.socket.addEventListener("open", () => {
      setText(this.el, "transport-status", "Browser stream connected")
    })

    this.socket.addEventListener("close", () => {
      setText(this.el, "transport-status", "Browser stream closed")
    })

    this.socket.addEventListener("error", () => {
      setText(this.el, "transport-status", "Browser stream error")
    })

    this.socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") {
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

      const termination = terminationLabel(payload.termination_kind)

      setText(this.el, "relay-status", `Relay status: ${payload.status}`)
      setText(this.el, "playback-state", `Playback state: ${payload.playback_state}`)
      setText(this.el, "viewer-count", `Viewer count: ${payload.viewer_count ?? 0}`)
      setText(this.el, "termination-kind", termination ? `Termination: ${termination}` : "")
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
}
