import * as d3 from "d3"

import {ensureTooltip as nfEnsureTooltip, escapeHtml} from "../../netflow_charts/util"

function formatBytes(value) {
  const n = Number(value || 0)
  if (!Number.isFinite(n)) return "0 B"
  if (n >= 1e12) return `${(n / 1e12).toFixed(2)} TB`
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)} GB`
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)} MB`
  if (n >= 1e3) return `${(n / 1e3).toFixed(2)} KB`
  return `${Math.round(n)} B`
}

function parseEdges(raw) {
  try {
    const parsed = JSON.parse(raw || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (_e) {
    return []
  }
}

function buildHierarchy(edges) {
  const srcMap = new Map()

  for (const edge of edges) {
    const src = String(edge?.src || "").trim()
    const dst = String(edge?.dst || "").trim()
    const bytes = Number(edge?.bytes || 0)
    const portRaw = edge?.port
    const portNum = Number.isFinite(Number(portRaw)) ? Number(portRaw) : null

    if (!src || !dst || !Number.isFinite(bytes) || bytes <= 0 || !Number.isInteger(portNum) || portNum <= 0) {
      continue
    }

    let srcNode = srcMap.get(src)
    if (!srcNode) {
      srcNode = {name: src, id: `src:${src}`, kind: "src", filterValue: src, children: new Map()}
      srcMap.set(src, srcNode)
    }

    let dstNode = srcNode.children.get(dst)
    if (!dstNode) {
      dstNode = {
        name: dst,
        id: `src:${src}|dst:${dst}`,
        kind: "dst",
        filterValue: dst,
        children: new Map(),
      }
      srcNode.children.set(dst, dstNode)
    }

    const portKey = String(portNum)
    let portNode = dstNode.children.get(portKey)
    if (!portNode) {
      portNode = {
        name: portKey,
        id: `src:${src}|dst:${dst}|port:${portKey}`,
        kind: "port",
        filterValue: portKey,
        value: 0,
      }
      dstNode.children.set(portKey, portNode)
    }

    portNode.value += bytes
  }

  const normalizeDst = (node) => ({
    name: node.name,
    id: node.id,
    kind: node.kind,
    filterValue: node.filterValue,
    children: Array.from(node.children.values())
      .map((p) => ({
        name: p.name,
        id: p.id,
        kind: p.kind,
        filterValue: p.filterValue,
        value: p.value,
      }))
      .sort((a, b) => b.value - a.value),
  })

  const normalizeSrc = (node) => ({
    name: node.name,
    id: node.id,
    kind: node.kind,
    filterValue: node.filterValue,
    children: Array.from(node.children.values()).map(normalizeDst),
  })

  return {
    name: "flows",
    id: "root",
    kind: "root",
    children: Array.from(srcMap.values()).map(normalizeSrc),
  }
}

export default {
  mounted() {
    this._focusId = "root"
    this._render = () => this._draw()
    this._resizeObserver = new ResizeObserver(() => this._render())
    this._resizeObserver.observe(this.el)
    this._render()
  },
  updated() {
    this._render()
  },
  destroyed() {
    try {
      this._resizeObserver?.disconnect()
    } catch (_e) {}
  },
  _draw() {
    const el = this.el
    const svg = el.querySelector("svg")
    if (!svg) return

    const width = Math.max(420, el.clientWidth || 0)
    const height = Math.max(220, el.clientHeight || 0)

    while (svg.firstChild) svg.removeChild(svg.firstChild)
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

    const edges = parseEdges(el.dataset.edges)
    const tooltip = nfEnsureTooltip(el)
    tooltip.classList.add("hidden")

    if (!edges.length) {
      const g = d3.select(svg).append("g")
      g.append("text")
        .attr("x", 14)
        .attr("y", 22)
        .attr("fill", "currentColor")
        .attr("font-size", 12)
        .text("No talker hierarchy in this window.")
      return
    }

    const rootData = buildHierarchy(edges)
    const root = d3
      .hierarchy(rootData)
      .sum((d) => Number(d.value || 0))
      .sort((a, b) => (b.value || 0) - (a.value || 0))

    d3.partition().size([height, width])(root)

    let focus = root
    if (this._focusId && this._focusId !== "root") {
      const found = root.descendants().find((d) => d.data?.id === this._focusId)
      if (found) focus = found
    }

    const x = d3.scaleLinear().domain([focus.x0, focus.x1]).range([0, height])
    const y = d3.scaleLinear().domain([focus.y0, width]).range([0, width])

    const nodes = root
      .descendants()
      .filter((d) => d.depth > 0 && d.x1 > focus.x0 && d.x0 < focus.x1 && d.y1 > focus.y0)

    const srcDomain = root.children ? root.children.map((d) => d.data.name) : []
    const srcColor = d3.scaleOrdinal(srcDomain, d3.schemeTableau10)

    const colorFor = (d) => {
      const srcAncestor = d.ancestors().find((a) => a.depth === 1)
      const base = srcAncestor ? d3.color(srcColor(srcAncestor.data.name)) : d3.color("#4e79a7")
      if (!base) return "#4e79a7"
      if (d.depth === 1) return base.formatHex()
      if (d.depth === 2) return base.copy({opacity: 0.75}).formatRgb()
      return base.copy({opacity: 0.58}).formatRgb()
    }

    const g = d3.select(svg).append("g")

    const showTooltip = (event, d) => {
      const rect = el.getBoundingClientRect()
      const mx = event.clientX - rect.left
      const my = event.clientY - rect.top
      const bytes = Number(d.value || 0)
      tooltip.innerHTML = `<div class="font-mono">${escapeHtml(d.data?.name || "unknown")}</div>
        <div class="text-[10px] text-base-content/70">${escapeHtml(d.data?.kind || "")}</div>
        <div class="mt-1 font-mono">${escapeHtml(formatBytes(bytes))}</div>`
      tooltip.classList.remove("hidden")
      const tRect = tooltip.getBoundingClientRect()
      const left = Math.max(8, Math.min(rect.width - tRect.width - 8, mx + 10))
      const top = Math.max(8, Math.min(rect.height - tRect.height - 8, my + 10))
      tooltip.style.left = `${left}px`
      tooltip.style.top = `${top}px`
    }

    const hideTooltip = () => {
      tooltip.classList.add("hidden")
    }

    g.selectAll("rect")
      .data(nodes)
      .join("rect")
      .attr("x", (d) => y(d.y0))
      .attr("y", (d) => x(d.x0))
      .attr("width", (d) => Math.max(0, y(d.y1) - y(d.y0) - 1))
      .attr("height", (d) => Math.max(0, x(d.x1) - x(d.x0) - 1))
      .attr("fill", (d) => colorFor(d))
      .attr("stroke", "rgba(255,255,255,0.18)")
      .style("cursor", "pointer")
      .on("mousemove", (event, d) => showTooltip(event, d))
      .on("mouseleave", () => hideTooltip())
      .on("click", (_event, d) => {
        if (d.data?.kind && d.data?.filterValue) {
          this.pushEvent("netflow_icicle_node", {
            kind: d.data.kind,
            value: d.data.filterValue,
          })
        }

        if (this._focusId === d.data.id && d.parent) {
          this._focusId = d.parent.data.id
        } else {
          this._focusId = d.data.id
        }
        this._render()
      })

    g.selectAll("text")
      .data(nodes)
      .join("text")
      .attr("x", (d) => y(d.y0) + 4)
      .attr("y", (d) => x(d.x0) + 12)
      .attr("fill", "white")
      .attr("font-size", 10)
      .attr("opacity", (d) => {
        const w = y(d.y1) - y(d.y0)
        const h = x(d.x1) - x(d.x0)
        return w > 70 && h > 14 ? 0.92 : 0
      })
      .text((d) => {
        const label = String(d.data?.name || "")
        return label.length > 18 ? `${label.slice(0, 16)}…` : label
      })

    const crumb = focus
      .ancestors()
      .reverse()
      .slice(1)
      .map((d) => d.data?.name)
      .filter(Boolean)
      .join(" / ")

    if (crumb) {
      g.append("text")
        .attr("x", 8)
        .attr("y", 14)
        .attr("font-size", 10)
        .attr("opacity", 0.75)
        .attr("fill", "currentColor")
        .text(`zoom: ${crumb}`)
    }
  },
}

