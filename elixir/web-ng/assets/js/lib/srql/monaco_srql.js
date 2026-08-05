import {tokenize} from "./tokenizer.js"

const SRQL_LANGUAGE_ID = "serviceradar-srql"
const SRQL_MARKER_OWNER = "serviceradar-srql"
const CATALOG_URL = "/api/srql/catalog"
const BOOLEAN_VALUES = ["true", "false"]
const SORT_DIRECTIONS = ["asc", "desc"]
const TIME_VALUES = ["last_1h", "last_24h", "last_7d", "last_30d"]
const CONTROL_DESCRIPTIONS = {
  "agg:": "Bucket aggregation: avg, min, max, sum, count, or rate.",
  "bucket:": "Group rows into fixed time buckets for a chart (e.g. 5m, 1h).",
  "by:": "Group or aggregate results by a field.",
  "group:": "Group results by a field.",
  "in:": "Choose the SRQL entity to query.",
  "limit:": "Limit the number of returned rows.",
  "series:": "Split buckets into one series per distinct value of a field.",
  "site:": "Filter results to a site.",
  "sort:": "Sort results by a field (append :asc or :desc).",
  "stats:": "Collapse rows into summary values (e.g. sum(bytes_total) as bytes by app).",
  "status:": "Filter results by status.",
  "tag:": "Filter results by tag.",
  "time:": "Choose a relative time window.",
  "type:": "Filter results by type.",
  "value_field:": "Which numeric field the bucket aggregation reads.",
  where: "Start a field filter clause.",
}
let monacoPromise = null

function globalState() {
  window.__serviceradarSrqlEditor = window.__serviceradarSrqlEditor || {
    completions: [],
    catalog: null,
    languageRegistered: false,
  }

  return window.__serviceradarSrqlEditor
}

// Share the structured catalog cache with the SRQLInput hook so both editors
// issue a single conditional GET and stay in sync.
function catalogCache() {
  window.__srqlCatalog ||= {etag: null, data: null}
  return window.__srqlCatalog
}

function loadSrqlCatalog({force = false} = {}) {
  const cache = catalogCache()
  // Always revalidate via ETag so hot-reloaded catalog fields (e.g. events.id)
  // show up without a full page reload. `force` also drops the in-memory body.
  if (!force && cache.data && cache.freshUntil && Date.now() < cache.freshUntil) {
    return Promise.resolve(cache.data)
  }

  cache.inflight ||= fetch(CATALOG_URL, {headers: cache.etag ? {"If-None-Match": cache.etag} : {}})
    .then(response => {
      if (response.status === 304 && cache.data) {
        cache.freshUntil = Date.now() + 30_000
        return cache.data
      }
      if (!response.ok) throw new Error(`SRQL catalog request failed with ${response.status}`)

      cache.etag = response.headers.get("etag")
      return response.json().then(data => {
        cache.data = data
        cache.freshUntil = Date.now() + 30_000
        return data
      })
    })
    .finally(() => {
      cache.inflight = null
    })

  return cache.inflight
}

export function setSrqlCompletions(completions = []) {
  globalState().completions = completions
}

export function ensureSrqlLanguage(monaco, completions = []) {
  const state = globalState()
  state.completions = completions

  // Kick off (or reuse) the catalog fetch so the completion provider can be
  // entity-aware. Until it resolves the provider falls back to the flat list.
  loadSrqlCatalog()
    .then(catalog => {
      state.catalog = catalog
    })
    .catch(() => {})

  if (state.languageRegistered) return
  state.languageRegistered = true

  monaco.languages.register({id: SRQL_LANGUAGE_ID})
  monaco.languages.setMonarchTokensProvider(SRQL_LANGUAGE_ID, {
    tokenizer: {
      root: [
        [/\bin:[a-zA-Z0-9_-]+/, "keyword"],
        [/\b(limit|sort|time|where|group|by|from|select|as|and|or|not|latest)\b/, "keyword"],
        [/\b(ok|warn|fail|unknown|true|false|null)\b/, "constant"],
        [/"[^"]*"/, "string"],
        [/'[^']*'/, "string"],
        [/\b\d+(\.\d+)?\b/, "number"],
        [/[<>!=]=?|=~/, "operator"],
        [/[a-zA-Z_][\w.-]*/, "identifier"],
      ],
    },
  })
  monaco.languages.setLanguageConfiguration(SRQL_LANGUAGE_ID, {
    brackets: [["(", ")"], ["[", "]"]],
    autoClosingPairs: [
      {open: "\"", close: "\""},
      {open: "'", close: "'"},
      {open: "(", close: ")"},
      {open: "[", close: "]"},
    ],
  })
  monaco.languages.registerCompletionItemProvider(SRQL_LANGUAGE_ID, {
    // Space/`:`/`(`/`,` cover the boundaries where a fresh token starts; the
    // identifier characters keep suggestions live while typing a token.
    triggerCharacters: [":", " ", "(", ",", ".", "$", "_"],
    provideCompletionItems(model, position) {
      const word = model.getWordUntilPosition(position)
      const linePrefix = model.getValueInRange({
        startLineNumber: position.lineNumber,
        startColumn: 1,
        endLineNumber: position.lineNumber,
        endColumn: position.column,
      })
      const range = {
        startLineNumber: position.lineNumber,
        endLineNumber: position.lineNumber,
        startColumn: word.startColumn,
        endColumn: word.endColumn,
      }
      const state = globalState()
      const items = srqlCompletionItems({
        catalog: state.catalog,
        completions: state.completions,
        linePrefix,
      })

      return {suggestions: items.map(item => toMonacoSuggestion(monaco, item, range))}
    },
  })
}

// Pure, catalog-aware suggestion builder. Returns editor-agnostic descriptors
// so it can be unit tested without a Monaco instance.
export function srqlCompletionItems({catalog, completions = [], linePrefix = ""} = {}) {
  const state = tokenize(linePrefix, linePrefix.length)

  if (!catalog || !catalog.entities) return legacyItems(completions, state)

  switch (state.slot) {
    case "entity":
      return entityItems(catalog, {bare: true})
    case "field":
      return fieldItems(catalog, state)
    case "op":
      return operatorItems(catalog, state)
    case "value":
      return valueItems(catalog, state)
    default:
      return controlItems(catalog, state)
  }
}

function entityItems(catalog, {bare = false} = {}) {
  return Object.entries(catalog.entities).map(([id, entity]) => ({
    label: bare ? id : `in:${id}`,
    insert: bare ? `${id} ` : `in:${id} `,
    kind: "entity",
    detail: entity.label || "entity",
    documentation: `Query ${entity.label || id}.`,
    retrigger: true,
  }))
}

function controlItems(catalog, state) {
  const controls = (catalog.control_tokens || []).map(token => ({
    label: token,
    insert: token === "where" ? "where " : token,
    kind: "control",
    detail: "control",
    documentation: CONTROL_DESCRIPTIONS[token] || "SRQL control token.",
    retrigger: token.endsWith(":"),
  }))

  // A bare `field:value` filter is valid at the control position, so once an
  // entity is chosen lead with its fields; otherwise lead with `in:<entity>`.
  const lead = state?.entity && catalog.entities[state.entity] ? fieldItems(catalog, state) : entityItems(catalog)

  return [...lead, ...controls]
}

function fieldItems(catalog, state) {
  const entity = catalog.entities[state.entity]
  const arrayFields = new Set(entity?.fields?.array || [])
  const enums = entity?.enums || {}

  return entityFields(entity).map(field => {
    const isArray = arrayFields.has(field)

    return {
      label: field,
      // Array columns want parenthesized set syntax (e.g. discovery_sources:(awx));
      // the snippet auto-closes the paren and drops the cursor inside it.
      insert: isArray ? `${field}:($0)` : `${field}:`,
      snippet: isArray,
      kind: "field",
      detail: fieldType(entity, field),
      documentation: fieldDoc(state.entity, field, isArray, enums[field]),
      retrigger: true,
    }
  })
}

function operatorItems(catalog, state) {
  const operators = (catalog.operators || []).map(op => ({
    label: op,
    insert: op,
    kind: "operator",
    detail: "operator",
  }))

  // Right after `field:` the user usually wants a value, not another operator.
  // Lead with the field's known/boolean values when it has any.
  return [...valueItems(catalog, state), ...operators]
}

function valueItems(catalog, state) {
  const entity = catalog.entities[state.entity]
  const position = state.activeRange?.start ?? 0
  const field = nearestField(state.tokens, position)

  if (field && entity?.enums?.[field.text]) {
    return entity.enums[field.text].map(value => ({
      label: value,
      insert: value,
      kind: "enum",
      detail: `${field.text} value`,
      documentation: `Known value for ${field.text}.`,
    }))
  }

  if (field && (entity?.fields?.boolean || []).includes(field.text)) {
    return BOOLEAN_VALUES.map(value => ({label: value, insert: value, kind: "value", detail: "boolean"}))
  }

  if (isSortDirectionContext(state.tokens, position)) {
    return SORT_DIRECTIONS.map(value => ({label: value, insert: value, kind: "value", detail: "sort direction"}))
  }

  if (directValueControl(state.tokens, position)?.text === "time:") {
    return TIME_VALUES.map(value => ({label: value, insert: value, kind: "value", detail: "time range"}))
  }

  return []
}

function legacyItems(completions, state) {
  const afterIn = state.slot === "entity"

  return (completions || []).map(label => {
    const isEntity = label.startsWith("in:")
    const isControl = label.endsWith(":") || isEntity
    const insert = afterIn && isEntity ? label.slice(3) : label

    return {
      label: insert,
      insert,
      kind: isEntity ? "entity" : isControl ? "control" : "field",
      detail: isEntity ? "entity" : isControl ? "control" : "field",
    }
  })
}

function entityFields(entity) {
  if (!entity?.fields) return []

  return [...new Set(Object.values(entity.fields).flat().filter(Boolean))].sort()
}

function fieldType(entity, field) {
  const fields = entity?.fields || {}
  if ((fields.array || []).includes(field)) return "array"
  if ((fields.boolean || []).includes(field)) return "boolean"
  if ((fields.numeric || []).includes(field)) return "numeric"
  if (entity?.enums?.[field]) return "enum"
  return "field"
}

function fieldDoc(entityId, field, isArray, enumValues) {
  const scope = entityId ? `${entityId} results` : "results"
  if (isArray) return `Array field on ${scope}; use set syntax, e.g. ${field}:(value).`
  if (enumValues?.length) return `Filter ${scope}. Known values: ${enumValues.slice(0, 8).join(", ")}.`
  return `Filter ${scope} by ${field}.`
}

function nearestField(tokens, position) {
  return [...tokens].reverse().find(token => token.kind === "field" && token.end <= position) || null
}

function previousToken(tokens, position) {
  return [...tokens].reverse().find(token => token.end <= position) || null
}

function directValueControl(tokens, position) {
  const previous = previousToken(tokens, position)
  return previous?.kind === "control" ? previous : null
}

function isSortDirectionContext(tokens, position) {
  const previous = previousToken(tokens, position)
  const field = previous?.kind === "op" ? previousToken(tokens, previous.start) : null
  const control = field?.kind === "field" ? previousToken(tokens, field.start) : null

  return previous?.text === ":" && control?.text === "sort:"
}

function toMonacoSuggestion(monaco, item, range) {
  const kinds = monaco.languages.CompletionItemKind
  const kindMap = {
    entity: kinds.Module,
    control: kinds.Keyword,
    field: kinds.Field,
    operator: kinds.Operator,
    value: kinds.Value,
    enum: kinds.EnumMember,
  }
  // Priority ordering that reads well in every slot: fields/values lead over
  // controls and operators.
  const group = {entity: "0", field: "1", enum: "2", value: "3", control: "4", operator: "5"}

  const suggestion = {
    label: item.label,
    insertText: item.insert,
    detail: item.detail,
    documentation: item.documentation,
    kind: kindMap[item.kind] || kinds.Text,
    sortText: `${group[item.kind] || "5"}-${item.label}`,
    range,
  }

  if (item.snippet) suggestion.insertTextRules = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
  if (item.retrigger) suggestion.command = {id: "editor.action.triggerSuggest", title: "Suggest"}

  return suggestion
}

export function applySrqlMarkers(monaco, editor, error) {
  const model = editor?.getModel()
  if (!model) return

  if (!error) {
    monaco.editor.setModelMarkers(model, SRQL_MARKER_OWNER, [])
    return
  }

  monaco.editor.setModelMarkers(model, SRQL_MARKER_OWNER, [
    {
      ...markerRangeForError(model, error),
      severity: monaco.MarkerSeverity.Error,
      message: errorMessage(error),
    },
  ])
}

export function loadSrqlMonaco() {
  if (!monacoPromise) {
    monacoPromise = import("monaco-editor/esm/vs/editor/editor.api")
  }

  return monacoPromise
}

export async function createSrqlEditor(container, options = {}) {
  const monaco = await loadSrqlMonaco()
  ensureSrqlLanguage(monaco, options.completions || [])

  const compact = options.compact === true
  const darkTheme = document.documentElement.dataset.theme === "dark" || document.documentElement.classList.contains("dark")
  const editor = monaco.editor.create(container, {
    value: options.value || "",
    language: SRQL_LANGUAGE_ID,
    theme: darkTheme ? "vs-dark" : "vs",
    readOnly: options.disabled === true,
    automaticLayout: true,
    fixedOverflowWidgets: true,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    fontSize: compact ? 11 : 12,
    glyphMargin: false,
    lightbulb: {enabled: false},
    lineDecorationsWidth: compact ? 0 : 8,
    lineNumbers: compact ? "off" : "on",
    lineNumbersMinChars: compact ? 0 : 3,
    minimap: {enabled: false},
    overviewRulerLanes: 0,
    parameterHints: {enabled: false},
    quickSuggestions: {other: true, comments: false, strings: false},
    renderLineHighlight: compact ? "none" : "line",
    scrollBeyondLastLine: false,
    scrollbar: {vertical: compact ? "hidden" : "auto", horizontal: "auto", alwaysConsumeMouseWheel: false},
    suggest: {
      preview: true,
      showFields: true,
      showKeywords: true,
      showWords: false,
    },
    suggestOnTriggerCharacters: true,
    tabCompletion: "on",
    wordBasedSuggestions: "off",
    wordWrap: compact ? "off" : "on",
  })

  applySrqlMarkers(monaco, editor, options.error)

  return {monaco, editor}
}

function errorMessage(error) {
  if (!error) return ""
  if (typeof error === "string") return error
  return error.message || String(error)
}

function markerRangeForError(model, error) {
  const explicit = explicitRangeForError(model, error)
  if (explicit) return explicit

  const tokenRange = tokenRangeForError(model, errorMessage(error))
  if (tokenRange) return tokenRange

  const firstLine = firstNonBlankLine(model)
  const text = model.getLineContent(firstLine)
  const startIndex = text.search(/\S/)
  const startColumn = startIndex >= 0 ? startIndex + 1 : 1

  return {
    startLineNumber: firstLine,
    startColumn,
    endLineNumber: firstLine,
    endColumn: Math.max(startColumn + 1, model.getLineMaxColumn(firstLine)),
  }
}

function explicitRangeForError(model, error) {
  if (!error || typeof error !== "object") return null

  const line = integerInRange(error.line || error.startLineNumber, 1, model.getLineCount())
  const column = integerInRange(error.column || error.startColumn, 1, model.getLineMaxColumn(line || 1))
  if (!line || !column) return null

  const endLine = integerInRange(error.endLine || error.endLineNumber, line, model.getLineCount()) || line
  const endColumn =
    integerInRange(error.endColumn, column + 1, model.getLineMaxColumn(endLine)) ||
    Math.min(column + String(error.token || "").length + 1, model.getLineMaxColumn(endLine)) ||
    column + 1

  return {
    startLineNumber: line,
    startColumn: column,
    endLineNumber: endLine,
    endColumn: Math.max(column + 1, endColumn),
  }
}

function tokenRangeForError(model, message) {
  const candidates = errorTokenCandidates(message)

  for (const candidate of candidates) {
    for (let lineNumber = 1; lineNumber <= model.getLineCount(); lineNumber += 1) {
      const line = model.getLineContent(lineNumber)
      const index = line.indexOf(candidate)
      if (index >= 0) {
        return {
          startLineNumber: lineNumber,
          startColumn: index + 1,
          endLineNumber: lineNumber,
          endColumn: index + candidate.length + 1,
        }
      }
    }
  }

  return null
}

function errorTokenCandidates(message) {
  if (!message) return []

  const quoted = [...String(message).matchAll(/["']([^"']{1,160})["']/g)].map(match => match[1])
  const bare =
    String(message)
      .match(/\b(?:in|time|sort|limit|bucket|agg|value_field|series|[a-zA-Z_][\w.-]*):[^\s,\]}]+/g) || []

  return [...quoted, ...bare]
    .map(candidate => candidate.trim())
    .filter(candidate => candidate.length > 0)
    .sort((a, b) => b.length - a.length)
}

function firstNonBlankLine(model) {
  for (let lineNumber = 1; lineNumber <= model.getLineCount(); lineNumber += 1) {
    if (model.getLineContent(lineNumber).trim() !== "") return lineNumber
  }

  return 1
}

function integerInRange(value, min, max) {
  const integer = Number(value)
  if (!Number.isInteger(integer)) return null
  return Math.min(max, Math.max(min, integer))
}
