import {describe, expect, it} from "vitest"

import {godViewRenderingTooltipMethods} from "./rendering_tooltip_methods"

function buildContext() {
  return {
    state: {
      lastGraph: {nodes: []},
      hoveredEdgeKey: null,
      hoveredNodeIndex: null,
      selectedEdgeKey: null,
      canvas: {style: {cursor: "grab"}},
    },
    formatPps: (value) => `${value} pps`,
    formatCapacity: (value) => `${value} bps`,
    nodeIndexLookup: () => new Map(),
    defaultStateReason: () => "Unknown state",
    stateDisplayName: (state) => (state === 1 ? "Healthy" : "Unknown"),
    nodeReferenceAction: () => "",
    escapeHtml: (value) => String(value == null ? "" : value),
    renderGraph: () => {},
    edgeLayerId: godViewRenderingTooltipMethods.edgeLayerId,
    displayNodeLabel: godViewRenderingTooltipMethods.displayNodeLabel,
  }
}

describe("rendering_tooltip_methods", () => {
  it("shows IP/type context when node details are present", () => {
    const ctx = buildContext()
    ctx.getNodeTooltip = godViewRenderingTooltipMethods.getNodeTooltip.bind(ctx)

    const tooltip = ctx.getNodeTooltip({
      layer: {id: "god-view-nodes"},
      object: {
        label: "core-router",
        state: 1,
        details: {
          ip: "192.0.2.10",
          type: "router",
          geo_city: "Austin",
          geo_country: "US",
          asn: "64512",
        },
      },
    })

    expect(tooltip.html).toContain("IP: 192.0.2.10")
    expect(tooltip.html).not.toContain("<a ")
    expect(tooltip.html).toContain("Type: router")
    expect(tooltip.html).toContain("Geo: Austin, US")
    expect(tooltip.html).toContain("ASN: 64512")
  })

  it("shows explicit unknown fallbacks for missing node details", () => {
    const ctx = buildContext()
    ctx.getNodeTooltip = godViewRenderingTooltipMethods.getNodeTooltip.bind(ctx)

    const tooltip = ctx.getNodeTooltip({
      layer: {id: "god-view-nodes"},
      object: {
        label: "edge-node",
        state: 3,
        details: {},
      },
    })

    expect(tooltip.html).toContain("IP: unknown")
    expect(tooltip.html).toContain("Type: unknown")
    expect(tooltip.html).toContain("State: Unknown")
  })

  it("uses a friendly title for unresolved placeholder nodes", () => {
    const ctx = buildContext()
    ctx.getNodeTooltip = godViewRenderingTooltipMethods.getNodeTooltip.bind(ctx)
    ctx.displayNodeLabel = godViewRenderingTooltipMethods.displayNodeLabel.bind(ctx)

    const tooltip = ctx.getNodeTooltip({
      layer: {id: "god-view-nodes"},
      object: {
        label: "sr:18794bab-1a5c-4266-bc75-561b0afd7341",
        state: 3,
        details: {
          ip: "unknown",
          type: "unknown",
          cluster_placeholder: true,
        },
      },
    })

    expect(tooltip.html).toContain("Unidentified endpoint")
    expect(tooltip.html).not.toContain("sr:18794bab-1a5c-4266-bc75-561b0afd7341")
  })

  it("shows expand and collapse hints for cluster nodes", () => {
    const ctx = buildContext()
    ctx.getNodeTooltip = godViewRenderingTooltipMethods.getNodeTooltip.bind(ctx)

    const collapsedTooltip = ctx.getNodeTooltip({
      layer: {id: "god-view-nodes"},
      object: {
        label: "5 endpoints",
        state: 1,
        details: {
          cluster_id: "cluster:endpoints:sr:test",
          cluster_kind: "endpoint-summary",
          cluster_expandable: true,
          cluster_expanded: false,
        },
      },
    })

    const expandedTooltip = ctx.getNodeTooltip({
      layer: {id: "god-view-nodes"},
      object: {
        label: "5 endpoints",
        state: 1,
        details: {
          cluster_id: "cluster:endpoints:sr:test",
          cluster_kind: "endpoint-anchor",
          cluster_expandable: true,
          cluster_expanded: true,
        },
      },
    })

    expect(collapsedTooltip.html).toContain("Click to expand endpoints")
    expect(expandedTooltip.html).toContain("Click to collapse endpoints")
  })

  it("handleHover updates cursor to pointer over nodes and grab otherwise", () => {
    const ctx = buildContext()
    ctx.handleHover = godViewRenderingTooltipMethods.handleHover.bind(ctx)

    ctx.handleHover({layer: {id: "god-view-nodes"}, object: {index: 3}})
    expect(ctx.state.hoveredNodeIndex).toEqual(3)
    expect(ctx.state.canvas.style.cursor).toEqual("pointer")

    ctx.handleHover({layer: {id: "god-view-node-labels"}, object: {index: 5}})
    expect(ctx.state.hoveredNodeIndex).toEqual(5)
    expect(ctx.state.canvas.style.cursor).toEqual("pointer")

    ctx.handleHover({layer: {id: "god-view-nodes"}, object: null})
    expect(ctx.state.hoveredNodeIndex).toEqual(null)
    expect(ctx.state.canvas.style.cursor).toEqual("grab")
  })
})
