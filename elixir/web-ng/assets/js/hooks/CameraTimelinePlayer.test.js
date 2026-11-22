import {afterEach, describe, expect, it, vi} from "vitest"

import CameraTimelinePlayer, {
  buildOverlaySvgMarkup,
  computeVideoContentRect,
  createSerialFragmentLoader,
  escapeOverlayText,
  extractRecordingCopy,
  parseOverlayDetections,
  projectDetectionBox,
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
  windowStartUs = "1000000000",
  seekOffsetSeconds = "",
  highlightFrameId = "",
  overlayDetections = "",
  clientWidth = 1000,
  clientHeight = 600,
  videoWidth = 1920,
  videoHeight = 1080,
} = {}) {
  const videoListeners = new Map()
  const video = {
    duration: 60,
    currentTime: 0,
    paused: false,
    clientWidth,
    clientHeight,
    videoWidth,
    videoHeight,
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

  const overlayAttrs = new Map()
  const overlay = {
    innerHTML: "",
    hidden: false,
    setAttribute: vi.fn((k, v) => overlayAttrs.set(k, v)),
    getAttribute: k => overlayAttrs.get(k),
  }

  const toggleListeners = new Map()
  const toggleAttrs = new Map([["aria-pressed", "true"]])
  const overlayToggle = {
    textContent: "AI boxes: On",
    addEventListener: vi.fn((event, handler) => {
      toggleListeners.set(event, handler)
    }),
    setAttribute: vi.fn((k, v) => toggleAttrs.set(k, v)),
    getAttribute: k => toggleAttrs.get(k),
    click: () => toggleListeners.get("click")?.(),
  }

  const el = {
    dataset: {
      playlistPath,
      hasAdjacentWindow,
      windowEndUs,
      windowStartUs,
      seekOffsetSeconds,
      highlightFrameId,
      overlayDetections,
    },
    querySelector: selector => {
      if (selector === "[data-role='timeline-video']") return video
      if (selector === "[data-role='timeline-status']") return status
      if (selector === "[data-role='timeline-retry']") return retry
      if (selector === "[data-role='served-copy-badge']") return copyBadge
      if (selector === "[data-role='semantic-bbox-overlay']") return overlay
      if (selector === "[data-role='toggle-bbox-overlay']") return overlayToggle
      return null
    },
  }

  return {el, video, status, retry, copyBadge, overlay, overlayToggle}
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

  it("seeks video.currentTime to seekOffsetSeconds once loadedmetadata fires (when > 0) and updates non-destructive SVG overlay on toggle & resize without reloading HLS", () => {
    let resizeCallback = null
    class FakeResizeObserver {
      constructor(cb) {
        resizeCallback = cb
        this.disconnected = false
      }
      observe() {}
      disconnect() {
        this.disconnected = true
      }
    }

    vi.stubGlobal("window", {addEventListener: vi.fn()})
    vi.stubGlobal("ResizeObserver", FakeResizeObserver)

    const detectionsPayload = JSON.stringify([
      {
        visual_frame_id: "01933b40-0000-7000-8000-000000000099",
        offset_seconds: 12.5,
        time_basis: "received",
        object_class: "person <script>alert(1)</script>",
        score: 0.876,
        bbox: [0.25, 0.2, 0.5, 0.8],
      },
      {
        visual_frame_id: "01933b40-0000-7000-8000-000000000100",
        offset_seconds: 30.0,
        time_basis: "camera_reported",
        object_class: "vehicle",
        score: 0.92,
        bbox: {x1: 0.1, y1: 0.4, x2: 0.6, y2: 0.9},
      },
    ])

    const {el, video, overlay, overlayToggle} = makeElement({
      seekOffsetSeconds: "12.5",
      highlightFrameId: "01933b40-0000-7000-8000-000000000099",
      overlayDetections: detectionsPayload,
      clientWidth: 1000,
      clientHeight: 600,
      videoWidth: 1920,
      videoHeight: 1080,
    })
    const {FakeHls, instances} = makeFakeHls()

    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.mounted()

    // Before loadedmetadata, currentTime has not been sought yet
    expect(video.currentTime).toBe(0)
    expect(instances).toHaveLength(1)

    // Once loadedmetadata fires, seeks to 12.5s and renders aspect-aligned letterbox coordinates:
    // 1920x1080 inside 1000x600 -> content width=1000, height=562.5, x=0, y=18.75
    // bbox [0.25, 0.2, 0.5, 0.8] -> x=250.00, y=18.75 + 112.5 = 131.25, width=250.00, height=337.50
    video.emit("loadedmetadata")
    expect(video.currentTime).toBe(12.5)
    expect(overlay.getAttribute("viewBox")).toBe("0 0 1000 600")
    expect(overlay.innerHTML).toContain('x="250.00"')
    expect(overlay.innerHTML).toContain('y="131.25"')
    expect(overlay.innerHTML).toContain('width="250.00"')
    expect(overlay.innerHTML).toContain('height="337.50"')

    // Escapes untrusted label characters; never injects raw <script>
    expect(overlay.innerHTML).not.toContain("<script>")
    expect(overlay.innerHTML).toContain("person &lt;script&gt;alert(1)&lt;/script&gt; 88% · received")

    // Toggling overlay off hides SVG immediately without touching HLS instance or reloading media
    overlayToggle.click()
    expect(overlay.hidden).toBe(true)
    expect(overlay.innerHTML).toBe("")
    expect(overlayToggle.getAttribute("aria-pressed")).toBe("false")
    expect(overlayToggle.textContent).toBe("AI boxes: Off")
    expect(instances).toHaveLength(1)

    // Toggling back on restores boxes immediately
    overlayToggle.click()
    expect(overlay.hidden).toBe(false)
    expect(overlay.innerHTML).toContain('x="250.00"')
    expect(instances).toHaveLength(1)

    // Resize to pillarboxed container (1000x450 for 1920x1080 -> width=800, height=450, x=100, y=0)
    // bbox [0.25, 0.2, 0.5, 0.8] -> x=100 + 200 = 300.00, y=90.00, width=200.00, height=270.00
    video.clientWidth = 1000
    video.clientHeight = 450
    resizeCallback?.()
    expect(overlay.getAttribute("viewBox")).toBe("0 0 1000 450")
    expect(overlay.innerHTML).toContain('x="300.00"')
    expect(overlay.innerHTML).toContain('y="90.00"')
    expect(overlay.innerHTML).toContain('width="200.00"')
    expect(overlay.innerHTML).toContain('height="270.00"')

    // Scrubbing away from any hit clears boxes; seeking to second hit renders vehicle box
    video.currentTime = 20.0
    video.emit("timeupdate")
    expect(overlay.innerHTML).toBe("")

    el.dataset.seekOffsetSeconds = "30"
    el.dataset.highlightFrameId = "01933b40-0000-7000-8000-000000000100"
    hook.updated()
    expect(video.currentTime).toBe(30)
    expect(instances).toHaveLength(1)
    expect(overlay.innerHTML).toContain("vehicle 92% · camera_reported")

    hook.destroyed()
  })

  it("ignores non-positive seekOffsetSeconds on initial load and computes exact aspect-aligned geometry + escaping", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    const {el, video} = makeElement({seekOffsetSeconds: "0"})
    const {FakeHls} = makeFakeHls()

    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.mounted()

    video.currentTime = 4.2
    video.emit("loadedmetadata")
    expect(video.currentTime).toBe(4.2)
    hook.destroyed()

    const letterbox = computeVideoContentRect({
      clientWidth: 800,
      clientHeight: 600,
      videoWidth: 1920,
      videoHeight: 1080,
    })
    expect(letterbox).toEqual({x: 0, y: 75, width: 800, height: 450})

    const pillarbox = computeVideoContentRect({
      clientWidth: 1200,
      clientHeight: 450,
      videoWidth: 1920,
      videoHeight: 1080,
    })
    expect(pillarbox).toEqual({x: 200, y: 0, width: 800, height: 450})

    expect(projectDetectionBox([0.1, 0.2, 0.6, 0.7], letterbox)).toEqual({
      x1: 0.1,
      y1: 0.2,
      x2: 0.6,
      y2: 0.7,
      left: expect.closeTo(80, 5),
      top: expect.closeTo(165, 5),
      width: expect.closeTo(400, 5),
      height: expect.closeTo(225, 5),
    })

    expect(escapeOverlayText(`"a"&'<b>'`)).toBe("&quot;a&quot;&amp;&#39;&lt;b&gt;&#39;")

    const parsed = parseOverlayDetections(
      JSON.stringify([
        {
          visual_frame_id: "frame-1",
          timeline_ts_us: 1_008_000_000,
          time_basis: "received",
          detections: [{object_class: "package", confidence: 0.75, bbox: [0.2, 0.3, 0.4, 0.5]}],
        },
      ]),
      {windowStartUs: 1_000_000_000}
    )
    expect(parsed).toHaveLength(1)
    expect(parsed[0].offsetSeconds).toBe(8)
    expect(buildOverlaySvgMarkup(parsed, letterbox)).toContain("package 75% · received")
  })

  it("does not interrupt active HLS playback when live refresh updates hasAdjacentWindow without changing playlistPath", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    const {el, video, copyBadge} = makeElement({
      hasAdjacentWindow: "false",
      seekOffsetSeconds: "0",
    })
    const {FakeHls, instances} = makeFakeHls()
    const pushedEvents = []

    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.pushEvent = vi.fn((event, payload) => pushedEvents.push([event, payload]))

    hook.mounted()
    expect(instances).toHaveLength(1)

    video.currentTime = 24.5
    video.emit("loadedmetadata")
    copyBadge.textContent = "Serving: local"
    copyBadge.dataset.servedCopy = "local"

    // Live refresh slides coverage forward and exposes an adjacent window while keeping playlistPath stable.
    el.dataset.hasAdjacentWindow = "true"
    hook.updated()

    expect(instances).toHaveLength(1)
    expect(instances[0].destroyed).toBe(false)
    expect(video.currentTime).toBe(24.5)
    expect(copyBadge.textContent).toBe("Serving: local")

    // Advancing near window end now triggers advance_timeline_window because hasAdjacentWindow became true.
    video.currentTime = 50
    video.emit("timeupdate")
    expect(pushedEvents).toEqual([["advance_timeline_window", {window_end_us: "2000"}]])

    hook.destroyed()
  })
})
