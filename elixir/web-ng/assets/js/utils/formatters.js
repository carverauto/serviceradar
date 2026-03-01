export function nfFormatBytes(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 B"
  const abs = Math.abs(v)
  if (abs >= 1e12) return `${(v / 1e12).toFixed(2)} TB`
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} GB`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} MB`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} KB`
  return `${v.toFixed(0)} B`
}

export function nfFormatBits(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 b"
  const abs = Math.abs(v)
  if (abs >= 1e12) return `${(v / 1e12).toFixed(2)} Tb`
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} Gb`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} Mb`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} Kb`
  return `${v.toFixed(0)} b`
}

export function nfFormatCountPerSec(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 /s"
  const abs = Math.abs(v)
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} G/s`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} M/s`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} K/s`
  return `${v.toFixed(2)} /s`
}

export function nfFormatRateValue(units, n) {
  const u = String(units || "").trim()
  if (u === "bps") return `${nfFormatBits(n)}/s`
  if (u === "Bps") return `${nfFormatBytes(n)}/s`
  if (u === "pps") return nfFormatCountPerSec(n)
  return nfFormatBytes(n)
}
