import {describe, expect, it} from "vitest"

import GodViewRenderingEngine from "./GodViewRenderingEngine"
import {godViewRenderingMethods} from "./rendering_methods"

describe("GodViewRenderingEngine API contract", () => {
  it("getContextApi exposes all rendering methods", () => {
    const engine = new GodViewRenderingEngine({state: {}, deps: {}})

    expect(Object.keys(engine.getContextApi())).toEqual(Object.keys(godViewRenderingMethods))
  })
})
