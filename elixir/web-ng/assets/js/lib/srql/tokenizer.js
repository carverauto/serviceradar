const CONTROL_PREFIXES = ["in:", "where:", "limit:", "sort:", "time:", "status:", "type:", "tag:", "site:", "group:", "by:"]
const CLAUSE_CONTROLS = new Set(["where"])
const OPERATORS = [":contains", ":equals", ">=", "<=", "!=", ":", ">", "<"]

export function tokenize(query = "", cursor = query.length) {
  const text = String(query || "")
  const cursorIndex = clamp(cursor, 0, text.length)
  const tokens = []

  for (const match of text.matchAll(/\S+/g)) {
    parseSegment(match[0], match.index, tokens)
  }

  const activeToken = findActiveToken(tokens, cursorIndex)
  const activeRange =
    activeToken?.kind === "control" && activeToken.end === cursorIndex
      ? {start: cursorIndex, end: cursorIndex}
      : activeToken
        ? {start: activeToken.start, end: activeToken.end}
        : emptyRangeForCursor(text, cursorIndex, tokens)

  return {
    tokens,
    activeToken,
    activeRange,
    entity: currentEntity(tokens),
    slot: inferSlot(text, cursorIndex, tokens, activeToken),
  }
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

function findOperator(segment) {
  let best = null

  for (const op of OPERATORS) {
    const index = segment.indexOf(op)
    if (index <= 0) continue
    if (!best || index < best[1] || (index === best[1] && op.length > best[0].length)) best = [op, index]
  }

  return best
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

function emptyRangeForCursor(text, cursor, tokens) {
  const before = previousToken(tokens, cursor)

  if (before && before.end === cursor && before.kind === "control") {
    return {start: cursor, end: cursor}
  }

  const segmentStart = findSegmentStart(text, cursor)
  const segmentEnd = findSegmentEnd(text, cursor)
  return {start: segmentStart, end: segmentEnd}
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

function fieldBackedControl(control) {
  return control === "where:" || control === "sort:" || control === "group:" || control === "by:"
}

function findSegmentStart(text, cursor) {
  let index = cursor
  while (index > 0 && !/\s/.test(text[index - 1])) index -= 1
  return index
}

function findSegmentEnd(text, cursor) {
  let index = cursor
  while (index < text.length && !/\s/.test(text[index])) index += 1
  return index
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, Number.isFinite(value) ? value : max))
}
