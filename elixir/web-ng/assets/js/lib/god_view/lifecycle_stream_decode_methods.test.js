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
})
