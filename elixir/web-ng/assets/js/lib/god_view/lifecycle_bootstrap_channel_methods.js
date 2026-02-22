import {Socket} from "phoenix"

export const godViewLifecycleBootstrapChannelMethods = {
  setupSnapshotChannel() {
    if (!window.godViewSocket) {
      window.godViewSocket = new Socket("/socket", {params: {_csrf_token: this.csrfToken}})
      window.godViewSocket.connect()
    }

    this.channel = window.godViewSocket.channel("topology:god_view", {})
    this.channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") this.lastPipelineStats = stats
    })
    this.channel.on("snapshot", (msg) => this.handleSnapshot(msg))
    this.channel.on("snapshot_error", (msg) => {
      this.summary.textContent = "snapshot stream error"
      this.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
      this.pollSnapshot()
    })
    this.channel
      .join()
      .receive("ok", () => {
        this.channelJoined = true
        this.summary.textContent = "topology channel connected"
        this.startPolling()
      })
      .receive("error", (reason) => {
        this.channelJoined = false
        this.summary.textContent = "topology channel failed"
        this.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
        this.startPolling(true)
      })
  },
}
