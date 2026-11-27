import {projectWorld} from "../lib/world.js"

// Lazy-loads the Natural Earth topology from data-topology-url (same origin)
// and draws land, region, arc and point layers. Updates arrive as patched
// data-* JSON or as the `sr:update:<id>` event. No tile server is contacted.
const topologies = new Map()

export const SrWorldMap = {
  mounted() {
    this.el.__srWorldMapPush = (event, id) => this.pushEvent(event, {id})
    this.handleEvent(`sr:update:${this.el.id}`, (payload) => {
      this.render(payload || {})
    })
    this.render({})
  },

  updated() {
    this.el.__srWorldMapPush = (event, id) => this.pushEvent(event, {id})
    this.render({})
  },

  render(payload) {
    const seq = (this._seq = (this._seq || 0) + 1)
    const url = this.el.dataset.topologyUrl
    if (!url) {
      setStatus(this.el, "Map data unavailable")
      return
    }

    loadTopology(url).then(
      (topology) => {
        if (seq !== this._seq) return
        paint(this.el, projectWorld(topology, viewOf(this.el, payload)))
        setStatus(this.el, null)
      },
      () => {
        if (seq !== this._seq) return
        setStatus(this.el, "Map data unavailable")
      },
    )
  },
}

function loadTopology(url) {
  if (!topologies.has(url)) {
    topologies.set(
      url,
      fetch(url).then((response) => {
        if (!response.ok) throw new Error(`topology HTTP ${response.status}`)
        return response.json()
      }),
    )
  }
  return topologies.get(url)
}

function viewOf(el, payload) {
  const svg = el.querySelector("svg")
  const box = (svg?.getAttribute("viewBox") || "0 0 960 500").trim().split(/\s+/)
  return {
    projection: payload.projection || el.dataset.projection || "natural-earth",
    width: Number(box[2]) || 960,
    height: Number(box[3]) || 500,
    points: pick(payload, "points", el.dataset.points),
    regions: pick(payload, "regions", el.dataset.regions),
    arcs: pick(payload, "arcs", el.dataset.arcs),
  }
}

function pick(payload, key, raw) {
  if (Object.prototype.hasOwnProperty.call(payload, key)) return payload[key] || []
  return parseJson(raw)
}

function parseJson(raw) {
  try {
    const parsed = JSON.parse(raw || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (_error) {
    return []
  }
}

function paint(el, model) {
  const sphere = el.querySelector('[data-sr-layer="sphere"]')
  if (sphere && model.sphere) sphere.setAttribute("d", model.sphere)

  fill(
    el,
    "land",
    model.land.map((shape) => path(shape.d, "sr-map-land-shape")),
  )
  fill(
    el,
    "regions",
    model.regions.map((shape) =>
      clickable(el, path(shape.d, `sr-map-region sr-tone-${shape.tone} sr-map-level-${shape.level}`), shape, "regionEvent"),
    ),
  )
  fill(
    el,
    "arcs",
    model.arcs.map((shape) =>
      clickable(el, path(shape.d, `sr-map-arc sr-tone-${shape.tone} sr-map-weight-${shape.weight}`), shape, "arcEvent"),
    ),
  )
  fill(
    el,
    "points",
    model.points.map((shape) =>
      clickable(
        el,
        svgEl("circle", {
          class: `sr-map-point sr-tone-${shape.tone}`,
          cx: shape.x,
          cy: shape.y,
          r: shape.r,
        }),
        shape,
        "pointEvent",
      ),
    ),
  )
}

function fill(el, layer, nodes) {
  const group = el.querySelector(`[data-sr-layer="${layer}"]`)
  if (group) group.replaceChildren(...nodes)
}

function path(d, className) {
  return svgEl("path", {d, class: className})
}

function clickable(el, node, shape, eventKey) {
  if (shape.label) {
    const title = svgEl("title")
    title.textContent = shape.label
    node.append(title)
  }
  const event = el.dataset[eventKey]
  if (!event) return node

  node.classList.add("sr-map-interactive")
  node.setAttribute("tabindex", "0")
  node.setAttribute("role", "button")
  if (shape.label) node.setAttribute("aria-label", shape.label)
  const push = () => el.__srWorldMapPush?.(event, shape.id)
  node.addEventListener("click", (domEvent) => {
    domEvent.stopPropagation()
    push()
  })
  node.addEventListener("keydown", (domEvent) => {
    if (domEvent.key !== "Enter" && domEvent.key !== " ") return
    domEvent.preventDefault()
    push()
  })
  return node
}

function svgEl(name, attrs = {}) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", name)
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value))
  return node
}

function setStatus(el, message) {
  const status = el.querySelector("[data-sr-status]")
  if (!status) return
  status.hidden = !message
  if (message) status.textContent = message
}
