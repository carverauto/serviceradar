import {Socket} from "phoenix"

export const godViewLifecycleBootstrapChannelSocketMethods = {
  ensureGodViewSocket() {
    if (!window.godViewSocket) {
      window.godViewSocket = new Socket("/socket", {params: {_csrf_token: stateRef(this).csrfToken}})
      window.godViewSocket.connect()
    }
    return window.godViewSocket
  },
}
import {depsRef, stateRef} from "./runtime_refs"
