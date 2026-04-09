import {godViewLifecycleBootstrapChannelSocketMethods} from "./lifecycle_bootstrap_channel_socket_methods"
import {godViewLifecycleBootstrapChannelEventMethods} from "./lifecycle_bootstrap_channel_event_methods"

const SNAPSHOT_MAGIC = "GVB1"
const SNAPSHOT_HEADER_BYTES = 53

function parseHeaderInt(headers, name) {
  const raw = headers?.get?.(name)
  const parsed = Number(raw)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
}

function parseGeneratedAtMs(headers, name) {
  const raw = headers?.get?.(name)
  if (typeof raw !== "string" || raw.trim() === "") return 0
  const parsed = Date.parse(raw)
  return Number.isFinite(parsed) ? parsed : 0
}

function pipelineStatsFromHeaders(headers) {
  return {
    raw_links: parseHeaderInt(headers, "x-sr-god-view-pipeline-raw-links"),
    unique_pairs: parseHeaderInt(headers, "x-sr-god-view-pipeline-unique-pairs"),
    final_edges: parseHeaderInt(headers, "x-sr-god-view-pipeline-final-edges"),
    final_direct: parseHeaderInt(headers, "x-sr-god-view-pipeline-final-direct"),
    final_inferred: parseHeaderInt(headers, "x-sr-god-view-pipeline-final-inferred"),
    final_attachment: parseHeaderInt(headers, "x-sr-god-view-pipeline-final-attachment"),
    unresolved_endpoints: parseHeaderInt(headers, "x-sr-god-view-pipeline-unresolved-endpoints"),
    edge_telemetry_interface: parseHeaderInt(headers, "x-sr-god-view-pipeline-edge-telemetry-interface"),
    edge_telemetry_fallback: parseHeaderInt(headers, "x-sr-god-view-pipeline-edge-telemetry-fallback"),
    edge_unresolved_directional: parseHeaderInt(headers, "x-sr-god-view-pipeline-edge-unresolved-directional"),
  }
}

const godViewLifecycleBootstrapChannelCoreMethods = {
  async bootstrapLatestSnapshot() {
    const url = this.state.el?.dataset?.url
    if (typeof url !== "string" || url.trim() === "" || typeof fetch !== "function") return false
    if (this.state.snapshotBootstrapPromise) return this.state.snapshotBootstrapPromise

    const promise = (async () => {
      const response = await fetch(url, {
        credentials: "same-origin",
        headers: {Accept: "application/octet-stream"},
      })

      if (!response.ok) {
        throw new Error(`snapshot bootstrap http ${response.status}`)
      }

      const payload = await response.arrayBuffer()
      this.state.lastPipelineStats = pipelineStatsFromHeaders(response.headers)
      await this.handleSnapshot(this.buildSnapshotFrameFromHttpResponse(payload, response.headers))
      return true
    })()
      .catch((error) => {
        if (!this.state.lastGraph && this.state.summary) {
          this.state.summary.textContent = "snapshot bootstrap failed"
        }
        this.state.pushEvent?.("god_view_stream_error", {
          reason: "snapshot_bootstrap_failed",
          message: `${error}`,
        })
        return false
      })
      .finally(() => {
        if (this.state.snapshotBootstrapPromise === promise) this.state.snapshotBootstrapPromise = null
      })

    this.state.snapshotBootstrapPromise = promise
    return promise
  },
  buildSnapshotFrameFromHttpResponse(payloadBuffer, headers) {
    const payload = new Uint8Array(payloadBuffer || new ArrayBuffer(0))
    const out = new Uint8Array(SNAPSHOT_HEADER_BYTES + payload.byteLength)
    out[0] = SNAPSHOT_MAGIC.charCodeAt(0)
    out[1] = SNAPSHOT_MAGIC.charCodeAt(1)
    out[2] = SNAPSHOT_MAGIC.charCodeAt(2)
    out[3] = SNAPSHOT_MAGIC.charCodeAt(3)

    const schemaVersion = parseHeaderInt(headers, "x-sr-god-view-schema")
    const revision = parseHeaderInt(headers, "x-sr-god-view-revision")
    const generatedAtMs = parseGeneratedAtMs(headers, "x-sr-god-view-generated-at")
    const view = new DataView(out.buffer)

    view.setUint8(4, schemaVersion)
    view.setBigUint64(5, BigInt(revision), false)
    view.setBigInt64(13, BigInt(generatedAtMs), false)
    view.setUint32(21, parseHeaderInt(headers, "x-sr-god-view-bitmap-root-bytes"), false)
    view.setUint32(25, parseHeaderInt(headers, "x-sr-god-view-bitmap-affected-bytes"), false)
    view.setUint32(29, parseHeaderInt(headers, "x-sr-god-view-bitmap-healthy-bytes"), false)
    view.setUint32(33, parseHeaderInt(headers, "x-sr-god-view-bitmap-unknown-bytes"), false)
    view.setUint32(37, parseHeaderInt(headers, "x-sr-god-view-bitmap-root-count"), false)
    view.setUint32(41, parseHeaderInt(headers, "x-sr-god-view-bitmap-affected-count"), false)
    view.setUint32(45, parseHeaderInt(headers, "x-sr-god-view-bitmap-healthy-count"), false)
    view.setUint32(49, parseHeaderInt(headers, "x-sr-god-view-bitmap-unknown-count"), false)
    out.set(payload, SNAPSHOT_HEADER_BYTES)

    return out.buffer
  },
  setupSnapshotChannel() {
    const socket = this.ensureGodViewSocket()
    this.state.channel = socket.channel("topology:god_view", {})
    this.registerSnapshotChannelEvents(this.state.channel)
    this.joinSnapshotChannel(this.state.channel)
  },
}

export const godViewLifecycleBootstrapChannelMethods = Object.assign(
  {},
  godViewLifecycleBootstrapChannelCoreMethods,
  godViewLifecycleBootstrapChannelSocketMethods,
  godViewLifecycleBootstrapChannelEventMethods,
)
