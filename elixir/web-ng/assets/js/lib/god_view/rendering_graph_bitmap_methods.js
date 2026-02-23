import {depsRef, stateRef} from "./runtime_refs"
export const godViewRenderingGraphBitmapMethods = {
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
  visibilityMask(states) {
    if (stateRef(this).wasmReady && stateRef(this).wasmEngine) {
      try {
        return stateRef(this).wasmEngine.computeStateMask(states, stateRef(this).filters)
      } catch (_err) {
        stateRef(this).wasmReady = false
      }
    }

    const mask = new Uint8Array(states.length)
    for (let i = 0; i < states.length; i += 1) {
      const category = this.stateCategory(states[i])
      mask[i] = stateRef(this).filters[category] !== false ? 1 : 0
    }
    return mask
  },
  computeTraversalMask(graph) {
    if (!graph || stateRef(this).selectedNodeIndex === null) return null
    if (stateRef(this).selectedNodeIndex >= graph.nodes.length) return null

    if (stateRef(this).wasmReady && stateRef(this).wasmEngine) {
      try {
        return stateRef(this).wasmEngine.computeThreeHopMask(
          graph.nodes.length,
          graph.edgeSourceIndex,
          graph.edgeTargetIndex,
          stateRef(this).selectedNodeIndex,
        )
      } catch (_err) {
        stateRef(this).wasmReady = false
      }
    }

    const mask = new Uint8Array(graph.nodes.length)
    const frontier = [stateRef(this).selectedNodeIndex]
    mask[stateRef(this).selectedNodeIndex] = 1

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
}
