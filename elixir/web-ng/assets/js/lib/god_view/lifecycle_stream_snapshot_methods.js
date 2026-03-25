export const godViewLifecycleStreamSnapshotMethods = {
  async handleSnapshot(msg) {
    const startedAt = performance.now()
    const requestToken = Number(this.state.layoutRequestToken || 0) + 1
    this.state.layoutRequestToken = requestToken

    try {
      const snapshot = this.parseSnapshotMessage(msg)
      const revision = Number.isFinite(Number(snapshot.revision)) ? Number(snapshot.revision) : this.state.lastRevision
      if (Number.isFinite(revision) && Number.isFinite(this.state.lastRevision) && revision === this.state.lastRevision) {
        this.state.lastSnapshotAt = Date.now()
        return
      }

      const bytes = snapshot?.payload
      if (!bytes || bytes.byteLength === 0) throw new Error("missing payload")

      const decodeStart = performance.now()
      const rawGraph = this.deps.decodeArrowGraph(bytes)
      const topologyStamp = this.deps.graphTopologyStamp(rawGraph)
      const graph = await this.deps.prepareGraphLayout(rawGraph, revision, topologyStamp)
      if (requestToken !== this.state.layoutRequestToken) return
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100
      const bitmapMetadata = this.deps.ensureBitmapMetadata(snapshot.bitmapMetadata, graph.nodes)

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
      this.state.summary.textContent =
        `schema=${snapshot.schemaVersion} revision=${snapshot.revision} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${bytes.byteLength}B selected=` +
        `${this.state.selectedNodeIndex === null ? "none" : this.state.selectedNodeIndex} visible=` +
        `${this.state.lastVisibleNodeCount}/${graph.nodes.length} layout=${graph._layoutMode || "unknown"}`
      const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
      const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

      this.state.pushEvent("god_view_stream_stats", {
        schema_version: snapshot.schemaVersion,
        revision: snapshot.revision,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
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
    } catch (error) {
      this.state.summary.textContent = "snapshot decode failed"
      this.state.pushEvent("god_view_stream_error", {reason: "decode_error", message: `${error}`})
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
