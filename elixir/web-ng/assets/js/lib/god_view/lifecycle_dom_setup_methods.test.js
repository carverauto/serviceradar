import {describe, expect, it, vi} from "vitest"

vi.mock("@deck.gl/core", () => ({
  Deck: class MockDeck {
    constructor(props) {
      this.props = props
    }
  },
  OrthographicView: class MockOrthographicView {
    constructor(props) {
      this.props = props
    }
  },
}))

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"

describe("lifecycle_dom_setup_methods", () => {
  it("createDeckInstance routes tooltip/hover/click through deps bridge", () => {
    const originalRaf = globalThis.requestAnimationFrame
    const raf = vi.fn((cb) => cb())
    globalThis.requestAnimationFrame = raf

    const state = {
      canvas: {},
      deck: {redraw: vi.fn()},
      visual: {bg: [10, 10, 10, 255]},
      viewState: {zoom: 1},
      isProgrammaticViewUpdate: false,
      zoomMode: "local",
    }
    const deps = {
      getNodeTooltip: vi.fn(() => ({text: "tooltip"})),
      handleHover: vi.fn(),
      handlePick: vi.fn(),
      setZoomTier: vi.fn(),
      resolveZoomTier: vi.fn(() => "local"),
    }
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    try {
      const instance = ctx.createDeckInstance(800, 600)

      const tooltipResult = instance.props.getTooltip({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
      instance.props.onHover({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
      instance.props.onClick({object: {id: "n1"}, layer: {id: "god-view-nodes"}})

      expect(tooltipResult).toEqual({text: "tooltip"})
      expect(instance.props.pickingRadius).toEqual(8)
      expect(deps.getNodeTooltip).toHaveBeenCalledTimes(1)
      expect(deps.handleHover).toHaveBeenCalledTimes(1)
      expect(deps.handlePick).toHaveBeenCalledTimes(1)
      expect(raf).toHaveBeenCalledTimes(1)
      expect(state.deck.redraw).toHaveBeenCalledWith(true)
    } finally {
      globalThis.requestAnimationFrame = originalRaf
    }
  })

  it("handleDetailsPanelClick navigates device links", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.navigateToHref = vi.fn()

    const link = {getAttribute: (name) => (name === "data-device-href" ? "/devices/sr%3Atest-01" : null)}
    const event = {
      target: {
        closest: (selector) => (selector === "[data-device-href]" ? link : null),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.navigateToHref).toHaveBeenCalledWith("/devices/sr%3Atest-01")
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleDetailsPanelClick focuses node index actions", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))

    const action = {getAttribute: (name) => (name === "data-node-index" ? "7" : null)}
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]" ? null : selector === "[data-node-index]" ? action : null,
      },
      preventDefault: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(deps.focusNodeByIndex).toHaveBeenCalledWith(7, true)
  })

  it("handleDetailsPanelClick routes cluster expansion actions", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.setClusterExpanded = vi.fn()

    const action = {
      getAttribute: (name) => {
        if (name === "data-cluster-id") return "cluster:endpoints:sr:test"
        if (name === "data-cluster-expand") return "true"
        return null
      },
    }
    const event = {
      target: {
        closest: (selector) =>
          selector === "[data-device-href]"
            ? null
            : selector === "[data-cluster-id]"
              ? action
              : null,
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleDetailsPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.setClusterExpanded).toHaveBeenCalledWith("cluster:endpoints:sr:test", true)
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })

  it("handleTooltipPanelClick navigates tooltip links", () => {
    const state = {}
    const deps = {focusNodeByIndex: vi.fn()}
    const ctx = createStateBackedContext(state, deps)
    Object.assign(ctx, bindApi(ctx, godViewLifecycleDomSetupMethods))
    ctx.navigateToHref = vi.fn()

    const link = {getAttribute: (name) => (name === "href" ? "/devices/sr%3Atest-02" : null)}
    const event = {
      target: {
        closest: (selector) => (selector === ".deck-tooltip a[href]" ? link : null),
      },
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    }

    ctx.handleTooltipPanelClick(event)

    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
    expect(ctx.navigateToHref).toHaveBeenCalledWith("/devices/sr%3Atest-02")
    expect(deps.focusNodeByIndex).not.toHaveBeenCalled()
  })
})
