export const godViewLifecycleBootstrapChannelEventMethods = {
  setClusterExpanded(clusterId, expanded) {
    const normalized = typeof clusterId === "string" ? clusterId.trim() : ""
    if (normalized === "") return
    if (expanded === true) this.ensureEndpointsLayerForClusterExpand()
    if (!this.state.channel) return
    this.state.pendingClusterFocus =
      expanded === true && !this.state.userCameraLocked
        ? {clusterId: normalized, expanded: true}
        : null
    if (!this.state.userCameraLocked) this.state.hasAutoFit = false
    this.state.channel.push("cluster:set_expanded", {
      cluster_id: normalized,
      expanded: expanded === true,
    })
  },
  ensureEndpointsLayerForClusterExpand() {
    const current = this.state.topologyLayers || {}
    if (current.endpoints === true) return

    this.state.topologyLayers = {...current, endpoints: true}
    if (typeof this.state.pushEvent === "function") {
      this.state.pushEvent("enable_attachment_layers", {})
    }
  },
  collapseAllClusters() {
    if (!this.state.channel) return
    this.state.pendingClusterFocus = null
    this.state.channel.push("cluster:collapse_all", {})
  },
  registerSnapshotChannelEvents(channel) {
    channel.on("snapshot_meta", (msg) => {
      const stats = msg?.pipeline_stats || msg?.pipelineStats
      if (stats && typeof stats === "object") this.state.lastPipelineStats = stats
    })

    channel.on("snapshot", (msg) => this.handleSnapshot(msg))

    channel.on("snapshot_error", (msg) => {
      this.state.summary.textContent = this.hasHydratedSnapshot()
        ? "snapshot stream error"
        : "waiting for topology snapshot"
      this.reportSnapshotStartupError(msg?.reason || "snapshot_error")
      if (!this.state.lastGraph) this.bootstrapLatestSnapshot()
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
        this.state.summary.textContent = this.hasHydratedSnapshot()
          ? "topology channel failed"
          : "waiting for topology channel"
        this.reportSnapshotStartupError(reason?.reason || "join_failed")
        this.bootstrapLatestSnapshot()
        this.scheduleChannelReconnect()
      })
  },
  handleChannelDown(reason) {
    this.state.channelJoined = false
    this.state.summary.textContent = this.hasHydratedSnapshot()
      ? "topology channel disconnected"
      : "waiting for topology channel"
    this.reportSnapshotStartupError(reason)
    this.bootstrapLatestSnapshot()
    this.scheduleChannelReconnect()
  },
  hasHydratedSnapshot() {
    return Boolean(this.state.lastGraph)
  },
  reportSnapshotStartupError(reason, extra = {}) {
    const payload = {
      ...extra,
      reason: typeof reason === "string" && reason.trim() !== "" ? reason : "snapshot_error",
    }

    if (this.hasHydratedSnapshot()) {
      this.state.pushEvent("god_view_stream_error", payload)
    } else {
      this.state.pushEvent("god_view_stream_retrying", payload)
    }
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
