import {depsRef, stateRef} from "./runtime_refs"
export const godViewRenderingStyleNodeReasonMethods = {
  stateCategory(state) {
    if (state === 0) return "root_cause"
    if (state === 1) return "affected"
    if (state === 2) return "healthy"
    return "unknown"
  },
  stateDisplayName(state) {
    if (state === 0) return "Root Cause"
    if (state === 1) return "Affected"
    if (state === 2) return "Healthy"
    return "Unknown"
  },
  defaultStateReason(state) {
    if (state === 0) return "Primary failure detected by causal model."
    if (state === 1) return "Impacted by an upstream dependency."
    if (state === 2) return "No active causal impact detected."
    return "Insufficient telemetry to classify root or affected."
  },
  stateReasonForNode(node, edgeData, allNodes = []) {
    const state = Number(node?.state)
    if (!Number.isFinite(state)) return this.defaultStateReason(3)
    const details = node?.details || {}
    const nodeIndexMap = this.nodeIndexLookup(allNodes)

    const causalReason = String(details?.causal_reason || "").trim()
    if (causalReason) {
      return this.humanizeCausalReason(causalReason, details, nodeIndexMap)
    }

    if (state === 0) {
      if (Number(node?.operUp) === 2) return "Device is operationally down and identified as a root cause."
      return "Marked as the most upstream causal source in current dependencies."
    }

    if (state === 2) {
      return "Healthy signal with no active upstream dependency impact."
    }

    if (state === 3) {
      return this.defaultStateReason(state)
    }

    const id = node?.id
    if (!id || !Array.isArray(edgeData) || edgeData.length === 0) return this.defaultStateReason(state)

    const neighbors = []
    const seen = new Set()

    for (const edge of edgeData) {
      if (!edge) continue
      let peerId = null

      if (edge.sourceId === id) peerId = edge.targetId
      else if (edge.targetId === id) peerId = edge.sourceId

      if (!peerId || seen.has(peerId)) continue
      seen.add(peerId)
      neighbors.push(peerId)
      if (neighbors.length >= 3) break
    }

    if (neighbors.length > 0) {
      return `Affected through dependencies on ${neighbors.join(", ")}.`
    }

    return this.defaultStateReason(state)
  },
  nodeIndexLookup(nodes) {
    const map = new Map()
    if (!Array.isArray(nodes)) return map
    for (const n of nodes) {
      const idx = Number(n?.index)
      if (!Number.isFinite(idx)) continue
      map.set(idx, n)
    }
    return map
  },
  nodeRefByIndex(index, nodeIndexMap) {
    const idx = Number(index)
    if (!Number.isFinite(idx) || idx < 0) return null
    const node = nodeIndexMap.get(idx)
    if (!node) return `node#${idx}`
    const label = this.normalizeDisplayLabel(node.label, node.id || `node#${idx}`)
    const ip = node?.details?.ip
    return ip ? `${label} (${ip})` : label
  },
  humanizeCausalReason(reason, details, nodeIndexMap) {
    const key = String(reason || "").trim().toLowerCase()
    const hop = Number(details?.causal_hop_distance)
    const rootRef = this.nodeRefByIndex(details?.causal_root_index, nodeIndexMap)
    const parentRef = this.nodeRefByIndex(details?.causal_parent_index, nodeIndexMap)

    if (key === "selected_as_root_from_unhealthy_candidates") {
      return "Selected as root cause from unhealthy candidates by topology centrality."
    }

    if (key.startsWith("reachable_from_root_within_") && Number.isFinite(hop) && hop >= 0) {
      const via = parentRef ? ` via ${parentRef}` : ""
      const root = rootRef ? ` from ${rootRef}` : ""
      return `Affected: reachable${root} within ${hop} hop(s)${via}.`
    }

    if (key === "healthy_signal_no_path_to_selected_root") {
      return rootRef
        ? `Healthy: no dependency path from selected root ${rootRef}.`
        : "Healthy: no dependency path from selected root."
    }

    if (key === "unhealthy_signal_not_reachable_from_selected_root") {
      return rootRef
        ? `Unhealthy but not causally linked to selected root ${rootRef}.`
        : "Unhealthy but not causally linked to selected root."
    }

    if (key === "healthy_signal_no_detected_causal_impact") {
      return "Healthy signal with no detected causal impact."
    }

    if (key === "unknown_signal_without_identified_root") {
      return "State unknown: insufficient telemetry to identify a root cause."
    }

    const root = rootRef ? ` Root: ${rootRef}.` : ""
    const via = parentRef ? ` Parent: ${parentRef}.` : ""
    return `${reason}.${root}${via}`.trim()
  },
}
