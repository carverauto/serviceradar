import {describe, expect, it, vi} from "vitest"

vi.mock("phoenix", () => ({
  Socket: class MockSocket {},
}))

vi.mock("../../wasm/god_view_exec_runtime", () => ({
  GodViewWasmEngine: class MockGodViewWasmEngine {
    static async init() {
      return null
    }
  },
}))

import GodViewRenderer from "../GodViewRenderer"

describe("GodViewRenderer real-engine smoke", () => {
  it("constructs real engines and registers composed context API", () => {
    const renderer = new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})

    expect(typeof renderer.context.layout.prepareGraphLayout).toEqual("function")
    expect(typeof renderer.context.rendering.buildVisibleGraphData).toEqual("function")
    expect(typeof renderer.context.lifecycle.initLifecycleState).toEqual("function")
    expect(typeof renderer.context.layout.reshapeGraph).toEqual("function")
    expect(typeof renderer.context.rendering.renderGraph).toEqual("function")
    expect(typeof renderer.context.lifecycle.ensureDeck).toEqual("function")
  })
})
