import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleStreamSnapshotMethods = {
  handleSnapshot(msg) {
    const startedAt = performance.now()
    try {
      const snapshot = this.parseSnapshotMessage(msg)
      const bytes = snapshot?.payload
      if (!bytes || bytes.byteLength === 0) throw new Error("missing payload")

      const decodeStart = performance.now()
      const rawGraph = depsRef(this).decodeArrowGraph(bytes)
      const revision = Number.isFinite(Number(snapshot.revision)) ? Number(snapshot.revision) : stateRef(this).lastRevision
      const topologyStamp = depsRef(this).graphTopologyStamp(rawGraph)
      const graph = depsRef(this).prepareGraphLayout(rawGraph, revision, topologyStamp)
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100
      const bitmapMetadata = depsRef(this).ensureBitmapMetadata(snapshot.bitmapMetadata, graph.nodes)

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
      stateRef(this).summary.textContent =
        `schema=${snapshot.schemaVersion} revision=${snapshot.revision} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${bytes.byteLength}B selected=` +
        `${stateRef(this).selectedNodeIndex === null ? "none" : stateRef(this).selectedNodeIndex} visible=` +
        `${stateRef(this).lastVisibleNodeCount}/${graph.nodes.length}`
      const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
      const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

      stateRef(this).pushEvent("god_view_stream_stats", {
        schema_version: snapshot.schemaVersion,
        revision: snapshot.revision,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        generated_at: snapshot.generatedAt,
        bitmap_metadata: bitmapMetadata,
        bytes: bytes.byteLength,
        renderer_mode: stateRef(this).rendererMode,
        zoom_tier: stateRef(this).zoomTier,
        zoom_mode: stateRef(this).zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: depsRef(this).normalizePipelineStats(stateRef(this).lastPipelineStats),
      })
    } catch (error) {
      stateRef(this).summary.textContent = "snapshot decode failed"
      stateRef(this).pushEvent("god_view_stream_error", {reason: "decode_error", message: `${error}`})
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
