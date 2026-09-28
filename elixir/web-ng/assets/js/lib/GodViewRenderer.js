import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"
import {buildLayoutDeps, buildLifecycleDeps, buildRenderingDeps} from "./god_view/renderer_deps"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
    /** @type {{state: import("./god_view/renderer_deps").GodViewState, layout: import("./god_view/renderer_deps").GodViewLayoutApi | {}, rendering: import("./god_view/renderer_deps").GodViewRenderingApi | {}, lifecycle: import("./god_view/renderer_deps").GodViewLifecycleApi | {}}} */
    this.context = {
      state: {
        el,
        pushEvent,
        handleEvent,
        csrfToken:
          options.csrfToken || document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "",
      },
      layout: {},
      rendering: {},
      lifecycle: {},
    }

    const layoutDeps = buildLayoutDeps(this.context)
    const renderingDeps = buildRenderingDeps(this.context)
    const lifecycleDeps = buildLifecycleDeps(this.context)

    this.layoutEngine = new GodViewLayoutEngine({state: this.context.state, deps: layoutDeps})
    this.renderingEngine = new GodViewRenderingEngine({state: this.context.state, deps: renderingDeps})
    this.lifecycleController = new GodViewLifecycleController({state: this.context.state, deps: lifecycleDeps})

    this.context.layout = this.layoutEngine.getContextApi()
    this.context.rendering = this.renderingEngine.getContextApi()
    this.context.lifecycle = this.lifecycleController.getContextApi()
  }

  mount() {
    this.lifecycleController.mount()
  }

  async mountScene(payload, headers) {
    this.context.state.sceneOnly = true
    this.mount()
    const lifecycle = this.context.lifecycle
    // The world owner supplies scene-local callbacks, never global subscriptions.
    lifecycle.registerLifecycleEvents()
    lifecycle.ensureDeck()
    const deadline = performance.now() + 15000
    while (!this.destroyed && this.context.state.rendererMode === "initializing" && performance.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 16))
    }
    if (this.destroyed) throw new Error("Topology detail was closed")
    // The detail fitter needs Deck's actual viewport when it admits labels.
    // Wait for asynchronous device creation before accepting the scene.
    if (this.context.state.rendererMode !== "webgpu") throw new Error("WebGPU is required for topology detail")
    lifecycle.resizeCanvas()
    await lifecycle.handleSnapshot(lifecycle.buildSnapshotFrameFromHttpResponse(payload, headers))
    if (this.destroyed) throw new Error("Topology detail was closed")
    if (this.context.state.rendererMode !== "webgpu" || this.context.state.lastGraph?._layoutMode !== "elk-scene-detail") {
      throw new Error("Topology detail could not be rendered")
    }
  }

  update() {
    if (typeof this.context.state.updated === "function") this.context.state.updated()
  }

  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    this.lifecycleController.destroy()
  }
}
