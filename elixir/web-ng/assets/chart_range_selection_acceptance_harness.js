import NetflowStackedAreaChart from "./js/hooks/charts/NetflowStackedAreaChart"
import NetflowTrafficTooltip from "./js/hooks/charts/NetflowTrafficTooltip"

const INTERVALS = [
  {start: "2026-08-29T01:00:00.000000Z", end: "2026-08-29T01:00:59.999999Z"},
  {start: "2026-08-29T01:01:00.000000Z", end: "2026-08-29T01:01:59.999999Z"},
]

let state = null

if (typeof window.ResizeObserver !== "function") {
  window.ResizeObserver = class ResizeObserverFallback {
    constructor(callback) {
      this.callback = callback
    }

    observe() {}
    disconnect() {}
  }
}

function label(node) {
  if (!node || node.nodeType !== Node.ELEMENT_NODE) return String(node?.nodeName || "unknown")
  return node.dataset.traceLabel || node.tagName.toLowerCase()
}

function rootFixture(renderer) {
  const root = document.createElement("div")
  root.setAttribute("role", "group")
  root.dataset.traceLabel = "chart-root"
  root.dataset.rangeBuckets = JSON.stringify([
    {x: 250, ...INTERVALS[0]},
    {x: 750, ...INTERVALS[1]},
  ])
  root.dataset.rangeIntervals = JSON.stringify(INTERVALS)
  root.dataset.rangeEvent = "netflow_range_selected"
  root.dataset.points = JSON.stringify([
    {t: INTERVALS[0].start, bytes: 128, traffic: 128},
    {t: INTERVALS[1].start, bytes: 256, traffic: 256},
  ])
  root.dataset.keys = JSON.stringify(["traffic"])
  root.dataset.colors = JSON.stringify({traffic: "#22c55e"})
  if (renderer === "d3") root.dataset.seriesField = "app"
  root.dataset.units = "Bps"
  root.dataset.chartWidth = "1000"
  root.dataset.chartHeight = "160"
  root.style.cssText = "position:relative;width:760px;height:260px;margin:24px;background:#111827;color:#d1fae5;"
  return root
}

function svgElement(name) {
  return document.createElementNS("http://www.w3.org/2000/svg", name)
}

function serverSvgFixture() {
  const svg = svgElement("svg")
  svg.dataset.rangeSvg = ""
  svg.dataset.traceLabel = "server-svg"
  svg.setAttribute("viewBox", "0 0 1000 160")
  svg.setAttribute("preserveAspectRatio", "none")
  svg.style.cssText = "display:block;width:100%;height:160px"

  const surface = svgElement("rect")
  surface.dataset.rangeSurface = ""
  surface.dataset.traceLabel = "server-surface"
  surface.setAttribute("x", "0")
  surface.setAttribute("y", "10")
  surface.setAttribute("width", "1000")
  surface.setAttribute("height", "140")
  surface.setAttribute("fill", "transparent")
  surface.setAttribute("pointer-events", "all")

  const overlay = svgElement("rect")
  overlay.dataset.rangeOverlay = ""
  overlay.setAttribute("y", "10")
  overlay.setAttribute("height", "140")
  overlay.setAttribute("pointer-events", "none")
  overlay.classList.add("hidden")

  svg.append(surface, overlay)

  const bucket = svgElement("circle")
  bucket.dataset.traceLabel = "server-bucket"
  bucket.setAttribute("cx", "250")
  bucket.setAttribute("cy", "80")
  bucket.setAttribute("r", "12")
  bucket.setAttribute("fill", "#22c55e")
  bucket.setAttribute("phx-click", "netflow_bucket")
  bucket.setAttribute("phx-value-start", INTERVALS[0].start)
  bucket.setAttribute("phx-value-end", INTERVALS[0].end)
  svg.append(bucket)
  return svg
}

function d3SvgFixture() {
  const svg = svgElement("svg")
  svg.dataset.traceLabel = "d3-svg"
  svg.style.cssText = "display:block;width:100%;height:100%"
  return svg
}

function installTrace(root, trace) {
  const pointer = (event) => {
    trace.push({
      kind: "pointer",
      type: event.type,
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      target: label(event.target),
      currentTarget: label(event.currentTarget),
      rootHasCapture: root.hasPointerCapture?.(event.pointerId) || false,
    })
  }

  for (const type of ["pointerdown", "pointermove", "pointerup", "pointercancel"]) {
    root.addEventListener(type, pointer, true)
    root.addEventListener(type, pointer)
  }
  root.addEventListener("click", (event) => {
    trace.push({kind: "click", target: label(event.target), currentTarget: label(event.currentTarget)})
  })
  document.addEventListener("click", (event) => {
    const action = event.target?.closest?.("[phx-click]")
    if (!action || !root.contains(action)) return

    trace.push({
      kind: "server-bucket-click",
      event: action.getAttribute("phx-click"),
      start: action.getAttribute("phx-value-start"),
      end: action.getAttribute("phx-value-end"),
      target: label(event.target),
      currentTarget: label(event.currentTarget),
    })
  })
}

function currentSvg() {
  return state?.root?.querySelector("svg") || null
}

function replaceRendererNodes() {
  if (!state) throw new Error("mount a renderer before replacing nodes")
  const before = currentSvg()
  const replacement = state.renderer === "server-svg" ? serverSvgFixture() : d3SvgFixture()
  before?.replaceWith(replacement)
  state.trace.push({
    kind: "renderer-replacement",
    renderer: state.renderer,
    before: label(before),
    after: label(replacement),
  })
  return snapshot()
}

function snapshot() {
  if (!state) return null
  return {
    renderer: state.renderer,
    svg: label(currentSvg()),
    trace: state.trace,
  }
}

window.chartRangeAcceptance = Object.freeze({
  mount(renderer) {
    if (state?.hook?.destroyed) state.hook.destroyed()
    const root = rootFixture(renderer)
    root.append(renderer === "server-svg" ? serverSvgFixture() : d3SvgFixture())
    const status = document.createElement("p")
    status.dataset.rangeStatus = ""
    root.append(status)

    const trace = []
    installTrace(root, trace)
    const hookDefinition = renderer === "server-svg" ? NetflowTrafficTooltip : NetflowStackedAreaChart
    const hook = Object.assign(Object.create(hookDefinition), {
      el: root,
      pushEvent(name, payload) {
        trace.push({kind: "push", name, payload})
      },
    })
    document.body.replaceChildren(root)
    hook.mounted()
    state = {hook, renderer, root, trace}
    trace.push({kind: "mounted", renderer, svg: label(currentSvg())})
    return snapshot()
  },
  replaceRendererNodes,
  updateHook() {
    if (!state) throw new Error("mount a renderer before updating the hook")
    state.hook.updated()
    state.trace.push({kind: "hook-updated", renderer: state.renderer, svg: label(currentSvg())})
    return snapshot()
  },
  snapshot,
})
