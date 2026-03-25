import {describe, expect, it, vi} from "vitest"

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
    deps: {},
    nodeIndexLookup: () => new Map(),
    defaultStateReason: () => "No issues detected",
    stateDisplayName: (state) => (state === 0 ? "Critical" : "Unknown"),
    nodeReferenceAction: () => "",
    forceDeckRedraw: godViewRenderingSelectionMethods.forceDeckRedraw,
    scheduleSelectionRefresh: godViewRenderingSelectionMethods.scheduleSelectionRefresh,
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

  it("renders camera relay actions for camera-capable nodes", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "sr:camera-01",
      label: "lobby-camera",
      state: 2,
      details: {
        id: "sr:camera-01",
        device_uid: "sr:camera-01",
        ip: "192.0.2.44",
        type: "camera",
        camera_availability_status: "available",
        camera_last_event_message: "Camera reachable from assigned edge agent",
        camera_streams: [
          {
            camera_source_id: "11111111-1111-1111-1111-111111111111",
            display_name: "Lobby Camera",
            stream_profiles: [
              {
                stream_profile_id: "22222222-2222-2222-2222-222222222222",
                profile_name: "Main Stream",
              },
            ],
          },
        ],
      },
    })

    expect(ctx.state.details.innerHTML).toContain("Camera Streams")
    expect(ctx.state.details.innerHTML).toContain("Camera Availability: available")
    expect(ctx.state.details.innerHTML).toContain("Camera Activity: Camera reachable from assigned edge agent")
    expect(ctx.state.details.innerHTML).toContain("Lobby Camera")
    expect(ctx.state.details.innerHTML).toContain("Open Main Stream")
    expect(ctx.state.details.innerHTML).toContain("data-camera-source-id=\"11111111-1111-1111-1111-111111111111\"")
    expect(ctx.state.details.innerHTML).toContain("data-stream-profile-id=\"22222222-2222-2222-2222-222222222222\"")
  })

  it("renders a camera tile-set action for cluster-capable nodes", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "cluster:endpoints:sr:switch-01",
      label: "5 endpoints",
      state: 2,
      details: {
        id: "cluster:endpoints:sr:switch-01",
        cluster_id: "cluster:endpoints:sr:switch-01",
        cluster_kind: "endpoint-summary",
        cluster_camera_tile_count: 3,
        cluster_camera_tiles: [
          {
            camera_source_id: "11111111-1111-1111-1111-111111111111",
            stream_profile_id: "22222222-2222-2222-2222-222222222222",
            device_uid: "sr:camera-01",
            camera_label: "Lobby Camera",
            profile_label: "Main Stream",
          },
          {
            camera_source_id: "33333333-3333-3333-3333-333333333333",
            stream_profile_id: "44444444-4444-4444-4444-444444444444",
            device_uid: "sr:camera-02",
            camera_label: "Loading Dock Camera",
            profile_label: "Main Stream",
          },
        ],
      },
    })

    expect(ctx.state.details.innerHTML).toContain("Cluster Cameras")
    expect(ctx.state.details.innerHTML).toContain("Open Camera Tile Set")
    expect(ctx.state.details.innerHTML).toContain("data-camera-cluster-id=\"cluster:endpoints:sr:switch-01\"")
    expect(ctx.state.details.innerHTML).toContain("data-camera-cluster-tiles=")
  })

  it("handlePick toggles selected node outside local zoom tier", () => {
    const ctx = buildContext()
    ctx.state.zoomMode = "regional"
    ctx.state.zoomTier = "regional"
    ctx.state.lastGraph = {nodes: [{index: 2}]}
    ctx.state.selectedNodeIndex = null
    ctx.state.selectedEdgeKey = null
    ctx.renderGraph = vi.fn()
    ctx.edgeLayerId = () => false
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({object: {index: 2}, layer: {id: "god-view-nodes"}})
    expect(ctx.state.selectedNodeIndex).toEqual(2)

    ctx.handlePick({object: {index: 2}, layer: {id: "god-view-nodes"}})
    expect(ctx.state.selectedNodeIndex).toEqual(null)
  })

  it("handlePick expands endpoint clusters directly from cluster summary nodes", () => {
    const ctx = buildContext()
    ctx.state.lastGraph = {
      nodes: [
        {
          index: 1,
          details: {
            cluster_id: "cluster:endpoints:sr:test",
            cluster_kind: "endpoint-summary",
            cluster_expandable: true,
            cluster_expanded: false,
          },
        },
      ],
    }
    ctx.state.selectedNodeIndex = null
    ctx.state.selectedEdgeKey = null
    ctx.renderGraph = vi.fn()
    ctx.edgeLayerId = () => false
    ctx.deps.setClusterExpanded = vi.fn()
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({object: {index: 0}, layer: {id: "god-view-nodes"}})

    expect(ctx.state.selectedNodeIndex).toEqual(null)
    expect(ctx.state.selectedEdgeKey).toEqual(null)
    expect(ctx.deps.setClusterExpanded).toHaveBeenCalledWith("cluster:endpoints:sr:test", true)
    expect(ctx.renderGraph).toHaveBeenCalledTimes(1)
  })

  it("handlePick expands endpoint clusters from clicked node metadata even when lastGraph lookup is stale", () => {
    const ctx = buildContext()
    ctx.state.lastGraph = {
      nodes: [
        {
          index: 0,
          details: {},
        },
      ],
    }
    ctx.state.selectedNodeIndex = 0
    ctx.state.selectedEdgeKey = "local:stale"
    ctx.renderGraph = vi.fn()
    ctx.edgeLayerId = () => false
    ctx.deps.setClusterExpanded = vi.fn()
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({
      object: {
        index: 0,
        details: {
          cluster_id: "cluster:endpoints:sr:clicked",
          cluster_kind: "endpoint-summary",
          cluster_expandable: true,
          cluster_expanded: false,
        },
      },
      layer: {id: "god-view-node-labels"},
    })

    expect(ctx.state.selectedNodeIndex).toEqual(null)
    expect(ctx.state.selectedEdgeKey).toEqual(null)
    expect(ctx.deps.setClusterExpanded).toHaveBeenCalledWith("cluster:endpoints:sr:clicked", true)
    expect(ctx.renderGraph).toHaveBeenCalledTimes(1)
  })

  it("handlePick ignores empty-canvas clicks", () => {
    const ctx = buildContext()
    ctx.state.selectedNodeIndex = 2
    ctx.state.selectedEdgeKey = "local:test"
    ctx.state.lastGraph = {nodes: [{id: "n1"}]}
    ctx.renderGraph = vi.fn()
    ctx.renderSelectionDetails = vi.fn()
    ctx.edgeLayerId = () => false
    ctx.state.deck = {redraw: vi.fn()}
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.forceDeckRedraw = godViewRenderingSelectionMethods.forceDeckRedraw.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({picked: false, object: null, layer: null})

    expect(ctx.state.selectedNodeIndex).toEqual(2)
    expect(ctx.state.selectedEdgeKey).toEqual("local:test")
    expect(ctx.renderSelectionDetails).not.toHaveBeenCalled()
    expect(ctx.renderGraph).not.toHaveBeenCalled()
    expect(ctx.state.deck.redraw).not.toHaveBeenCalled()
  })

  it("handlePick ignores edge-layer clicks without an interaction key", () => {
    const ctx = buildContext()
    ctx.state.selectedNodeIndex = 1
    ctx.state.selectedEdgeKey = "local:test"
    ctx.state.lastGraph = {nodes: [{id: "n1"}]}
    ctx.state.deck = {redraw: vi.fn()}
    ctx.renderGraph = vi.fn()
    ctx.renderSelectionDetails = vi.fn()
    ctx.edgeLayerId = (layerId) => layerId === "god-view-edges-crust"
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.forceDeckRedraw = godViewRenderingSelectionMethods.forceDeckRedraw.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({picked: false, object: null, layer: {id: "god-view-edges-crust"}})

    expect(ctx.state.selectedNodeIndex).toEqual(1)
    expect(ctx.state.selectedEdgeKey).toEqual("local:test")
    expect(ctx.renderSelectionDetails).not.toHaveBeenCalled()
    expect(ctx.renderGraph).not.toHaveBeenCalled()
    expect(ctx.state.deck.redraw).not.toHaveBeenCalled()
  })

  it("handlePick ignores undefined pick metadata", () => {
    const ctx = buildContext()
    ctx.state.selectedNodeIndex = 2
    ctx.state.selectedEdgeKey = "local:test"
    ctx.state.lastGraph = {nodes: [{id: "n1"}]}
    ctx.state.deck = {redraw: vi.fn()}
    ctx.renderGraph = vi.fn()
    ctx.renderSelectionDetails = vi.fn()
    ctx.edgeLayerId = () => false
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.forceDeckRedraw = godViewRenderingSelectionMethods.forceDeckRedraw.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({object: null, layer: null})

    expect(ctx.state.selectedNodeIndex).toEqual(2)
    expect(ctx.state.selectedEdgeKey).toEqual("local:test")
    expect(ctx.renderSelectionDetails).not.toHaveBeenCalled()
    expect(ctx.renderGraph).not.toHaveBeenCalled()
    expect(ctx.state.deck.redraw).not.toHaveBeenCalled()
  })

  it("handlePick ignores edge-layer clicks without an interaction key even without picked=false", () => {
    const ctx = buildContext()
    ctx.state.selectedNodeIndex = 1
    ctx.state.selectedEdgeKey = "local:test"
    ctx.state.lastGraph = {nodes: [{id: "n1"}]}
    ctx.state.deck = {redraw: vi.fn()}
    ctx.renderGraph = vi.fn()
    ctx.renderSelectionDetails = vi.fn()
    ctx.edgeLayerId = (layerId) => layerId === "god-view-edges-crust"
    ctx.handlePick = godViewRenderingSelectionMethods.handlePick.bind(ctx)
    ctx.forceDeckRedraw = godViewRenderingSelectionMethods.forceDeckRedraw.bind(ctx)
    ctx.scheduleSelectionRefresh = godViewRenderingSelectionMethods.scheduleSelectionRefresh.bind(ctx)

    ctx.handlePick({object: {}, layer: {id: "god-view-edges-crust"}})

    expect(ctx.state.selectedNodeIndex).toEqual(1)
    expect(ctx.state.selectedEdgeKey).toEqual("local:test")
    expect(ctx.renderSelectionDetails).not.toHaveBeenCalled()
    expect(ctx.renderGraph).not.toHaveBeenCalled()
    expect(ctx.state.deck.redraw).not.toHaveBeenCalled()
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

  it("renders explicit cluster controls for endpoint summaries", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "cluster:endpoints:sr:test",
      label: "5 endpoints",
      state: 2,
      details: {
        id: "cluster:endpoints:sr:test",
        type: "endpoint cluster",
        cluster_id: "cluster:endpoints:sr:test",
        cluster_kind: "endpoint-summary",
        cluster_member_count: 5,
        cluster_expandable: true,
        cluster_anchor_label: "u6mesh",
        cluster_expanded: false,
      },
    })

    expect(ctx.state.details.innerHTML).toContain("Cluster Size: 5")
    expect(ctx.state.details.innerHTML).toContain("Cluster Anchor: u6mesh")
    expect(ctx.state.details.innerHTML).toContain("data-cluster-id=\"cluster:endpoints:sr:test\"")
    expect(ctx.state.details.innerHTML).toContain("Expand endpoints")
  })

  it("renders cluster controls on anchor devices without duplicating the anchor line", () => {
    const ctx = buildContext()
    ctx.renderSelectionDetails = godViewRenderingSelectionMethods.renderSelectionDetails.bind(ctx)

    ctx.renderSelectionDetails({
      id: "sr:switch-01",
      label: "access-switch",
      state: 2,
      details: {
        id: "sr:switch-01",
        ip: "192.0.2.44",
        type: "switch",
        type_id: 10,
        cluster_id: "cluster:endpoints:sr:switch-01",
        cluster_kind: "endpoint-anchor",
        cluster_member_count: 1,
        cluster_expandable: true,
        cluster_expanded: false,
        cluster_anchor_id: "sr:switch-01",
        cluster_anchor_label: "access-switch",
      },
    })

    expect(ctx.state.details.innerHTML).toContain("Cluster Size: 1")
    expect(ctx.state.details.innerHTML).toContain("data-cluster-id=\"cluster:endpoints:sr:switch-01\"")
    expect(ctx.state.details.innerHTML).toContain("Expand endpoints")
    expect(ctx.state.details.innerHTML).not.toContain("Cluster Anchor:")
  })
})
