import {tableFromIPC} from "apache-arrow"

import * as d3 from "d3"
import {COORDINATE_SYSTEM, Deck, OrthographicView} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

import PacketFlowLayer from "../../lib/deckgl/PacketFlowLayer"
import {GodViewWasmEngine} from "../../wasm/god_view_exec_runtime"

export default {
    mounted() {
      this.canvas = null
      this.summary = null
      this.details = null
      this.deck = null
      this.channel = null
      this.rendererMode = "initializing"
      this.filters = {root_cause: true, affected: true, healthy: true, unknown: true}
      this.lastGraph = null
      this.wasmEngine = null
      this.wasmReady = false
      this.selectedNodeIndex = null
      this.hoveredEdgeKey = null
      this.selectedEdgeKey = null
      this.pendingAnimationFrame = null
      this.zoomMode = "local"
      this.zoomTier = "local"
      this.hasAutoFit = false
      this.userCameraLocked = false
      this.dragState = null
      this.isProgrammaticViewUpdate = false
      this.lastSnapshotAt = 0
      this.channelJoined = false
      this.lastVisibleNodeCount = 0
      this.lastVisibleEdgeCount = 0
      this.pollTimer = null
      this.animationTimer = null
      this.animationPhase = 0
      this.layers = {mantle: true, crust: true, atmosphere: true, security: true}
      this.topologyLayers = {backbone: true, inferred: false, endpoints: false}
      this.lastPipelineStats = null
      this.layoutMode = "auto"
      this.layoutRevision = null
      this.lastRevision = null
      this.lastTopologyStamp = null
      this.snapshotUrl = this.el.dataset.url || null
      this.pollIntervalMs = Number.parseInt(this.el.dataset.intervalMs || "5000", 10) || 5000
      this.visual = {
        bg: [10, 10, 10, 255],
        mantleEdge: [42, 42, 42, 170],
        crustArc: [214, 97, 255, 180],
        atmosphereParticle: [0, 224, 255, 185],
        nodeRoot: [255, 64, 64, 255],
        nodeAffected: [255, 162, 50, 255],
        nodeHealthy: [0, 224, 255, 255],
        nodeUnknown: [122, 141, 168, 255],
        label: [226, 232, 240, 230],
        edgeLabel: [148, 163, 184, 220],
        pulse: [255, 64, 64, 220],
      }
      this.viewState = {
        target: [320, 160, 0],
        zoom: 1.4,
        minZoom: -2,
        maxZoom: 5,
      }

      this.ensureDOM = this.ensureDOM.bind(this)
      this.resizeCanvas = this.resizeCanvas.bind(this)
      this.renderGraph = this.renderGraph.bind(this)
      this.ensureDeck = this.ensureDeck.bind(this)
      this.pollSnapshot = this.pollSnapshot.bind(this)
      this.startPolling = this.startPolling.bind(this)
      this.stopPolling = this.stopPolling.bind(this)
      this.visibilityMask = this.visibilityMask.bind(this)
      this.computeTraversalMask = this.computeTraversalMask.bind(this)
      this.handlePick = this.handlePick.bind(this)
      this.animateTransition = this.animateTransition.bind(this)
      this.parseSnapshotMessage = this.parseSnapshotMessage.bind(this)
      this.resolveZoomTier = this.resolveZoomTier.bind(this)
      this.setZoomTier = this.setZoomTier.bind(this)
      this.reshapeGraph = this.reshapeGraph.bind(this)
      this.reclusterByState = this.reclusterByState.bind(this)
      this.reclusterByGrid = this.reclusterByGrid.bind(this)
      this.clusterEdges = this.clusterEdges.bind(this)
      this.autoFitViewState = this.autoFitViewState.bind(this)
      this.ensureBitmapMetadata = this.ensureBitmapMetadata.bind(this)
      this.buildBitmapFallbackMetadata = this.buildBitmapFallbackMetadata.bind(this)
      this.startAnimationLoop = this.startAnimationLoop.bind(this)
      this.stopAnimationLoop = this.stopAnimationLoop.bind(this)
      this.buildPacketFlowInstances = this.buildPacketFlowInstances.bind(this)
      this.prepareGraphLayout = this.prepareGraphLayout.bind(this)
      this.shouldUseGeoLayout = this.shouldUseGeoLayout.bind(this)
      this.projectGeoLayout = this.projectGeoLayout.bind(this)
      this.forceDirectedLayout = this.forceDirectedLayout.bind(this)
      this.renderSelectionDetails = this.renderSelectionDetails.bind(this)
      this.geoGridData = this.geoGridData.bind(this)
      this.getNodeTooltip = this.getNodeTooltip.bind(this)
      this.handleHover = this.handleHover.bind(this)
      this.handleWheelZoom = this.handleWheelZoom.bind(this)
      this.handlePanStart = this.handlePanStart.bind(this)
      this.handlePanMove = this.handlePanMove.bind(this)
      this.handlePanEnd = this.handlePanEnd.bind(this)

      this.ensureDOM()
      this.resizeCanvas()
      window.addEventListener("resize", this.resizeCanvas)
      this.canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
      this.canvas.addEventListener("pointerdown", this.handlePanStart)
      window.addEventListener("pointermove", this.handlePanMove)
      window.addEventListener("pointerup", this.handlePanEnd)
      window.addEventListener("pointercancel", this.handlePanEnd)
      this.startAnimationLoop()
      GodViewWasmEngine.init()
        .then((engine) => {
          this.wasmEngine = engine
          this.wasmReady = true
        })
        .catch((_err) => {
          this.wasmReady = false
          this.wasmEngine = null
        })
      this.handleEvent("god_view:set_filters", ({filters}) => {
        if (filters && typeof filters === "object") {
          this.filters = {
            root_cause: filters.root_cause !== false,
            affected: filters.affected !== false,
            healthy: filters.healthy !== false,
            unknown: filters.unknown !== false,
          }
          if (this.lastGraph) this.renderGraph(this.lastGraph)
        }
      })
      this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
        const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
        this.zoomMode = normalized

        if (!this.deck) return

        if (normalized === "auto") {
          this.setZoomTier(this.resolveZoomTier(this.viewState.zoom || 0), true)
          return
        }

        const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
        this.viewState = {
          ...this.viewState,
          zoom: zoomByTier[normalized] || this.viewState.zoom,
        }
        this.userCameraLocked = true
        this.isProgrammaticViewUpdate = true
        this.deck.setProps({viewState: this.viewState})
        this.setZoomTier(normalized, true)
      })
      this.handleEvent("god_view:set_layers", ({layers}) => {
        if (layers && typeof layers === "object") {
          this.layers = {
            mantle: layers.mantle !== false,
            crust: layers.crust !== false,
            atmosphere: layers.atmosphere !== false,
            security: layers.security !== false,
          }
          if (this.lastGraph) this.renderGraph(this.lastGraph)
        }
      })
      this.handleEvent("god_view:set_topology_layers", ({layers}) => {
        if (layers && typeof layers === "object") {
          this.topologyLayers = {
            backbone: layers.backbone !== false,
            inferred: layers.inferred === true,
            endpoints: layers.endpoints === true,
          }
          if (this.lastGraph) this.renderGraph(this.lastGraph)
        }
      })

      if (!window.godViewSocket) {
        window.godViewSocket = new Socket("/socket", {params: {_csrf_token: csrfToken}})
        window.godViewSocket.connect()
      }

      this.channel = window.godViewSocket.channel("topology:god_view", {})
      this.channel.on("snapshot_meta", (msg) => {
        const stats = msg?.pipeline_stats || msg?.pipelineStats
        if (stats && typeof stats === "object") this.lastPipelineStats = stats
      })
      this.channel.on("snapshot", (msg) => this.handleSnapshot(msg))
      this.channel.on("snapshot_error", (msg) => {
        this.summary.textContent = "snapshot stream error"
        this.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
        this.pollSnapshot()
      })
      this.channel
        .join()
        .receive("ok", () => {
          this.channelJoined = true
          this.summary.textContent = "topology channel connected"
          this.startPolling()
        })
        .receive("error", (reason) => {
          this.channelJoined = false
          this.summary.textContent = "topology channel failed"
          this.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
          this.startPolling(true)
        })
    },
    destroyed() {
      window.removeEventListener("resize", this.resizeCanvas)
      if (this.canvas) this.canvas.removeEventListener("wheel", this.handleWheelZoom)
      if (this.canvas) this.canvas.removeEventListener("pointerdown", this.handlePanStart)
      window.removeEventListener("pointermove", this.handlePanMove)
      window.removeEventListener("pointerup", this.handlePanEnd)
      window.removeEventListener("pointercancel", this.handlePanEnd)
      this.stopAnimationLoop()
      this.stopPolling()
      if (this.channel) {
        this.channel.leave()
        this.channel = null
      }
      if (this.pendingAnimationFrame) {
        cancelAnimationFrame(this.pendingAnimationFrame)
        this.pendingAnimationFrame = null
      }
      if (this.deck) {
        this.deck.finalize()
        this.deck = null
      }
    },
    startAnimationLoop() {
      if (this.animationTimer) return
      const tick = () => {
        this.animationPhase = performance.now() / 1000
        if (this.deck && this.lastGraph) {
          try {
            this.renderGraph(this.lastGraph)
          } catch (error) {
            if (this.summary) this.summary.textContent = `animation render error: ${String(error)}`
          }
        }
        this.animationTimer = window.requestAnimationFrame(tick)
      }
      this.animationTimer = window.requestAnimationFrame(tick)
    },
    stopAnimationLoop() {
      if (!this.animationTimer) return
      window.cancelAnimationFrame(this.animationTimer)
      this.animationTimer = null
    },
    handlePanStart(event) {
      if (!this.deck) return
      if (event.button !== 0) return

      event.preventDefault()
      this.dragState = {
        pointerId: event.pointerId,
        lastX: Number(event.clientX || 0),
        lastY: Number(event.clientY || 0),
      }
      this.canvas.style.cursor = "grabbing"
      if (typeof this.canvas.setPointerCapture === "function") {
        try {
          this.canvas.setPointerCapture(event.pointerId)
        } catch (_err) {
          // Ignore capture failures and continue with window listeners.
        }
      }
    },
    handlePanMove(event) {
      if (!this.deck || !this.dragState) return
      if (event.pointerId !== this.dragState.pointerId) return

      event.preventDefault()
      const clientX = Number(event.clientX || 0)
      const clientY = Number(event.clientY || 0)
      const dx = clientX - this.dragState.lastX
      const dy = clientY - this.dragState.lastY
      this.dragState.lastX = clientX
      this.dragState.lastY = clientY

      const zoom = Number(this.viewState.zoom || 0)
      const scale = Math.max(0.0001, 2 ** zoom)
      const [targetX = 0, targetY = 0, targetZ = 0] = this.viewState.target || [0, 0, 0]

      this.viewState = {
        ...this.viewState,
        target: [targetX - dx / scale, targetY - dy / scale, targetZ],
      }
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
    },
    handlePanEnd(event) {
      if (!this.dragState) return
      if (event && event.pointerId !== this.dragState.pointerId) return

      if (this.canvas && typeof this.canvas.releasePointerCapture === "function") {
        try {
          this.canvas.releasePointerCapture(this.dragState.pointerId)
        } catch (_err) {
          // Ignore capture release failures.
        }
      }
      this.dragState = null
      if (this.canvas) this.canvas.style.cursor = "grab"
    },
    handleWheelZoom(event) {
      if (!this.deck) return
      event.preventDefault()

      const delta = Number(event.deltaY || 0)
      const direction = delta > 0 ? -1 : 1
      const zoomStep = 0.12
      const nextZoom = (this.viewState.zoom || 0) + direction * zoomStep
      const clamped = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, nextZoom))

      this.viewState = {...this.viewState, zoom: clamped}
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      if (this.zoomMode === "auto") {
        this.setZoomTier(this.resolveZoomTier(clamped), true)
      }
    },
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
    ensureDOM() {
      if (this.canvas && this.summary) return

      this.el.innerHTML = ""
      this.el.classList.add("relative")
      this.canvas = document.createElement("canvas")
      this.canvas.className = "h-full w-full rounded border border-base-300 bg-neutral"
      this.canvas.style.cursor = "grab"

      this.summary = document.createElement("div")
      this.summary.className =
        "pointer-events-none absolute bottom-2 left-2 rounded bg-base-100/85 px-2 py-1 text-[11px] opacity-90"
      this.summary.textContent = "waiting for snapshot..."

      this.details = document.createElement("div")
      this.details.className =
        "absolute left-2 top-2 z-30 max-w-sm whitespace-pre-line rounded border border-primary/30 bg-base-100/95 px-3 py-2 text-xs shadow-xl hidden"
      this.details.textContent = "Select a node for details"
      this.details.addEventListener("click", (event) => {
        const action = event.target?.closest?.("[data-node-index]")
        if (!action) return
        const nextIndex = Number(action.getAttribute("data-node-index"))
        if (!Number.isFinite(nextIndex)) return
        event.preventDefault()
        this.focusNodeByIndex(nextIndex, true)
      })
      this.el.addEventListener("click", (event) => {
        const action = event.target?.closest?.(".deck-tooltip [data-node-index]")
        if (!action) return
        const nextIndex = Number(action.getAttribute("data-node-index"))
        if (!Number.isFinite(nextIndex)) return
        event.preventDefault()
        event.stopPropagation()
        this.focusNodeByIndex(nextIndex, true)
      })

      this.el.appendChild(this.canvas)
      this.el.appendChild(this.summary)
      this.el.appendChild(this.details)
    },
    resizeCanvas() {
      if (!this.canvas) return
      const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
      const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
      this.canvas.style.width = `${width}px`
      this.canvas.style.height = `${height}px`
      if (this.deck) {
        this.deck.setProps({width, height})
        this.deck.redraw(true)
      }
    },
    ensureDeck() {
      if (this.deck) return
      this.ensureDOM()
      const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
      const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
      const mode = navigator.gpu ? "webgpu" : "webgl"
      this.rendererMode = mode

      try {
        this.deck = new Deck({
          canvas: this.canvas,
          width,
          height,
          views: new OrthographicView({id: "god-view-ortho"}),
          controller: {
            dragPan: true,
            dragRotate: false,
            scrollZoom: true,
            doubleClickZoom: false,
            touchZoom: true,
            touchRotate: false,
            keyboard: false,
          },
          useDevicePixels: true,
          initialViewState: this.viewState,
          parameters: {
            clearColor: this.visual.bg,
            blend: true,
            blendFunc: [770, 771],
          },
          getTooltip: this.getNodeTooltip,
          onHover: this.handleHover,
          onClick: this.handlePick,
          onViewStateChange: ({viewState}) => {
            this.viewState = viewState
            if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
            this.isProgrammaticViewUpdate = false
            if (this.zoomMode === "auto") {
              this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
            }
          },
        })
      } catch (_error) {
        this.rendererMode = "webgl-fallback"
        this.deck = new Deck({
          canvas: this.canvas,
          width,
          height,
          views: new OrthographicView({id: "god-view-ortho"}),
          controller: {
            dragPan: true,
            dragRotate: false,
            scrollZoom: true,
            doubleClickZoom: false,
            touchZoom: true,
            touchRotate: false,
            keyboard: false,
          },
          useDevicePixels: true,
          initialViewState: this.viewState,
          parameters: {
            clearColor: this.visual.bg,
            blend: true,
            blendFunc: [770, 771],
          },
          getTooltip: this.getNodeTooltip,
          onHover: this.handleHover,
          onClick: this.handlePick,
          onViewStateChange: ({viewState}) => {
            this.viewState = viewState
            if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
            this.isProgrammaticViewUpdate = false
            if (this.zoomMode === "auto") {
              this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
            }
          },
        })
      }
    },
    resolveZoomTier(zoom) {
      if (zoom < -0.3) return "global"
      if (zoom < 1.1) return "regional"
      return "local"
    },
    setZoomTier(nextTier, forceRender) {
      if (!nextTier) return
      if (!forceRender && this.zoomTier === nextTier) return
      this.zoomTier = nextTier
      if (nextTier !== "local") this.selectedNodeIndex = null
      if (this.lastGraph) this.renderGraph(this.lastGraph)
    },
    reshapeGraph(graph) {
      const tier = this.zoomMode === "auto" ? this.zoomTier : this.zoomMode
      if (tier === "local") return {shape: "local", ...graph}
      if (tier === "global") return this.reclusterByState(graph)
      return this.reclusterByGrid(graph)
    },
    reclusterByState(graph) {
      const clusters = new Map()
      const clusterByNode = new Array(graph.nodes.length)

      graph.nodes.forEach((node, index) => {
        const key = `state:${node.state}`
        const existing = clusters.get(key) || {
          id: key,
          sumX: 0,
          sumY: 0,
          count: 0,
          sumPps: 0,
          upCount: 0,
          downCount: 0,
          stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
          sampleNode: null,
        }
        existing.sumX += node.x
        existing.sumY += node.y
        existing.count += 1
        existing.sumPps += Number(node.pps || 0)
        if (Number(node.operUp) === 1) existing.upCount += 1
        if (Number(node.operUp) === 2) existing.downCount += 1
        existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
        if (!existing.sampleNode && node.details) existing.sampleNode = node
        clusters.set(key, existing)
        clusterByNode[index] = key
      })

      const nodes = Array.from(clusters.values()).map((cluster) => ({
        id: cluster.id,
        x: cluster.sumX / cluster.count,
        y: cluster.sumY / cluster.count,
        state: Number(cluster.id.split(":")[1]),
        clusterCount: cluster.count,
        pps: cluster.sumPps,
        operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
        label: `${this.stateDisplayName(Number(cluster.id.split(":")[1]))} Cluster`,
        details: this.clusterDetails(cluster, "global"),
      }))

      const edges = this.clusterEdges(graph.edges, clusterByNode)
      return {shape: "global", nodes, edges}
    },
    reclusterByGrid(graph) {
      const cell = 180
      const clusters = new Map()
      const clusterByNode = new Array(graph.nodes.length)

      graph.nodes.forEach((node, index) => {
        const gx = Math.floor(node.x / cell)
        const gy = Math.floor(node.y / cell)
        const key = `grid:${gx}:${gy}`
        const existing = clusters.get(key) || {
          id: key,
          sumX: 0,
          sumY: 0,
          count: 0,
          sumPps: 0,
          upCount: 0,
          downCount: 0,
          stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
          sampleNode: null,
        }
        existing.sumX += node.x
        existing.sumY += node.y
        existing.count += 1
        existing.sumPps += Number(node.pps || 0)
        if (Number(node.operUp) === 1) existing.upCount += 1
        if (Number(node.operUp) === 2) existing.downCount += 1
        existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
        if (!existing.sampleNode && node.details) existing.sampleNode = node
        clusters.set(key, existing)
        clusterByNode[index] = key
      })

      const nodes = Array.from(clusters.values()).map((cluster) => {
        const dominantState = [0, 1, 2, 3].sort(
          (a, b) => (cluster.stateHistogram[b] || 0) - (cluster.stateHistogram[a] || 0),
        )[0]
        const keyParts = String(cluster.id).split(":")
        const gridX = keyParts.length >= 3 ? keyParts[1] : "0"
        const gridY = keyParts.length >= 3 ? keyParts[2] : "0"
        return {
          id: cluster.id,
          x: cluster.sumX / cluster.count,
          y: cluster.sumY / cluster.count,
          state: dominantState,
          clusterCount: cluster.count,
          pps: cluster.sumPps,
          operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
          label: `Regional Cluster ${gridX},${gridY}`,
          details: this.clusterDetails(cluster, "regional"),
        }
      })

      const edges = this.clusterEdges(graph.edges, clusterByNode)
      return {shape: "regional", nodes, edges}
    },
    clusterDetails(cluster, scope) {
      const sample = cluster.sampleNode?.details || {}
      const sampleLabel = cluster.sampleNode?.label || null
      const sampleIp = sample.ip || null
      const sampleType = sample.type || null
      const bucketType = scope === "global" ? "State Cluster" : "Regional Cluster"
      return {
        id: cluster.id,
        ip: sampleIp || "cluster",
        type: sampleType || bucketType,
        model: sample.model || null,
        vendor: sample.vendor || null,
        asn: sample.asn || null,
        geo_city: sample.geo_city || null,
        geo_country: sample.geo_country || null,
        last_seen: sample.last_seen || null,
        cluster_scope: scope,
        cluster_count: cluster.count,
        sample_label: sampleLabel,
      }
    },
    clusterEdges(edges, clusterByNode) {
      const acc = new Map()
      edges.forEach((edge) => {
        const a = clusterByNode[edge.source]
        const b = clusterByNode[edge.target]
        if (!a || !b || a === b) return
        const key = a < b ? `${a}|${b}` : `${b}|${a}`
        const current = acc.get(key) || {
          sourceCluster: a < b ? a : b,
          targetCluster: a < b ? b : a,
          weight: 0,
          flowPps: 0,
          flowBps: 0,
          capacityBps: 0,
          topologyClassCounts: {backbone: 0, inferred: 0, endpoints: 0},
        }
        const topologyClass = this.edgeTopologyClass(edge)
        current.weight += 1
        current.flowPps += Number(edge.flowPps || 0)
        current.flowBps += Number(edge.flowBps || 0)
        current.capacityBps += Number(edge.capacityBps || 0)
        current.topologyClassCounts[topologyClass] =
          Number(current.topologyClassCounts[topologyClass] || 0) + 1
        acc.set(key, current)
      })
      return Array.from(acc.values())
    },
    animateTransition(previousGraph, nextGraph) {
      if (this.pendingAnimationFrame) {
        cancelAnimationFrame(this.pendingAnimationFrame)
        this.pendingAnimationFrame = null
      }

      const shouldAnimate =
        previousGraph &&
        previousGraph.nodes.length > 0 &&
        previousGraph.nodes.length === nextGraph.nodes.length

      if (!shouldAnimate) {
        this.renderGraph(nextGraph)
        return
      }

      const durationMs = 220
      const prevXY = this.xyBuffer(previousGraph.nodes)
      const nextXY = this.xyBuffer(nextGraph.nodes)
      const startedAt = performance.now()

      const step = (now) => {
        const t = Math.min((now - startedAt) / durationMs, 1)
        const frameNodes = this.interpolateNodes(previousGraph.nodes, nextGraph.nodes, prevXY, nextXY, t)
        this.renderGraph({...nextGraph, nodes: frameNodes})

        if (t < 1) {
          this.pendingAnimationFrame = requestAnimationFrame(step)
        } else {
          this.pendingAnimationFrame = null
        }
      }

      this.pendingAnimationFrame = requestAnimationFrame(step)
    },
    xyBuffer(nodes) {
      const xy = new Float32Array(nodes.length * 2)
      for (let i = 0; i < nodes.length; i += 1) {
        xy[i * 2] = nodes[i].x
        xy[i * 2 + 1] = nodes[i].y
      }
      return xy
    },
    interpolateNodes(previousNodes, nextNodes, prevXY, nextXY, t) {
      if (this.wasmReady && this.wasmEngine) {
        try {
          const xy = this.wasmEngine.computeInterpolatedXY(prevXY, nextXY, t)
          const out = new Array(nextNodes.length)
          for (let i = 0; i < nextNodes.length; i += 1) {
            out[i] = {
              ...(nextNodes[i] || {}),
              x: xy[i * 2],
              y: xy[i * 2 + 1],
            }
          }
          return out
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const clamped = Math.max(0, Math.min(t, 1))
      const out = new Array(nextNodes.length)
      for (let i = 0; i < nextNodes.length; i += 1) {
        const a = previousNodes[i]
        const b = nextNodes[i]
        out[i] = {
          ...(b || {}),
          x: a.x + (b.x - a.x) * clamped,
          y: a.y + (b.y - a.y) * clamped,
        }
      }
      return out
    },
    prepareGraphLayout(graph, revision, topologyStamp) {
      if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph
      const stamp =
        typeof topologyStamp === "string" && topologyStamp.length > 0
          ? topologyStamp
          : this.graphTopologyStamp(graph)

      if (this.lastGraph && stamp === this.lastTopologyStamp) {
        const reused = this.reusePreviousPositions(graph, this.lastGraph)
        reused._layoutMode = this.layoutMode || "auto"
        reused._layoutRevision = revision
        return reused
      }

      if (this.lastGraph && Number.isFinite(revision) && this.layoutRevision === revision) {
        const reused = this.reusePreviousPositions(graph, this.lastGraph)
        reused._layoutMode = this.layoutMode || "auto"
        reused._layoutRevision = revision
        return reused
      }
      if (graph._layoutRevision && graph._layoutRevision === revision) return graph

      const mode = this.shouldUseGeoLayout(graph) ? "geo" : "force"
      const laidOut = mode === "geo" ? this.projectGeoLayout(graph) : this.forceDirectedLayout(graph)
      laidOut._layoutMode = mode
      laidOut._layoutRevision = revision
      this.layoutMode = mode
      this.layoutRevision = revision
      return laidOut
    },
    graphTopologyStamp(graph) {
      if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
      let nodeHash = 0
      for (let i = 0; i < graph.nodes.length; i += 1) {
        const id = String(graph.nodes[i]?.id || "")
        for (let j = 0; j < id.length; j += 1) nodeHash = ((nodeHash << 5) - nodeHash + id.charCodeAt(j)) | 0
      }
      let edgeHash = 0
      for (let i = 0; i < graph.edges.length; i += 1) {
        const s = Number(graph.edges[i]?.source || 0)
        const t = Number(graph.edges[i]?.target || 0)
        edgeHash = (((edgeHash << 5) - edgeHash + s * 31 + t * 131) | 0)
      }
      return `${graph.nodes.length}:${graph.edges.length}:${nodeHash}:${edgeHash}`
    },
    sameTopology(previousGraph, nextGraph, stamp, revision) {
      if (!previousGraph || !nextGraph) return false
      if (!Number.isFinite(revision) || !Number.isFinite(this.lastRevision)) return false
      return (
        revision === this.lastRevision &&
        stamp === this.lastTopologyStamp &&
        previousGraph.nodes.length === nextGraph.nodes.length &&
        previousGraph.edges.length === nextGraph.edges.length
      )
    },
    reusePreviousPositions(nextGraph, previousGraph) {
      if (!nextGraph || !previousGraph) return nextGraph
      const byId = new Map((previousGraph.nodes || []).map((n) => [n.id, n]))
      const nodes = (nextGraph.nodes || []).map((n) => {
        const prev = byId.get(n.id)
        if (!prev) return n
        return {...n, x: Number(prev.x || n.x || 0), y: Number(prev.y || n.y || 0)}
      })
      return {...nextGraph, nodes}
    },
    shouldUseGeoLayout(graph) {
      const nodes = graph?.nodes || []
      if (nodes.length < 6) return false
      let geoCount = 0
      for (const node of nodes) {
        if (Number.isFinite(node?.geoLat) && Number.isFinite(node?.geoLon)) geoCount += 1
      }
      return geoCount / Math.max(1, nodes.length) >= 0.25
    },
    projectGeoLayout(graph) {
      const width = 640
      const height = 320
      const pad = 20
      const nodes = graph.nodes.map((node) => ({...node}))
      let fallbackIdx = 0
      for (const node of nodes) {
        const lat = Number(node?.geoLat)
        const lon = Number(node?.geoLon)
        if (Number.isFinite(lat) && Number.isFinite(lon)) {
          const clampedLat = Math.max(-85, Math.min(85, lat))
          const x = ((lon + 180) / 360) * (width - pad * 2) + pad
          const rad = clampedLat * (Math.PI / 180)
          const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
          const y = mercY * (height - pad * 2) + pad
          node.x = x
          node.y = y
        } else {
          const angle = fallbackIdx * 0.72
          const ring = 22 + (fallbackIdx % 14) * 7
          node.x = width / 2 + Math.cos(angle) * ring
          node.y = height / 2 + Math.sin(angle) * ring
          fallbackIdx += 1
        }
      }
      return {...graph, nodes}
    },
    forceDirectedLayout(graph) {
      const width = 640
      const height = 320
      const pad = 20
      const nodes = graph.nodes.map((node) => ({...node}))
      if (nodes.length <= 2) return {...graph, nodes}

      const links = graph.edges
        .filter((edge) => Number.isInteger(edge?.source) && Number.isInteger(edge?.target))
        .map((edge) => ({source: edge.source, target: edge.target, weight: Number(edge.weight || 1)}))

      const simulation = d3.forceSimulation(nodes)
        .alphaMin(0.02)
        .force("charge", d3.forceManyBody().strength(nodes.length > 500 ? -20 : -45))
        .force("link", d3.forceLink(links).id((_d, i) => i).distance((l) => {
          const w = Number(l?.weight || 1)
          return Math.max(22, Math.min(90, 52 - Math.log2(Math.max(1, w)) * 8))
        }).strength(0.34))
        .force("collide", d3.forceCollide().radius(7).strength(0.8))
        .force("center", d3.forceCenter(width / 2, height / 2))
        .stop()

      const iterations = Math.min(220, Math.max(70, Math.round(30 + nodes.length * 0.32)))
      for (let i = 0; i < iterations; i += 1) simulation.tick()

      const xs = nodes.map((n) => Number(n.x || 0))
      const ys = nodes.map((n) => Number(n.y || 0))
      const minX = Math.min(...xs)
      const maxX = Math.max(...xs)
      const minY = Math.min(...ys)
      const maxY = Math.max(...ys)
      const dx = Math.max(1, maxX - minX)
      const dy = Math.max(1, maxY - minY)
      for (const n of nodes) {
        n.x = pad + ((Number(n.x || 0) - minX) / dx) * (width - pad * 2)
        n.y = pad + ((Number(n.y || 0) - minY) / dy) * (height - pad * 2)
      }

      return {...graph, nodes}
    },
    geoGridData() {
      if (this.layoutMode !== "geo") return []
      const width = 640
      const height = 320
      const pad = 20
      const project = (lat, lon) => {
        const clampedLat = Math.max(-85, Math.min(85, lat))
        const x = ((lon + 180) / 360) * (width - pad * 2) + pad
        const rad = clampedLat * (Math.PI / 180)
        const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
        const y = mercY * (height - pad * 2) + pad
        return [x, y, -2]
      }

      const lines = []
      for (let lon = -150; lon <= 150; lon += 30) {
        for (let lat = -80; lat < 80; lat += 10) {
          lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat + 10, lon)})
        }
      }
      for (let lat = -60; lat <= 60; lat += 20) {
        for (let lon = -180; lon < 180; lon += 15) {
          lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat, lon + 15)})
        }
      }
      return lines
    },
    getNodeTooltip({object, layer}) {
      if (!object) return null
      if (layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust") {
        const connection = object.connectionLabel || "LINK"
        return {text: `${connection}\n${this.formatPps(object.flowPps || 0)}\n${this.formatCapacity(object.capacityBps || 0)}`}
      }
      if (layer?.id !== "god-view-nodes") return null
      const d = object?.details || {}
      const nodeMap = this.nodeIndexLookup((this.lastGraph?.nodes || []))
      const reason = this.escapeHtml(object.stateReason || this.defaultStateReason(object.state))
      const rootRef = this.nodeReferenceAction(
        d?.causal_root_index,
        "Root",
        nodeMap,
      )
      const parentRef = this.nodeReferenceAction(
        d?.causal_parent_index,
        "Parent",
        nodeMap,
      )
      const geo = [d.geo_city, d.geo_country].filter(Boolean).join(", ")
      return {
        html: [
          `<div class="font-semibold">${this.escapeHtml(object.label || "node")}</div>`,
          `<div>IP: ${this.escapeHtml(d.ip || "unknown")}</div>`,
          `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
          `<div>State: ${this.escapeHtml(this.stateDisplayName(object.state))}</div>`,
          `<div>Why: ${reason}</div>`,
          rootRef,
          parentRef,
          geo ? `<div>Geo: ${this.escapeHtml(geo)}</div>` : "",
          d.asn ? `<div>ASN: ${this.escapeHtml(d.asn)}</div>` : "",
        ].filter(Boolean).join(""),
        style: {
          backgroundColor: "rgba(15, 23, 42, 0.94)",
          border: "1px solid rgba(148, 163, 184, 0.35)",
          borderRadius: "10px",
          color: "#e2e8f0",
          fontSize: "12px",
          lineHeight: "1.35",
          maxWidth: "360px",
          padding: "8px 10px",
          pointerEvents: "auto",
          whiteSpace: "normal",
        },
      }
    },
    edgeLayerId(layerId) {
      return layerId === "god-view-edges-mantle" || layerId === "god-view-edges-crust"
    },
    handleHover(info) {
      const layerId = info?.layer?.id || ""
      const nextKey =
        this.edgeLayerId(layerId) && typeof info?.object?.interactionKey === "string"
          ? info.object.interactionKey
          : null
      if (this.hoveredEdgeKey === nextKey) return
      this.hoveredEdgeKey = nextKey
      if (this.lastGraph) this.renderGraph(this.lastGraph)
    },
    edgeIsFocused(edge) {
      if (!edge) return false
      const key = edge.interactionKey
      return key != null && (key === this.hoveredEdgeKey || key === this.selectedEdgeKey)
    },
    renderSelectionDetails(node) {
      if (!this.details) return
      if (!node) {
        this.details.classList.add("hidden")
        this.details.textContent = "Select a node for details"
        return
      }

      const d = node.details || {}
      const nodeMap = this.nodeIndexLookup((this.lastGraph?.nodes || []))
      const reason = this.escapeHtml(node.stateReason || this.defaultStateReason(node.state))
      const rootRef = this.nodeReferenceAction(
        d?.causal_root_index,
        "Root",
        nodeMap,
      )
      const parentRef = this.nodeReferenceAction(
        d?.causal_parent_index,
        "Parent",
        nodeMap,
      )
      const detailLines = [
        `<div class="font-semibold text-sm mb-1">${this.escapeHtml(node.label || "node")}</div>`,
        `<div>ID: ${this.escapeHtml(d.id || node.id || "unknown")}</div>`,
        `<div>IP: ${this.escapeHtml(d.ip || "unknown")}</div>`,
        `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
        `<div>State: ${this.escapeHtml(this.stateDisplayName(node.state))}</div>`,
        `<div>Why: ${reason}</div>`,
        rootRef,
        parentRef,
        `<div>Vendor/Model: ${this.escapeHtml(`${d.vendor || "—"} ${d.model || ""}`.trim())}</div>`,
        `<div>Last Seen: ${this.escapeHtml(d.last_seen || "unknown")}</div>`,
        `<div>ASN: ${this.escapeHtml(d.asn || "unknown")}</div>`,
        `<div>Geo: ${this.escapeHtml([d.geo_city, d.geo_country].filter(Boolean).join(", ") || "unknown")}</div>`,
      ].filter(Boolean)

      this.details.innerHTML = detailLines.join("")
      this.details.classList.remove("hidden")
    },
    escapeHtml(value) {
      const text = String(value == null ? "" : value)
      return text
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;")
    },
    nodeReferenceAction(index, label, nodeMap) {
      const idx = Number(index)
      if (!Number.isFinite(idx) || idx < 0) return ""
      const ref = this.nodeRefByIndex(idx, nodeMap) || `node#${idx}`
      return `<div>${this.escapeHtml(label)}: <button type="button" class="link link-primary text-xs" data-node-index="${idx}">${this.escapeHtml(ref)}</button></div>`
    },
    focusNodeByIndex(index, switchToLocal = false) {
      const idx = Number(index)
      if (!Number.isFinite(idx) || idx < 0) return
      const node = this.lastGraph?.nodes?.[idx]
      if (!node) return

      if (switchToLocal) {
        this.zoomMode = "local"
        this.zoomTier = "local"
      }

      this.selectedNodeIndex = idx

      const x = Number(node.x)
      const y = Number(node.y)
      if (Number.isFinite(x) && Number.isFinite(y)) {
        this.viewState = {...this.viewState, target: [x, y, 0]}
        if (this.deck) {
          this.isProgrammaticViewUpdate = true
          this.deck.setProps({viewState: this.viewState})
          this.isProgrammaticViewUpdate = false
        }
      }

      if (this.lastGraph) this.renderGraph(this.lastGraph)
    },
    handlePick(info) {
      const layerId = info?.layer?.id || ""
      if (this.edgeLayerId(layerId)) {
        const key = typeof info?.object?.interactionKey === "string" ? info.object.interactionKey : null
        if (!key) return
        this.selectedEdgeKey = this.selectedEdgeKey === key ? null : key
        if (this.lastGraph) this.renderGraph(this.lastGraph)
        return
      }

      const tier = this.zoomMode === "auto" ? this.zoomTier : this.zoomMode
      if (tier === "local") {
        const picked = info?.object?.index
        if (Number.isInteger(picked)) {
          this.selectedNodeIndex = this.selectedNodeIndex === picked ? null : picked
          if (this.lastGraph) this.renderGraph(this.lastGraph)
          return
        }
      }

      if (info && info.picked === false) {
        let changed = false
        if (this.selectedNodeIndex !== null) {
          this.selectedNodeIndex = null
          changed = true
        }
        if (this.selectedEdgeKey !== null) {
          this.selectedEdgeKey = null
          changed = true
        }
        if (changed && this.lastGraph) this.renderGraph(this.lastGraph)
      }
    },
    renderGraph(graph) {
      this.ensureDeck()
      this.autoFitViewState(graph)
      const effective = this.reshapeGraph(graph)

      const states = Uint8Array.from(effective.nodes.map((node) => node.state))
      const stateMask = this.visibilityMask(states)
      const traversalMask = effective.shape === "local" ? this.computeTraversalMask(effective) : null
      const mask = new Uint8Array(effective.nodes.length)

      for (let i = 0; i < effective.nodes.length; i += 1) {
        const stateVisible = stateMask[i] === 1
        const traversalVisible = !traversalMask || traversalMask[i] === 1
        mask[i] = stateVisible && traversalVisible ? 1 : 0
      }

      const visibleNodes = effective.nodes.map((node, index) => ({
        ...node,
        index,
        selected: this.selectedNodeIndex === index,
        visible: mask[index] === 1,
      }))
      const visibleById = new Map(visibleNodes.map((node) => [node.id, node]))

      const edgeData = effective.edges
        .filter((edge) => this.edgeEnabledByTopologyLayer(edge))
        .map((edge, edgeIndex) => {
          const src =
            effective.shape === "local"
              ? visibleNodes[edge.source]
              : visibleById.get(edge.sourceCluster)
          const dst =
            effective.shape === "local"
              ? visibleNodes[edge.target]
              : visibleById.get(edge.targetCluster)
          if (!src || !dst || !src.visible || !dst.visible) return null
          const label =
            effective.shape === "local"
              ? String(edge.label || `${src.label || src.id || "node"} -> ${dst.label || dst.id || "node"}`)
              : `${this.formatPps(edge.flowPps || 0)} / ${this.formatCapacity(edge.capacityBps || 0)}`
          const connectionLabel = this.connectionKindFromLabel(label)
          const sourceId = effective.shape === "local" ? src.id : src.id || edge.sourceCluster || "src"
          const targetId = effective.shape === "local" ? dst.id : dst.id || edge.targetCluster || "dst"
          const rawEdgeId = edge.id || edge.edge_id || edge.label || edge.type || `${sourceId}:${targetId}:${edgeIndex}`
          return {
            sourceId,
            targetId,
            sourcePosition: [src.x, src.y, 0],
            targetPosition: [dst.x, dst.y, 0],
            weight: edge.weight || 1,
            flowPps: Number(edge.flowPps || 0),
            flowBps: Number(edge.flowBps || 0),
            capacityBps: Number(edge.capacityBps || 0),
            midpoint: [(src.x + dst.x) / 2, (src.y + dst.y) / 2, 0],
            label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
            connectionLabel,
            interactionKey: `${effective.shape}:${rawEdgeId}`,
          }
        })
        .filter(Boolean)
      const edgeKeys = new Set(edgeData.map((edge) => edge.interactionKey))
      if (this.hoveredEdgeKey && !edgeKeys.has(this.hoveredEdgeKey)) this.hoveredEdgeKey = null
      if (this.selectedEdgeKey && !edgeKeys.has(this.selectedEdgeKey)) this.selectedEdgeKey = null
      const edgeLabelData = this.selectEdgeLabels(edgeData, effective.shape)

      const nodeData = visibleNodes
        .filter((node) => node.visible)
        .map((node) => ({
          id: node.id,
          position: [node.x, node.y, 0],
          index: node.index,
          state: node.state,
          selected: node.selected,
          clusterCount: node.clusterCount || 1,
          pps: Number(node.pps || 0),
          operUp: Number(node.operUp || 0),
          details: node.details || {},
          label:
            this.normalizeDisplayLabel(node.label, node.id || `node-${node.index + 1}`),
          metricText: this.nodeMetricText(node, effective.shape),
          statusIcon: this.nodeStatusIcon(node.operUp),
          stateReason: this.stateReasonForNode(node, edgeData, visibleNodes),
        }))
      this.lastVisibleNodeCount = nodeData.length
      this.lastVisibleEdgeCount = edgeData.length
      const pulse = (Math.sin(this.animationPhase * 3.5) + 1) / 2
      const pulseRadius = 14 + pulse * 20
      const pulseAlpha = Math.floor(80 + pulse * 130)
      const rootPulseNodes = nodeData.filter((d) => d.state === 0)
      const packetFlowData = this.buildPacketFlowInstances(edgeData)
      const securityEnabled = this.layers.security
      const mantleLayers = this.layers.mantle
        ? [
            new LineLayer({
              id: "god-view-edges-mantle",
              data: edgeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => d.sourcePosition,
              getTargetPosition: (d) => d.targetPosition,
              getColor: (d) => this.edgeTelemetryColor(d.flowBps, d.capacityBps, d.flowPps, false),
              getWidth: (d) => this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) + (this.edgeIsFocused(d) ? 1.25 : 0),
              widthUnits: "pixels",
              widthMinPixels: 1,
              pickable: true,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
                depthTest: false,
              },
            }),
          ]
        : []
      const crustLayers =
        this.layers.crust
          ? [
              new ArcLayer({
                id: "god-view-edges-crust",
                data: edgeData,
                coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                getSourcePosition: (d) => [d.sourcePosition[0], d.sourcePosition[1], 8],
                getTargetPosition: (d) => [d.targetPosition[0], d.targetPosition[1], 8],
                getSourceColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source,
                getTargetColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).target,
                getWidth: (d) => {
                  const base = Math.max(1.1, Math.min(this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * 0.85, 4.8))
                  return this.edgeIsFocused(d) ? Math.min(5.8, base + 0.9) : base
                },
                widthUnits: "pixels",
                greatCircle: false,
                getTilt: effective.shape === "local" ? 16 : 24,
                pickable: true,
                parameters: {
                  blend: true,
                  blendFunc: [770, 1, 1, 1],
                },
              }),
            ]
          : []
      const atmosphereLayers = this.layers.atmosphere
        ? [
            new PacketFlowLayer({
              id: "god-view-atmosphere-particles",
              data: packetFlowData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              pickable: false,
              time: this.animationPhase,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
                depthTest: false,
              },
            }),
          ]
        : []
      const securityLayers = this.layers.security
        ? [
            new ScatterplotLayer({
              id: "god-view-security-pulse",
              data: rootPulseNodes,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getRadius: pulseRadius,
              radiusUnits: "pixels",
              radiusMinPixels: 8,
              filled: false,
              stroked: true,
              lineWidthUnits: "pixels",
              getLineWidth: 2,
              getLineColor: [
                this.visual.pulse[0],
                this.visual.pulse[1],
                this.visual.pulse[2],
                pulseAlpha,
              ],
              pickable: false,
            }),
          ]
        : []

      const baseGeoLines = this.geoGridData()
      const baseLayers = baseGeoLines.length > 0
        ? [
            new LineLayer({
              id: "god-view-geo-grid",
              data: baseGeoLines,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => d.sourcePosition,
              getTargetPosition: (d) => d.targetPosition,
              getColor: [32, 62, 88, 65],
              getWidth: 1,
              widthUnits: "pixels",
              pickable: false,
            }),
          ]
        : []

      const selectedVisibleNode =
        effective.shape !== "local" || this.selectedNodeIndex === null
          ? null
          : nodeData.find((node) => node.index === this.selectedNodeIndex)
      this.renderSelectionDetails(selectedVisibleNode)

      this.deck.setProps({
        layers: [
          ...baseLayers,
          ...mantleLayers,
          ...crustLayers,
          new ScatterplotLayer({
            id: "god-view-nodes",
            data: nodeData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getPosition: (d) => d.position,
            getRadius: (d) => Math.min(8 + ((d.clusterCount || 1) - 1) * 0.45, 26),
            radiusUnits: "pixels",
            radiusMinPixels: 4,
            stroked: true,
            filled: true,
            lineWidthUnits: "pixels",
            pickable: true,
            getLineWidth: (d) => (d.selected ? 3 : 1),
            getLineColor: [15, 23, 42, 255],
            getFillColor: (d) => (securityEnabled ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)),
          }),
          ...securityLayers,
          ...atmosphereLayers,
          ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
            ? [
                new TextLayer({
                  id: "god-view-node-labels",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.label,
                  getSize: effective.shape === "local" ? 12 : 10,
                  sizeUnits: "pixels",
                  sizeMinPixels: effective.shape === "local" ? 10 : 8,
                  getColor: this.visual.label,
                  getPixelOffset: [0, -16],
                  billboard: true,
                  pickable: false,
                }),
                new TextLayer({
                  id: "god-view-node-metrics",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.metricText,
                  getSize: effective.shape === "local" ? 10 : 9,
                  sizeUnits: "pixels",
                  sizeMinPixels: 8,
                  getColor: [148, 163, 184, 220],
                  getPixelOffset: [0, -3],
                  billboard: true,
                  pickable: false,
                }),
                new TextLayer({
                  id: "god-view-node-status-icon",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.statusIcon,
                  getSize: effective.shape === "local" ? 12 : 11,
                  sizeUnits: "pixels",
                  sizeMinPixels: 9,
                  getColor: (d) => this.nodeStatusColor(d.operUp),
                  getPixelOffset: [-18, -16],
                  billboard: true,
                  pickable: false,
                }),
              ]
            : []),
          ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional")
            ? [
                new TextLayer({
                  id: "god-view-edge-labels",
                  data: edgeLabelData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.midpoint,
                  getText: (d) => d.connectionLabel,
                  getSize: 10,
                  sizeUnits: "pixels",
                  sizeMinPixels: 8,
                  getColor: this.visual.edgeLabel,
                  billboard: true,
                  pickable: false,
                }),
              ]
            : []),
        ],
      })
    },
    ensureBitmapMetadata(metadata, nodes) {
      const fallback = this.buildBitmapFallbackMetadata(nodes)
      const value = metadata && typeof metadata === "object" ? metadata : {}

      const pick = (key) => {
        const item = value[key] || value[String(key)] || {}
        const bytes = Number(item.bytes || 0)
        const count = Number(item.count || 0)
        return {
          bytes: Number.isFinite(bytes) ? bytes : 0,
          count: Number.isFinite(count) ? count : 0,
        }
      }

      const normalized = {
        root_cause: pick("root_cause"),
        affected: pick("affected"),
        healthy: pick("healthy"),
        unknown: pick("unknown"),
      }

      const sumCounts =
        normalized.root_cause.count +
        normalized.affected.count +
        normalized.healthy.count +
        normalized.unknown.count
      const sumBytes =
        normalized.root_cause.bytes +
        normalized.affected.bytes +
        normalized.healthy.bytes +
        normalized.unknown.bytes

      if (sumCounts === 0 && sumBytes === 0 && Array.isArray(nodes) && nodes.length > 0) {
        return fallback
      }

      return normalized
    },
    buildBitmapFallbackMetadata(nodes) {
      const safeNodes = Array.isArray(nodes) ? nodes : []
      const byteWidth = Math.ceil(safeNodes.length / 8)
      const counts = {root_cause: 0, affected: 0, healthy: 0, unknown: 0}

      for (let i = 0; i < safeNodes.length; i += 1) {
        const category = this.stateCategory(Number(safeNodes[i]?.state))
        counts[category] = (counts[category] || 0) + 1
      }

      return {
        root_cause: {bytes: byteWidth, count: counts.root_cause || 0},
        affected: {bytes: byteWidth, count: counts.affected || 0},
        healthy: {bytes: byteWidth, count: counts.healthy || 0},
        unknown: {bytes: byteWidth, count: counts.unknown || 0},
      }
    },
    autoFitViewState(graph) {
      if (!this.deck || !graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return
      if (this.hasAutoFit || this.userCameraLocked) return

      let minX = Number.POSITIVE_INFINITY
      let maxX = Number.NEGATIVE_INFINITY
      let minY = Number.POSITIVE_INFINITY
      let maxY = Number.NEGATIVE_INFINITY

      for (let i = 0; i < graph.nodes.length; i += 1) {
        const node = graph.nodes[i]
        const x = Number(node?.x)
        const y = Number(node?.y)
        if (!Number.isFinite(x) || !Number.isFinite(y)) continue
        minX = Math.min(minX, x)
        maxX = Math.max(maxX, x)
        minY = Math.min(minY, y)
        maxY = Math.max(maxY, y)
      }

      if (!Number.isFinite(minX) || !Number.isFinite(minY)) return

      const width = Math.max(1, this.el.clientWidth || 1)
      const height = Math.max(1, this.el.clientHeight || 1)
      const spanX = Math.max(1, maxX - minX)
      const spanY = Math.max(1, maxY - minY)
      const padding = 0.88
      const zoomX = Math.log2((width * padding) / spanX)
      const zoomY = Math.log2((height * padding) / spanY)
      const zoom = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, Math.min(zoomX, zoomY)))

      this.viewState = {
        ...this.viewState,
        target: [(minX + maxX) / 2, (minY + maxY) / 2, 0],
        zoom,
      }

      this.hasAutoFit = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      if (this.zoomMode === "auto") {
        this.setZoomTier(this.resolveZoomTier(zoom), true)
      }
    },
    visibilityMask(states) {
      if (this.wasmReady && this.wasmEngine) {
        try {
          return this.wasmEngine.computeStateMask(states, this.filters)
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const mask = new Uint8Array(states.length)
      for (let i = 0; i < states.length; i += 1) {
        const category = this.stateCategory(states[i])
        mask[i] = this.filters[category] !== false ? 1 : 0
      }
      return mask
    },
    computeTraversalMask(graph) {
      if (!graph || this.selectedNodeIndex === null) return null
      if (this.selectedNodeIndex >= graph.nodes.length) return null

      if (this.wasmReady && this.wasmEngine) {
        try {
          return this.wasmEngine.computeThreeHopMask(
            graph.nodes.length,
            graph.edgeSourceIndex,
            graph.edgeTargetIndex,
            this.selectedNodeIndex,
          )
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const mask = new Uint8Array(graph.nodes.length)
      const frontier = [this.selectedNodeIndex]
      mask[this.selectedNodeIndex] = 1

      for (let hop = 0; hop < 3; hop += 1) {
        if (frontier.length === 0) break
        const next = []

        for (const node of frontier) {
          for (let i = 0; i < graph.edges.length; i += 1) {
            const edge = graph.edges[i]
            const a = edge.source
            const b = edge.target

            if (a === node && b < graph.nodes.length && mask[b] === 0) {
              mask[b] = 1
              next.push(b)
            } else if (b === node && a < graph.nodes.length && mask[a] === 0) {
              mask[a] = 1
              next.push(a)
            }
          }
        }

        frontier.length = 0
        frontier.push(...next)
      }

      return mask
    },
    stateCategory(state) {
      if (state === 0) return "root_cause"
      if (state === 1) return "affected"
      if (state === 2) return "healthy"
      return "unknown"
    },
    stateDisplayName(state) {
      if (state === 0) return "Root Cause"
      if (state === 1) return "Affected"
      if (state === 2) return "Healthy"
      return "Unknown"
    },
    defaultStateReason(state) {
      if (state === 0) return "Primary failure detected by causal model."
      if (state === 1) return "Impacted by an upstream dependency."
      if (state === 2) return "No active causal impact detected."
      return "Insufficient telemetry to classify root or affected."
    },
    stateReasonForNode(node, edgeData, allNodes = []) {
      const state = Number(node?.state)
      if (!Number.isFinite(state)) return this.defaultStateReason(3)
      const details = node?.details || {}
      const nodeIndexMap = this.nodeIndexLookup(allNodes)

      const causalReason = String(details?.causal_reason || "").trim()
      if (causalReason) {
        return this.humanizeCausalReason(causalReason, details, nodeIndexMap)
      }

      if (state === 0) {
        if (Number(node?.operUp) === 2) return "Device is operationally down and identified as a root cause."
        return "Marked as the most upstream causal source in current dependencies."
      }

      if (state === 2) {
        return "Healthy signal with no active upstream dependency impact."
      }

      if (state === 3) {
        return this.defaultStateReason(state)
      }

      const id = node?.id
      if (!id || !Array.isArray(edgeData) || edgeData.length === 0) return this.defaultStateReason(state)

      const neighbors = []
      const seen = new Set()

      for (const edge of edgeData) {
        if (!edge) continue
        let peerId = null

        if (edge.sourceId === id) peerId = edge.targetId
        else if (edge.targetId === id) peerId = edge.sourceId

        if (!peerId || seen.has(peerId)) continue
        seen.add(peerId)
        neighbors.push(peerId)
        if (neighbors.length >= 3) break
      }

      if (neighbors.length > 0) {
        return `Affected through dependencies on ${neighbors.join(", ")}.`
      }

      return this.defaultStateReason(state)
    },
    nodeIndexLookup(nodes) {
      const map = new Map()
      if (!Array.isArray(nodes)) return map
      for (const n of nodes) {
        const idx = Number(n?.index)
        if (!Number.isFinite(idx)) continue
        map.set(idx, n)
      }
      return map
    },
    nodeRefByIndex(index, nodeIndexMap) {
      const idx = Number(index)
      if (!Number.isFinite(idx) || idx < 0) return null
      const node = nodeIndexMap.get(idx)
      if (!node) return `node#${idx}`
      const label = this.normalizeDisplayLabel(node.label, node.id || `node#${idx}`)
      const ip = node?.details?.ip
      return ip ? `${label} (${ip})` : label
    },
    humanizeCausalReason(reason, details, nodeIndexMap) {
      const key = String(reason || "").trim().toLowerCase()
      const hop = Number(details?.causal_hop_distance)
      const rootRef = this.nodeRefByIndex(details?.causal_root_index, nodeIndexMap)
      const parentRef = this.nodeRefByIndex(details?.causal_parent_index, nodeIndexMap)

      if (key === "selected_as_root_from_unhealthy_candidates") {
        return "Selected as root cause from unhealthy candidates by topology centrality."
      }

      if (key.startsWith("reachable_from_root_within_") && Number.isFinite(hop) && hop >= 0) {
        const via = parentRef ? ` via ${parentRef}` : ""
        const root = rootRef ? ` from ${rootRef}` : ""
        return `Affected: reachable${root} within ${hop} hop(s)${via}.`
      }

      if (key === "healthy_signal_no_path_to_selected_root") {
        return rootRef
          ? `Healthy: no dependency path from selected root ${rootRef}.`
          : "Healthy: no dependency path from selected root."
      }

      if (key === "unhealthy_signal_not_reachable_from_selected_root") {
        return rootRef
          ? `Unhealthy but not causally linked to selected root ${rootRef}.`
          : "Unhealthy but not causally linked to selected root."
      }

      if (key === "healthy_signal_no_detected_causal_impact") {
        return "Healthy signal with no detected causal impact."
      }

      if (key === "unknown_signal_without_identified_root") {
        return "State unknown: insufficient telemetry to identify a root cause."
      }

      const root = rootRef ? ` Root: ${rootRef}.` : ""
      const via = parentRef ? ` Parent: ${parentRef}.` : ""
      return `${reason}.${root}${via}`.trim()
    },
    nodeMetricText(node, shape) {
      const clusterCount = Number(node?.clusterCount || 1)
      if (shape === "global" || shape === "regional") {
        return `${clusterCount} node${clusterCount === 1 ? "" : "s"}`
      }
      return this.formatPps(node?.pps || 0)
    },
    nodeColor(state) {
      if (state === 0) return this.visual.nodeRoot
      if (state === 1) return this.visual.nodeAffected
      if (state === 2) return this.visual.nodeHealthy
      return this.visual.nodeUnknown
    },
    nodeNeutralColor(operUp) {
      if (Number(operUp) === 1) return [56, 189, 248, 230]
      if (Number(operUp) === 2) return [120, 113, 108, 220]
      return [100, 116, 139, 220]
    },
    formatPps(value) {
      const n = Number(value || 0)
      if (!Number.isFinite(n) || n <= 0) return "0 pps"
      if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)} Mpps`
      if (n >= 1_000) return `${(n / 1_000).toFixed(1)} Kpps`
      return `${Math.round(n)} pps`
    },
    formatCapacity(value) {
      const n = Number(value || 0)
      if (!Number.isFinite(n) || n <= 0) return "UNK"
      if (n >= 100_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 10_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 1_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 100_000_000) return `${Math.round(n / 1_000_000)}M`
      return `${Math.max(1, Math.round(n / 1_000_000))}M`
    },
    nodeStatusIcon(operUp) {
      if (Number(operUp) === 1) return "●"
      if (Number(operUp) === 2) return "○"
      return "◌"
    },
    nodeStatusColor(operUp) {
      if (Number(operUp) === 1) return [34, 197, 94, 230]
      if (Number(operUp) === 2) return [239, 68, 68, 230]
      return [148, 163, 184, 220]
    },
    edgeTelemetryColor(flowBps, capacityBps, flowPps, vivid = false) {
      const bps = Number(flowBps || 0)
      const cap = Number(capacityBps || 0)
      const pps = Number(flowPps || 0)
      const util = cap > 0 ? Math.min(1, bps / cap) : 0
      const spark = pps > 0 ? Math.min(1, Math.log10(Math.max(10, pps)) / 6) : 0
      const t = Math.min(1, Math.max(util, spark))

      const low = vivid ? [48, 226, 255, 65] : [40, 170, 220, 45]
      const high = vivid ? [255, 74, 212, 90] : [214, 97, 255, 70]

      return [
        Math.round(low[0] * (1 - t) + high[0] * t),
        Math.round(low[1] * (1 - t) + high[1] * t),
        Math.round(low[2] * (1 - t) + high[2] * t),
        Math.round(low[3] * (1 - t) + high[3] * t),
      ]
    },
    edgeTelemetryArcColors(flowBps, capacityBps, flowPps) {
      const source = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, true)
      const target = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, false)
      return {source, target}
    },
    edgeWidthPixels(capacityBps, flowPps, flowBps) {
      const cap = Number(capacityBps || 0)
      const pps = Number(flowPps || 0)
      const bps = Number(flowBps || 0)

      let base = 0.75
      if (cap >= 100_000_000_000) base = 3.5
      else if (cap >= 40_000_000_000) base = 2.8
      else if (cap >= 10_000_000_000) base = 2
      else if (cap >= 1_000_000_000) base = 1.5
      else if (cap >= 100_000_000) base = 1

      const ppsBoost = Math.min(2.8, Math.log10(Math.max(1, pps)) * 0.85)
      const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
      const bpsBoost = utilization > 0 ? Math.min(3.2, Math.sqrt(utilization) * 3.2) : 0
      const flowBoost = Math.max(ppsBoost, bpsBoost) * 0.6
      return Math.min(4.5, Math.max(0.75, base + flowBoost))
    },
    normalizeDisplayLabel(value, fallback = "node") {
      const label = String(value == null ? "" : value).trim()
      if (label === "") return fallback
      const lowered = label.toLowerCase()
      if (lowered === "nil" || lowered === "null" || lowered === "undefined") return fallback
      return label
    },
    connectionKindFromLabel(label) {
      const text = String(label == null ? "" : label).trim()
      if (text === "") return "LINK"
      const token = text.split(/\s+/)[0] || ""
      const clean = token.replace(/[^a-zA-Z0-9_-]/g, "").toUpperCase()
      if (!clean || clean === "NODE") return "LINK"
      return clean
    },
    pipelineStatsFromHeaders(headers) {
      if (!headers || typeof headers.get !== "function") return null
      const readInt = (name) => {
        const raw = headers.get(name)
        if (raw == null || raw === "") return null
        const parsed = Number.parseInt(raw, 10)
        return Number.isFinite(parsed) ? parsed : null
      }

      const stats = {
        raw_links: readInt("x-sr-god-view-pipeline-raw-links"),
        unique_pairs: readInt("x-sr-god-view-pipeline-unique-pairs"),
        final_edges: readInt("x-sr-god-view-pipeline-final-edges"),
        final_direct: readInt("x-sr-god-view-pipeline-final-direct"),
        final_inferred: readInt("x-sr-god-view-pipeline-final-inferred"),
        final_attachment: readInt("x-sr-god-view-pipeline-final-attachment"),
        unresolved_endpoints: readInt("x-sr-god-view-pipeline-unresolved-endpoints"),
      }

      const hasAny = Object.values(stats).some((value) => Number.isFinite(value))
      return hasAny ? stats : null
    },
    normalizePipelineStats(raw) {
      if (!raw || typeof raw !== "object") return null
      const keys = [
        "raw_links",
        "unique_pairs",
        "final_edges",
        "final_direct",
        "final_inferred",
        "final_attachment",
        "unresolved_endpoints",
      ]
      const out = {}
      for (let i = 0; i < keys.length; i += 1) {
        const key = keys[i]
        const value = raw[key]
        const parsed =
          Number.isFinite(value) ? Number(value) :
          (typeof value === "string" ? Number.parseInt(value, 10) : NaN)
        if (Number.isFinite(parsed)) out[key] = parsed
      }
      return Object.keys(out).length > 0 ? out : null
    },
    edgeTopologyClassFromLabel(label) {
      const text = String(label == null ? "" : label).trim().toUpperCase()
      if (text.includes(" ENDPOINT ")) return "endpoints"
      if (text.includes(" INFERRED ")) return "inferred"
      return "backbone"
    },
    edgeTopologyClass(edge) {
      const explicit = String(edge?.topologyClass || "").trim().toLowerCase()
      if (explicit === "inferred" || explicit === "endpoints" || explicit === "backbone") {
        return explicit
      }
      return this.edgeTopologyClassFromLabel(edge?.label || "")
    },
    edgeEnabledByTopologyLayer(edge) {
      const classCounts = edge?.topologyClassCounts
      if (classCounts && typeof classCounts === "object") {
        const showBackbone =
          Number(classCounts.backbone || 0) > 0 && this.topologyLayers.backbone !== false
        const showInferred =
          Number(classCounts.inferred || 0) > 0 && this.topologyLayers.inferred === true
        const showEndpoints =
          Number(classCounts.endpoints || 0) > 0 && this.topologyLayers.endpoints === true
        return showBackbone || showInferred || showEndpoints
      }

      const topologyClass = this.edgeTopologyClass(edge)
      if (topologyClass === "inferred") return this.topologyLayers.inferred === true
      if (topologyClass === "endpoints") return this.topologyLayers.endpoints === true
      return this.topologyLayers.backbone !== false
    },
    selectEdgeLabels(edgeData, shape) {
      if (!Array.isArray(edgeData) || edgeData.length === 0) return []
      if (shape !== "local" && shape !== "regional") return []

      const selected = this.selectedEdgeKey
      const hovered = this.hoveredEdgeKey
      if (!selected && !hovered) return []

      const picked = []
      const seen = new Set()
      for (let i = 0; i < edgeData.length; i += 1) {
        const edge = edgeData[i]
        if (edge.interactionKey !== selected && edge.interactionKey !== hovered) continue
        if (seen.has(edge.interactionKey)) continue
        seen.add(edge.interactionKey)
        picked.push(edge)
      }
      return picked
    },
    buildPacketFlowInstances(edgeData) {
      if (!Array.isArray(edgeData) || edgeData.length === 0) return []
      const maxParticles = 22000
      const particles = []

      for (let i = 0; i < edgeData.length; i += 1) {
        if (particles.length >= maxParticles) break
        const edge = edgeData[i]
        const src = edge?.sourcePosition
        const dst = edge?.targetPosition
        if (!Array.isArray(src) || !Array.isArray(dst)) continue
        const pps = Number(edge?.flowPps || 0)
        const bps = Number(edge?.flowBps || 0)
        const cap = Number(edge?.capacityBps || 0)
        const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
        const ppsSignal = pps > 0 ? Math.log10(Math.max(10, pps)) : 0
        const bpsSignal = utilization > 0 ? utilization * 3.2 : 0
        const baseline = 1.05 + Math.min(1.1, Math.log10(Math.max(1, edge.weight || 1)) * 0.72)
        const intensity = Math.max(baseline, ppsSignal, bpsSignal)
        const particlesOnEdge = Math.max(24, Math.min(140, Math.floor(intensity * 10.5)))
        const baseSpeed = 0.11 + Math.min(1.35, intensity * 0.11)

        for (let j = 0; j < particlesOnEdge; j += 1) {
          if (particles.length >= maxParticles) break
          const seed = (((i * 17 + j * 37) % 997) + 1) / 997
          const speedModifier = 0.7 + (((j * 43) % 101) / 100) * 0.6
          const particleSpeed = baseSpeed * speedModifier
          const hue = Math.min(1, intensity / 4)
          const cyan = [73, 231, 255, 95]
          const magenta = [244, 114, 255, 120]
          const color = [
            Math.round(cyan[0] * (1 - hue) + magenta[0] * hue),
            Math.round(cyan[1] * (1 - hue) + magenta[1] * hue),
            Math.round(cyan[2] * (1 - hue) + magenta[2] * hue),
            Math.round(cyan[3] * (1 - hue) + magenta[3] * hue),
          ]
          particles.push({
            from: [src[0], src[1]],
            to: [dst[0], dst[1]],
            seed,
            speed: particleSpeed,
            jitter: 8 + Math.min(26, intensity * 6.5),
            size: Math.min(24.0, 10.0 + intensity * 2.5),
            color,
          })
        }
      }

      return particles
    },
}
