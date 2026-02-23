import {bindApi} from "./api_helpers"
import {godViewRenderingMethods} from "./rendering_methods"

export default class GodViewRenderingEngine {
  constructor(context) {
    this.contextApi = bindApi(context, godViewRenderingMethods)
  }

  getContextApi() {
    return this.contextApi
  }
}
