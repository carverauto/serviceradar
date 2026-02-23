import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapChannelEventMethods = {
  registerSnapshotChannelEvents(channel) {
    channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") stateRef(this).lastPipelineStats = stats
    })

    channel.on("snapshot", (msg) => this.handleSnapshot(msg))

    channel.on("snapshot_error", (msg) => {
      stateRef(this).summary.textContent = "snapshot stream error"
      stateRef(this).pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
      this.pollSnapshot()
    })
  },
  joinSnapshotChannel(channel) {
    channel
      .join()
      .receive("ok", () => {
        stateRef(this).channelJoined = true
        stateRef(this).summary.textContent = "topology channel connected"
        this.startPolling()
      })
      .receive("error", (reason) => {
        stateRef(this).channelJoined = false
        stateRef(this).summary.textContent = "topology channel failed"
        stateRef(this).pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
        this.startPolling(true)
      })
  },
}
