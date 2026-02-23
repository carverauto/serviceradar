import {godViewLifecycleBootstrapChannelSocketMethods} from "./lifecycle_bootstrap_channel_socket_methods"
import {godViewLifecycleBootstrapChannelEventMethods} from "./lifecycle_bootstrap_channel_event_methods"

const godViewLifecycleBootstrapChannelCoreMethods = {
  setupSnapshotChannel() {
    const socket = this.ensureGodViewSocket()
    this.state.channel = socket.channel("topology:god_view", {})
    this.registerSnapshotChannelEvents(this.state.channel)
    this.joinSnapshotChannel(this.state.channel)
  },
}

export const godViewLifecycleBootstrapChannelMethods = Object.assign(
  {},
  godViewLifecycleBootstrapChannelCoreMethods,
  godViewLifecycleBootstrapChannelSocketMethods,
  godViewLifecycleBootstrapChannelEventMethods,
)
