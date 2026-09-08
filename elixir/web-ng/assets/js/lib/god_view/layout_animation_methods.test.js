import {afterEach, describe, expect, it, vi} from "vitest"

import {godViewLayoutAnimationMethods} from "./layout_animation_methods"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("layout_animation_methods", () => {
  it.each(["elk-radial-overview", "elk-scene-detail"])(
    "commits an accepted %s scene atomically without detached intermediate nodes",
    (layoutMode) => {
    const cancelAnimationFrame = vi.fn()
    const requestAnimationFrame = vi.fn(() => 92)
    vi.stubGlobal("cancelAnimationFrame", cancelAnimationFrame)
    vi.stubGlobal("requestAnimationFrame", requestAnimationFrame)

    const previousGraph = {
      _layoutMode: layoutMode,
      _topologyScene: {
        key: "previous-scene",
        nodes: [{id: "a"}, {id: "b"}],
        routes: [{id: "a-b", points: [{x: 0, y: 0}, {x: 20, y: 0}]}],
        bounds: {minX: 0, minY: 0, maxX: 20, maxY: 0},
      },
      nodes: [{id: "a", x: 0, y: 0}, {id: "b", x: 20, y: 0}],
      edges: [],
    }
    const nextGraph = {
      _layoutMode: layoutMode,
      _topologyScene: {
        key: "next-scene",
        nodes: [{id: "a"}, {id: "b"}],
        routes: [{id: "a-b", points: [{x: 100, y: 80}, {x: 240, y: 80}]}],
        bounds: {minX: 100, minY: 80, maxX: 240, maxY: 80},
      },
      nodes: [{id: "a", x: 100, y: 80}, {id: "b", x: 240, y: 80}],
      edges: [],
    }
    const context = {
      state: {pendingAnimationFrame: 0},
      deps: {renderGraph: vi.fn()},
      ...godViewLayoutAnimationMethods,
    }

    context.animateTransition(previousGraph, nextGraph)

    expect(cancelAnimationFrame).toHaveBeenCalledWith(0)
    expect(context.state.pendingAnimationFrame).toBeNull()
    expect(requestAnimationFrame).not.toHaveBeenCalled()
    expect(context.deps.renderGraph).toHaveBeenCalledTimes(1)
    expect(context.deps.renderGraph).toHaveBeenCalledWith(nextGraph)
    const [rendered] = context.deps.renderGraph.mock.calls[0]
    expect(rendered.nodes.map(({x, y}) => [x, y])).toEqual([[100, 80], [240, 80]])
    expect(rendered._topologyScene.routes[0].points).toEqual([
      {x: 100, y: 80},
      {x: 240, y: 80},
    ])
    },
  )
})
