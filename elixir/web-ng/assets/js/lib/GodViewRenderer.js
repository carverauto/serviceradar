import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
    this.state = {
      el,
      pushEvent,
      handleEvent,
      csrfToken:
        options.csrfToken || document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "",
    }

    this.layoutEngine = new GodViewLayoutEngine(this.state)
    this.renderingEngine = new GodViewRenderingEngine(this.state)
    this.lifecycleController = new GodViewLifecycleController(this.state)

    Object.assign(this.state, this.layoutEngine.getSharedApi())
    Object.assign(this.state, this.renderingEngine.getSharedApi())
    Object.assign(this.state, this.lifecycleController.getSharedApi())
  }

  mount() {
    this.lifecycleController.mount()
  }

  update() {
    if (typeof this.state.updated === "function") this.state.updated()
  }

  destroy() {
    this.lifecycleController.destroy()
  }
}
