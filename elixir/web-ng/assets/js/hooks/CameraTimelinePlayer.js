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

export function extractFragmentPdtRanges(levelDetails) {
  const fragments = Array.isArray(levelDetails) ? levelDetails : levelDetails?.fragments
  if (!Array.isArray(fragments) || fragments.length === 0) return []

  const ranges = []
  for (const frag of fragments) {
    if (!frag || typeof frag !== "object") continue
    const startSec = Number(frag.start)
    const duration = Number(frag.duration)
    const pdtMs = frag.programDateTime === null || frag.programDateTime === undefined ? Number.NaN : Number(frag.programDateTime)
    if (!Number.isFinite(startSec) || !Number.isFinite(duration) || duration <= 0 || !Number.isFinite(pdtMs)) {
      continue
    }
    const startUs = Math.round(pdtMs * 1000)
    const endUs = Math.round(startUs + duration * 1_000_000)
    ranges.push({
      startSec,
      endSec: startSec + duration,
      startUs,
      endUs,
    })
  }

  ranges.sort((a, b) => a.startSec - b.startSec)
  return ranges
}

export function resolvePlaybackTimelineUs(currentTimeSec, fragmentPdtRanges) {
  const t = Number(currentTimeSec)
  if (!Number.isFinite(t) || !Array.isArray(fragmentPdtRanges) || fragmentPdtRanges.length === 0) {
    return null
  }

  const lastIndex = fragmentPdtRanges.length - 1
  for (let i = 0; i <= lastIndex; i += 1) {
    const frag = fragmentPdtRanges[i]
    const within = i === lastIndex ? t >= frag.startSec && t <= frag.endSec : t >= frag.startSec && t < frag.endSec
    if (within) {
      return Math.round(frag.startUs + (t - frag.startSec) * 1_000_000)
    }
  }

  let nearest = null
  let nearestDist = Number.POSITIVE_INFINITY
  for (const frag of fragmentPdtRanges) {
    const dist = t < frag.startSec ? frag.startSec - t : t > frag.endSec ? t - frag.endSec : 0
    if (dist < nearestDist) {
      nearestDist = dist
      nearest = frag
    }
  }

  if (!nearest) return null
  return Math.round(nearest.startUs + (t - nearest.startSec) * 1_000_000)
}

export function resolveTimelineUsToPlaybackSeconds(targetUs, fragmentPdtRanges) {
  const ts = Number(targetUs)
  if (!Number.isFinite(ts) || !Array.isArray(fragmentPdtRanges) || fragmentPdtRanges.length === 0) {
    return null
  }

  const first = fragmentPdtRanges[0]
  if (ts < first.startUs) {
    return first.startSec + (ts - first.startUs) / 1_000_000
  }

  const lastIndex = fragmentPdtRanges.length - 1
  for (let i = 0; i <= lastIndex; i += 1) {
    const frag = fragmentPdtRanges[i]
    const within = i === lastIndex ? ts >= frag.startUs && ts <= frag.endUs : ts >= frag.startUs && ts < frag.endUs
    if (within) {
      return frag.startSec + (ts - frag.startUs) / 1_000_000
    }
    if (i < lastIndex) {
      const next = fragmentPdtRanges[i + 1]
      if (ts >= frag.endUs && ts < next.startUs) {
        return ts - frag.endUs <= next.startUs - ts ? frag.endSec : next.startSec
      }
    }
  }

  const last = fragmentPdtRanges[lastIndex]
  return last.endSec + (ts - last.endUs) / 1_000_000
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

    const rawTsUs =
      item.timeline_ts_us ??
      item.timelineTsUs ??
      item.best_timeline_ts_us ??
      parent.timeline_ts_us ??
      parent.timelineTsUs ??
      parent.best_timeline_ts_us
    const parsedTsUs =
      rawTsUs !== null && rawTsUs !== undefined && String(rawTsUs).trim() !== "" ? Number(rawTsUs) : Number.NaN
    const timelineTsUs = Number.isFinite(parsedTsUs) ? parsedTsUs : null

    let offsetSeconds = Number(item.offset_seconds ?? item.offsetSeconds ?? parent.offset_seconds ?? parent.offsetSeconds)
    if (!Number.isFinite(offsetSeconds)) {
      if (timelineTsUs !== null && Number.isFinite(winStart)) {
        offsetSeconds = Math.max(0, (timelineTsUs - winStart) / 1_000_000)
      } else {
        offsetSeconds = 0
      }
    }

    const rawScore = Number(item.score ?? item.confidence ?? item.similarity ?? parent.score ?? parent.similarity)
    const score = Number.isFinite(rawScore) ? Math.min(1, Math.max(0, rawScore)) : null

    normalized.push({
      visualFrameId: String(item.visual_frame_id ?? item.visualFrameId ?? parent.visual_frame_id ?? parent.visualFrameId ?? ""),
      offsetSeconds,
      timelineTsUs,
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
  {highlightFrameId = null, toleranceSeconds = 1.5, metadataLoaded = true, currentTimelineUs = null} = {}
) {
  if (!Array.isArray(detections) || detections.length === 0) return []
  const highlightId = highlightFrameId ? String(highlightFrameId) : ""

  if (!metadataLoaded && highlightId !== "") {
    const highlighted = detections.filter(d => d.visualFrameId === highlightId)
    if (highlighted.length > 0) return highlighted
  }

  const nowSec = Number(currentTimeSeconds)
  if (!Number.isFinite(nowSec)) return []

  const nowUs =
    currentTimelineUs !== null && currentTimelineUs !== undefined && Number.isFinite(Number(currentTimelineUs))
      ? Number(currentTimelineUs)
      : null

  const distanceSeconds = det => {
    if (nowUs !== null && det.timelineTsUs !== null && Number.isFinite(det.timelineTsUs)) {
      return Math.abs(det.timelineTsUs - nowUs) / 1_000_000
    }
    return Math.abs(det.offsetSeconds - nowSec)
  }

  const inWindow = detections.filter(d => distanceSeconds(d) <= toleranceSeconds)
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

    const dist = distanceSeconds(det)
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

const ADJACENT_PREFETCH_THRESHOLD_SECONDS = 1.0

const SMART_SCRUBBER_CATEGORIES = new Set(["person", "animal", "vehicle", "package", "object"])
const SCRUBBER_EVENT_CATEGORIES = new Set(["person", "animal", "vehicle", "package", "object", "motion"])

const SCRUBBER_CATEGORY_STYLES = {
  person: {label: "Person", tier: "smart", bg: "bg-sky-400/90 hover:bg-sky-300", ring: "ring-sky-300/60"},
  animal: {label: "Animal", tier: "smart", bg: "bg-amber-400/90 hover:bg-amber-300", ring: "ring-amber-300/60"},
  vehicle: {label: "Vehicle", tier: "smart", bg: "bg-cyan-400/90 hover:bg-cyan-300", ring: "ring-cyan-300/60"},
  package: {label: "Package", tier: "smart", bg: "bg-violet-400/90 hover:bg-violet-300", ring: "ring-violet-300/60"},
  object: {label: "Detection", tier: "smart", bg: "bg-emerald-400/90 hover:bg-emerald-300", ring: "ring-emerald-300/60"},
  motion: {label: "Motion", tier: "motion", bg: "bg-slate-200/55 hover:bg-white/90", ring: ""},
}

export function isSmartScrubberCategory(category) {
  return SMART_SCRUBBER_CATEGORIES.has(category)
}

export function isScrubberEventCategory(category) {
  return SCRUBBER_EVENT_CATEGORIES.has(category)
}

export function isSafeThumbnailUrl(url) {
  if (typeof url !== "string") return false
  const trimmed = url.trim()
  if (trimmed === "") return false
  return /^(\/(?!\/)|https?:\/\/)/i.test(trimmed)
}

export function normalizeEventCategory(rawClass) {
  const normalized = String(rawClass ?? "").trim().toLowerCase()
  if (!normalized) return "object"
  if (normalized.includes("person") || normalized.includes("human") || normalized.includes("pedestrian")) {
    return "person"
  }
  if (
    normalized.includes("vehicle") ||
    normalized.includes("car") ||
    normalized.includes("truck") ||
    normalized.includes("bus") ||
    normalized.includes("van") ||
    normalized.includes("motorcycle") ||
    normalized.includes("bicycle")
  ) {
    return "vehicle"
  }
  if (
    normalized.includes("animal") ||
    normalized.includes("dog") ||
    normalized.includes("cat") ||
    normalized.includes("bird") ||
    normalized.includes("pet") ||
    normalized.includes("deer")
  ) {
    return "animal"
  }
  if (normalized.includes("package") || normalized.includes("parcel") || normalized.includes("box")) {
    return "package"
  }
  if (normalized.includes("motion")) {
    return "motion"
  }
  return "object"
}

export function formatScrubberTime(seconds) {
  const sec = Math.max(0, Math.floor(Number(seconds) || 0))
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = sec % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
  }
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
}

export function computeScrubberFraction(clientX, rect) {
  if (!rect || !Number.isFinite(rect.width) || rect.width <= 0) return null
  const raw = (clientX - rect.left) / rect.width
  const clamped = Math.min(1, Math.max(0, raw))
  return Number(clamped.toFixed(6))
}

export function parseScrubberEvents(rawJson, {windowStartUs = null} = {}) {
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

  const out = []
  for (const item of parsed) {
    if (!item || typeof item !== "object") continue

    const rawStartUs = item.start_us ?? item.peak_ts_us ?? item.timeline_ts_us
    const parsedStartUs =
      rawStartUs !== null && rawStartUs !== undefined && String(rawStartUs).trim() !== ""
        ? Number(rawStartUs)
        : Number.NaN
    const startUs = Number.isFinite(parsedStartUs) ? parsedStartUs : null

    const rawEndUs = item.end_us
    const parsedEndUs =
      rawEndUs !== null && rawEndUs !== undefined && String(rawEndUs).trim() !== ""
        ? Number(rawEndUs)
        : Number.NaN
    const endUs = Number.isFinite(parsedEndUs) ? parsedEndUs : startUs

    let startSec = Number(item.start_offset_seconds ?? item.offset_seconds ?? item.offsetSeconds)
    if (!Number.isFinite(startSec)) {
      if (startUs !== null && Number.isFinite(winStart)) {
        startSec = Math.max(0, (startUs - winStart) / 1_000_000)
      }
    }
    if (!Number.isFinite(startSec)) continue

    let endSec = Number(item.end_offset_seconds)
    if (!Number.isFinite(endSec)) {
      if (endUs !== null && Number.isFinite(winStart)) {
        endSec = Math.max(startSec, (endUs - winStart) / 1_000_000)
      } else {
        endSec = startSec
      }
    }

    const rawCategory = String(item.category ?? item.object_class ?? item.class ?? item.label ?? "")
      .trim()
      .toLowerCase()
    if (!rawCategory || rawCategory === "recording") continue
    const category = normalizeEventCategory(rawCategory)
    if (!isScrubberEventCategory(category)) continue

    const rawScore = Number(item.score ?? item.confidence)
    const score = Number.isFinite(rawScore)
      ? Math.min(1, Math.max(0, rawScore > 1 ? rawScore / 100 : rawScore))
      : null

    const rawThumb = item.thumbnail_url ?? item.thumbnailUrl
    const thumbnailUrl = isSafeThumbnailUrl(rawThumb) ? rawThumb.trim() : null

    out.push({
      startSec: Math.max(0, startSec),
      endSec: Math.max(startSec, endSec),
      startUs,
      endUs,
      category,
      label: String(item.label ?? item.object_class ?? item.category ?? "Event"),
      score,
      thumbnailUrl,
    })
  }

  return out
}

export function parseScrubberThumbnails(rawJson, {windowStartUs = null} = {}) {
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

  const out = []
  for (const item of parsed) {
    if (!item || typeof item !== "object") continue
    const rawThumb = item.thumbnail_url ?? item.thumbnailUrl
    if (!isSafeThumbnailUrl(rawThumb)) continue

    const rawTsUs = item.ts_us ?? item.timeline_ts_us ?? item.peak_ts_us
    const parsedTsUs =
      rawTsUs !== null && rawTsUs !== undefined && String(rawTsUs).trim() !== ""
        ? Number(rawTsUs)
        : Number.NaN
    const tsUs = Number.isFinite(parsedTsUs) ? parsedTsUs : null

    let offsetSeconds = Number(item.offset_seconds ?? item.offsetSeconds)
    if (!Number.isFinite(offsetSeconds)) {
      if (tsUs !== null && Number.isFinite(winStart)) {
        offsetSeconds = Math.max(0, (tsUs - winStart) / 1_000_000)
      }
    }
    if (!Number.isFinite(offsetSeconds)) continue

    const rawLabel = item.label ?? item.object_class ?? null
    const label = typeof rawLabel === "string" && rawLabel.trim() !== "" ? rawLabel.trim() : null

    out.push({
      offsetSeconds: Math.max(0, offsetSeconds),
      tsUs,
      thumbnailUrl: rawThumb.trim(),
      label,
    })
  }

  out.sort((a, b) => a.offsetSeconds - b.offsetSeconds)
  return out
}

export function clampHoverTooltipPercent(fraction, trackWidthPx, cardWidthPx = 144) {
  const clampedFraction = Math.min(1, Math.max(0, Number(fraction) || 0))
  const width = Number(trackWidthPx)
  if (Number.isFinite(width) && width > cardWidthPx) {
    const halfFrac = cardWidthPx / 2 / width
    const bounded = Math.min(1 - halfFrac, Math.max(halfFrac, clampedFraction))
    return Number((bounded * 100).toFixed(2))
  }
  return Number((clampedFraction * 100).toFixed(2))
}

export function findNearestScrubberThumbnail(thumbnails = [], segments = [], hoverSec = 0, durationSeconds = 0) {
  const targetSec = Number(hoverSec)
  const duration = Number(durationSeconds)
  if (!Number.isFinite(targetSec)) {
    return {thumbnailUrl: null, label: null, category: null}
  }

  const eventTolerance = Number.isFinite(duration) && duration > 0 ? Math.max(1.5, duration * 0.02) : 1.5
  let matchedSmartSegment = null
  let matchedSmartDistance = Number.POSITIVE_INFINITY
  let matchedMotionSegment = null
  let matchedMotionDistance = Number.POSITIVE_INFINITY

  if (Array.isArray(segments)) {
    for (const seg of segments) {
      if (!seg || !isScrubberEventCategory(seg.category)) continue
      const inRange = targetSec >= seg.startSec && targetSec <= seg.endSec
      const dist = inRange
        ? 0
        : Math.min(Math.abs(targetSec - seg.startSec), Math.abs(targetSec - seg.endSec))
      if (dist > eventTolerance) continue

      if (isSmartScrubberCategory(seg.category)) {
        if (dist < matchedSmartDistance) {
          matchedSmartDistance = dist
          matchedSmartSegment = seg
        }
      } else if (dist < matchedMotionDistance) {
        matchedMotionDistance = dist
        matchedMotionSegment = seg
      }
    }
  }

  const matchedSegment = matchedSmartSegment || matchedMotionSegment

  if (matchedSegment?.thumbnailUrl) {
    return {
      thumbnailUrl: matchedSegment.thumbnailUrl,
      label: matchedSegment.label || null,
      category: matchedSegment.category || null,
    }
  }

  let bestThumb = null
  let bestThumbDist = Number.POSITIVE_INFINITY

  if (Array.isArray(thumbnails)) {
    for (const thumb of thumbnails) {
      if (!thumb || !thumb.thumbnailUrl || !Number.isFinite(thumb.offsetSeconds)) continue
      const dist = Math.abs(thumb.offsetSeconds - targetSec)
      if (dist < bestThumbDist) {
        bestThumbDist = dist
        bestThumb = thumb
      }
    }
  }

  if (Array.isArray(segments)) {
    for (const seg of segments) {
      if (!seg || !seg.thumbnailUrl || !Number.isFinite(seg.startSec)) continue
      const midSec = (seg.startSec + (seg.endSec ?? seg.startSec)) / 2
      const dist = Math.abs(midSec - targetSec)
      if (dist < bestThumbDist) {
        bestThumbDist = dist
        bestThumb = {thumbnailUrl: seg.thumbnailUrl, label: seg.label}
      }
    }
  }

  return {
    thumbnailUrl: bestThumb?.thumbnailUrl || null,
    label: matchedSegment?.label || null,
    category: matchedSegment?.category || null,
  }
}

export function buildScrubberHoverMarkup({hoverSec = 0, thumbnailUrl = null, label = null, segTitle = null} = {}) {
  const timeText = escapeOverlayText(formatScrubberTime(hoverSec))
  if (thumbnailUrl && isSafeThumbnailUrl(thumbnailUrl)) {
    const safeSrc = escapeOverlayText(thumbnailUrl.trim())
    const labelText = label ? escapeOverlayText(label) : ""
    const labelBadge = labelText
      ? `<span data-role="scrubber-hover-label" class="truncate rounded bg-sky-500/25 px-1 py-0.5 text-[9px] font-medium text-sky-200">${labelText}</span>`
      : ""
    return (
      `<div data-role="scrubber-hover-card" class="flex flex-col items-center gap-1">` +
      `<img data-role="scrubber-hover-thumb" src="${safeSrc}" alt="" loading="eager" decoding="async" draggable="false" ` +
      `class="h-[72px] w-32 rounded object-cover bg-zinc-950" />` +
      `<div class="flex max-w-32 items-center justify-center gap-1.5 px-0.5 leading-tight">` +
      `<span data-role="scrubber-hover-time" class="font-mono text-[10px] font-semibold text-white">${timeText}</span>` +
      `${labelBadge}` +
      `</div>` +
      `</div>`
    )
  }

  const fallbackText = escapeOverlayText(segTitle || formatScrubberTime(hoverSec))
  return `<span data-role="scrubber-hover-time" class="whitespace-nowrap px-1 py-0.5 font-mono text-[10px] font-medium text-white">${fallbackText}</span>`
}

export function buildScrubberEventSegments(
  detections = [],
  windowEvents = [],
  durationSeconds = 0,
  {mergeGapSeconds = 2.0, minWidthPct = 1.4, fragmentPdtRanges = null} = {}
) {
  const duration = Number(durationSeconds)
  if (!Number.isFinite(duration) || duration <= 0) return []

  const hasPdt = Array.isArray(fragmentPdtRanges) && fragmentPdtRanges.length > 0
  const rawPoints = []

  if (Array.isArray(detections)) {
    for (const det of detections) {
      if (!det) continue
      const mappedSec =
        hasPdt && det.timelineTsUs !== null && Number.isFinite(det.timelineTsUs)
          ? resolveTimelineUsToPlaybackSeconds(det.timelineTsUs, fragmentPdtRanges)
          : det.offsetSeconds
      if (!Number.isFinite(mappedSec) || mappedSec < 0 || mappedSec > duration) continue
      const category = normalizeEventCategory(det.objectClass)
      if (!isScrubberEventCategory(category)) continue
      rawPoints.push({
        startSec: mappedSec,
        endSec: mappedSec,
        category,
        label: SCRUBBER_CATEGORY_STYLES[category]?.label || det.objectClass || "Detection",
        score: Number.isFinite(det.score) ? det.score : null,
        thumbnailUrl: isSafeThumbnailUrl(det.thumbnailUrl) ? det.thumbnailUrl.trim() : null,
      })
    }
  }

  if (Array.isArray(windowEvents)) {
    for (const evt of windowEvents) {
      if (!evt) continue
      const startSec =
        hasPdt && evt.startUs !== null && Number.isFinite(evt.startUs)
          ? resolveTimelineUsToPlaybackSeconds(evt.startUs, fragmentPdtRanges)
          : evt.startSec
      const rawEndSec =
        hasPdt && evt.endUs !== null && Number.isFinite(evt.endUs)
          ? resolveTimelineUsToPlaybackSeconds(evt.endUs, fragmentPdtRanges)
          : evt.endSec ?? startSec
      if (!Number.isFinite(startSec)) continue
      const endSec = Number.isFinite(rawEndSec) ? rawEndSec : startSec
      const clampedStart = Math.min(duration, Math.max(0, startSec))
      const clampedEnd = Math.min(duration, Math.max(clampedStart, endSec))
      if (endSec < 0 || startSec > duration) continue
      const category = normalizeEventCategory(evt.category)
      if (!isScrubberEventCategory(category)) continue
      rawPoints.push({
        startSec: clampedStart,
        endSec: clampedEnd,
        category,
        label: SCRUBBER_CATEGORY_STYLES[category]?.label || evt.label || "Event",
        score: Number.isFinite(evt.score) ? evt.score : null,
        thumbnailUrl: isSafeThumbnailUrl(evt.thumbnailUrl) ? evt.thumbnailUrl.trim() : null,
      })
    }
  }

  if (rawPoints.length === 0) return []

  // Group by category and merge adjacent points within mergeGapSeconds
  const byCategory = new Map()
  for (const pt of rawPoints) {
    if (!byCategory.has(pt.category)) byCategory.set(pt.category, [])
    byCategory.get(pt.category).push(pt)
  }

  const segments = []
  for (const [category, pts] of byCategory.entries()) {
    pts.sort((a, b) => a.startSec - b.startSec)
    let current = null

    for (const pt of pts) {
      if (!current) {
        current = {
          category,
          label: SCRUBBER_CATEGORY_STYLES[category]?.label || pt.label,
          startSec: pt.startSec,
          endSec: pt.endSec,
          maxScore: pt.score,
          thumbnailUrl: pt.thumbnailUrl || null,
          count: 1,
        }
      } else if (pt.startSec <= current.endSec + mergeGapSeconds) {
        current.endSec = Math.max(current.endSec, pt.endSec)
        if (pt.score !== null && (current.maxScore === null || pt.score > current.maxScore)) {
          current.maxScore = pt.score
          if (pt.thumbnailUrl) current.thumbnailUrl = pt.thumbnailUrl
        } else if (!current.thumbnailUrl && pt.thumbnailUrl) {
          current.thumbnailUrl = pt.thumbnailUrl
        }
        current.count += 1
      } else {
        segments.push(current)
        current = {
          category,
          label: SCRUBBER_CATEGORY_STYLES[category]?.label || pt.label,
          startSec: pt.startSec,
          endSec: pt.endSec,
          maxScore: pt.score,
          thumbnailUrl: pt.thumbnailUrl || null,
          count: 1,
        }
      }
    }
    if (current) segments.push(current)
  }

  const tierRank = seg => (SCRUBBER_CATEGORY_STYLES[seg.category]?.tier === "motion" ? 0 : 1)
  segments.sort((a, b) => {
    const tierDiff = tierRank(a) - tierRank(b)
    if (tierDiff !== 0) return tierDiff
    return a.startSec - b.startSec
  })

  return segments.map(seg => {
    const style = SCRUBBER_CATEGORY_STYLES[seg.category] || SCRUBBER_CATEGORY_STYLES.object
    const rawLeft = (seg.startSec / duration) * 100
    const rawWidth = ((seg.endSec - seg.startSec) / duration) * 100
    const widthPct = Math.min(100, Math.max(minWidthPct, rawWidth))
    const leftPct = Math.min(Math.max(0, rawLeft), Math.max(0, 100 - widthPct))
    const scorePart = seg.maxScore !== null ? ` · ${Math.round(seg.maxScore * 100)}%` : ""
    const timePart = formatScrubberTime(seg.startSec)
    return {
      ...seg,
      tier: style.tier || "smart",
      leftPct: Number(leftPct.toFixed(3)),
      widthPct: Number(widthPct.toFixed(3)),
      tooltip: `${seg.label} · ${timePart}${scorePart}`,
    }
  })
}

export default {
  mounted() {
    this.video = this.el.querySelector("[data-role='timeline-video']")
    this.videoContainer = this.el.querySelector("[data-role='timeline-video-container']")
    this.status = this.el.querySelector("[data-role='timeline-status']")
    this.retry = this.el.querySelector("[data-role='timeline-retry']")
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    this.overlay = this.el.querySelector("[data-role='semantic-bbox-overlay']")
    this.overlayToggle = this.el.querySelector("[data-role='toggle-bbox-overlay']")
    this.scrubber = this.el.querySelector("[data-role='playback-scrubber']")
    this.scrubberTrack = this.el.querySelector("[data-role='scrubber-track']")
    this.scrubberFilmstrip = this.el.querySelector("[data-role='scrubber-filmstrip']")
    this.scrubberBuffered = this.el.querySelector("[data-role='scrubber-buffered']")
    this.scrubberProgress = this.el.querySelector("[data-role='scrubber-progress']")
    this.scrubberPlayhead = this.el.querySelector("[data-role='scrubber-playhead']")
    this.scrubberEvents = this.el.querySelector("[data-role='scrubber-events']")
    this.scrubberTicks = this.el.querySelector("[data-role='scrubber-ticks']")
    this.scrubberHoverLine = this.el.querySelector("[data-role='scrubber-hover-line']")
    this.scrubberHoverTooltip = this.el.querySelector("[data-role='scrubber-hover-tooltip']")
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
    this.windowEvents = []
    this.windowThumbnails = []
    this.fragmentPdtRanges = []
    this.scrubberSegments = []
    this.scrubberDragging = false
    this.scrubberRafId = null
    this.lastScrubberPctStr = null
    this.lastScrubberAriaNow = null
    this.lastScrubberAriaMax = null
    this.lastHoverMarkup = null
    this.lastOverlayMarkup = null
    this.lastOverlayViewBox = null
    this.lastAppliedSeekAttr = ""
    this.pendingSeekOffsetSeconds = null
    this.lastSeekTargetOffsetSeconds = null
    this.seekAppliedWithPdt = false

    const options = {signal: this.listeners.signal}
    const hideBrokenThumb = event => {
      if (event?.target?.tagName === "IMG") {
        event.target.hidden = true
      }
    }
    this.scrubberFilmstrip?.addEventListener?.("error", hideBrokenThumb, {capture: true, signal: this.listeners.signal})
    this.scrubberHoverTooltip?.addEventListener?.("error", hideBrokenThumb, {capture: true, signal: this.listeners.signal})
    this.retry?.addEventListener("click", () => this.start(), options)
    this.overlayToggle?.addEventListener("click", () => this.toggleOverlay(), options)
    this.btnBack10?.addEventListener("click", () => this.stepSeconds(-10), options)
    this.btnPlayPause?.addEventListener("click", () => this.togglePlayPause(), options)
    this.btnFwd10?.addEventListener("click", () => this.stepSeconds(10), options)
    this.btnMute?.addEventListener("click", () => this.toggleMute(), options)
    this.btnFullscreen?.addEventListener("click", () => this.toggleFullscreen(), options)

    this.bindScrubberListeners(options)

    this.video?.addEventListener(
      "loadedmetadata",
      () => {
        this.metadataLoaded = true
        this.applyPendingSeek()
        this.renderScrubberEvents()
        this.syncScrubberBuffered()
        this.syncScrubberPosition()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "loadeddata",
      () => {
        this.report("Ready")
        this.syncScrubberPosition()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "progress",
      () => {
        this.syncScrubberBuffered()
      },
      options
    )
    this.video?.addEventListener(
      "playing",
      () => {
        this.report("Playing")
        this.syncTransportControls()
        this.startScrubberAnimation()
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
        this.syncScrubberPosition()
        this.maybeAdvanceWindow()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "timeupdate",
      () => {
        this.syncTransportControls()
        this.syncScrubberPosition()
        this.maybeAdvanceWindow()
        this.renderOverlay()
      },
      options
    )
    this.video?.addEventListener(
      "pause",
      () => {
        if (this.player) this.report("Paused")
        this.stopScrubberAnimation()
        this.syncTransportControls()
        this.syncScrubberPosition()
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
        this.stopScrubberAnimation()
        this.maybeAdvanceWindow()
        this.report("End of timeline window")
        this.syncScrubberPosition()
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
    this.renderScrubberEvents()
    this.syncScrubberBuffered()
    this.syncScrubberPosition()
    this.syncTransportControls()
    this.start()
  },

  updated() {
    this.copyBadge = this.el.querySelector("[data-role='served-copy-badge']")
    const nextOverlay = this.el.querySelector("[data-role='semantic-bbox-overlay']")
    if (nextOverlay !== this.overlay) {
      this.overlay = nextOverlay
      this.lastOverlayMarkup = null
      this.lastOverlayViewBox = null
    }
    this.overlayToggle = this.el.querySelector("[data-role='toggle-bbox-overlay']")
    this.syncOverlayDataset()
    this.syncOverlayToggleButton()
    this.renderScrubberEvents()
    this.syncScrubberBuffered()
    this.syncScrubberPosition()

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
      this.lastSeekTargetOffsetSeconds = null
      this.seekAppliedWithPdt = false
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
    this.stopScrubberAnimation()
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    this.listeners?.abort()
    this.stop()
  },

  bindScrubberListeners(options) {
    const track = this.scrubberTrack || this.scrubber
    if (!track) return

    const seekFromPointer = event => {
      const duration = this.effectiveDurationSeconds()
      if (duration <= 0) return
      const rect = track.getBoundingClientRect?.()
      const fraction = computeScrubberFraction(event.clientX, rect)
      if (fraction === null) return
      const targetSeconds = fraction * duration
      this.seekToSeconds(targetSeconds)
      this.updateScrubberHover(event, fraction)
    }

    track.addEventListener(
      "pointerdown",
      event => {
        const segEl = event.target?.closest?.("[data-role='scrubber-event-segment']")
        if (segEl && segEl.dataset?.seekSeconds !== undefined) {
          const seekSec = Number.parseFloat(segEl.dataset.seekSeconds)
          if (Number.isFinite(seekSec)) {
            this.seekToSeconds(seekSec)
          }
        } else {
          seekFromPointer(event)
        }
        this.scrubberDragging = true
        track.setPointerCapture?.(event.pointerId)
      },
      options
    )

    track.addEventListener(
      "pointermove",
      event => {
        const rect = track.getBoundingClientRect?.()
        const fraction = computeScrubberFraction(event.clientX, rect)
        if (fraction === null) return
        if (this.scrubberDragging) {
          const duration = this.effectiveDurationSeconds()
          if (duration > 0) this.seekToSeconds(fraction * duration)
        }
        this.updateScrubberHover(event, fraction)
      },
      options
    )

    const endDrag = event => {
      if (!this.scrubberDragging) return
      this.scrubberDragging = false
      track.releasePointerCapture?.(event.pointerId)
    }

    track.addEventListener("pointerup", endDrag, options)
    track.addEventListener("pointercancel", endDrag, options)
    track.addEventListener(
      "pointerleave",
      () => {
        if (this.scrubberHoverLine) this.scrubberHoverLine.hidden = true
        if (this.scrubberHoverTooltip) this.scrubberHoverTooltip.hidden = true
      },
      options
    )
  },

  effectiveDurationSeconds() {
    const videoDur = Number(this.video?.duration)
    if (Number.isFinite(videoDur) && videoDur > 0) return videoDur

    const startUs = Number(this.el.dataset?.windowStartUs)
    const endUs = Number(this.el.dataset?.windowEndUs)
    if (Number.isFinite(startUs) && Number.isFinite(endUs) && endUs > startUs) {
      return (endUs - startUs) / 1_000_000
    }
    return 0
  },

  seekToSeconds(seconds) {
    if (!this.video) return
    this.seekAppliedWithPdt = true
    const duration = this.effectiveDurationSeconds()
    const target = duration > 0 ? Math.min(duration, Math.max(0, seconds)) : Math.max(0, seconds)
    this.video.currentTime = target
    this.syncScrubberPosition()
    this.syncTransportControls()
    this.renderOverlay()
  },

  resolvedWindowThumbnails() {
    if (!Array.isArray(this.fragmentPdtRanges) || this.fragmentPdtRanges.length === 0) {
      return this.windowThumbnails
    }
    return this.windowThumbnails.map(thumb => {
      if (thumb.tsUs !== null && Number.isFinite(thumb.tsUs)) {
        const mapped = resolveTimelineUsToPlaybackSeconds(thumb.tsUs, this.fragmentPdtRanges)
        if (Number.isFinite(mapped)) {
          return {...thumb, offsetSeconds: Math.max(0, mapped)}
        }
      }
      return thumb
    })
  },

  updateScrubberHover(event, fraction) {
    const duration = this.effectiveDurationSeconds()
    const pct = `${(fraction * 100).toFixed(2)}%`
    if (this.scrubberHoverLine) {
      this.scrubberHoverLine.style.left = pct
      this.scrubberHoverLine.hidden = false
    }
    if (this.scrubberHoverTooltip && duration > 0) {
      const hoverSec = fraction * duration
      const segEl = event?.target?.closest?.("[data-role='scrubber-event-segment']")
      const segTitle = segEl?.getAttribute?.("title") || null
      const nearest = findNearestScrubberThumbnail(
        this.resolvedWindowThumbnails(),
        this.scrubberSegments,
        hoverSec,
        duration
      )
      const label = nearest.label || (segTitle ? segTitle.split(" · ")[0] : null)
      const markup = buildScrubberHoverMarkup({
        hoverSec,
        thumbnailUrl: nearest.thumbnailUrl,
        label,
        segTitle,
      })
      if (markup !== this.lastHoverMarkup) {
        this.lastHoverMarkup = markup
        this.scrubberHoverTooltip.innerHTML = markup
      }
      const trackRect = (this.scrubberTrack || this.scrubber)?.getBoundingClientRect?.()
      const cardWidth = nearest.thumbnailUrl ? 144 : 72
      const clampedPct = clampHoverTooltipPercent(fraction, trackRect?.width, cardWidth)
      this.scrubberHoverTooltip.style.left = `${clampedPct}%`
      this.scrubberHoverTooltip.hidden = false
    }
  },

  renderScrubberFilmstrip(duration) {
    if (!this.scrubberFilmstrip) return

    const thumbs = this.resolvedWindowThumbnails()
    const candidates =
      thumbs.length > 0
        ? thumbs
        : this.scrubberSegments
            .filter(seg => Boolean(seg.thumbnailUrl))
            .map(seg => ({
              offsetSeconds: seg.startSec,
              thumbnailUrl: seg.thumbnailUrl,
              label: seg.label,
            }))

    if (candidates.length === 0) {
      this.scrubberFilmstrip.innerHTML = ""
      return
    }

    if (candidates.length >= 6) {
      const maxTiles = 16
      let tiles = candidates
      if (candidates.length > maxTiles) {
        tiles = []
        const step = (candidates.length - 1) / (maxTiles - 1)
        for (let i = 0; i < maxTiles; i += 1) {
          tiles.push(candidates[Math.round(i * step)])
        }
      }
      this.scrubberFilmstrip.innerHTML = tiles
        .map(item => {
          const safeSrc = escapeOverlayText(item.thumbnailUrl)
          return (
            `<img data-role="scrubber-filmstrip-thumb" src="${safeSrc}" alt="" ` +
            `loading="lazy" decoding="async" draggable="false" ` +
            `class="h-full min-w-0 flex-1 border-r border-zinc-950/50 object-cover last:border-r-0" />`
          )
        })
        .join("")
      return
    }

    if (!Number.isFinite(duration) || duration <= 0) {
      this.scrubberFilmstrip.innerHTML = ""
      return
    }

    const kept = []
    for (const item of candidates) {
      const rawPct = Math.min(95, Math.max(5, (item.offsetSeconds / duration) * 100))
      if (kept.some(prev => Math.abs(prev.leftPct - rawPct) < 6.5)) continue
      kept.push({...item, leftPct: Number(rawPct.toFixed(2))})
    }

    this.scrubberFilmstrip.innerHTML = kept
      .map(item => {
        const safeSrc = escapeOverlayText(item.thumbnailUrl)
        return (
          `<img data-role="scrubber-filmstrip-thumb" src="${safeSrc}" alt="" ` +
          `loading="lazy" decoding="async" draggable="false" ` +
          `style="left: ${item.leftPct}%;" ` +
          `class="absolute top-1/2 h-[22px] w-9 -translate-x-1/2 -translate-y-1/2 rounded object-cover ring-1 ring-white/25" />`
        )
      })
      .join("")
  },

  renderScrubberEvents() {
    if (!this.scrubberEvents && !this.scrubberTicks && !this.scrubberFilmstrip) return
    const duration = this.effectiveDurationSeconds()
    this.scrubberSegments = buildScrubberEventSegments(this.detections, this.windowEvents, duration, {
      fragmentPdtRanges: this.fragmentPdtRanges,
    })
    this.renderScrubberFilmstrip(duration)

    if (this.scrubberEvents) {
      this.scrubberEvents.innerHTML = this.scrubberSegments
        .map(seg => {
          const style = SCRUBBER_CATEGORY_STYLES[seg.category] || SCRUBBER_CATEGORY_STYLES.object
          const tier = style.tier || "smart"
          const title = escapeOverlayText(seg.tooltip)
          const cat = escapeOverlayText(seg.category)
          const seekSec = seg.startSec.toFixed(3)
          const barClass =
            tier === "motion"
              ? `absolute bottom-0 h-[2px] z-[3] cursor-pointer rounded-full ${style.bg} transition-colors`
              : `absolute bottom-0.5 h-1.5 z-[4] cursor-pointer rounded-full ${style.bg} shadow-sm ring-1 ${style.ring} transition-transform hover:scale-y-125`
          return (
            `<button type="button" data-role="scrubber-event-segment" ` +
            `data-event-tier="${tier}" data-event-category="${cat}" data-seek-seconds="${seekSec}" ` +
            `title="${title}" aria-label="${title}" ` +
            `style="left: ${seg.leftPct}%; width: ${seg.widthPct}%;" ` +
            `class="${barClass}">` +
            `</button>`
          )
        })
        .join("")
    }

    if (this.scrubberTicks) {
      if (duration <= 0) {
        this.scrubberTicks.innerHTML = ""
      } else {
        const ticks = [0, 0.25, 0.5, 0.75, 1].map(frac => {
          const label = formatScrubberTime(frac * duration)
          return `<span>${escapeOverlayText(label)}</span>`
        })
        this.scrubberTicks.innerHTML = ticks.join("")
      }
    }
  },

  syncScrubberPosition() {
    if (!this.scrubber && !this.scrubberPlayhead && !this.scrubberProgress) return
    const duration = this.effectiveDurationSeconds()
    const current = Math.max(0, Number(this.video?.currentTime) || 0)
    const pct = duration > 0 ? Math.min(100, Math.max(0, (current / duration) * 100)) : 0
    const pctStr = `${pct.toFixed(3)}%`

    if (pctStr !== this.lastScrubberPctStr) {
      this.lastScrubberPctStr = pctStr
      if (this.scrubberProgress) {
        this.scrubberProgress.style.width = pctStr
      }
      if (this.scrubberPlayhead) {
        this.scrubberPlayhead.style.left = pctStr
      }
    }

    if (this.scrubber) {
      const ariaNow = String(Math.round(current))
      const ariaMax = String(Math.round(duration))
      if (ariaNow !== this.lastScrubberAriaNow) {
        this.lastScrubberAriaNow = ariaNow
        this.scrubber.setAttribute?.("aria-valuenow", ariaNow)
      }
      if (ariaMax !== this.lastScrubberAriaMax) {
        this.lastScrubberAriaMax = ariaMax
        this.scrubber.setAttribute?.("aria-valuemax", ariaMax)
      }
    }
  },

  syncScrubberBuffered() {
    if (!this.scrubberBuffered || !this.video) return
    const duration = this.effectiveDurationSeconds()
    const buffered = this.video.buffered
    if (duration <= 0 || !buffered || buffered.length === 0) {
      this.scrubberBuffered.style.width = "0%"
      return
    }
    const endSec = buffered.end(buffered.length - 1)
    const pct = Math.min(100, Math.max(0, (endSec / duration) * 100))
    this.scrubberBuffered.style.width = `${pct.toFixed(2)}%`
  },

  startScrubberAnimation() {
    if (typeof requestAnimationFrame !== "function") return
    if (this.scrubberRafId !== null) return
    const step = () => {
      this.syncScrubberPosition()
      if (this.video && !this.video.paused && !this.video.ended) {
        this.scrubberRafId = requestAnimationFrame(step)
      } else {
        this.scrubberRafId = null
      }
    }
    this.scrubberRafId = requestAnimationFrame(step)
  },

  stopScrubberAnimation() {
    if (this.scrubberRafId !== null && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this.scrubberRafId)
    }
    this.scrubberRafId = null
  },

  start() {
    this.stop()
    this.path = this.el.dataset.playlistPath || ""
    this.metadataLoaded = false
    this.fragmentPdtRanges = []
    this.lastAppliedSeekAttr = this.el.dataset.seekOffsetSeconds || ""
    this.pendingSeekOffsetSeconds = parseSeekOffsetSeconds(this.lastAppliedSeekAttr)
    this.lastSeekTargetOffsetSeconds = null
    this.seekAppliedWithPdt = false

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
      enableWorker: true,
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
    if (HlsClass.Events?.LEVEL_LOADED) {
      player.on(HlsClass.Events.LEVEL_LOADED, (_event, data) => {
        if (this.player !== player) return
        const ranges = extractFragmentPdtRanges(data?.details)
        if (ranges.length === 0) return
        this.fragmentPdtRanges = ranges
        if (this.metadataLoaded && !this.seekAppliedWithPdt && this.lastSeekTargetOffsetSeconds !== null) {
          this.pendingSeekOffsetSeconds = this.lastSeekTargetOffsetSeconds
          this.applyPendingSeek()
        }
        this.renderScrubberEvents()
        this.renderOverlay()
      })
    }
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
    this.stopScrubberAnimation()
    this.fragmentPdtRanges = []
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
    const rawOffset = this.pendingSeekOffsetSeconds
    this.pendingSeekOffsetSeconds = null
    this.lastSeekTargetOffsetSeconds = rawOffset

    let target = rawOffset
    const rawWinStart = this.el.dataset?.windowStartUs
    const winStart =
      rawWinStart !== null && rawWinStart !== undefined && String(rawWinStart).trim() !== ""
        ? Number(rawWinStart)
        : Number.NaN
    if (Array.isArray(this.fragmentPdtRanges) && this.fragmentPdtRanges.length > 0 && Number.isFinite(winStart)) {
      const targetUs = winStart + rawOffset * 1_000_000
      const mapped = resolveTimelineUsToPlaybackSeconds(targetUs, this.fragmentPdtRanges)
      if (Number.isFinite(mapped)) {
        target = Math.max(0, mapped)
        this.seekAppliedWithPdt = true
      }
    }

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
    this.seekAppliedWithPdt = true
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
    const windowStartUs = this.el.dataset.windowStartUs || null
    this.detections = parseOverlayDetections(this.el.dataset.overlayDetections || "", {
      windowStartUs,
    })
    this.windowEvents = parseScrubberEvents(this.el.dataset.windowEvents || "", {
      windowStartUs,
    })
    this.windowThumbnails = parseScrubberThumbnails(this.el.dataset.windowThumbnails || "", {
      windowStartUs,
    })
  },

  syncOverlayToggleButton() {
    if (!this.overlayToggle) return
    this.overlayToggle.setAttribute?.("aria-pressed", String(this.overlayEnabled))
    this.overlayToggle.textContent = this.overlayEnabled ? "AI boxes: On" : "AI boxes: Off"
  },

  clearOverlay() {
    if (!this.overlay) return
    if (this.lastOverlayMarkup !== "") {
      this.lastOverlayMarkup = ""
      this.overlay.innerHTML = ""
    }
  },

  renderOverlay() {
    if (!this.overlay || !this.video) return

    if (!this.overlayEnabled || this.detections.length === 0) {
      this.overlay.hidden = !this.overlayEnabled
      if (this.lastOverlayMarkup !== "") {
        this.lastOverlayMarkup = ""
        this.overlay.innerHTML = ""
      }
      return
    }

    this.overlay.hidden = false
    const cw = Number(this.video.clientWidth) || 0
    const ch = Number(this.video.clientHeight) || 0
    if (cw <= 0 || ch <= 0) {
      if (this.lastOverlayMarkup !== "") {
        this.lastOverlayMarkup = ""
        this.overlay.innerHTML = ""
      }
      return
    }

    const viewBox = `0 0 ${cw} ${ch}`
    if (viewBox !== this.lastOverlayViewBox) {
      this.lastOverlayViewBox = viewBox
      this.overlay.setAttribute?.("viewBox", viewBox)
    }
    const contentRect = computeVideoContentRect({
      clientWidth: cw,
      clientHeight: ch,
      videoWidth: this.video.videoWidth,
      videoHeight: this.video.videoHeight,
    })

    const currentTimelineUs = resolvePlaybackTimelineUs(this.video.currentTime, this.fragmentPdtRanges)
    const active = selectActiveDetections(this.detections, this.video.currentTime, {
      highlightFrameId: this.el.dataset.highlightFrameId || null,
      metadataLoaded: this.metadataLoaded,
      currentTimelineUs,
    })

    const markup = buildOverlaySvgMarkup(active, contentRect)
    if (markup !== this.lastOverlayMarkup) {
      this.lastOverlayMarkup = markup
      this.overlay.innerHTML = markup
    }
  },

  maybeAdvanceWindow() {
    if (this.advancingWindow) return
    if (this.el.dataset.hasAdjacentWindow !== "true") return
    if (!this.video) return
    if (this.video.paused && !this.video.ended) return

    const duration = this.video.duration
    const currentTime = this.video.currentTime
    if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) return

    if (this.video.ended || duration - currentTime <= ADJACENT_PREFETCH_THRESHOLD_SECONDS) {
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
