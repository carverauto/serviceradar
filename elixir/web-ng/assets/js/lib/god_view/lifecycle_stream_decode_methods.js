import {decodeSnapshotColumns} from "./snapshot_columns"
import {canonicalSemanticRelationId} from "./topology_relation_identity"

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
   * Every node and edge is one plain object with data properties only, so the spreads and
   * copies the layout path makes keep every field. Nothing here parses `node_details` or
   * `edge_details`: ids, cluster counts, coordinates, relation identity and metadata come
   * from the encoder's details columns, and each `details` / `metadata` is an object that
   * answers those keys from the columns and parses its own row only for any other key.
   * `graph.columns` (not enumerable) carries the typed arrays.
   */
  decodeArrowGraph(bytes) {
    const columns = decodeSnapshotColumns(bytes)
    const normalizeDisplayLabel = this.deps.normalizeDisplayLabel
    const parseOptionalFloat = (value) => this.parseOptionalFloat(value)
    const {nodeCount, edgeCount, nodeX, nodeY, nodeState, nodePps, nodeOperUp} = columns

    const nodes = new Array(nodeCount)
    for (let i = 0; i < nodeCount; i += 1) {
      const fallbackLabel = `node-${i + 1}`
      const geoLat = parseOptionalFloat(columns.nodeDetail(i, "geo_lat"))
      const geoLon = parseOptionalFloat(columns.nodeDetail(i, "geo_lon"))
      nodes[i] = {
        id: normalizeDisplayLabel(columns.nodeDetail(i, "id"), fallbackLabel),
        x: nodeX[i],
        y: nodeY[i],
        state: nodeState[i],
        label: normalizeDisplayLabel(columns.nodeLabel(i), fallbackLabel),
        clusterCount: Math.max(1, Number(columns.nodeDetail(i, "cluster_member_count") || 1)),
        pps: nodePps[i],
        operUp: nodeOperUp[i],
        geoLat: Number.isFinite(geoLat) ? geoLat : NaN,
        geoLon: Number.isFinite(geoLon) ? geoLon : NaN,
        details: columns.nodeDetails(i),
      }
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
      const {details, metadata} = columns.edgeDetailsAndMetadata(i)
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
        details,
        metadata,
        relationType: normalizeDisplayLabel(metadata.relation_type, ""),
        id: "",
      }
      const sourceId = String(nodes[edge.source]?.id ?? "").trim()
      const targetId = String(nodes[edge.target]?.id ?? "").trim()
      edge.id = canonicalSemanticRelationId(edge, sourceId, targetId)
      edges[i] = edge
    }

    const graph = {
      nodes,
      edges,
      edgeSourceIndex: columns.edgeSource,
      edgeTargetIndex: columns.edgeTarget,
    }
    if (columns.table.schema.metadata.get("payload_kind") === "detail") {
      if (nodeCount > 128 || edgeCount > 256 || bytes.byteLength > 262144) throw new Error("Topology detail exceeds budget")
      graph._topologySemanticLevel = "detail"
    }
    // Not enumerable: layout spreads and deep-clones the graph, and must not copy the table.
    Object.defineProperty(graph, "columns", {value: columns, enumerable: false})
    return graph
  },
}
