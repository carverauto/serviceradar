import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingStyleNodeReasonMethods} from "./rendering_style_node_reason_methods"
import {godViewRenderingStyleNodeVisualMethods} from "./rendering_style_node_visual_methods"

const state = {}
const methods = createStateBackedContext(state, {}, Object.keys(state))
Object.assign(
  methods,
  bindApi(methods, godViewRenderingStyleNodeVisualMethods),
  bindApi(methods, godViewRenderingStyleNodeReasonMethods),
)

describe("rendering_style_node_reason_methods", () => {
  it("stateReasonForNode returns root-cause down-device reason", () => {
    const reason = methods.stateReasonForNode({state: 0, operUp: 2}, [])
    expect(reason).toEqual("Device is operationally down and identified as a root cause.")
  })

  it("stateReasonForNode derives affected dependency reason from edges", () => {
    const node = {id: "node-a", state: 1, details: {}}
    const edges = [
      {sourceId: "node-a", targetId: "upstream-1"},
      {sourceId: "upstream-2", targetId: "node-a"},
    ]

    const reason = methods.stateReasonForNode(node, edges)
    expect(reason).toEqual("Affected through dependencies on upstream-1, upstream-2.")
  })

  it("humanizeCausalReason formats reachable-from-root detail", () => {
    const nodeIndexMap = methods.nodeIndexLookup([
      {index: 1, id: "root", label: "Root", details: {ip: "10.0.0.1"}},
      {index: 2, id: "parent", label: "Parent", details: {ip: "10.0.0.2"}},
    ])

    const text = methods.humanizeCausalReason(
      "reachable_from_root_within_2",
      {causal_hop_distance: 2, causal_root_index: 1, causal_parent_index: 2},
      nodeIndexMap,
    )

    expect(text).toEqual(
      "Affected: reachable from Root (10.0.0.1) within 2 hop(s) via Parent (10.0.0.2).",
    )
  })
})
