export function hoverPosition(clientX, rect, opts = {}) {
  const rectWidth = positiveNumber(rect?.width, 1)
  const viewBoxWidth = positiveNumber(opts.viewBoxWidth, rectWidth)
  const scale = rectWidth / viewBoxWidth
  const plotLeft = numberOr(opts.plotLeft, 0) * scale
  const plotWidth = Math.max(1, numberOr(opts.plotWidth, viewBoxWidth) * scale)
  const pointerX = numberOr(clientX, 0) - numberOr(rect?.left, 0)
  const plotX = clamp(pointerX - plotLeft, 0, plotWidth)
  const pct = plotX / plotWidth
  const lineX = plotLeft + plotX

  return {pointerX, plotX, pct, lineX, plotLeft, plotWidth}
}

export function svgViewBoxWidth(svg, fallback) {
  const attr = svg?.getAttribute?.("viewBox")
  if (typeof attr !== "string") return fallback

  const parts = attr.trim().split(/\s+/)
  if (parts.length < 4) return fallback

  const width = Number(parts[2])
  return Number.isFinite(width) && width > 0 ? width : fallback
}

export function plotGeometryFromDataset(el, svg, rect) {
  const viewBoxWidth = numberOr(el?.dataset?.chartWidth, svgViewBoxWidth(svg, rect?.width))
  const symmetricPad = numberOr(el?.dataset?.chartPad, 0)
  const leftPad = numberOr(el?.dataset?.chartLeftPad, symmetricPad)
  const rightPad = numberOr(el?.dataset?.chartRightPad, symmetricPad)

  return {
    viewBoxWidth,
    plotLeft: leftPad,
    plotRight: rightPad,
    plotWidth: Math.max(1, viewBoxWidth - leftPad - rightPad),
  }
}

function numberOr(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) ? n : fallback
}

function positiveNumber(value, fallback) {
  const n = numberOr(value, fallback)
  return n > 0 ? n : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}
