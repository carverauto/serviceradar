import Hls from "hls.js/light"

const loadPolicy = () => ({
  default: {
    maxTimeToFirstByteMs: 12_000,
    maxLoadTimeMs: 12_000,
    timeoutRetry: null,
    errorRetry: null,
  },
})

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
    this.status = this.el.querySelector("[data-role='timeline-status']")
    this.retry = this.el.querySelector("[data-role='timeline-retry']")
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    this.listeners = new AbortController()
    this.advancingWindow = false

    const options = {signal: this.listeners.signal}
    this.retry?.addEventListener("click", () => this.start(), options)
    this.video?.addEventListener("loadeddata", () => this.report("Ready"), options)
    this.video?.addEventListener("playing", () => this.report("Playing"), options)
    this.video?.addEventListener("seeking", () => this.report("Seeking"), options)
    this.video?.addEventListener("seeked", () => {
      this.report(this.video.paused ? "Paused" : "Playing")
      this.maybeAdvanceWindow()
    }, options)
    this.video?.addEventListener("timeupdate", () => this.maybeAdvanceWindow(), options)
    this.video?.addEventListener("pause", () => {
      if (this.player) this.report("Paused")
    }, options)
    this.video?.addEventListener("ended", () => {
      this.maybeAdvanceWindow()
      this.report("End of timeline window")
    }, options)

    window.addEventListener("pagehide", () => this.stop(), options)
    window.addEventListener("pageshow", event => {
      if (event.persisted) this.start()
    }, options)

    this.start()
  },

  updated() {
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    if (this.path !== (this.el.dataset.playlistPath || "")) {
      this.advancingWindow = false
      this.start()
    }
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
    this.listeners?.abort()
    this.stop()
  },

  start() {
    this.stop()
    this.path = this.el.dataset.playlistPath || ""
    if (this.retry) this.retry.hidden = true
    this.updateServedCopy(null)

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
