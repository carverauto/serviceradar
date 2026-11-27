// Value and time formatting for SrTimeseries. Units match
// ServiceRadarUI.Charts.Format. Time zone and locale are caller options;
// nothing here reads a host application's user_time helpers.

const UNITS = [
  "number",
  "percent",
  "bytes",
  "bytes_per_sec",
  "bits_per_sec",
  "count",
  "count_per_sec",
  "ms",
  "hz",
]

export function formatValue(value, unit) {
  if (value === null || value === undefined || Number.isNaN(value)) return "-"
  const n = Number(value)
  if (!Number.isFinite(n)) return "-"

  switch (unit) {
    case "percent":
      return `${round(n, 1)}%`
    case "bytes":
      return si(n, ["B", "KB", "MB", "GB", "TB", "PB"])
    case "bytes_per_sec":
      return `${si(n, ["B", "KB", "MB", "GB", "TB", "PB"])}/s`
    case "bits_per_sec":
      return si(n, ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"])
    case "hz":
      return si(n, ["Hz", "KHz", "MHz", "GHz"])
    case "count":
      return compact(n)
    case "count_per_sec":
      return `${compact(n)}/s`
    case "ms":
      return n >= 1000 ? `${round(n / 1000, 2)} s` : `${round(n, 1)} ms`
    default:
      return compact(n)
  }
}

export function formatInstant(iso, opts = {}) {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ""

  const span = Number(opts.spanMs) || 0
  const format =
    opts.format === "auto" || !opts.format
      ? span > 2 * 86_400_000
        ? "date"
        : "time"
      : opts.format

  const timeZone = opts.timeZone || undefined
  const base = {timeZone, hourCycle: "h23"}
  let options
  if (format === "date") options = {...base, month: "short", day: "numeric"}
  else if (format === "datetime")
    options = {...base, month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"}
  else options = {...base, hour: "2-digit", minute: "2-digit"}

  return new Intl.DateTimeFormat(opts.locale || undefined, options).format(date)
}

export function units() {
  return UNITS
}

function si(value, labels) {
  let n = value
  let i = 0
  while (i < labels.length - 1 && Math.abs(n) >= 1000) {
    n /= 1000
    i += 1
  }
  return `${i === 0 ? round(n, 0) : round(n, 2)} ${labels[i]}`
}

function compact(value) {
  const abs = Math.abs(value)
  if (abs >= 1e9) return `${round(value / 1e9, 2)}G`
  if (abs >= 1e6) return `${round(value / 1e6, 2)}M`
  if (abs >= 1e4) return `${round(value / 1e3, 1)}K`
  if (abs >= 100) return round(value, 0)
  return round(value, 2)
}

function round(value, places) {
  const factor = 10 ** places
  const rounded = Math.round(value * factor) / factor
  if (places === 0) return String(Math.trunc(rounded))
  return String(rounded)
}
