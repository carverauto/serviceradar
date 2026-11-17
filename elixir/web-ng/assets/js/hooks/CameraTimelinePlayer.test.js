import {afterEach, describe, expect, it, vi} from "vitest"

import CameraTimelinePlayer, {
  createSerialFragmentLoader,
  extractRecordingCopy,
} from "./CameraTimelinePlayer"

class FakeBaseLoader {
  constructor() {
    this.stats = {aborted: false}
    this.aborted = false
    this.destroyed = false
  }

  load(context, _config, callbacks) {
    this.loadedContext = context
    this.callbacks = callbacks
    FakeBaseLoader.started.push(this)
  }

  abort() {
    this.aborted = true
    this.stats.aborted = true
  }

  destroy() {
    this.destroyed = true
  }
}
FakeBaseLoader.started = []

function makeElement({
  playlistPath = "/api/cameras/cam-1/timeline/playlist.m3u8?from=1000&to=2000&source=auto",
  hasAdjacentWindow = "true",
  windowEndUs = "2000",
} = {}) {
  const videoListeners = new Map()
  const video = {
    duration: 60,
    currentTime: 0,
    paused: false,
    addEventListener: vi.fn((event, handler) => {
      videoListeners.set(event, handler)
    }),
    pause: vi.fn(),
    removeAttribute: vi.fn(),
    load: vi.fn(),
    emit: event => videoListeners.get(event)?.(),
  }

  const status = {textContent: ""}
  const retryListeners = new Map()
  const retry = {
    hidden: true,
    addEventListener: vi.fn((event, handler) => {
      retryListeners.set(event, handler)
    }),
    click: () => retryListeners.get("click")?.(),
  }

  const copyBadge = {
    textContent: "Serving: —",
    dataset: {},
  }

  const el = {
    dataset: {playlistPath, hasAdjacentWindow, windowEndUs},
    querySelector: selector => {
      if (selector === "[data-role='timeline-video']") return video
      if (selector === "[data-role='timeline-status']") return status
      if (selector === "[data-role='timeline-retry']") return retry
      if (selector === "[data-role='served-copy-badge']") return copyBadge
      return null
    },
  }

  return {el, video, status, retry, copyBadge}
}

function makeFakeHls() {
  const instances = []

  class FakeHls {
    static isSupported() {
      return true
    }

    constructor(config) {
      this.config = config
      this.handlers = new Map()
      this.loadedSource = null
      this.attachedVideo = null
      this.destroyed = false
      instances.push(this)
    }

    on(event, handler) {
      this.handlers.set(event, handler)
    }

    loadSource(source) {
      this.loadedSource = source
    }

    attachMedia(video) {
      this.attachedVideo = video
    }

    destroy() {
      this.destroyed = true
    }
  }

  FakeHls.Events = {ERROR: "hlsError"}
  FakeHls.DefaultConfig = {loader: FakeBaseLoader}

  return {FakeHls, instances}
}

afterEach(() => {
  FakeBaseLoader.started = []
  vi.unstubAllGlobals()
})

describe("CameraTimelinePlayer hook", () => {
  it("configures 30s buffer bounds, updates served-copy badge from X-Recording-Copy, and advances adjacent windows once", () => {
    vi.stubGlobal("window", {
      addEventListener: vi.fn(),
    })

    const {el, video, copyBadge} = makeElement()
    const {FakeHls, instances} = makeFakeHls()
    const pushedEvents = []

    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.pushEvent = vi.fn((event, payload) => pushedEvents.push([event, payload]))

    hook.mounted()

    expect(instances).toHaveLength(1)
    expect(instances[0].config.maxBufferLength).toBe(30)
    expect(instances[0].config.maxMaxBufferLength).toBe(30)
    expect(instances[0].config.backBufferLength).toBe(30)
    expect(instances[0].loadedSource).toBe(el.dataset.playlistPath)

    // Simulate fragment responses carrying local, provisional, and archive headers
    const LoaderClass = instances[0].config.fLoader
    const firstLoader = new LoaderClass()
    firstLoader.load({url: "blocks/entry-1/fragments/0?source=auto"}, {}, {onSuccess: vi.fn()})

    return Promise.resolve().then(() => {
      expect(FakeBaseLoader.started).toHaveLength(1)

      FakeBaseLoader.started[0].callbacks.onSuccess(
        {data: new Uint8Array([1, 2, 3])},
        {},
        FakeBaseLoader.started[0].loadedContext,
        {getResponseHeader: name => (name.toLowerCase() === "x-recording-copy" ? "local; provisional" : null)}
      )

      expect(copyBadge.textContent).toBe("Serving: local; provisional")
      expect(copyBadge.dataset.servedCopy).toBe("local; provisional")

      // Far from window end (> 15s remaining): does not advance
      video.currentTime = 40
      video.emit("timeupdate")
      expect(pushedEvents).toEqual([])

      // Within 15s of window end: pushes advance_timeline_window once
      video.currentTime = 46
      video.emit("timeupdate")
      video.currentTime = 48
      video.emit("timeupdate")

      expect(pushedEvents).toEqual([
        ["advance_timeline_window", {window_end_us: "2000"}],
      ])

      // Updating playlistPath resets the adjacent-window latch for the next window
      el.dataset.playlistPath = "/api/cameras/cam-1/timeline/playlist.m3u8?from=2000&to=3000&source=auto"
      el.dataset.windowEndUs = "3000"
      hook.updated()

      expect(instances).toHaveLength(2)
      expect(copyBadge.textContent).toBe("Serving: —")

      video.currentTime = 50
      video.emit("timeupdate")
      expect(pushedEvents).toHaveLength(2)
      expect(pushedEvents[1]).toEqual([
        "advance_timeline_window",
        {window_end_us: "3000"},
      ])

      hook.destroyed()
    })
  })

  it("serializes fragment loads and cancels queued + in-flight requests on seek abort so the target fragment starts immediately", async () => {
    const copies = []
    const LoaderClass = createSerialFragmentLoader(FakeBaseLoader, copy => copies.push(copy))

    const loader0 = new LoaderClass()
    const loader1Queued = new LoaderClass()
    const loader2SeekTarget = new LoaderClass()

    const abortedQueued = vi.fn()
    loader0.load({url: "frag/0"}, {}, {onSuccess: vi.fn()})
    loader1Queued.load({url: "frag/1"}, {}, {onAbort: abortedQueued})

    await Promise.resolve()
    expect(FakeBaseLoader.started.map(l => l.loadedContext.url)).toEqual(["frag/0"])

    // Simulate viewer seeking: hls.js aborts in-flight frag/0 and queued frag/1, then loads frag/2
    loader1Queued.abort()
    expect(abortedQueued).toHaveBeenCalledOnce()
    loader0.abort()
    expect(loader0.aborted).toBe(true)

    loader2SeekTarget.load({url: "frag/2"}, {}, {onSuccess: vi.fn()})
    await Promise.resolve()
    await Promise.resolve()

    // Queued frag/1 never issued an HTTP load, and frag/2 started immediately!
    expect(FakeBaseLoader.started.map(l => l.loadedContext.url)).toEqual(["frag/0", "frag/2"])

    FakeBaseLoader.started[1].callbacks.onSuccess(
      {headers: {"x-recording-copy": "archive"}},
      {},
      FakeBaseLoader.started[1].loadedContext,
      null
    )
    expect(copies).toEqual(["archive"])
  })

  it("extracts X-Recording-Copy across XHR, Fetch Headers, and plain header maps", () => {
    expect(
      extractRecordingCopy(null, {
        getResponseHeader: key => (key === "x-recording-copy" ? "local" : null),
      })
    ).toBe("local")

    expect(
      extractRecordingCopy({
        headers: {get: key => (key === "x-recording-copy" ? "archive" : null)},
      })
    ).toBe("archive")

    expect(
      extractRecordingCopy({
        headers: {"X-Recording-Copy": "local; provisional"},
      })
    ).toBe("local; provisional")
  })
})
