import React, {useEffect, useMemo, useRef, useState} from "react"
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  LineChart,
  PolarAngleAxis,
  RadialBar,
  RadialBarChart,
  ReferenceLine,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"

import {canonicalUtcInstant, formatUserTime} from "../../js/utils/user_time"

const CHART_COLORS = ["#38bdf8", "#22c55e", "#f59e0b", "#ef4444", "#a78bfa"]
const GRID_STROKE = "#1e293b"
const TICK_STROKE = "#94a3b8"
const DEFAULT_TIME_ZONE = "Etc/UTC"
const STATUS_COLORS = {
  success: "#22c55e",
  warning: "#f59e0b",
  error: "#ef4444",
  info: "#38bdf8",
  primary: "#38bdf8",
}
const CAPACITY_FORECAST_FIELDS = {
  forecastedAt: ["forecasted_at", "timestamp", "created_at"],
  horizonEndsAt: ["horizon_ends_at", "projected_at"],
  currentValue: ["current_value", "value"],
  projectedValue: ["projected_value", "forecast_value"],
  lowerBound: ["lower_bound"],
  upperBound: ["upper_bound"],
  threshold: ["exhaustion_threshold", "threshold"],
  exhaustionAt: ["projected_exhaustion_at", "exhaustion_at"],
  label: ["resource_label", "resource_key", "metric_name"],
  status: ["status"],
  confidence: ["confidence"],
}

function fieldName(field) {
  if (typeof field === "string") return field
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

function firstPresentField(fields, names) {
  const available = new Set(fields.map(fieldName))
  return names.find(name => available.has(name)) || ""
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

function displayTimeZone(timeZone) {
  return typeof timeZone === "string" && timeZone.trim() !== ""
    ? timeZone
    : DEFAULT_TIME_ZONE
}

export function dashboardPanelTimeLabel(
  value,
  {timeZone = DEFAULT_TIME_ZONE, style = "tooltip", locale, intl = globalThis.Intl} = {},
) {
  return dashboardPanelTimePresentation(value, {timeZone, style, locale, intl}).text
}

export function dashboardPanelTimePresentation(
  value,
  {timeZone = DEFAULT_TIME_ZONE, style = "tooltip", locale, intl = globalThis.Intl} = {},
) {
  if (value === null || value === undefined || value === "") {
    return {
      canonical: null,
      text: style === "axis" ? "" : "—",
      timeZone: displayTimeZone(timeZone),
      style,
    }
  }

  const canonical = canonicalUtcInstant(value)
  const zone = displayTimeZone(timeZone)
  if (!canonical) return {canonical: null, text: String(value), timeZone: zone, style}

  const text =
    formatUserTime(canonical, {
      timeZone: zone,
      style,
      locale,
      intl,
    })?.text || canonical

  return {canonical, text, timeZone: zone, style}
}

function DashboardPanelUserTime({value, timezone, style = "tooltip"}) {
  const presentation = dashboardPanelTimePresentation(value, {timeZone: timezone, style})

  if (!presentation.canonical) return presentation.text

  const accessibleLabel = `${presentation.text}; display zone ${presentation.timeZone}; canonical UTC ${presentation.canonical}`
  const title = `${presentation.canonical} UTC; display zone ${presentation.timeZone}`

  return (
    <time
      dateTime={presentation.canonical}
      data-user-time-zone={presentation.timeZone}
      data-user-time-style={presentation.style}
      title={title}
      aria-label={accessibleLabel}
    >
      {presentation.text}
    </time>
  )
}

function booleanish(value) {
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return null
}

export function dashboardPanelCategoryLabel(
  value,
  field,
  {fieldType: categoryFieldType, timeZone, style = "axis"} = {},
) {
  const normalizedField = String(field || "").toLowerCase()
  if (["is_available", "available", "availability"].includes(normalizedField)) {
    const availability = booleanish(value)
    if (availability === true) return "Available"
    if (availability === false) return "Unavailable"
  }

  const canonical = categoryCanonicalInstant(value, categoryFieldType)

  return canonical
    ? dashboardPanelTimeLabel(canonical, {timeZone, style})
    : formatValue(value)
}

function categoryCanonicalInstant(value, categoryFieldType) {
  if (String(categoryFieldType || "").toLowerCase() === "datetime") {
    return canonicalUtcInstant(value)
  }

  return typeof value === "string" ? canonicalUtcInstant(value) : null
}

function timeAxisMetadata(values, timeZone) {
  const canonicalValues = values.map(canonicalUtcInstant).filter(Boolean)
  if (canonicalValues.length === 0) return {}

  const zone = displayTimeZone(timeZone)
  const start = canonicalValues[0]
  const end = canonicalValues[canonicalValues.length - 1]
  const startLabel = dashboardPanelTimeLabel(start, {timeZone: zone, style: "tooltip"})
  const endLabel = dashboardPanelTimeLabel(end, {timeZone: zone, style: "tooltip"})

  return {
    "data-time-axis-start": start,
    "data-time-axis-end": end,
    "data-time-axis-zone": zone,
    "aria-label": `Time axis from ${startLabel} to ${endLabel}; display zone ${zone}; canonical UTC range ${start} to ${end}`,
  }
}

function humanizeFieldName(field, fallback = "value") {
  if (!field) return fallback
  return String(field)
    .replace(/_id$/u, "")
    .replace(/_/gu, " ")
    .replace(/\b\w/gu, character => character.toUpperCase())
}

function metricLabel(field, fallback) {
  const normalized = String(field || "").toLowerCase()
  if (["numerator", "value", "count"].includes(normalized)) return fallback
  if (["denominator", "total", "target"].includes(normalized)) return fallback
  return humanizeFieldName(field, fallback)
}

function countLabel(count, singular, plural = `${singular}s`) {
  return Number(count) === 1 ? singular : plural
}

function entityLabel(panel, fallback = "item") {
  const source =
    panel?.display_config?.entity_label ||
    panel?.display_config?.noun ||
    panel?.srql_query ||
    ""
  const match = String(source).match(/\bin:([a-zA-Z_][\w-]*)/u)
  const entity = match?.[1]

  if (!entity) return fallback
  if (entity.endsWith("ies")) return entity.slice(0, -3) + "y"
  if (entity.endsWith("s")) return entity.slice(0, -1)
  return entity
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

function displayFlag(value) {
  return value === true || value === "true" || value === "1" || value === "capacity_forecast"
}

export function isCapacityForecastPanel(panel, fields = []) {
  if (displayFlag(panel?.display_config?.capacity_forecast)) return true

  const names = new Set((fields || []).map(fieldName))

  return (
    names.has("forecasted_at") &&
    names.has("current_value") &&
    names.has("projected_value") &&
    names.has("horizon_ends_at")
  )
}

function capacityForecastFieldMap(fields) {
  return Object.entries(CAPACITY_FORECAST_FIELDS).reduce((acc, [key, names]) => {
    acc[key] = firstPresentField(fields, names)
    return acc
  }, {})
}

export function capacityForecastRows(rows, fields) {
  const fieldMap = capacityForecastFieldMap(fields || [])

  return (rows || [])
    .map(row => {
      const forecastedAt = valueAt(row, fieldMap.forecastedAt)
      const current = numericValue(valueAt(row, fieldMap.currentValue))
      const projected = numericValue(valueAt(row, fieldMap.projectedValue))

      if (!forecastedAt || (current === null && projected === null)) return null

      return {
        name: forecastedAt,
        forecastedAt,
        horizonEndsAt: valueAt(row, fieldMap.horizonEndsAt),
        current,
        projected,
        lower: numericValue(valueAt(row, fieldMap.lowerBound)),
        upper: numericValue(valueAt(row, fieldMap.upperBound)),
        threshold: numericValue(valueAt(row, fieldMap.threshold)),
        exhaustionAt: valueAt(row, fieldMap.exhaustionAt),
        label: valueAt(row, fieldMap.label),
        status: valueAt(row, fieldMap.status),
        confidence: numericValue(valueAt(row, fieldMap.confidence)),
      }
    })
    .filter(Boolean)
    .sort((a, b) => new Date(a.forecastedAt).getTime() - new Date(b.forecastedAt).getTime())
}

function seriesRows(rows, fields, panel) {
  const {valueField, timeField, labelField} = chartFields(panel, fields)
  const visual = String(panel?.visual_type || "line")
  const xField = ["line", "area"].includes(visual) ? timeField || labelField : labelField || timeField
  const xFieldType = fieldType(fields.find(field => fieldName(field) === xField))

  return rows
    .map((row, index) => {
      const value = numericValue(valueAt(row, valueField))
      if (value === null) return null

      const categoryValue = valueAt(row, xField)

      return {
        name:
          categoryValue === null || categoryValue === undefined || categoryValue === ""
            ? `Row ${index + 1}`
            : categoryValue,
        categoryField: xField,
        categoryFieldType: xFieldType,
        value,
      }
    })
    .filter(Boolean)
}

function gaugeDatum(rows, fields, panel) {
  const {valueField, denominatorField, labelField} = chartFields(panel, fields)
  const visual = String(panel?.visual_type || "gauge")
  const groupedAvailability = groupedAvailabilityDatum(rows, valueField, labelField)
  const row = rows[0] || {}
  const numerator =
    groupedAvailability?.numerator ??
    numericValue(valueAt(row, panel?.data_binding?.numerator_field || valueField)) ??
    0
  const denominator =
    groupedAvailability?.denominator ??
    numericValue(valueAt(row, denominatorField)) ??
    100
  const percent = denominator > 0 ? (numerator / denominator) * 100 : numerator
  const clamped = Math.max(0, Math.min(100, percent))
  const tone = gaugeTone(panel, clamped)
  const numeratorLabel =
    panel?.display_config?.numerator_label ||
    panel?.display_config?.value_label ||
    (visual === "availability" ? countLabel(numerator, "available", "available") : metricLabel(valueField, "current"))
  const denominatorLabel =
    panel?.display_config?.denominator_label ||
    panel?.display_config?.total_label ||
    (visual === "availability" ? countLabel(denominator, "monitored", "monitored") : metricLabel(denominatorField, "target"))
  const subject = entityLabel(panel)
  const contextLabel =
    panel?.display_config?.context_label ||
    (visual === "availability"
      ? `${formatValue(numerator)} of ${formatValue(denominator)} ${countLabel(denominator, subject)} available`
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

function groupedAvailabilityDatum(rows, valueField, labelField) {
  if (!valueField || !labelField) return null

  const normalizedLabel = String(labelField).toLowerCase()
  if (!["is_available", "available", "availability"].includes(normalizedLabel)) return null

  let numerator = 0
  let denominator = 0
  let matched = false

  rows.forEach(row => {
    const value = numericValue(valueAt(row, valueField))
    if (value === null) return

    const availability = booleanish(valueAt(row, labelField))
    if (availability === null) return

    matched = true
    denominator += value
    if (availability) numerator += value
  })

  return matched ? {numerator, denominator} : null
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

function ChartTooltip({active, payload, label, timezone, categoryField, categoryFieldType}) {
  if (!active || !payload?.length) return null
  const item = payload[0]
  const canonical = categoryCanonicalInstant(label, categoryFieldType)

  return (
    <div className="rounded-md border border-slate-700 bg-slate-950/95 px-3 py-2 text-xs shadow-xl shadow-cyan-950/30">
      <div className="font-medium text-slate-100">
        {canonical ? (
          <DashboardPanelUserTime value={canonical} timezone={timezone} />
        ) : (
          dashboardPanelCategoryLabel(label, categoryField, {
            fieldType: categoryFieldType,
            timeZone: timezone,
            style: "tooltip",
          })
        )}
      </div>
      <div className="mt-1 font-mono text-slate-300">{formatValue(item.value)}</div>
    </div>
  )
}

function CapacityForecastTooltip({active, payload, label, timezone}) {
  if (!active || !payload?.length) return null

  const data = payload.find(item => item?.payload)?.payload || {}

  return (
    <div className="max-w-72 rounded-md border border-slate-700 bg-slate-950/95 px-3 py-2 text-xs shadow-xl shadow-cyan-950/30">
      <div className="font-medium text-slate-100">{data.label || label}</div>
      <div className="mt-1 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 font-mono text-slate-300">
        {data.forecastedAt ? (
          <>
            <span className="text-slate-500">Forecasted</span>
            <span><DashboardPanelUserTime value={data.forecastedAt} timezone={timezone} /></span>
          </>
        ) : null}
        <span className="text-slate-500">Current</span>
        <span>{formatValue(data.current)}</span>
        <span className="text-slate-500">Projected</span>
        <span>{formatValue(data.projected)}</span>
        {data.threshold !== null && data.threshold !== undefined ? (
          <>
            <span className="text-slate-500">Threshold</span>
            <span>{formatValue(data.threshold)}</span>
          </>
        ) : null}
        {data.exhaustionAt ? (
          <>
            <span className="text-slate-500">ETA</span>
            <span><DashboardPanelUserTime value={data.exhaustionAt} timezone={timezone} /></span>
          </>
        ) : null}
      </div>
    </div>
  )
}

function AxisChart({visual, rows, timezone}) {
  if (rows.length === 0) return <EmptyChart />

  const categoryField = rows[0]?.categoryField || ""
  const categoryFieldType = rows[0]?.categoryFieldType || "string"

  const common = {
    data: rows,
    margin: {top: 10, right: 18, bottom: 8, left: 0},
  }

  const axis = (
    <>
      <CartesianGrid stroke={GRID_STROKE} strokeOpacity={0.95} vertical={false} />
      <XAxis
        dataKey="name"
        tickFormatter={value =>
          dashboardPanelCategoryLabel(value, categoryField, {
            fieldType: categoryFieldType,
            timeZone: timezone,
            style: "axis",
          })
        }
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
      <Tooltip
        content={
          <ChartTooltip
            timezone={timezone}
            categoryField={categoryField}
            categoryFieldType={categoryFieldType}
          />
        }
      />
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

function latestCapacityForecast(rows) {
  return rows[rows.length - 1] || null
}

function firstForecastThreshold(rows) {
  return rows.find(row => row.threshold !== null && row.threshold !== undefined)?.threshold ?? null
}

function forecastStatusTone(status, exhaustionAt) {
  const normalized = String(status || "").toLowerCase()
  if (["skipped", "unknown"].includes(normalized)) return "text-slate-400"
  return exhaustionAt ? "text-amber-300" : "text-emerald-300"
}

function CapacityForecastChart({rows, fields, panel, timezone}) {
  const chartRows = useMemo(() => capacityForecastRows(rows, fields), [rows, fields])
  if (chartRows.length === 0) return <EmptyChart message="No capacity forecast data" />

  const latest = latestCapacityForecast(chartRows)
  const threshold = firstForecastThreshold(chartRows)
  const unit = panel?.display_config?.unit || ""
  const axisMetadata = timeAxisMetadata(chartRows.map(row => row.forecastedAt), timezone)

  return (
    <div
      className="flex h-full min-h-0 flex-col gap-3 overflow-hidden text-slate-400"
      {...axisMetadata}
    >
      <div className="grid shrink-0 grid-cols-1 gap-2 text-xs sm:grid-cols-3">
        <div className="rounded-md border border-slate-800 bg-slate-950/50 px-3 py-2">
          <div className="text-slate-500">Current</div>
          <div className="mt-1 font-mono text-sm text-slate-100">
            {formatValue(latest.current)}
            {unit}
          </div>
        </div>
        <div className="rounded-md border border-slate-800 bg-slate-950/50 px-3 py-2">
          <div className="text-slate-500">Projected</div>
          <div className="mt-1 font-mono text-sm text-cyan-200">
            {formatValue(latest.projected)}
            {unit}
          </div>
        </div>
        <div className="rounded-md border border-slate-800 bg-slate-950/50 px-3 py-2">
          <div className="text-slate-500">Exhaustion ETA</div>
          <div
            className={`mt-1 truncate font-mono text-sm ${forecastStatusTone(latest.status, latest.exhaustionAt)}`}
          >
            {latest.exhaustionAt ? (
              <DashboardPanelUserTime value={latest.exhaustionAt} timezone={timezone} />
            ) : (
              "Outside horizon"
            )}
          </div>
        </div>
      </div>
      <div className="min-h-0 flex-1">
        <ResponsiveChart>
          <ComposedChart data={chartRows} margin={{top: 10, right: 18, bottom: 8, left: 0}}>
            <CartesianGrid stroke={GRID_STROKE} strokeOpacity={0.95} vertical={false} />
            <XAxis
              dataKey="name"
              tickFormatter={value =>
                dashboardPanelTimeLabel(value, {timeZone: timezone, style: "axis"})
              }
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
            <Tooltip content={<CapacityForecastTooltip timezone={timezone} />} />
            <Legend wrapperStyle={{fontSize: "11px", color: TICK_STROKE}} />
            {threshold !== null ? (
              <ReferenceLine
                y={threshold}
                stroke="#f59e0b"
                strokeDasharray="4 4"
                label={{value: "threshold", fill: "#f59e0b", fontSize: 11, position: "insideTopRight"}}
              />
            ) : null}
            <Line
              name="Current"
              dataKey="current"
              type="monotone"
              stroke={CHART_COLORS[0]}
              strokeWidth={2}
              dot={false}
              activeDot={{r: 4}}
            />
            <Line
              name="Projected"
              dataKey="projected"
              type="monotone"
              stroke={CHART_COLORS[2]}
              strokeDasharray="6 4"
              strokeWidth={2}
              dot={false}
              activeDot={{r: 4}}
            />
            <Line
              name="Upper"
              dataKey="upper"
              type="monotone"
              stroke="#94a3b8"
              strokeDasharray="2 4"
              strokeWidth={1}
              dot={false}
            />
            <Line
              name="Lower"
              dataKey="lower"
              type="monotone"
              stroke="#64748b"
              strokeDasharray="2 4"
              strokeWidth={1}
              dot={false}
            />
          </ComposedChart>
        </ResponsiveChart>
      </div>
    </div>
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
    <div className="mt-2 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs leading-5">
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
    <div className="grid h-full min-h-0 grid-cols-1 items-center gap-2 overflow-hidden sm:grid-cols-[minmax(104px,34%)_minmax(0,1fr)] sm:gap-3">
      <div className="h-24 min-h-0 sm:h-full">
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
      <div className="min-w-0 overflow-hidden">
        <div className="line-clamp-2 text-sm font-medium leading-5 text-slate-300">{gauge.label}</div>
        <div className="mt-1 text-3xl font-semibold tracking-normal text-slate-100 sm:text-4xl">
          {gauge.display}<span className="text-xl text-slate-400">{gauge.unit}</span>
        </div>
        <div className="mt-2 line-clamp-2 text-xs leading-5 text-slate-400">{gauge.contextLabel}</div>
        <TrendBadge trend={trend} />
        <div className="mt-3 flex flex-wrap gap-2 text-xs leading-5 text-slate-400">
          <span className="max-w-full rounded border border-slate-700 px-2 py-0.5">
            {formatValue(gauge.numerator)} {gauge.numeratorLabel}
          </span>
          <span className="max-w-full rounded border border-slate-700 px-2 py-0.5">
            {formatValue(gauge.denominator)} {gauge.denominatorLabel}
          </span>
        </div>
      </div>
    </div>
  )
}

export function Component({
  panel = {},
  rows = [],
  fields = [],
  trend = null,
  timezone = DEFAULT_TIME_ZONE,
}) {
  const visual = String(panel.visual_type || "line")
  const chartRows = useMemo(() => seriesRows(rows, fields, panel), [rows, fields, panel])
  const axisMetadata = timeAxisMetadata(
    chartRows
      .filter(row => categoryCanonicalInstant(row.name, row.categoryFieldType))
      .map(row => row.name),
    timezone,
  )

  if (visual === "gauge" || visual === "availability") {
    return <GaugeChart rows={rows} fields={fields} panel={panel} trend={trend} />
  }

  if (["line", "area"].includes(visual) && isCapacityForecastPanel(panel, fields)) {
    return <CapacityForecastChart rows={rows} fields={fields} panel={panel} timezone={timezone} />
  }

  return (
    <div className="h-full min-h-0 overflow-hidden text-slate-400" {...axisMetadata}>
      <AxisChart visual={visual} rows={chartRows} timezone={timezone} />
    </div>
  )
}

export default Component
