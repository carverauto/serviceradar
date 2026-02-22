import {godViewLifecycleMethods} from "./god_view/lifecycle_methods"
import {godViewLayoutMethods} from "./god_view/layout_methods"
import {godViewRenderingMethods} from "./god_view/rendering_methods"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
    this.el = el
    this.pushEvent = pushEvent
    this.handleEvent = handleEvent
    this.csrfToken =
      options.csrfToken || document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
  }

  mount() {
    if (typeof this.mounted === "function") this.mounted()
  }

  update() {
    if (typeof this.updated === "function") this.updated()
  }

  destroy() {
    if (typeof this.destroyed === "function") this.destroyed()
  }
}

Object.assign(
  GodViewRenderer.prototype,
  godViewLifecycleMethods,
  godViewLayoutMethods,
  godViewRenderingMethods,
)
