import {depsRef, stateRef} from "./runtime_refs"
export const godViewRenderingSelectionMethods = {
  renderSelectionDetails(node) {
    if (!stateRef(this).details) return
    if (!node) {
      stateRef(this).details.classList.add("hidden")
      stateRef(this).details.textContent = "Select a node for details"
      return
    }

    const d = node.details || {}
    const nodeMap = this.nodeIndexLookup((stateRef(this).lastGraph?.nodes || []))
    const reason = this.escapeHtml(node.stateReason || this.defaultStateReason(node.state))
    const rootRef = this.nodeReferenceAction(
      d?.causal_root_index,
      "Root",
      nodeMap,
    )
    const parentRef = this.nodeReferenceAction(
      d?.causal_parent_index,
      "Parent",
      nodeMap,
    )
    const detailLines = [
      `<div class="font-semibold text-sm mb-1">${this.escapeHtml(node.label || "node")}</div>`,
      `<div>ID: ${this.escapeHtml(d.id || node.id || "unknown")}</div>`,
      `<div>IP: ${this.escapeHtml(d.ip || "unknown")}</div>`,
      `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
      `<div>State: ${this.escapeHtml(this.stateDisplayName(node.state))}</div>`,
      `<div>Why: ${reason}</div>`,
      rootRef,
      parentRef,
      `<div>Vendor/Model: ${this.escapeHtml(`${d.vendor || "—"} ${d.model || ""}`.trim())}</div>`,
      `<div>Last Seen: ${this.escapeHtml(d.last_seen || "unknown")}</div>`,
      `<div>ASN: ${this.escapeHtml(d.asn || "unknown")}</div>`,
      `<div>Geo: ${this.escapeHtml([d.geo_city, d.geo_country].filter(Boolean).join(", ") || "unknown")}</div>`,
    ].filter(Boolean)

    stateRef(this).details.innerHTML = detailLines.join("")
    stateRef(this).details.classList.remove("hidden")
  },
  escapeHtml(value) {
    const text = String(value == null ? "" : value)
    return text
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  },
  nodeReferenceAction(index, label, nodeMap) {
    const idx = Number(index)
    if (!Number.isFinite(idx) || idx < 0) return ""
    const ref = this.nodeRefByIndex(idx, nodeMap) || `node#${idx}`
    return `<div>${this.escapeHtml(label)}: <button type="button" class="link link-primary text-xs" data-node-index="${idx}">${this.escapeHtml(ref)}</button></div>`
  },
  focusNodeByIndex(index, switchToLocal = false) {
    const idx = Number(index)
    if (!Number.isFinite(idx) || idx < 0) return
    const node = stateRef(this).lastGraph?.nodes?.[idx]
    if (!node) return

    if (switchToLocal) {
      stateRef(this).zoomMode = "local"
      stateRef(this).zoomTier = "local"
    }

    stateRef(this).selectedNodeIndex = idx

    const x = Number(node.x)
    const y = Number(node.y)
    if (Number.isFinite(x) && Number.isFinite(y)) {
      stateRef(this).viewState = {...stateRef(this).viewState, target: [x, y, 0]}
      if (stateRef(this).deck) {
        stateRef(this).isProgrammaticViewUpdate = true
        stateRef(this).deck.setProps({viewState: stateRef(this).viewState})
        stateRef(this).isProgrammaticViewUpdate = false
      }
    }

    if (stateRef(this).lastGraph) this.renderGraph(stateRef(this).lastGraph)
  },
  handlePick(info) {
    const layerId = info?.layer?.id || ""
    if (this.edgeLayerId(layerId)) {
      const key = typeof info?.object?.interactionKey === "string" ? info.object.interactionKey : null
      if (!key) return
      stateRef(this).selectedEdgeKey = stateRef(this).selectedEdgeKey === key ? null : key
      if (stateRef(this).lastGraph) this.renderGraph(stateRef(this).lastGraph)
      return
    }

    const tier = stateRef(this).zoomMode === "auto" ? stateRef(this).zoomTier : stateRef(this).zoomMode
    if (tier === "local") {
      const picked = info?.object?.index
      if (Number.isInteger(picked)) {
        stateRef(this).selectedNodeIndex = stateRef(this).selectedNodeIndex === picked ? null : picked
        if (stateRef(this).lastGraph) this.renderGraph(stateRef(this).lastGraph)
        return
      }
    }

    if (info && info.picked === false) {
      let changed = false
      if (stateRef(this).selectedNodeIndex !== null) {
        stateRef(this).selectedNodeIndex = null
        changed = true
      }
      if (stateRef(this).selectedEdgeKey !== null) {
        stateRef(this).selectedEdgeKey = null
        changed = true
      }
      if (changed && stateRef(this).lastGraph) this.renderGraph(stateRef(this).lastGraph)
    }
  },
  selectEdgeLabels(edgeData, shape) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []
    if (shape !== "local" && shape !== "regional") return []

    const selected = stateRef(this).selectedEdgeKey
    const hovered = stateRef(this).hoveredEdgeKey
    if (!selected && !hovered) return []

    const picked = []
    const seen = new Set()
    for (let i = 0; i < edgeData.length; i += 1) {
      const edge = edgeData[i]
      if (edge.interactionKey !== selected && edge.interactionKey !== hovered) continue
      if (seen.has(edge.interactionKey)) continue
      seen.add(edge.interactionKey)
      picked.push(edge)
    }
    return picked
  },
}
