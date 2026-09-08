// Control tokens the engine reserves. A prefix missing from this list falls through to
// `findOperator`, which splits it on the `:` into a field token -- and since `bucket`,
// `agg`, `value_field`, `series` and `stats` are not fields on any entity, the editor
// then underlines them as unknown. Keep in sync with `@completion_control_tokens` in
// lib/serviceradar_web_ng_web/srql/catalog.ex, which gates the same tokens a second time.
const CONTROL_PREFIXES = [
  "in:",
  "limit:",
  "sort:",
  "time:",
  "status:",
  "type:",
  "tag:",
  "site:",
  "group:",
  "by:",
  "bucket:",
  "agg:",
  "value_field:",
  "series:",
  "stats:",
]
const CLAUSE_CONTROLS = new Set(["where"])
const OPERATORS = [":contains", ":equals", ">=", "<=", "!=", ":", ">", "<"]

// Mirrors `is_valid_jsonb_key` in rust/srql (query/devices/filters/jsonb.rs):
// non-empty, at most 64 bytes, and only ASCII [A-Za-z0-9_-]. Those characters
// are all single-byte, so the JS string length equals the Rust byte length.
const JSONB_KEY_PATTERN = /^[A-Za-z0-9_-]{1,64}$/

// Field prefixes the engine routes to arbitrary JSONB sub-key filters (see the
// `field.starts_with("metadata.")` / `"tags."` arms in
// rust/srql/src/query/devices/filters.rs). The whole `<prefix>.<key>` string is
// the field token; the value follows the `:`.
const DYNAMIC_KEY_PREFIXES = ["metadata", "tags"]

export function tokenize(query = "", cursor = query.length) {
  const text = String(query || "")
  const cursorIndex = clamp(cursor, 0, text.length)
  const tokens = []
  const segments = splitSegments(text)

  for (const segment of segments) {
    parseSegment(segment.text, segment.start, tokens)
  }

  const activeToken = findActiveToken(tokens, cursorIndex)
  const activeRange =
    activeToken?.kind === "control" && activeToken.end === cursorIndex
      ? {start: cursorIndex, end: cursorIndex}
      : activeToken
        ? {start: activeToken.start, end: activeToken.end}
        : emptyRangeForCursor(text, cursorIndex, tokens, segments)

  return {
    tokens,
    activeToken,
    activeRange,
    entity: currentEntity(tokens),
    slot: inferSlot(text, cursorIndex, tokens, activeToken),
  }
}

function splitSegments(text) {
  const segments = []
  let start = null
  let quote = null
  let escaped = false

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]

    if (start === null) {
      if (/\s/.test(char)) continue
      start = index
    }

    if (escaped) {
      escaped = false
      continue
    }

    if (char === "\\") {
      escaped = true
      continue
    }

    if (quote) {
      if (char === quote) quote = null
      continue
    }

    if (char === "\"" || char === "'") {
      quote = char
      continue
    }

    if (/\s/.test(char)) {
      segments.push({start, end: index, text: text.slice(start, index)})
      start = null
    }
  }

  if (start !== null) {
    segments.push({start, end: text.length, text: text.slice(start)})
  }

  return segments
}

function parseSegment(segment, start, tokens) {
  const prefixedControl = CONTROL_PREFIXES.find(prefix => segment.startsWith(prefix))

  if (prefixedControl) {
    tokens.push({
      start,
      end: start + prefixedControl.length,
      kind: "control",
      text: prefixedControl,
    })

    const remainder = segment.slice(prefixedControl.length)
    if (!remainder) return

    if (prefixedControl === "sort:") {
      parseSortRemainder(remainder, start + prefixedControl.length, tokens)
      return
    }

    tokens.push({
      start: start + prefixedControl.length,
      end: start + segment.length,
      kind: prefixedControl === "in:" ? "entity" : fieldBackedControl(prefixedControl) ? "field" : "value",
      text: remainder,
    })
    return
  }

  if (CLAUSE_CONTROLS.has(segment)) {
    tokens.push({start, end: start + segment.length, kind: "control", text: segment})
    return
  }

  const opMatch = findOperator(segment)
  if (opMatch) {
    const [op, index] = opMatch
    const field = segment.slice(0, index)
    const value = segment.slice(index + op.length)

    if (field) {
      tokens.push({start, end: start + field.length, kind: "field", text: field})
    }

    tokens.push({
      start: start + index,
      end: start + index + op.length,
      kind: "op",
      text: op,
    })

    if (value) {
      tokens.push({
        start: start + index + op.length,
        end: start + segment.length,
        kind: "value",
        text: value,
      })
    }

    return
  }

  tokens.push({start, end: start + segment.length, kind: "unknown", text: segment})
}

function parseSortRemainder(remainder, start, tokens) {
  const directionSeparator = lastUnquotedColon(remainder)

  if (directionSeparator <= 0) {
    tokens.push({start, end: start + remainder.length, kind: "field", text: remainder})
    return
  }

  const field = remainder.slice(0, directionSeparator)
  const direction = remainder.slice(directionSeparator + 1)

  tokens.push({start, end: start + field.length, kind: "field", text: field})
  tokens.push({
    start: start + directionSeparator,
    end: start + directionSeparator + 1,
    kind: "op",
    text: ":",
  })

  if (direction) {
    tokens.push({
      start: start + directionSeparator + 1,
      end: start + remainder.length,
      kind: "value",
      text: direction,
    })
  }
}

function lastUnquotedColon(segment) {
  let quote = null
  let escaped = false
  let colon = -1

  for (let index = 0; index < segment.length; index += 1) {
    const char = segment[index]

    if (escaped) {
      escaped = false
      continue
    }

    if (char === "\\") {
      escaped = true
      continue
    }

    if (quote) {
      if (char === quote) quote = null
      continue
    }

    if (char === "\"" || char === "'") {
      quote = char
      continue
    }

    if (char === ":") colon = index
  }

  return colon
}

function findOperator(segment) {
  let best = null

  for (const op of OPERATORS) {
    const index = indexOfOperator(segment, op)
    if (index <= 0) continue
    if (!best || index < best[1] || (index === best[1] && op.length > best[0].length)) best = [op, index]
  }

  return best
}

function indexOfOperator(segment, op) {
  let quote = null
  let escaped = false

  for (let index = 0; index <= segment.length - op.length; index += 1) {
    const char = segment[index]

    if (escaped) {
      escaped = false
      continue
    }

    if (char === "\\") {
      escaped = true
      continue
    }

    if (quote) {
      if (char === quote) quote = null
      continue
    }

    if (char === "\"" || char === "'") {
      quote = char
      continue
    }

    if (segment.startsWith(op, index)) return index
  }

  return -1
}

function inferSlot(text, cursor, tokens, activeToken) {
  if (activeToken) {
    if (activeToken.kind === "control" && activeToken.end === cursor) {
      if (activeToken.text === "in:") return "entity"
      if (fieldBackedControl(activeToken.text)) return "field"
      if (activeToken.text.endsWith(":")) return "value"
    }

    if (activeToken.kind === "unknown") return slotFromContext(tokens, activeToken.start)
    if (activeToken.kind === "op") return "op"
    return activeToken.kind
  }

  const before = previousToken(tokens, cursor)
  if (!before) return "control"

  const previousChar = text[cursor - 1] || ""
  if (/\s/.test(previousChar)) {
    if (before.kind === "control" && before.text === "where") return "field"
    return "control"
  }

  if (before.kind === "control") {
    if (before.text === "in:") return "entity"
    if (fieldBackedControl(before.text)) return "field"
    return "value"
  }

  if (before.kind === "field") return "op"
  if (before.kind === "op") return "value"

  return "none"
}

function slotFromContext(tokens, position) {
  const before = previousToken(tokens, position)
  if (!before) return "control"
  if (before.kind === "control" && before.text === "where") return "field"
  if (before.kind === "control" && before.text === "in:") return "entity"
  if (fieldBackedControl(before.text)) return "field"
  return "control"
}

function emptyRangeForCursor(text, cursor, tokens, segments) {
  const before = previousToken(tokens, cursor)

  if (before && before.end === cursor && before.kind === "control") {
    return {start: cursor, end: cursor}
  }

  const segment = segments.find(({start, end}) => start <= cursor && cursor <= end)
  if (segment) return {start: segment.start, end: segment.end}

  return {start: cursor, end: cursor}
}

function findActiveToken(tokens, cursor) {
  return tokens.find(token => token.start <= cursor && cursor <= token.end) || null
}

function previousToken(tokens, cursor) {
  return [...tokens].reverse().find(token => token.end <= cursor) || null
}

function currentEntity(tokens) {
  const entity = tokens.find(token => token.kind === "entity")
  return entity?.text || null
}

// Controls whose remainder is a field name rather than a literal value. Completion after
// these offers the entity's fields (`value_field:` -> value_fields, `series:` ->
// series_fields, both already exported in the catalog's `fields` map).
function fieldBackedControl(control) {
  return (
    control === "sort:" ||
    control === "group:" ||
    control === "by:" ||
    control === "value_field:" ||
    control === "series:"
  )
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, Number.isFinite(value) ? value : max))
}

// True when `key` is a valid JSONB sub-key, mirroring the engine's
// `is_valid_jsonb_key`. Used to decide whether a `<prefix>.<key>` field is a
// real dynamic-key filter or a typo.
export function isValidJsonbKey(key = "") {
  return JSONB_KEY_PATTERN.test(String(key))
}

// True when `field` is a dynamic JSONB-key filter the engine accepts but the
// static catalog can't enumerate, e.g. `metadata.gateway_id` or `tags.owner`.
// Editors must treat these as valid fields (no "unknown field" flag). Only the
// first `.` splits prefix from key, so nested paths like `metadata.a.b` fail the
// key check and stay flagged — matching the engine, which rejects them too.
export function isDynamicKeyField(field = "") {
  const text = String(field)
  const dot = text.indexOf(".")
  if (dot <= 0) return false

  return DYNAMIC_KEY_PREFIXES.includes(text.slice(0, dot)) && isValidJsonbKey(text.slice(dot + 1))
}
