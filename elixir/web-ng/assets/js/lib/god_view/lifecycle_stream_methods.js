import {tableFromIPC} from "apache-arrow"

export const godViewLifecycleStreamMethods = {
  handleSnapshot(msg) {
    const startedAt = performance.now()
    try {
      const snapshot = this.parseSnapshotMessage(msg)
      const bytes = snapshot?.payload
      if (!bytes || bytes.byteLength === 0) throw new Error("missing payload")

      const decodeStart = performance.now()
      const rawGraph = this.decodeArrowGraph(bytes)
      const revision = Number.isFinite(Number(snapshot.revision)) ? Number(snapshot.revision) : this.lastRevision
      const topologyStamp = this.graphTopologyStamp(rawGraph)
      const graph = this.prepareGraphLayout(rawGraph, revision, topologyStamp)
      const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100
      const bitmapMetadata = this.ensureBitmapMetadata(snapshot.bitmapMetadata, graph.nodes)

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
      this.summary.textContent =
        `schema=${snapshot.schemaVersion} revision=${snapshot.revision} nodes=${graph.nodes.length} ` +
        `edges=${graph.edges.length} payload=${bytes.byteLength}B selected=` +
        `${this.selectedNodeIndex === null ? "none" : this.selectedNodeIndex} visible=` +
        `${this.lastVisibleNodeCount}/${graph.nodes.length}`
      const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
      const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

      this.pushEvent("god_view_stream_stats", {
        schema_version: snapshot.schemaVersion,
        revision: snapshot.revision,
        node_count: graph.nodes.length,
        edge_count: graph.edges.length,
        generated_at: snapshot.generatedAt,
        bitmap_metadata: bitmapMetadata,
        bytes: bytes.byteLength,
        renderer_mode: this.rendererMode,
        zoom_tier: this.zoomTier,
        zoom_mode: this.zoomMode,
        network_ms: networkMs,
        decode_ms: decodeMs,
        render_ms: renderMs,
        pipeline_stats: this.normalizePipelineStats(this.lastPipelineStats),
      })
    } catch (error) {
      this.summary.textContent = "snapshot decode failed"
      this.pushEvent("god_view_stream_error", {reason: "decode_error", message: `${error}`})
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
  decodeArrowGraph(bytes) {
    const table = tableFromIPC(bytes)
    const rowType = table.getChild("row_type")
    const nodeX = table.getChild("node_x")
    const nodeY = table.getChild("node_y")
    const nodeState = table.getChild("node_state")
    const nodeLabel = table.getChild("node_label")
    const nodePps = table.getChild("node_pps")
    const nodeOperUp = table.getChild("node_oper_up")
    const nodeDetails = table.getChild("node_details")
    const edgeSource = table.getChild("edge_source")
    const edgeTarget = table.getChild("edge_target")
    const edgePps = table.getChild("edge_pps")
    const edgeFlowBps = table.getChild("edge_flow_bps")
    const edgeCapacityBps = table.getChild("edge_capacity_bps")
    const edgeLabel = table.getChild("edge_label")

    const nodes = []
    const edges = []
    const edgeSourceIndex = []
    const edgeTargetIndex = []
    const rowCount = table.numRows || 0

    for (let i = 0; i < rowCount; i += 1) {
      const t = rowType?.get(i)
      if (t === 0) {
        const fallbackLabel = `node-${nodes.length + 1}`
        let parsedDetails = {}
        const rawDetails = nodeDetails?.get(i)
        if (typeof rawDetails === "string" && rawDetails.trim() !== "") {
          try {
            parsedDetails = JSON.parse(rawDetails)
          } catch (_err) {
            parsedDetails = {}
          }
        }
        const detailLat = Number(parsedDetails?.geo_lat)
        const detailLon = Number(parsedDetails?.geo_lon)
        nodes.push({
          id: this.normalizeDisplayLabel(parsedDetails?.id, fallbackLabel),
          x: Number(nodeX?.get(i) || 0),
          y: Number(nodeY?.get(i) || 0),
          state: Number(nodeState?.get(i) || 3),
          label: this.normalizeDisplayLabel(nodeLabel?.get(i), fallbackLabel),
          pps: Number(nodePps?.get(i) || 0),
          operUp: Number(nodeOperUp?.get(i) || 0),
          geoLat: Number.isFinite(detailLat) ? detailLat : NaN,
          geoLon: Number.isFinite(detailLon) ? detailLon : NaN,
          details: parsedDetails,
        })
      } else if (t === 1) {
        const source = Number(edgeSource?.get(i) || 0)
        const target = Number(edgeTarget?.get(i) || 0)
        edges.push({
          source,
          target,
          flowPps: Number(edgePps?.get(i) || 0),
          flowBps: Number(edgeFlowBps?.get(i) || 0),
          capacityBps: Number(edgeCapacityBps?.get(i) || 0),
          label: this.normalizeDisplayLabel(edgeLabel?.get(i), ""),
          topologyClass: this.edgeTopologyClassFromLabel(edgeLabel?.get(i) || ""),
        })
        edgeSourceIndex.push(source)
        edgeTargetIndex.push(target)
      }
    }

    return {
      nodes,
      edges,
      edgeSourceIndex: Uint32Array.from(edgeSourceIndex),
      edgeTargetIndex: Uint32Array.from(edgeTargetIndex),
    }
  },
}
