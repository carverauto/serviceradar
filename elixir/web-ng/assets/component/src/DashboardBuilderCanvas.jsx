import React, {useEffect, useMemo, useRef, useState} from "react"
import {GridStack} from "gridstack"
import {loadSrqlMonaco} from "../../js/lib/srql/monaco_srql.js"
import SrqlEditor from "./SrqlEditor.jsx"

const VISUAL_LABELS = {
  table: "Table",
  stat: "Stat",
  count: "Count",
  gauge: "Gauge",
  availability: "Availability",
  line: "Line",
  area: "Area",
  bar: "Bar",
  category: "Category",
  status_list: "Status List",
  pivot: "Pivot Table",
}

function escapeSelector(value) {
  if (window.CSS?.escape) return window.CSS.escape(value)
  return String(value).replace(/["\\]/g, "\\$&")
}

function normalizeLayout(panel, index) {
  const layout = panel.layout || {}

  return {
    x: Number.isFinite(Number(layout.x)) ? Number(layout.x) : defaultX(panel, index),
    y: Number.isFinite(Number(layout.y)) ? Number(layout.y) : Math.floor(index / 3) * 4,
    w: Number.isFinite(Number(layout.w)) ? Number(layout.w) : defaultWidth(panel.visual_type),
    h: Number.isFinite(Number(layout.h)) ? Number(layout.h) : defaultHeight(panel.visual_type),
  }
}

function defaultWidth(visualType) {
  if (["table", "pivot", "line", "area"].includes(String(visualType))) return 12
  if (String(visualType) === "status_list") return 8
  return 4
}

function defaultHeight(visualType) {
  if (["table", "pivot"].includes(String(visualType))) return 8
  if (["line", "area", "bar", "category"].includes(String(visualType))) return 6
  return 4
}

function defaultX(panel, index) {
  const width = defaultWidth(panel.visual_type)
  if (width >= 12) return 0
  return (index * width) % 12
}

function valueAt(row, field) {
  if (!row || !field) return null
  return row[field]
}

function displayValue(value) {
  if (value === null || value === undefined || value === "") return "—"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}

function numericValue(value) {
  const next = Number(value)
  return Number.isFinite(next) ? next : null
}

function panelFields(panel) {
  return panel.preview?.fields || panel.field_metadata?.fields || []
}

function panelRows(panel) {
  return panel.preview?.rows || []
}

function firstField(fields, type) {
  return fields.find(field => field.type === type)?.name || fields[0]?.name || null
}

function firstFieldWhere(fields, predicate) {
  return fields.find(predicate)?.name || ""
}

function fieldOptions(fields, predicate = () => true) {
  return fields.filter(predicate).map(field => ({name: field.name, label: `${field.name} (${field.type})`}))
}

function FieldSelect({label, value, fields, onChange, predicate}) {
  const options = fieldOptions(fields, predicate)

  return (
    <label className="form-control">
      <span className="label-text text-xs">{label}</span>
      <select className="select select-sm w-full" value={value || ""} onChange={event => onChange(event.target.value)}>
        <option value="">Auto</option>
        {options.map(option => (
          <option key={option.name} value={option.name}>{option.label}</option>
        ))}
      </select>
    </label>
  )
}

function MiniVisual({panel}) {
  const rows = panelRows(panel)
  const fields = panelFields(panel)
  const binding = panel.data_binding || {}
  const visual = String(panel.visual_type || "table")

  if (["stat", "count", "gauge", "availability"].includes(visual)) {
    const valueField = binding.value_field || binding.numerator_field || firstField(fields, "number")
    const raw = numericValue(valueAt(rows[0], valueField)) || 0
    const unit = panel.display_config?.unit || (["gauge", "availability"].includes(visual) ? "%" : "")

    return (
      <div className="flex h-full flex-col justify-center gap-2">
        <div className="text-3xl font-semibold tracking-normal">
          {raw}
          <span className="text-base text-base-content/50">{unit}</span>
        </div>
        <div className="truncate text-xs text-base-content/55">{panel.display_config?.label || valueField || "Value"}</div>
        {["gauge", "availability"].includes(visual) ? (
          <div className="h-2 overflow-hidden rounded-full bg-base-300">
            <div className="h-full rounded-full bg-primary" style={{width: `${Math.max(0, Math.min(raw, 100))}%`}} />
          </div>
        ) : null}
      </div>
    )
  }

  if (visual === "pivot") {
    const rowField = binding.row_field || firstField(fields, "string")
    const columnField = binding.column_field || fields.find(field => ["status", "state", "health"].includes(field.name))?.name

    return (
      <div className="overflow-hidden rounded border border-base-300">
        <table className="table table-xs">
          <thead>
            <tr>
              <th>{rowField || "row"}</th>
              <th>{columnField || "column"}</th>
            </tr>
          </thead>
          <tbody>
            {rows.slice(0, 3).map((row, index) => (
              <tr key={index}>
                <td>{displayValue(valueAt(row, rowField))}</td>
                <td>{displayValue(valueAt(row, columnField))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }

  if (["line", "area", "bar", "category"].includes(visual)) {
    const valueField = binding.value_field || firstField(fields, "number")
    const values = rows.map(row => numericValue(valueAt(row, valueField)) || 0)
    const max = Math.max(...values, 1)

    return (
      <div className="flex h-24 items-end gap-1">
        {values.slice(0, 16).map((value, index) => (
          <div
            key={index}
            className="min-w-2 flex-1 rounded-t bg-primary/70"
            style={{height: `${Math.max(8, (value / max) * 100)}%`}}
          />
        ))}
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded border border-base-300">
      <table className="table table-xs">
        <thead>
          <tr>{fields.slice(0, 4).map(field => <th key={field.name}>{field.name}</th>)}</tr>
        </thead>
        <tbody>
          {rows.slice(0, 4).map((row, index) => (
            <tr key={index}>
              {fields.slice(0, 4).map(field => <td key={field.name}>{displayValue(valueAt(row, field.name))}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Inspector({panel, visualOptions, defaultQuery, srqlCompletions, error, onApply, onPreview, onRemove}) {
  const [draft, setDraft] = useState(() => draftFromPanel(panel, defaultQuery))
  const lastPreviewKey = useRef("")
  const visualDrafts = useRef({})

  useEffect(() => {
    const next = draftFromPanel(panel, defaultQuery)
    setDraft(next)
    visualDrafts.current = {[String(next.visual_type || "table")]: pickBindingDraft(next)}
    lastPreviewKey.current = draftPreviewKey(next)
  }, [panel, defaultQuery])

  useEffect(() => {
    if (!panel) return undefined
    const key = draftPreviewKey(draft)
    if (key === lastPreviewKey.current) return undefined

    const timeout = window.setTimeout(() => {
      lastPreviewKey.current = key
      onPreview(panel.id, draftPayload(draft))
    }, 450)

    return () => window.clearTimeout(timeout)
  }, [draft, onPreview, panel])

  if (!panel) {
    return (
      <div className="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
        Select a panel on the canvas, or add one from the palette.
      </div>
    )
  }

  const fields = panelFields(panel)
  const numericField = field => field.type === "number"
  const dimensionField = field => ["string", "boolean", "datetime"].includes(String(field.type))
  const visual = String(draft.visual_type || "table")
  const update = (key, value) => setDraft(current => ({...current, [key]: value}))
  const updateVisual = value => {
    setDraft(current => {
      const currentVisual = String(current.visual_type || "table")
      visualDrafts.current[currentVisual] = pickBindingDraft(current)

      const nextVisual = String(value || "table")
      const defaults = defaultsForVisual(nextVisual, fields, current)
      const restored = visualDrafts.current[nextVisual]

      return {
        ...current,
        ...emptyBindingDraft(),
        ...sanitizeBindingsForVisual(nextVisual, restored || defaults, fields, defaults),
        visual_type: nextVisual,
      }
    })
  }

  return (
    <div className="space-y-3">
      <label className="form-control">
        <span className="label-text text-xs">Title</span>
        <input className="input input-sm w-full" value={draft.panel_title} onChange={event => update("panel_title", event.target.value)} />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Dataset key</span>
        <input className="input input-sm w-full" value={draft.dataset_key} onChange={event => update("dataset_key", event.target.value)} />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Visual</span>
        <select className="select select-sm w-full" value={draft.visual_type} onChange={event => updateVisual(event.target.value)}>
          {visualOptions.map(option => (
            <option key={option.type} value={option.type}>{option.label || VISUAL_LABELS[option.type] || option.type}</option>
          ))}
        </select>
      </label>
      <label className="form-control">
        <span className="label-text text-xs">SRQL query</span>
        <SrqlEditor value={draft.srql_query} onChange={value => update("srql_query", value)} completions={srqlCompletions} error={error} />
      </label>
      {error ? <div className="rounded-lg border border-error/30 bg-error/10 p-2 text-xs text-error">{error}</div> : null}
      <label className="form-control">
        <span className="label-text text-xs">Unit</span>
        <input className="input input-sm w-full" value={draft.unit} onChange={event => update("unit", event.target.value)} />
      </label>
      {["stat", "count", "gauge", "availability"].includes(visual) ? (
        <div className="grid grid-cols-1 gap-2">
          <FieldSelect label="Value field" value={draft.value_field} fields={fields} predicate={numericField} onChange={value => update("value_field", value)} />
          <FieldSelect label="Numerator field" value={draft.numerator_field} fields={fields} predicate={numericField} onChange={value => update("numerator_field", value)} />
          <FieldSelect label="Denominator field" value={draft.denominator_field} fields={fields} predicate={numericField} onChange={value => update("denominator_field", value)} />
          <FieldSelect label="Label field" value={draft.label_field} fields={fields} onChange={value => update("label_field", value)} />
        </div>
      ) : null}
      {visual === "pivot" ? (
        <div className="grid grid-cols-1 gap-2">
          <FieldSelect label="Rows" value={draft.row_field} fields={fields} predicate={dimensionField} onChange={value => update("row_field", value)} />
          <FieldSelect label="Columns" value={draft.column_field} fields={fields} predicate={dimensionField} onChange={value => update("column_field", value)} />
          <FieldSelect label="Values" value={draft.value_field} fields={fields} predicate={numericField} onChange={value => update("value_field", value)} />
          <label className="form-control">
            <span className="label-text text-xs">Aggregate</span>
            <select className="select select-sm w-full" value={draft.aggregate || "sum"} onChange={event => update("aggregate", event.target.value)}>
              {["sum", "avg", "min", "max", "count"].map(value => <option key={value} value={value}>{value}</option>)}
            </select>
          </label>
          <label className="form-control">
            <span className="label-text text-xs">Empty value</span>
            <input className="input input-sm w-full" value={draft.empty_value} onChange={event => update("empty_value", event.target.value)} />
          </label>
        </div>
      ) : null}
      {["line", "area", "bar", "category", "status_list"].includes(visual) ? (
        <div className="grid grid-cols-1 gap-2">
          {["line", "area"].includes(visual) ? (
            <FieldSelect label="Time field" value={draft.time_field} fields={fields} predicate={field => field.type === "datetime"} onChange={value => update("time_field", value)} />
          ) : null}
          <FieldSelect label="Value field" value={draft.value_field} fields={fields} predicate={numericField} onChange={value => update("value_field", value)} />
          <FieldSelect label="Label field" value={draft.label_field} fields={fields} onChange={value => update("label_field", value)} />
          {visual === "status_list" ? (
            <FieldSelect label="Status field" value={draft.status_field} fields={fields} onChange={value => update("status_field", value)} />
          ) : null}
        </div>
      ) : null}
      {["stat", "count", "gauge", "availability"].includes(visual) ? (
        <label className="form-control">
          <span className="label-text text-xs">Compare to</span>
          <select className="select select-sm w-full" value={draft.trend_mode} onChange={event => update("trend_mode", event.target.value)}>
            <option value="">No comparison</option>
            <option value="last_hour">Last hour</option>
            <option value="same_time_yesterday">Same time yesterday</option>
            <option value="same_time_last_week">Same time last week</option>
            <option value="custom">Custom SRQL</option>
          </select>
        </label>
      ) : null}
      {draft.trend_mode === "custom" ? (
        <label className="form-control">
          <span className="label-text text-xs">Custom trend SRQL</span>
          <SrqlEditor value={draft.trend_query} onChange={value => update("trend_query", value)} completions={srqlCompletions} />
        </label>
      ) : null}
      <div className="flex gap-2">
        <button type="button" className="btn btn-sm btn-primary" onClick={() => onApply(panel.id, draftPayload(draft))}>
          Apply
        </button>
        <button type="button" className="btn btn-sm btn-error btn-outline" onClick={() => onRemove(panel.id)}>
          Remove
        </button>
      </div>
    </div>
  )
}

function draftFromPanel(panel, defaultQuery) {
  const binding = panel?.data_binding || {}
  const visualConfig = panel?.visual_config || {}

  return {
    dataset_key: panel?.dataset_key || "primary",
    panel_title: panel?.title || "Panel",
    srql_query: panel?.srql_query || defaultQuery || "",
    visual_type: String(panel?.visual_type || "table"),
    unit: panel?.display_config?.unit || "",
    value_field: binding.value_field || "",
    numerator_field: binding.numerator_field || "",
    denominator_field: binding.denominator_field || "",
    label_field: binding.label_field || "",
    row_field: binding.row_field || "",
    column_field: binding.column_field || "",
    time_field: binding.time_field || "",
    status_field: binding.status_field || "",
    aggregate: binding.aggregate || "sum",
    empty_value: binding.empty_value || "0",
    trend_mode: visualConfig.trend_mode || (visualConfig.trend_query ? "custom" : ""),
    trend_query: panel?.trend_query || visualConfig.trend_query || "",
  }
}

function draftPayload(draft) {
  const trendQuery = synthesizeTrendQuery(draft)

  return {
    ...draft,
    trend_query: trendQuery,
  }
}

function draftPreviewKey(draft) {
  return JSON.stringify(draftPayload(draft))
}

function emptyBindingDraft() {
  return {
    value_field: "",
    numerator_field: "",
    denominator_field: "",
    label_field: "",
    row_field: "",
    column_field: "",
    time_field: "",
    status_field: "",
    aggregate: "sum",
    empty_value: "0",
  }
}

function pickBindingDraft(draft) {
  const bindings = {}
  for (const key of Object.keys(emptyBindingDraft())) {
    bindings[key] = draft?.[key] || ""
  }

  bindings.aggregate = draft?.aggregate || "sum"
  bindings.empty_value = draft?.empty_value || "0"
  return bindings
}

function visualBindingKeys(visualType) {
  const visual = String(visualType || "table")

  if (["stat", "count", "gauge", "availability"].includes(visual)) {
    return ["value_field", "numerator_field", "denominator_field", "label_field"]
  }

  if (visual === "pivot") return ["row_field", "column_field", "value_field", "aggregate", "empty_value"]
  if (["line", "area"].includes(visual)) return ["time_field", "value_field", "label_field"]
  if (["bar", "category"].includes(visual)) return ["value_field", "label_field"]
  if (visual === "status_list") return ["value_field", "label_field", "status_field"]

  return []
}

function validField(value, fields, predicate = () => true) {
  if (!value) return false
  return fields.some(field => field.name === value && predicate(field))
}

function sanitizeBindingsForVisual(visualType, bindings, fields, defaults = emptyBindingDraft()) {
  const visual = String(visualType || "table")
  const numeric = field => field.type === "number"
  const dimension = field => ["string", "boolean", "datetime"].includes(String(field.type))
  const datetime = field => field.type === "datetime"
  const next = {}

  for (const key of visualBindingKeys(visual)) {
    const value = bindings?.[key] || defaults[key] || ""

    if (key === "aggregate") {
      next[key] = ["sum", "avg", "min", "max", "count"].includes(value) ? value : defaults[key] || "sum"
    } else if (key === "empty_value") {
      next[key] = value || defaults[key] || "0"
    } else if (key === "value_field" || key === "numerator_field" || key === "denominator_field") {
      next[key] = validField(value, fields, numeric) ? value : defaults[key] || ""
    } else if (key === "time_field") {
      next[key] = validField(value, fields, datetime) ? value : defaults[key] || ""
    } else if (key === "row_field" || key === "column_field") {
      next[key] = validField(value, fields, dimension) ? value : defaults[key] || ""
    } else {
      next[key] = validField(value, fields) ? value : defaults[key] || ""
    }
  }

  return next
}

function defaultsForVisual(visualType, fields, current = {}) {
  const visual = String(visualType || "table")
  const numeric = field => field.type === "number"
  const dimension = field => ["string", "boolean", "datetime"].includes(String(field.type))
  const datetime = field => field.type === "datetime"
  const defaults = emptyBindingDraft()
  const currentBindings = pickBindingDraft(current)

  if (["stat", "count", "gauge", "availability"].includes(visual)) {
    return {
      ...defaults,
      value_field: validField(currentBindings.value_field, fields, numeric) ? currentBindings.value_field : firstFieldWhere(fields, numeric),
      numerator_field: validField(currentBindings.numerator_field, fields, numeric) ? currentBindings.numerator_field : firstFieldWhere(fields, numeric),
      denominator_field: "",
      label_field: validField(currentBindings.label_field, fields) ? currentBindings.label_field : firstFieldWhere(fields, field => !numeric(field)),
    }
  }

  if (visual === "pivot") {
    const dimensions = fields.filter(dimension)

    return {
      ...defaults,
      row_field: dimensions[0]?.name || "",
      column_field: dimensions[1]?.name || dimensions[0]?.name || "",
      value_field: validField(currentBindings.value_field, fields, numeric) ? currentBindings.value_field : firstFieldWhere(fields, numeric),
      aggregate: currentBindings.aggregate || "sum",
      empty_value: currentBindings.empty_value || "0",
    }
  }

  if (["line", "area"].includes(visual)) {
    return {
      ...defaults,
      time_field: firstFieldWhere(fields, datetime),
      value_field: validField(currentBindings.value_field, fields, numeric) ? currentBindings.value_field : firstFieldWhere(fields, numeric),
      label_field: validField(currentBindings.label_field, fields) ? currentBindings.label_field : firstFieldWhere(fields, field => !numeric(field)),
    }
  }

  if (["bar", "category"].includes(visual)) {
    return {
      ...defaults,
      value_field: validField(currentBindings.value_field, fields, numeric) ? currentBindings.value_field : firstFieldWhere(fields, numeric),
      label_field: validField(currentBindings.label_field, fields, dimension) ? currentBindings.label_field : firstFieldWhere(fields, dimension),
    }
  }

  if (visual === "status_list") {
    return {
      ...defaults,
      value_field: validField(currentBindings.value_field, fields, numeric) ? currentBindings.value_field : firstFieldWhere(fields, numeric),
      label_field: validField(currentBindings.label_field, fields, dimension) ? currentBindings.label_field : firstFieldWhere(fields, dimension),
      status_field:
        validField(currentBindings.status_field, fields) ?
          currentBindings.status_field :
          firstFieldWhere(fields, field => ["status", "state", "health"].includes(field.name)) || firstFieldWhere(fields, dimension),
    }
  }

  return defaults
}

function synthesizeTrendQuery(draft) {
  if (draft.trend_mode === "custom") return draft.trend_query || ""
  if (!draft.trend_mode) return ""

  const windowByMode = {
    last_hour: "last_1h",
    same_time_yesterday: "yesterday",
    same_time_last_week: "last_week",
  }
  const window = windowByMode[draft.trend_mode]
  if (!window) return ""

  const base = stripSrqlTimeTokens(draft.srql_query || "")
  return `${base} time:${window}`.trim()
}

function stripSrqlTimeTokens(query) {
  return splitSrqlTokens(query)
    .filter(token => !token.startsWith("time:"))
    .join(" ")
    .trim()
}

function splitSrqlTokens(query) {
  const tokens = []
  let current = ""
  let quote = null
  let escaped = false

  for (const ch of String(query || "")) {
    if (escaped) {
      current += ch
      escaped = false
      continue
    }

    if (ch === "\\") {
      current += ch
      escaped = true
      continue
    }

    if ((ch === "\"" || ch === "'") && !quote) {
      quote = ch
      current += ch
      continue
    }

    if (quote && ch === quote) {
      quote = null
      current += ch
      continue
    }

    if (!quote && /\s/.test(ch)) {
      if (current) {
        tokens.push(current)
        current = ""
      }
      continue
    }

    current += ch
  }

  if (current) tokens.push(current)
  return tokens
}

function draftForStorage(dashboardParams, panels) {
  return {
    dashboard: dashboardParams,
    panels: panels.map(panel => {
      const {preview: _preview, ...rest} = panel
      return rest
    }),
  }
}

function writeDraftToStorage(key, dashboardParams, panels) {
  try {
    window.localStorage.setItem(key, JSON.stringify(draftForStorage(dashboardParams, panels)))
  } catch (_error) {
    // Browser privacy modes and quota limits can reject synchronous localStorage writes.
  }
}

export default function DashboardBuilderCanvas({
  panels = [],
  visualOptions = [],
  selectedId = "",
  canManage = false,
  defaultQuery = "",
  dashboardParams = {},
  inspectorErrors = {},
  srqlCompletions = [],
  draftStorageKey = "",
  pushEvent = () => {},
}) {
  const gridRef = useRef(null)
  const gridInstance = useRef(null)
  const panelsById = useMemo(() => new Map(panels.map(panel => [panel.id, panel])), [panels])
  const selectedPanel = panelsById.get(selectedId) || panels[0] || null
  const restoredRef = useRef(false)

  useEffect(() => {
    loadSrqlMonaco()
  }, [])

  useEffect(() => {
    if (!draftStorageKey || restoredRef.current) return
    restoredRef.current = true
    const stored = window.localStorage.getItem(draftStorageKey)
    if (!stored || panels.length > 0) return

    try {
      const draft = JSON.parse(stored)
      if (draft?.panels?.length) pushEvent("restore_canvas_draft", draft)
    } catch (_error) {
      window.localStorage.removeItem(draftStorageKey)
    }
  }, [draftStorageKey, panels.length, pushEvent])

  useEffect(() => {
    if (!draftStorageKey || !canManage) return
    if (panels.length === 0 && !dashboardParams?.title) return

    const timeout = window.setTimeout(() => {
      writeDraftToStorage(draftStorageKey, dashboardParams, panels)
    }, 1500)

    return () => window.clearTimeout(timeout)
  }, [canManage, dashboardParams, draftStorageKey, panels])

  useEffect(() => {
    if (!gridRef.current) return

    if (!gridInstance.current) {
      gridInstance.current = GridStack.init(
        {
          column: 12,
          cellHeight: 38,
          margin: 8,
          float: true,
          animate: true,
          disableDrag: !canManage,
          disableResize: !canManage,
          draggable: {handle: ".sr-dashboard-canvas-drag-handle"},
          resizable: {handles: "e,se,s,sw,w"},
        },
        gridRef.current,
      )

      gridInstance.current.on("change", (_event, items) => {
        pushEvent("canvas_layout_change", {
          layouts: items
            .map(item => ({
              id: item.el?.dataset.panelId,
              x: item.x,
              y: item.y,
              w: item.w,
              h: item.h,
            }))
            .filter(item => item.id),
        })
      })
    }

    const grid = gridInstance.current
    const ids = new Set(panels.map(panel => panel.id))
    grid.getGridItems().forEach(item => {
      if (!ids.has(item.dataset.panelId)) {
        grid.removeWidget(item, false)
      }
    })

    grid.batchUpdate()
    panels.forEach((panel, index) => {
      const item = gridRef.current.querySelector(`[data-panel-id="${escapeSelector(panel.id)}"]`)
      if (!item) return
      const layout = normalizeLayout(panel, index)
      if (!item.gridstackNode) {
        grid.makeWidget(item)
      }
      grid.update(item, layout)
    })
    grid.batchUpdate(false)

    return undefined
  }, [panels, canManage, pushEvent])

  useEffect(() => {
    if (!gridInstance.current) return
    gridInstance.current.enableMove(canManage)
    gridInstance.current.enableResize(canManage)
  }, [canManage])

  useEffect(() => {
    return () => {
      if (gridInstance.current) {
        gridInstance.current.destroy(false)
        gridInstance.current = null
      }
    }
  }, [])

  return (
    <div className="grid min-h-[520px] grid-cols-1 gap-4 xl:grid-cols-[220px_minmax(0,1fr)_320px]">
      <aside className="rounded-lg border border-base-300 bg-base-100 p-3">
        <div className="mb-3 text-sm font-semibold">Palette</div>
        <div className="grid grid-cols-2 gap-2 xl:grid-cols-1">
          {visualOptions.map(option => (
            <button
              key={option.type}
              type="button"
              className="btn btn-sm justify-start"
              disabled={!canManage}
              onClick={() => pushEvent("canvas_add_panel", {visualType: option.type})}
            >
              {option.label || VISUAL_LABELS[option.type] || option.type}
            </button>
          ))}
        </div>
      </aside>

      <main className="rounded-lg border border-base-300 bg-base-200/40 p-3">
        <div ref={gridRef} className="grid-stack min-h-[480px]">
          {panels.map((panel, index) => {
            const layout = normalizeLayout(panel, index)
            const selected = panel.id === selectedId
            const compact = layout.h <= 4 || layout.w <= 4

            return (
              <div
                key={panel.id}
                className="grid-stack-item"
                data-panel-id={panel.id}
                gs-x={layout.x}
                gs-y={layout.y}
                gs-w={layout.w}
                gs-h={layout.h}
              >
                <div
                  className={`grid-stack-item-content rounded-lg border bg-base-100 shadow-sm ${selected ? "border-primary" : "border-base-300"}`}
                  onClick={() => pushEvent("canvas_select_panel", {id: panel.id})}
                >
                  <div className="sr-dashboard-canvas-drag-handle flex cursor-move items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
                    <div className="min-w-0">
                      <div className="truncate text-sm font-semibold">{panel.title}</div>
                      {!compact ? (
                        <div className="truncate font-mono text-[11px] text-base-content/45">{panel.srql_query}</div>
                      ) : null}
                    </div>
                    <span className="badge badge-xs badge-outline">{VISUAL_LABELS[panel.visual_type] || panel.visual_type}</span>
                  </div>
                  <div className="h-[calc(100%-48px)] overflow-hidden p-3">
                    <MiniVisual panel={panel} />
                  </div>
                </div>
              </div>
            )
          })}
        </div>
        {panels.length === 0 ? (
          <div className="flex min-h-[480px] items-center justify-center rounded-lg border border-dashed border-base-300 text-sm text-base-content/60">
            Add a visualization from the palette to start building the dashboard.
          </div>
        ) : null}
      </main>

      <aside className="rounded-lg border border-base-300 bg-base-100 p-3">
        <div className="mb-3 text-sm font-semibold">Inspector</div>
        <Inspector
          panel={selectedPanel}
          visualOptions={visualOptions}
          defaultQuery={defaultQuery}
          srqlCompletions={srqlCompletions}
          error={selectedPanel ? inspectorErrors[selectedPanel.id] : null}
          onApply={(id, draft) => pushEvent("canvas_update_panel", {id, panel: draft})}
          onPreview={(id, draft) => pushEvent("canvas_preview_panel", {id, panel: draft})}
          onRemove={id => pushEvent("remove_panel", {id})}
        />
      </aside>
    </div>
  )
}
