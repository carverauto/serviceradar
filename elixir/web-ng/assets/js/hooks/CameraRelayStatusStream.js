import {CAMERA_RELAY_MSE_TRANSPORT, CAMERA_RELAY_WEBRTC_TRANSPORT} from "../lib/camera_relay/player"
import {CAMERA_VIEWER_STATES, CameraRelayViewer, playbackMetadataFromDataset} from "../lib/camera_relay/viewer"

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
    const supportsLiveViewEvents = typeof this.handleEvent === "function"
    const supportsPushEvent = typeof this.pushEvent === "function"
    const useLiveViewSignaling =
      this.el.dataset.liveviewWebrtcSignaling === "true" && supportsPushEvent
    this.notifyViewerReady = this.el.dataset.notifyViewerReady === "true" && supportsPushEvent
    this.notifiedViewerReady = false

    const sendWebRtcAnswer = useLiveViewSignaling
      ? ({relaySessionId, viewerSessionId, sdp}) =>
          new Promise((resolve, reject) => {
            this.pushEvent(
              "camera_webrtc_answer",
              {
                relay_session_id: relaySessionId,
                viewer_session_id: viewerSessionId,
                sdp,
              },
              (reply) => {
                if (reply?.ok) {
                  resolve(reply)
                } else {
                  reject(new Error(reply?.message || "WebRTC answer was rejected"))
                }
              }
            )
          })
      : null

    const sendWebRtcCandidates = useLiveViewSignaling
      ? ({relaySessionId, viewerSessionId, candidates}) => {
          this.pushEvent("camera_webrtc_candidates", {
            relay_session_id: relaySessionId,
            viewer_session_id: viewerSessionId,
            candidates,
          })
        }
      : null

    this.viewer = new CameraRelayViewer({
      relaySessionId: this.el.dataset.relaySessionId || null,
      streamPath: this.el.dataset.streamPath,
      webrtcSignalingPath: this.el.dataset.webrtcSignalingPath,
      iceServers: parseJsonDataset(this.el.dataset.webrtcIceServers, []),
      playbackMetadata: playbackMetadataFromDataset(this.el.dataset),
      awaitPreloadedWebRtcOffer: supportsLiveViewEvents,
      sendWebRtcAnswer,
      sendWebRtcCandidates,
      getCanvas: () => this.el.querySelector("[data-role='video-canvas']"),
      getVideo: () => this.el.querySelector("[data-role='video-element']"),
      report: (role, value) => setText(this.el, role, value),
      reportState: (role, value) => setDataset(this.el, role, value),
      setSurfaceVisibility: (transport) => this.setSurfaceVisibility(transport),
      onStateChange: (state) => this.handleViewerStateChange(state),
    })

    if (supportsLiveViewEvents) {
      this.handleEvent("camera-relay:webrtc-offer", (payload) => {
        if (!this.viewer || !payload?.data) return
        if (payload.signaling_path && payload.signaling_path !== this.el.dataset.webrtcSignalingPath) return
        this.viewer.setPreloadedWebRtcSession(payload.data)
      })
    }

    this.viewer.start()
  },

  destroyed() {
    if (this.viewer) {
      this.viewer.close()
      this.viewer = null
    }
  },

  handleViewerStateChange(state) {
    if (state === CAMERA_VIEWER_STATES.PLAYING) {
      const poster = this.el.querySelector("[data-role='video-poster']")
      poster?.classList?.add?.("opacity-0")
    }

    if (
      this.notifyViewerReady &&
      !this.notifiedViewerReady &&
      (state === CAMERA_VIEWER_STATES.PLAYING || state === CAMERA_VIEWER_STATES.FAILED)
    ) {
      this.notifiedViewerReady = true
      this.pushEvent("camera_live_viewer_ready", {})
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
