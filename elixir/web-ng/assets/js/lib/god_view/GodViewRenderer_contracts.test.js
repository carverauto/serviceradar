import {describe, expect, it, vi} from "vitest"

import GodViewLayoutEngine from "./GodViewLayoutEngine"
import GodViewRenderingEngine from "./GodViewRenderingEngine"

vi.mock("./lifecycle_methods", () => ({
  godViewLifecycleMethods: {
    mounted() {},
    destroyed() {},
    ensureDeck() {},
  },
}))

import GodViewLifecycleController from "./GodViewLifecycleController"

function duplicateKeys(...objects) {
  const seen = new Set()
  const duplicates = new Set()

  for (const object of objects) {
    for (const key of Object.keys(object)) {
      if (seen.has(key)) duplicates.add(key)
      seen.add(key)
    }
  }

  return [...duplicates].sort()
}

describe("GodViewRenderer contracts", () => {
  it("engine context APIs do not collide on method names", () => {
    const layoutApi = new GodViewLayoutEngine({state: {}, deps: {}}).getContextApi()
    const renderingApi = new GodViewRenderingEngine({state: {}, deps: {}}).getContextApi()
    const lifecycleApi = new GodViewLifecycleController({state: {}, deps: {}}).getContextApi()

    expect(duplicateKeys(layoutApi, renderingApi, lifecycleApi)).toEqual([])
  })

  it("required runtime methods are provided by composed engine APIs", () => {
    const layoutApi = new GodViewLayoutEngine({state: {}, deps: {}}).getContextApi()
    const renderingApi = new GodViewRenderingEngine({state: {}, deps: {}}).getContextApi()
    const lifecycleApi = new GodViewLifecycleController({state: {}, deps: {}}).getContextApi()

    expect(typeof renderingApi.renderGraph).toEqual("function")
    expect(typeof layoutApi.reshapeGraph).toEqual("function")
    expect(typeof lifecycleApi.ensureDeck).toEqual("function")
  })
})
