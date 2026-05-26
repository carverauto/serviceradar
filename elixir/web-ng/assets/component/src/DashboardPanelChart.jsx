import React, {useEffect, useMemo, useRef, useState} from "../../node_modules/react/index.js"
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  PolarAngleAxis,
  RadialBar,
  RadialBarChart,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"

const CHART_COLORS = ["#38bdf8", "#22c55e", "#f59e0b", "#ef4444", "#a78bfa"]
const GRID_STROKE = "#1e293b"
const TICK_STROKE = "#94a3b8"
const STATUS_COLORS = {
  success: "#22c55e",
  warning: "#f59e0b",
  error: "#ef4444",
  info: "#38bdf8",
  primary: "#38bdf8",
}

function fieldName(field) {
  return field?.name || ""
}

function fieldType(field) {
  return field?.type || "string"
}

function firstField(fields, type) {
  return fields.find(field => fieldType(field) === type)?.name || ""
}

function firstNamedField(fields, names) {
  const wanted = new Set(names)
  return fields.find(field => wanted.has(fieldName(field)))?.name || ""
}

function valueAt(row, field) {
  if (!row || !field) return null
  return row[field]
}

function numericValue(value) {
  const next = Number(value)
  return Number.isFinite(next) ? next : null
}

function formatValue(value) {
  if (value === null || value === undefined || value === "") return "—"
  if (typeof value === "number") {
    return Number.isInteger(value) ? String(value) : value.toFixed(2)
  }
  return String(value)
}

function formatPercent(value) {
  const number = numericValue(value)
  if (number === null) return null
  const prefix = number > 0 ? "+" : ""
  return `${prefix}${number.toFixed(1)}%`
}

function formatAxisValue(value) {
  if (value === null || value === undefined || value === "") return ""
  const date = new Date(value)
  if (!Number.isNaN(date.getTime()) && String(value).includes("T")) {
    return date.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})
  }
  return String(value)
}

function booleanish(value) {
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return null
}

function formatCategoryValue(value, field) {
  const normalizedField = String(field || "").toLowerCase()
  if (["is_available", "available", "availability"].includes(normalizedField)) {
    const availability = booleanish(value)
    if (availability === true) return "Available"
    if (availability === false) return "Unavailable"
  }

  return formatAxisValue(value)
}

function humanizeFieldName(field, fallback = "value") {
  if (!field) return fallback
  return String(field)
    .replace(/_id$/u, "")
    .replace(/_/gu, " ")
    .replace(/\b\w/gu, character => character.toUpperCase())
}

function countLabel(count, singular, plural = `${singular}s`) {
  return Number(count) === 1 ? singular : plural
}

function gaugeTone(panel, percent) {
  const thresholds = Array.isArray(panel?.display_config?.thresholds)
    ? panel.display_config.thresholds
    : []

  const tone = thresholds
    .map(threshold => ({
      value: numericValue(threshold.value ?? threshold.at),
      tone: String(threshold.tone || threshold.level || "primary"),
    }))
    .filter(threshold => threshold.value !== null)
    .sort((a, b) => a.value - b.value)
    .reduce((current, threshold) => (percent >= threshold.value ? threshold.tone : current), "primary")

  return STATUS_COLORS[tone] ? tone : "primary"
}

function chartFields(panel, fields) {
  const binding = panel?.data_binding || {}
  const valueField = binding.value_field || binding.numerator_field || firstField(fields, "number")
  const denominatorField = binding.denominator_field || firstNamedField(fields, ["total", "count", "denominator"])
  const timeField =
    binding.time_field ||
    binding.timestamp_field ||
    firstField(fields, "datetime") ||
    firstNamedField(fields, ["timestamp", "created_at", "observed_at"])
  const labelField = binding.label_field || binding.row_field || firstField(fields, "string") || timeField

  return {valueField, denominatorField, timeField, labelField}
}

function seriesRows(rows, fields, panel) {
  const {valueField, timeField, labelField} = chartFields(panel, fields)
  const visual = String(panel?.visual_type || "line")
  const xField = ["line", "area"].includes(visual) ? timeField || labelField : labelField || timeField

  return rows
    .map((row, index) => {
      const value = numericValue(valueAt(row, valueField))
      if (value === null) return null

      return {
        name: formatCategoryValue(valueAt(row, xField), xField) || `Row ${index + 1}`,
        value,
      }
    })
    .filter(Boolean)
}

function gaugeDatum(rows, fields, panel) {
  const {valueField, denominatorField} = chartFields(panel, fields)
  const visual = String(panel?.visual_type || "gauge")
  const row = rows[0] || {}
  const numerator = numericValue(valueAt(row, valueField)) || 0
  const denominator = numericValue(valueAt(row, denominatorField)) || 100
  const percent = denominator > 0 ? (numerator / denominator) * 100 : numerator
  const clamped = Math.max(0, Math.min(100, percent))
  const tone = gaugeTone(panel, clamped)
  const numeratorLabel =
    panel?.display_config?.numerator_label ||
    panel?.display_config?.value_label ||
    (visual === "availability" ? countLabel(numerator, "available", "available") : humanizeFieldName(valueField))
  const denominatorLabel =
    panel?.display_config?.denominator_label ||
    panel?.display_config?.total_label ||
    (visual === "availability" ? countLabel(denominator, "monitored", "monitored") : humanizeFieldName(denominatorField, "target"))
  const contextLabel =
    panel?.display_config?.context_label ||
    (visual === "availability"
      ? `${formatValue(numerator)} of ${formatValue(denominator)} ${countLabel(denominator, "service")} available`
      : `${formatValue(numerator)} of ${formatValue(denominator)} ${denominatorLabel.toLowerCase()}`)

  return {
    percent: clamped,
    display: clamped.toFixed(1),
    numerator,
    denominator,
    numeratorLabel,
    denominatorLabel,
    contextLabel,
    tone,
    color: STATUS_COLORS[tone],
    label: panel?.display_config?.label || panel?.title || "Gauge",
    unit: panel?.display_config?.unit || "%",
  }
}

function EmptyChart({message = "No chartable data"}) {
  return (
    <div className="flex h-full min-h-0 items-center justify-center rounded-lg border border-dashed border-slate-800 text-sm text-slate-500">
      {message}
    </div>
  )
}

function ResponsiveChart({children}) {
  const ref = useRef(null)
  const [size, setSize] = useState({width: 0, height: 0})

  useEffect(() => {
    const node = ref.current
    if (!node) return undefined

    const updateSize = () => {
      const rect = node.getBoundingClientRect()
      setSize({
        width: Math.max(0, Math.floor(rect.width)),
        height: Math.max(0, Math.floor(rect.height)),
      })
    }

    updateSize()

    if (typeof ResizeObserver === "undefined") {
      const frame = window.requestAnimationFrame(updateSize)
      return () => window.cancelAnimationFrame(frame)
    }

    const observer = new ResizeObserver(updateSize)
    observer.observe(node)

    return () => observer.disconnect()
  }, [])

  const ready = size.width > 0 && size.height > 0

  return (
    <div ref={ref} className="h-full min-h-0 w-full min-w-0">
      {ready ? React.cloneElement(children, {width: size.width, height: size.height}) : null}
    </div>
  )
}

function ChartTooltip({active, payload, label}) {
  if (!active || !payload?.length) return null
  const item = payload[0]

  return (
    <div className="rounded-md border border-slate-700 bg-slate-950/95 px-3 py-2 text-xs shadow-xl shadow-cyan-950/30">
      <div className="font-medium text-slate-100">{label}</div>
      <div className="mt-1 font-mono text-slate-300">{formatValue(item.value)}</div>
    </div>
  )
}

function AxisChart({visual, rows}) {
  if (rows.length === 0) return <EmptyChart />

  const common = {
    data: rows,
    margin: {top: 10, right: 18, bottom: 8, left: 0},
  }

  const axis = (
    <>
      <CartesianGrid stroke={GRID_STROKE} strokeOpacity={0.95} vertical={false} />
      <XAxis
        dataKey="name"
        minTickGap={24}
        tick={{fontSize: 11, fill: TICK_STROKE}}
        tickLine={false}
        axisLine={false}
      />
      <YAxis
        width={44}
        tick={{fontSize: 11, fill: TICK_STROKE}}
        tickLine={false}
        axisLine={false}
      />
      <Tooltip content={<ChartTooltip />} />
    </>
  )

  if (visual === "bar" || visual === "category") {
    return (
      <ResponsiveChart>
        <BarChart {...common}>
          {axis}
          <Bar dataKey="value" fill={CHART_COLORS[0]} radius={[5, 5, 0, 0]} maxBarSize={42} />
        </BarChart>
      </ResponsiveChart>
    )
  }

  if (visual === "area") {
    return (
      <ResponsiveChart>
        <AreaChart {...common}>
          {axis}
          <Area
            dataKey="value"
            type="monotone"
            stroke={CHART_COLORS[0]}
            fill={CHART_COLORS[0]}
            fillOpacity={0.18}
            strokeWidth={2}
            dot={false}
            activeDot={{r: 4}}
          />
        </AreaChart>
      </ResponsiveChart>
    )
  }

  return (
    <ResponsiveChart>
      <LineChart {...common}>
        {axis}
        <Line
          dataKey="value"
          type="monotone"
          stroke={CHART_COLORS[0]}
          strokeWidth={2}
          dot={false}
          activeDot={{r: 4}}
        />
      </LineChart>
    </ResponsiveChart>
  )
}

function trendTone(trend) {
  if (trend?.direction === "up") return "text-emerald-300"
  if (trend?.direction === "down") return "text-rose-300"
  return "text-slate-400"
}

function trendArrow(trend) {
  if (trend?.direction === "up") return "Up"
  if (trend?.direction === "down") return "Down"
  return "Flat"
}

function TrendBadge({trend}) {
  if (!trend) return null

  const percent = formatPercent(trend.percent_delta)
  const text = percent || trend.text
  if (!text) return null

  return (
    <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
      <span className={`font-semibold ${trendTone(trend)}`}>
        {trendArrow(trend)} {text}
      </span>
      {trend.label ? <span className="text-slate-500">{trend.label}</span> : null}
    </div>
  )
}

function GaugeChart({rows, fields, panel, trend}) {
  const gauge = gaugeDatum(rows, fields, panel)

  return (
    <div className="grid h-full min-h-0 grid-cols-[minmax(96px,40%)_1fr] items-center gap-3 overflow-hidden">
      <div className="h-full min-h-0">
        <ResponsiveChart>
          <RadialBarChart
            innerRadius="68%"
            outerRadius="96%"
            data={[{name: gauge.label, value: gauge.percent, fill: gauge.color}]}
            startAngle={210}
            endAngle={-30}
          >
            <PolarAngleAxis type="number" domain={[0, 100]} tick={false} />
            <RadialBar dataKey="value" cornerRadius={8} background={{fill: "rgba(148, 163, 184, 0.18)"}} />
          </RadialBarChart>
        </ResponsiveChart>
      </div>
      <div className="min-w-0">
        <div className="truncate text-sm font-medium text-slate-300">{gauge.label}</div>
        <div className="mt-1 text-4xl font-semibold tracking-normal text-slate-100">
          {gauge.display}<span className="text-xl text-slate-400">{gauge.unit}</span>
        </div>
        <div className="mt-2 truncate text-xs text-slate-400">{gauge.contextLabel}</div>
        <TrendBadge trend={trend} />
        <div className="mt-3 flex flex-wrap gap-2 text-xs text-slate-400">
          <span className="rounded border border-slate-700 px-2 py-0.5">
            {formatValue(gauge.numerator)} {gauge.numeratorLabel}
          </span>
          <span className="rounded border border-slate-700 px-2 py-0.5">
            {formatValue(gauge.denominator)} {gauge.denominatorLabel}
          </span>
        </div>
      </div>
    </div>
  )
}

export default function DashboardPanelChart({
  panel = {},
  rows = [],
  fields = [],
  trend = null,
}) {
  const visual = String(panel.visual_type || "line")
  const chartRows = useMemo(() => seriesRows(rows, fields, panel), [rows, fields, panel])

  if (visual === "gauge" || visual === "availability") {
    return <GaugeChart rows={rows} fields={fields} panel={panel} trend={trend} />
  }

  return (
    <div className="h-full min-h-0 overflow-hidden text-slate-400">
      <AxisChart visual={visual} rows={chartRows} />
    </div>
  )
}
