import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleBootstrapCleanupDomMethods} from "./lifecycle_bootstrap_cleanup_dom_methods"

describe("lifecycle_bootstrap_cleanup_dom_methods", () => {
  it("disconnects the topology resize and safe-area mutation observers", () => {
    const originalWindow = globalThis.window
    globalThis.window = {removeEventListener: vi.fn()}
    const resizeObserver = {disconnect: vi.fn()}
    const safeAreaMutationObserver = {disconnect: vi.fn()}
    const state = {
      resizeObserver,
      safeAreaMutationObserver,
      safeAreaResizeTargets: new Set([{id: "safe-area"}]),
      canvas: null,
      mapControls: null,
      themeObserver: null,
      themeMediaQuery: null,
      themeMediaListener: null,
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewLifecycleBootstrapCleanupDomMethods), {
      resizeCanvas: vi.fn(),
      handleWheelZoom: vi.fn(),
      handlePanStart: vi.fn(),
      handleMapControlClick: vi.fn(),
      handlePanMove: vi.fn(),
      handlePanEnd: vi.fn(),
    })

    try {
      ctx.cleanupLifecycleDomListeners()

      expect(resizeObserver.disconnect).toHaveBeenCalledTimes(1)
      expect(state.resizeObserver).toBe(null)
      expect(safeAreaMutationObserver.disconnect).toHaveBeenCalledTimes(1)
      expect(state.safeAreaMutationObserver).toBe(null)
      expect(state.safeAreaResizeTargets).toBe(null)
    } finally {
      globalThis.window = originalWindow
    }
  })
})
