import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleStreamPollingMethods = {
  startPolling(force = false) {
    if (!stateRef(this).snapshotUrl) return
    if (stateRef(this).pollTimer && !force) return
    if (force && stateRef(this).pollTimer) {
      window.clearInterval(stateRef(this).pollTimer)
      stateRef(this).pollTimer = null
    }
    this.pollSnapshot()
    stateRef(this).pollTimer = window.setInterval(this.pollSnapshot, stateRef(this).pollIntervalMs)
  },
  stopPolling() {
    if (!stateRef(this).pollTimer) return
    window.clearInterval(stateRef(this).pollTimer)
    stateRef(this).pollTimer = null
  },
  async pollSnapshot() {
    if (!stateRef(this).snapshotUrl) return
    if (stateRef(this).channelJoined && stateRef(this).lastSnapshotAt > 0) {
      const staleAfterMs = Math.max(stateRef(this).pollIntervalMs * 2, 10_000)
      if (Date.now() - stateRef(this).lastSnapshotAt < staleAfterMs) return
    }
    const startedAt = performance.now()
    try {
      const response = await fetch(stateRef(this).snapshotUrl, {
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
      const revision = Number.isFinite(parsedRevision) ? parsedRevision : stateRef(this).lastRevision

      const decodeStart = performance.now()
      const rawGraph = depsRef(this).decodeArrowGraph(new Uint8Array(buffer))
      const topologyStamp = depsRef(this).graphTopologyStamp(rawGraph)
      const graph = depsRef(this).prepareGraphLayout(rawGraph, revision, topologyStamp)
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100

      const renderStart = performance.now()
      const previousGraph = stateRef(this).lastGraph
      stateRef(this).lastGraph = graph
      if (depsRef(this).sameTopology(previousGraph, graph, topologyStamp, revision)) {
        depsRef(this).renderGraph(graph)
      } else {
        depsRef(this).animateTransition(previousGraph, graph)
      }
      stateRef(this).lastRevision = revision
      stateRef(this).lastTopologyStamp = topologyStamp
      stateRef(this).lastSnapshotAt = Date.now()
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
      const effectiveBitmapMetadata = depsRef(this).ensureBitmapMetadata(bitmapMetadata, graph.nodes)
      const pipelineStats = depsRef(this).pipelineStatsFromHeaders(response.headers)
      if (pipelineStats) stateRef(this).lastPipelineStats = pipelineStats

      stateRef(this).summary.textContent =
        `snapshot revision=${revisionHeader || "—"} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${buffer.byteLength}B selected=` +
        `${stateRef(this).selectedNodeIndex === null ? "none" : stateRef(this).selectedNodeIndex} visible=` +
        `${stateRef(this).lastVisibleNodeCount}/${graph.nodes.length}`

      stateRef(this).pushEvent("god_view_stream_stats", {
        schema_version: schemaHeader ? Number(schemaHeader) : null,
        revision: revisionHeader ? Number(revisionHeader) : null,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        generated_at: response.headers.get("x-sr-god-view-generated-at"),
        bitmap_metadata: effectiveBitmapMetadata,
        bytes: buffer.byteLength,
        renderer_mode: stateRef(this).rendererMode,
        zoom_tier: stateRef(this).zoomTier,
        zoom_mode: stateRef(this).zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: depsRef(this).normalizePipelineStats(pipelineStats || stateRef(this).lastPipelineStats),
      })
    } catch (error) {
      stateRef(this).summary.textContent = "snapshot polling error"
      if (!stateRef(this).channelJoined || stateRef(this).lastSnapshotAt === 0) {
        stateRef(this).pushEvent("god_view_stream_error", {
          reason: "poll_error",
          message: `${error}`,
        })
      }
    }
  },
}
