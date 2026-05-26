import React, {useMemo} from "../../node_modules/react/index.js"
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
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"

const CHART_COLORS = ["#38bdf8", "#22c55e", "#f59e0b", "#ef4444", "#a78bfa"]
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

function formatAxisValue(value) {
  if (value === null || value === undefined || value === "") return ""
  const date = new Date(value)
  if (!Number.isNaN(date.getTime()) && String(value).includes("T")) {
    return date.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})
  }
  return String(value)
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
        name: formatAxisValue(valueAt(row, xField)) || `Row ${index + 1}`,
        value,
      }
    })
    .filter(Boolean)
}

function gaugeDatum(rows, fields, panel) {
  const {valueField, denominatorField} = chartFields(panel, fields)
  const row = rows[0] || {}
  const numerator = numericValue(valueAt(row, valueField)) || 0
  const denominator = numericValue(valueAt(row, denominatorField)) || 100
  const percent = denominator > 0 ? (numerator / denominator) * 100 : numerator
  const clamped = Math.max(0, Math.min(100, percent))
  const tone = gaugeTone(panel, clamped)

  return {
    percent: clamped,
    display: clamped.toFixed(1),
    numerator,
    denominator,
    tone,
    color: STATUS_COLORS[tone],
    label: panel?.display_config?.label || panel?.title || "Gauge",
    unit: panel?.display_config?.unit || "%",
  }
}

function EmptyChart({message = "No chartable data"}) {
  return (
    <div className="flex h-full min-h-32 items-center justify-center rounded-lg border border-dashed border-base-300 text-sm text-base-content/65">
      {message}
    </div>
  )
}

function ChartTooltip({active, payload, label}) {
  if (!active || !payload?.length) return null
  const item = payload[0]

  return (
    <div className="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-xs shadow-lg">
      <div className="font-medium text-base-content">{label}</div>
      <div className="mt-1 font-mono text-base-content/75">{formatValue(item.value)}</div>
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
      <CartesianGrid stroke="currentColor" strokeOpacity={0.12} vertical={false} />
      <XAxis
        dataKey="name"
        minTickGap={24}
        tick={{fontSize: 11, fill: "currentColor"}}
        tickLine={false}
        axisLine={false}
      />
      <YAxis
        width={44}
        tick={{fontSize: 11, fill: "currentColor"}}
        tickLine={false}
        axisLine={false}
      />
      <Tooltip content={<ChartTooltip />} />
    </>
  )

  if (visual === "bar" || visual === "category") {
    return (
      <ResponsiveContainer width="100%" height="100%" minWidth={1} minHeight={1}>
        <BarChart {...common}>
          {axis}
          <Bar dataKey="value" fill={CHART_COLORS[0]} radius={[6, 6, 0, 0]} maxBarSize={44} />
        </BarChart>
      </ResponsiveContainer>
    )
  }

  if (visual === "area") {
    return (
      <ResponsiveContainer width="100%" height="100%" minWidth={1} minHeight={1}>
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
      </ResponsiveContainer>
    )
  }

  return (
    <ResponsiveContainer width="100%" height="100%" minWidth={1} minHeight={1}>
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
    </ResponsiveContainer>
  )
}

function GaugeChart({rows, fields, panel}) {
  const gauge = gaugeDatum(rows, fields, panel)

  return (
    <div className="grid h-full min-h-44 grid-cols-1 items-center gap-4 sm:grid-cols-[minmax(160px,220px)_1fr]">
      <div className="h-40">
        <ResponsiveContainer width="100%" height="100%" minWidth={1} minHeight={1}>
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
        </ResponsiveContainer>
      </div>
      <div className="min-w-0">
        <div className="text-sm font-medium text-base-content/80">{gauge.label}</div>
        <div className="mt-1 text-4xl font-semibold tracking-normal text-base-content">
          {gauge.display}<span className="text-xl text-base-content/70">{gauge.unit}</span>
        </div>
        <div className="mt-3 flex flex-wrap gap-2 text-xs text-base-content/70">
          <span className="badge badge-sm badge-outline">{formatValue(gauge.numerator)} numerator</span>
          <span className="badge badge-sm badge-outline">{formatValue(gauge.denominator)} total</span>
        </div>
      </div>
    </div>
  )
}

export default function DashboardPanelChart({
  panel = {},
  rows = [],
  fields = [],
}) {
  const visual = String(panel.visual_type || "line")
  const chartRows = useMemo(() => seriesRows(rows, fields, panel), [rows, fields, panel])

  if (visual === "gauge" || visual === "availability") {
    return <GaugeChart rows={rows} fields={fields} panel={panel} />
  }

  return (
    <div className="h-56 min-h-56 text-base-content/70">
      <AxisChart visual={visual} rows={chartRows} />
    </div>
  )
}
