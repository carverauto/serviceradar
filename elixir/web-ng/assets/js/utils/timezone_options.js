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
  const current = approved.has(currentZone) ? currentZone : null
  const baseline = ["Etc/UTC", current].filter(Boolean)

  if (!intl?.DateTimeFormat || typeof intl.supportedValuesOf !== "function") {
    return [...new Set(baseline)]
  }

  let browserZones

  try {
    browserZones = new Set(intl.supportedValuesOf("timeZone"))
  } catch (_error) {
    return [...new Set(baseline)]
  }

  const survivors = [...approved].filter((zone) => zone === "Etc/UTC" || zone === current || browserZones.has(zone))
  const supported = survivors.filter((zone) => zone === current || canFormatTimeZone(intl, zone))

  return [...new Set(["Etc/UTC", ...supported, current].filter(Boolean))]
    .sort((left, right) => {
      if (left === "Etc/UTC") return -1
      if (right === "Etc/UTC") return 1
      return left.localeCompare(right)
    })
}
