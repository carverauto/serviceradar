// @vitest-environment happy-dom
import {describe, expect, it, vi} from "vitest"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {
  buildHorizonEgressGraphLayout,
  formatLossPct,
  formatPortSpeedMbps,
  formatRttUs,
  horizonEntityBadges,
  horizonInspectUrl,
} from "./horizon_egress_shared"
import {godViewRenderingHorizonEgressMethods} from "./rendering_horizon_egress_methods"
import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"
import {godViewRenderingSelectionMethods} from "./rendering_selection_methods"
import {godViewRenderingTooltipMethods} from "./rendering_tooltip_methods"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"
import {godViewLifecycleBootstrapEventLayerMethods} from "./lifecycle_bootstrap_event_layer_methods"
import {visualForTheme} from "./lifecycle_bootstrap_state_defaults_methods"
import WorldMapRenderer from "./WorldMapRenderer"
import {decodeWorldTile} from "./world_tile_decode"
import {worldTileIpc, worldTileKey} from "./fixtures/world_tile_ipc"

vi.mock("../GodViewRenderer", () => ({default: class {}}))

function sampleEgressPayload() {
  return {
    max_hops: 3,
    truncated: false,
    egress_devices: [
      {
        id: "sr:edge-rtr-01",
        kind: "Device",
        label: "edge-rtr-01",
        ip: "192.0.2.1",
        if_name: "et-0/0/0",
        if_index: 12,
        egress_source: "manual",
        port_speed_mbps: 10000,
      },
    ],
    external_nodes: [
      {
        id: "198.51.100.0/24",
        kind: "Prefix",
        label: "198.51.100.0/24",
        asn: 64512,
        rpki_state: "invalid",
        rtbh_active: false,
        outage_state: "degraded",
        irr_status: "mismatch",
      },
      {
        id: "asn:64512",
        kind: "ASN",
        label: "Example Transit",
        asn: 64512,
        region: "us-east",
        rpki_state: "valid",
        rtbh_active: true,
        outage_state: "outage",
        port_speed_mbps: 100000,
      },
      {
        id: "saas:cloud-app-east",
        kind: "SaasTarget",
        label: "Example SaaS East",
        outage_state: "healthy",
      },
    ],
    edges: [
      {
        src_id: "sr:edge-rtr-01",
        dst_id: "198.51.100.0/24",
        kind: "EGRESSES_TO",
        egress_source: "manual",
        if_name: "et-0/0/0",
        port_speed_mbps: 10000,
        avg_rtt_us: 4200,
        loss_pct: 0.0,
      },
      {
        src_id: "asn:64512",
        dst_id: "198.51.100.0/24",
        kind: "ORIGIN_PREFIX",
        border_asn: 64512,
        port_speed_mbps: 100000,
        avg_rtt_us: 12500,
        loss_pct: 1.0,
      },
      {
        src_id: "asn:64512",
        dst_id: "saas:cloud-app-east",
        kind: "ANYCAST_SERVES",
        avg_rtt_us: 24000,
        loss_pct: 4.5,
      },
    ],
  }
}

describe("horizon_egress_shared & rendering_horizon_egress_methods", () => {
  it("formats port speeds, severity badges, and /dashboards/horizon hash drill-down URLs", () => {
    expect(formatPortSpeedMbps(10000)).toBe("10G")
    expect(formatPortSpeedMbps(100000)).toBe("100G")
    expect(formatPortSpeedMbps(2500)).toBe("2.5G")
    expect(formatPortSpeedMbps(500)).toBe("500M")

    expect(
      horizonEntityBadges({
        outage_state: "outage",
        rpki_state: "invalid",
        rtbh_active: true,
        port_speed_mbps: 100000,
      }),
    ).toEqual(["[OUTAGE]", "[RPKI INVALID]", "[RTBH]", "100G"])

    expect(
      horizonInspectUrl({id: "asn:64512", kind: "ASN", asn: 64512}),
    ).toBe("/dashboards/horizon#tab=bgp_sankey&origin_asn=64512")

    expect(
      horizonInspectUrl({id: "198.51.100.0/24", kind: "Prefix", asn: 64512}),
    ).toBe("/dashboards/horizon#tab=bgp_sankey&origin_asn=64512&prefix=198.51.100.0%2F24")

    expect(
      horizonInspectUrl({id: "saas:cloud-app-east", kind: "SaasTarget"}),
    ).toBe("/dashboards/horizon#tab=multipath_dag&target_id=cloud-app-east")

    expect(
      horizonInspectUrl({id: "target:checkout-api", kind: "SaasTarget"}),
    ).toBe("/dashboards/horizon#tab=multipath_dag&target_id=checkout-api")

    expect(
      horizonInspectUrl({id: "ixp:iad-01", kind: "IXP"}),
    ).toBe("/dashboards/horizon#tab=weather_map")

    // Null/empty/zero ASNs on preceding connected nodes must not shadow valid positive ASNs
    expect(
      horizonInspectUrl(
        {id: "198.51.100.0/24", kind: "Prefix", asn: null},
        [
          {id: "saas:cloud-app-east", kind: "SaasTarget", asn: null},
          {id: "asn:0", kind: "ASN", asn: 0},
          {id: "asn:64512", kind: "ASN", asn: 64512},
        ],
      ),
    ).toBe("/dashboards/horizon#tab=bgp_sankey&origin_asn=64512&prefix=198.51.100.0%2F24")

    expect(
      horizonInspectUrl({id: "198.51.100.0/24", kind: "Prefix", asn: ""}, [{id: "asn:64512", asn: 64512}]),
    ).toBe("/dashboards/horizon#tab=bgp_sankey&origin_asn=64512&prefix=198.51.100.0%2F24")

    expect(
      horizonInspectUrl({id: "198.51.100.0/24", kind: "Prefix", asn: 0}),
    ).toBe("/dashboards/horizon#tab=bgp_sankey&prefix=198.51.100.0%2F24")
  })

  it("does not coerce null/undefined/empty avg_rtt_us or loss_pct to 0us / 0.0%", () => {
    expect(formatRttUs(null)).toBe("")
    expect(formatRttUs(undefined)).toBe("")
    expect(formatRttUs("")).toBe("")
    expect(formatRttUs("   ")).toBe("")
    expect(formatRttUs(0)).toBe("0us")
    expect(formatRttUs(4200)).toBe("4.2ms")

    expect(formatLossPct(null)).toBe("")
    expect(formatLossPct(undefined)).toBe("")
    expect(formatLossPct("")).toBe("")
    expect(formatLossPct("   ")).toBe("")
    expect(formatLossPct(0)).toBe("0.0%")
    expect(formatLossPct(4.5)).toBe("4.5%")
  })

  it("places external nodes in collision-free tiers outside internal node bounds and builds layers", () => {
    const internalNodes = [
      {id: "sr:edge-rtr-01", position: [120, 200, 0], details: {device_uid: "sr:edge-rtr-01"}},
      {id: "sr:core-sw-01", position: [280, 320, 0], details: {device_uid: "sr:core-sw-01"}},
    ]

    const layout = buildHorizonEgressGraphLayout(sampleEgressPayload(), internalNodes, {
      mode: "cartesian",
    })

    expect(layout.nodes).toHaveLength(3)
    expect(layout.edges).toHaveLength(3)
    expect(layout.pulseNodes.map((n) => n.id)).toEqual(["asn:64512"])

    // External nodes must sit strictly above internal minY (200) and never collide.
    for (const node of layout.nodes) {
      expect(node.position[1]).toBeLessThan(200)
    }
    const prefixNode = layout.nodes.find((n) => n.id === "198.51.100.0/24")
    const asnNode = layout.nodes.find((n) => n.id === "asn:64512")
    const saasNode = layout.nodes.find((n) => n.id === "saas:cloud-app-east")
    expect(prefixNode.hopDepth).toBe(1)
    expect(asnNode.hopDepth).toBe(2)
    expect(saasNode.hopDepth).toBe(3)
    expect(asnNode.position[1]).toBeLessThan(prefixNode.position[1])
    expect(saasNode.position[1]).toBeLessThan(asnNode.position[1])
    expect(asnNode.labelText).toContain("[OUTAGE]")
    expect(asnNode.labelText).toContain("[RTBH]")
    expect(asnNode.labelText).toContain("100G")

    const state = {
      topologyLayers: {backbone: true, inferred: false, endpoints: true, mtr_paths: true, horizon_egress: true},
      horizonEgressData: sampleEgressPayload(),
      selectedHorizonEntity: null,
      hoveredHorizonKey: null,
      animationPhase: 0.25,
      visual: visualForTheme("dark"),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingHorizonEgressMethods))

    const layers = ctx.buildHorizonEgressLayers(internalNodes)
    expect(layers.map((l) => l.id)).toEqual([
      "god-view-horizon-egress-edges",
      "god-view-horizon-egress-pulse",
      "god-view-horizon-egress-nodes-halo",
      "god-view-horizon-egress-nodes-ring",
      "god-view-horizon-egress-nodes",
      "god-view-horizon-egress-labels",
    ])
    expect(layers[0]).toBeInstanceOf(LineLayer)
    expect(layers[0].props.pickable).toBe(true)
    expect(layers[1]).toBeInstanceOf(ScatterplotLayer)
    expect(layers[5]).toBeInstanceOf(TextLayer)

    // Graceful empty when disabled or unmatched
    state.topologyLayers.horizon_egress = false
    expect(ctx.buildHorizonEgressLayers(internalNodes)).toEqual([])
    state.topologyLayers.horizon_egress = true
    expect(ctx.buildHorizonEgressLayers([{id: "sr:unrelated", position: [0, 0, 0]}])).toEqual([])
  })

  it("renders inspector details and tooltips for external nodes, egress edges, and internal egress devices", () => {
    const details = {
      className: "hidden",
      innerHTML: "",
      textContent: "",
      style: {},
      classList: {
        add(name) {
          if (!details.className.split(" ").includes(name)) details.className = `${details.className} ${name}`.trim()
        },
        remove(name) {
          details.className = details.className.split(" ").filter((t) => t && t !== name).join(" ")
        },
        contains(name) {
          return details.className.split(" ").includes(name)
        },
      },
    }
    const state = {
      details,
      el: {dataset: {timezone: "Etc/UTC"}},
      lastGraph: {nodes: []},
      selectedNodeIndex: null,
      selectedEdgeKey: null,
      selectedHorizonEntity: null,
      hoveredEdgeKey: null,
      hoveredHorizonKey: null,
      topologyLayers: {horizon_egress: true},
      horizonEgressData: sampleEgressPayload(),
      visual: visualForTheme("dark"),
    }
    const ctx = createStateBackedContext(state, {})
    Object.assign(
      ctx,
      bindApi(ctx, godViewRenderingHorizonEgressMethods),
      bindApi(ctx, godViewRenderingGraphCoreMethods),
      bindApi(ctx, godViewRenderingSelectionMethods),
      bindApi(ctx, godViewRenderingTooltipMethods),
      bindApi(ctx, godViewLifecycleDomSetupMethods),
      {
        nodeIndexLookup: () => new Map(),
        defaultStateReason: () => "Healthy",
        stateDisplayName: () => "Healthy",
        nodeReferenceAction: () => "",
        refreshGraphLayersForViewState: vi.fn(),
        formatPps: () => "0 pps",
        formatCapacity: () => "0 bps",
      },
    )

    const layout = buildHorizonEgressGraphLayout(sampleEgressPayload(), [
      {id: "sr:edge-rtr-01", position: [100, 200, 0], details: {device_uid: "sr:edge-rtr-01"}},
    ])
    const asnNode = layout.nodes.find((n) => n.id === "asn:64512")
    const egressEdge = layout.edges.find((e) => e.src_id === "sr:edge-rtr-01")

    const nodeTooltip = ctx.getNodeTooltip({layer: {id: "god-view-horizon-egress-nodes"}, object: asnNode})
    expect(nodeTooltip.html).toContain("AS64512 · Example Transit")
    expect(nodeTooltip.html).toContain("[OUTAGE]")
    expect(nodeTooltip.html).toContain("100G")

    const edgeTooltip = ctx.getNodeTooltip({layer: {id: "god-view-horizon-egress-edges"}, object: egressEdge})
    expect(edgeTooltip.html).toContain("EGRESSES_TO")
    expect(edgeTooltip.html).toContain("10G")
    expect(edgeTooltip.html).toContain("4.2ms")

    // Pick external node -> populates details with hash drill-down link
    state.lastGraph = null
    ctx.handlePick({layer: {id: "god-view-horizon-egress-nodes"}, object: asnNode})
    expect(state.selectedHorizonEntity).toBe(asnNode)
    expect(details.classList.contains("hidden")).toBe(false)
    expect(details.innerHTML).toContain('data-horizon-href="/dashboards/horizon#tab=bgp_sankey&amp;origin_asn=64512"')
    expect(details.innerHTML).toContain("[OUTAGE]")
    expect(details.innerHTML).toContain("[RTBH]")

    // handleDetailsPanelClick delegates [data-horizon-href] to navigateToHref
    ctx.navigateToHref = vi.fn()
    const horizonLink = {getAttribute: (name) => (name === "data-horizon-href" ? "/dashboards/horizon#tab=bgp_sankey&origin_asn=64512" : null)}
    ctx.handleDetailsPanelClick({
      target: {closest: (selector) => (selector === "[data-horizon-href]" ? horizonLink : null)},
      preventDefault: vi.fn(),
      stopPropagation: vi.fn(),
    })
    expect(ctx.navigateToHref).toHaveBeenCalledWith("/dashboards/horizon#tab=bgp_sankey&origin_asn=64512")

    // Internal Device inspector enrichment when device is an egress router
    ctx.renderSelectionDetails({
      id: "sr:edge-rtr-01",
      label: "edge-rtr-01",
      state: 2,
      details: {id: "sr:edge-rtr-01", ip: "192.0.2.1", type: "router"},
    })
    expect(details.innerHTML).toContain("Internet Egress / Horizon")
    expect(details.innerHTML).toContain("Egress Source: manual")
    expect(details.innerHTML).toContain("Port Speed: 10G")
    expect(details.innerHTML).toContain("data-horizon-href")
  })

  it("caches and replays god_view:horizon_egress_data in WorldMapRenderer and renders World-mode panel & layers", () => {
    const handlers = {}
    const detailHandlers = new Map()
    const el = document.createElement("div")
    const renderer = new WorldMapRenderer(el, vi.fn(), (name, fn) => {
      handlers[name] = fn
    })
    renderer.el = el
    renderer.deck = {device: {submit() {}}, setProps: vi.fn()}
    renderer.horizonEgressPanel = document.createElement("section")
    renderer.panel = document.createElement("div")
    renderer.detailHandlers = detailHandlers

    const geometry = decodeWorldTile(
      worldTileIpc({
        metadata: {device_count: 1},
        edges: [],
        nodes: [{x: 1000, y: 1000, label: "edge-rtr-01", details: {id: "sr:edge-rtr-01", type: "device", cluster_member_count: 1}}],
      }),
      worldTileKey,
    )
    renderer.cache.manifest = {layout_version: worldTileKey.layout_version, zmax: 16, node_count: 1}
    renderer.cache.visible.set("1/1/0", worldTileKey)
    renderer.cache.entries.set("1/1/0", {geometry, dirty: false})

    const payload = sampleEgressPayload()
    const layersSpy = vi.fn()
    const egressSpy = vi.fn()
    detailHandlers.set("god_view:set_topology_layers", layersSpy)
    detailHandlers.set("god_view:horizon_egress_data", egressSpy)

    renderer.setSceneControl("god_view:set_topology_layers", {layers: {horizon_egress: true}})
    renderer.setSceneControl("god_view:horizon_egress_data", payload)

    expect(renderer.sceneControls.get("god_view:horizon_egress_data")).toEqual(payload)
    expect(layersSpy).toHaveBeenCalledWith({layers: {horizon_egress: true}})
    expect(egressSpy).toHaveBeenCalledWith(payload)
    expect(renderer.horizonEgressPanel.hidden).toBe(false)
    expect(renderer.horizonEgressPanel.textContent).toContain("Internet Egress / Horizon")
    expect(renderer.horizonEgressPanel.textContent).toContain("edge-rtr-01")
    expect(renderer.horizonEgressPanel.textContent).toContain("[OUTAGE]")
    // Healthy saas:cloud-app-east must not inflate the alert count beyond the 2 unhealthy nodes.
    expect(renderer.horizonEgressPanel.textContent).toContain("2 alerts")
    expect(renderer.horizonEgressPanel.innerHTML).toContain("/dashboards/horizon#tab=bgp_sankey")

    const lastCall = renderer.deck.setProps.mock.calls.at(-1)[0]
    expect(lastCall.layers.some((l) => l.id === "world-horizon-egress-edges")).toBe(true)
    expect(lastCall.layers.some((l) => l.id === "world-horizon-egress-nodes")).toBe(true)
    expect(lastCall.layers.some((l) => l.id === "world-horizon-egress-labels")).toBe(true)

    // Unmeasured edges must not display fake RTT 0us or loss 0.0% in World tooltip or selection panel.
    const unmeasuredEdge = {
      horizonEntityType: "edge",
      src_id: "sr:edge-rtr-01",
      dst_id: "198.51.100.0/24",
      kind: "EGRESSES_TO",
      avg_rtt_us: null,
      loss_pct: null,
    }
    const worldEdgeTip = renderer.worldTooltip({
      layer: {id: "world-horizon-egress-edges"},
      object: unmeasuredEdge,
    })
    expect(worldEdgeTip.text).toBe("EGRESSES_TO: sr:edge-rtr-01 → 198.51.100.0/24")

    renderer.showHorizonEgressSelection(unmeasuredEdge)
    expect(renderer.panel.hidden).toBe(false)
    expect(renderer.panel.textContent).not.toContain("0us")
    expect(renderer.panel.textContent).not.toContain("0.0%")

    // Toggling horizon_egress off must dismiss an active Horizon selection panel.
    renderer.setSceneControl("god_view:set_topology_layers", {layers: {horizon_egress: false}})
    expect(renderer.panel.hidden).toBe(true)
    expect(renderer.horizonEgressPanel.hidden).toBe(true)
  })

  it("traverses INTERFACE_PREFIX + ORIGIN_PREFIX + multi-hop chains without duplicate edges and preserves healthy 0-alert count", () => {
    const internalNodes = [
      {id: "sr:gw-1", position: [100, 300, 0], details: {device_uid: "sr:gw-1"}},
    ]
    const payload = {
      max_hops: 4,
      truncated: false,
      egress_devices: [{id: "sr:gw-1", kind: "Device", label: "gw-1", egress_source: "prefix_origin"}],
      external_nodes: [
        {id: "198.51.100.0/24", kind: "Prefix", label: "198.51.100.0/24", asn: 64512, outage_state: "healthy"},
        {id: "asn:64512", kind: "ASN", label: "Origin Transit", asn: 64512, outage_state: "healthy", rpki_state: "valid"},
        {id: "asn:64513", kind: "ASN", label: "Upstream Provider", asn: 64513, outage_state: "healthy"},
        {id: "saas:github", kind: "SaasTarget", label: "SaaS Target", outage_state: "healthy"},
      ],
      edges: [
        {src_id: "sr:gw-1", dst_id: "198.51.100.0/24", kind: "INTERFACE_PREFIX", avg_rtt_us: null, loss_pct: null},
        {src_id: "asn:64512", dst_id: "198.51.100.0/24", kind: "ORIGIN_PREFIX", avg_rtt_us: null, loss_pct: null},
        // Duplicate ORIGIN_PREFIX edge should be deduplicated
        {src_id: "asn:64512", dst_id: "198.51.100.0/24", kind: "ORIGIN_PREFIX", avg_rtt_us: null, loss_pct: null},
        {src_id: "asn:64512", dst_id: "asn:64513", kind: "AS_REL_PROVIDER", avg_rtt_us: null, loss_pct: null},
        {src_id: "asn:64513", dst_id: "saas:github", kind: "ANYCAST_SERVES", avg_rtt_us: null, loss_pct: null},
      ],
    }

    const layout = buildHorizonEgressGraphLayout(payload, internalNodes, {mode: "cartesian"})
    expect(layout.nodes.map((n) => n.id)).toEqual([
      "198.51.100.0/24",
      "asn:64512",
      "asn:64513",
      "saas:github",
    ])
    expect(layout.nodes.find((n) => n.id === "198.51.100.0/24").hopDepth).toBe(1)
    expect(layout.nodes.find((n) => n.id === "asn:64512").hopDepth).toBe(2)
    expect(layout.nodes.find((n) => n.id === "asn:64513").hopDepth).toBe(3)
    expect(layout.nodes.find((n) => n.id === "saas:github").hopDepth).toBe(4)
    expect(layout.edges).toHaveLength(4)

    // Reverse/forward ORIGIN_PREFIX direction also continues to work
    const forwardOriginLayout = buildHorizonEgressGraphLayout(
      {
        ...payload,
        edges: [
          {src_id: "sr:gw-1", dst_id: "198.51.100.0/24", kind: "INTERFACE_PREFIX"},
          {src_id: "198.51.100.0/24", dst_id: "asn:64512", kind: "ORIGIN_PREFIX"},
          {src_id: "asn:64512", dst_id: "saas:github", kind: "ANYCAST_SERVES"},
        ],
      },
      internalNodes,
    )
    expect(forwardOriginLayout.nodes.map((n) => n.id)).toEqual([
      "198.51.100.0/24",
      "asn:64512",
      "saas:github",
    ])

    // Healthy external nodes produce 0 alerts in WorldMapRenderer panel
    const el = document.createElement("div")
    const renderer = new WorldMapRenderer(el, vi.fn(), vi.fn())
    renderer.horizonEgressPanel = document.createElement("section")
    renderer.panel = document.createElement("div")
    renderer.setSceneControl("god_view:set_topology_layers", {layers: {horizon_egress: true}})
    renderer.setSceneControl("god_view:horizon_egress_data", payload)
    expect(renderer.horizonEgressPanel.textContent).not.toContain("alerts")
    expect(renderer.horizonEgressPanel.textContent).toContain("1 egress · 4 external · 5 links")
  })

  it("omits null avg_rtt_us/loss_pct from selection/tooltip and clears Horizon selection when horizon_egress toggles off", () => {
    const details = {
      className: "hidden",
      innerHTML: "",
      textContent: "",
      style: {},
      classList: {
        add(name) {
          if (!details.className.split(" ").includes(name)) details.className = `${details.className} ${name}`.trim()
        },
        remove(name) {
          details.className = details.className.split(" ").filter((t) => t && t !== name).join(" ")
        },
        contains(name) {
          return details.className.split(" ").includes(name)
        },
      },
    }
    const handlers = {}
    const state = {
      details,
      el: {dataset: {timezone: "Etc/UTC"}},
      deck: {setProps: vi.fn()},
      lastGraph: {nodes: [], edges: []},
      selectedNodeIndex: null,
      selectedEdgeKey: null,
      selectedHorizonEntity: null,
      hoveredEdgeKey: null,
      hoveredHorizonKey: null,
      topologyLayers: {backbone: true, inferred: false, endpoints: false, mtr_paths: true, horizon_egress: true},
      horizonEgressData: sampleEgressPayload(),
      visual: visualForTheme("dark"),
      handleEvent(name, fn) {
        handlers[name] = fn
      },
    }
    const ctx = createStateBackedContext(state, {
      ensureDeck: vi.fn(),
      reshapeGraph: (g) => ({...g, shape: "local"}),
      renderGraph: (g) => ctx.renderGraph(g),
    })
    Object.assign(
      ctx,
      bindApi(ctx, godViewLifecycleBootstrapEventLayerMethods),
      bindApi(ctx, godViewRenderingHorizonEgressMethods),
      bindApi(ctx, godViewRenderingGraphCoreMethods),
      bindApi(ctx, godViewRenderingSelectionMethods),
      bindApi(ctx, godViewRenderingTooltipMethods),
      bindApi(ctx, godViewLifecycleDomSetupMethods),
      {
        autoFitViewState: vi.fn(),
        buildVisibleGraphData: () => ({
          edgeData: [],
          edgeLabelData: [],
          nodeData: [],
          rootPulseNodes: [],
          selectedVisibleNode: null,
          nodeFrame: {records: [], selectedNodeIndex: null},
        }),
        buildGraphLayers: () => [],
      },
    )

    const unmeasuredEdge = {
      horizonEntityType: "edge",
      src_id: "sr:edge-rtr-01",
      dst_id: "198.51.100.0/24",
      kind: "EGRESSES_TO",
      avg_rtt_us: null,
      loss_pct: null,
    }
    const edgeTooltip = ctx.getHorizonEgressEdgeTooltip(unmeasuredEdge)
    expect(edgeTooltip.html).not.toContain("Avg RTT:")
    expect(edgeTooltip.html).not.toContain("Loss:")

    ctx.renderHorizonSelectionDetails(unmeasuredEdge)
    expect(details.innerHTML).not.toContain("Avg RTT:")
    expect(details.innerHTML).not.toContain("Loss:")
    expect(details.classList.contains("hidden")).toBe(false)

    ctx.registerLayerEvents()
    state.selectedHorizonEntity = unmeasuredEdge
    state.hoveredHorizonKey = "horizon-edge:sr%3Aedge-rtr-01:198.51.100.0%2F24:EGRESSES_TO"

    handlers["god_view:set_topology_layers"]({layers: {horizon_egress: false}})
    expect(state.topologyLayers.horizon_egress).toBe(false)
    expect(state.selectedHorizonEntity).toBeNull()
    expect(state.hoveredHorizonKey).toBeNull()
    expect(details.classList.contains("hidden")).toBe(true)
  })

  it("walks upstream AS_REL_PROVIDER (dst -> src) and bidirectional AS_REL_PEER with cycle protection", () => {
    const internalNodes = [
      {id: "sr:tonka-gw", position: [200, 300, 0], details: {device_uid: "sr:tonka-gw"}},
    ]
    const payload = {
      max_hops: 4,
      truncated: false,
      egress_devices: [{id: "sr:tonka-gw", kind: "Device", label: "unifi.tonka.carverauto.dev", egress_source: "manual", port_speed_mbps: 1000}],
      external_nodes: [
        {id: "asn:10242", kind: "ASN", label: "US Internet Corp", asn: 10242, outage_state: "up"},
        {id: "asn:174", kind: "ASN", label: "Cogent Communications, Inc.", asn: 174, outage_state: "up"},
        {id: "asn:15267", kind: "ASN", label: "702 Communications", asn: 15267, outage_state: "up"},
        {id: "asn:209", kind: "ASN", label: "CenturyLink", asn: 209, outage_state: "up"},
        {id: "ixp:14", kind: "IXP", label: "NYIIX", port_speed_mbps: 100000, outage_state: "up"},
        {id: "saas:github", kind: "SaasTarget", label: "GitHub", outage_state: "up"},
      ],
      edges: [
        {src_id: "sr:tonka-gw", dst_id: "asn:10242", kind: "EGRESSES_TO", egress_source: "manual", port_speed_mbps: 1000},
        // provider -> customer orientation from Horizon
        {src_id: "asn:174", dst_id: "asn:10242", kind: "AS_REL_PROVIDER"},
        // bidirectional peers + cycle back to asn:174
        {src_id: "asn:174", dst_id: "asn:15267", kind: "AS_REL_PEER"},
        {src_id: "asn:209", dst_id: "asn:174", kind: "AS_REL_PEER"},
        {src_id: "asn:15267", dst_id: "asn:174", kind: "AS_REL_PEER"},
        {src_id: "asn:174", dst_id: "ixp:14", kind: "IXP_MEMBER"},
        {src_id: "asn:15267", dst_id: "saas:github", kind: "ANYCAST_SERVES"},
      ],
    }

    const layout = buildHorizonEgressGraphLayout(payload, internalNodes, {mode: "cartesian"})
    expect(layout.nodes.find((n) => n.id === "asn:10242")?.hopDepth).toBe(1)
    expect(layout.nodes.find((n) => n.id === "asn:174")?.hopDepth).toBe(2)
    expect(layout.nodes.find((n) => n.id === "asn:15267")?.hopDepth).toBe(3)
    expect(layout.nodes.find((n) => n.id === "asn:209")?.hopDepth).toBe(3)
    expect(layout.nodes.find((n) => n.id === "ixp:14")?.hopDepth).toBe(3)
    expect(layout.nodes.find((n) => n.id === "saas:github")?.hopDepth).toBe(4)
    expect(layout.edges).toHaveLength(7)
  })
})
