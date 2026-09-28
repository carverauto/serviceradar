import {CAMERA_RELAY_MSE_TRANSPORT, CAMERA_RELAY_WEBRTC_TRANSPORT} from "../lib/camera_relay/player"
import {CameraRelayViewer, playbackMetadataFromDataset} from "../lib/camera_relay/viewer"

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

export default {
  mounted() {
    this.viewer = new CameraRelayViewer({
      streamPath: this.el.dataset.streamPath,
      webrtcSignalingPath: this.el.dataset.webrtcSignalingPath,
      iceServers: parseJsonDataset(this.el.dataset.webrtcIceServers, []),
      playbackMetadata: playbackMetadataFromDataset(this.el.dataset),
      getCanvas: () => this.el.querySelector("[data-role='video-canvas']"),
      getVideo: () => this.el.querySelector("[data-role='video-element']"),
      report: (role, value) => setText(this.el, role, value),
      reportState: (role, value) => setDataset(this.el, role, value),
      setSurfaceVisibility: (transport) => this.setSurfaceVisibility(transport),
    })

    this.viewer.start()
  },

  destroyed() {
    if (this.viewer) {
      this.viewer.close()
      this.viewer = null
    }
  },

  setSurfaceVisibility(transport) {
    const canvas = this.el.querySelector("[data-role='video-canvas']")
    const video = this.el.querySelector("[data-role='video-element']")

    if (canvas) {
      canvas.classList.toggle(
        "hidden",
        transport === CAMERA_RELAY_MSE_TRANSPORT || transport === CAMERA_RELAY_WEBRTC_TRANSPORT || transport == null
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
