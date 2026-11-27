// Offline world projection. Topology is passed in by the hook, which
// lazy-loads priv/static/world-110m.json from the page origin. This module
// does not fetch and does not know about tile servers.

import {geoEquirectangular, geoNaturalEarth1, geoPath} from "d3-geo"
import {feature} from "topojson-client"

const TONES = new Set(["brand", "success", "warning", "danger", "info", "neutral"])

export function projectWorld(topology, opts) {
  const width = positive(opts.width, 960)
  const height = positive(opts.height, 500)
  const countries = feature(topology, topology.objects.countries)
  const projection = (opts.projection === "equirectangular" ? geoEquirectangular() : geoNaturalEarth1())
    .fitSize([width, height], {type: "Sphere"})
  const path = geoPath(projection)
  const features = countries.features || []

  return {
    sphere: path({type: "Sphere"}) || "",
    land: features
      .map((country) => ({d: path(country)}))
      .filter((country) => country.d),
    regions: (opts.regions || [])
      .map((region) => regionShape(features, path, region))
      .filter(Boolean),
    arcs: (opts.arcs || []).map((arc, index) => arcShape(projection, arc, index)).filter(Boolean),
    points: (opts.points || [])
      .map((point, index) => pointShape(projection, point, index))
      .filter(Boolean),
  }
}

function regionShape(features, path, region) {
  const country = findCountry(features, region.id ?? region.name)
  if (!country) return null
  const d = path(country)
  if (!d) return null
  return {
    id: String(region.id ?? country.id),
    label: String(region.label || country.properties?.name || region.id || ""),
    tone: tone(region.tone),
    level: clampInt(region.level, 1, 5, 3),
    d,
  }
}

function findCountry(features, id) {
  const key = String(id ?? "")
    .trim()
    .toLowerCase()
  if (!key) return null
  return features.find((country) => {
    const numeric = String(country.id ?? "").toLowerCase()
    const name = String(country.properties?.name ?? "").toLowerCase()
    return numeric === key || name === key
  })
}

function pointShape(projection, point, index) {
  const lon = Number(point.lon ?? point.lng)
  const lat = Number(point.lat)
  if (!inRange(lon, -180, 180) || !inRange(lat, -90, 90)) return null
  const xy = projection([lon, lat])
  if (!xy) return null
  const size = clampInt(point.size, 1, 5, 2)
  return {
    id: String(point.id ?? `point-${index}`),
    label: point.label ? String(point.label) : "",
    tone: tone(point.tone),
    x: round(xy[0]),
    y: round(xy[1]),
    r: 1.5 + size,
  }
}

function arcShape(projection, arc, index) {
  const from = pair(arc.from)
  const to = pair(arc.to)
  if (!from || !to) return null
  const a = projection(from)
  const b = projection(to)
  if (!a || !b) return null
  const mx = (a[0] + b[0]) / 2
  const my = (a[1] + b[1]) / 2
  const dx = b[0] - a[0]
  const dy = b[1] - a[1]
  const len = Math.hypot(dx, dy) || 1
  const lift = Math.min(80, len * 0.25)
  return {
    id: String(arc.id ?? `arc-${index}`),
    label: arc.label ? String(arc.label) : "",
    tone: tone(arc.tone, "info"),
    weight: clampInt(arc.weight, 1, 5, 2),
    d: `M${round(a[0])},${round(a[1])} Q${round(mx - (dy / len) * lift)},${round(my + (dx / len) * lift)} ${round(b[0])},${round(b[1])}`,
  }
}

function pair(value) {
  if (!Array.isArray(value) || value.length < 2) return null
  const lon = Number(value[0])
  const lat = Number(value[1])
  if (!inRange(lon, -180, 180) || !inRange(lat, -90, 90)) return null
  return [lon, lat]
}

function tone(value, fallback = "brand") {
  return TONES.has(value) ? value : fallback
}

function clampInt(value, min, max, fallback) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.round(n)))
}

function inRange(value, min, max) {
  return Number.isFinite(value) && value >= min && value <= max
}

function positive(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? n : fallback
}

function round(value) {
  return Math.round(value * 100) / 100
}
