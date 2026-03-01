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
    })

    channel.onError?.(() => this.handleChannelDown("channel_error"))
    channel.onClose?.(() => this.handleChannelDown("channel_close"))
  },
  joinSnapshotChannel(channel) {
    channel
      .join()
      .receive("ok", () => {
        this.state.channelJoined = true
        this.state.channelReconnectAttempt = 0
        this.clearChannelReconnectTimer()
        this.state.summary.textContent = "topology channel connected"
      })
      .receive("error", (reason) => {
        this.state.channelJoined = false
        this.state.summary.textContent = "topology channel failed"
        this.state.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
        this.scheduleChannelReconnect()
      })
  },
  handleChannelDown(reason) {
    this.state.channelJoined = false
    this.state.summary.textContent = "topology channel disconnected"
    this.state.pushEvent("god_view_stream_error", {reason})
    this.scheduleChannelReconnect()
  },
  scheduleChannelReconnect() {
    if (this.state.channelReconnectTimer) return

    const attempt = Number(this.state.channelReconnectAttempt || 0)
    const baseMs = Number(this.state.channelReconnectBaseMs || 1000)
    const maxMs = Number(this.state.channelReconnectMaxMs || 10000)
    const delayMs = Math.min(baseMs * (attempt + 1), maxMs)

    this.state.channelReconnectTimer = window.setTimeout(() => {
      this.state.channelReconnectTimer = null
      this.state.channelReconnectAttempt = attempt + 1
      this.reconnectSnapshotChannel()
    }, delayMs)
  },
  reconnectSnapshotChannel() {
    try {
      if (this.state.channel) this.state.channel.leave()
    } catch (_err) {
      // best effort
    }
    this.setupSnapshotChannel()
  },
  clearChannelReconnectTimer() {
    if (!this.state.channelReconnectTimer) return
    window.clearTimeout(this.state.channelReconnectTimer)
    this.state.channelReconnectTimer = null
  }
}
