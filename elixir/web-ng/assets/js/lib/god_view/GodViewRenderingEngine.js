import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingMethods} from "./rendering_methods"

export default class GodViewRenderingEngine {
  constructor({state, deps}) {
    this.runtimeContext = createStateBackedContext(state, deps)
    this.contextApi = bindApi(this.runtimeContext, godViewRenderingMethods)
    Object.assign(this.runtimeContext, this.contextApi)
  }

  getContextApi() {
    return this.contextApi
  }
}
