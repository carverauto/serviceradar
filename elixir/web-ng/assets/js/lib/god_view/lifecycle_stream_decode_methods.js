import {tableFromIPC} from "apache-arrow"

export const godViewLifecycleStreamDecodeMethods = {
  decodeArrowGraph(bytes) {
    const table = tableFromIPC(bytes)
    const rowType = table.getChild("row_type")
    const nodeX = table.getChild("node_x")
    const nodeY = table.getChild("node_y")
    const nodeState = table.getChild("node_state")
    const nodeLabel = table.getChild("node_label")
    const nodePps = table.getChild("node_pps")
    const nodeOperUp = table.getChild("node_oper_up")
    const nodeDetails = table.getChild("node_details")
    const edgeSource = table.getChild("edge_source")
    const edgeTarget = table.getChild("edge_target")
    const edgePps = table.getChild("edge_pps")
    const edgePpsAb = table.getChild("edge_pps_ab")
    const edgePpsBa = table.getChild("edge_pps_ba")
    const edgeFlowBps = table.getChild("edge_flow_bps")
    const edgeFlowBpsAb = table.getChild("edge_flow_bps_ab")
    const edgeFlowBpsBa = table.getChild("edge_flow_bps_ba")
    const edgeCapacityBps = table.getChild("edge_capacity_bps")
    const edgeTelemetryEligible = table.getChild("edge_telemetry_eligible")
    const edgeLabel = table.getChild("edge_label")
    const edgeTopologyClass = table.getChild("edge_topology_class")
    const edgeProtocol = table.getChild("edge_protocol")
    const edgeEvidenceClass = table.getChild("edge_evidence_class")

    const nodes = []
    const edges = []
    const edgeSourceIndex = []
    const edgeTargetIndex = []
    const rowCount = table.numRows || 0

    for (let i = 0; i < rowCount; i += 1) {
      const t = rowType?.get(i)
      if (t === 0) {
        const fallbackLabel = `node-${nodes.length + 1}`
        let parsedDetails = {}
        const rawDetails = nodeDetails?.get(i)
        if (typeof rawDetails === "string" && rawDetails.trim() !== "") {
          try {
            parsedDetails = JSON.parse(rawDetails)
          } catch (_err) {
            parsedDetails = {}
          }
        }
        const detailLat = Number(parsedDetails?.geo_lat)
        const detailLon = Number(parsedDetails?.geo_lon)
        nodes.push({
          id: this.deps.normalizeDisplayLabel(parsedDetails?.id, fallbackLabel),
          x: Number(nodeX?.get(i) || 0),
          y: Number(nodeY?.get(i) || 0),
          state: Number(nodeState?.get(i) || 3),
          label: this.deps.normalizeDisplayLabel(nodeLabel?.get(i), fallbackLabel),
          pps: Number(nodePps?.get(i) || 0),
          operUp: Number(nodeOperUp?.get(i) || 0),
          geoLat: Number.isFinite(detailLat) ? detailLat : NaN,
          geoLon: Number.isFinite(detailLon) ? detailLon : NaN,
          details: parsedDetails,
        })
      } else if (t === 1) {
        const source = Number(edgeSource?.get(i) || 0)
        const target = Number(edgeTarget?.get(i) || 0)
        edges.push({
          source,
          target,
          flowPps: Number(edgePps?.get(i) || 0),
          flowPpsAb: Number(edgePpsAb?.get(i) || 0),
          flowPpsBa: Number(edgePpsBa?.get(i) || 0),
          flowBps: Number(edgeFlowBps?.get(i) || 0),
          flowBpsAb: Number(edgeFlowBpsAb?.get(i) || 0),
          flowBpsBa: Number(edgeFlowBpsBa?.get(i) || 0),
          capacityBps: Number(edgeCapacityBps?.get(i) || 0),
          telemetryEligible: Number(edgeTelemetryEligible?.get(i) ?? 1) > 0,
          label: this.deps.normalizeDisplayLabel(edgeLabel?.get(i), ""),
          topologyClass: this.deps.normalizeDisplayLabel(edgeTopologyClass?.get(i), "unknown"),
          protocol: this.deps.normalizeDisplayLabel(edgeProtocol?.get(i), ""),
          evidenceClass: this.deps.normalizeDisplayLabel(edgeEvidenceClass?.get(i), ""),
        })
        edgeSourceIndex.push(source)
        edgeTargetIndex.push(target)
      }
    }

    return {
      nodes,
      edges,
      edgeSourceIndex: Uint32Array.from(edgeSourceIndex),
      edgeTargetIndex: Uint32Array.from(edgeTargetIndex),
    }
  },
}
