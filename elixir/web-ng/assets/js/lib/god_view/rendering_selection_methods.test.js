import {describe, expect, it} from "vitest"

import {godViewRenderingSelectionMethods} from "./rendering_selection_methods"

function buildContext() {
  const details = {
    className: "hidden",
    innerHTML: "",
    textContent: "",
    classList: {
      add(name) {
        if (!details.className.split(" ").includes(name)) {
          details.className = `${details.className} ${name}`.trim()
        }
      },
      remove(name) {
        details.className = details.className
          .split(" ")
          .filter((token) => token && token !== name)
          .join(" ")
      },
      contains(name) {
        return details.className.split(" ").includes(name)
      },
    },
  }

  return {
    state: {
      details,
      lastGraph: {nodes: []},
      selectedNodeIndex: null,
    },
    nodeIndexLookup: () => new Map(),
    defaultStateReason: () => "No issues detected",
    stateDisplayName: (state) => (state === 0 ? "Critical" : "Unknown"),
    nodeReferenceAction: () => "",
    deviceDetailsHref: godViewRenderingSelectionMethods.deviceDetailsHref,
    parseTypeId: godViewRenderingSelectionMethods.parseTypeId,
    nodeTypeHeroIcon: godViewRenderingSelectionMethods.nodeTypeHeroIcon,
    escapeHtml: godViewRenderingSelectionMethods.escapeHtml,
  }
}

describe("rendering_selection_methods", () => {
  it("renders node detail card with IP and metadata when present", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "sr:test-01",
      label: "core-router",
      state: 0,
      stateReason: "Downstream alarms observed",
      details: {
        id: "sr:test-01",
        ip: "192.0.2.10",
        type: "router",
        type_id: 12,
        vendor: "Acme",
        model: "XR-500",
        last_seen: "2026-02-27T00:00:00Z",
        asn: "64512",
        geo_city: "Austin",
        geo_country: "US",
      },
    })

    expect(ctx.state.details.classList.contains("hidden")).toEqual(false)
    expect(ctx.state.details.innerHTML).toContain("hero-arrows-right-left")
    expect(ctx.state.details.innerHTML).toContain("IP: <button type=\"button\" class=\"link link-primary\" data-device-href=\"/devices/sr%3Atest-01\">192.0.2.10</button>")
    expect(ctx.state.details.innerHTML).toContain("Type: router")
    expect(ctx.state.details.innerHTML).toContain("Vendor/Model: Acme XR-500")
    expect(ctx.state.details.innerHTML).toContain("ASN: 64512")
    expect(ctx.state.details.innerHTML).toContain("Geo: Austin, US")
  })

  it("renders explicit fallback values for missing node detail fields", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "sr:test-02",
      label: "edge-node",
      state: 3,
      details: {},
    })

    expect(ctx.state.details.classList.contains("hidden")).toEqual(false)
    expect(ctx.state.details.innerHTML).not.toContain("hero-")
    expect(ctx.state.details.innerHTML).toContain("IP: unknown")
    expect(ctx.state.details.innerHTML).toContain("Type: unknown")
    expect(ctx.state.details.innerHTML).toContain("Last Seen: unknown")
    expect(ctx.state.details.innerHTML).toContain("ASN: unknown")
    expect(ctx.state.details.innerHTML).toContain("Geo: unknown")
  })

  it("handlePick toggles selected node outside local zoom tier", () => {
    const ctx = buildContext()
    ctx.state.zoomMode = "regional"
    ctx.state.zoomTier = "regional"
    ctx.state.lastGraph = {nodes: [{index: 2}]}
    ctx.state.selectedNodeIndex = null
    ctx.state.selectedEdgeKey = null
    ctx.renderGraph = () => {}
    ctx.edgeLayerId = () => false
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)

    ctx.handlePick({object: {index: 2}, layer: {id: "god-view-nodes"}})
    expect(ctx.state.selectedNodeIndex).toEqual(2)

    ctx.handlePick({object: {index: 2}, layer: {id: "god-view-nodes"}})
    expect(ctx.state.selectedNodeIndex).toEqual(null)
  })

  it("renderSelectionDetails avoids rewriting identical detail HTML", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    let writeCount = 0
    let html = ""
    Object.defineProperty(ctx.state.details, "innerHTML", {
      get() {
        return html
      },
      set(value) {
        writeCount += 1
        html = value
      },
      configurable: true,
    })

    const node = {
      id: "sr:test-03",
      label: "same-node",
      state: 2,
      details: {id: "sr:test-03", ip: "192.0.2.33", type: "switch", type_id: 10},
    }

    ctx.renderSelectionDetails(node)
    ctx.renderSelectionDetails(node)
    expect(writeCount).toEqual(1)
  })
})
