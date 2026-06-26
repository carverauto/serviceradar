export const TIMESERIES_VIEWBOX_WIDTH = 800
export const TIMESERIES_CHART_LEFT_PAD = 36
export const TIMESERIES_CHART_RIGHT_PAD = 24

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

export function timeseriesClientXToPointIndex(clientX, rect, pointCount, opts = {}) {
  if (!Number.isFinite(pointCount) || pointCount <= 1) return 0

  const viewBoxWidth = opts.viewBoxWidth ?? TIMESERIES_VIEWBOX_WIDTH
  const chartLeftPad = opts.chartLeftPad ?? opts.chartPad ?? TIMESERIES_CHART_LEFT_PAD
  const chartRightPad = opts.chartRightPad ?? opts.chartPad ?? TIMESERIES_CHART_RIGHT_PAD
  const width = Math.max(1, Number(rect?.width || 0))
  const localX = clamp(clientX - Number(rect?.left || 0), 0, width)
  const viewX = (localX / width) * viewBoxWidth
  const usable = Math.max(1, viewBoxWidth - chartLeftPad - chartRightPad)
  const pct = clamp((viewX - chartLeftPad) / usable, 0, 1)

  return Math.round(pct * (pointCount - 1))
}

export function timeseriesPointIndexToLocalX(index, rect, pointCount, opts = {}) {
  const viewBoxWidth = opts.viewBoxWidth ?? TIMESERIES_VIEWBOX_WIDTH
  const chartLeftPad = opts.chartLeftPad ?? opts.chartPad ?? TIMESERIES_CHART_LEFT_PAD
  const chartRightPad = opts.chartRightPad ?? opts.chartPad ?? TIMESERIES_CHART_RIGHT_PAD
  const width = Math.max(1, Number(rect?.width || 0))
  const maxIndex = Math.max(0, pointCount - 1)
  const idx = clamp(Number(index || 0), 0, maxIndex)

  if (pointCount <= 1) return (chartLeftPad / viewBoxWidth) * width

  const usable = viewBoxWidth - chartLeftPad - chartRightPad
  const viewX = chartLeftPad + (idx / maxIndex) * usable
  return (viewX / viewBoxWidth) * width
}
