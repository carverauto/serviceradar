export const godViewLifecycleStreamPollingMethods = {
  startPolling(force = false) {
    if (!this.state.snapshotUrl) return
    if (this.state.pollTimer && !force) return
    if (force && this.state.pollTimer) {
      window.clearInterval(this.state.pollTimer)
      this.state.pollTimer = null
    }
    this.pollSnapshot()
    this.state.pollTimer = window.setInterval(this.pollSnapshot, this.state.pollIntervalMs)
  },
  stopPolling() {
    if (!this.state.pollTimer) return
    window.clearInterval(this.state.pollTimer)
    this.state.pollTimer = null
  },
  async pollSnapshot() {
    if (!this.state.snapshotUrl) return
    if (this.state.channelJoined && this.state.lastSnapshotAt > 0) {
      const staleAfterMs = Math.max(this.state.pollIntervalMs * 2, 10_000)
      if (Date.now() - this.state.lastSnapshotAt < staleAfterMs) return
    }
    const startedAt = performance.now()
    try {
      const response = await fetch(this.state.snapshotUrl, {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        headers: {Accept: "application/octet-stream"},
      })
      if (!response.ok) {
        throw new Error(`snapshot_http_${response.status}`)
      }

      const buffer = await response.arrayBuffer()
      if (!buffer || buffer.byteLength === 0) {
        throw new Error("snapshot_empty")
      }

      const revisionHeader = response.headers.get("x-sr-god-view-revision")
      const parsedRevision = revisionHeader ? Number(revisionHeader) : null
      const revision = Number.isFinite(parsedRevision) ? parsedRevision : this.state.lastRevision

      const decodeStart = performance.now()
      const rawGraph = this.deps.decodeArrowGraph(new Uint8Array(buffer))
      const topologyStamp = this.deps.graphTopologyStamp(rawGraph)
      const graph = this.deps.prepareGraphLayout(rawGraph, revision, topologyStamp)
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100

      const renderStart = performance.now()
      const previousGraph = this.state.lastGraph
      this.state.lastGraph = graph
      if (this.deps.sameTopology(previousGraph, graph, topologyStamp, revision)) {
        this.deps.renderGraph(graph)
      } else {
        this.deps.animateTransition(previousGraph, graph)
      }
      this.state.lastRevision = revision
      this.state.lastTopologyStamp = topologyStamp
      this.state.lastSnapshotAt = Date.now()
      const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
      const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

      const schemaHeader = response.headers.get("x-sr-god-view-schema")

      const bitmapMetadata = {
        root_cause: {
          bytes: Number(response.headers.get("x-sr-god-view-bitmap-root-bytes") || 0),
          count: Number(response.headers.get("x-sr-god-view-bitmap-root-count") || 0),
        },
        affected: {
          bytes: Number(response.headers.get("x-sr-god-view-bitmap-affected-bytes") || 0),
          count: Number(response.headers.get("x-sr-god-view-bitmap-affected-count") || 0),
        },
        healthy: {
          bytes: Number(response.headers.get("x-sr-god-view-bitmap-healthy-bytes") || 0),
          count: Number(response.headers.get("x-sr-god-view-bitmap-healthy-count") || 0),
        },
        unknown: {
          bytes: Number(response.headers.get("x-sr-god-view-bitmap-unknown-bytes") || 0),
          count: Number(response.headers.get("x-sr-god-view-bitmap-unknown-count") || 0),
        },
      }
      const effectiveBitmapMetadata = this.deps.ensureBitmapMetadata(bitmapMetadata, graph.nodes)
      const pipelineStats = this.deps.pipelineStatsFromHeaders(response.headers)
      if (pipelineStats) this.state.lastPipelineStats = pipelineStats

      this.state.summary.textContent =
        `snapshot revision=${revisionHeader || "—"} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${buffer.byteLength}B selected=` +
        `${this.state.selectedNodeIndex === null ? "none" : this.state.selectedNodeIndex} visible=` +
        `${this.state.lastVisibleNodeCount}/${graph.nodes.length}`

      this.state.pushEvent("god_view_stream_stats", {
        schema_version: schemaHeader ? Number(schemaHeader) : null,
        revision: revisionHeader ? Number(revisionHeader) : null,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        generated_at: response.headers.get("x-sr-god-view-generated-at"),
        bitmap_metadata: effectiveBitmapMetadata,
        bytes: buffer.byteLength,
        renderer_mode: this.state.rendererMode,
        zoom_tier: this.state.zoomTier,
        zoom_mode: this.state.zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: this.deps.normalizePipelineStats(pipelineStats || this.state.lastPipelineStats),
      })
    } catch (error) {
      this.state.summary.textContent = "snapshot polling error"
      if (!this.state.channelJoined || this.state.lastSnapshotAt === 0) {
        this.state.pushEvent("god_view_stream_error", {
          reason: "poll_error",
          message: `${error}`,
        })
      }
    }
  },
}
