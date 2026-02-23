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

    expect(typeof renderer.context.prepareGraphLayout).toEqual("function")
    expect(typeof renderer.context.buildVisibleGraphData).toEqual("function")
    expect(typeof renderer.context.initLifecycleState).toEqual("function")
    expect(typeof renderer.context.reshapeGraph).toEqual("function")
    expect(typeof renderer.context.renderGraph).toEqual("function")
    expect(typeof renderer.context.ensureDeck).toEqual("function")
  })
})
