import {describe, expect, it, vi} from "vitest"

import OperationsTrafficMap from "./OperationsTrafficMap"

function classListMock() {
  return {
    add: vi.fn(),
    remove: vi.fn(),
    toggle: vi.fn(),
  }
}

function pointerEvent({x = 100, y = 100, pointerId = 7, button = 0} = {}) {
  return {
    button,
    clientX: x,
    clientY: y,
    pointerId,
    preventDefault: vi.fn(),
    stopPropagation: vi.fn(),
    target: {closest: vi.fn(() => null)},
  }
}

function clickEvent({matches = new Set()} = {}) {
  return {
    preventDefault: vi.fn(),
    stopPropagation: vi.fn(),
    target: {
      closest: vi.fn((selector) => (matches.has(selector) ? {dataset: {}} : null)),
    },
  }
}

function makeContext() {
  const parentClassList = classListMock()

  return {
    mapView: "netflow",
    currentViewBox: "0 0 100 50",
    autoViewBox: "0 0 100 50",
    dragState: null,
    suppressNextClick: false,
    svgOverlay: {
      getBoundingClientRect: vi.fn(() => ({width: 1000, height: 500})),
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn(),
    },
    el: {
      parentElement: {
        classList: parentClassList,
      },
    },
    _setMapViewBox: vi.fn(),
    _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    parentClassList,
  }
}

describe("OperationsTrafficMap netflow panning", () => {
  it("does not translate the viewBox for a click-sized pointer move", () => {
    const ctx = makeContext()
    const down = pointerEvent()
    const move = pointerEvent({x: 103, y: 102})
    const up = pointerEvent()

    OperationsTrafficMap._onMapPointerDown.call(ctx, down)
    OperationsTrafficMap._onMapPointerMove.call(ctx, move)
    OperationsTrafficMap._onMapPointerUp.call(ctx, up)

    expect(ctx.currentViewBox).toEqual("0 0 100 50")
    expect(ctx._setMapViewBox).not.toHaveBeenCalled()
    expect(ctx.suppressNextClick).toEqual(false)
    expect(ctx.parentClassList.add).not.toHaveBeenCalledWith("is-netflow-panning")
  })

  it("translates the viewBox once pointer movement exceeds the pan threshold", () => {
    const ctx = makeContext()
    const down = pointerEvent()
    const move = pointerEvent({x: 130, y: 115})
    const up = pointerEvent()

    OperationsTrafficMap._onMapPointerDown.call(ctx, down)
    OperationsTrafficMap._onMapPointerMove.call(ctx, move)
    OperationsTrafficMap._onMapPointerUp.call(ctx, up)

    expect(ctx.currentViewBox).not.toEqual("0 0 100 50")
    expect(ctx._setMapViewBox).toHaveBeenCalledWith(ctx.currentViewBox)
    expect(ctx.suppressNextClick).toEqual(true)
    expect(ctx.parentClassList.add).toHaveBeenCalledWith("is-netflow-panning")
    expect(ctx.parentClassList.remove).toHaveBeenCalledWith("is-netflow-panning")
  })
})

describe("OperationsTrafficMap netflow links", () => {
  it("keeps non-GeoIP conversations using topology fallback points", () => {
    const [link] = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.0.10",
          target_label: "10.0.0.20",
          topology_from: [-120, 20],
          topology_to: [-90, 30],
          bytes: 1024,
        },
      ],
      "netflow",
    )

    expect(link).toMatchObject({
      from: [-120, 20],
      to: [-90, 30],
      sourceLabel: "10.0.0.10",
      targetLabel: "10.0.0.20",
      geoMapped: false,
    })
  })

  it("normalizes attribution metadata for the map popup", () => {
    const [link] = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.2.11",
          target_label: "192.168.10.96",
          topology_from: [-120, 20],
          topology_to: [-90, 30],
          bytes: 70,
          attributed_flow_count: 3,
          attribution_agent_id: "agent-k8s-cp3-worker1",
          attribution_comm: "gobgpd",
          attribution_pid: 45246,
          attribution_pod_namespace: "demo",
          attribution_pod_name: "gobgpd-0",
          attribution_container_name: "gobgpd",
          attribution_image: "registry.example/gobgpd:latest",
        },
      ],
      "netflow",
    )

    expect(link).toMatchObject({
      attributedFlowCount: 3,
      attributionAgentId: "agent-k8s-cp3-worker1",
      attributionComm: "gobgpd",
      attributionPid: 45246,
      attributionPodNamespace: "demo",
      attributionPodName: "gobgpd-0",
      attributionContainerName: "gobgpd",
      attributionImage: "registry.example/gobgpd:latest",
    })
  })
})

describe("OperationsTrafficMap netflow details dismissal", () => {
  it("removes node details when the SVG background is clicked", () => {
    const remove = vi.fn()
    const ctx = {
      ...makeContext(),
      anchorDetails: {remove},
    }

    OperationsTrafficMap._onSvgOverlayClick.call(ctx, clickEvent())

    expect(remove).toHaveBeenCalled()
    expect(ctx.anchorDetails).toBeNull()
  })

  it("removes node details when a non-interactive map-shell area is clicked", () => {
    const remove = vi.fn()
    const ctx = {
      ...makeContext(),
      anchorDetails: {remove},
    }

    OperationsTrafficMap._onMapShellClick.call(ctx, clickEvent())

    expect(remove).toHaveBeenCalled()
    expect(ctx.anchorDetails).toBeNull()
  })

  it("keeps node details when links inside the details panel are clicked", () => {
    const anchorDetails = {remove: vi.fn()}
    const ctx = {
      ...makeContext(),
      anchorDetails,
    }

    OperationsTrafficMap._onMapShellClick.call(
      ctx,
      clickEvent({matches: new Set([".sr-ops-anchor-details"])}),
    )

    expect(anchorDetails.remove).not.toHaveBeenCalled()
    expect(ctx.anchorDetails).toBe(anchorDetails)
  })
})

describe("OperationsTrafficMap flow detail links", () => {
  it("renders drilldown links for clicked attributed NetFlow paths", () => {
    const anchorDetails = {className: "", innerHTML: "", style: {}, offsetWidth: 288, offsetHeight: 320}
    const parent = {
      appendChild: vi.fn(),
      getBoundingClientRect: vi.fn(() => ({width: 800, height: 500, left: 0, top: 0, right: 800, bottom: 500})),
    }
    const flowNode = {
      getBoundingClientRect: vi.fn(() => ({width: 20, height: 20, left: 120, top: 80})),
      dataset: {
        sourceLabel: "Kansas City, US, 34.117.62.14",
        targetLabel: "Carver, MN",
        sourceIp: "34.117.62.14",
        targetIp: "10.0.2.13",
        bytes: "36249",
        packets: "50",
        flowCount: "1",
        attributedFlowCount: "1",
        attributionAgentId: "agent-k8s-cp3-worker3",
        attributionComm: "cosign",
        attributionPid: "2663619",
      },
    }

    const ctx = {
      el: {parentElement: parent},
      anchorDetails,
      _renderAnchorDetails: OperationsTrafficMap._renderAnchorDetails,
      _positionAnchorDetails: OperationsTrafficMap._positionAnchorDetails,
    }

    OperationsTrafficMap._showFlowDetails.call(ctx, flowNode)

    expect(ctx.anchorDetails.innerHTML).toContain("Flow details")
    expect(ctx.anchorDetails.innerHTML).toContain("tab=netflows")
    expect(ctx.anchorDetails.innerHTML).toContain("Attributed flows")
    expect(ctx.anchorDetails.innerHTML).toContain("/observability/flows/attributed")
    // Pinned header + scrollable body keep the trailing drill-down reachable.
    expect(ctx.anchorDetails.innerHTML).toContain("sr-ops-anchor-details-header")
    expect(ctx.anchorDetails.innerHTML).toContain("sr-ops-anchor-details-body")
  })
})

describe("OperationsTrafficMap anchor details positioning", () => {
  function positioningContext({parentRect, popupHeight, popupWidth = 288}) {
    const anchorDetails = {className: "", innerHTML: "", style: {}, offsetHeight: popupHeight, offsetWidth: popupWidth}

    return {
      el: {parentElement: {getBoundingClientRect: () => parentRect}},
      anchorDetails,
    }
  }

  it("caps a tall popup to the visible band and top-justifies it so the header stays on-screen", () => {
    const parentRect = {left: 0, top: 0, right: 800, bottom: 500, width: 800, height: 500}
    // Popup taller than the 12px-margin band (500 - 24 = 476) anchored near the bottom.
    const ctx = positioningContext({parentRect, popupHeight: 640})

    OperationsTrafficMap._positionAnchorDetails.call(ctx, {left: 120, top: 470, width: 8, height: 8}, {offsetY: 3})

    // Height is capped to the available band so the body scrolls instead of clipping.
    expect(ctx.anchorDetails.style.maxHeight).toEqual("476px")
    // Top is clamped to the margin so the header (and everything below it) stays visible.
    expect(ctx.anchorDetails.style.top).toEqual("12px")
  })

  it("anchors a short popup near the click without forcing it off the top", () => {
    const parentRect = {left: 0, top: 0, right: 800, bottom: 500, width: 800, height: 500}
    const ctx = positioningContext({parentRect, popupHeight: 120})

    OperationsTrafficMap._positionAnchorDetails.call(ctx, {left: 120, top: 80, width: 8, height: 8}, {offsetY: 12})

    // Short popup fits, so it opens at the anchor and stays within the band.
    expect(ctx.anchorDetails.style.top).toEqual("92px")
    const top = Number.parseInt(ctx.anchorDetails.style.top, 10)
    expect(top + 120).toBeLessThanOrEqual(488)
  })
})
