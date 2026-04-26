import {geoEquirectangular, geoPath} from "d3-geo"
import countries110m from "world-atlas/countries-110m.json"
import {feature} from "topojson-client"

const MAP_VIEWS = new Set(["topology_traffic", "netflow"])
const WORLD_COUNTRIES = feature(countries110m, countries110m.objects.countries)
const WORLD_MAP_PATHS = buildWorldMapPaths()
const TOPOLOGY_VIEWBOX = "-170 -70 340 140"
const NETFLOW_WORLD_VIEWBOX = "-180 -86 360 172"
const NETFLOW_PAN_THRESHOLD_PX = 6
const COUNTRY_NAMES = typeof Intl !== "undefined" && Intl.DisplayNames
  ? new Intl.DisplayNames(["en"], {type: "region"})
  : null

function parseJson(value, fallback) {
  try {
    const parsed = JSON.parse(value || "")
    return Array.isArray(parsed) ? parsed : fallback
  } catch (_e) {
    return fallback
  }
}

function buildWorldMapPaths() {
  const projection = geoEquirectangular()
    .scale(180 / Math.PI)
    .translate([0, 0])
    .precision(0.1)
  const path = geoPath(projection)

  return WORLD_COUNTRIES.features.map((country) => path(country)).filter(Boolean)
}

function normalizePoint(value) {
  if (Array.isArray(value) && value.length >= 2) {
    const x = Number(value[0])
    const y = Number(value[1])
    if (Number.isFinite(x) && Number.isFinite(y)) return [x, y]
  }

  return [0, 0]
}

function fallbackPoint(primary, fallback) {
  if (Array.isArray(primary) && primary.length >= 2) return normalizePoint(primary)
  return normalizePoint(fallback)
}

function scaledColor(color, alphaMultiplier = 1) {
  const rgba = Array.isArray(color) ? color : [56, 189, 248, 180]
  const alpha = Math.max(45, Math.min(255, Math.round(Number(rgba[3] ?? 180) * alphaMultiplier)))
  return [Number(rgba[0] ?? 56), Number(rgba[1] ?? 189), Number(rgba[2] ?? 248), alpha]
}

function netflowLinkColor(link, magnitude) {
  const flowCount = Number(link?.flow_count || 0)
  const sourceLocal = Boolean(link?.source_local_anchor)
  const targetLocal = Boolean(link?.target_local_anchor)

  if (magnitude >= 1_000_000_000 || flowCount >= 50) return [251, 146, 60, 235]
  if (magnitude >= 100_000_000 || flowCount >= 15) return [167, 139, 250, 230]
  if (sourceLocal && targetLocal) return [45, 212, 191, 230]
  if (sourceLocal || targetLocal) return [56, 189, 248, 230]

  return [148, 163, 184, 185]
}

function normalizeLinks(rawLinks) {
  return rawLinks
    .map((link, idx) => {
      const from = normalizePoint(link?.from || link?.source)
      const to = normalizePoint(link?.to || link?.target)
      const magnitude = Math.max(0, Number(link?.magnitude || link?.bytes || link?.packets || 0))
      const color = Array.isArray(link?.color) ? link.color : [56, 189, 248, 180]

      return {
        id: link?.id || `link-${idx}`,
        from,
        to,
        magnitude,
        color,
        sourceLabel: link?.source_label,
        targetLabel: link?.target_label,
        sourceIp: link?.source_label,
        targetIp: link?.target_label,
        protocol: link?.protocol,
        telemetrySource: link?.telemetry_source,
        localInterface: link?.local_if_name,
        neighborInterface: link?.neighbor_if_name,
        topologyPlane: link?.topology_plane,
        evidenceClass: link?.evidence_class,
        flowBps: Number(link?.flow_bps || 0),
        capacityBps: Number(link?.capacity_bps || 0),
        utilizationPct: Number(link?.utilization_pct || 0),
        sparkline: Array.isArray(link?.sparkline) ? link.sparkline : [],
        sparklineLabel: link?.sparkline_label,
        seed: (idx * 0.137) % 1,
        speed: 0.18 + Math.min(0.42, magnitude / 10_000_000_000),
        size: 3 + Math.min(7, Math.log10(Math.max(10, magnitude)) * 0.8),
        jitter: 0.5,
        laneOffset: (idx % 5) - 2,
      }
    })
    .filter((link) => link.from[0] !== link.to[0] || link.from[1] !== link.to[1])
}

function topologySchematicLinks(links) {
  if (!Array.isArray(links) || links.length === 0) return []

  const nodeStats = new Map()
  const touch = (label, weight) => {
    if (!label) return
    const current = nodeStats.get(label) || {label, degree: 0, weight: 0}
    current.degree += 1
    current.weight += weight
    nodeStats.set(label, current)
  }

  for (const link of links) {
    const weight = visualMagnitude(link)
    touch(link.sourceLabel, weight)
    touch(link.targetLabel, weight)
  }

  const nodes = [...nodeStats.values()].sort((a, b) => b.degree - a.degree || b.weight - a.weight || a.label.localeCompare(b.label))
  const hubs = nodes.slice(0, Math.min(5, Math.max(2, Math.ceil(nodes.length / 4))))
  const hubLabels = new Set(hubs.map((node) => node.label))
  const positions = new Map()
  const hubSpacing = hubs.length > 1 ? 160 / (hubs.length - 1) : 0

  hubs.forEach((node, idx) => {
    positions.set(node.label, [-80 + idx * hubSpacing, idx % 2 === 0 ? -5 : 8])
  })

  const leavesByHub = new Map(hubs.map((node) => [node.label, []]))
  const nearestHubFor = (label) => {
    const candidate = links.find((link) => {
      return (link.sourceLabel === label && hubLabels.has(link.targetLabel)) || (link.targetLabel === label && hubLabels.has(link.sourceLabel))
    })

    if (candidate) return hubLabels.has(candidate.sourceLabel) ? candidate.sourceLabel : candidate.targetLabel

    return hubs[0]?.label
  }

  for (const node of nodes) {
    if (hubLabels.has(node.label)) continue
    const hub = nearestHubFor(node.label)
    if (!hub) continue
    leavesByHub.get(hub)?.push(node)
  }

  for (const [hub, leaves] of leavesByHub.entries()) {
    const [hubX, hubY] = positions.get(hub)
    leaves
      .sort((a, b) => b.weight - a.weight || a.label.localeCompare(b.label))
      .forEach((node, idx) => {
        const side = idx % 2 === 0 ? 1 : -1
        const ring = Math.floor(idx / 2)
        const x = Math.max(-158, Math.min(158, hubX + side * (34 + ring * 24)))
        const y = Math.max(-58, Math.min(58, hubY + (ring % 2 === 0 ? 34 : -34)))
        positions.set(node.label, [x, y])
      })
  }

  return links.map((link) => ({
    ...link,
    from: positions.get(link.sourceLabel) || link.from,
    to: positions.get(link.targetLabel) || link.to,
  }))
}

function normalizeTrafficLinks(rawLinks, mapView) {
  return rawLinks
    .map((link, idx) => {
      const useGeo = mapView === "netflow"
      const geoMapped = Boolean(link?.geo_from && link?.geo_to)
      const topologyFrom = link?.topology_from || link?.from || link?.source
      const topologyTo = link?.topology_to || link?.to || link?.target
      const from = useGeo ? fallbackPoint(link?.geo_from, topologyFrom) : normalizePoint(topologyFrom)
      const to = useGeo ? fallbackPoint(link?.geo_to, topologyTo) : normalizePoint(topologyTo)
      const magnitude = Math.max(0, Number(link?.magnitude || link?.bytes || link?.packets || 0))
      const baseColor = useGeo ? netflowLinkColor(link, magnitude) : Array.isArray(link?.color) ? link.color : [56, 189, 248, 180]
      const color = scaledColor(baseColor, useGeo && !geoMapped ? 0.45 : 1)
      const sourceGeoLabel = link?.source_geo_label || null
      const targetGeoLabel = link?.target_geo_label || null

      return {
        id: link?.id || `flow-${idx}`,
        from,
        to,
        magnitude,
        color,
        sourceLabel: useGeo ? sourceGeoLabel || link?.source_label : link?.source_label,
        targetLabel: useGeo ? targetGeoLabel || link?.target_label : link?.target_label,
        sourceIp: link?.source_label,
        targetIp: link?.target_label,
        sourceGeoLabel,
        targetGeoLabel,
        sourceAnchorLabel: link?.source_anchor_label,
        targetAnchorLabel: link?.target_anchor_label,
        sourceLocalAnchor: Boolean(link?.source_local_anchor),
        targetLocalAnchor: Boolean(link?.target_local_anchor),
        geoMapped,
        bytes: Number(link?.bytes || 0),
        packets: Number(link?.packets || 0),
        flowCount: Number(link?.flow_count || 0),
        flowBps: Number(link?.flow_bps || 0),
        capacityBps: Number(link?.capacity_bps || 0),
        utilizationPct: Number(link?.utilization_pct || 0),
        seed: (idx * 0.137) % 1,
        speed: 0.18 + Math.min(0.42, magnitude / 10_000_000_000),
        size: 3 + Math.min(7, Math.log10(Math.max(10, magnitude)) * 0.8),
        jitter: useGeo ? 0.18 : 0.5,
        laneOffset: (idx % 5) - 2,
      }
    })
    .filter((link) => mapView !== "netflow" || link.geoMapped)
    .filter((link) => link.from[0] !== link.to[0] || link.from[1] !== link.to[1])
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

function formatBytes(value) {
  const bytes = Number(value || 0)
  if (bytes >= 1_000_000_000_000) return `${(bytes / 1_000_000_000_000).toFixed(1)} TB`
  if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(1)} KB`
  return `${bytes.toFixed(0)} B`
}

function formatRate(value) {
  const bps = Number(value || 0)
  if (bps >= 1_000_000_000_000) return `${(bps / 1_000_000_000_000).toFixed(1)} Tbps`
  if (bps >= 1_000_000_000) return `${(bps / 1_000_000_000).toFixed(1)} Gbps`
  if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`
  if (bps >= 1_000) return `${(bps / 1_000).toFixed(1)} Kbps`
  return `${bps.toFixed(0)} bps`
}

function flowEndpointLabel(label, ip, fallback) {
  const value = String(label || ip || fallback || "").trim()
  return value || "Unknown"
}

function srqlQuote(value) {
  return `"${String(value || "").replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`
}

function flowDetailsUrlForPair(sourceIp, targetIp) {
  if (!isIpLike(sourceIp) || !isIpLike(targetIp)) return null

  const q = [
    "in:flows",
    "time:last_1h",
    `src_endpoint_ip:${srqlQuote(sourceIp)}`,
    `dst_endpoint_ip:${srqlQuote(targetIp)}`,
    "sort:bytes_total:desc",
  ].join(" ")

  return `/observability/flows?${new URLSearchParams({q, limit: "100"}).toString()}`
}

function endpointFlowSummary(link, side) {
  const sourceIp = link.sourceIp
  const targetIp = link.targetIp
  const sourceLabel = flowEndpointLabel(link.sourceAnchorLabel || link.sourceGeoLabel || link.sourceLabel, sourceIp, "Source")
  const targetLabel = flowEndpointLabel(link.targetAnchorLabel || link.targetGeoLabel || link.targetLabel, targetIp, "Destination")
  const href = flowDetailsUrlForPair(sourceIp, targetIp)

  if (!href) return null

  return {
    direction: side === "source" ? "Egress" : "Ingress",
    peerLabel: side === "source" ? targetLabel : sourceLabel,
    sourceIp,
    targetIp,
    bytes: Number(link.bytes || link.magnitude || 0),
    packets: Number(link.packets || 0),
    flowCount: Number(link.flowCount || 0),
    href,
  }
}

function normalizeEndpointFlows(flows) {
  return [...(Array.isArray(flows) ? flows : [])]
    .filter((flow) => flow && flow.href)
    .sort((a, b) => Number(b.bytes || 0) - Number(a.bytes || 0))
    .slice(0, 5)
}

function endpointFlowsHtml(encodedFlows) {
  let flows = []

  try {
    flows = normalizeEndpointFlows(JSON.parse(encodedFlows || "[]"))
  } catch (_e) {
    flows = []
  }

  if (flows.length === 0) return ""

  return `
    <div class="sr-ops-anchor-flow-list">
      <em>Top flow links</em>
      ${flows
        .map((flow) => `
          <a class="sr-ops-anchor-flow-link" href="${escapeHtml(flow.href)}">
            <span>
              <i>${escapeHtml(flow.direction)}</i>
              <b>${escapeHtml(flow.peerLabel)}</b>
            </span>
            <small>${escapeHtml(flow.sourceIp)} -> ${escapeHtml(flow.targetIp)} · ${formatBytes(flow.bytes)} · ${Number(flow.flowCount || 0).toLocaleString()} flows</small>
          </a>
        `)
        .join("")}
    </div>
  `
}

function shortNodeLabel(value) {
  const label = String(value || "")
  const clean = label
    .replace(/^sr:/, "")
    .replace(/^device:/, "")
    .replace(/^ip:/, "")

  if (clean.length <= 22) return clean

  return `${clean.slice(0, 19)}...`
}

function isIpLike(value) {
  const label = String(value || "").trim()
  return (label.includes(".") || label.includes(":")) && /^[0-9a-f:.]+$/i.test(label)
}

function countryIpLabel(value) {
  const [country, ip] = String(value || "")
    .split(",")
    .map((part) => part.trim())

  if (/^[a-z]{2}$/i.test(country || "") && isIpLike(ip)) {
    const countryCode = country.toUpperCase()

    return {
      country: countryCode,
      countryName: countryDisplayName(countryCode),
      ip,
    }
  }

  return null
}

function countryDisplayName(countryCode) {
  try {
    const name = COUNTRY_NAMES?.of(countryCode)
    if (name && name !== countryCode) return name
  } catch (_e) {
    // Fall back to the region code when the browser cannot resolve it.
  }

  return countryCode
}

function compactCityLabel(city) {
  const clean = String(city || "").trim()
  if (clean.length <= 13) return clean

  const [firstWord] = clean.split(/\s+/)
  if (firstWord && firstWord.length >= 5 && firstWord.length <= 13) return firstWord

  return `${clean.slice(0, 12)}...`
}

function shortEndpointLabel(value) {
  const label = String(value || "").trim()
  if (!label) return ""
  const countryIp = countryIpLabel(label)
  if (countryIp) return compactCityLabel(countryIp.countryName)
  if (label.length <= 18) return label

  const [city, region] = label.split(",").map((part) => part.trim())
  if (city && region) {
    return `${compactCityLabel(city)}, ${region.slice(0, 3)}`
  }

  return `${label.slice(0, 15)}...`
}

function networkClusterLabel(labels) {
  const names = labels
    .map((label) => compactCityLabel(String(label || "").split(",")[0]))
    .filter(Boolean)
    .sort((a, b) => a.localeCompare(b))

  if (names.length === 2 && names.every((name) => name.length <= 11)) {
    return `${names[0]} / ${names[1]}`
  }

  if (names.length === 3 && names.every((name) => name.length <= 8)) {
    return names.join(" / ")
  }

  return `${labels.length} networks`
}

function projectedSvgPoint(point, mapView) {
  const x = Number(point[0] || 0)
  const y = Number(point[1] || 0)

  if (mapView === "netflow") return [x, -y]

  return [x, y]
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function rounded(value) {
  return Math.round(value * 10) / 10
}

function parseViewBox(value) {
  const parts = String(value || "")
    .split(/\s+/)
    .map(Number)

  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part))) return null

  return {
    x: parts[0],
    y: parts[1],
    width: parts[2],
    height: parts[3],
  }
}

function formatViewBox(box) {
  return `${rounded(box.x)} ${rounded(box.y)} ${rounded(box.width)} ${rounded(box.height)}`
}

function constrainedNetflowViewBox(box) {
  const width = clamp(box.width, 28, 360)
  const height = clamp(box.height, 16, 172)
  const x = clamp(box.x, -180, 180 - width)
  const y = clamp(box.y, -86, 86 - height)

  return {x, y, width, height}
}

function scaledViewBox(viewBox, factor, focalPoint = null) {
  const box = parseViewBox(viewBox)
  if (!box) return null

  const width = box.width * factor
  const height = box.height * factor
  const anchorX = focalPoint?.x ?? box.x + box.width / 2
  const anchorY = focalPoint?.y ?? box.y + box.height / 2
  const ratioX = focalPoint?.ratioX ?? 0.5
  const ratioY = focalPoint?.ratioY ?? 0.5

  return constrainedNetflowViewBox({
    x: anchorX - ratioX * width,
    y: anchorY - ratioY * height,
    width,
    height,
  })
}

function netflowZoomScale(zoomWidth) {
  return clamp((zoomWidth || 272) / 272, 0.11, 1)
}

function netflowLabelStyle(zoomWidth, local) {
  const scale = netflowZoomScale(zoomWidth)
  const fontSize = local ? clamp(3.05 * scale, 2.35, 3.05) : clamp(2.45 * scale, 1.85, 2.45)

  return {
    fontSize,
    strokeWidth: fontSize * 0.28,
    collisionX: local ? Math.max(8.6, fontSize * 8.9) : Math.max(6.8, fontSize * 7.8),
    collisionY: Math.max(3, fontSize * 2.5),
  }
}

function netflowGeometryStyle(zoomWidth) {
  const scale = netflowZoomScale(zoomWidth)

  return {
    scale,
    localNodeRadius: 2.15 * scale,
    externalNodeRadius: 0.55 * scale,
    haloExtraWidth: 2.4 * scale,
    arrowSize: Math.max(0.9, 1.85 * scale),
  }
}

function reservedNetflowLegendArea(endpoint, box) {
  if (endpoint.local || !box) return false

  const reserveRight = box.x + box.width * 0.24
  const reserveBottom = box.y + box.height * 0.72

  return endpoint.x < reserveRight && endpoint.y < reserveBottom
}

function translatedViewBox(viewBox, deltaX, deltaY) {
  const box = parseViewBox(viewBox)
  if (!box) return null

  return constrainedNetflowViewBox({
    ...box,
    x: box.x + deltaX,
    y: box.y + deltaY,
  })
}

function viewBoxForMap(mapView, links = []) {
  if (mapView !== "netflow") return TOPOLOGY_VIEWBOX

  const points = links
    .flatMap((link) => [link.from, link.to])
    .map((point) => projectedSvgPoint(point, "netflow"))
    .filter(([x, y]) => Number.isFinite(x) && Number.isFinite(y))

  if (points.length < 2) return NETFLOW_WORLD_VIEWBOX

  const xs = points.map(([x]) => x)
  const ys = points.map(([, y]) => y)
  let minX = Math.min(...xs) - 24
  let maxX = Math.max(...xs) + 24
  let minY = Math.min(...ys) - 18
  let maxY = Math.max(...ys) + 18

  const minWidth = 118
  const minHeight = 64
  const width = maxX - minX
  const height = maxY - minY

  if (width < minWidth) {
    const center = (minX + maxX) / 2
    minX = center - minWidth / 2
    maxX = center + minWidth / 2
  }

  if (height < minHeight) {
    const center = (minY + maxY) / 2
    minY = center - minHeight / 2
    maxY = center + minHeight / 2
  }

  minX = clamp(minX, -180, 180 - minWidth)
  maxX = clamp(maxX, minX + minWidth, 180)
  minY = clamp(minY, -86, 86 - minHeight)
  maxY = clamp(maxY, minY + minHeight, 86)

  return `${rounded(minX)} ${rounded(minY)} ${rounded(maxX - minX)} ${rounded(maxY - minY)}`
}

function svgPathForLink(link, idx, mapView) {
  const {from, control, to} = linkCurvePoints(link, idx, mapView)
  return `M ${rounded(from[0])} ${rounded(from[1])} Q ${rounded(control[0])} ${rounded(control[1])} ${rounded(to[0])} ${rounded(to[1])}`
}

function linkCurvePoints(link, idx, mapView) {
  const [x1, y1] = projectedSvgPoint(link.from, mapView)
  const [x2, y2] = projectedSvgPoint(link.to, mapView)
  const dx = x2 - x1
  const dy = y2 - y1
  const distance = Math.max(1, Math.hypot(dx, dy))
  const curveScale = mapView === "netflow"
    ? Math.min(24, Math.max(5, distance * 0.12))
    : Math.min(14, Math.max(3, distance * 0.075))
  const curve = curveScale * (idx % 2 === 0 ? 1 : -1)
  const cx = (x1 + x2) / 2 - (dy / distance) * curve
  const cy = (y1 + y2) / 2 + (dx / distance) * curve

  return {from: [x1, y1], control: [cx, cy], to: [x2, y2]}
}

function quadraticPoint(from, control, to, t) {
  const inverse = 1 - t

  return [
    inverse * inverse * from[0] + 2 * inverse * t * control[0] + t * t * to[0],
    inverse * inverse * from[1] + 2 * inverse * t * control[1] + t * t * to[1],
  ]
}

function quadraticTangentAngle(from, control, to, t) {
  const inverse = 1 - t
  const dx = 2 * inverse * (control[0] - from[0]) + 2 * t * (to[0] - control[0])
  const dy = 2 * inverse * (control[1] - from[1]) + 2 * t * (to[1] - control[1])

  return Math.atan2(dy, dx) * (180 / Math.PI)
}

function linkArrowGeometry(link, idx, mapView, size = 1.25) {
  const {from, control, to} = linkCurvePoints(link, idx, mapView)
  const point = quadraticPoint(from, control, to, 0.78)
  const angle = quadraticTangentAngle(from, control, to, 0.78)
  const d = `M ${rounded(-size * 0.55)} ${rounded(-size * 0.52)} L ${rounded(size * 0.8)} 0 L ${rounded(-size * 0.55)} ${rounded(size * 0.52)} Z`

  return {d, transform: `translate(${rounded(point[0])} ${rounded(point[1])}) rotate(${rounded(angle)})`}
}

function rgbaCss(color, alphaMultiplier = 1) {
  const rgba = scaledColor(color, alphaMultiplier)
  return `rgba(${rgba[0]}, ${rgba[1]}, ${rgba[2]}, ${Math.max(0.18, Math.min(1, rgba[3] / 255))})`
}

function strokeWidthFor(link, mapView = "topology_traffic") {
  const magnitude = Math.log10(Math.max(10, visualMagnitude(link)))
  const width = mapView === "netflow" ? 0.62 + Math.min(1.75, magnitude / 3.2) : 0.82 + Math.min(3.25, magnitude / 1.55)

  return Math.round(width * 10) / 10
}

function visualMagnitude(link) {
  const value = Number(link?.magnitude || link?.flowBps || link?.bytes || link?.packets || 0)
  return Number.isFinite(value) ? value : 0
}

function netflowPathClass(link) {
  const magnitude = visualMagnitude(link)
  const flowCount = Number(link?.flowCount || 0)

  if (magnitude >= 1_000_000_000 || flowCount >= 50) return "is-netflow-hot"
  if (magnitude >= 100_000_000 || flowCount >= 15) return "is-netflow-busy"
  if (link?.sourceLocalAnchor && link?.targetLocalAnchor) return "is-netflow-local"
  if (link?.sourceLocalAnchor || link?.targetLocalAnchor) return "is-netflow-edge"

  return "is-netflow-external"
}

function topVisualLinks(links, limit, {includeIdle = false} = {}) {
  return [...links]
    .filter((link) => includeIdle || visualMagnitude(link) > 0)
    .sort((a, b) => visualMagnitude(b) - visualMagnitude(a))
    .slice(0, limit)
}

function endpointNodes(links, mapView = "topology_traffic") {
  const byKey = new Map()

  for (const link of links) {
    const endpoints = [
      {
        point: link.from,
        label: mapView === "netflow" && link.sourceLocalAnchor ? link.sourceAnchorLabel || link.sourceLabel : link.sourceLabel,
        ip: link.sourceIp,
        geoLabel: link.sourceGeoLabel,
        color: link.color,
        magnitude: link.magnitude,
        localAnchor: Boolean(link.sourceLocalAnchor),
        anchorLabel: link.sourceAnchorLabel,
        flow: endpointFlowSummary(link, "source"),
      },
      {
        point: link.to,
        label: mapView === "netflow" && link.targetLocalAnchor ? link.targetAnchorLabel || link.targetLabel : link.targetLabel,
        ip: link.targetIp,
        geoLabel: link.targetGeoLabel,
        color: link.color,
        magnitude: link.magnitude,
        localAnchor: Boolean(link.targetLocalAnchor),
        anchorLabel: link.targetAnchorLabel,
        flow: endpointFlowSummary(link, "target"),
      },
    ]

    for (const endpoint of endpoints) {
      const point = endpoint.point
      const key = mapView === "netflow" && endpoint.localAnchor && endpoint.anchorLabel
        ? `local:${endpoint.anchorLabel}`
        : `${point[0].toFixed(2)},${point[1].toFixed(2)}`
      const nodeColor = mapView === "netflow"
        ? endpoint.localAnchor
          ? [45, 212, 191, 245]
          : [148, 163, 184, 92]
        : endpoint.color

      if (!byKey.has(key)) {
        byKey.set(key, {
          id: key,
          position: [point[0], point[1], 0],
          color: nodeColor,
          sourceLabel: endpoint.label || endpoint.ip || key,
          sourceIp: endpoint.ip,
          sourceGeoLabel: endpoint.geoLabel,
          localAnchor: endpoint.localAnchor,
          anchorLabel: endpoint.anchorLabel,
          longitude: point[0],
          latitude: point[1],
          magnitude: endpoint.magnitude || 0,
          count: 1,
          flows: normalizeEndpointFlows([endpoint.flow]),
        })
      } else {
        const existing = byKey.get(key)
        existing.magnitude += endpoint.magnitude || 0
        existing.count += 1
        existing.flows = normalizeEndpointFlows([...(existing.flows || []), endpoint.flow])
        if (endpoint.localAnchor) {
          existing.localAnchor = true
          existing.color = [45, 212, 191, 245]
        }
      }
    }
  }

  return Array.from(byKey.values())
}

export default {
  mounted() {
    this.links = []
    this.topologyLinks = []
    this.overlays = []
    this.mapView = "topology_traffic"
    this.autoViewBox = NETFLOW_WORLD_VIEWBOX
    this.currentViewBox = null
    this.viewBoxSignature = null
    this.dragState = null
    this.suppressNextClick = false
    this._resizeMap = this._resizeMap.bind(this)
    this._onMapViewChange = this._onMapViewChange.bind(this)
    this._onExternalMapViewChange = this._onExternalMapViewChange.bind(this)
    this._onMapWheel = this._onMapWheel.bind(this)
    this._onMapPointerDown = this._onMapPointerDown.bind(this)
    this._onMapPointerMove = this._onMapPointerMove.bind(this)
    this._onMapPointerUp = this._onMapPointerUp.bind(this)
    this._onMapShellClick = this._onMapShellClick.bind(this)
    this._onSvgOverlayClick = this._onSvgOverlayClick.bind(this)
    this._onClusterLabelClick = this._onClusterLabelClick.bind(this)
    this._zoomIn = this._zoomIn.bind(this)
    this._zoomOut = this._zoomOut.bind(this)
    this._resetViewBox = this._resetViewBox.bind(this)
    this._fitWorld = this._fitWorld.bind(this)
    this._blockMapGesture = this._blockMapGesture.bind(this)
    document.addEventListener("change", this._onMapViewChange)
    window.addEventListener("serviceradar:dashboard-map-view", this._onExternalMapViewChange)
    this.el.addEventListener("wheel", this._onMapWheel, {passive: false})
    this.el.addEventListener("touchmove", this._blockMapGesture, {passive: false})
    window.addEventListener("pointermove", this._onMapPointerMove)
    window.addEventListener("pointerup", this._onMapPointerUp)
    window.addEventListener("pointercancel", this._onMapPointerUp)
    this._ensureWorldMapBackground()
    this._ensureSvgOverlay()
    this.el.parentElement?.addEventListener("click", this._onMapShellClick)
    this._ensureInteractionControls()
    this.resizeObserver = new ResizeObserver(this._resizeMap)
    this.resizeObserver.observe(this.el.parentElement || this.el)
    this._resizeMap()
    this._syncData()
  },

  updated() {
    this._syncData()
  },

  destroyed() {
    document.removeEventListener("change", this._onMapViewChange)
    window.removeEventListener("serviceradar:dashboard-map-view", this._onExternalMapViewChange)
    this.el.removeEventListener("wheel", this._onMapWheel)
    this.el.removeEventListener("touchmove", this._blockMapGesture)
    window.removeEventListener("pointermove", this._onMapPointerMove)
    window.removeEventListener("pointerup", this._onMapPointerUp)
    window.removeEventListener("pointercancel", this._onMapPointerUp)
    this.el.parentElement?.removeEventListener("click", this._onMapShellClick)
    this.svgOverlay?.removeEventListener("click", this._onSvgOverlayClick)
    this.svgOverlay?.removeEventListener("wheel", this._onMapWheel)
    this.svgOverlay?.removeEventListener("pointerdown", this._onMapPointerDown)
    this.resizeObserver?.disconnect()
    this.interactionControls?.remove()
    this.anchorDetails?.remove()
    this.svgOverlay?.remove()
    this.worldMapBackground?.remove()
  },

  _blockMapGesture(event) {
    event.preventDefault()
    event.stopPropagation()
  },

  _hideAnchorDetails() {
    this.anchorDetails?.remove()
    this.anchorDetails = null

    const activeElement = typeof document !== "undefined" ? document.activeElement : null
    if (activeElement && this.svgOverlay?.contains?.(activeElement)) {
      activeElement.blur?.()
    }
  },

  _onMapWheel(event) {
    if (this.mapView !== "netflow") return this._blockMapGesture(event)

    event.preventDefault()
    event.stopPropagation()
    this._scaleCurrentViewBox(event.deltaY < 0 ? 0.9 : 1.12, event)
  },

  _pointForClientEvent(event) {
    const box = parseViewBox(this.currentViewBox || this.autoViewBox)
    const parent = this.svgOverlay || this.el.parentElement || this.el
    const rect = parent.getBoundingClientRect()

    if (!box || rect.width <= 0 || rect.height <= 0) return null

    const viewRatio = box.width / box.height
    const rectRatio = rect.width / rect.height
    let activeLeft = rect.left
    let activeTop = rect.top
    let activeWidth = rect.width
    let activeHeight = rect.height

    if (rectRatio > viewRatio) {
      activeWidth = rect.height * viewRatio
      activeLeft = rect.left + (rect.width - activeWidth) / 2
    } else if (rectRatio < viewRatio) {
      activeHeight = rect.width / viewRatio
      activeTop = rect.top + (rect.height - activeHeight) / 2
    }

    const localX = clamp(event.clientX - activeLeft, 0, activeWidth)
    const localY = clamp(event.clientY - activeTop, 0, activeHeight)
    const ratioX = activeWidth > 0 ? localX / activeWidth : 0.5
    const ratioY = activeHeight > 0 ? localY / activeHeight : 0.5

    return {
      x: box.x + ratioX * box.width,
      y: box.y + ratioY * box.height,
      ratioX,
      ratioY,
    }
  },

  _onMapPointerDown(event) {
    if (this.mapView !== "netflow" || event.button > 0) return
    if (event.target?.closest?.(".sr-ops-traffic-node.is-local-anchor")) return
    if (event.target?.closest?.(".sr-ops-traffic-node.is-external-geo, .sr-ops-traffic-label.is-clickable-endpoint, .sr-ops-traffic-endpoint-hit")) return
    if (event.target?.closest?.(".sr-ops-traffic-link-hit")) return
    if (event.target?.closest?.(".sr-ops-traffic-label.is-cluster-label, .sr-ops-traffic-cluster-hit")) return
    if (event.target?.closest?.(".sr-ops-map-interaction-controls")) return

    const box = parseViewBox(this.currentViewBox || this.autoViewBox)
    if (!box) return

    event.preventDefault()
    event.stopPropagation()
    this.dragState = {
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startBox: box,
      dragged: false,
    }
    this.svgOverlay?.setPointerCapture?.(event.pointerId)
  },

  _onMapPointerMove(event) {
    if (!this.dragState || this.mapView !== "netflow") return
    if (event.pointerId !== this.dragState.pointerId) return

    const rect = (this.svgOverlay || this.el.parentElement || this.el).getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return

    const deltaClientX = event.clientX - this.dragState.startClientX
    const deltaClientY = event.clientY - this.dragState.startClientY
    const distance = Math.hypot(deltaClientX, deltaClientY)

    if (!this.dragState.dragged) {
      if (distance < NETFLOW_PAN_THRESHOLD_PX) return

      this.dragState.dragged = true
      this.el.parentElement?.classList.add("is-netflow-panning")
    }

    const deltaX = -(deltaClientX / rect.width) * this.dragState.startBox.width
    const deltaY = -(deltaClientY / rect.height) * this.dragState.startBox.height
    const next = translatedViewBox(formatViewBox(this.dragState.startBox), deltaX, deltaY)
    if (!next) return

    event.preventDefault()
    event.stopPropagation()
    this.currentViewBox = formatViewBox(next)
    this._setMapViewBox(this.currentViewBox)
  },

  _onMapPointerUp(event) {
    if (!this.dragState) return
    if (event.pointerId !== this.dragState.pointerId) return

    this.suppressNextClick = this.dragState.dragged
    this.dragState = null
    this.svgOverlay?.releasePointerCapture?.(event.pointerId)
    this.el.parentElement?.classList.remove("is-netflow-panning")
  },

  _onMapViewChange(event) {
    const target = event.target
    if (!target || target.id !== "traffic-map-view-select") return

    this.el.dataset.mapView = MAP_VIEWS.has(target.value) ? target.value : "topology_traffic"
    this._syncData()
  },

  _onExternalMapViewChange(event) {
    this.el.dataset.mapView = MAP_VIEWS.has(event.detail?.mapView)
      ? event.detail.mapView
      : "topology_traffic"
    this._syncData()
  },

  _resizeMap() {
    this._syncData()
  },

  _ensureSvgOverlay() {
    const parent = this.el.parentElement
    if (!parent) return null

    this.svgOverlay = parent.querySelector(".sr-ops-traffic-overlay")
    if (!this.svgOverlay) {
      this.svgOverlay = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      this.svgOverlay.classList.add("sr-ops-traffic-overlay")
      this.svgOverlay.setAttribute("preserveAspectRatio", "xMidYMid meet")
      this.svgOverlay.setAttribute("aria-hidden", "true")
      parent.appendChild(this.svgOverlay)
    }

    if (!this.svgOverlay.dataset.clickBound) {
      this.svgOverlay.addEventListener("click", this._onSvgOverlayClick)
      this.svgOverlay.addEventListener("wheel", this._onMapWheel, {passive: false})
      this.svgOverlay.addEventListener("pointerdown", this._onMapPointerDown)
      this.svgOverlay.dataset.clickBound = "true"
    }

    this.svgOverlay.setAttribute("viewBox", this.currentViewBox || viewBoxForMap(this.mapView, topVisualLinks(this.links, 26)))

    return this.svgOverlay
  },

  _ensureWorldMapBackground() {
    const parent = this.el.parentElement
    if (!parent) return null

    this.worldMapBackground = parent.querySelector(".sr-ops-world-map-background")
    if (!this.worldMapBackground) {
      this.worldMapBackground = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      this.worldMapBackground.classList.add("sr-ops-world-map-background")
      this.worldMapBackground.setAttribute("preserveAspectRatio", "xMidYMid meet")
      this.worldMapBackground.setAttribute("aria-hidden", "true")

      const ocean = document.createElementNS("http://www.w3.org/2000/svg", "rect")
      ocean.setAttribute("class", "sr-ops-world-map-ocean")
      ocean.setAttribute("x", "-180")
      ocean.setAttribute("y", "-90")
      ocean.setAttribute("width", "360")
      ocean.setAttribute("height", "180")

      const group = document.createElementNS("http://www.w3.org/2000/svg", "g")
      group.setAttribute("class", "sr-ops-world-map-countries")

      for (const d of WORLD_MAP_PATHS) {
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
        path.setAttribute("d", d)
        group.appendChild(path)
      }

      this.worldMapBackground.appendChild(ocean)
      this.worldMapBackground.appendChild(group)
      parent.insertBefore(this.worldMapBackground, this.el)
    }

    this.worldMapBackground.setAttribute("viewBox", this.currentViewBox || viewBoxForMap(this.mapView, topVisualLinks(this.links, 26)))

    return this.worldMapBackground
  },

  _ensureInteractionControls() {
    const parent = this.el.parentElement
    if (!parent || this.interactionControls) return

    this.interactionControls = document.createElement("div")
    this.interactionControls.className = "sr-ops-map-interaction-controls"
    this.interactionControls.innerHTML = `
      <button type="button" class="sr-ops-map-control-button" data-action="zoom-in" aria-label="Zoom in">+</button>
      <button type="button" class="sr-ops-map-control-button" data-action="zoom-out" aria-label="Zoom out">-</button>
      <button type="button" class="sr-ops-map-control-button" data-action="reset" aria-label="Reset map extent">Reset</button>
      <button type="button" class="sr-ops-map-control-button" data-action="world" aria-label="Show world extent">World</button>
    `
    this.interactionControls.querySelector('[data-action="zoom-in"]')?.addEventListener("click", this._zoomIn)
    this.interactionControls.querySelector('[data-action="zoom-out"]')?.addEventListener("click", this._zoomOut)
    this.interactionControls.querySelector('[data-action="reset"]')?.addEventListener("click", this._resetViewBox)
    this.interactionControls.querySelector('[data-action="world"]')?.addEventListener("click", this._fitWorld)
    parent.appendChild(this.interactionControls)
  },

  _setMapViewBox(viewBox) {
    if (!viewBox) return
    this.svgOverlay?.setAttribute("viewBox", viewBox)
    this.worldMapBackground?.setAttribute("viewBox", viewBox)

    const box = parseViewBox(viewBox)
    this.el.parentElement?.classList.toggle("is-netflow-zoomed", this.mapView === "netflow" && Boolean(box) && box.width < 180)
  },

  _syncViewBoxForLinks(links) {
    const autoViewBox = viewBoxForMap(this.mapView, links)
    const signature = links.map((link) => `${link.id}:${link.from.join(",")}:${link.to.join(",")}`).join("|")

    if (!this.currentViewBox || this.viewBoxSignature !== signature || this.mapView !== "netflow") {
      this.currentViewBox = autoViewBox
    }

    this.autoViewBox = autoViewBox
    this.viewBoxSignature = signature
    this._setMapViewBox(this.currentViewBox)
  },

  _scaleCurrentViewBox(factor, event = null) {
    if (this.mapView !== "netflow") return

    const focalPoint = event ? this._pointForClientEvent(event) : null
    const next = scaledViewBox(this.currentViewBox || this.autoViewBox, factor, focalPoint)
    if (!next) return
    this.currentViewBox = formatViewBox(next)
    this._setMapViewBox(this.currentViewBox)
    this._renderSvgOverlay()
  },

  _zoomIn() {
    this._scaleCurrentViewBox(0.82)
  },

  _zoomOut() {
    this._scaleCurrentViewBox(1.22)
  },

  _resetViewBox() {
    this.currentViewBox = this.autoViewBox
    this._setMapViewBox(this.currentViewBox)
    this._hideAnchorDetails()
    this._renderSvgOverlay()
  },

  _fitWorld() {
    if (this.mapView !== "netflow") return

    this.currentViewBox = NETFLOW_WORLD_VIEWBOX
    this._setMapViewBox(this.currentViewBox)
    this._hideAnchorDetails()
    this._renderSvgOverlay()
  },

  _onMapShellClick(event) {
    if (this.mapView !== "netflow") return
    if (event.target?.closest?.(".sr-ops-anchor-details")) return
    if (event.target?.closest?.(".sr-ops-map-controls, .sr-ops-map-interaction-controls")) return
    if (event.target?.closest?.(".sr-ops-traffic-link-hit")) return
    if (event.target?.closest?.(".sr-ops-traffic-label.is-cluster-label, .sr-ops-traffic-cluster-hit")) return
    if (event.target?.closest?.(".sr-ops-traffic-node.is-local-anchor, .sr-ops-traffic-node.is-external-geo, .sr-ops-traffic-label.is-clickable-endpoint, .sr-ops-traffic-endpoint-hit")) return

    this._hideAnchorDetails()
  },

  _onSvgOverlayClick(event) {
    if (this.suppressNextClick) {
      this.suppressNextClick = false
      event.preventDefault()
      event.stopPropagation()
      return
    }

    const flow = event.target?.closest?.(".sr-ops-traffic-link-hit")
    const cluster = event.target?.closest?.(".sr-ops-traffic-label.is-cluster-label, .sr-ops-traffic-cluster-hit")
    const node = event.target?.closest?.(".sr-ops-traffic-node.is-local-anchor, .sr-ops-traffic-node.is-external-geo, .sr-ops-traffic-label.is-clickable-endpoint")
      || event.target?.closest?.(".sr-ops-traffic-endpoint-hit")

    if (!node && !cluster && !flow) {
      this._hideAnchorDetails()
      return
    }

    event.preventDefault()
    event.stopPropagation()
    if (cluster) {
      this._showClusterDetails(cluster)
      return
    }
    if (flow) {
      this._showFlowDetails(flow)
      return
    }

    this._showAnchorDetails(node)
  },

  _onClusterLabelClick(event) {
    event.preventDefault()
    event.stopPropagation()
    this._showClusterDetails(event.currentTarget)
  },

  _showClusterDetails(labelNode) {
    const parent = this.el.parentElement
    if (!parent) return

    const parentRect = parent.getBoundingClientRect()
    const nodeRect = labelNode.getBoundingClientRect()
    const labels = String(labelNode.dataset.networkLabels || "")
      .split("|")
      .filter(Boolean)
    const totalBytes = Number(labelNode.dataset.totalBytes || 0)
    const flowCount = Number(labelNode.dataset.flowCount || 0)
    const flowsHtml = endpointFlowsHtml(labelNode.dataset.flows)

    if (!this.anchorDetails) {
      this.anchorDetails = document.createElement("div")
      parent.appendChild(this.anchorDetails)
    }
    this.anchorDetails.className = "sr-ops-anchor-details"

    this.anchorDetails.innerHTML = `
      <strong>${labels.length.toLocaleString()} networks</strong>
      ${labels.slice(0, 6).map((label) => `<span><em>Network</em><b>${escapeHtml(label)}</b></span>`).join("")}
      ${labels.length > 6 ? `<span><em>More</em><b>${(labels.length - 6).toLocaleString()}</b></span>` : ""}
      <span><em>Observed conversations</em><b>${flowCount.toLocaleString()}</b></span>
      <span><em>Traffic</em><b>${formatBytes(totalBytes)}</b></span>
      ${flowsHtml}
    `
    this.anchorDetails.style.left = `${Math.min(parentRect.width - 240, Math.max(12, nodeRect.left - parentRect.left + 12))}px`
    this.anchorDetails.style.top = `${Math.min(parentRect.height - 150, Math.max(12, nodeRect.top - parentRect.top + 12))}px`
  },

  _showAnchorDetails(node) {
    const parent = this.el.parentElement
    if (!parent) return

    const parentRect = parent.getBoundingClientRect()
    const nodeRect = node.getBoundingClientRect()
    const totalBytes = Number(node.dataset.totalBytes || 0)
    const flowCount = Number(node.dataset.flowCount || 0)
    const kind = node.dataset.endpointKind || "network"
    const label = node.dataset.anchorLabel || (kind === "external" ? "External endpoint" : "Network")
    const endpointIp = node.dataset.endpointIp
    const endpointCountry = node.dataset.endpointCountry
    const fullLabel = node.dataset.fullLabel
    const coords = [node.dataset.latitude, node.dataset.longitude].filter(Boolean).join(", ")
    const flowsHtml = endpointFlowsHtml(node.dataset.flows)

    if (!this.anchorDetails) {
      this.anchorDetails = document.createElement("div")
      parent.appendChild(this.anchorDetails)
    }
    this.anchorDetails.className = "sr-ops-anchor-details"

    this.anchorDetails.innerHTML = `
      <strong>${escapeHtml(label)}</strong>
      <span><em>Type</em><b>${kind === "external" ? "Geo endpoint" : "Network"}</b></span>
      ${endpointCountry ? `<span><em>Country</em><b>${escapeHtml(endpointCountry)}</b></span>` : ""}
      ${endpointIp ? `<span><em>Address</em><b>${escapeHtml(endpointIp)}</b></span>` : ""}
      ${fullLabel && fullLabel !== label && !endpointIp ? `<span><em>Label</em><b>${escapeHtml(fullLabel)}</b></span>` : ""}
      <span><em>Observed conversations</em><b>${flowCount.toLocaleString()}</b></span>
      <span><em>Traffic</em><b>${formatBytes(totalBytes)}</b></span>
      ${coords ? `<span><em>Coordinates</em><b>${escapeHtml(coords)}</b></span>` : ""}
      ${flowsHtml}
    `
    const detailsWidth = Math.max(220, this.anchorDetails.offsetWidth || 0)
    const detailsHeight = Math.max(112, this.anchorDetails.offsetHeight || 0)
    this.anchorDetails.style.left = `${Math.min(parentRect.width - detailsWidth - 12, Math.max(12, nodeRect.left - parentRect.left + 12))}px`
    this.anchorDetails.style.top = `${Math.min(parentRect.height - detailsHeight - 12, Math.max(12, nodeRect.top - parentRect.top + 12))}px`
  },

  _showFlowDetails(flowNode) {
    const parent = this.el.parentElement
    if (!parent) return

    const parentRect = parent.getBoundingClientRect()
    const nodeRect = flowNode.getBoundingClientRect()
    const source = flowNode.dataset.sourceLabel || "Unknown source"
    const target = flowNode.dataset.targetLabel || "Unknown target"
    const bytes = Number(flowNode.dataset.bytes || 0)
    const packets = Number(flowNode.dataset.packets || 0)
    const flowCount = Number(flowNode.dataset.flowCount || 0)
    const rate = Number(flowNode.dataset.flowBps || 0)

    if (!this.anchorDetails) {
      this.anchorDetails = document.createElement("div")
      parent.appendChild(this.anchorDetails)
    }
    this.anchorDetails.className = "sr-ops-anchor-details is-flow-details"

    this.anchorDetails.innerHTML = `
      <strong>Flow path</strong>
      <span class="is-endpoint-row"><em>Source</em><b>${escapeHtml(source)}</b></span>
      <span class="is-endpoint-row"><em>Destination</em><b>${escapeHtml(target)}</b></span>
      <span><em>Observed conversations</em><b>${flowCount.toLocaleString()}</b></span>
      <span><em>Traffic</em><b>${formatBytes(bytes)}</b></span>
      ${packets > 0 ? `<span><em>Packets</em><b>${packets.toLocaleString()}</b></span>` : ""}
      ${rate > 0 ? `<span><em>Rate</em><b>${formatRate(rate)}</b></span>` : ""}
    `
    this.anchorDetails.style.left = `${Math.min(parentRect.width - 300, Math.max(12, nodeRect.left - parentRect.left + nodeRect.width * 0.45))}px`
    this.anchorDetails.style.top = `${Math.min(parentRect.height - 218, Math.max(12, nodeRect.top - parentRect.top + nodeRect.height * 0.35))}px`
  },

  _renderSvgOverlay() {
    const svg = this._ensureSvgOverlay()
    if (!svg) return

    let visualLinks = []
    let overlayLinks = []

    if (this.mapView === "netflow") {
      visualLinks = topVisualLinks(this.links, 26)
    } else {
      const rawTopologyLinks = topVisualLinks(this.topologyLinks, 24, {includeIdle: true}).map((link) => ({
        ...link,
        overlayKind: "topology",
      }))
      const rawOverlayLinks = topVisualLinks(this.overlays, 2).map((link) => ({
        ...link,
        overlayKind: "mtr",
      }))
      const schematicLinks = topologySchematicLinks([...rawTopologyLinks, ...rawOverlayLinks])

      visualLinks = schematicLinks.filter((link) => link.overlayKind === "topology")
      overlayLinks = schematicLinks.filter((link) => link.overlayKind === "mtr")
    }

    this._syncViewBoxForLinks(visualLinks)

    if (visualLinks.length === 0 && overlayLinks.length === 0) {
      svg.replaceChildren()
      return
    }

    const currentBox = parseViewBox(this.currentViewBox || this.autoViewBox)
    const zoomWidth = currentBox?.width || 360
    const geometryStyle = this.mapView === "netflow" ? netflowGeometryStyle(zoomWidth) : null
    const fragment = document.createDocumentFragment()
    const linkGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const particleGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const nodeGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const labelGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const linksForNodes = this.mapView === "netflow" ? visualLinks.slice(0, 16) : visualLinks.slice(0, 18)

    linkGroup.setAttribute("class", "sr-ops-traffic-overlay-links")
    particleGroup.setAttribute("class", "sr-ops-traffic-overlay-particles")
    nodeGroup.setAttribute("class", "sr-ops-traffic-overlay-nodes")
    labelGroup.setAttribute("class", "sr-ops-traffic-overlay-labels")

    visualLinks.forEach((link, idx) => {
      const pathData = svgPathForLink(link, idx, this.mapView)
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
      const baseStrokeWidth = this.mapView === "topology_traffic" && visualMagnitude(link) <= 0 ? 1.15 : strokeWidthFor(link, this.mapView)
      const strokeWidth = this.mapView === "netflow" ? baseStrokeWidth * geometryStyle.scale : baseStrokeWidth

      if (this.mapView === "netflow") {
        const halo = document.createElementNS("http://www.w3.org/2000/svg", "path")
        halo.setAttribute("d", pathData)
        halo.setAttribute("class", `sr-ops-traffic-path-halo ${netflowPathClass(link)}`)
        halo.setAttribute("stroke", rgbaCss(link.color, 0.8))
        halo.setAttribute("stroke-width", String(strokeWidth + geometryStyle.haloExtraWidth))
        linkGroup.appendChild(halo)
      }

      if (this.mapView === "netflow") {
        const hit = document.createElementNS("http://www.w3.org/2000/svg", "path")
        const source = flowEndpointLabel(link.sourceAnchorLabel || link.sourceGeoLabel || link.sourceLabel, link.sourceIp, "Source")
        const target = flowEndpointLabel(link.targetAnchorLabel || link.targetGeoLabel || link.targetLabel, link.targetIp, "Destination")

        hit.setAttribute("d", pathData)
        hit.setAttribute("class", "sr-ops-traffic-link-hit")
        hit.setAttribute("stroke-width", String(Math.max(7, strokeWidth + geometryStyle.haloExtraWidth + 3)))
        hit.setAttribute("role", "button")
        hit.setAttribute("tabindex", "0")
        hit.setAttribute("aria-label", `${source} to ${target} flow`)
        hit.dataset.sourceLabel = source
        hit.dataset.targetLabel = target
        hit.dataset.bytes = String(link.bytes || link.magnitude || 0)
        hit.dataset.packets = String(link.packets || 0)
        hit.dataset.flowCount = String(link.flowCount || 0)
        hit.dataset.flowBps = String(link.flowBps || 0)
        linkGroup.appendChild(hit)
      }

      path.setAttribute("d", pathData)
      path.setAttribute("class", "sr-ops-traffic-path")
      path.classList.add(this.mapView === "netflow" ? "is-netflow" : "is-topology")
      if (this.mapView === "netflow") path.classList.add(netflowPathClass(link))
      path.setAttribute("stroke", rgbaCss(link.color, this.mapView === "netflow" ? 1.08 : 0.88))
      path.setAttribute("stroke-width", String(strokeWidth))
      path.dataset.opsTrafficPath = "true"
      if (this.mapView === "topology_traffic" && visualMagnitude(link) <= 0) {
        path.classList.add("is-idle")
      }
      path.style.setProperty("--traffic-delay", `${(idx % 7) * -0.38}s`)
      linkGroup.appendChild(path)

      if (this.mapView === "netflow") {
        const arrow = document.createElementNS("http://www.w3.org/2000/svg", "path")
        const arrowGeometry = linkArrowGeometry(link, idx, this.mapView, geometryStyle.arrowSize)

        arrow.setAttribute("d", arrowGeometry.d)
        arrow.setAttribute("transform", arrowGeometry.transform)
        arrow.setAttribute("class", `sr-ops-traffic-arrow ${netflowPathClass(link)}`)
        arrow.setAttribute("fill", rgbaCss(link.color, 1.08))
        arrow.setAttribute("stroke", "rgba(2, 8, 23, 0.72)")
        arrow.setAttribute("stroke-width", String(Math.max(0.18, geometryStyle.arrowSize * 0.18)))
        linkGroup.appendChild(arrow)
      }

      if (this.mapView !== "netflow" && idx < 10 && visualMagnitude(link) > 0) {
        const particle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
        const motion = document.createElementNS("http://www.w3.org/2000/svg", "animateMotion")

        particle.setAttribute("r", String(this.mapView === "netflow" ? 0.7 : Math.min(1.85, Math.max(1, strokeWidthFor(link) * 0.38))))
        particle.setAttribute("fill", rgbaCss(link.color, 1.2))
        particle.setAttribute("class", "sr-ops-traffic-particle")
        motion.setAttribute("dur", `${Math.max(2.4, 5.8 - Math.min(2.6, Math.log10(Math.max(10, visualMagnitude(link) || 10)) * 0.24))}s`)
        motion.setAttribute("begin", `${(idx % 6) * 0.22}s`)
        motion.setAttribute("repeatCount", "indefinite")
        motion.setAttribute("path", pathData)
        particle.appendChild(motion)
        particleGroup.appendChild(particle)
      }
    })

    overlayLinks.forEach((link, idx) => {
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")

      path.setAttribute("d", svgPathForLink(link, idx, this.mapView))
      path.setAttribute("class", "sr-ops-mtr-overlay-path")
      linkGroup.appendChild(path)
    })

    const nodeData = endpointNodes(linksForNodes, this.mapView)

    nodeData.forEach((endpoint) => {
      const node = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      const point = endpoint.position
      const [cx, cy] = projectedSvgPoint(point, this.mapView)
      const isExternalNetflow = this.mapView === "netflow" && !endpoint.localAnchor
      const radius = this.mapView === "netflow"
        ? endpoint.localAnchor
          ? geometryStyle.localNodeRadius
          : geometryStyle.externalNodeRadius
        : 2.4

      node.setAttribute("cx", cx)
      node.setAttribute("cy", cy)
      node.setAttribute("r", String(radius))
      node.setAttribute("fill", isExternalNetflow ? "rgba(148, 163, 184, 0.45)" : rgbaCss(endpoint.color, 1.25))
      node.setAttribute("class", "sr-ops-traffic-node")
      node.classList.add(endpoint.localAnchor ? "is-local-anchor" : "is-external-geo")
      if (this.mapView === "netflow") {
        node.setAttribute("role", "button")
        node.setAttribute("tabindex", "0")
        node.setAttribute("aria-label", `${endpoint.anchorLabel || endpoint.sourceGeoLabel || endpoint.sourceLabel} ${endpoint.localAnchor ? "network" : "geo endpoint"}`)
        node.dataset.endpointKind = endpoint.localAnchor ? "network" : "external"
        node.dataset.anchorLabel = endpoint.anchorLabel || endpoint.sourceGeoLabel || endpoint.sourceLabel || (endpoint.localAnchor ? "Network" : "External endpoint")
        node.dataset.totalBytes = String(endpoint.magnitude || 0)
        node.dataset.flowCount = String(endpoint.count || 0)
        node.dataset.flows = JSON.stringify(endpoint.flows || [])
        node.dataset.latitude = String(Math.round(Number(endpoint.latitude || 0) * 10_000) / 10_000)
        node.dataset.longitude = String(Math.round(Number(endpoint.longitude || 0) * 10_000) / 10_000)
      }
      nodeGroup.appendChild(node)
    })

    const renderedLabels = new Set()
    const renderedLabelBoxes = []
    const labelOffsets = [
      [4, -3.4],
      [4, 5.8],
      [-4, -3.4],
      [-4, 5.8],
      [6, 0],
      [-6, 0],
    ]

    if (this.mapView === "topology_traffic") {
      nodeData.forEach((endpoint) => {
        const point = endpoint.position
        const label = endpoint.sourceLabel
        if (!label || renderedLabels.has(label) || renderedLabels.size >= 9) return
        renderedLabels.add(label)
        const [x, y] = projectedSvgPoint(point, this.mapView)
        const [dx, dy] = labelOffsets[renderedLabels.size % labelOffsets.length]
        const labelX = x + dx
        const labelY = y + dy
        const collides = renderedLabelBoxes.some((box) => Math.abs(box.x - labelX) < 24 && Math.abs(box.y - labelY) < 9)

        if (collides) return

        const text = document.createElementNS("http://www.w3.org/2000/svg", "text")

        text.setAttribute("x", labelX)
        text.setAttribute("y", labelY)
        if (dx < 0) text.setAttribute("text-anchor", "end")
        text.setAttribute("class", "sr-ops-traffic-label")
        text.textContent = shortNodeLabel(label)
        labelGroup.appendChild(text)
        renderedLabelBoxes.push({x: labelX, y: labelY})
      })
    } else if (this.mapView === "netflow") {
      const endpointsByKey = new Map()
      const externalLabelLimit = zoomWidth < 45 ? 10 : zoomWidth < 90 ? 8 : zoomWidth < 150 ? 6 : 5
      const networkLabelLimit = zoomWidth < 160 ? 5 : 3
      const labelLimit = networkLabelLimit + externalLabelLimit

      visualLinks.forEach((link) => {
        ;[
          {
            point: link.from,
            label: link.sourceLocalAnchor ? link.sourceAnchorLabel || link.sourceLabel : link.sourceGeoLabel || link.sourceLabel,
            local: link.sourceLocalAnchor,
            magnitude: visualMagnitude(link),
            count: 1,
            flow: endpointFlowSummary(link, "source"),
          },
          {
            point: link.to,
            label: link.targetLocalAnchor ? link.targetAnchorLabel || link.targetLabel : link.targetGeoLabel || link.targetLabel,
            local: link.targetLocalAnchor,
            magnitude: visualMagnitude(link),
            count: 1,
            flow: endpointFlowSummary(link, "target"),
          },
        ].forEach((endpoint) => {
          const [x, y] = projectedSvgPoint(endpoint.point, this.mapView)
          const fullLabel = String(endpoint.label || "").trim()
          const label = shortEndpointLabel(fullLabel)
          if (!label) return

          const key = endpoint.local ? `network:${label}` : `geo:${label}:${Math.round(x * 4) / 4}:${Math.round(y * 4) / 4}`
          const existing = endpointsByKey.get(key)
          if (existing) {
            existing.magnitude += endpoint.magnitude || 0
            existing.count += 1
            existing.flows = normalizeEndpointFlows([...(existing.flows || []), endpoint.flow])
          } else {
            endpointsByKey.set(key, {...endpoint, fullLabel, label, x, y, count: 1, flows: normalizeEndpointFlows([endpoint.flow])})
          }
        })
      })

      const candidateEndpoints = [...endpointsByKey.values()]
        .sort((a, b) => Number(b.local) - Number(a.local) || b.magnitude - a.magnitude)
        .filter((endpoint) => endpoint.local || externalLabelLimit > 0)
        .slice(0, Math.max(8, labelLimit * 2))
      const clusteredNetworkKeys = new Set()
      const clusteredNetworks = candidateEndpoints.filter((endpoint) => endpoint.local)
      const clusterRadius = Math.max(2.8, zoomWidth * 0.018)

      if (clusteredNetworks.length > 1) {
        const clusters = []

        clusteredNetworks.forEach((endpoint) => {
          const cluster = clusters.find((item) => item.some((candidate) => Math.hypot(candidate.x - endpoint.x, candidate.y - endpoint.y) <= clusterRadius))
          if (cluster) {
            cluster.push(endpoint)
          } else {
            clusters.push([endpoint])
          }
        })

        clusters
          .filter((cluster) => cluster.length > 1)
          .forEach((cluster) => {
            const x = cluster.reduce((sum, endpoint) => sum + endpoint.x, 0) / cluster.length
            const y = cluster.reduce((sum, endpoint) => sum + endpoint.y, 0) / cluster.length
            const labelStyle = netflowLabelStyle(zoomWidth, true)
            const labelX = x + 3.8
            const labelY = y - 4.2
            const hit = document.createElementNS("http://www.w3.org/2000/svg", "rect")
            const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
            const networkLabels = cluster.map((endpoint) => endpoint.label).sort((a, b) => a.localeCompare(b))
            const displayLabel = networkClusterLabel(networkLabels)
            const totalBytes = cluster.reduce((sum, endpoint) => sum + Number(endpoint.magnitude || 0), 0)
            const flowCount = cluster.reduce((sum, endpoint) => sum + Number(endpoint.count || 0), 0)
            const pillWidth = Math.max(labelStyle.fontSize * (displayLabel.length * 0.68 + 1.8), labelStyle.collisionX * 0.8)
            const pillHeight = Math.max(labelStyle.fontSize * 2.55, labelStyle.collisionY * 1.3)

            cluster.forEach((endpoint) => clusteredNetworkKeys.add(`network:${endpoint.label}`))
            renderedLabels.add(`network-cluster:${labelX}:${labelY}`)
            hit.setAttribute("x", String(labelX - pillWidth * 0.18))
            hit.setAttribute("y", String(labelY - pillHeight * 0.72))
            hit.setAttribute("width", String(pillWidth))
            hit.setAttribute("height", String(pillHeight))
            hit.setAttribute("rx", String(Math.max(labelStyle.fontSize * 0.8, 0.8)))
            hit.setAttribute("class", "sr-ops-traffic-cluster-hit")
            hit.setAttribute("role", "button")
            hit.setAttribute("tabindex", "0")
            hit.setAttribute("aria-label", `${displayLabel} clustered networks`)
            hit.dataset.networkLabels = networkLabels.join("|")
            hit.dataset.totalBytes = String(totalBytes)
            hit.dataset.flowCount = String(flowCount)
            hit.dataset.flows = JSON.stringify(normalizeEndpointFlows(cluster.flatMap((endpoint) => endpoint.flows || [])))
            hit.addEventListener("click", this._onClusterLabelClick)
            labelGroup.appendChild(hit)
            text.setAttribute("x", labelX)
            text.setAttribute("y", labelY)
            text.setAttribute("class", "sr-ops-traffic-label is-network-label is-cluster-label")
            text.setAttribute("role", "button")
            text.setAttribute("tabindex", "0")
            text.setAttribute("aria-label", `${displayLabel} clustered networks`)
            text.dataset.networkLabels = networkLabels.join("|")
            text.dataset.totalBytes = String(totalBytes)
            text.dataset.flowCount = String(flowCount)
            text.dataset.flows = JSON.stringify(normalizeEndpointFlows(cluster.flatMap((endpoint) => endpoint.flows || [])))
            text.addEventListener("click", this._onClusterLabelClick)
            text.style.fontSize = `${labelStyle.fontSize}px`
            text.style.strokeWidth = `${labelStyle.strokeWidth}px`
            text.textContent = displayLabel
            labelGroup.appendChild(text)
            renderedLabelBoxes.push({x: labelX, y: labelY, collisionX: Math.max(labelStyle.collisionX, pillWidth * 0.68), collisionY: labelStyle.collisionY})
          })
      }

      candidateEndpoints
        .forEach((endpoint, idx) => {
          const label = shortEndpointLabel(endpoint.label)
          if (!label) return

          const x = endpoint.x
          const y = endpoint.y
          const key = endpoint.local ? `network:${label}` : `geo:${label}:${Math.round(x * 4) / 4}:${Math.round(y * 4) / 4}`
          if (clusteredNetworkKeys.has(key)) return
          if (renderedLabels.has(key) || renderedLabels.size >= labelLimit) return
          if (reservedNetflowLegendArea(endpoint, currentBox)) return
          if (endpoint.local && [...renderedLabels].filter((item) => item.startsWith("network:")).length >= networkLabelLimit) return
          if (!endpoint.local && [...renderedLabels].filter((item) => item.startsWith("geo:")).length >= externalLabelLimit) return

          const [dx, dy] = labelOffsets[idx % labelOffsets.length]
          const labelX = x + dx
          const labelY = y + dy
          const labelStyle = netflowLabelStyle(zoomWidth, endpoint.local)
          const collides = renderedLabelBoxes.some(
            (box) => Math.abs(box.x - labelX) < Math.max(box.collisionX, labelStyle.collisionX) && Math.abs(box.y - labelY) < Math.max(box.collisionY, labelStyle.collisionY),
          )
          if (collides && !endpoint.local && currentBox?.width > 90) return

          renderedLabels.add(key)

          const hit = document.createElementNS("http://www.w3.org/2000/svg", "rect")
          const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
          const hitWidth = Math.max(labelStyle.fontSize * label.length * 0.86, labelStyle.collisionX * 0.68)
          const hitHeight = Math.max(labelStyle.fontSize * 2.5, labelStyle.collisionY * 1.12)

          hit.setAttribute("x", String(dx < 0 ? labelX - hitWidth : labelX - labelStyle.fontSize * 0.45))
          hit.setAttribute("y", String(labelY - hitHeight * 0.72))
          hit.setAttribute("width", String(hitWidth))
          hit.setAttribute("height", String(hitHeight))
          hit.setAttribute("rx", String(Math.max(labelStyle.fontSize * 0.62, 0.6)))
          hit.setAttribute("class", `sr-ops-traffic-endpoint-hit ${endpoint.local ? "is-network-endpoint" : "is-external-endpoint"}`)
          hit.setAttribute("role", "button")
          hit.setAttribute("tabindex", "0")
          hit.setAttribute("aria-label", `${label} ${endpoint.local ? "network" : "geo endpoint"}`)
          hit.dataset.endpointKind = endpoint.local ? "network" : "external"
          hit.dataset.anchorLabel = label
          hit.dataset.fullLabel = endpoint.fullLabel || label
          hit.dataset.totalBytes = String(endpoint.magnitude || 0)
          hit.dataset.flowCount = String(endpoint.count || 0)
          hit.dataset.flows = JSON.stringify(endpoint.flows || [])
          hit.dataset.latitude = String(Math.round(Number(endpoint.point?.[1] || 0) * 10_000) / 10_000)
          hit.dataset.longitude = String(Math.round(Number(endpoint.point?.[0] || 0) * 10_000) / 10_000)
          const countryIp = countryIpLabel(endpoint.fullLabel)
          if (countryIp) {
            hit.dataset.endpointCountry = countryIp.countryName
            hit.dataset.endpointIp = countryIp.ip
          }
          labelGroup.appendChild(hit)

          text.setAttribute("x", labelX)
          text.setAttribute("y", labelY)
          if (dx < 0) text.setAttribute("text-anchor", "end")
          text.setAttribute("class", endpoint.local ? "sr-ops-traffic-label is-network-label is-clickable-endpoint" : "sr-ops-traffic-label is-external-label is-clickable-endpoint")
          text.setAttribute("role", "button")
          text.setAttribute("tabindex", "0")
          text.setAttribute("aria-label", `${label} ${endpoint.local ? "network" : "geo endpoint"}`)
          text.dataset.endpointKind = endpoint.local ? "network" : "external"
          text.dataset.anchorLabel = label
          text.dataset.fullLabel = endpoint.fullLabel || label
          text.dataset.totalBytes = String(endpoint.magnitude || 0)
          text.dataset.flowCount = String(endpoint.count || 0)
          text.dataset.flows = JSON.stringify(endpoint.flows || [])
          text.dataset.latitude = String(Math.round(Number(endpoint.point?.[1] || 0) * 10_000) / 10_000)
          text.dataset.longitude = String(Math.round(Number(endpoint.point?.[0] || 0) * 10_000) / 10_000)
          if (countryIp) {
            text.dataset.endpointCountry = countryIp.countryName
            text.dataset.endpointIp = countryIp.ip
          }
          text.style.fontSize = `${labelStyle.fontSize}px`
          text.style.strokeWidth = `${labelStyle.strokeWidth}px`
          text.textContent = label
          labelGroup.appendChild(text)
          renderedLabelBoxes.push({x: labelX, y: labelY, collisionX: labelStyle.collisionX, collisionY: labelStyle.collisionY})
        })
    }

    fragment.appendChild(linkGroup)
    fragment.appendChild(particleGroup)
    fragment.appendChild(nodeGroup)
    fragment.appendChild(labelGroup)
    svg.replaceChildren(fragment)
  },

  _syncData() {
    this.mapView = MAP_VIEWS.has(this.el.dataset.mapView) ? this.el.dataset.mapView : "topology_traffic"
    this._ensureWorldMapBackground()
    this.el.parentElement?.classList.toggle("is-netflow-view", this.mapView === "netflow")
    this.topologyLinks = this.mapView === "topology_traffic" ? normalizeLinks(parseJson(this.el.dataset.topologyLinks, [])) : []
    this.links = normalizeTrafficLinks(parseJson(this.el.dataset.links, []), this.mapView)
    this.overlays = this.mapView === "topology_traffic" ? normalizeLinks(parseJson(this.el.dataset.mtrOverlays, [])) : []
    this._renderSvgOverlay()
  },
}
