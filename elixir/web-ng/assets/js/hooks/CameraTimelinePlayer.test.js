import {afterEach, describe, expect, it, vi} from "vitest"

import CameraTimelinePlayer, {
  buildOverlaySvgMarkup,
  buildScrubberEventSegments,
  buildScrubberHoverMarkup,
  clampHoverTooltipPercent,
  computeScrubberFraction,
  computeVideoContentRect,
  createSerialFragmentLoader,
  escapeOverlayText,
  extractFragmentPdtRanges,
  extractRecordingCopy,
  findNearestScrubberThumbnail,
  formatScrubberTime,
  isSafeThumbnailUrl,
  isScrubberEventCategory,
  isSmartScrubberCategory,
  normalizeEventCategory,
  parseOverlayDetections,
  parseScrubberEvents,
  parseScrubberThumbnails,
  projectDetectionBox,
  resolvePlaybackTimelineUs,
  resolveTimelineUsToPlaybackSeconds,
  selectActiveDetections,
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
    ended: false,
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

    emit(event, data) {
      this.handlers.get(event)?.(event, data)
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

  FakeHls.Events = {ERROR: "hlsError", LEVEL_LOADED: "hlsLevelLoaded"}
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
    expect(instances[0].config.enableWorker).toBe(true)
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

      // Not yet at window end (10s remaining): does not advance prematurely
      video.currentTime = 50
      video.emit("timeupdate")
      expect(pushedEvents).toEqual([])

      // Paused even within 1s of window end (and not ended): does not auto-advance
      video.paused = true
      video.ended = false
      video.currentTime = 59.5
      video.emit("seeked")
      expect(pushedEvents).toEqual([])

      // Playing within 1.0s of window end: pushes advance_timeline_window once
      video.paused = false
      video.currentTime = 59.2
      video.emit("timeupdate")
      video.currentTime = 59.6
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

      // Reaching ended event (even when browser sets paused=true on ended) advances the next window
      video.paused = true
      video.ended = true
      video.currentTime = 60
      video.emit("ended")
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

    // Advancing near window end (<= 1.0s remaining while playing) triggers advance_timeline_window because hasAdjacentWindow became true.
    video.currentTime = 59.3
    video.emit("timeupdate")
    expect(pushedEvents).toEqual([["advance_timeline_window", {window_end_us: "2000"}]])

    hook.destroyed()
  })

  it("renders multi-frame window detections during normal playback without highlightFrameId and refreshes non-destructively on updated()", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    const initialPayload = JSON.stringify([
      {
        visual_frame_id: "frame-window-1",
        timeline_ts_us: 1_005_000_000,
        time_basis: "received",
        object_class: "person",
        score: 0.91,
        bbox: [0.1, 0.2, 0.3, 0.8],
      },
      {
        visual_frame_id: "frame-window-2",
        timeline_ts_us: 1_018_000_000,
        time_basis: "received",
        object_class: "vehicle",
        score: 0.86,
        bbox: [0.4, 0.3, 0.8, 0.7],
      },
    ])

    const {el, video, overlay} = makeElement({
      windowStartUs: "1000000000",
      seekOffsetSeconds: "0",
      highlightFrameId: "",
      overlayDetections: initialPayload,
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

    video.currentTime = 5.0
    video.emit("loadedmetadata")
    expect(overlay.innerHTML).toContain("person 91% · received")
    expect(overlay.innerHTML).not.toContain("vehicle")

    // Scrubbing to 18.0s switches active frame to frame-window-2 without highlightFrameId
    video.currentTime = 18.0
    video.emit("timeupdate")
    expect(overlay.innerHTML).toContain("vehicle 86% · received")
    expect(overlay.innerHTML).not.toContain("person")

    // Live refresh updates overlayDetections while keeping playlistPath stable (no HLS reload)
    el.dataset.overlayDetections = JSON.stringify([
      {
        visual_frame_id: "frame-window-2",
        timeline_ts_us: 1_018_000_000,
        time_basis: "received",
        object_class: "package",
        score: 0.84,
        bbox: [0.45, 0.35, 0.75, 0.65],
      },
    ])
    hook.updated()

    expect(instances).toHaveLength(1)
    expect(instances[0].destroyed).toBe(false)
    expect(overlay.innerHTML).toContain("package 84% · received")

    hook.destroyed()
  })

  it("renders Smart highlight bars + subtle Motion hairlines, filmstrip thumbnails, and live hover thumbnail preview card", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    expect(normalizeEventCategory("Person")).toBe("person")
    expect(normalizeEventCategory("white van")).toBe("vehicle")
    expect(normalizeEventCategory("dog")).toBe("animal")
    expect(normalizeEventCategory("package")).toBe("package")
    expect(normalizeEventCategory("motion")).toBe("motion")
    expect(isSmartScrubberCategory("person")).toBe(true)
    expect(isSmartScrubberCategory("animal")).toBe(true)
    expect(isSmartScrubberCategory("vehicle")).toBe(true)
    expect(isSmartScrubberCategory("package")).toBe(true)
    expect(isSmartScrubberCategory("motion")).toBe(false)
    expect(isScrubberEventCategory("person")).toBe(true)
    expect(isScrubberEventCategory("motion")).toBe(true)
    expect(isScrubberEventCategory("recording")).toBe(false)
    expect(isSafeThumbnailUrl("/api/cameras/cam-1/timeline/thumbnails/frame/f1.jpg")).toBe(true)
    expect(isSafeThumbnailUrl("https://thumbnails.example.com/frame-1.jpg")).toBe(true)
    expect(isSafeThumbnailUrl("javascript:alert(1)")).toBe(false)
    expect(isSafeThumbnailUrl("//evil.example.com/x.jpg")).toBe(false)
    expect(formatScrubberTime(75)).toBe("01:15")
    expect(formatScrubberTime(3665)).toBe("1:01:05")
    expect(computeScrubberFraction(250, {left: 100, width: 300})).toBe(0.5)
    expect(clampHoverTooltipPercent(0.01, 400, 144)).toBe(18)
    expect(clampHoverTooltipPercent(0.99, 400, 144)).toBe(82)
    expect(clampHoverTooltipPercent(0.5, 400, 144)).toBe(50)

    const parsedWindowEvents = parseScrubberEvents(
      JSON.stringify([
        {category: "recording", label: "Recording", start_offset_seconds: 5, end_offset_seconds: 15},
        {category: "motion", label: "Motion", start_offset_seconds: 40, end_offset_seconds: 44},
        {
          category: "vehicle",
          label: "Vehicle",
          start_offset_seconds: 45,
          end_offset_seconds: 48,
          confidence: 0.88,
          thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/frame/v1.jpg",
        },
      ])
    )
    // Both Smart detections and Motion are preserved; :recording is excluded
    expect(parsedWindowEvents).toHaveLength(2)
    expect(parsedWindowEvents[0].category).toBe("motion")
    expect(parsedWindowEvents[1].category).toBe("vehicle")
    expect(parsedWindowEvents[1].thumbnailUrl).toBe("/api/cameras/cam-1/timeline/thumbnails/frame/v1.jpg")

    const segments = buildScrubberEventSegments(
      [
        {offsetSeconds: 10, objectClass: "person", score: 0.91},
        {offsetSeconds: 11.5, objectClass: "person", score: 0.95},
        {offsetSeconds: 30, objectClass: "animal", score: 0.82},
      ],
      [
        ...parsedWindowEvents,
        // Overlapping motion at 10-12s must NOT overwrite or merge into person
        {startSec: 10, endSec: 12, category: "motion", label: "Motion", score: null, thumbnailUrl: null},
      ],
      60
    )
    // Motion segments sort first (underneath), Smart segments sort on top
    expect(segments).toHaveLength(5)
    expect(segments.map(s => `${s.tier}:${s.category}`)).toEqual([
      "motion:motion",
      "motion:motion",
      "smart:person",
      "smart:animal",
      "smart:vehicle",
    ])
    expect(segments[0].tooltip).toBe("Motion · 00:10")
    expect(segments[1].tooltip).toBe("Motion · 00:40")
    expect(segments[2].tooltip).toBe("Person · 00:10 · 95%")
    expect(segments[3].tooltip).toBe("Animal · 00:30 · 82%")
    expect(segments[4].tooltip).toBe("Vehicle · 00:45 · 88%")

    const parsedThumbs = parseScrubberThumbnails(
      JSON.stringify([
        {offset_seconds: 5, thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/block/b1.jpg", label: null},
        {offset_seconds: 30, thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/frame/a1.jpg", label: "Animal"},
        {offset_seconds: 55, thumbnail_url: "javascript:bad()", label: "Bad"},
      ])
    )
    expect(parsedThumbs).toHaveLength(2)
    // Smart label wins over overlapping motion at 10.5s
    expect(findNearestScrubberThumbnail(parsedThumbs, segments, 10.5, 60)).toEqual({
      thumbnailUrl: "/api/cameras/cam-1/timeline/thumbnails/block/b1.jpg",
      label: "Person",
      category: "person",
    })
    // Motion-only segment at 42s still reports "Motion" label
    expect(findNearestScrubberThumbnail(parsedThumbs, segments, 42, 60)).toEqual({
      thumbnailUrl: "/api/cameras/cam-1/timeline/thumbnails/frame/v1.jpg",
      label: "Motion",
      category: "motion",
    })
    expect(findNearestScrubberThumbnail(parsedThumbs, segments, 30.2, 60)).toEqual({
      thumbnailUrl: "/api/cameras/cam-1/timeline/thumbnails/frame/a1.jpg",
      label: "Animal",
      category: "animal",
    })
    expect(
      buildScrubberHoverMarkup({
        hoverSec: 30,
        thumbnailUrl: "/api/cameras/cam-1/timeline/thumbnails/frame/a1.jpg",
        label: "Animal",
      })
    ).toContain('data-role="scrubber-hover-thumb"')

    const trackListeners = new Map()
    const filmstripListeners = new Map()
    const tooltipListeners = new Map()
    const scrubberAttrs = new Map()
    const scrubber = {
      setAttribute: vi.fn((k, v) => scrubberAttrs.set(k, v)),
      getAttribute: k => scrubberAttrs.get(k),
    }
    const scrubberTrack = {
      getBoundingClientRect: () => ({left: 100, width: 400}),
      addEventListener: vi.fn((ev, fn) => trackListeners.set(ev, fn)),
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn(),
    }
    const scrubberFilmstrip = {
      innerHTML: "",
      addEventListener: vi.fn((ev, fn) => filmstripListeners.set(ev, fn)),
    }
    const scrubberBuffered = {style: {width: "0%"}}
    const scrubberProgress = {style: {width: "0%"}}
    const scrubberPlayhead = {style: {left: "0%"}}
    const scrubberEvents = {innerHTML: ""}
    const scrubberTicks = {innerHTML: ""}
    const scrubberHoverLine = {style: {left: "0%"}, hidden: true}
    const scrubberHoverTooltip = {
      style: {left: "0%"},
      innerHTML: "",
      hidden: true,
      addEventListener: vi.fn((ev, fn) => tooltipListeners.set(ev, fn)),
    }

    const {el, video} = makeElement({
      windowStartUs: "1000000000",
      windowEndUs: "1060000000",
      overlayDetections: JSON.stringify([
        {
          visual_frame_id: "frame-p1",
          offset_seconds: 12,
          time_basis: "received",
          object_class: "person",
          score: 0.93,
          bbox: [0.1, 0.2, 0.3, 0.8],
        },
      ]),
    })
    el.dataset.windowEvents = JSON.stringify([
      {category: "motion", label: "Motion", start_offset_seconds: 45, end_offset_seconds: 48},
      {
        category: "person",
        label: "Person",
        start_offset_seconds: 12,
        end_offset_seconds: 15,
        confidence: 0.93,
        thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/frame/p1.jpg",
      },
    ])
    el.dataset.windowThumbnails = JSON.stringify([
      {offset_seconds: 12, thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/frame/p1.jpg", label: "Person"},
      {offset_seconds: 30, thumbnail_url: "/api/cameras/cam-1/timeline/thumbnails/block/b2.jpg", label: null},
    ])
    video.buffered = {length: 1, end: () => 30}

    const origQuerySelector = el.querySelector
    el.querySelector = selector => {
      if (selector === "[data-role='playback-scrubber']") return scrubber
      if (selector === "[data-role='scrubber-track']") return scrubberTrack
      if (selector === "[data-role='scrubber-filmstrip']") return scrubberFilmstrip
      if (selector === "[data-role='scrubber-buffered']") return scrubberBuffered
      if (selector === "[data-role='scrubber-progress']") return scrubberProgress
      if (selector === "[data-role='scrubber-playhead']") return scrubberPlayhead
      if (selector === "[data-role='scrubber-events']") return scrubberEvents
      if (selector === "[data-role='scrubber-ticks']") return scrubberTicks
      if (selector === "[data-role='scrubber-hover-line']") return scrubberHoverLine
      if (selector === "[data-role='scrubber-hover-tooltip']") return scrubberHoverTooltip
      return origQuerySelector(selector)
    }

    const {FakeHls} = makeFakeHls()
    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.mounted()

    // Both subtle 2px Motion hairlines (tier=motion) and crisp Smart bars (tier=smart) render, with Motion underneath Smart
    expect(scrubberEvents.innerHTML).toContain('data-role="scrubber-event-segment"')
    expect(scrubberEvents.innerHTML).toContain('data-event-tier="motion" data-event-category="motion"')
    expect(scrubberEvents.innerHTML).toContain("bottom-0 h-[2px] z-[3]")
    expect(scrubberEvents.innerHTML).toContain('title="Motion · 00:45"')
    expect(scrubberEvents.innerHTML).toContain('data-event-tier="smart" data-event-category="person"')
    expect(scrubberEvents.innerHTML).toContain("bottom-0.5 h-1.5 z-[4]")
    expect(scrubberEvents.innerHTML.indexOf('data-event-tier="motion"')).toBeLessThan(
      scrubberEvents.innerHTML.indexOf('data-event-tier="smart"')
    )
    expect(scrubberFilmstrip.innerHTML).toContain('data-role="scrubber-filmstrip-thumb"')
    expect(scrubberFilmstrip.innerHTML).toContain("/api/cameras/cam-1/timeline/thumbnails/frame/p1.jpg")
    expect(scrubberTicks.innerHTML).toContain("00:00")
    expect(scrubberTicks.innerHTML).toContain("01:00")

    // Broken image error listener hides failed thumbnails cleanly
    const brokenImg = {tagName: "IMG", hidden: false}
    filmstripListeners.get("error")({target: brokenImg})
    expect(brokenImg.hidden).toBe(true)

    // Progress & buffered range sync on timeupdate
    video.currentTime = 15
    video.emit("timeupdate")
    expect(scrubberPlayhead.style.left).toBe("25.000%")
    expect(scrubberProgress.style.width).toBe("25.000%")
    expect(scrubberBuffered.style.width).toBe("50.00%")

    // Clicking directly on an event bar seeks immediately to that bar's start second
    trackListeners.get("pointerdown")({
      clientX: 200,
      pointerId: 1,
      target: {
        closest: sel =>
          sel === "[data-role='scrubber-event-segment']"
            ? {dataset: {seekSeconds: "12.000"}, getAttribute: () => "Person · 00:12 · 93%"}
            : null,
      },
    })
    expect(video.currentTime).toBe(12)

    // Dragging/hovering across the scrubber track renders live thumbnail preview card with timestamp
    trackListeners.get("pointermove")({
      clientX: 300,
      target: {closest: () => null},
    })
    expect(video.currentTime).toBe(30)
    expect(scrubberHoverLine.hidden).toBe(false)
    expect(scrubberHoverTooltip.hidden).toBe(false)
    expect(scrubberHoverTooltip.innerHTML).toContain('data-role="scrubber-hover-card"')
    expect(scrubberHoverTooltip.innerHTML).toContain("/api/cameras/cam-1/timeline/thumbnails/block/b2.jpg")
    expect(scrubberHoverTooltip.innerHTML).toContain("00:30")

    // Hovering near the far-left edge clamps the preview card inside the scrubber track bounds
    trackListeners.get("pointermove")({
      clientX: 102,
      target: {closest: () => null},
    })
    expect(scrubberHoverTooltip.style.left).toBe("18%")

    trackListeners.get("pointerup")({pointerId: 1})
    trackListeners.get("pointerleave")()
    expect(scrubberHoverLine.hidden).toBe(true)
    expect(scrubberHoverTooltip.hidden).toBe(true)

    hook.destroyed()
  })

  it("avoids 60fps DOM thrash: skips buffered queries during syncScrubberPosition, throttles aria attributes to 1Hz, and caches overlay SVG markup", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    const bufferedEnd = vi.fn(() => 30)
    const scrubberSetAttr = vi.fn()
    const scrubber = {setAttribute: scrubberSetAttr, addEventListener: vi.fn()}
    let widthWrites = 0
    let leftWrites = 0
    let currentWidth = ""
    let currentLeft = ""
    const scrubberProgress = {
      style: {
        get width() {
          return currentWidth
        },
        set width(val) {
          widthWrites += 1
          currentWidth = val
        },
      },
    }
    const scrubberPlayhead = {
      style: {
        get left() {
          return currentLeft
        },
        set left(val) {
          leftWrites += 1
          currentLeft = val
        },
      },
    }
    const scrubberBuffered = {style: {width: "0%"}}

    const {el, video, overlay} = makeElement({
      windowStartUs: "1000000000",
      windowEndUs: "1060000000",
      overlayDetections: JSON.stringify([
        {
          visual_frame_id: "frame-p1",
          offset_seconds: 10,
          time_basis: "received",
          object_class: "person",
          score: 0.9,
          bbox: [0.1, 0.2, 0.3, 0.8],
        },
      ]),
    })
    video.buffered = {length: 1, end: bufferedEnd}

    let overlayInnerHtmlWrites = 0
    let currentOverlayHtml = ""
    Object.defineProperty(overlay, "innerHTML", {
      get: () => currentOverlayHtml,
      set: val => {
        overlayInnerHtmlWrites += 1
        currentOverlayHtml = val
      },
    })

    const origQuerySelector = el.querySelector
    el.querySelector = selector => {
      if (selector === "[data-role='playback-scrubber']") return scrubber
      if (selector === "[data-role='scrubber-buffered']") return scrubberBuffered
      if (selector === "[data-role='scrubber-progress']") return scrubberProgress
      if (selector === "[data-role='scrubber-playhead']") return scrubberPlayhead
      return origQuerySelector(selector)
    }

    const {FakeHls} = makeFakeHls()
    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.mounted()

    video.currentTime = 10.1
    video.emit("loadedmetadata")
    expect(scrubberBuffered.style.width).toBe("50.00%")

    // Reset counters after initial mount/metadata
    bufferedEnd.mockClear()
    scrubberSetAttr.mockClear()
    overlayInnerHtmlWrites = 0
    widthWrites = 0
    leftWrites = 0

    // Repeated syncScrubberPosition at same time does zero DOM writes and never queries video.buffered
    hook.syncScrubberPosition()
    hook.syncScrubberPosition()
    expect(bufferedEnd).not.toHaveBeenCalled()
    expect(widthWrites).toBe(0)
    expect(leftWrites).toBe(0)
    expect(scrubberSetAttr).not.toHaveBeenCalled()

    // Sub-second advance within the same rounded integer second updates progress/playhead once without touching aria
    video.currentTime = 10.25
    hook.syncScrubberPosition()
    expect(bufferedEnd).not.toHaveBeenCalled()
    expect(widthWrites).toBe(1)
    expect(leftWrites).toBe(1)
    expect(scrubberSetAttr).not.toHaveBeenCalled()

    // Crossing into next rounded integer second updates aria-valuenow once
    video.currentTime = 10.6
    hook.syncScrubberPosition()
    expect(scrubberSetAttr).toHaveBeenCalledTimes(1)
    expect(scrubberSetAttr).toHaveBeenCalledWith("aria-valuenow", "11")

    // progress event updates buffered bar
    bufferedEnd.mockReturnValue(45)
    video.emit("progress")
    expect(bufferedEnd).toHaveBeenCalledTimes(1)
    expect(scrubberBuffered.style.width).toBe("75.00%")

    // Repeated renderOverlay with unchanged active detection skips innerHTML assignment
    hook.renderOverlay()
    hook.renderOverlay()
    expect(overlayInnerHtmlWrites).toBe(0)

    hook.destroyed()
  })

  it("syncs bounding-box overlays, scrubber segments, and initial seek to HLS #EXT-X-PROGRAM-DATE-TIME across a 3.5s GOP lead-in", () => {
    vi.stubGlobal("window", {addEventListener: vi.fn()})

    const windowStartUs = 1_000_000_000 // 1000.0s
    const detectionUs = windowStartUs + 5_000_000 // 1005.0s (windowStartUs + 5.0s)

    const {el, video, overlay} = makeElement({
      windowStartUs: String(windowStartUs),
      windowEndUs: String(windowStartUs + 20_000_000),
      seekOffsetSeconds: "5.0",
      overlayDetections: JSON.stringify([
        {
          visual_frame_id: "frame-pdt-1",
          timeline_ts_us: detectionUs,
          offset_seconds: 5.0,
          time_basis: "received",
          object_class: "person",
          score: 0.94,
          bbox: [0.2, 0.2, 0.5, 0.8],
        },
      ]),
    })
    el.dataset.windowEvents = JSON.stringify([
      {
        category: "person",
        label: "Person",
        start_us: detectionUs,
        end_us: detectionUs + 2_000_000,
        start_offset_seconds: 5.0,
        end_offset_seconds: 7.0,
        confidence: 0.94,
      },
    ])

    const scrubberEvents = {innerHTML: ""}
    const origQuerySelector = el.querySelector
    el.querySelector = selector => {
      if (selector === "[data-role='scrubber-events']") return scrubberEvents
      return origQuerySelector(selector)
    }

    const {FakeHls, instances} = makeFakeHls()
    const hook = Object.create(CameraTimelinePlayer)
    hook.el = el
    hook.hlsClass = FakeHls
    hook.mounted()

    // HLS playlist starts 3.5s BEFORE windowStartUs (whole GOP lead-in)
    instances[0].emit(FakeHls.Events.LEVEL_LOADED, {
      details: {
        fragments: [
          {start: 0.0, duration: 5.0, programDateTime: 996_500},
          {start: 5.0, duration: 5.0, programDateTime: 1_001_500},
          {start: 10.0, duration: 5.0, programDateTime: 1_006_500},
        ],
      },
    })

    // Initial seek lands at 8.5s (3.5s GOP lead-in + 5.0s offset), NOT 5.0s
    video.emit("loadedmetadata")
    expect(video.currentTime).toBeCloseTo(8.5, 3)
    expect(overlay.innerHTML).toContain("person 94% · received")

    // Scrubber event segment is shifted to 8.500s to match the actual HLS playback clock
    expect(scrubberEvents.innerHTML).toContain('data-seek-seconds="8.500"')

    // At currentTime = 5.0s (wall clock = windowStartUs + 1.5s), detection at windowStartUs + 5.0s is NOT shown
    video.currentTime = 5.0
    video.emit("timeupdate")
    expect(overlay.innerHTML).toBe("")

    // At currentTime = 8.5s (wall clock = windowStartUs + 5.0s), detection IS shown
    video.currentTime = 8.5
    video.emit("timeupdate")
    expect(overlay.innerHTML).toContain("person 94% · received")

    hook.destroyed()
    expect(hook.fragmentPdtRanges).toEqual([])
  })

  it("maps playback time cleanly across a 30s HLS discontinuity gap and falls back gracefully when PDT ranges are empty", () => {
    const ranges = extractFragmentPdtRanges({
      fragments: [
        {start: 0.0, duration: 4.0, programDateTime: 1_000_000}, // 1000s..1004s
        {start: 4.0, duration: 4.0, programDateTime: 1_034_000}, // 1034s..1038s (30s gap)
        {start: 8.0, duration: 4.0, programDateTime: null}, // ignored
      ],
    })

    expect(ranges).toEqual([
      {startSec: 0, endSec: 4, startUs: 1_000_000_000, endUs: 1_004_000_000},
      {startSec: 4, endSec: 8, startUs: 1_034_000_000, endUs: 1_038_000_000},
    ])

    // Pre-gap playback
    expect(resolvePlaybackTimelineUs(3.5, ranges)).toBe(1_003_500_000)
    // Boundary at discontinuity jumps cleanly across the 30s gap
    expect(resolvePlaybackTimelineUs(4.0, ranges)).toBe(1_034_000_000)
    // Post-gap playback
    expect(resolvePlaybackTimelineUs(6.0, ranges)).toBe(1_036_000_000)
    expect(resolveTimelineUsToPlaybackSeconds(1_036_000_000, ranges)).toBeCloseTo(6.0, 5)

    const detections = parseOverlayDetections(
      JSON.stringify([
        {
          visual_frame_id: "pre-gap",
          timeline_ts_us: 1_003_000_000,
          object_class: "vehicle",
          score: 0.88,
          bbox: [0.1, 0.1, 0.4, 0.4],
        },
        {
          visual_frame_id: "post-gap",
          timeline_ts_us: 1_036_000_000,
          object_class: "person",
          score: 0.92,
          bbox: [0.3, 0.2, 0.6, 0.8],
        },
      ]),
      {windowStartUs: 1_000_000_000}
    )

    expect(detections[0].timelineTsUs).toBe(1_003_000_000)
    expect(detections[1].timelineTsUs).toBe(1_036_000_000)
    // Naive offsetSeconds for post-gap would be 36.0s, which would miss currentTime = 6.0s
    expect(detections[1].offsetSeconds).toBe(36)

    const postGapActive = selectActiveDetections(detections, 6.0, {
      currentTimelineUs: resolvePlaybackTimelineUs(6.0, ranges),
    })
    expect(postGapActive.map(d => d.visualFrameId)).toEqual(["post-gap"])

    const scrubberSegments = buildScrubberEventSegments(detections, [], 8.0, {
      fragmentPdtRanges: ranges,
    })
    expect(scrubberSegments.find(s => s.category === "person")?.startSec).toBeCloseTo(6.0, 3)

    // Graceful fallback when fragmentPdtRanges is empty (native HLS / tests)
    expect(resolvePlaybackTimelineUs(5.0, [])).toBeNull()
    expect(resolveTimelineUsToPlaybackSeconds(1_005_000_000, [])).toBeNull()
    const fallbackActive = selectActiveDetections(detections, 3.0, {
      currentTimelineUs: null,
    })
    expect(fallbackActive.map(d => d.visualFrameId)).toEqual(["pre-gap"])
  })
})
