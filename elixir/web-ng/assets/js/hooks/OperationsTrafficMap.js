import {COORDINATE_SYSTEM, Deck, OrthographicView} from "@deck.gl/core"
import {ArcLayer, LineLayer, PolygonLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

const MAP_VIEWS = new Set(["topology_traffic", "netflow"])
const BASE_GRID_LINES = buildGridLines()

function parseJson(value, fallback) {
  try {
    const parsed = JSON.parse(value || "")
    return Array.isArray(parsed) ? parsed : fallback
  } catch (_e) {
    return fallback
  }
}

function buildGridLines() {
  const lines = []

  for (let x = -150; x <= 150; x += 30) lines.push({from: [x, -58], to: [x, 58]})
  for (let y = -45; y <= 45; y += 15) lines.push({from: [-176, y], to: [176, y]})

  return lines
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
      const color = scaledColor(Array.isArray(link?.color) ? link.color : [56, 189, 248, 180], useGeo && !geoMapped ? 0.45 : 1)
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
    .filter((link) => link.from[0] !== link.to[0] || link.from[1] !== link.to[1])
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

function formatRate(value) {
  const bps = Number(value || 0)
  if (bps >= 1_000_000_000) return `${(bps / 1_000_000_000).toFixed(1)} Gbps`
  if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`
  if (bps >= 1_000) return `${(bps / 1_000).toFixed(1)} Kbps`
  if (bps > 0) return `${bps.toFixed(0)} bps`
  return "No rate"
}

function formatBytes(value) {
  const bytes = Number(value || 0)
  if (bytes >= 1_000_000_000_000) return `${(bytes / 1_000_000_000_000).toFixed(1)} TB`
  if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(1)} KB`
  return `${bytes.toFixed(0)} B`
}

function svgPoint(point) {
  return `${Math.round(Number(point[0] || 0) * 10) / 10} ${Math.round(Number(point[1] || 0) * 10) / 10}`
}

function svgPathForLink(link, idx) {
  const [x1, y1] = link.from
  const [x2, y2] = link.to
  const dx = x2 - x1
  const dy = y2 - y1
  const distance = Math.max(1, Math.hypot(dx, dy))
  const curve = Math.min(14, Math.max(3, distance * 0.075)) * (idx % 2 === 0 ? 1 : -1)
  const cx = (x1 + x2) / 2 - (dy / distance) * curve
  const cy = (y1 + y2) / 2 + (dx / distance) * curve

  return `M ${svgPoint(link.from)} Q ${Math.round(cx * 10) / 10} ${Math.round(cy * 10) / 10} ${svgPoint(link.to)}`
}

function rgbaCss(color, alphaMultiplier = 1) {
  const rgba = scaledColor(color, alphaMultiplier)
  return `rgba(${rgba[0]}, ${rgba[1]}, ${rgba[2]}, ${Math.max(0.18, Math.min(1, rgba[3] / 255))})`
}

function strokeWidthFor(link) {
  return Math.round((0.8 + Math.min(4.8, Math.log10(Math.max(10, link.magnitude || link.flowBps || link.bytes || 10)) / 1.25)) * 10) / 10
}

function topVisualLinks(links, limit) {
  return [...links]
    .filter((link) => Number(link.magnitude || link.flowBps || link.bytes || 0) > 0)
    .sort((a, b) => Number(b.magnitude || b.flowBps || b.bytes || 0) - Number(a.magnitude || a.flowBps || a.bytes || 0))
    .slice(0, limit)
}

function sparklineSvg(points, fallbackLabel) {
  if (!Array.isArray(points) || points.length < 2) return ""

  const values = points.map((point) => Math.max(0, Number(point?.value ?? point ?? 0)))
  const maxValue = Math.max(...values)
  if (!Number.isFinite(maxValue) || maxValue <= 0) return ""
  const label = points.find((point) => point?.label)?.label || fallbackLabel || "Recent interface rate"

  const width = 148
  const height = 34
  const step = width / Math.max(values.length - 1, 1)
  const polyline = values
    .map((value, idx) => {
      const x = Math.round(idx * step * 10) / 10
      const y = Math.round((height - (value / maxValue) * (height - 4) - 2) * 10) / 10
      return `${x},${y}`
    })
    .join(" ")

  return `
    <div class="sr-ops-map-tooltip-spark">
      <span>${escapeHtml(label)}</span>
      <svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Interface rate sparkline">
        <polyline points="${polyline}" />
      </svg>
    </div>
  `
}

function tooltipFor(object, layer) {
  if (!object) return null

  const title = [object.sourceLabel, object.targetLabel].filter(Boolean).join(" -> ") || object.sourceLabel || object.id || "Traffic path"
  const details = []

  if (object.protocol) details.push(["Protocol", object.protocol])
  if (object.telemetrySource) details.push(["Telemetry", object.telemetrySource])
  if (object.sourceIp && object.sourceIp !== object.sourceLabel) details.push(["Source IP", object.sourceIp])
  if (object.targetIp && object.targetIp !== object.targetLabel) details.push(["Destination IP", object.targetIp])
  if (object.sourceGeoLabel && object.sourceGeoLabel !== object.sourceLabel) details.push(["Source Geo", object.sourceGeoLabel])
  if (object.targetGeoLabel && object.targetGeoLabel !== object.targetLabel) details.push(["Destination Geo", object.targetGeoLabel])
  if (object.geoMapped === false) details.push(["GeoIP", "not enriched"])
  if (object.localInterface || object.neighborInterface) {
    details.push(["Interfaces", [object.localInterface, object.neighborInterface].filter(Boolean).join(" -> ")])
  }
  if (object.bytes > 0) details.push(["Bytes", formatBytes(object.bytes)])
  if (object.flowCount > 0) details.push(["Flows", object.flowCount.toLocaleString()])
  if (object.flowBps > 0 || layer?.id === "ops-topology-links") details.push(["Current rate", formatRate(object.flowBps)])
  if (object.capacityBps > 0) details.push(["Capacity", formatRate(object.capacityBps)])
  if (object.utilizationPct > 0) details.push(["Utilization", `${object.utilizationPct.toFixed(1)}%`])

  return {
    html: `
      <div class="sr-ops-map-tooltip">
        <strong>${escapeHtml(title)}</strong>
        ${details.map(([label, value]) => `<span><em>${escapeHtml(label)}</em>${escapeHtml(value)}</span>`).join("")}
        ${sparklineSvg(object.sparkline, object.sparklineLabel)}
      </div>
    `,
    style: {
      backgroundColor: "rgba(2, 8, 23, 0.94)",
      border: "1px solid rgba(56, 189, 248, 0.38)",
      borderRadius: "6px",
      color: "#e2e8f0",
      fontFamily: "Inter, ui-sans-serif, system-ui",
      fontSize: "12px",
      maxWidth: "320px",
      padding: "10px 12px",
    },
  }
}

function endpointNodes(links) {
  const byKey = new Map()

  for (const link of links) {
    const endpoints = [
      {
        point: link.from,
        label: link.sourceLabel,
        ip: link.sourceIp,
        geoLabel: link.sourceGeoLabel,
        color: link.color,
        magnitude: link.magnitude,
      },
      {
        point: link.to,
        label: link.targetLabel,
        ip: link.targetIp,
        geoLabel: link.targetGeoLabel,
        color: link.color,
        magnitude: link.magnitude,
      },
    ]

    for (const endpoint of endpoints) {
      const point = endpoint.point
      const key = `${point[0].toFixed(2)},${point[1].toFixed(2)}`

      if (!byKey.has(key)) {
        byKey.set(key, {
          id: key,
          position: [point[0], point[1], 0],
          color: endpoint.color,
          sourceLabel: endpoint.label || endpoint.ip || key,
          sourceIp: endpoint.ip,
          sourceGeoLabel: endpoint.geoLabel,
          magnitude: endpoint.magnitude || 0,
          count: 1,
        })
      } else {
        const existing = byKey.get(key)
        existing.magnitude += endpoint.magnitude || 0
        existing.count += 1
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
    this.time = 0
    this._tick = this._tick.bind(this)
    this._resizeDeck = this._resizeDeck.bind(this)
    this._onMapViewChange = this._onMapViewChange.bind(this)
    this._onExternalMapViewChange = this._onExternalMapViewChange.bind(this)
    document.addEventListener("change", this._onMapViewChange)
    window.addEventListener("serviceradar:dashboard-map-view", this._onExternalMapViewChange)
    this._initDeck()
    this._ensureSvgOverlay()
    this.resizeObserver = new ResizeObserver(this._resizeDeck)
    this.resizeObserver.observe(this.el.parentElement || this.el)
    this._resizeDeck()
    this._syncData()
    this._tick()
  },

  updated() {
    this._syncData()
  },

  destroyed() {
    document.removeEventListener("change", this._onMapViewChange)
    window.removeEventListener("serviceradar:dashboard-map-view", this._onExternalMapViewChange)
    this.resizeObserver?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.svgOverlay?.remove()
    this.deck?.finalize()
    this.deck = null
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

  _initDeck() {
    const {width, height} = this._deckSize()

    this.deck = new Deck({
      canvas: this.el,
      width,
      height,
      views: new OrthographicView({
        id: "ops-traffic-view",
        flipY: false,
        clear: true,
        clearColor: [2, 8, 23, 255],
      }),
      initialViewState: {
        target: [0, 0, 0],
        zoom: 1.34,
      },
      controller: {dragPan: true, scrollZoom: true, doubleClickZoom: true, touchZoom: true},
      useDevicePixels: true,
      parameters: {
        blend: true,
        blendFunc: [770, 771],
        depthTest: false,
        depthWrite: false,
      },
      getTooltip: () => null,
      layers: this._layers(),
    })
  },

  _deckSize() {
    const parent = this.el.parentElement || this.el
    return {
      width: Math.max(320, Math.floor(parent.clientWidth || this.el.clientWidth || 0)),
      height: Math.max(180, Math.floor(parent.clientHeight || this.el.clientHeight || 0)),
    }
  },

  _resizeDeck() {
    if (!this.deck) return
    const {width, height} = this._deckSize()
    this.deck.setProps({width, height})
    this.deck.redraw(true)
  },

  _ensureSvgOverlay() {
    const parent = this.el.parentElement
    if (!parent) return null

    this.svgOverlay = parent.querySelector(".sr-ops-traffic-overlay")
    if (!this.svgOverlay) {
      this.svgOverlay = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      this.svgOverlay.classList.add("sr-ops-traffic-overlay")
      this.svgOverlay.setAttribute("viewBox", "-180 -90 360 180")
      this.svgOverlay.setAttribute("preserveAspectRatio", "xMidYMid meet")
      this.svgOverlay.setAttribute("aria-hidden", "true")
      parent.appendChild(this.svgOverlay)
    }

    return this.svgOverlay
  },

  _renderSvgOverlay() {
    const svg = this._ensureSvgOverlay()
    if (!svg) return

    const visualLinks =
      this.mapView === "netflow" ? topVisualLinks(this.links, 32) : topVisualLinks(this.topologyLinks, 18)
    const overlayLinks = this.mapView === "topology_traffic" ? topVisualLinks(this.overlays, 8) : []

    if (visualLinks.length === 0 && overlayLinks.length === 0) {
      svg.replaceChildren()
      return
    }

    const fragment = document.createDocumentFragment()
    const linkGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const particleGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const nodeGroup = document.createElementNS("http://www.w3.org/2000/svg", "g")
    const linksForNodes = this.mapView === "netflow" ? visualLinks.slice(0, 16) : visualLinks.slice(0, 10)

    linkGroup.setAttribute("class", "sr-ops-traffic-overlay-links")
    particleGroup.setAttribute("class", "sr-ops-traffic-overlay-particles")
    nodeGroup.setAttribute("class", "sr-ops-traffic-overlay-nodes")

    visualLinks.forEach((link, idx) => {
      const pathData = svgPathForLink(link, idx)
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")

      path.setAttribute("d", pathData)
      path.setAttribute("class", "sr-ops-traffic-path")
      path.setAttribute("stroke", rgbaCss(link.color, this.mapView === "netflow" && link.geoMapped === false ? 0.58 : 1))
      path.setAttribute("stroke-width", strokeWidthFor(link))
      path.style.setProperty("--traffic-delay", `${(idx % 7) * -0.38}s`)
      linkGroup.appendChild(path)

      if (idx < 16) {
        const particle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
        const motion = document.createElementNS("http://www.w3.org/2000/svg", "animateMotion")

        particle.setAttribute("r", String(Math.min(2.4, Math.max(1.2, strokeWidthFor(link) * 0.42))))
        particle.setAttribute("fill", rgbaCss(link.color, 1.2))
        particle.setAttribute("class", "sr-ops-traffic-particle")
        motion.setAttribute("dur", `${Math.max(2.4, 5.8 - Math.min(2.6, Math.log10(Math.max(10, link.magnitude || 10)) * 0.24))}s`)
        motion.setAttribute("begin", `${(idx % 6) * 0.22}s`)
        motion.setAttribute("repeatCount", "indefinite")
        motion.setAttribute("path", pathData)
        particle.appendChild(motion)
        particleGroup.appendChild(particle)
      }
    })

    overlayLinks.forEach((link, idx) => {
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")

      path.setAttribute("d", svgPathForLink(link, idx))
      path.setAttribute("class", "sr-ops-mtr-overlay-path")
      linkGroup.appendChild(path)
    })

    linksForNodes.forEach((link) => {
      for (const point of [link.from, link.to]) {
        const node = document.createElementNS("http://www.w3.org/2000/svg", "circle")

        node.setAttribute("cx", point[0])
        node.setAttribute("cy", point[1])
        node.setAttribute("r", this.mapView === "netflow" ? "1.7" : "1.35")
        node.setAttribute("fill", rgbaCss(link.color, 1.25))
        node.setAttribute("class", "sr-ops-traffic-node")
        nodeGroup.appendChild(node)
      }
    })

    fragment.appendChild(linkGroup)
    fragment.appendChild(particleGroup)
    fragment.appendChild(nodeGroup)
    svg.replaceChildren(fragment)
  },

  _syncData() {
    this.mapView = MAP_VIEWS.has(this.el.dataset.mapView) ? this.el.dataset.mapView : "topology_traffic"
    this.topologyLinks = this.mapView === "topology_traffic" ? normalizeLinks(parseJson(this.el.dataset.topologyLinks, [])) : []
    this.links = normalizeTrafficLinks(parseJson(this.el.dataset.links, []), this.mapView)
    this.overlays = this.mapView === "topology_traffic" ? normalizeLinks(parseJson(this.el.dataset.mtrOverlays, [])) : []
    this.deck?.setProps({layers: this._layers()})
    this._renderSvgOverlay()
  },

  _tick() {
    this.time += 0.016
    if (this.deck && (this.links.length > 0 || this.topologyLinks.length > 0 || this.overlays.length > 0)) {
      this.deck.setProps({layers: this._layers()})
    }
    this.frame = requestAnimationFrame(this._tick)
  },

  _layers() {
    const nodes = this.mapView === "netflow" ? endpointNodes(this.links) : []
    const labeledNodes =
      this.mapView === "netflow"
        ? nodes
            .filter((node) => node.sourceLabel)
            .sort((a, b) => b.magnitude - a.magnitude)
            .slice(0, 18)
        : []
    const label =
      this.mapView === "netflow"
        ? this.links.length > 0
          ? `${this.links.length} flow paths`
          : "No NetFlow paths"
        : `${this.topologyLinks.length} topology links / ${this.links.length} flow paths`

    return [
      new PolygonLayer({
        id: "ops-map-background",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: [{polygon: [[-180, -90], [180, -90], [180, 90], [-180, 90]]}],
        getPolygon: (d) => d.polygon,
        getFillColor: [2, 8, 23, 255],
        stroked: false,
        filled: true,
        pickable: false,
      }),
      new LineLayer({
        id: "ops-map-grid",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: BASE_GRID_LINES,
        getSourcePosition: (d) => d.from,
        getTargetPosition: (d) => d.to,
        getColor: [30, 58, 95, 42],
        getWidth: 1,
      }),
      new LineLayer({
        id: "ops-topology-links",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: this.topologyLinks,
        getSourcePosition: (d) => d.from,
        getTargetPosition: (d) => d.to,
        getColor: (d) => scaledColor(d.color, d.magnitude > 0 ? 1.3 : 0.9),
        getWidth: (d) => 1.45 + Math.min(5, Math.log10(Math.max(10, d.magnitude || 10)) / 1.15),
        widthUnits: "pixels",
        pickable: false,
      }),
      new ArcLayer({
        id: "ops-flow-arcs",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: this.links,
        getSourcePosition: (d) => d.from,
        getTargetPosition: (d) => d.to,
        getSourceColor: (d) => scaledColor(d.color, d.geoMapped === false ? 0.7 : 1.12),
        getTargetColor: (d) => scaledColor(d.color, d.geoMapped === false ? 0.7 : 1.12),
        getWidth: (d) => 1.2 + Math.min(5.5, Math.log10(Math.max(10, d.magnitude)) / 1.08),
        greatCircle: false,
        pickable: false,
      }),
      new LineLayer({
        id: "ops-mtr-overlays",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: this.overlays,
        getSourcePosition: (d) => d.from,
        getTargetPosition: (d) => d.to,
        getColor: [251, 191, 36, 180],
        getWidth: 2,
        pickable: false,
      }),
      new ScatterplotLayer({
        id: "ops-map-nodes",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: nodes,
        getPosition: (d) => d.position,
        getRadius: (d) => 4 + Math.min(8, Math.log10(Math.max(10, d.magnitude || 10)) * 0.55),
        radiusUnits: "pixels",
        stroked: true,
        filled: true,
        getFillColor: [15, 23, 42, 225],
        getLineColor: (d) => d.color,
        lineWidthMinPixels: 2,
        pickable: false,
      }),
      new TextLayer({
        id: "ops-map-node-labels",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: labeledNodes,
        getPosition: (d) => [d.position[0] + 2.5, d.position[1] - 2.5, 0],
        getText: (d) => d.sourceLabel,
        getColor: [203, 213, 225, 230],
        getSize: 10,
        sizeUnits: "pixels",
        getTextAnchor: "start",
        getAlignmentBaseline: "center",
        background: true,
        getBackgroundColor: [2, 8, 23, 170],
        backgroundPadding: [3, 2],
        pickable: false,
      }),
      new TextLayer({
        id: "ops-map-label",
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        data: [{position: [-168, 54, 0], label}],
        getPosition: (d) => d.position,
        getText: (d) => d.label,
        getColor: [148, 163, 184, 210],
        getSize: 12,
        sizeUnits: "pixels",
      }),
    ]
  },
}
