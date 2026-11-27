// Pointer position inside an SVG plot, in viewBox units.
// Generalized from web-ng chart_hover_geometry.js. Layout is computed here
// and applied by the hook through SVG attributes or CSSOM, never as a
// server-rendered style attribute.

export function hoverPosition(clientX, rect, opts = {}) {
  const rectWidth = positive(rect?.width, 1)
  const viewBoxWidth = positive(opts.viewBoxWidth, rectWidth)
  const scale = rectWidth / viewBoxWidth
  const plotLeft = numberOr(opts.plotLeft, 0) * scale
  const plotWidth = Math.max(1, numberOr(opts.plotWidth, viewBoxWidth) * scale)
  const pointerX = numberOr(clientX, 0) - numberOr(rect?.left, 0)
  const plotX = clamp(pointerX - plotLeft, 0, plotWidth)

  return {
    pct: plotX / plotWidth,
    plotLeft: numberOr(opts.plotLeft, 0),
    plotWidth: numberOr(opts.plotWidth, viewBoxWidth),
  }
}

export function plotGeometryFromDataset(el, svg) {
  const viewBoxWidth = numberOr(el?.dataset?.chartWidth, viewBoxWidthOf(svg, 800))
  const symmetric = numberOr(el?.dataset?.chartPad, 0)
  const plotLeft = numberOr(el?.dataset?.chartLeftPad, symmetric)
  const plotRight = numberOr(el?.dataset?.chartRightPad, symmetric)

  return {
    viewBoxWidth,
    plotLeft,
    plotWidth: Math.max(1, viewBoxWidth - plotLeft - plotRight),
  }
}

export function nearestByX(points, x) {
  if (!Array.isArray(points) || points.length === 0) return null
  let best = points[0]
  let bestDist = Math.abs(numberOr(best.x, 0) - x)
  for (const point of points) {
    const dist = Math.abs(numberOr(point.x, 0) - x)
    if (dist < bestDist) {
      best = point
      bestDist = dist
    }
  }
  return best
}

function viewBoxWidthOf(svg, fallback) {
  const attr = svg?.getAttribute?.("viewBox")
  if (typeof attr !== "string") return fallback
  const width = Number(attr.trim().split(/\s+/)[2])
  return Number.isFinite(width) && width > 0 ? width : fallback
}

function numberOr(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) ? n : fallback
}

function positive(value, fallback) {
  const n = numberOr(value, fallback)
  return n > 0 ? n : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}
