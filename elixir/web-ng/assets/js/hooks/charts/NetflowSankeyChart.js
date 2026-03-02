import * as d3 from "d3"
import {sankey as d3Sankey, sankeyLinkHorizontal as d3SankeyLinkHorizontal} from "d3-sankey"

import {ensureTooltip as nfEnsureTooltip} from "../../netflow_charts/util"

export default {
  mounted() {
    this._render = () => this._draw()
    this._resizeObserver = new ResizeObserver(() => this._render())
    this._resizeObserver.observe(this.el)
    this._hiddenGroups = this._hiddenGroups || new Set()
    this._render()
  },
  updated() {
    this._render()
  },
  destroyed() {
    try {
      this._resizeObserver?.disconnect()
    } catch (_e) {}
    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
  },
  _draw() {
    const hook = this
    const el = this.el
    const svg = el.querySelector("svg")
    if (!svg) return

    const renderMessage = (msg, detail) => {
      // Clear existing SVG children.
      while (svg.firstChild) svg.removeChild(svg.firstChild)

      const width = Math.max(300, el.clientWidth || 0)
      const height = Math.max(220, el.clientHeight || 0)
      svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

      const g = document.createElementNS("http://www.w3.org/2000/svg", "g")
      const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
      text.setAttribute("x", "16")
      text.setAttribute("y", "24")
      text.setAttribute("fill", "currentColor")
      text.setAttribute("font-size", "12")
      text.textContent = msg || "No Sankey edges in this window."
      g.appendChild(text)

      if (detail) {
        const t2 = document.createElementNS("http://www.w3.org/2000/svg", "text")
        t2.setAttribute("x", "16")
        t2.setAttribute("y", "44")
        t2.setAttribute("fill", "currentColor")
        t2.setAttribute("font-size", "11")
        t2.setAttribute("opacity", "0.7")
        t2.textContent = detail
        g.appendChild(t2)
      }

      svg.appendChild(g)
    }

    const groupLabel = {
      src: el.dataset.srcLabel || "Source",
      mid: el.dataset.midLabel || "Middle",
      dst: el.dataset.dstLabel || "Destination",
    }

    const tooltip = nfEnsureTooltip(el)
    tooltip.classList.add("hidden")

    const showTooltip = (evt, html) => {
      if (!html) return
      const rect = el.getBoundingClientRect()
      const x = evt.clientX - rect.left
      const y = evt.clientY - rect.top

      tooltip.innerHTML = html
      tooltip.classList.remove("hidden")

      const pad = 8
      const ttRect = tooltip.getBoundingClientRect()
      const maxLeft = rect.width - (ttRect.width || 180) - pad
      const left = Math.max(pad, Math.min(maxLeft, x + 12))
      const top = Math.max(pad, Math.min(rect.height - 48, y - 12))
      tooltip.style.left = `${left}px`
      tooltip.style.top = `${top}px`
    }

    const hideTooltip = () => {
      tooltip.classList.add("hidden")
    }

    let edges = []
    try {
      edges = JSON.parse(el.dataset.edges || "[]")
    } catch (_e) {
      edges = []
    }

    const width = Math.max(300, el.clientWidth || 0)
    const height = Math.max(220, el.clientHeight || 0)

    try {
      svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

      // Clear
      while (svg.firstChild) svg.removeChild(svg.firstChild)

      if (!Array.isArray(edges) || edges.length === 0) {
        renderMessage("No Sankey edges in this window.", "Try widening the time range or switching dimensions.")
        return
      }

      const formatBytes = (value) => {
        const abs = Math.abs(value || 0)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MB`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KB`
        return `${(value || 0).toFixed(0)} B`
      }

      const nodeIds = new Map()
      const nodes = []
      const nodeKey = (group, label) => `${String(group || "")}:${String(label || "")}`
      const addNode = (id, group) => {
        if (!id) return
        const key = nodeKey(group, id)
        if (nodeIds.has(key)) return
        nodeIds.set(key, true)
        // Keep a stable, namespaced id for layout, but preserve the original label for display.
        nodes.push({id: key, label: id, group})
      }

      const links = []
      for (const e of edges) {
        const src = e?.src
        const mid = e?.mid
        const dst = e?.dst
        const bytes = Number(e?.bytes || 0)
        const port = e?.port
        if (!src || !mid || !dst || !Number.isFinite(bytes) || bytes <= 0) continue

        addNode(src, "src")
        addNode(mid, "mid")
        addNode(dst, "dst")

        // Model as 2-hop links so d3-sankey lays out 3 columns.
        const mid_field = e?.mid_field ?? ""
        const mid_value = e?.mid_value ?? ""
        links.push({
          source: nodeKey("src", src),
          target: nodeKey("mid", mid),
          value: bytes,
          edge: {src, dst, port, mid_field, mid_value},
        })
        links.push({
          source: nodeKey("mid", mid),
          target: nodeKey("dst", dst),
          value: bytes,
          edge: {src, dst, port, mid_field, mid_value},
        })
      }

      const buildSankey = (nodeList, linkList) => {
        const sankey = d3Sankey()
          .nodeId((d) => d.id)
          .nodeWidth(12)
          .nodePadding(10)
          .extent([
            [12, 10],
            [width - 12, height - 10],
          ])

        return sankey({
          nodes: nodeList.map((d) => ({...d})),
          links: linkList.map((d) => ({...d})),
        })
      }

      // d3-sankey requires a DAG. In practice we only emit src->mid->dst edges, but if upstream
      // data ever produces a cycle (or the browser is running a stale bundle), degrade gracefully
      // to a 2-column sankey (src->dst aggregated across the middle).
      let graph
      let degraded = false
      try {
        graph = buildSankey(nodes, links)
      } catch (e) {
        const msg = String(e?.message || e || "")
        if (!msg.toLowerCase().includes("circular link")) throw e
        degraded = true

        // Aggregate to src->dst only.
        const nodeIds2 = new Map()
        const nodes2 = []
        const add2 = (id, group) => {
          if (!id) return
          const key = nodeKey(group, id)
          if (nodeIds2.has(key)) return
          nodeIds2.set(key, true)
          nodes2.push({id: key, label: id, group})
        }

        const byPair = new Map()
        for (const e2 of edges) {
          const src2 = e2?.src
          const dst2 = e2?.dst
          const bytes2 = Number(e2?.bytes || 0)
          if (!src2 || !dst2 || !Number.isFinite(bytes2) || bytes2 <= 0) continue
          add2(src2, "src")
          add2(dst2, "dst")
          const key = `${nodeKey("src", src2)}|${nodeKey("dst", dst2)}`
          const cur = byPair.get(key) || 0
          byPair.set(key, cur + bytes2)
        }

        const links2 = []
        for (const [key, value] of byPair.entries()) {
          const [s, t] = key.split("|")
          if (!s || !t) continue
          links2.push({source: s, target: t, value})
        }

        graph = buildSankey(nodes2, links2)
      }

      const g = d3.select(svg).append("g")
      if (degraded) {
        g.append("text")
          .attr("x", width - 12)
          .attr("y", height - 10)
          .attr("text-anchor", "end")
          .attr("font-size", 10)
          .attr("opacity", 0.6)
          .attr("fill", "currentColor")
          .text("Simplified (cycle detected)")
      }

      const color = d3.scaleOrdinal().domain(["src", "mid", "dst"]).range(["#00D8FF", "#A855F7", "#00E676"])

      const groupHidden = (grp) => hook._hiddenGroups?.has(grp)

      // Links
      g.append("g")
        .attr("fill", "none")
        .selectAll("path")
        .data(graph.links)
        .join("path")
        .attr("d", d3SankeyLinkHorizontal())
        .attr("stroke", (d) => {
          const grp = d?.source?.group || "src"
          return color(grp)
        })
        .attr("stroke-opacity", (d) => {
          const grp = d?.source?.group || "src"
          return groupHidden(grp) ? 0.03 : 0.25
        })
        .attr("stroke-width", (d) => Math.max(1, d.width || 1))
        .style("cursor", "pointer")
        .on("mousemove", (evt, d) => {
          const edge = d?.edge
          const s = edge?.src || d?.source?.id || ""
          const t = edge?.dst || d?.target?.id || ""
          const port = edge?.port ?? ""
          const mf = String(edge?.mid_field || "")
          const mv = String(edge?.mid_value || "")

          const midLabel = (() => {
            if (mf === "dst_port" || mf === "dst_endpoint_port") return `${groupLabel.mid}: ${String(port || mv || "-")}`
            if (mf === "app") return `${groupLabel.mid}: ${mv || "-"}`
            if (mf === "protocol_group") return `${groupLabel.mid}: ${mv || "-"}`
            return `${groupLabel.mid}: ${mv || port || "-"}`
          })()
          const html = `
	            <div class="text-[11px]"><span class="opacity-70">${groupLabel.src}:</span> <span class="font-mono">${String(s)}</span></div>
	            <div class="mt-0.5 text-[11px] opacity-70">${midLabel}</div>
	            <div class="mt-0.5 text-[11px]"><span class="opacity-70">${groupLabel.dst}:</span> <span class="font-mono">${String(t)}</span></div>
	            <div class="mt-0.5 text-[11px] font-mono">${formatBytes(d?.value || 0)}</div>
	          `
          showTooltip(evt, html)
        })
        .on("mouseleave", hideTooltip)
        .on("click", (_evt, d) => {
          const edge = d?.edge
          if (!edge) return
          this.pushEvent("netflow_sankey_edge", {
            src: edge.src,
            dst: edge.dst,
            port: edge.port ?? "",
            mid_field: edge.mid_field ?? "",
            mid_value: edge.mid_value ?? "",
          })
        })
        .append("title")
        .text((d) => {
          const s = d?.source?.label || d?.source?.id || ""
          const t = d?.target?.label || d?.target?.id || ""
          return `${s} -> ${t}\n${formatBytes(d.value)}`
        })

      // Nodes
      const node = g
        .append("g")
        .selectAll("g")
        .data(graph.nodes)
        .join("g")
        .attr("opacity", (d) => (groupHidden(d.group || "src") ? 0.15 : 1))
        .style("pointer-events", (d) => (groupHidden(d.group || "src") ? "none" : "all"))

      node
        .append("rect")
        .attr("x", (d) => d.x0)
        .attr("y", (d) => d.y0)
        .attr("height", (d) => Math.max(1, d.y1 - d.y0))
        .attr("width", (d) => Math.max(1, d.x1 - d.x0))
        .attr("rx", 3)
        .attr("fill", (d) => color(d.group || "src"))
        .attr("fill-opacity", 0.65)

      node
        .append("title")
        .text((d) => d.label || d.id)

      // Labels (trim aggressively to avoid overlap)
      node
        .append("text")
        .attr("x", (d) => (d.x0 < width / 2 ? d.x1 + 6 : d.x0 - 6))
        .attr("y", (d) => (d.y0 + d.y1) / 2)
        .attr("dy", "0.35em")
        .attr("text-anchor", (d) => (d.x0 < width / 2 ? "start" : "end"))
        .attr("font-size", 10)
        .attr("fill", "currentColor")
        .attr("opacity", 0.75)
        .text((d) => {
          const s = String(d.label || d.id || "")
          return s.length > 24 ? `${s.slice(0, 21)}...` : s
        })
        .on("mousemove", (evt, d) => {
          const grp = d?.group || "src"
          const html = `
	            <div class="text-[11px] font-mono">${String(d?.label || d?.id || "")}</div>
	            <div class="mt-0.5 text-[11px] opacity-70">${String(groupLabel[grp] || grp)}</div>
	          `
          showTooltip(evt, html)
        })
        .on("mouseleave", hideTooltip)

      // Column headers (what each column represents).
      try {
        const centers = {}
        for (const n of graph.nodes || []) {
          const grp = n?.group || "src"
          const cx = (Number(n.x0) + Number(n.x1)) / 2
          if (!Number.isFinite(cx)) continue
          if (!centers[grp]) centers[grp] = []
          centers[grp].push(cx)
        }

        const headerY = 10
        for (const grp of ["src", "mid", "dst"]) {
          const xs = centers[grp] || []
          if (xs.length === 0) continue
          const x = xs.reduce((a, b) => a + b, 0) / xs.length
          g.append("text")
            .attr("x", x)
            .attr("y", headerY)
            .attr("text-anchor", "middle")
            .attr("font-size", 10)
            .attr("opacity", 0.7)
            .attr("fill", "currentColor")
            .text(String(groupLabel[grp] || grp))
        }
      } catch (_e) {}
    } catch (e) {
      renderMessage("Sankey failed to render.", String(e?.message || e || "unknown error"))
      return
    }
  },
}
