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
    const state = {
      canvas: {},
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

    const instance = ctx.createDeckInstance(800, 600)

    const tooltipResult = instance.props.getTooltip({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
    instance.props.onHover({object: {id: "n1"}, layer: {id: "god-view-nodes"}})
    instance.props.onClick({object: {id: "n1"}, layer: {id: "god-view-nodes"}})

    expect(tooltipResult).toEqual({text: "tooltip"})
    expect(deps.getNodeTooltip).toHaveBeenCalledTimes(1)
    expect(deps.handleHover).toHaveBeenCalledTimes(1)
    expect(deps.handlePick).toHaveBeenCalledTimes(1)
  })
})
