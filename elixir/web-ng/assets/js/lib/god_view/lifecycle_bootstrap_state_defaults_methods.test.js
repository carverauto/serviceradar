import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapStateDefaultsMethods} from "./lifecycle_bootstrap_state_defaults_methods"

describe("lifecycle_bootstrap_state_defaults_methods", () => {
  it("initLifecycleState hides endpoint topology by default", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapStateDefaultsMethods))

    ctx.initLifecycleState()

    expect(state.topologyLayers).toEqual({
      backbone: true,
      inferred: false,
      endpoints: false,
      mtr_paths: true,
    })
  })
})
