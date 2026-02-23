export const godViewLifecycleBootstrapChannelEventMethods = {
  registerSnapshotChannelEvents(channel) {
    channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") this.state.lastPipelineStats = stats
    })

    channel.on("snapshot", (msg) => this.handleSnapshot(msg))

    channel.on("snapshot_error", (msg) => {
      this.state.summary.textContent = "snapshot stream error"
      this.state.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
      this.pollSnapshot()
    })
  },
  joinSnapshotChannel(channel) {
    channel
      .join()
      .receive("ok", () => {
        this.state.channelJoined = true
        this.state.summary.textContent = "topology channel connected"
        this.startPolling()
      })
      .receive("error", (reason) => {
        this.state.channelJoined = false
        this.state.summary.textContent = "topology channel failed"
        this.state.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
        this.startPolling(true)
      })
  },
}
