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
  it("omits one-sided geographic conversations instead of inventing an ocean endpoint", () => {
    const links = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.2.12",
          target_label: "104.18.11.60",
          geo_from: [-93.6258, 44.7636],
          geo_to: null,
          topology_from: [-120, 20],
          topology_to: [-56, 26],
          bytes: 1024,
        },
      ],
      "netflow",
    )

    expect(links).toEqual([])
  })

  it("spreads colocated local endpoints so LAN conversations stay visible", () => {
    const [link] = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.2.3",
          target_label: "192.168.10.31",
          geo_from: [-93.4687, 44.9212],
          geo_to: [-93.4687, 44.9212],
          bytes: 4096,
        },
      ],
      "netflow",
    )

    expect(link.geoMapped).toBe(true)
    expect(link.from).toEqual([-93.4687, 44.9212])
    expect(link.to[0]).not.toEqual(link.from[0])
    expect(link.to[1]).not.toEqual(link.from[1])
  })

  it("keeps fully mapped geographic conversations", () => {
    const [link] = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.2.12",
          target_label: "8.8.8.8",
          geo_from: [-93.6258, 44.7636],
          geo_to: [-97.822, 37.751],
          topology_from: [-120, 20],
          topology_to: [-56, 26],
          bytes: 1024,
        },
      ],
      "netflow",
    )

    expect(link).toMatchObject({
      from: [-93.6258, 44.7636],
      to: [-97.822, 37.751],
      sourceLabel: "10.0.2.12",
      targetLabel: "8.8.8.8",
      geoMapped: true,
    })
  })

  it("rejects zero and out-of-range geographic coordinates", () => {
    const links = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {source_label: "a", target_label: "b", geo_from: [0, 0], geo_to: [-93, 44]},
        {source_label: "c", target_label: "d", geo_from: [-93, 44], geo_to: [181, 45]},
      ],
      "netflow",
    )

    expect(links).toEqual([])
  })

  it("keeps schematic fallback points in topology view", () => {
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
      "topology_traffic",
    )

    expect(link).toMatchObject({from: [-120, 20], to: [-90, 30]})
  })

  it("normalizes attribution metadata for the map popup", () => {
    const [link] = OperationsTrafficMap._normalizeTrafficLinks(
      [
        {
          source_label: "10.0.2.11",
          target_label: "192.168.10.96",
          geo_from: [-93.6258, 44.7636],
          geo_to: [-93.4687, 44.9212],
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
  function positioningContext({popupHeight, popupWidth = 288}) {
    const anchorDetails = {className: "", innerHTML: "", style: {}, offsetHeight: popupHeight, offsetWidth: popupWidth}

    return {anchorDetails}
  }

  function withViewport({innerWidth, innerHeight}, run) {
    vi.stubGlobal("window", {innerWidth, innerHeight})
    try {
      run()
    } finally {
      vi.unstubAllGlobals()
    }
  }

  it("caps a tall popup to the viewport height and clamps its top into view", () => {
    withViewport({innerWidth: 1200, innerHeight: 500}, () => {
      // Popup taller than the 12px-margin viewport band (500 - 24 = 476), clicked near the bottom.
      const ctx = positioningContext({popupHeight: 640})

      OperationsTrafficMap._positionAnchorDetails.call(ctx, {left: 300, top: 470, width: 8, height: 8}, {offsetY: 3})

      // Height is capped to the viewport band so the body scrolls instead of clipping.
      expect(ctx.anchorDetails.style.maxHeight).toEqual("476px")
      // Top is clamped so the whole capped popup (476px) stays fully within the viewport.
      expect(ctx.anchorDetails.style.top).toEqual("12px")
    })
  })

  it("anchors a short popup near the click and keeps it inside the viewport", () => {
    withViewport({innerWidth: 1200, innerHeight: 500}, () => {
      const ctx = positioningContext({popupHeight: 120})

      OperationsTrafficMap._positionAnchorDetails.call(ctx, {left: 300, top: 80, width: 8, height: 8}, {offsetY: 12})

      // Short popup fits, so it opens at the anchor (viewport-relative) without scroll.
      expect(ctx.anchorDetails.style.top).toEqual("92px")
      const top = Number.parseInt(ctx.anchorDetails.style.top, 10)
      expect(top + 120).toBeLessThanOrEqual(500 - 12)
    })
  })

  it("clamps a click near the right edge back inside the viewport", () => {
    withViewport({innerWidth: 400, innerHeight: 500}, () => {
      const ctx = positioningContext({popupHeight: 120, popupWidth: 300})

      OperationsTrafficMap._positionAnchorDetails.call(ctx, {left: 380, top: 100, width: 8, height: 8}, {offsetX: 12})

      // maxLeft = 400 - 12(margin) - 300(popup) = 88, so the popup is pulled left to fit.
      expect(ctx.anchorDetails.style.left).toEqual("88px")
      const left = Number.parseInt(ctx.anchorDetails.style.left, 10)
      expect(left + 300).toBeLessThanOrEqual(400 - 12)
    })
  })
})

describe("OperationsTrafficMap body-level overlay", () => {
  it("appends the popup to document.body, not the map shell", () => {
    const shellAppendChild = vi.fn()
    const bodyAppendChild = vi.fn()
    const created = {addEventListener: vi.fn(), style: {}, className: "", innerHTML: ""}

    vi.stubGlobal("document", {
      body: {appendChild: bodyAppendChild},
      createElement: vi.fn(() => created),
    })

    try {
      const ctx = {
        el: {parentElement: {appendChild: shellAppendChild}},
        anchorDetails: null,
        _onAnchorDetailsClick: vi.fn(),
        _renderAnchorDetails: OperationsTrafficMap._renderAnchorDetails,
      }

      const result = ctx._renderAnchorDetails("sr-ops-anchor-details", "<strong>Flow path</strong>", "<span>row</span>")

      expect(result).toBe(created)
      // Reparented to the document root, escaping the map shell overflow clip.
      expect(bodyAppendChild).toHaveBeenCalledWith(created)
      expect(shellAppendChild).not.toHaveBeenCalled()
      // A dismissable close affordance is rendered and wired once at creation.
      expect(created.innerHTML).toContain("sr-ops-anchor-details-close")
      expect(created.addEventListener).toHaveBeenCalledWith("click", ctx._onAnchorDetailsClick)
    } finally {
      vi.unstubAllGlobals()
    }
  })
})

describe("OperationsTrafficMap overlay lifecycle", () => {
  it("dismisses the overlay when its close button is clicked", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      svgOverlay: null,
      _onAnchorDetailsClick: OperationsTrafficMap._onAnchorDetailsClick,
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onAnchorDetailsClick.call(
      ctx,
      clickEvent({matches: new Set([".sr-ops-anchor-details-close"])}),
    )

    expect(remove).toHaveBeenCalled()
    expect(ctx.anchorDetails).toBeNull()
  })

  it("keeps the overlay open for non-close clicks inside it (drill-down links)", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      _onAnchorDetailsClick: OperationsTrafficMap._onAnchorDetailsClick,
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onAnchorDetailsClick.call(ctx, clickEvent())

    expect(remove).not.toHaveBeenCalled()
    expect(ctx.anchorDetails).toEqual({remove})
  })

  it("dismisses the overlay on an outside click", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      svgOverlay: null,
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onDocumentClick.call(ctx, clickEvent())

    expect(remove).toHaveBeenCalled()
    expect(ctx.anchorDetails).toBeNull()
  })

  it("keeps the overlay open for a click inside it", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onDocumentClick.call(
      ctx,
      clickEvent({matches: new Set([".sr-ops-anchor-details"])}),
    )

    expect(remove).not.toHaveBeenCalled()
    expect(ctx.anchorDetails).toEqual({remove})
  })

  it("dismisses the overlay when Escape is pressed", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      svgOverlay: null,
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onDocumentKeyDown.call(ctx, {key: "Escape"})

    expect(remove).toHaveBeenCalled()
    expect(ctx.anchorDetails).toBeNull()
  })

  it("ignores non-Escape keys", () => {
    const remove = vi.fn()
    const ctx = {
      anchorDetails: {remove},
      _hideAnchorDetails: OperationsTrafficMap._hideAnchorDetails,
    }

    OperationsTrafficMap._onDocumentKeyDown.call(ctx, {key: "a"})

    expect(remove).not.toHaveBeenCalled()
    expect(ctx.anchorDetails).toEqual({remove})
  })
})
