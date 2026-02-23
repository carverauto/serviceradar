import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
    this.context = {
      el,
      pushEvent,
      handleEvent,
      csrfToken:
        options.csrfToken || document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "",
    }

    this.layoutEngine = new GodViewLayoutEngine(this.context)
    this.renderingEngine = new GodViewRenderingEngine(this.context)
    this.lifecycleController = new GodViewLifecycleController(this.context)

    Object.assign(this.context, this.layoutEngine.getContextApi())
    Object.assign(this.context, this.renderingEngine.getContextApi())
    Object.assign(this.context, this.lifecycleController.getContextApi())

    Object.assign(this.context, this.layoutEngine.getSharedApi())
    Object.assign(this.context, this.renderingEngine.getSharedApi())
    Object.assign(this.context, this.lifecycleController.getSharedApi())
  }

  mount() {
    this.lifecycleController.mount()
  }

  update() {
    if (typeof this.context.updated === "function") this.context.updated()
  }

  destroy() {
    this.lifecycleController.destroy()
  }
}
