import {describe, expect, it} from "vitest"

import GodViewLayoutEngine from "./GodViewLayoutEngine"
import {godViewLayoutAnimationMethods} from "./layout_animation_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLayoutTopologyMethods} from "./layout_topology_methods"

const EXPECTED_LAYOUT_CONTEXT_KEYS = Object.keys(
  Object.assign({}, godViewLayoutClusterMethods, godViewLayoutAnimationMethods, godViewLayoutTopologyMethods),
)

describe("GodViewLayoutEngine API contract", () => {
  it("getContextApi exposes all composed layout methods", () => {
    const engine = new GodViewLayoutEngine({state: {}, deps: {}})

    expect(Object.keys(engine.getContextApi())).toEqual(EXPECTED_LAYOUT_CONTEXT_KEYS)
  })
})
