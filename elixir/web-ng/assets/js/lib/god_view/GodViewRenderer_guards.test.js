import {describe, expect, it, vi} from "vitest"

async function loadRendererWithMocks({layoutApi = {}, renderingApi = {}, lifecycleApi = {}} = {}) {
  vi.resetModules()

  vi.doMock("../god_view/GodViewLayoutEngine", () => ({
    default: class MockGodViewLayoutEngine {
      constructor(_context) {}
      getContextApi() {
        return layoutApi
      }
    },
  }))

  vi.doMock("../god_view/GodViewRenderingEngine", () => ({
    default: class MockGodViewRenderingEngine {
      constructor(_context) {}
      getContextApi() {
        return renderingApi
      }
    },
  }))

  vi.doMock("../god_view/GodViewLifecycleController", () => ({
    default: class MockGodViewLifecycleController {
      constructor(_context) {}
      getContextApi() {
        return lifecycleApi
      }
      mount() {}
      destroy() {}
    },
  }))

  const mod = await import("../GodViewRenderer")
  return mod.default
}

describe("GodViewRenderer guards", () => {
  it("throws when required context methods are missing", async () => {
    const GodViewRenderer = await loadRendererWithMocks({
      layoutApi: {reshapeGraph: vi.fn()},
      renderingApi: {renderGraph: vi.fn()},
      lifecycleApi: {},
    })

    expect(() => new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})).toThrow(
      "missing required context methods",
    )
  })

  it("throws on API collisions between engine context APIs", async () => {
    const GodViewRenderer = await loadRendererWithMocks({
      layoutApi: {reshapeGraph: vi.fn(), duplicateKey: vi.fn()},
      renderingApi: {renderGraph: vi.fn(), duplicateKey: vi.fn()},
      lifecycleApi: {ensureDeck: vi.fn()},
    })

    expect(() => new GodViewRenderer({}, vi.fn(), vi.fn(), {csrfToken: "test-token"})).toThrow(
      "API collision",
    )
  })
})
