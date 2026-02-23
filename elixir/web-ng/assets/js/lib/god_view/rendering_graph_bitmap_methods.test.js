import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphBitmapMethods} from "./rendering_graph_bitmap_methods"

describe("rendering_graph_bitmap_methods", () => {
  it("ensureBitmapMetadata falls back to derived counts when metadata is empty", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {}, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphBitmapMethods))
    ctx.stateCategory = (s) => {
      if (s === 0) return "root_cause"
      if (s === 1) return "affected"
      if (s === 2) return "healthy"
      return "unknown"
    }

    const nodes = [{state: 0}, {state: 1}, {state: 2}, {state: 3}]
    const out = ctx.ensureBitmapMetadata({}, nodes)

    expect(out.root_cause.count).toEqual(1)
    expect(out.affected.count).toEqual(1)
    expect(out.healthy.count).toEqual(1)
    expect(out.unknown.count).toEqual(1)
    expect(out.root_cause.bytes).toEqual(1)
  })

  it("ensureBitmapMetadata keeps provided non-empty metadata", () => {
    const state = {}
    const ctx = createStateBackedContext(state, {}, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphBitmapMethods))
    ctx.stateCategory = (s) => {
      if (s === 0) return "root_cause"
      if (s === 1) return "affected"
      if (s === 2) return "healthy"
      return "unknown"
    }

    const meta = {
      root_cause: {bytes: 2, count: 3},
      affected: {bytes: 1, count: 0},
      healthy: {bytes: 1, count: 0},
      unknown: {bytes: 1, count: 0},
    }

    const out = ctx.ensureBitmapMetadata(meta, [{state: 0}])
    expect(out.root_cause.bytes).toEqual(2)
    expect(out.root_cause.count).toEqual(3)
    expect(out.affected.bytes).toEqual(1)
    expect(out.unknown.count).toEqual(0)
  })

  it("computeTraversalMask fallback traverses up to 3 hops", () => {
    const state = {
      selectedNodeIndex: 0,
      wasmReady: false,
      wasmEngine: null,
    }
    const ctx = createStateBackedContext(state, {}, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphBitmapMethods))

    const graph = {
      nodes: [{}, {}, {}, {}, {}],
      edges: [
        {source: 0, target: 1},
        {source: 1, target: 2},
        {source: 2, target: 3},
        {source: 3, target: 4},
      ],
      edgeSourceIndex: new Uint32Array([0, 1, 2, 3]),
      edgeTargetIndex: new Uint32Array([1, 2, 3, 4]),
    }

    const mask = ctx.computeTraversalMask(graph)

    expect(Array.from(mask)).toEqual([1, 1, 1, 1, 0])
  })

  it("visibilityMask fallback obeys filters", () => {
    const state = {
      wasmReady: false,
      wasmEngine: null,
      filters: {root_cause: true, affected: false, healthy: true, unknown: false},
    }
    const ctx = createStateBackedContext(state, {}, Object.keys(state))
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphBitmapMethods))
    ctx.stateCategory = (s) => {
      if (s === 0) return "root_cause"
      if (s === 1) return "affected"
      if (s === 2) return "healthy"
      return "unknown"
    }

    const mask = ctx.visibilityMask(Uint8Array.from([0, 1, 2, 3]))
    expect(Array.from(mask)).toEqual([1, 0, 1, 0])
  })
})
