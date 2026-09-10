import {filterHistory, pushHistory} from "../lib/srql/queryHistory.js"
import {baseFieldName, isDynamicKeyField, tokenize} from "../lib/srql/tokenizer.js"

const BOOLEAN_VALUES = ["true", "false"]
const SORT_DIRECTIONS = ["asc", "desc"]
const TIME_VALUES = ["last_1h", "last_24h", "last_7d", "last_30d"]
const CONTROL_DESCRIPTIONS = {
  "by:": "Group or aggregate results by a field.",
  "group:": "Group results by a field.",
  "in:": "Choose the SRQL entity to query.",
  "limit:": "Limit the number of returned rows.",
  "site:": "Filter results to a site.",
  "sort:": "Sort results by a field.",
  "status:": "Filter results by status.",
  "tag:": "Filter results by tag.",
  "time:": "Choose a relative time window.",
  "type:": "Filter results by type.",
  where: "Start a field filter clause.",
}
const HINT_ROLE_LABELS = {
  control: "Control token",
  entity: "Entity",
  field: "Field",
  history: "Recent query",
  op: "Operator",
  value: "Value",
}

function ensureCache() {
  window.__srqlCatalog ||= {etag: null, data: null}
  return window.__srqlCatalog
}

function unique(values) {
  return [...new Set(values.filter(Boolean))].sort()
}

function timestampSortAliases(field) {
  return ["event_timestamp", "time", "timestamp"].includes(field)
    ? ["event_timestamp", "time", "timestamp"]
    : []
}

export default {
  mounted() {
    this.input = this.el
    this.frame = this.input.closest("[data-srql-input-frame]")
    this.form = this.input.closest("form")
    this.overlay = this.frame?.querySelector("[data-srql-input-overlay]")
    this.dropdown = this.frame?.querySelector("[data-srql-input-dropdown]")
    this.hint = this.frame?.querySelector("[data-srql-input-hint]")
    this.catalog = null
    this.candidates = []
    this.highlighted = 0
    this.dropdownOpen = false
    this.historyStorage = globalThis.localStorage

    // Native <datalist> (list=) races the custom dropdown: empty-bar history flashes
    // then a browser suggestion list of every field token paints over it.
    this.detachNativeDatalist()

    this.onInput = () => {
      this.forceAllCandidates = false
      this.updateState({open: true})
    }
    this.onClick = () =>
      window.requestAnimationFrame(() => {
        this.forceAllCandidates = true
        this.updateState({open: true})
      })
    this.onKeydown = event => this.handleKeydown(event)
    this.onBlur = () => setTimeout(() => this.close(), 120)
    this.onScroll = () => this.syncOverlayScroll()
    this.onCatalogStale = () => this.loadCatalog({force: true})
    this.onSubmit = () => this.recordHistory(this.input.value)

    this.input.addEventListener("input", this.onInput)
    this.input.addEventListener("click", this.onClick)
    this.input.addEventListener("focus", this.onInput)
    this.input.addEventListener("keydown", this.onKeydown)
    this.input.addEventListener("blur", this.onBlur)
    this.input.addEventListener("scroll", this.onScroll)
    this.form?.addEventListener("submit", this.onSubmit)
    window.addEventListener("phx:srql:catalog-stale", this.onCatalogStale)

    this.loadCatalog()
  },

  // LiveView re-morphs the input and can reattach list=/datalist from server HTML;
  // re-strip on every patch so the browser suggestion list cannot return.
  updated() {
    this.input = this.el
    this.frame = this.input.closest("[data-srql-input-frame]")
    this.overlay = this.frame?.querySelector("[data-srql-input-overlay]")
    this.dropdown = this.frame?.querySelector("[data-srql-input-dropdown]")
    this.hint = this.frame?.querySelector("[data-srql-input-hint]")
    this.detachNativeDatalist()
    if (this.input === document.activeElement) {
      this.updateState({open: true})
    }
  },

  destroyed() {
    this.input.removeEventListener("input", this.onInput)
    this.input.removeEventListener("click", this.onClick)
    this.input.removeEventListener("focus", this.onInput)
    this.input.removeEventListener("keydown", this.onKeydown)
    this.input.removeEventListener("blur", this.onBlur)
    this.input.removeEventListener("scroll", this.onScroll)
    this.form?.removeEventListener("submit", this.onSubmit)
    window.removeEventListener("phx:srql:catalog-stale", this.onCatalogStale)
  },

  async loadCatalog({force = false} = {}) {
    const cache = ensureCache()
    // Revalidate periodically so newly-added catalog fields (e.g. events.id)
    // are picked up after a hot reload without requiring a full page refresh.
    const fresh = cache.data && cache.freshUntil && Date.now() < cache.freshUntil
    // Keep the dropdown open across catalog load if the bar is focused so empty-bar
    // history does not flash and then get closed when the catalog arrives.
    const keepOpen = () => this.input === document.activeElement

    if (!force && fresh) {
      this.catalog = cache.data
      this.updateState({open: keepOpen()})
      return
    }

    try {
      cache.inflight ||= fetchCatalog(cache)
      await cache.inflight
      this.catalog = cache.data

      this.updateState({open: keepOpen()})
    } catch (_error) {
      this.catalog = null
      this.close()
    } finally {
      cache.inflight = null
    }
  },

  handleKeydown(event) {
    // History works without a catalog; token completions need one.
    if (!this.catalog && this.candidates.length === 0) return

    if ((event.key === "Tab" || event.key === "Enter") && this.candidates.length > 0) {
      event.preventDefault()
      this.accept(this.candidates[this.highlighted] || this.candidates[0])
      return
    }

    if (event.key === "ArrowDown" && this.candidates.length > 0) {
      event.preventDefault()
      this.dropdownOpen = true
      this.highlighted = (this.highlighted + 1) % this.candidates.length
      this.renderDropdown()
      return
    }

    if (event.key === "ArrowUp" && this.candidates.length > 0) {
      event.preventDefault()
      this.dropdownOpen = true
      this.highlighted = (this.highlighted - 1 + this.candidates.length) % this.candidates.length
      this.renderDropdown()
      return
    }

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  },

  updateState({open = false} = {}) {
    // LiveView patches (and some browsers) re-bind list=; strip before every open.
    this.detachNativeDatalist()

    const value = this.input.value
    const selection = this.input.selectionStart ?? value.length

    if (!this.catalog) {
      // Catalog still loading — still surface recent queries on an empty bar.
      this.state = null
      this.candidates = value.trim() ? [] : this.historyCandidates()
      this.highlighted = Math.min(this.highlighted, Math.max(this.candidates.length - 1, 0))
      this.dropdownOpen = open && this.candidates.length > 0
      this.renderDropdown()
      return
    }

    this.state = tokenize(value, selection)
    this.candidates = this.buildCandidates(this.state)
    this.highlighted = Math.min(this.highlighted, Math.max(this.candidates.length - 1, 0))
    this.dropdownOpen = open && this.candidates.length > 0

    this.renderOverlay()
    this.renderDropdown()
    this.renderHint()
  },

  recordHistory(query) {
    pushHistory(query, this.historyStorage)
  },

  detachNativeDatalist() {
    if (!this.input) return

    const listId = this.input.getAttribute("list") || (this.input.id ? `${this.input.id}-completions` : null)
    this.input.removeAttribute("list")
    // Also disable browser autocomplete chrome that can look like our dropdown.
    this.input.setAttribute("autocomplete", "off")
    this.input.setAttribute("autocapitalize", "off")
    this.input.setAttribute("autocorrect", "off")
    this.input.setAttribute("spellcheck", "false")

    if (listId) document.getElementById(listId)?.remove()
    // Sweep any leftover datalists near the frame (LiveView may reinsert them).
    this.frame?.parentElement?.querySelectorAll("datalist")?.forEach(node => {
      if (node.id?.endsWith("-completions")) node.remove()
    })
  },

  historyCandidates(filter = this.input?.value || "") {
    return filterHistory(filter, this.historyStorage).map(value => ({
      value,
      label: value,
      detail: "Recent",
      slot: "history",
    }))
  },

  buildCandidates(state) {
    const fullQuery = (this.input?.value ?? "").trim()

    // Empty bar → Chrome-style recent list (no token noise).
    if (!fullQuery) return this.historyCandidates("")

    const raw = this.candidateFilterText(state).toLowerCase()
    let candidates = []

    if (state.slot === "entity") {
      candidates = Object.entries(this.catalog.entities || {}).map(([value, entity]) => ({
        value,
        label: value,
        detail: entity.label || "Entity",
        slot: "entity",
      }))
    } else if (state.slot === "field") {
      candidates = this.fieldSlotCandidates(state)
    } else if (state.slot === "op") {
      candidates = (this.catalog.operators || []).map(value => ({value, label: value, detail: "Operator", slot: "op"}))
    } else if (state.slot === "value") {
      candidates = this.valueCandidates(state)
    } else if (state.slot === "control") {
      const controls = unique(["in:", ...(this.catalog.control_tokens || [])]).map(value => ({
        value,
        label: value,
        detail: "Control",
        slot: "control",
      }))

      // A bare `field:value` filter is valid here, so once an entity is chosen
      // surface its fields alongside the control tokens (this is what lets users
      // discover fields like `discovery_sources` after `in:devices`).
      candidates = state.entity ? [...this.fieldSlotCandidates(state), ...controls] : controls
    }

    // Once a known entity is in play (e.g. `in:devices …`), keep the dropdown
    // pure token autocomplete — do not interleave Recent rows with Field lists.
    // History only merges while the user is still choosing/retyping before that
    // (empty bar is handled above; partials like `in:dev` still match).
    const hasKnownEntity = Boolean(state.entity && this.catalog.entities?.[state.entity])
    if (!hasKnownEntity) {
      const history = this.historyCandidates(fullQuery).filter(
        // Bar already equals a recent entry — no point listing it above tokens.
        candidate => candidate.value !== fullQuery
      )
      if (history.length > 0) {
        candidates = [...history, ...candidates]
      }
    }

    if (!raw || this.forceAllCandidates) return candidates

    // History rows already filter on the full query string; only rank token rows.
    const historyRows = candidates.filter(candidate => candidate.slot === "history")
    const tokenRows = rankedMatches(
      candidates.filter(candidate => candidate.slot !== "history"),
      raw
    )
    return [...historyRows, ...tokenRows]
  },

  activeText(state) {
    if (state.activeToken) return state.activeToken.text
    if (!state.activeRange) return ""
    return this.input.value.slice(state.activeRange.start, state.activeRange.end)
  },

  // When filtering value candidates, ignore set/list punctuation so that the
  // partial value in `discovery_sources:(aw` matches `awx`.
  candidateFilterText(state) {
    const text = this.activeText(state)
    if (state.slot !== "value") return text
    return text.slice(valuePrefixOffset(text))
  },

  fieldsForEntity(entityId) {
    if (!entityId) return allFields(this.catalog.entities || {})

    const entity = this.catalog.entities?.[entityId]
    const fields = entity?.fields || {}
    return unique(Object.values(fields).flat())
  },

  sortableFieldsForEntity(entityId) {
    const entity = this.catalog.entities?.[entityId]
    const defaultSortField = entity?.default_sort?.field

    return unique([
      ...this.fieldsForEntity(entityId),
      defaultSortField,
      ...timestampSortAliases(defaultSortField),
    ])
  },

  fieldCandidates(state) {
    const position = state.activeRange?.start ?? state.activeToken?.start ?? 0

    if (isSortFieldContext(state.tokens, position)) {
      return this.sortableFieldsForEntity(state.entity).map(value => ({value, detail: "Sort field"}))
    }

    return this.fieldsForEntity(state.entity).map(value => ({value, detail: "Field"}))
  },

  fieldSlotCandidates(state) {
    const arrays = new Set(this.arrayFields(state.entity))

    return this.fieldCandidates(state).map(({value, detail}) => {
      const base = {value, label: value, detail, slot: "field"}
      // Only filter fields (not sort fields) get the parenthesized-set scaffold.
      return detail === "Field" && arrays.has(value) ? {...base, array: true} : base
    })
  },

  valueCandidates(state) {
    const field = nearestField(state.tokens, state.activeRange?.start ?? 0)
    const fieldName = field ? baseFieldName(field.text) : null

    if (fieldName) {
      const enumValues = this.enumValues(state.entity, fieldName)
      if (enumValues.length > 0) {
        return enumValues.map(value => ({value, label: value, detail: "Value", slot: "value"}))
      }
    }

    if (fieldName && this.booleanFields(state.entity).includes(fieldName)) {
      return BOOLEAN_VALUES.map(value => ({value, label: value, detail: "Boolean", slot: "value"}))
    }

    if (isSortDirectionContext(state.tokens, state.activeRange?.start ?? 0)) {
      return SORT_DIRECTIONS.map(value => ({value, label: value, detail: "Sort direction", slot: "value"}))
    }

    if (directValueControl(state.tokens, state.activeRange?.start ?? 0)?.text === "time:") {
      return TIME_VALUES.map(value => ({value, label: value, detail: "Time range", slot: "value"}))
    }

    return []
  },

  booleanFields(entityId) {
    if (!entityId) {
      return unique(
        Object.values(this.catalog.entities || {}).flatMap(entity => entity?.fields?.boolean || [])
      )
    }

    const entity = this.catalog.entities?.[entityId]
    return entity?.fields?.boolean || []
  },

  arrayFields(entityId) {
    if (!entityId) {
      return unique(Object.values(this.catalog.entities || {}).flatMap(entity => entity?.fields?.array || []))
    }

    return this.catalog.entities?.[entityId]?.fields?.array || []
  },

  enumValues(entityId, field) {
    if (!entityId || !field) return []

    return this.catalog.entities?.[entityId]?.enums?.[field] || []
  },

  renderOverlay() {
    if (!this.overlay || !this.state) return

    const fragment = document.createDocumentFragment()
    let index = 0

    for (const token of this.state.tokens) {
      if (token.start > index) fragment.append(document.createTextNode(this.input.value.slice(index, token.start)))

      const span = document.createElement("span")
      span.textContent = token.text
      if (this.isUnknown(token)) span.className = "srql-token--unknown"
      fragment.append(span)
      index = token.end
    }

    if (index < this.input.value.length) fragment.append(document.createTextNode(this.input.value.slice(index)))

    this.overlay.replaceChildren(fragment)
    this.syncOverlayScroll()
  },

  renderDropdown() {
    if (!this.dropdown) return

    if (!this.dropdownOpen || this.candidates.length === 0) {
      this.dropdown.classList.add("hidden")
      this.dropdown.replaceChildren()
      return
    }

    this.dropdown.classList.remove("hidden")
    this.dropdown.replaceChildren(
      ...this.candidates.map((candidate, index) => {
        const row = document.createElement("li")
        const item = document.createElement("button")
        item.type = "button"
        item.role = "option"
        item.className = `srql-dropdown__item ${index === this.highlighted ? "srql-dropdown__item--active" : ""}`
        if (candidate.slot === "history") item.classList.add("srql-dropdown__item--history")
        item.title = candidate.value
        const label = document.createElement("span")
        const detail = document.createElement("span")
        label.textContent = candidate.label
        detail.textContent = candidate.detail || ""
        item.append(label, detail)
        item.addEventListener("mousedown", event => event.preventDefault())
        item.addEventListener("click", () => this.accept(candidate))
        row.append(item)
        return row
      })
    )
  },

  renderHint() {
    if (!this.hint || !this.state?.activeToken || this.dropdownOpen) {
      this.hint?.classList.add("hidden")
      return
    }

    const token = this.state.activeToken
    if (token.kind === "unknown" || !this.input.matches(":focus")) {
      this.hint.classList.add("hidden")
      return
    }

    const values = this.hintValues(token).slice(0, 4).join(", ")
    const role = document.createElement("strong")
    const description = document.createElement("span")
    const preview = document.createElement("span")

    role.textContent = HINT_ROLE_LABELS[token.kind] || token.kind
    description.textContent = this.hintDescription(token)
    preview.textContent = values ? `Try: ${values}` : ""
    preview.className = "srql-hint__preview"

    this.hint.replaceChildren(role, description, preview)
    this.positionHint(token)
    this.hint.classList.remove("hidden")
  },

  hintValues(token) {
    if (token.kind === "entity") return Object.keys(this.catalog.entities || {})
    if (token.kind === "field") {
      const enumValues = this.enumValues(this.state.entity, baseFieldName(token.text))
      if (enumValues.length > 0) return enumValues
      return this.fieldsForEntity(this.state.entity)
    }
    if (token.kind === "op") return this.catalog.operators || []
    if (token.kind === "value") {
      const field = nearestField(this.state.tokens, token.start)
      const enumValues = field ? this.enumValues(this.state.entity, baseFieldName(field.text)) : []
      if (enumValues.length > 0) return enumValues
      return []
    }
    if (token.kind === "control") {
      if (token.text === "in:") return Object.keys(this.catalog.entities || {})
      if (token.text === "where") return this.fieldsForEntity(this.state.entity)
      if (token.text === "time:") return TIME_VALUES
      return this.catalog.control_tokens || []
    }
    return []
  },

  hintDescription(token) {
    if (token.kind === "control") return CONTROL_DESCRIPTIONS[token.text] || "Controls how the query is interpreted."
    if (token.kind === "entity") return this.catalog.entities?.[token.text]?.label || "Queryable SRQL entity."
    if (token.kind === "field" && this.state.entity) return `Filter or group ${this.state.entity} results.`
    if (token.kind === "field") return "Filter or group results after choosing an entity."
    if (token.kind === "op") return "Compare a field to a value."
    if (token.kind === "value") return "Value for the preceding field or control token."
    return ""
  },

  positionHint(token) {
    if (!this.frame || !this.hint) return

    const inputStyle = window.getComputedStyle(this.input)
    const paddingLeft = Number.parseFloat(inputStyle.paddingLeft) || 0
    const tokenLeft = paddingLeft + textWidth(this.input.value.slice(0, token.start), inputStyle) - this.input.scrollLeft
    const maxLeft = Math.max(0, this.frame.clientWidth - 240)
    const left = Math.max(0, Math.min(tokenLeft, maxLeft))

    this.hint.style.left = `${left}px`
    this.hint.style.right = "auto"
  },

  isUnknown(token) {
    if (token.kind === "entity") return !this.catalog.entities?.[token.text]
    // Resolve the engine's `!` negation prefix before every catalog lookup so
    // `!discovery_sources:(armis)` validates against `discovery_sources`.
    // `metadata.<key>` / `tags.<key>` are dynamic JSONB-key filters the engine
    // accepts but the catalog can't enumerate — never flag them as unknown.
    if (token.kind === "field" && isDynamicKeyField(baseFieldName(token.text))) return false
    if (token.kind === "field" && isSortFieldContext(this.state.tokens, token.start)) {
      // No `!` stripping here: negation is a filter op, meaningless on a sort
      // key, and the engine rejects `sort:!field`.
      return Boolean(this.state.entity) && !this.sortableFieldsForEntity(this.state.entity).includes(token.text)
    }

    if (token.kind === "field") return Boolean(this.state.entity) && !this.fieldsForEntity(this.state.entity).includes(baseFieldName(token.text))
    if (token.kind === "op") return !(this.catalog.operators || []).includes(token.text)
    if (token.kind === "value" && isSortDirectionContext(this.state.tokens, token.start)) {
      return !SORT_DIRECTIONS.includes(token.text.toLowerCase())
    }

    if (token.kind === "control") {
      const controls = new Set(["in:", "where", ...(this.catalog.control_tokens || [])])
      return !controls.has(token.text)
    }

    return false
  },

  accept(candidate) {
    if (!candidate) return

    // Recent queries replace the whole bar (address-bar style), then close so
    // Enter can submit on the next keypress instead of re-accepting a token.
    if (candidate.slot === "history") {
      this.input.value = candidate.value
      const end = candidate.value.length
      this.input.setSelectionRange(end, end)
      this.input.dispatchEvent(new Event("input", {bubbles: true}))
      this.input.dispatchEvent(new Event("change", {bubbles: true}))
      this.close()
      return
    }

    if (!this.state) return

    const selectionStart = this.input.selectionStart ?? 0
    const selectionEnd = this.input.selectionEnd ?? selectionStart
    const range = this.state.activeRange || (selectionStart !== selectionEnd ? {start: selectionStart, end: selectionEnd} : null)
    if (!range) return

    const replacementRange = this.replacementRange(candidate, range)
    this.input.setRangeText(completionText(candidate), replacementRange.start, replacementRange.end, "end")
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
    this.input.dispatchEvent(new Event("change", {bubbles: true}))
    this.close()
  },

  replacementRange(candidate, range) {
    if (candidate.slot === "value") {
      // Preserve any leading `(` / `,` when replacing the partial value inside a set.
      const tokenText = this.input.value.slice(range.start, range.end)
      const offset = valuePrefixOffset(tokenText)
      return offset > 0 ? {start: range.start + offset, end: range.end} : range
    }

    if (candidate.slot !== "field") return range

    const next = this.state.tokens.find(token => token.start === range.end && token.kind === "op" && token.text === ":")
    return next ? {start: range.start, end: next.end} : range
  },

  close() {
    this.dropdownOpen = false
    this.candidates = []
    this.forceAllCandidates = false
    this.dropdown?.classList.add("hidden")
    this.dropdown?.replaceChildren()
    this.hint?.classList.add("hidden")
  },

  syncOverlayScroll() {
    if (this.overlay) this.overlay.scrollLeft = this.input.scrollLeft
  },
}

async function fetchCatalog(cache) {
  const headers = cache.etag ? {"If-None-Match": cache.etag} : {}
  const response = await fetch("/api/srql/catalog", {headers})

  if (response.status === 304 && cache.data) {
    cache.freshUntil = Date.now() + 30_000
    return
  }
  if (!response.ok) throw new Error(`SRQL catalog request failed with ${response.status}`)

  cache.etag = response.headers.get("etag")
  cache.data = await response.json()
  cache.freshUntil = Date.now() + 30_000
}

function allFields(entities) {
  return unique(Object.values(entities).flatMap(entity => Object.values(entity?.fields || {}).flat()))
}

function rankedMatches(candidates, raw) {
  return candidates
    .map(candidate => ({candidate, rank: matchRank(candidate.value.toLowerCase(), raw)}))
    .filter(({rank}) => rank >= 0)
    .sort((left, right) => left.rank - right.rank || left.candidate.value.localeCompare(right.candidate.value))
    .map(({candidate}) => candidate)
}

function matchRank(value, raw) {
  if (value.startsWith(raw)) return 0
  if (value.includes(raw)) return 1
  if (isSubsequence(raw, value)) return 2
  return -1
}

function isSubsequence(needle, haystack) {
  let index = 0
  for (const char of haystack) {
    if (char === needle[index]) index += 1
    if (index === needle.length) return true
  }
  return false
}

function completionText(candidate) {
  if (candidate.slot === "entity") return `${candidate.value} `
  // Array columns need parenthesized set syntax, e.g. discovery_sources:(awx).
  if (candidate.slot === "field" && candidate.array) return `${candidate.value}:(`
  if (candidate.slot === "field" && !candidate.value.endsWith(":")) return `${candidate.value}:`
  if (candidate.slot === "control" && candidate.value === "where") return "where "
  return candidate.value
}

function textWidth(text, style) {
  const canvas = textWidth.canvas || (textWidth.canvas = document.createElement("canvas"))
  const context = canvas.getContext("2d")
  context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
  return context.measureText(text).width
}

function nearestField(tokens, position) {
  return [...tokens].reverse().find(token => token.kind === "field" && token.end <= position)
}

// Offset to the start of the value currently being typed within a token,
// skipping leading set punctuation (`(`, `[`, `,`).
function valuePrefixOffset(text) {
  let offset = 0
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]
    if (char === "(" || char === "[" || char === ",") offset = index + 1
  }
  return offset
}

function directValueControl(tokens, position) {
  const previous = previousToken(tokens, position)
  return previous?.kind === "control" ? previous : null
}

function isSortFieldContext(tokens, position) {
  return directValueControl(tokens, position)?.text === "sort:"
}

function isSortDirectionContext(tokens, position) {
  const previous = previousToken(tokens, position)
  const field = previous?.kind === "op" ? previousToken(tokens, previous.start) : null
  const control = field?.kind === "field" ? previousToken(tokens, field.start) : null

  return previous?.text === ":" && control?.text === "sort:"
}

function previousToken(tokens, position) {
  return [...tokens].reverse().find(token => token.end <= position)
}
