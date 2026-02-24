import {Socket} from "phoenix"

export const godViewLifecycleBootstrapChannelSocketMethods = {
  ensureGodViewSocket() {
    if (!window.godViewSocket) {
      window.godViewSocket = new Socket("/socket", {params: {_csrf_token: this.state.csrfToken}})
      window.godViewSocket.connect()
    }
    return window.godViewSocket
  },
}
