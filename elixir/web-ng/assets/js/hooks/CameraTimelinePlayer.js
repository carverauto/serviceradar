import Hls from "hls.js/light"

const loadPolicy = () => ({
  default: {
    maxTimeToFirstByteMs: 12_000,
    maxLoadTimeMs: 12_000,
    timeoutRetry: null,
    errorRetry: null,
  },
})

export function escapeOverlayText(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

export function parseSeekOffsetSeconds(rawValue, {allowZero = false} = {}) {
  if (rawValue === null || rawValue === undefined || String(rawValue).trim() === "") {
    return null
  }
  const parsed = Number.parseFloat(String(rawValue))
  if (!Number.isFinite(parsed)) return null
  if (allowZero ? parsed < 0 : parsed <= 0) return null
  return parsed
}

export function computeVideoContentRect({
  clientWidth = 0,
  clientHeight = 0,
  videoWidth = 0,
  videoHeight = 0,
} = {}) {
  const cw = Number(clientWidth) || 0
  const ch = Number(clientHeight) || 0
  if (cw <= 0 || ch <= 0) {
    return {x: 0, y: 0, width: 0, height: 0}
  }

  const vw = Number(videoWidth) || 0
  const vh = Number(videoHeight) || 0
  if (vw <= 0 || vh <= 0) {
    return {x: 0, y: 0, width: cw, height: ch}
  }

  const containerAspect = cw / ch
  const videoAspect = vw / vh

  if (videoAspect > containerAspect) {
    const width = cw
    const height = cw / videoAspect
    return {
      x: 0,
      y: (ch - height) / 2,
      width,
      height,
    }
  }

  const height = ch
  const width = ch * videoAspect
  return {
    x: (cw - width) / 2,
    y: 0,
    width,
    height,
  }
}

function normalizeBboxTuple(bbox) {
  if (!bbox) return null

  let raw = null
  if (Array.isArray(bbox) && bbox.length === 4) {
    raw = bbox
  } else if (typeof bbox === "object") {
    const x1 = bbox.x1 ?? bbox.bbox_x1
    const y1 = bbox.y1 ?? bbox.bbox_y1
    const x2 = bbox.x2 ?? bbox.bbox_x2
    const y2 = bbox.y2 ?? bbox.bbox_y2
    raw = [x1, y1, x2, y2]
  }

  if (!raw) return null
  const nums = raw.map(Number)
  if (nums.some(n => !Number.isFinite(n))) return null

  const clamp01 = n => Math.min(1, Math.max(0, n))
  const [x1, y1, x2, y2] = nums.map(clamp01)
  if (!(x2 > x1 && y2 > y1)) return null
  return [x1, y1, x2, y2]
}

export function projectDetectionBox(bbox, contentRect) {
  const tuple = normalizeBboxTuple(bbox)
  if (!tuple || !contentRect || contentRect.width <= 0 || contentRect.height <= 0) {
    return null
  }

  const [x1, y1, x2, y2] = tuple
  return {
    x1,
    y1,
    x2,
    y2,
    left: contentRect.x + x1 * contentRect.width,
    top: contentRect.y + y1 * contentRect.height,
    width: (x2 - x1) * contentRect.width,
    height: (y2 - y1) * contentRect.height,
  }
}

export function parseOverlayDetections(rawJson, {windowStartUs = null} = {}) {
  if (!rawJson || typeof rawJson !== "string" || rawJson.trim() === "") return []

  let parsed
  try {
    parsed = JSON.parse(rawJson)
  } catch (_err) {
    return []
  }

  if (!Array.isArray(parsed)) return []

  const winStart =
    windowStartUs !== null && windowStartUs !== undefined && String(windowStartUs).trim() !== ""
      ? Number(windowStartUs)
      : null

  const normalized = []

  const pushEntry = (item, parent = {}) => {
    if (!item || typeof item !== "object") return
    const bbox = normalizeBboxTuple(item.bbox ?? item.bbox_norm ?? parent.bbox ?? parent.bbox_norm)
    if (!bbox) return

    let offsetSeconds = Number(item.offset_seconds ?? item.offsetSeconds ?? parent.offset_seconds ?? parent.offsetSeconds)
    if (!Number.isFinite(offsetSeconds)) {
      const tsUs = Number(item.timeline_ts_us ?? item.best_timeline_ts_us ?? parent.timeline_ts_us ?? parent.best_timeline_ts_us)
      if (Number.isFinite(tsUs) && Number.isFinite(winStart)) {
        offsetSeconds = Math.max(0, (tsUs - winStart) / 1_000_000)
      } else {
        offsetSeconds = 0
      }
    }

    const rawScore = Number(item.score ?? item.confidence ?? item.similarity ?? parent.score ?? parent.similarity)
    const score = Number.isFinite(rawScore) ? Math.min(1, Math.max(0, rawScore)) : null

    normalized.push({
      visualFrameId: String(item.visual_frame_id ?? item.visualFrameId ?? parent.visual_frame_id ?? parent.visualFrameId ?? ""),
      offsetSeconds,
      timeBasis: String(item.time_basis ?? item.timeBasis ?? parent.time_basis ?? parent.timeBasis ?? "received"),
      objectClass: String(item.object_class ?? item.objectClass ?? item.class ?? "object"),
      score,
      bbox,
      highlighted: Boolean(item.highlighted ?? parent.highlighted),
    })
  }

  for (const entry of parsed) {
    if (!entry || typeof entry !== "object") continue
    if (Array.isArray(entry.detections) && entry.detections.length > 0) {
      for (const child of entry.detections) {
        pushEntry(child, entry)
      }
    } else {
      pushEntry(entry)
    }
  }

  return normalized
}

export function selectActiveDetections(
  detections,
  currentTimeSeconds,
  {highlightFrameId = null, toleranceSeconds = 1.5, metadataLoaded = true} = {}
) {
  if (!Array.isArray(detections) || detections.length === 0) return []
  const highlightId = highlightFrameId ? String(highlightFrameId) : ""

  if (!metadataLoaded && highlightId !== "") {
    const highlighted = detections.filter(d => d.visualFrameId === highlightId)
    if (highlighted.length > 0) return highlighted
  }

  const nowSec = Number(currentTimeSeconds)
  if (!Number.isFinite(nowSec)) return []

  const inWindow = detections.filter(d => Math.abs(d.offsetSeconds - nowSec) <= toleranceSeconds)
  if (inWindow.length === 0) return []

  if (highlightId !== "") {
    const exactFrame = inWindow.filter(d => d.visualFrameId === highlightId)
    if (exactFrame.length > 0) return exactFrame
  }

  let bestGroupKey = null
  let bestDistance = Number.POSITIVE_INFINITY
  const groups = new Map()

  for (const det of inWindow) {
    const key = det.visualFrameId !== "" ? `frame:${det.visualFrameId}` : `ts:${det.offsetSeconds.toFixed(3)}`
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(det)

    const dist = Math.abs(det.offsetSeconds - nowSec)
    if (dist < bestDistance) {
      bestDistance = dist
      bestGroupKey = key
    }
  }

  return bestGroupKey ? groups.get(bestGroupKey) || [] : []
}

export function buildOverlaySvgMarkup(detections, contentRect) {
  if (!Array.isArray(detections) || detections.length === 0) return ""
  if (!contentRect || contentRect.width <= 0 || contentRect.height <= 0) return ""

  const items = []

  for (const det of detections) {
    const projected = projectDetectionBox(det.bbox, contentRect)
    if (!projected) continue

    const classText = escapeOverlayText(det.objectClass || "object")
    const basisText = escapeOverlayText(det.timeBasis || "received")
    const scorePart = det.score !== null && Number.isFinite(det.score) ? ` ${Math.round(det.score * 100)}%` : ""
    const label = `${classText}${scorePart} · ${basisText}`

    const x = projected.left.toFixed(2)
    const y = projected.top.toFixed(2)
    const w = projected.width.toFixed(2)
    const h = projected.height.toFixed(2)

    const labelHeight = 20
    const labelWidth = Math.max(76, Math.min(projected.width, label.length * 6.8 + 12))
    const labelY = Math.max(contentRect.y, projected.top - labelHeight >= contentRect.y ? projected.top - labelHeight : projected.top)
    const textX = (projected.left + 6).toFixed(2)
    const textY = (labelY + 14).toFixed(2)

    items.push(
      `<g data-role="semantic-bbox-item" data-object-class="${classText}" data-time-basis="${basisText}">` +
        `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="3" fill="rgba(16, 185, 129, 0.14)" stroke="#10b981" stroke-width="2" />` +
        `<rect x="${x}" y="${labelY.toFixed(2)}" width="${labelWidth.toFixed(2)}" height="${labelHeight}" rx="3" fill="rgba(9, 9, 11, 0.85)" />` +
        `<text x="${textX}" y="${textY}" fill="#ecfdf5" font-size="11" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">${label}</text>` +
        `</g>`
    )
  }

  return items.join("")
}

export function extractRecordingCopy(response, networkDetails, loaderInstance) {
  const candidates = [networkDetails, response, loaderInstance?.loader, loaderInstance]

  for (const source of candidates) {
    if (!source) continue

    if (typeof source.getResponseHeader === "function") {
      const value = source.getResponseHeader("x-recording-copy") || source.getResponseHeader("X-Recording-Copy")
      if (typeof value === "string" && value.trim() !== "") return value.trim()
    }

    if (source.headers) {
      if (typeof source.headers.get === "function") {
        const value = source.headers.get("x-recording-copy") || source.headers.get("X-Recording-Copy")
        if (typeof value === "string" && value.trim() !== "") return value.trim()
      } else if (typeof source.headers === "object") {
        const value = source.headers["x-recording-copy"] || source.headers["X-Recording-Copy"]
        if (typeof value === "string" && value.trim() !== "") return value.trim()
      }
    }
  }

  return null
}

export function createSerialFragmentLoader(BaseLoader = Hls.DefaultConfig.loader, onServedCopy = null) {
  let inFlight = null
  const queue = []
  const active = new Set()

  const pump = () => {
    while (!inFlight && queue.length > 0) {
      const next = queue.shift()
      if (!next || next.cancelled || next.finished) continue
      inFlight = next
      next.startLoad()
    }
  }

  class TimelineFragmentLoader extends BaseLoader {
    load(context, config, callbacks) {
      this.context = context
      this.cancelled = false
      this.started = false
      this.finished = false
      this.abortQueued = () => callbacks.onAbort?.(this.stats, context, null)

      this.finish = () => {
        if (this.finished) return
        this.finished = true
        active.delete(this)
        const queuedIndex = queue.indexOf(this)
        if (queuedIndex !== -1) queue.splice(queuedIndex, 1)
        if (inFlight === this) {
          inFlight = null
          pump()
        }
      }

      const complete = callback => (...args) => {
        try {
          callback?.(...args)
        } finally {
          this.finish()
        }
      }

      this.startLoad = () => {
        this.started = true
        super.load(context, config, {
          ...callbacks,
          onSuccess: (response, stats, loadedContext, networkDetails) => {
            try {
              const copy = extractRecordingCopy(response, networkDetails, this)
              if (copy && typeof onServedCopy === "function") {
                onServedCopy(copy)
              }
              callbacks.onSuccess?.(response, stats, loadedContext, networkDetails)
            } finally {
              this.finish()
            }
          },
          onError: complete(callbacks.onError),
          onTimeout: complete(callbacks.onTimeout),
        })
      }

      active.add(this)
      queue.push(this)
      pump()
    }

    abort() {
      this.cancelled = true
      if (this.started) {
        super.abort?.()
      } else {
        if (this.stats) this.stats.aborted = true
        this.abortQueued?.()
      }
      this.finish?.()
    }

    destroy() {
      this.cancelled = true
      super.destroy?.()
      this.finish?.()
    }
  }

  TimelineFragmentLoader.cancelAll = () => {
    for (const loader of Array.from(active)) {
      loader.abort()
    }
  }

  return TimelineFragmentLoader
}

const ADJACENT_PREFETCH_THRESHOLD_SECONDS = 15

export default {
  mounted() {
    this.video = this.el.querySelector("[data-role='timeline-video']")
    this.videoContainer = this.el.querySelector("[data-role='timeline-video-container']")
    this.status = this.el.querySelector("[data-role='timeline-status']")
    this.retry = this.el.querySelector("[data-role='timeline-retry']")
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    this.overlay = this.el.querySelector("[data-role='semantic-bbox-overlay']")
    this.overlayToggle = this.el.querySelector("[data-role='toggle-bbox-overlay']")
    this.btnBack10 = this.el.querySelector("[data-role='transport-back-10']")
    this.btnPlayPause = this.el.querySelector("[data-role='transport-play-pause']")
    this.btnFwd10 = this.el.querySelector("[data-role='transport-fwd-10']")
    this.btnMute = this.el.querySelector("[data-role='transport-mute']")
    this.btnFullscreen = this.el.querySelector("[data-role='transport-fullscreen']")
    this.timeDisplay = this.el.querySelector("[data-role='transport-current-time']")
    this.listeners = new AbortController()
    this.advancingWindow = false
    this.overlayEnabled = true
    this.metadataLoaded = false
    this.detections = []
    this.lastAppliedSeekAttr = ""
    this.pendingSeekOffsetSeconds = null

    const options = {signal: this.listeners.signal}
    this.retry?.addEventListener("click", () => this.start(), options)
    this.overlayToggle?.addEventListener("click", () => this.toggleOverlay(), options)
    this.btnBack10?.addEventListener("click", () => this.stepSeconds(-10), options)
    this.btnPlayPause?.addEventListener("click", () => this.togglePlayPause(), options)
    this.btnFwd10?.addEventListener("click", () => this.stepSeconds(10), options)
    this.btnMute?.addEventListener("click", () => this.toggleMute(), options)
    this.btnFullscreen?.addEventListener("click", () => this.toggleFullscreen(), options)

    this.video?.addEventListener(
      "loadedmetadata",
      () => {
        this.metadataLoaded = true
        this.applyPendingSeek()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "loadeddata",
      () => {
        this.report("Ready")
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "playing",
      () => {
        this.report("Playing")
        this.syncTransportControls()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener("seeking", () => this.report("Seeking"), options)
    this.video?.addEventListener(
      "seeked",
      () => {
        this.report(this.video.paused ? "Paused" : "Playing")
        this.syncTransportControls()
        this.maybeAdvanceWindow()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "timeupdate",
      () => {
        this.syncTransportControls()
        this.maybeAdvanceWindow()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "pause",
      () => {
        if (this.player) this.report("Paused")
        this.syncTransportControls()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "volumechange",
      () => {
        this.syncTransportControls()
      },
      options
    )
    this.video?.addEventListener(
      "ended",
      () => {
        this.maybeAdvanceWindow()
        this.report("End of timeline window")
        this.renderOverlay()
      },
      options
    )

    if (typeof ResizeObserver === "function" && this.video) {
      this.resizeObserver = new ResizeObserver(() => this.renderOverlay())
      this.resizeObserver.observe(this.video)
    }

    window.addEventListener("pagehide", () => this.stop(), options)
    window.addEventListener(
      "pageshow",
      event => {
        if (event.persisted) this.start()
      },
      options
    )

    this.syncOverlayDataset()
    this.syncOverlayToggleButton()
    this.syncTransportControls()
    this.start()
  },

  updated() {
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    this.overlay = this.el.querySelector("[data-role='semantic-bbox-overlay']")
    this.overlayToggle = this.el.querySelector("[data-role='toggle-bbox-overlay']")
    this.syncOverlayDataset()
    this.syncOverlayToggleButton()

    const nextPlaylistPath = this.el.dataset.playlistPath || ""
    const nextSeekAttr = this.el.dataset.seekOffsetSeconds || ""

    if (this.path !== nextPlaylistPath) {
      this.advancingWindow = false
      this.start()
      return
    }

    if (nextSeekAttr !== this.lastAppliedSeekAttr) {
      this.lastAppliedSeekAttr = nextSeekAttr
      this.pendingSeekOffsetSeconds = parseSeekOffsetSeconds(nextSeekAttr, {allowZero: true})
      if (this.metadataLoaded) {
        this.applyPendingSeek()
      }
    }

    this.renderOverlay()
  },

  disconnected() {
    this.suspended = true
    this.stop()
    this.report("Connection lost. Reconnecting...")
  },

  reconnected() {
    this.suspended = false
    this.start()
  },

  destroyed() {
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    this.listeners?.abort()
    this.stop()
  },

  start() {
    this.stop()
    this.path = this.el.dataset.playlistPath || ""
    this.metadataLoaded = false
    this.lastAppliedSeekAttr = this.el.dataset.seekOffsetSeconds || ""
    this.pendingSeekOffsetSeconds = parseSeekOffsetSeconds(this.lastAppliedSeekAttr)

    if (this.retry) this.retry.hidden = true
    this.updateServedCopy(null)
    this.renderOverlay()

    if (this.suspended || !this.path) {
      this.report("No playable footage in selected window")
      return
    }

    const HlsClass = this.hlsClass || Hls
    if (!HlsClass.isSupported()) {
      this.report("Timeline playback is not supported in this browser.")
      return
    }

    this.report("Loading timeline...")
    const LoaderClass = createSerialFragmentLoader(
      HlsClass.DefaultConfig?.loader,
      copy => this.updateServedCopy(copy)
    )
    this.loaderClass = LoaderClass

    const player = new HlsClass({
      enableWorker: false,
      lowLatencyMode: false,
      progressive: false,
      maxBufferLength: 30,
      maxMaxBufferLength: 30,
      backBufferLength: 30,
      fLoader: LoaderClass,
      manifestLoadPolicy: loadPolicy(),
      playlistLoadPolicy: loadPolicy(),
      fragLoadPolicy: loadPolicy(),
    })

    this.player = player
    player.on(HlsClass.Events.ERROR, (_event, data) => {
      if (this.player !== player || !data.fatal) return
      const statusCode = data?.response?.code
      this.stop()
      if (statusCode === 503) {
        this.report("Playback read capacity busy. Retry shortly.")
      } else if (statusCode === 403 || statusCode === 401) {
        this.report("Recording access denied or revoked.")
      } else {
        this.report("Timeline footage unavailable. Retry to check access and availability.")
      }
      if (this.retry) this.retry.hidden = false
    })

    player.loadSource(this.path)
    if (this.video) player.attachMedia(this.video)
  },

  stop() {
    if (this.loaderClass?.cancelAll) {
      this.loaderClass.cancelAll()
      this.loaderClass = null
    }
    const player = this.player
    this.player = null
    if (player) player.destroy()
    if (this.video) {
      this.video.pause()
      this.video.removeAttribute("src")
      this.video.load()
    }
    this.clearOverlay()
  },

  applyPendingSeek() {
    if (!this.video || this.pendingSeekOffsetSeconds === null) return
    const target = this.pendingSeekOffsetSeconds
    this.pendingSeekOffsetSeconds = null

    const duration = this.video.duration
    if (Number.isFinite(duration) && duration > 0) {
      this.video.currentTime = Math.min(target, duration)
    } else {
      this.video.currentTime = target
    }
  },

  toggleOverlay() {
    this.overlayEnabled = !this.overlayEnabled
    this.syncOverlayToggleButton()
    this.renderOverlay()
  },

  stepSeconds(delta) {
    if (!this.video) return
    const current = Number(this.video.currentTime) || 0
    const duration = Number(this.video.duration)
    const target = Math.max(0, current + delta)
    this.video.currentTime = Number.isFinite(duration) && duration > 0 ? Math.min(target, duration) : target
    this.syncTransportControls()
  },

  togglePlayPause() {
    if (!this.video) return
    if (this.video.paused) {
      this.video.play?.()?.catch?.(() => {})
    } else {
      this.video.pause?.()
    }
    this.syncTransportControls()
  },

  toggleMute() {
    if (!this.video) return
    this.video.muted = !this.video.muted
    this.syncTransportControls()
  },

  toggleFullscreen() {
    const target = this.videoContainer || this.video
    if (!target) return
    if (typeof document !== "undefined" && document.fullscreenElement) {
      document.exitFullscreen?.()?.catch?.(() => {})
    } else {
      target.requestFullscreen?.()?.catch?.(() => {})
    }
  },

  syncTransportControls() {
    if (!this.video) return

    if (this.btnPlayPause) {
      const playing = !this.video.paused
      this.btnPlayPause.setAttribute?.("aria-pressed", String(playing))
      this.btnPlayPause.textContent = playing ? "Pause" : "Play"
    }

    if (this.btnMute) {
      const muted = Boolean(this.video.muted)
      this.btnMute.setAttribute?.("aria-pressed", String(muted))
      this.btnMute.textContent = muted ? "Unmute" : "Mute"
    }

    if (this.timeDisplay) {
      const cur = Math.max(0, Math.floor(Number(this.video.currentTime) || 0))
      const dur = Number.isFinite(this.video.duration) && this.video.duration > 0 ? Math.floor(this.video.duration) : 0
      const fmt = sec => {
        const m = Math.floor(sec / 60)
        const s = sec % 60
        return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
      }
      this.timeDisplay.textContent = dur > 0 ? `${fmt(cur)} / ${fmt(dur)}` : fmt(cur)
    }
  },

  syncOverlayDataset() {
    this.detections = parseOverlayDetections(this.el.dataset.overlayDetections || "", {
      windowStartUs: this.el.dataset.windowStartUs || null,
    })
  },

  syncOverlayToggleButton() {
    if (!this.overlayToggle) return
    this.overlayToggle.setAttribute?.("aria-pressed", String(this.overlayEnabled))
    this.overlayToggle.textContent = this.overlayEnabled ? "AI boxes: On" : "AI boxes: Off"
  },

  clearOverlay() {
    if (!this.overlay) return
    this.overlay.innerHTML = ""
  },

  renderOverlay() {
    if (!this.overlay || !this.video) return

    if (!this.overlayEnabled || this.detections.length === 0) {
      this.overlay.hidden = !this.overlayEnabled
      this.overlay.innerHTML = ""
      return
    }

    this.overlay.hidden = false
    const cw = Number(this.video.clientWidth) || 0
    const ch = Number(this.video.clientHeight) || 0
    if (cw <= 0 || ch <= 0) {
      this.overlay.innerHTML = ""
      return
    }

    this.overlay.setAttribute?.("viewBox", `0 0 ${cw} ${ch}`)
    const contentRect = computeVideoContentRect({
      clientWidth: cw,
      clientHeight: ch,
      videoWidth: this.video.videoWidth,
      videoHeight: this.video.videoHeight,
    })

    const active = selectActiveDetections(this.detections, this.video.currentTime, {
      highlightFrameId: this.el.dataset.highlightFrameId || null,
      metadataLoaded: this.metadataLoaded,
    })

    this.overlay.innerHTML = buildOverlaySvgMarkup(active, contentRect)
  },

  maybeAdvanceWindow() {
    if (this.advancingWindow) return
    if (this.el.dataset.hasAdjacentWindow !== "true") return
    if (!this.video) return

    const duration = this.video.duration
    const currentTime = this.video.currentTime
    if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) return

    if (duration - currentTime <= ADJACENT_PREFETCH_THRESHOLD_SECONDS) {
      this.advancingWindow = true
      this.pushEvent?.("advance_timeline_window", {
        window_end_us: this.el.dataset.windowEndUs || null,
      })
    }
  },

  updateServedCopy(copy) {
    if (!this.copyBadge) return
    if (!copy) {
      this.copyBadge.textContent = "Serving: —"
      this.copyBadge.dataset.servedCopy = ""
      return
    }
    this.copyBadge.textContent = `Serving: ${copy}`
    this.copyBadge.dataset.servedCopy = copy
  },

  report(message) {
    if (this.status) this.status.textContent = message
  },
}
