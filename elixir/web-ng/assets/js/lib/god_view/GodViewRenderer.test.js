import {describe, expect, it, vi} from "vitest"

vi.mock("../god_view/GodViewLayoutEngine", () => ({
  default: class MockGodViewLayoutEngine {
    constructor(_context) {}
    getContextApi() {
      return {
        reshapeGraph: vi.fn(),
        prepareGraphLayout: vi.fn(),
        resolveZoomTier: vi.fn(),
      }
    }
  },
}))

vi.mock("../god_view/GodViewRenderingEngine", () => ({
  default: class MockGodViewRenderingEngine {
    constructor(_context) {}
    getContextApi() {
      return {
        buildVisibleGraphData: vi.fn(),
        renderGraph: vi.fn(),
        stateDisplayName: vi.fn(),
        edgeTopologyClass: vi.fn(),
      }
    }
  },
}))

vi.mock("../god_view/GodViewLifecycleController", () => ({
  default: class MockGodViewLifecycleController {
    constructor(_context) {}
    getContextApi() {
      return {
        initLifecycleState: vi.fn(),
        ensureDeck: vi.fn(),
      }
    }
    mount() {}
    destroy() {}
  },
}))

import GodViewRenderer from "../GodViewRenderer"

describe("GodViewRenderer", () => {
  it("registers context methods from engine context APIs", () => {
    const renderer = new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})

    expect(renderer.context.csrfToken).toEqual("test-token")
    expect(typeof renderer.context.prepareGraphLayout).toEqual("function")
    expect(typeof renderer.context.buildVisibleGraphData).toEqual("function")
    expect(typeof renderer.context.initLifecycleState).toEqual("function")

    expect(typeof renderer.context.renderGraph).toEqual("function")
    expect(typeof renderer.context.stateDisplayName).toEqual("function")
    expect(typeof renderer.context.edgeTopologyClass).toEqual("function")
    expect(typeof renderer.context.ensureDeck).toEqual("function")
  })

  it("update delegates to context.updated when present", () => {
    const renderer = new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})
    renderer.context.updated = vi.fn()

    renderer.update()

    expect(renderer.context.updated).toHaveBeenCalledTimes(1)
  })

  it("mount and destroy delegate to lifecycle controller", () => {
    const renderer = new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})
    const mountSpy = vi.spyOn(renderer.lifecycleController, "mount").mockImplementation(() => {})
    const destroySpy = vi.spyOn(renderer.lifecycleController, "destroy").mockImplementation(() => {})

    renderer.mount()
    renderer.destroy()

    expect(mountSpy).toHaveBeenCalledTimes(1)
    expect(destroySpy).toHaveBeenCalledTimes(1)
  })
})
