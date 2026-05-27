import {tokenize} from "../lib/srql/tokenizer.js"

const BOOLEAN_VALUES = ["true", "false"]
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

export default {
  mounted() {
    this.input = this.el
    this.frame = this.input.closest("[data-srql-input-frame]")
    this.overlay = this.frame?.querySelector("[data-srql-input-overlay]")
    this.dropdown = this.frame?.querySelector("[data-srql-input-dropdown]")
    this.hint = this.frame?.querySelector("[data-srql-input-hint]")
    this.catalog = null
    this.candidates = []
    this.highlighted = 0
    this.dropdownOpen = false

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

    this.input.addEventListener("input", this.onInput)
    this.input.addEventListener("click", this.onClick)
    this.input.addEventListener("focus", this.onInput)
    this.input.addEventListener("keydown", this.onKeydown)
    this.input.addEventListener("blur", this.onBlur)
    this.input.addEventListener("scroll", this.onScroll)
    window.addEventListener("phx:srql:catalog-stale", this.onCatalogStale)

    this.loadCatalog()
  },

  destroyed() {
    this.input.removeEventListener("input", this.onInput)
    this.input.removeEventListener("click", this.onClick)
    this.input.removeEventListener("focus", this.onInput)
    this.input.removeEventListener("keydown", this.onKeydown)
    this.input.removeEventListener("blur", this.onBlur)
    this.input.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("phx:srql:catalog-stale", this.onCatalogStale)
  },

  async loadCatalog({force = false} = {}) {
    const cache = ensureCache()
    if (!force && cache.data) {
      this.catalog = cache.data
      this.updateState()
      return
    }

    try {
      cache.inflight ||= fetchCatalog(cache)
      await cache.inflight
      this.catalog = cache.data

      this.updateState()
    } catch (_error) {
      this.catalog = null
      this.close()
    } finally {
      cache.inflight = null
    }
  },

  handleKeydown(event) {
    if (!this.catalog) return

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
    if (!this.catalog) return

    this.state = tokenize(this.input.value, this.input.selectionStart ?? this.input.value.length)
    this.candidates = this.buildCandidates(this.state)
    this.highlighted = Math.min(this.highlighted, Math.max(this.candidates.length - 1, 0))
    this.dropdownOpen = open && this.candidates.length > 0

    this.renderOverlay()
    this.renderDropdown()
    this.renderHint()
  },

  buildCandidates(state) {
    const raw = this.activeText(state).toLowerCase()
    let candidates = []

    if (state.slot === "entity") {
      candidates = Object.entries(this.catalog.entities || {}).map(([value, entity]) => ({
        value,
        label: value,
        detail: entity.label || "Entity",
        slot: "entity",
      }))
    } else if (state.slot === "field") {
      candidates = this.fieldsForEntity(state.entity).map(value => ({value, label: value, detail: "Field", slot: "field"}))
    } else if (state.slot === "op") {
      candidates = (this.catalog.operators || []).map(value => ({value, label: value, detail: "Operator", slot: "op"}))
    } else if (state.slot === "value") {
      candidates = this.valueCandidates(state)
    } else if (state.slot === "control") {
      candidates = unique(["in:", ...(this.catalog.control_tokens || [])]).map(value => ({
        value,
        label: value,
        detail: "Control",
        slot: "control",
      }))
    }

    if (!raw || this.forceAllCandidates) return candidates

    return rankedMatches(candidates, raw)
  },

  activeText(state) {
    if (state.activeToken) return state.activeToken.text
    if (!state.activeRange) return ""
    return this.input.value.slice(state.activeRange.start, state.activeRange.end)
  },

  fieldsForEntity(entityId) {
    if (!entityId) return allFields(this.catalog.entities || {})

    const entity = this.catalog.entities?.[entityId]
    const fields = entity?.fields || {}
    return unique(Object.values(fields).flat())
  },

  valueCandidates(state) {
    const field = nearestField(state.tokens, state.activeRange?.start ?? 0)
    if (field && this.booleanFields(state.entity).includes(field.text)) {
      return BOOLEAN_VALUES.map(value => ({value, label: value, detail: "Boolean", slot: "value"}))
    }

    const control = nearestControl(state.tokens, state.activeRange?.start ?? 0)
    if (control?.text === "time:") {
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
    if (token.kind === "field") return this.fieldsForEntity(this.state.entity)
    if (token.kind === "op") return this.catalog.operators || []
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
    if (token.kind === "field") return Boolean(this.state.entity) && !this.fieldsForEntity(this.state.entity).includes(token.text)
    if (token.kind === "op") return !(this.catalog.operators || []).includes(token.text)
    if (token.kind === "control") {
      const controls = new Set(["in:", "where", ...(this.catalog.control_tokens || [])])
      return !controls.has(token.text)
    }

    return false
  },

  accept(candidate) {
    if (!candidate || !this.state) return

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

  if (response.status === 304 && cache.data) return
  if (!response.ok) throw new Error(`SRQL catalog request failed with ${response.status}`)

  cache.etag = response.headers.get("etag")
  cache.data = await response.json()
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

function nearestControl(tokens, position) {
  return [...tokens].reverse().find(token => token.kind === "control" && token.end <= position)
}
