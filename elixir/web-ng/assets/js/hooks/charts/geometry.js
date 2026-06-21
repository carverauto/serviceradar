export const TIMESERIES_VIEWBOX_WIDTH = 800
export const TIMESERIES_CHART_PAD = 8

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

export function timeseriesClientXToPointIndex(clientX, rect, pointCount, opts = {}) {
  if (!Number.isFinite(pointCount) || pointCount <= 1) return 0

  const viewBoxWidth = opts.viewBoxWidth ?? TIMESERIES_VIEWBOX_WIDTH
  const chartPad = opts.chartPad ?? TIMESERIES_CHART_PAD
  const width = Math.max(1, Number(rect?.width || 0))
  const localX = clamp(clientX - Number(rect?.left || 0), 0, width)
  const viewX = (localX / width) * viewBoxWidth
  const usable = Math.max(1, viewBoxWidth - chartPad * 2)
  const pct = clamp((viewX - chartPad) / usable, 0, 1)

  return Math.round(pct * (pointCount - 1))
}

export function timeseriesPointIndexToLocalX(index, rect, pointCount, opts = {}) {
  const viewBoxWidth = opts.viewBoxWidth ?? TIMESERIES_VIEWBOX_WIDTH
  const chartPad = opts.chartPad ?? TIMESERIES_CHART_PAD
  const width = Math.max(1, Number(rect?.width || 0))
  const maxIndex = Math.max(0, pointCount - 1)
  const idx = clamp(Number(index || 0), 0, maxIndex)

  if (pointCount <= 1) return (chartPad / viewBoxWidth) * width

  const usable = viewBoxWidth - chartPad * 2
  const viewX = chartPad + (idx / maxIndex) * usable
  return (viewX / viewBoxWidth) * width
}
