import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"

const REQUIRED_CONTEXT_METHODS = [
  "renderGraph",
  "reshapeGraph",
  "ensureDeck",
]

function registerApi(context, api, source, ownership) {
  for (const [name, fn] of Object.entries(api)) {
    if (typeof fn !== "function") continue
    if (ownership[name] && ownership[name] !== source) {
      throw new Error(
        `GodViewRenderer API collision for '${name}' between '${ownership[name]}' and '${source}'`,
      )
    }
    context[name] = fn
    ownership[name] = source
  }
}

function assertRequiredContextMethods(context) {
  const missing = REQUIRED_CONTEXT_METHODS.filter((name) => typeof context[name] !== "function")
  if (missing.length > 0) {
    throw new Error(`GodViewRenderer missing required context methods: ${missing.join(", ")}`)
  }
}

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

    const ownership = {}
    registerApi(this.context, this.layoutEngine.getContextApi(), "layout.context", ownership)
    registerApi(this.context, this.renderingEngine.getContextApi(), "rendering.context", ownership)
    registerApi(this.context, this.lifecycleController.getContextApi(), "lifecycle.context", ownership)

    assertRequiredContextMethods(this.context)
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
