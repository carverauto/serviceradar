import {formatEdgeClassStatus} from "./topology_class_stats"

function captureTopologyRenderState(state) {
  return {
    values: {
      hasAutoFit: state.hasAutoFit,
      hoveredEdgeKey: state.hoveredEdgeKey,
      isProgrammaticViewUpdate: state.isProgrammaticViewUpdate,
      lastDetailsHtml: state.lastDetailsHtml,
      lastGraph: state.lastGraph,
      lastGraphLayerFrame: state.lastGraphLayerFrame,
      lastLayoutKey: state.lastLayoutKey,
      lastVisibleEdgeCount: state.lastVisibleEdgeCount,
      lastVisibleNodeCount: state.lastVisibleNodeCount,
      layoutMode: state.layoutMode,
      layoutRevision: state.layoutRevision,
      managedTopologyDensityConstraintsCache: state.managedTopologyDensityConstraintsCache,
      managedTopologyDensityConstraintsLayoutCache: state.managedTopologyDensityConstraintsLayoutCache,
      managedTopologySceneForMinZoom: state.managedTopologySceneForMinZoom,
      managedTopologySceneMinZoom: state.managedTopologySceneMinZoom,
      managedTopologySceneMinZoomKey: state.managedTopologySceneMinZoomKey,
      managedTopologyVisualDensity: state.managedTopologyVisualDensity,
      packetFlowCache: state.packetFlowCache,
      packetFlowCacheStamp: state.packetFlowCacheStamp,
      pendingClusterFocus: state.pendingClusterFocus,
      pendingViewportProfileKey: state.pendingViewportProfileKey,
      selectedEdgeKey: state.selectedEdgeKey,
      topologyLabelDetailsFallbackIds: state.topologyLabelDetailsFallbackIds,
      topologyRouteDiagnostics: state.topologyRouteDiagnostics,
      viewState: state.viewState,
      viewportProfileKey: state.viewportProfileKey,
      wasmReady: state.wasmReady,
      zoomTier: state.zoomTier,
    },
    layersAtmosphere: state.layers?.atmosphere,
    traversalMaskBuffer: state.traversalMaskBuffer,
    traversalMaskContents: state.traversalMaskBuffer?.slice?.(),
    visibilityMaskBuffer: state.visibilityMaskBuffer,
    visibilityMaskContents: state.visibilityMaskBuffer?.slice?.(),
  }
}

function restoreTopologyRenderState(state, captured) {
  Object.assign(state, captured.values)
  if (state.layers && captured.layersAtmosphere !== undefined) {
    state.layers.atmosphere = captured.layersAtmosphere
  }
  if (captured.traversalMaskBuffer && captured.traversalMaskContents) {
    captured.traversalMaskBuffer.set(captured.traversalMaskContents)
  }
  if (captured.visibilityMaskBuffer && captured.visibilityMaskContents) {
    captured.visibilityMaskBuffer.set(captured.visibilityMaskContents)
  }
  state.traversalMaskBuffer = captured.traversalMaskBuffer
  state.visibilityMaskBuffer = captured.visibilityMaskBuffer
}

function restoreLastGoodRender(context, captured) {
  restoreTopologyRenderState(context.state, captured)
  try {
    if (captured.values.lastGraph) context.deps.renderGraph?.(captured.values.lastGraph)
  } catch (_restoreError) {
    // Preserve the original render failure; the accepted state is restored below.
  }
  restoreTopologyRenderState(context.state, captured)
  try {
    if (captured.values.viewState) {
      context.state.deck?.setProps?.({viewState: captured.values.viewState})
    }
  } catch (_restoreError) {
    // A failed best-effort camera restore must not replace the original error.
  }
  restoreTopologyRenderState(context.state, captured)
}

export const godViewLifecycleStreamSnapshotMethods = {
  async handleSnapshot(msg) {
    const startedAt = performance.now()
    const requestToken = Number(this.state.layoutRequestToken || 0) + 1
    this.state.layoutRequestToken = requestToken
    this.state.latestSnapshotLayoutToken = requestToken
    this.state.pendingSnapshotLayoutToken = requestToken

    try {
      const snapshot = this.parseSnapshotMessage(msg)
      const revision = Number.isFinite(Number(snapshot.revision)) ? Number(snapshot.revision) : this.state.lastRevision

      const bytes = snapshot?.payload
      if (!bytes || bytes.byteLength === 0) throw new Error("missing payload")

      const decodeStart = performance.now()
      const rawGraph = this.deps.decodeArrowGraph(bytes)
      const topologyStamp = this.deps.graphTopologyStamp(rawGraph)
      const graph = await this.deps.prepareGraphLayout(
        rawGraph,
        revision,
        topologyStamp,
        {commit: false},
      )
      if (requestToken !== this.state.latestSnapshotLayoutToken) return
      const unrecoverableLayoutError =
        graph?._layoutMode === "elk-scene-error" ||
        (graph?._layoutError && !graph?._topologyScene)
      if (unrecoverableLayoutError) {
        const message = `${graph?._layoutError || "ELK layout unavailable"}`
        this.state.summary.textContent = "topology layout unavailable"
        this.state.pushEvent("god_view_stream_error", {reason: "layout_error", message})
        return
      }
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100
      const bitmapMetadata = this.deps.ensureBitmapMetadata(snapshot.bitmapMetadata, graph.nodes)

      const renderStart = performance.now()
      const previousGraph = this.state.lastGraph
      const topologyUnchanged = this.deps.sameTopology(previousGraph, graph, topologyStamp, revision)
      const graphProfileKey = graph._topologyScene?.profileKey
      const previousAcceptanceState = captureTopologyRenderState(this.state)
      try {
        if (!topologyUnchanged && !this.state.userCameraLocked) {
          this.state.hasAutoFit = false
        }
        this.state.layoutMode = graph._layoutMode
        this.state.layoutRevision = revision
        this.state.lastLayoutKey = graph._layoutCacheKey ?? null
        this.state.viewportProfileKey = graphProfileKey || this.state.viewportProfileKey
        if (!this.state.pendingViewportProfileKey || this.state.pendingViewportProfileKey === graphProfileKey) {
          this.state.pendingViewportProfileKey = null
        }
        this.state.lastGraph = graph
        if (topologyUnchanged) {
          this.deps.renderGraph(graph)
        } else {
          this.deps.animateTransition(previousGraph, graph)
        }
        const pendingClusterFocus = this.state.pendingClusterFocus
        if (pendingClusterFocus?.expanded === true) {
          const focused = this.deps.focusClusterNeighborhood(graph, pendingClusterFocus.clusterId)
          if (focused) this.state.pendingClusterFocus = null
        }
      } catch (error) {
        restoreLastGoodRender(this, previousAcceptanceState)
        this.state.summary.textContent = "topology render unavailable"
        // deck.gl strips assertion text in a production build, so `${error}` can arrive as a
        // bare "deck.gl: assertion failed." naming nothing. The stack is the only thing that
        // identifies which layer threw, and without it a render error is undiagnosable from
        // the server logs -- which is the only place these are ever read.
        this.state.pushEvent("god_view_stream_error", {
          reason: "render_error",
          message: `${error}`,
          stack: String(error?.stack || ""),
        })
        return
      }
      this.state.lastRevision = revision
      this.state.lastTopologyStamp = topologyStamp
      this.state.lastSnapshotAt = Date.now()
      const visibleNodeCount = Number(this.state.lastVisibleNodeCount || 0)
      const visibleEdgeCount = Number(this.state.lastVisibleEdgeCount || 0)
      const edgeClassStatus = formatEdgeClassStatus(this.state.lastPipelineStats)
      this.state.summary.textContent =
        `schema=${snapshot.schemaVersion} revision=${snapshot.revision} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${bytes.byteLength}B selected=` +
        `${this.state.selectedNodeIndex === null ? "none" : this.state.selectedNodeIndex} visible=` +
        `${visibleNodeCount}/${graph.nodes.length} rendered_edges=${visibleEdgeCount} layout=${graph._layoutMode || "unknown"}` +
        (edgeClassStatus ? ` ${edgeClassStatus}` : "")
      if (graph?._layoutError && graph?._topologyScene) {
        this.state.pushEvent("god_view_stream_error", {
          reason: "layout_error",
          message: `${graph._layoutError}`,
          reused_last_good: true,
        })
      }
      const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
      const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

      this.state.pushEvent("god_view_stream_stats", {
        schema_version: snapshot.schemaVersion,
        revision: snapshot.revision,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        rendered_node_count: visibleNodeCount,
        rendered_edge_count: visibleEdgeCount,
        generated_at: snapshot.generatedAt,
        bitmap_metadata: bitmapMetadata,
        bytes: bytes.byteLength,
        renderer_mode: this.state.rendererMode,
        zoom_tier: this.state.zoomTier,
        zoom_mode: this.state.zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: this.deps.normalizePipelineStats(this.state.lastPipelineStats),
      })
      const pendingProfileKey = this.state.pendingViewportProfileKey
      if (
        pendingProfileKey &&
        pendingProfileKey !== graphProfileKey &&
        typeof this.requestTopologyProfileLayout === "function"
      ) {
        globalThis.queueMicrotask(() => {
          if (this.state.lastGraph !== graph || this.state.pendingViewportProfileKey !== pendingProfileKey) return
          void this.requestTopologyProfileLayout(graph, pendingProfileKey)
        })
      }
    } catch (error) {
      if (requestToken !== this.state.latestSnapshotLayoutToken) return
      this.state.summary.textContent = "snapshot decode failed"
      this.state.pushEvent("god_view_stream_error", {reason: "decode_error", message: `${error}`})
    } finally {
      if (this.state.pendingSnapshotLayoutToken === requestToken) {
        this.state.pendingSnapshotLayoutToken = null
      }
    }
  },
  parseSnapshotMessage(msg) {
    if (msg instanceof ArrayBuffer) {
      return this.parseBinarySnapshotFrame(msg)
    }
    if (msg?.binary instanceof ArrayBuffer) {
      return this.parseBinarySnapshotFrame(msg.binary)
    }
    if (ArrayBuffer.isView(msg)) {
      return this.parseBinarySnapshotFrame(
        msg.buffer.slice(msg.byteOffset, msg.byteOffset + msg.byteLength),
      )
    }
    if (Array.isArray(msg) && msg[0] === "binary" && typeof msg[1] === "string") {
      return this.parseBinarySnapshotFrame(this.base64ToArrayBuffer(msg[1]))
    }
    throw new Error("snapshot payload is not a binary frame")
  },
  base64ToArrayBuffer(b64) {
    const binary = atob(b64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
    return bytes.buffer
  },
  parseBinarySnapshotFrame(buffer) {
    const bytes = new Uint8Array(buffer)
    if (bytes.byteLength < 53) throw new Error("invalid binary snapshot frame")

    const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
    if (magic !== "GVB1") throw new Error("unexpected binary snapshot magic")

    const view = new DataView(buffer)
    const schemaVersion = view.getUint8(4)
    const revision = Number(view.getBigUint64(5, false))
    const generatedAtMs = Number(view.getBigInt64(13, false))
    const rootBytes = view.getUint32(21, false)
    const affectedBytes = view.getUint32(25, false)
    const healthyBytes = view.getUint32(29, false)
    const unknownBytes = view.getUint32(33, false)
    const rootCount = view.getUint32(37, false)
    const affectedCount = view.getUint32(41, false)
    const healthyCount = view.getUint32(45, false)
    const unknownCount = view.getUint32(49, false)
    const generatedAt = Number.isFinite(generatedAtMs)
      ? new Date(generatedAtMs).toISOString()
      : null

    return {
      schemaVersion,
      revision,
      generatedAt,
      bitmapMetadata: {
        root_cause: {bytes: rootBytes, count: rootCount},
        affected: {bytes: affectedBytes, count: affectedCount},
        healthy: {bytes: healthyBytes, count: healthyCount},
        unknown: {bytes: unknownBytes, count: unknownCount},
      },
      payload: bytes.slice(53),
    }
  },
}
