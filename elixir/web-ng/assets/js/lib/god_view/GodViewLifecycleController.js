import {bindApi} from "./api_helpers"
import {godViewLifecycleMethods} from "./lifecycle_methods"

export default class GodViewLifecycleController {
  constructor(context) {
    this.contextApi = bindApi(context, godViewLifecycleMethods)
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
