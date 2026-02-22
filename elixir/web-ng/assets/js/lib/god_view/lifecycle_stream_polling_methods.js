export const godViewLifecycleStreamPollingMethods = {
  startPolling(force = false) {
    if (!this.snapshotUrl) return
    if (this.pollTimer && !force) return
    if (force && this.pollTimer) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
    this.pollSnapshot()
    this.pollTimer = window.setInterval(this.pollSnapshot, this.pollIntervalMs)
  },
  stopPolling() {
    if (!this.pollTimer) return
    window.clearInterval(this.pollTimer)
    this.pollTimer = null
  },
  async pollSnapshot() {
    if (!this.snapshotUrl) return
    if (this.channelJoined && this.lastSnapshotAt > 0) {
      const staleAfterMs = Math.max(this.pollIntervalMs * 2, 10_000)
      if (Date.now() - this.lastSnapshotAt < staleAfterMs) return
    }
    const startedAt = performance.now()
    try {
      const response = await fetch(this.snapshotUrl, {
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
      const revision = Number.isFinite(parsedRevision) ? parsedRevision : this.lastRevision

      const decodeStart = performance.now()
      const rawGraph = this.decodeArrowGraph(new Uint8Array(buffer))
      const topologyStamp = this.graphTopologyStamp(rawGraph)
      const graph = this.prepareGraphLayout(rawGraph, revision, topologyStamp)
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100

      const renderStart = performance.now()
      const previousGraph = this.lastGraph
      this.lastGraph = graph
      if (this.sameTopology(previousGraph, graph, topologyStamp, revision)) {
        this.renderGraph(graph)
      } else {
        this.animateTransition(previousGraph, graph)
      }
      this.lastRevision = revision
      this.lastTopologyStamp = topologyStamp
      this.lastSnapshotAt = Date.now()
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
      const effectiveBitmapMetadata = this.ensureBitmapMetadata(bitmapMetadata, graph.nodes)
      const pipelineStats = this.pipelineStatsFromHeaders(response.headers)
      if (pipelineStats) this.lastPipelineStats = pipelineStats

      this.summary.textContent =
        `snapshot revision=${revisionHeader || "—"} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${buffer.byteLength}B selected=` +
        `${this.selectedNodeIndex === null ? "none" : this.selectedNodeIndex} visible=` +
        `${this.lastVisibleNodeCount}/${graph.nodes.length}`

      this.pushEvent("god_view_stream_stats", {
        schema_version: schemaHeader ? Number(schemaHeader) : null,
        revision: revisionHeader ? Number(revisionHeader) : null,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        generated_at: response.headers.get("x-sr-god-view-generated-at"),
        bitmap_metadata: effectiveBitmapMetadata,
        bytes: buffer.byteLength,
        renderer_mode: this.rendererMode,
        zoom_tier: this.zoomTier,
        zoom_mode: this.zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: this.normalizePipelineStats(pipelineStats || this.lastPipelineStats),
      })
    } catch (error) {
      this.summary.textContent = "snapshot polling error"
      if (!this.channelJoined || this.lastSnapshotAt === 0) {
        this.pushEvent("god_view_stream_error", {
          reason: "poll_error",
          message: `${error}`,
        })
      }
    }
  },
}
