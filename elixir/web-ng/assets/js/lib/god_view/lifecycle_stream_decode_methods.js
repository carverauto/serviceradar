import {decodeSnapshotColumns, defineLazyProperty} from "./snapshot_columns"
import {canonicalSemanticRelationId} from "./topology_relation_identity"

function finiteOrNaN(value) {
  return Number.isFinite(value) ? value : NaN
}

export const godViewLifecycleStreamDecodeMethods = {
  parseOptionalFloat(value) {
    if (value == null) return NaN
    if (typeof value === "number") return Number.isFinite(value) ? value : NaN
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed === "") return NaN
      const parsed = Number(trimmed)
      return Number.isFinite(parsed) ? parsed : NaN
    }
    return NaN
  },
  /**
   * Decodes a snapshot into the typed columns plus the one object graph layout still needs.
   *
   * Nothing here parses `node_details` or `edge_details`. Each node's and edge's `details`
   * (and the fields derived from them: `clusterCount`, `geoLat`, `geoLon`, edge `metadata`,
   * `relationType` and the semantic edge `id`) is a lazy property that parses its own row on
   * first read. `graph.columns` carries the typed arrays the render path draws from.
   */
  decodeArrowGraph(bytes) {
    const columns = decodeSnapshotColumns(bytes)
    const normalizeDisplayLabel = this.deps.normalizeDisplayLabel
    const parseOptionalFloat = (value) => this.parseOptionalFloat(value)
    const {nodeCount, edgeCount} = columns

    const nodes = new Array(nodeCount)
    for (let i = 0; i < nodeCount; i += 1) {
      const fallbackLabel = `node-${i + 1}`
      const node = {
        id: normalizeDisplayLabel(columns.nodeId(i), fallbackLabel),
        x: columns.nodeX[i],
        y: columns.nodeY[i],
        state: columns.nodeState[i],
        label: normalizeDisplayLabel(columns.nodeLabel(i), fallbackLabel),
        pps: columns.nodePps[i],
        operUp: columns.nodeOperUp[i],
      }
      defineLazyProperty(node, "clusterCount", () => Math.max(1, Number(node.details?.cluster_member_count || 1)))
      defineLazyProperty(node, "geoLat", () => finiteOrNaN(parseOptionalFloat(node.details?.geo_lat)))
      defineLazyProperty(node, "geoLon", () => finiteOrNaN(parseOptionalFloat(node.details?.geo_lon)))
      defineLazyProperty(node, "details", () => columns.nodeDetails(i))
      nodes[i] = node
    }

    const flowPps = columns.edgeColumn("edge_pps")
    const flowPpsAb = columns.edgeColumn("edge_pps_ab")
    const flowPpsBa = columns.edgeColumn("edge_pps_ba")
    const flowBps = columns.edgeColumn("edge_flow_bps")
    const flowBpsAb = columns.edgeColumn("edge_flow_bps_ab")
    const flowBpsBa = columns.edgeColumn("edge_flow_bps_ba")
    const capacityBps = columns.edgeColumn("edge_capacity_bps")
    const telemetryEligible = columns.edgeColumn("edge_telemetry_eligible", Uint8Array, 1)
    const edgeLabel = columns.edgeStrings("edge_label")
    const edgeTopologyClass = columns.edgeStrings("edge_topology_class")
    const edgeProtocol = columns.edgeStrings("edge_protocol")
    const edgeEvidenceClass = columns.edgeStrings("edge_evidence_class")

    const edges = new Array(edgeCount)
    for (let i = 0; i < edgeCount; i += 1) {
      const edge = {
        source: columns.edgeSource[i],
        target: columns.edgeTarget[i],
        flowPps: flowPps[i],
        flowPpsAb: flowPpsAb[i],
        flowPpsBa: flowPpsBa[i],
        flowBps: flowBps[i],
        flowBpsAb: flowBpsAb[i],
        flowBpsBa: flowBpsBa[i],
        capacityBps: capacityBps[i],
        telemetryEligible: telemetryEligible[i] > 0,
        label: normalizeDisplayLabel(edgeLabel(i), ""),
        topologyClass: normalizeDisplayLabel(edgeTopologyClass(i), "unknown"),
        protocol: normalizeDisplayLabel(edgeProtocol(i), ""),
        evidenceClass: normalizeDisplayLabel(edgeEvidenceClass(i), ""),
      }
      defineLazyProperty(edge, "details", () => columns.edgeDetails(i))
      defineLazyProperty(edge, "metadata", () => {
        const details = edge.details
        return details?.metadata && typeof details.metadata === "object" ? details.metadata : {}
      })
      defineLazyProperty(edge, "relationType", () => normalizeDisplayLabel(edge.metadata?.relation_type, ""))
      defineLazyProperty(edge, "id", () => {
        const sourceId = String(nodes[edge.source]?.id ?? "").trim()
        const targetId = String(nodes[edge.target]?.id ?? "").trim()
        return canonicalSemanticRelationId(edge, sourceId, targetId)
      })
      edges[i] = edge
    }

    return {
      nodes,
      edges,
      edgeSourceIndex: columns.edgeSource,
      edgeTargetIndex: columns.edgeTarget,
      columns,
    }
  },
}
