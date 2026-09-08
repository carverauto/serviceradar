import {canonicalUtcInstant, formatUserTime} from "./user_time"

export function dashboardUserTimeHtml(value, {timeZone = "Etc/UTC", style = "full"} = {}) {
  if (!value) return "n/a"

  const raw = String(value)
  const canonical = canonicalUtcInstant(raw)
  if (!canonical) return escapeHtml(raw)

  const displayZone = timeZone || "Etc/UTC"
  const result = formatUserTime(canonical, {timeZone: displayZone, style})
  const text = result?.text || canonical
  const accessibleOffset = result && !text.includes(result.offset) ? `; ${result.offset}` : ""
  const title = `${canonical} (UTC); display zone ${displayZone}`
  const ariaLabel = `${text}${accessibleOffset}; display zone ${displayZone}; canonical UTC ${canonical}`

  return `<time datetime="${escapeAttr(canonical)}" data-user-time-zone="${escapeAttr(displayZone)}" data-user-time-style="${escapeAttr(style)}" title="${escapeAttr(title)}" aria-label="${escapeAttr(ariaLabel)}">${escapeHtml(text)}</time>`
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#96;")
}
