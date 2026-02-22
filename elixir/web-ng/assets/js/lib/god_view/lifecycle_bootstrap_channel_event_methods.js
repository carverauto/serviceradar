export const godViewLifecycleBootstrapChannelEventMethods = {
  registerSnapshotChannelEvents(channel) {
    channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") this.lastPipelineStats = stats
    })

    channel.on("snapshot", (msg) => this.handleSnapshot(msg))

    channel.on("snapshot_error", (msg) => {
      this.summary.textContent = "snapshot stream error"
      this.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
      this.pollSnapshot()
    })
  },
  joinSnapshotChannel(channel) {
    channel
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
