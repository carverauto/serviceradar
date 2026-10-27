import Hls from "hls.js/light"

// Archive requests are independently authorized. A busy or failed reader requires
// an explicit retry; client cancellation does not release server admission.
const loadPolicy = () => ({
  default: {
    maxTimeToFirstByteMs: 12_000,
    maxLoadTimeMs: 12_000,
    timeoutRetry: null,
    errorRetry: null,
  },
})

// hls.js loads initialization and media fragments concurrently. Archive reads
// share one server slot, so each player queues its fragment HTTP requests.
function serialFragmentLoader() {
  let tail = Promise.resolve()
  return class extends Hls.DefaultConfig.loader {
    load(context, config, callbacks) {
      this.context = context
      this.abortQueued = () => callbacks.onAbort?.(this.stats, context, null)
      const previous = tail
      const done = new Promise(resolve => { this.finish = resolve })
      // A cancelled queued request must still wait for its predecessor before
      // allowing the following request through.
      tail = previous.then(() => done)
      const complete = callback => (...args) => {
        try { callback(...args) } finally { this.finish() }
      }
      previous.then(() => {
        if (this.cancelled) return
        this.started = true
        super.load(context, config, {
          ...callbacks,
          onSuccess: complete(callbacks.onSuccess),
          onError: complete(callbacks.onError),
          onTimeout: complete(callbacks.onTimeout),
        })
      })
    }

    abort() {
      this.cancelled = true
      if (this.started) super.abort()
      else {
        this.stats.aborted = true
        this.abortQueued?.()
      }
      this.finish?.()
    }

    destroy() {
      this.cancelled = true
      super.destroy()
      this.finish?.()
    }
  }
}

export default {
  mounted() {
    this.video = this.el.querySelector("[data-role='archive-video']")
    this.status = this.el.querySelector("[data-role='archive-status']")
    this.retry = this.el.querySelector("[data-role='archive-retry']")
    this.listeners = new AbortController()
    const options = {signal: this.listeners.signal}
    this.retry.addEventListener("click", () => this.start(), options)
    this.video.addEventListener("loadeddata", () => this.report("Ready"), options)
    this.video.addEventListener("playing", () => this.report("Playing"), options)
    this.video.addEventListener("seeking", () => this.report("Seeking"), options)
    this.video.addEventListener("seeked", () => this.report(this.video.paused ? "Paused" : "Playing"), options)
    this.video.addEventListener("pause", () => {
      if (this.player) this.report("Paused")
    }, options)
    this.video.addEventListener("ended", () => this.report("End of playback window"), options)
    window.addEventListener("pagehide", () => this.stop(), options)
    window.addEventListener("pageshow", event => {
      if (event.persisted) this.start()
    }, options)
    this.start()
  },

  updated() {
    if (this.path !== this.el.dataset.playlistPath) this.start()
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
    this.listeners.abort()
    this.stop()
  },

  start() {
    this.stop()
    this.path = this.el.dataset.playlistPath || ""
    this.retry.hidden = true
    if (this.suspended || !this.path) {
      this.report("Select a recording")
      return
    }
    if (!Hls.isSupported()) {
      this.report("Archive playback is not supported in this browser.")
      return
    }

    this.report("Loading recording...")
    const player = new Hls({
      enableWorker: false,
      lowLatencyMode: false,
      progressive: false,
      maxBufferLength: 8,
      maxMaxBufferLength: 8,
      backBufferLength: 8,
      fLoader: serialFragmentLoader(),
      manifestLoadPolicy: loadPolicy(),
      playlistLoadPolicy: loadPolicy(),
      fragLoadPolicy: loadPolicy(),
    })
    this.player = player
    player.on(Hls.Events.ERROR, (_event, data) => {
      if (this.player !== player || !data.fatal) return
      this.stop()
      this.report("Recording unavailable. Retry to check access and availability again.")
      this.retry.hidden = false
    })
    player.loadSource(this.path)
    player.attachMedia(this.video)
  },

  stop() {
    const player = this.player
    this.player = null
    if (player) player.destroy()
    this.video.pause()
    this.video.removeAttribute("src")
    this.video.load()
  },

  report(message) {
    this.status.textContent = message
  },
}
