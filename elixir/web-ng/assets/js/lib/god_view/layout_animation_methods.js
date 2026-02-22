export const godViewLayoutAnimationMethods = {
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
}
