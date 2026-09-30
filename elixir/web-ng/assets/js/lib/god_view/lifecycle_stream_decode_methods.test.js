import {tableFromArrays, tableToIPC} from "apache-arrow"
import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {largeRingSnapshotIpcBytes, snapshotIpcBytes, syntheticRing} from "./fixtures/snapshot_ipc"
import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"
import {copyDetails, detailsHaveSparkline} from "./snapshot_columns"

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
  it.each([
    {profile: undefined, semanticLevel: "detail"},
    {profile: "radial-overview", semanticLevel: "overview"},
  ])("routes a bounded server page to its selected ELK profile: $profile", ({profile, semanticLevel}) => {
    const metadataEntries = [["payload_kind", "detail"], ["layout_algorithm", "elk"]]
    if (profile) metadataEntries.push(["layout_profile", profile])
    const nodes = [{label: "Synthetic switch", details: {id: "invented-detail-switch"}}]
    const graph = decoder().decodeArrowGraph(snapshotIpcBytes({nodes, edges: [], metadataEntries}))
    expect(graph._topologySemanticLevel).toBe(semanticLevel)
    expect(graph._topologyBoundedPage).toBe(true)
    expect(graph.nodes[0].id).toBe("invented-detail-switch")
    expect(() => decoder().decodeArrowGraph(snapshotIpcBytes({nodes: Array(129).fill(nodes[0]), edges: [], metadataEntries}))).toThrow("Topology detail exceeds budget")
  })

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

  it("names edge endpoints above 65535 and exposes quantized layout coordinates per node", () => {
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
    expect([decoded.nodes[65_537].x, decoded.nodes[65_537].y]).toEqual([1, (65_537 * 7) % 65536])

    const {nodeX, nodeY, nodeState} = decoded.columns
    expect(nodeX).toBeInstanceOf(Uint16Array)
    expect(nodeY).toBeInstanceOf(Uint16Array)
    expect([nodeX[65_537], nodeY[65_537]]).toEqual([1, (65_537 * 7) % 65536])
    expect(nodeState).toBeInstanceOf(Uint8Array)
    expect(nodeState[65_538]).toEqual(65_538 % 4)
  }, 30_000)

  it("answers the per-row details keys from columns and parses JSON only for the row that is read", () => {
    const {nodes, edges} = syntheticRing(500)
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({nodes, edges}))

    // Ids, positions, endpoints, relation identity and the keys every render reads.
    expect(decoded.nodes[123].id).toEqual("n-123")
    expect(decoded.nodes[123].details.type).toEqual("switch")
    expect(decoded.nodes[123].details.topology_unplaced).toBe(false)
    expect(decoded.nodes[123].details.cluster_kind).toBeUndefined()
    expect(decoded.edges[42].target).toEqual(43)
    expect(decoded.edges[42].details.source_id).toEqual("n-42")
    expect(decoded.edges[42].metadata.relation_type).toEqual("CONNECTS_TO")
    expect(decoded.edges[42].details.metadata.topology_plane).toEqual("physical")
    expect(decoded.edges[42].id).toMatch(/^semantic:/)
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 0, edges: 0})

    // A key without a column parses that row, once.
    expect(decoded.nodes[321].details.ip).toEqual("192.0.2.65")
    expect(decoded.nodes[321].details.hostname).toEqual("host-321.example.com")
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 1, edges: 0})
    expect(decoded.edges[7].details.interface_sparkline).toEqual([])
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 1, edges: 1})
  })

  it("serves exactly what the JSON says for every column-backed key", () => {
    const nodeDetails = [
      {id: "a", type: "router", cluster_kind: "endpoint-summary", cluster_id: "c1", cluster_anchor_id: "b",
        cluster_panel_side: "right", identity_source: "mapper", topology_plane: "backbone",
        cluster_expanded: true, topology_unplaced: false, cluster_member_count: 12, geo_lat: 0.5, geo_lon: null},
      {id: "b"},
      {},
    ]
    const edgeDetails = [
      {source_id: "a", target_id: "b", source_interface: "ge-0/0/1", source_if_index: 3, target_if_index: null,
        telemetry_source: "interface", telemetry_observed_at: "2026-01-01T00:00:00Z", interface_sparkline: [{value: 1}],
        metadata: {relation_type: "CONNECTS_TO", topology_plane: "physical", connectivity_forest_bridge: true, raw_relation_type: "X"}},
      {source_id: "b"},
    ]
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: nodeDetails.map((details, index) => ({id: details.id, details, x: index})),
      edges: edgeDetails.map((details, index) => ({source: index, target: index + 1, details})),
    }))
    const nodeKeys = ["id", "type", "cluster_kind", "cluster_id", "cluster_anchor_id", "cluster_panel_side",
      "identity_source", "topology_plane", "cluster_expanded", "topology_unplaced", "cluster_member_count", "geo_lat", "geo_lon"]
    const edgeKeys = ["source_id", "target_id", "source_interface", "target_interface", "telemetry_source",
      "telemetry_observed_at", "observed_at", "source_if_index", "target_if_index"]
    const metadataKeys = ["relation_type", "topology_plane", "confidence_tier", "confidence_reason", "connectivity_forest_bridge"]

    const served = {
      nodes: decoded.nodes.map((node) => nodeKeys.map((key) => node.details[key])),
      edges: decoded.edges.map((edge) => edgeKeys.map((key) => edge.details[key])),
      metadata: decoded.edges.map((edge) => metadataKeys.map((key) => edge.metadata[key])),
      hasMetadata: decoded.edges.map((edge) => edge.details.metadata !== undefined),
    }
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 0, edges: 0})

    // `?? undefined`: a column cannot tell JSON null from an absent key; readers treat both alike.
    const plain = (value) => value ?? undefined
    expect(served).toEqual({
      nodes: nodeDetails.map((details) => nodeKeys.map((key) => plain(details[key]))),
      edges: edgeDetails.map((details) => edgeKeys.map((key) => plain(details[key]))),
      metadata: edgeDetails.map((details) => metadataKeys.map((key) => plain(details.metadata?.[key]))),
      hasMetadata: [true, false],
    })
    // Spreading or reading any other key is the full JSON.
    expect({...decoded.edges[0].metadata}).toEqual(edgeDetails[0].metadata)
    expect({...decoded.nodes[0].details}).toEqual(nodeDetails[0])
  })

  it("parses a row up front when a column cannot carry one of its values", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [
        {id: "a", details: {id: "a", cluster_expanded: "true"}},
        {id: "b", details: {id: "b", cluster_expanded: true}},
      ],
      edges: [{source: 0, target: 1, details: {metadata: {"relation-type": "CONNECTS_TO"}}}],
    }))

    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 1, edges: 1})
    expect(decoded.nodes[0].details.cluster_expanded).toBe("true")
    expect(decoded.nodes[1].details.cluster_expanded).toBe(true)
    expect(decoded.edges[0].metadata["relation-type"]).toBe("CONNECTS_TO")
  })

  it("copies details without parsing, and a copy writes to itself", () => {
    const {nodes, edges} = syntheticRing(3)
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({nodes, edges}))
    const original = decoded.edges[1].details

    const copy = copyDetails(original)
    expect(copy.source_id).toEqual("n-1")
    expect(copy.metadata.relation_type).toEqual("CONNECTS_TO")
    expect(detailsHaveSparkline(copy)).toBe(false)
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 0, edges: 0})

    copy.source_id = "changed"
    expect(copy.source_id).toEqual("changed")
    expect(original.source_id).toEqual("n-1")
  })

  it("reads node ids from details for a frame without details columns", () => {
    const decoded = decoder().decodeArrowGraph(snapshotIpcBytes({
      nodes: [{label: "A", details: {id: "sr:a"}}, {label: "B", details: {}}],
      detailColumns: false,
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
