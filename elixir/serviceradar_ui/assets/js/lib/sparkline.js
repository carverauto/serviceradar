// Server-matching sparkline geometry for the SrSparkline hook.
// ViewBox is 0 0 100 32, with the line drawn between y=4 and y=28.

const WIDTH = 100
const TOP = 4
const BOTTOM = 28
const BASELINE = 32

export function sparklinePaths(values, opts = {}) {
  const series = (Array.isArray(values) ? values : []).map(valueOf)
  const domain = valueDomain(
    series.filter((v) => v !== null),
    numberOrNull(opts.min),
    numberOrNull(opts.max),
  )
  const count = series.length
  const xAt = (i) => (count > 1 ? (i * WIDTH) / (count - 1) : 50)
  const yAt = (v) => scale(v, domain, [BOTTOM, TOP])
  const segments = chunk(series, xAt, yAt)
  const smooth = opts.smooth !== false && opts.smooth !== "false"
  const line = smooth ? smoothPath(segments) : linePath(segments)

  return {
    line,
    area: areaPath(segments, BASELINE, smooth),
    empty: line === "",
  }
}

function valueOf(value) {
  if (value === null || value === undefined || value === "") return null
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "object") {
    if ("value" in value) return valueOf(value.value)
    if ("v" in value) return valueOf(value.v)
  }
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function valueDomain(numbers, min, max) {
  if (numbers.length === 0) return [min ?? 0, max ?? 1]
  let lo = min ?? Math.min(...numbers)
  let hi = max ?? Math.max(...numbers)
  if (hi > lo) return [lo, hi]
  return [lo - 0.5, hi + 0.5]
}

function scale(v, [d0, d1], [r0, r1]) {
  if (d1 === d0) return (r0 + r1) / 2
  return r0 + ((v - d0) / (d1 - d0)) * (r1 - r0)
}

function chunk(values, xAt, yAt) {
  const segments = []
  let current = []
  values.forEach((value, i) => {
    if (value === null) {
      if (current.length) segments.push(current)
      current = []
    } else {
      current.push([xAt(i), yAt(value)])
    }
  })
  if (current.length) segments.push(current)
  return segments
}

function linePath(segments) {
  return segments.map(segmentLine).filter(Boolean).join(" ")
}

function segmentLine(points) {
  if (points.length === 0) return ""
  if (points.length === 1) {
    const [x, y] = points[0]
    return `M${fmt(x - 1)},${fmt(y)} L${fmt(x + 1)},${fmt(y)}`
  }
  return points
    .map(([x, y], i) => `${i === 0 ? "M" : "L"}${fmt(x)},${fmt(y)}`)
    .join(" ")
}

function smoothPath(segments) {
  return segments.map(segmentSmooth).filter(Boolean).join(" ")
}

function segmentSmooth(points) {
  if (points.length < 3) return segmentLine(points)
  const slopes = []
  for (let i = 0; i < points.length - 1; i += 1) {
    const [xa, ya] = points[i]
    const [xb, yb] = points[i + 1]
    slopes.push(xb === xa ? 0 : (yb - ya) / (xb - xa))
  }
  const tangents = points.map((_, i) => {
    if (i === 0) return slopes[0]
    if (i === points.length - 1) return slopes[slopes.length - 1]
    return harmonic(slopes[i - 1], slopes[i])
  })
  const [x0, y0] = points[0]
  const curves = []
  for (let i = 0; i < points.length - 1; i += 1) {
    const [xa, ya] = points[i]
    const [xb, yb] = points[i + 1]
    const dx = (xb - xa) / 3
    curves.push(
      `C${fmt(xa + dx)},${fmt(ya + tangents[i] * dx)} ${fmt(xb - dx)},${fmt(yb - tangents[i + 1] * dx)} ${fmt(xb)},${fmt(yb)}`,
    )
  }
  return [`M${fmt(x0)},${fmt(y0)}`, ...curves].join(" ")
}

function harmonic(s0, s1) {
  if (s0 * s1 <= 0) return 0
  return (2 * s0 * s1) / (s0 + s1)
}

function areaPath(segments, baseline, smooth) {
  return segments
    .filter((points) => points.length >= 2)
    .map((points) => {
      const top = smooth ? segmentSmooth(points) : segmentLine(points)
      const x0 = points[0][0]
      const xn = points[points.length - 1][0]
      return `${top} L${fmt(xn)},${fmt(baseline)} L${fmt(x0)},${fmt(baseline)} Z`
    })
    .join(" ")
}

function fmt(num) {
  const rounded = Math.round(num * 100) / 100
  if (Object.is(rounded, -0) || rounded === 0) return "0"
  return String(rounded)
}
