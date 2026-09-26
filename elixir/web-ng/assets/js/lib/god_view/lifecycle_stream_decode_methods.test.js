import {tableFromArrays, tableToIPC} from "apache-arrow"
import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {largeRingSnapshotIpcBytes, snapshotIpcBytes, syntheticRing} from "./fixtures/snapshot_ipc"
import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"

function decoder() {
  const deps = {
    normalizeDisplayLabel: (value, fallback) =>
      typeof value === "string" && value.trim() !== "" ? value : fallback,
  }
  const methods = createStateBackedContext({}, deps)
  Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))
  return methods
}

describe("lifecycle_stream_decode_methods", () => {
  it("decodes explicit edge topology metadata without label inference", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{id: "core-a", label: "core-a", x: 10, y: 20, state: 2, operUp: 1}],
      edges: [{
        source: 0,
        target: 0,
        flowPps: 77,
        label: "LINK ENDPOINT attachment",
        topologyClass: "backbone",
        protocol: "snmp-l2",
        evidenceClass: "direct",
        details: {
          source_interface: "xe-0/0/0",
          target_interface: "xe-0/0/1",
          metadata: {relation_type: "ATTACHED_TO", topology_plane: "attachment"},
          interface_sparkline: [{value: 1000}, {value: 2000}],
        },
      }],
    }))

    expect(decoded.nodes).toHaveLength(1)
    expect(decoded.edges).toHaveLength(1)
    expect(decoded.edges[0].topologyClass).toEqual("backbone")
    expect(decoded.edges[0].protocol).toEqual("snmp-l2")
    expect(decoded.edges[0].evidenceClass).toEqual("direct")
    expect(decoded.edges[0].metadata).toEqual({relation_type: "ATTACHED_TO", topology_plane: "attachment"})
    expect(decoded.edges[0].relationType).toEqual("ATTACHED_TO")
    expect(decoded.edges[0].details.source_interface).toEqual("xe-0/0/0")
    expect(decoded.edges[0].details.interface_sparkline).toHaveLength(2)
  })

  it("preserves backend edge rows and directional fields without client-side reshaping", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{id: "a", label: "a"}, {id: "b", label: "b"}],
      edges: [
        {source: 0, target: 1, flowPps: 300, flowPpsAb: 250, flowPpsBa: 50, flowBps: 3000, capacityBps: 10000},
        {source: 1, target: 0, flowPps: 120, flowPpsAb: 20, flowPpsBa: 100, flowBps: 1200, capacityBps: 10000},
      ],
    }))

    expect(decoded.nodes).toHaveLength(2)
    expect(decoded.edges).toHaveLength(2)
    expect(decoded.edges[0]).toMatchObject({source: 0, target: 1, flowPpsAb: 250, flowPpsBa: 50})
    expect(decoded.edges[1]).toMatchObject({source: 1, target: 0, flowPpsAb: 20, flowPpsBa: 100})
  })

  it("emits canonical edge field set with typed defaults when optional columns are absent", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{id: "a"}, {id: "b"}],
      edges: [{source: 0, target: 1, flowPps: 42, flowBps: 4242, capacityBps: 1_000_000}],
      omitColumns: [
        "edge_pps_ab",
        "edge_pps_ba",
        "edge_flow_bps_ab",
        "edge_flow_bps_ba",
        "edge_telemetry_eligible",
        "edge_label",
        "edge_topology_class",
        "edge_protocol",
        "edge_evidence_class",
        "edge_details",
      ],
    }))

    expect(decoded.edges).toHaveLength(1)
    expect(decoded.edges[0]).toMatchObject({
      source: 0,
      target: 1,
      flowPps: 42,
      flowPpsAb: 0,
      flowPpsBa: 0,
      flowBps: 4242,
      flowBpsAb: 0,
      flowBpsBa: 0,
      capacityBps: 1_000_000,
      telemetryEligible: true,
      label: "",
      topologyClass: "unknown",
      protocol: "",
      evidenceClass: "",
    })
  })

  it("preserves reversed directional links without collapsing or reorientation", () => {
    const nodes = ["hub-a", "hub-b", "edge-c", "edge-d", "leaf-e", "leaf-f"].map((id, index) => ({
      id,
      label: id,
      x: 10 * (index + 1),
      y: 10 * (index + 1) + 5,
      state: 1,
      operUp: 1,
    }))
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes,
      edges: [
        {source: 0, target: 1, flowPpsAb: 80, flowPpsBa: 60},
        {source: 1, target: 0, flowPpsAb: 40, flowPpsBa: 35},
        {source: 2, target: 3, flowPpsAb: 50, flowPpsBa: 40},
        {source: 3, target: 2, flowPpsAb: 30, flowPpsBa: 35},
        {source: 4, target: 5, flowPpsAb: 40, flowPpsBa: 15, topologyClass: "endpoint"},
        {source: 5, target: 4, flowPpsAb: 18, flowPpsBa: 31, topologyClass: "endpoint"},
      ],
    }))

    expect(decoded.nodes).toHaveLength(6)
    expect(decoded.edges).toHaveLength(6)
    const has = (source, target, ab, ba) => decoded.edges.some((edge) =>
      edge.source === source && edge.target === target && edge.flowPpsAb === ab && edge.flowPpsBa === ba)
    expect(has(0, 1, 80, 60)).toEqual(true)
    expect(has(1, 0, 40, 35)).toEqual(true)
    expect(has(2, 3, 50, 40)).toEqual(true)
    expect(has(4, 5, 40, 15)).toEqual(true)
  })

  it("treats null geo fields as missing coordinates instead of 0,0", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{id: "sr:geo-null", label: "geo-null-node", details: {id: "sr:geo-null", geo_lat: null, geo_lon: null}}],
    }))

    expect(decoded.nodes).toHaveLength(1)
    expect(Number.isNaN(decoded.nodes[0].geoLat)).toEqual(true)
    expect(Number.isNaN(decoded.nodes[0].geoLon)).toEqual(true)
  })

  it("names edge endpoints above 65535 and exposes positions as one packed Float32Array", () => {
    const count = 70_000
    const decoded = decoder().decodeArrowGraph(largeRingSnapshotIpcBytes(count))

    expect(decoded.nodes).toHaveLength(count)
    expect(decoded.edges).toHaveLength(count)
    expect(decoded.edgeSourceIndex).toBeInstanceOf(Uint32Array)
    expect(decoded.edgeSourceIndex[69_999]).toEqual(69_999)
    expect(decoded.edgeTargetIndex[69_999]).toEqual(0)
    expect(decoded.edgeTargetIndex[65_535]).toEqual(65_536)
    expect(decoded.edges[65_536]).toMatchObject({source: 65_536, target: 65_537})
    expect(decoded.nodes[65_537].id).toEqual("n-65537")

    const {positions, nodeState} = decoded.columns
    expect(positions).toBeInstanceOf(Float32Array)
    expect(positions).toHaveLength(count * 2)
    expect([positions[65_537 * 2], positions[65_537 * 2 + 1]]).toEqual([1, (65_537 * 7) % 65536])
    expect(nodeState).toBeInstanceOf(Uint8Array)
    expect(nodeState[65_538]).toEqual(65_538 % 4)
  }, 30_000)

  it("parses details JSON only for the row that is read", () => {
    const {nodes, edges} = syntheticRing(500)
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({nodes, edges}))

    // Decoding, ids, positions and endpoints need no details.
    expect(decoded.nodes[123].id).toEqual("n-123")
    expect(decoded.edges[42].target).toEqual(43)
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 0, edges: 0})

    // Picking one node parses that node only, once.
    expect(decoded.nodes[321].details.ip).toEqual("192.0.2.65")
    expect(decoded.nodes[321].details.ip).toEqual("192.0.2.65")
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 1, edges: 0})

    // Same for an edge.
    expect(decoded.edges[7].details.source_id).toEqual("n-7")
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 1, edges: 1})
  })

  it("reads node ids from details for a frame that predates the node_id column", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{id: "ignored", label: "A", details: {id: "sr:a"}}, {label: "B", details: {}}],
      omitColumns: ["node_id"],
    }))

    expect(decoded.nodes.map((node) => node.id)).toEqual(["sr:a", "node-2"])
  })

  it("counts rows from row_type when the count metadata is absent, and refuses interleaved rows", () => {
    const nodeFirst = snapshotIpcBytes({
      nodes: [{id: "a"}, {id: "b"}],
      edges: [{source: 1, target: 0}],
      metadata: false,
    })
    const decoded = decoder().decodeArrowGraph(nodeFirst)
    expect(decoded.nodes.map((node) => node.id)).toEqual(["a", "b"])
    expect(decoded.edges[0]).toMatchObject({source: 1, target: 0})

    const interleaved = tableToIPC(tableFromArrays({
      row_type: Int8Array.from([0, 1, 0]),
      node_x: Uint16Array.from([1, 0, 2]),
      node_y: Uint16Array.from([1, 0, 2]),
    }), "file")
    expect(() => decoder().decodeArrowGraph(interleaved)).toThrow(/not node-first/)
  })
})
