import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleMethods} from "./lifecycle_methods"

export default class GodViewLifecycleController {
  constructor({state, deps}) {
    this.runtimeContext = createStateBackedContext(state, deps)
    this.contextApi = bindApi(this.runtimeContext, godViewLifecycleMethods)
    Object.assign(this.runtimeContext, this.contextApi)
  }

  getContextApi() {
    return this.contextApi
  }

  mount() {
    if (typeof this.contextApi.mounted === "function") this.contextApi.mounted()
  }

  destroy() {
    if (typeof this.contextApi.destroyed === "function") this.contextApi.destroyed()
  }
}
