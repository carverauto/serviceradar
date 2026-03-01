import {describe, expect, it, vi} from "vitest"

vi.mock("apache-arrow", () => ({
  tableFromIPC: vi.fn(),
}))

import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"
import {bindApi, createStateBackedContext} from "./api_helpers"
import {tableFromIPC} from "apache-arrow"

function makeColumn(values) {
  return {get: (idx) => values[idx]}
}

function makeTable(columns, numRows) {
  return {
    numRows,
    getChild: (name) => columns[name],
  }
}

describe("lifecycle_stream_decode_methods", () => {
  it("decodes explicit edge topology metadata without label inference", () => {
    tableFromIPC.mockReturnValueOnce(
      makeTable(
        {
          row_type: makeColumn([0, 1]),
          node_x: makeColumn([10, null]),
          node_y: makeColumn([20, null]),
          node_state: makeColumn([2, null]),
          node_label: makeColumn(["farm01", null]),
          node_pps: makeColumn([0, null]),
          node_oper_up: makeColumn([1, null]),
          node_details: makeColumn([JSON.stringify({id: "farm01"}), null]),
          edge_source: makeColumn([null, 0]),
          edge_target: makeColumn([null, 0]),
          edge_pps: makeColumn([null, 77]),
          edge_pps_ab: makeColumn([null, 55]),
          edge_pps_ba: makeColumn([null, 22]),
          edge_flow_bps: makeColumn([null, 1000]),
          edge_flow_bps_ab: makeColumn([null, 800]),
          edge_flow_bps_ba: makeColumn([null, 200]),
          edge_capacity_bps: makeColumn([null, 1_000_000_000]),
          edge_telemetry_eligible: makeColumn([null, 1]),
          edge_label: makeColumn([null, "LINK ENDPOINT attachment"]),
          edge_topology_class: makeColumn([null, "backbone"]),
          edge_protocol: makeColumn([null, "snmp-l2"]),
          edge_evidence_class: makeColumn([null, "direct"]),
        },
        2,
      ),
    )

    const state = {}
    const deps = {
      normalizeDisplayLabel: (value, fallback) =>
        typeof value === "string" && value.trim() !== "" ? value : fallback,
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))

    const decoded = methods.decodeArrowGraph(new Uint8Array([1, 2, 3]))
    expect(decoded.nodes).toHaveLength(1)
    expect(decoded.edges).toHaveLength(1)
    expect(decoded.edges[0].topologyClass).toEqual("backbone")
    expect(decoded.edges[0].protocol).toEqual("snmp-l2")
    expect(decoded.edges[0].evidenceClass).toEqual("direct")
  })

  it("preserves backend edge rows and directional fields without client-side reshaping", () => {
    tableFromIPC.mockReturnValueOnce(
      makeTable(
        {
          row_type: makeColumn([0, 0, 1, 1]),
          node_x: makeColumn([10, 20, null, null]),
          node_y: makeColumn([30, 40, null, null]),
          node_state: makeColumn([1, 1, null, null]),
          node_label: makeColumn(["a", "b", null, null]),
          node_pps: makeColumn([0, 0, null, null]),
          node_oper_up: makeColumn([1, 1, null, null]),
          node_details: makeColumn([JSON.stringify({id: "a"}), JSON.stringify({id: "b"}), null, null]),
          edge_source: makeColumn([null, null, 0, 1]),
          edge_target: makeColumn([null, null, 1, 0]),
          edge_pps: makeColumn([null, null, 300, 120]),
          edge_pps_ab: makeColumn([null, null, 250, 20]),
          edge_pps_ba: makeColumn([null, null, 50, 100]),
          edge_flow_bps: makeColumn([null, null, 3_000, 1_200]),
          edge_flow_bps_ab: makeColumn([null, null, 2_500, 200]),
          edge_flow_bps_ba: makeColumn([null, null, 500, 1_000]),
          edge_capacity_bps: makeColumn([null, null, 10_000, 10_000]),
          edge_telemetry_eligible: makeColumn([null, null, 1, 1]),
          edge_label: makeColumn([null, null, "edge-ab", "edge-ba"]),
          edge_topology_class: makeColumn([null, null, "backbone", "backbone"]),
          edge_protocol: makeColumn([null, null, "snmp", "snmp"]),
          edge_evidence_class: makeColumn([null, null, "direct", "direct"]),
        },
        4,
      ),
    )

    const state = {}
    const deps = {
      normalizeDisplayLabel: (value, fallback) =>
        typeof value === "string" && value.trim() !== "" ? value : fallback,
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))

    const decoded = methods.decodeArrowGraph(new Uint8Array([1, 2, 3]))
    expect(decoded.nodes).toHaveLength(2)
    expect(decoded.edges).toHaveLength(2)

    expect(decoded.edges[0].source).toEqual(0)
    expect(decoded.edges[0].target).toEqual(1)
    expect(decoded.edges[0].flowPpsAb).toEqual(250)
    expect(decoded.edges[0].flowPpsBa).toEqual(50)

    expect(decoded.edges[1].source).toEqual(1)
    expect(decoded.edges[1].target).toEqual(0)
    expect(decoded.edges[1].flowPpsAb).toEqual(20)
    expect(decoded.edges[1].flowPpsBa).toEqual(100)
  })

  it("emits canonical edge field set with typed defaults when optional columns are absent", () => {
    tableFromIPC.mockReturnValueOnce(
      makeTable(
        {
          row_type: makeColumn([0, 0, 1]),
          node_x: makeColumn([10, 20, null]),
          node_y: makeColumn([30, 40, null]),
          node_state: makeColumn([1, 1, null]),
          node_label: makeColumn(["a", "b", null]),
          node_pps: makeColumn([0, 0, null]),
          node_oper_up: makeColumn([1, 1, null]),
          node_details: makeColumn([JSON.stringify({id: "a"}), JSON.stringify({id: "b"}), null]),
          edge_source: makeColumn([null, null, 0]),
          edge_target: makeColumn([null, null, 1]),
          edge_pps: makeColumn([null, null, 42]),
          edge_flow_bps: makeColumn([null, null, 4242]),
          edge_capacity_bps: makeColumn([null, null, 1_000_000]),
        },
        3,
      ),
    )

    const state = {}
    const deps = {
      normalizeDisplayLabel: (value, fallback) =>
        typeof value === "string" && value.trim() !== "" ? value : fallback,
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))

    const decoded = methods.decodeArrowGraph(new Uint8Array([1, 2, 3]))
    expect(decoded.edges).toHaveLength(1)
    const edge = decoded.edges[0]

    expect(edge).toMatchObject({
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

  it("preserves known unstable directional links without collapsing or reorientation", () => {
    tableFromIPC.mockReturnValueOnce(
      makeTable(
        {
          row_type: makeColumn([0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1]),
          node_x: makeColumn([10, 20, 30, 40, 50, 60, null, null, null, null, null, null]),
          node_y: makeColumn([15, 25, 35, 45, 55, 65, null, null, null, null, null, null]),
          node_state: makeColumn([1, 1, 1, 1, 1, 1, null, null, null, null, null, null]),
          node_label: makeColumn([
            "farm01",
            "uswaggregation",
            "tonka01",
            "aruba-24g-02",
            "uswlite8poe",
            "u6mesh",
            null,
            null,
            null,
            null,
            null,
            null,
          ]),
          node_pps: makeColumn([0, 0, 0, 0, 0, 0, null, null, null, null, null, null]),
          node_oper_up: makeColumn([1, 1, 1, 1, 1, 1, null, null, null, null, null, null]),
          node_details: makeColumn([
            JSON.stringify({id: "sr:farm01"}),
            JSON.stringify({id: "sr:uswaggregation"}),
            JSON.stringify({id: "sr:tonka01"}),
            JSON.stringify({id: "sr:aruba-24g-02"}),
            JSON.stringify({id: "sr:uswlite8poe"}),
            JSON.stringify({id: "sr:u6mesh"}),
            null,
            null,
            null,
            null,
            null,
            null,
          ]),
          edge_source: makeColumn([null, null, null, null, null, null, 0, 1, 2, 3, 4, 5]),
          edge_target: makeColumn([null, null, null, null, null, null, 1, 0, 3, 2, 5, 4]),
          edge_pps: makeColumn([null, null, null, null, null, null, 140, 75, 90, 65, 55, 49]),
          edge_pps_ab: makeColumn([null, null, null, null, null, null, 80, 40, 50, 30, 40, 18]),
          edge_pps_ba: makeColumn([null, null, null, null, null, null, 60, 35, 40, 35, 15, 31]),
          edge_flow_bps: makeColumn([null, null, null, null, null, null, 14_000, 7_500, 9_000, 6_500, 5_500, 4_900]),
          edge_flow_bps_ab: makeColumn([null, null, null, null, null, null, 8_000, 4_000, 5_000, 3_000, 4_000, 1_800]),
          edge_flow_bps_ba: makeColumn([null, null, null, null, null, null, 6_000, 3_500, 4_000, 3_500, 1_500, 3_100]),
          edge_capacity_bps: makeColumn([null, null, null, null, null, null, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000, 1_000_000_000]),
          edge_telemetry_eligible: makeColumn([null, null, null, null, null, null, 1, 1, 1, 1, 1, 1]),
          edge_label: makeColumn([null, null, null, null, null, null, "", "", "", "", "", ""]),
          edge_topology_class: makeColumn([null, null, null, null, null, null, "backbone", "backbone", "backbone", "backbone", "endpoint", "endpoint"]),
          edge_protocol: makeColumn([null, null, null, null, null, null, "snmp-l2", "snmp-l2", "snmp-l2", "snmp-l2", "snmp-l2", "snmp-l2"]),
          edge_evidence_class: makeColumn([null, null, null, null, null, null, "direct", "direct", "direct", "direct", "direct", "direct"]),
        },
        12,
      ),
    )

    const state = {}
    const deps = {
      normalizeDisplayLabel: (value, fallback) =>
        typeof value === "string" && value.trim() !== "" ? value : fallback,
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))

    const decoded = methods.decodeArrowGraph(new Uint8Array([1, 2, 3]))
    expect(decoded.nodes).toHaveLength(6)
    expect(decoded.edges).toHaveLength(6)

    const hasFarmForward = decoded.edges.some((edge) => edge.source === 0 && edge.target === 1 && edge.flowPpsAb === 80 && edge.flowPpsBa === 60)
    const hasFarmReverse = decoded.edges.some((edge) => edge.source === 1 && edge.target === 0 && edge.flowPpsAb === 40 && edge.flowPpsBa === 35)
    const hasTonkaForward = decoded.edges.some((edge) => edge.source === 2 && edge.target === 3 && edge.flowPpsAb === 50 && edge.flowPpsBa === 40)
    const hasLiteForward = decoded.edges.some((edge) => edge.source === 4 && edge.target === 5 && edge.flowPpsAb === 40 && edge.flowPpsBa === 15)

    expect(hasFarmForward).toEqual(true)
    expect(hasFarmReverse).toEqual(true)
    expect(hasTonkaForward).toEqual(true)
    expect(hasLiteForward).toEqual(true)
  })

  it("treats null geo fields as missing coordinates instead of 0,0", () => {
    tableFromIPC.mockReturnValueOnce(
      makeTable(
        {
          row_type: makeColumn([0]),
          node_x: makeColumn([10]),
          node_y: makeColumn([20]),
          node_state: makeColumn([1]),
          node_label: makeColumn(["geo-null-node"]),
          node_pps: makeColumn([0]),
          node_oper_up: makeColumn([1]),
          node_details: makeColumn([JSON.stringify({id: "sr:geo-null", geo_lat: null, geo_lon: null})]),
        },
        1,
      ),
    )

    const state = {}
    const deps = {
      normalizeDisplayLabel: (value, fallback) =>
        typeof value === "string" && value.trim() !== "" ? value : fallback,
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamDecodeMethods))

    const decoded = methods.decodeArrowGraph(new Uint8Array([1, 2, 3]))
    expect(decoded.nodes).toHaveLength(1)
    expect(Number.isNaN(decoded.nodes[0].geoLat)).toEqual(true)
    expect(Number.isNaN(decoded.nodes[0].geoLon)).toEqual(true)
  })
})
