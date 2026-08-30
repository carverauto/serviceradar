const DATE_PART_OPTIONS = Object.freeze({
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
})

const OFFSET_PATTERN = /(?:GMT|UTC)[+-]\d{1,2}(?::?\d{2})?/
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$/

export const STYLE_OPTIONS = Object.freeze({
  full: Object.freeze({
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    timeZoneName: "shortOffset",
  }),
  compact: Object.freeze({
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }),
  date: Object.freeze({year: "numeric", month: "short", day: "2-digit"}),
  time: Object.freeze({hour: "2-digit", minute: "2-digit", second: "2-digit"}),
  axis: Object.freeze({hour: "2-digit", minute: "2-digit"}),
  tooltip: Object.freeze({
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    timeZoneName: "shortOffset",
  }),
})

function formatterParts(formatter, instant) {
  if (typeof formatter.formatToParts !== "function") return null

  return formatter.formatToParts(instant)
}

function numericOffsetFromParts(intl, locale, timeZone, instant) {
  const localFormatter = new intl.DateTimeFormat(locale, {...DATE_PART_OPTIONS, timeZone})
  const utcFormatter = new intl.DateTimeFormat(locale, {...DATE_PART_OPTIONS, timeZone: "Etc/UTC"})
  const localParts = dateParts(formatterParts(localFormatter, instant))
  const utcParts = dateParts(formatterParts(utcFormatter, instant))

  if (!localParts || !utcParts) return null

  const localMilliseconds = Date.UTC(...localParts)
  const utcMilliseconds = Date.UTC(...utcParts)
  const offsetMinutes = Math.round((localMilliseconds - utcMilliseconds) / 60_000)

  if (!Number.isFinite(offsetMinutes)) return null

  const sign = offsetMinutes < 0 ? "-" : "+"
  const absoluteMinutes = Math.abs(offsetMinutes)
  const hours = String(Math.floor(absoluteMinutes / 60)).padStart(2, "0")
  const minutes = String(absoluteMinutes % 60).padStart(2, "0")

  return `GMT${sign}${hours}:${minutes}`
}

function dateParts(parts) {
  if (!parts) return null

  const values = Object.fromEntries(
    parts
      .filter((part) => ["year", "month", "day", "hour", "minute", "second"].includes(part.type))
      .map((part) => [part.type, Number(part.value)]),
  )

  if ([values.year, values.month, values.day, values.hour, values.minute, values.second].some(Number.isNaN)) return null

  return [values.year, values.month - 1, values.day, values.hour, values.minute, values.second]
}

function numericOffset(intl, locale, timeZone, instant) {
  const offsetFormatter = new intl.DateTimeFormat(locale, {
    ...DATE_PART_OPTIONS,
    timeZone,
    timeZoneName: "shortOffset",
  })
  const namedOffset = formatterParts(offsetFormatter, instant)?.find((part) => part.type === "timeZoneName")?.value

  if (namedOffset && OFFSET_PATTERN.test(namedOffset)) return namedOffset

  return numericOffsetFromParts(intl, locale, timeZone, instant)
}

function styleRequiresOffset(style) {
  return style === "full" || style === "tooltip"
}

function validInstant(iso) {
  return typeof iso === "string" && ISO_INSTANT_PATTERN.test(iso) && !Number.isNaN(new Date(iso).getTime())
}

export function formatUserTime(iso, {timeZone, style = "full", locale, intl = globalThis.Intl} = {}) {
  if (!timeZone || !STYLE_OPTIONS[style] || !intl?.DateTimeFormat || !validInstant(iso)) return null

  const instant = new Date(iso)

  try {
    const formatter = new intl.DateTimeFormat(locale, {...STYLE_OPTIONS[style], timeZone})
    const offset = numericOffset(intl, locale, timeZone, instant)
    const initialText = formatter.format(instant)

    if (!initialText || !offset) return null

    const text = styleRequiresOffset(style) && !OFFSET_PATTERN.test(initialText)
      ? `${initialText} ${offset}`
      : initialText

    return {text, offset, canonical: iso}
  } catch (_error) {
    return null
  }
}

function axisCanonicalValue(value) {
  if (validInstant(value)) return value

  const instant = value instanceof Date ? value : new Date(value)

  return Number.isNaN(instant.getTime()) ? null : instant.toISOString()
}

export function axisUserTimeFormatter(options = {}) {
  return (value) => {
    const canonical = axisCanonicalValue(value)
    if (!canonical) return ""

    return formatUserTime(canonical, {...options, style: "axis"})?.text || canonical
  }
}
