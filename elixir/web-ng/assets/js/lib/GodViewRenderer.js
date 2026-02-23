import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"
import {buildLayoutDeps, buildLifecycleDeps, buildRenderingDeps} from "./god_view/renderer_deps"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
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

  update() {
    if (typeof this.context.state.updated === "function") this.context.state.updated()
  }

  destroy() {
    this.lifecycleController.destroy()
  }
}
