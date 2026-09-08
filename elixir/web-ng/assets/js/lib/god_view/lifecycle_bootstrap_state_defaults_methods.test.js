import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapStateDefaultsMethods} from "./lifecycle_bootstrap_state_defaults_methods"

describe("lifecycle_bootstrap_state_defaults_methods", () => {
  it("initLifecycleState shows the attachment plane by default and keeps inferred off", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapStateDefaultsMethods))

    ctx.initLifecycleState()

    // Most infrastructure has no backbone adjacency at all -- its only links are
    // attachment-class -- so defaulting `endpoints` off drew genuinely connected
    // devices as isolated dots until something flipped the layer on. `inferred`
    // stays off: it is low-confidence segment data and belongs behind a toggle.
    expect(state.topologyLayers).toEqual({
      backbone: true,
      inferred: false,
      endpoints: true,
      mtr_paths: true,
    })
    expect(state.managedTopologyCameraBaseMinZoom).toEqual(-2)
    expect(state.managedTopologySceneMinZoom).toBeNull()
    expect(state.managedTopologySceneMinZoomKey).toBeNull()
    expect(state.managedTopologySceneForMinZoom).toBeNull()
    expect(state.managedTopologyCameraErrorActive).toBe(false)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBeNull()
  })
})
