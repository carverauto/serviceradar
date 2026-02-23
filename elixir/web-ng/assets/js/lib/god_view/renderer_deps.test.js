import {describe, expect, it, vi} from "vitest"

import {buildLayoutDeps, buildLifecycleDeps, buildRenderingDeps} from "./renderer_deps"

function makeContext() {
  return {
    layout: {
      resolveZoomTier: vi.fn((...args) => ["layout.resolveZoomTier", ...args]),
      setZoomTier: vi.fn((...args) => ["layout.setZoomTier", ...args]),
      reshapeGraph: vi.fn((...args) => ["layout.reshapeGraph", ...args]),
      geoGridData: vi.fn((...args) => ["layout.geoGridData", ...args]),
      prepareGraphLayout: vi.fn((...args) => ["layout.prepareGraphLayout", ...args]),
      graphTopologyStamp: vi.fn((...args) => ["layout.graphTopologyStamp", ...args]),
      sameTopology: vi.fn((...args) => ["layout.sameTopology", ...args]),
      animateTransition: vi.fn((...args) => ["layout.animateTransition", ...args]),
    },
    rendering: {
      renderGraph: vi.fn((...args) => ["rendering.renderGraph", ...args]),
      stateDisplayName: vi.fn((...args) => ["rendering.stateDisplayName", ...args]),
      edgeTopologyClass: vi.fn((...args) => ["rendering.edgeTopologyClass", ...args]),
      focusNodeByIndex: vi.fn((...args) => ["rendering.focusNodeByIndex", ...args]),
      ensureBitmapMetadata: vi.fn((...args) => ["rendering.ensureBitmapMetadata", ...args]),
      pipelineStatsFromHeaders: vi.fn((...args) => ["rendering.pipelineStatsFromHeaders", ...args]),
      normalizePipelineStats: vi.fn((...args) => ["rendering.normalizePipelineStats", ...args]),
      normalizeDisplayLabel: vi.fn((...args) => ["rendering.normalizeDisplayLabel", ...args]),
      edgeTopologyClassFromLabel: vi.fn((...args) => ["rendering.edgeTopologyClassFromLabel", ...args]),
    },
    lifecycle: {
      ensureDeck: vi.fn((...args) => ["lifecycle.ensureDeck", ...args]),
      decodeArrowGraph: vi.fn((...args) => ["lifecycle.decodeArrowGraph", ...args]),
    },
  }
}

describe("renderer_deps", () => {
  it("buildLayoutDeps forwards to rendering namespace", () => {
    const context = makeContext()
    const deps = buildLayoutDeps(context)

    expect(deps.renderGraph("g")).toEqual(["rendering.renderGraph", "g"])
    expect(deps.stateDisplayName(2)).toEqual(["rendering.stateDisplayName", 2])
    expect(deps.edgeTopologyClass({label: "x"})).toEqual(["rendering.edgeTopologyClass", {label: "x"}])
  })

  it("buildRenderingDeps forwards to layout/lifecycle namespaces", () => {
    const context = makeContext()
    const deps = buildRenderingDeps(context)

    expect(deps.resolveZoomTier(1.2)).toEqual(["layout.resolveZoomTier", 1.2])
    expect(deps.setZoomTier("regional", true)).toEqual(["layout.setZoomTier", "regional", true])
    expect(deps.reshapeGraph({nodes: []})).toEqual(["layout.reshapeGraph", {nodes: []}])
    expect(deps.geoGridData()).toEqual(["layout.geoGridData"])
    expect(deps.ensureDeck()).toEqual(["lifecycle.ensureDeck"])
  })

  it("buildLifecycleDeps forwards to rendering/layout/lifecycle namespaces", () => {
    const context = makeContext()
    const deps = buildLifecycleDeps(context)

    expect(deps.renderGraph("g")).toEqual(["rendering.renderGraph", "g"])
    expect(deps.focusNodeByIndex(3, true)).toEqual(["rendering.focusNodeByIndex", 3, true])
    expect(deps.ensureBitmapMetadata({}, [])).toEqual(["rendering.ensureBitmapMetadata", {}, []])
    expect(deps.pipelineStatsFromHeaders({})).toEqual(["rendering.pipelineStatsFromHeaders", {}])
    expect(deps.normalizePipelineStats({})).toEqual(["rendering.normalizePipelineStats", {}])
    expect(deps.decodeArrowGraph(new Uint8Array([1]))).toEqual(["lifecycle.decodeArrowGraph", new Uint8Array([1])])
    expect(deps.normalizeDisplayLabel("a", "b")).toEqual(["rendering.normalizeDisplayLabel", "a", "b"])
    expect(deps.edgeTopologyClassFromLabel("x")).toEqual(["rendering.edgeTopologyClassFromLabel", "x"])
    expect(deps.setZoomTier("global", false)).toEqual(["layout.setZoomTier", "global", false])
    expect(deps.resolveZoomTier(0.1)).toEqual(["layout.resolveZoomTier", 0.1])
    expect(deps.prepareGraphLayout({}, 1, "t")).toEqual(["layout.prepareGraphLayout", {}, 1, "t"])
    expect(deps.graphTopologyStamp({})).toEqual(["layout.graphTopologyStamp", {}])
    expect(deps.sameTopology({}, {}, "t", 1)).toEqual(["layout.sameTopology", {}, {}, "t", 1])
    expect(deps.animateTransition({}, {})).toEqual(["layout.animateTransition", {}, {}])
  })
})
