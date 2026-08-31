const DATE_PART_OPTIONS = Object.freeze({
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  numberingSystem: "latn",
  calendar: "iso8601",
})

const OFFSET_PATTERN = /(?:GMT|UTC)[+-]\d{1,2}(?::?\d{2})?/
const ISO_INSTANT_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/

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

function compatibleFormatter(intl, locale, options) {
  try {
    return new intl.DateTimeFormat(locale, options)
  } catch (error) {
    if (options.timeZoneName !== "shortOffset") throw error

    const {timeZoneName: _timeZoneName, ...fallbackOptions} = options
    return new intl.DateTimeFormat(locale, fallbackOptions)
  }
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
  try {
    const offsetFormatter = new intl.DateTimeFormat(locale, {
      ...DATE_PART_OPTIONS,
      timeZone,
      timeZoneName: "shortOffset",
    })
    const namedOffset = formatterParts(offsetFormatter, instant)?.find((part) => part.type === "timeZoneName")?.value

    if (namedOffset && OFFSET_PATTERN.test(namedOffset)) return namedOffset
  } catch (_error) {
    // Some supported Intl runtimes reject shortOffset but still provide formatToParts.
  }

  return numericOffsetFromParts(intl, locale, timeZone, instant)
}

function styleRequiresOffset(style) {
  return style === "full" || style === "tooltip"
}

function validInstant(iso) {
  if (typeof iso !== "string") return false

  const match = ISO_INSTANT_PATTERN.exec(iso)
  if (!match) return false

  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number)
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

  if (month < 1 || month > 12 || day < 1 || day > daysInMonth[month - 1]) return false
  if (hour > 23 || minute > 59 || second > 59) return false

  return !Number.isNaN(new Date(iso).getTime())
}

export function canonicalUtcInstant(value) {
  let instant

  if (typeof value === "string") {
    if (!validInstant(value)) return null
    const match = ISO_INSTANT_PATTERN.exec(value)
    if (match[8] === "Z") return value
    instant = new Date(value)

    const canonical = instant.toISOString()
    return match[7] ? `${canonical.slice(0, 19)}${match[7]}Z` : canonical
  } else if (value instanceof Date) {
    instant = value
  } else if (typeof value === "number" && Number.isFinite(value)) {
    instant = new Date(value)
  } else {
    return null
  }

  return Number.isNaN(instant.getTime()) ? null : instant.toISOString()
}

export function formatUserTime(iso, {timeZone, style = "full", locale, intl = globalThis.Intl} = {}) {
  if (!timeZone || !STYLE_OPTIONS[style] || !intl?.DateTimeFormat || !validInstant(iso)) return null

  const instant = new Date(iso)

  try {
    const formatter = compatibleFormatter(intl, locale, {...STYLE_OPTIONS[style], timeZone})
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
  if (typeof value === "string") return validInstant(value) ? value : null

  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value.toISOString()
  if (typeof value !== "number" || !Number.isFinite(value)) return null

  const instant = new Date(value)

  return Number.isNaN(instant.getTime()) ? null : instant.toISOString()
}

export function userTimeFormatter(options = {}) {
  return (value) => {
    const canonical = axisCanonicalValue(value)
    if (!canonical) return ""

    return formatUserTime(canonical, options)?.text || canonical
  }
}

export function axisUserTimeFormatter(options = {}) {
  return userTimeFormatter({...options, style: "axis"})
}
