function canFormatTimeZone(intl, zone) {
  try {
    new intl.DateTimeFormat(undefined, {timeZone: zone})
    return true
  } catch (_error) {
    return false
  }
}

export function filterTimezoneOptions(serverZones, currentZone, options = {}) {
  const intl = Object.hasOwn(options, "intl") ? options.intl : globalThis.Intl
  const approved = new Set(Array.isArray(serverZones) ? serverZones : [])
  const baseline = ["Etc/UTC", currentZone].filter(Boolean)

  if (!intl?.DateTimeFormat) {
    return [...new Set(baseline)]
  }

  let candidates = [...approved]

  if (typeof intl.supportedValuesOf === "function") {
    try {
      const browserZones = new Set(intl.supportedValuesOf("timeZone"))
      candidates = candidates.filter(
        (zone) => zone === "Etc/UTC" || browserZones.has(zone) || canFormatTimeZone(intl, zone),
      )
    } catch (_error) {
      // Older or partial Intl implementations can expose this API but reject the
      // timeZone key. Probe the server-approved values instead of discarding them.
    }
  }

  const supported = candidates.filter((zone) => canFormatTimeZone(intl, zone))

  return [...new Set([...baseline, ...supported])]
    .sort((left, right) => {
      if (left === "Etc/UTC") return -1
      if (right === "Etc/UTC") return 1
      return left.localeCompare(right)
    })
}

function normalizeTimezoneQuery(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[_/]+/g, " ")
}

export function matchingTimezoneOptions(zones, query, currentZone) {
  const list = Array.isArray(zones) ? zones : []
  const normalizedQuery = (query ?? "").trim().toLowerCase()
  const current = (currentZone ?? "").trim().toLowerCase()

  if (normalizedQuery === "" || normalizedQuery === current) {
    return [...list]
  }

  const needle = normalizeTimezoneQuery(normalizedQuery)
  return list.filter((zone) => normalizeTimezoneQuery(zone).includes(needle))
}
