import {describe, expect, it, vi} from "vitest"
import {AttributeManager, Deck, OrthographicViewport} from "@deck.gl/core"
import ViewManager from "../../../node_modules/@deck.gl/core/dist/lib/view-manager.js"
import {AnimationLoop} from "@luma.gl/engine"
import {godViewLifecycleDomSetupMethods} from "./lifecycle_dom_setup_methods"
import WorldTileLayer from "./world_tile_layer"
import WorldMapRenderer from "./WorldMapRenderer"
import {decodeWorldTile} from "./world_tile_decode"
import {worldTileIpc, worldTileKey, worldTileRevision} from "./fixtures/world_tile_ipc"

vi.mock("../GodViewRenderer", () => ({default: class {}}))

function tile() {
  return {...decodeWorldTile(worldTileIpc(), worldTileKey), generation: 1}
}

function overlay(geometry) {
  return {
    layout_version: worldTileKey.layout_version, generation: 1, revision: worldTileRevision,
    health: {glyphs: [{id: geometry.nodes[0].id, counts: {total: 70000, healthy: 70000, unavailable: 0, unknown: 0}}]},
    flow: {edges: [{id: geometry.edges[0].id, total_relations: 90000, selected_relations: 90000,
      forward: {status: "measured", animate: true, packets_per_second: 120, octets_per_second: 12000},
      reverse: {status: "unknown", animate: false}}]},
  }
}

function layers(geometry, telemetry) {
  const layer = new WorldTileLayer({id: "synthetic-world", overlays: new Map([["1/1/0", telemetry]])})
  return layer.renderSubLayers({id: "synthetic-tile", data: geometry}).filter(Boolean)
}

describe("world tile rendering contract", () => {
  it.each(["world", "detail"])("submits %s draws before camera updates retire attribute buffers", async mode => {
    vi.useFakeTimers()
    const domNode = () => ({style: {}, append() {}, replaceChildren() {}, setAttribute() {}, addEventListener() {}})
    vi.stubGlobal("document", {createElement: domNode})
    vi.stubGlobal("window", {location: {pathname: "/topology"}, addEventListener() {}, removeEventListener() {}})
    vi.stubGlobal("ResizeObserver", class {observe() {} disconnect() {}})
    vi.spyOn(Deck.prototype, "_createDevice").mockReturnValue(new Promise(() => {}))
    vi.spyOn(Deck.prototype, "_createAnimationLoop").mockReturnValue({start() {}, stop() {}, destroy() {}, setProps() {}})
    const renderer = new WorldMapRenderer({...domNode(), clientWidth: 800, clientHeight: 600}, vi.fn(), vi.fn())
    vi.spyOn(renderer, "poll").mockResolvedValue()
    let deck
    let attributes
    try {
      if (mode === "world") {
        await renderer.mount()
        deck = renderer.deck
      } else {
        deck = godViewLifecycleDomSetupMethods.createDeckInstance.call({state: {canvas: domNode()}}, 800, 600)
      }
      let pending = []
      let submitted = 0
      const retired = []
      const device = {
        type: "webgpu",
        createBuffer: props => ({...props, destroyed: false, write() {},
          destroy() {this.destroyed = true; retired.push(this)}, delete() {this.destroy()},
        }),
        submit() {
          for (const buffer of pending) {
            if (buffer.destroyed) throw new Error("instanceIconDefs submitted after destruction")
          }
          submitted += pending.length
          pending = []
        },
      }
      attributes = new AttributeManager(device, {id: "dynamic-icons"})
      attributes.addInstanced({instanceIconDefs: {size: 4, accessor: "getIcon"}})
      const resize = count => {
        attributes.invalidateAll()
        attributes.update({data: Array.from({length: count}, () => [0, 0, 8, 8]), numInstances: count, props: {getIcon: row => row}})
      }
      resize(1)
      deck.setProps({_animate: true})
      deck.layerManager = {context: {device}, updateLayers() {}, getLayers: () => [], finalize() {}}
      deck.effectManager = {getEffects: () => [], finalize() {}}
      deck.widgetManager = {onRedraw() {}, finalize() {}}
      deck.deckRenderer = {renderLayers() {pending.push(attributes.getAttributes().instanceIconDefs.getBuffer())}, finalize() {}}
      deck.viewManager = {getViewports: () => [], getViews: () => ({}), updateViewStates: () => resize(256), finalize() {}}
      for (const method of ["_getFrameStats", "_getMetrics", "_updateCursor", "_pickAndCallback"]) vi.spyOn(deck, method).mockImplementation(() => {})
      // Run pinned Deck/Luma ordering and real attribute allocation. GPU draws,
      // queue validation and the camera-triggered layer refresh are simulated.
      const loop = {device, props: {onRender: () => deck._onRenderFrame()}, _getAnimationProps: () => ({})}
      AnimationLoop.prototype._renderFrame.call(loop, {})
      expect(retired.length).toBeGreaterThan(0)
      expect(submitted).toBe(1)
      // An explicit redraw also has to finish its commands before layer teardown.
      deck.redraw("selection")
      attributes.finalize()
      attributes = null
      device.submit()
      expect(submitted).toBe(2)
    } finally {
      attributes?.finalize()
      if (mode === "world") renderer.destroy()
      else deck?.finalize()
      vi.restoreAllMocks()
      vi.unstubAllGlobals()
      vi.useRealTimers()
    }
  })

  it("resets the displayed map camera repeatedly after interactive pan and zoom", async () => {
    vi.useFakeTimers()
    const handlers = new Map()
    const domNode = () => ({style: {}, append() {}, replaceChildren() {}, setAttribute() {}, addEventListener() {}})
    vi.stubGlobal("document", {createElement: domNode})
    vi.stubGlobal("window", {location: {pathname: "/topology"}, addEventListener() {}, removeEventListener() {}})
    vi.stubGlobal("ResizeObserver", class {observe() {} disconnect() {}})
    // Keep Deck's real camera lifecycle; only GPU startup and drawing are absent.
    vi.spyOn(Deck.prototype, "_createDevice").mockReturnValue(new Promise(() => {}))
    vi.spyOn(Deck.prototype, "_createAnimationLoop").mockReturnValue({start() {}, stop() {}, destroy() {}, setProps() {}})
    const renderer = new WorldMapRenderer({...domNode(), clientWidth: 800, clientHeight: 600}, vi.fn(),
      (name, handler) => handlers.set(name, handler))
    vi.spyOn(renderer, "poll").mockResolvedValue()
    try {
      await renderer.mount()
      const deck = renderer.deck
      Object.assign(deck, {width: 800, height: 600})
      deck.viewManager = new ViewManager({
        views: deck._getViews(), width: 800, height: 600,
        viewState: deck._getViewState(), eventManager: null,
        onViewStateChange: params => deck._onViewStateChange(params),
      })
      deck.layerManager = {activateViewport() {}, setProps() {}, finalize() {}}
      deck.effectManager = {setProps() {}, finalize() {}}
      deck.deckRenderer = {setProps() {}, finalize() {}}
      deck.deckPicker = {setProps() {}, finalize() {}}
      deck.widgetManager = {setProps() {}, finalize() {}}
      // An invented occupied world fits to target [128, 128].
      renderer.cache.manifest = {bounds: [[0, 0], [8388608, 8388608]], zmax: 16}
      handlers.get("god_view:reset_view")()
      for (const zoom of [4, 6]) {
        deck._onViewStateChange({viewId: "god-view-world", viewState: {target: [300, 200, 0], zoom}})
        expect(deck.getViewports()[0].zoom).toBe(zoom)
        expect(deck.getViewports()[0].target).toEqual([300, 200, 0])
        handlers.get("god_view:reset_view")()
        const viewport = deck.getViewports()[0]
        expect(viewport.target).toEqual([128, 128, 0])
        expect(viewport.zoom).toBeCloseTo(Math.log2(460 / 256))
      }
    } finally {
      renderer.destroy()
      vi.restoreAllMocks()
      vi.unstubAllGlobals()
      vi.useRealTimers()
    }
  })

  it("admits nonoverlapping labels across tile seams and readmits them on zoom", async () => {
    const layer = new WorldTileLayer({id: "label-seams", maxZoom: 1})
    const viewport = zoom => new OrthographicViewport({width: 1024, height: 512, target: [256, 100, 0], zoom})
    const tileset = new layer.props.TilesetClass({
      tileSize: 512, extent: layer.props.extent, minZoom: 1, maxZoom: 1,
      refinementStrategy: layer.props.refinementStrategy,
      getTileData: ({index}) => {
        const xs = index.y === 0 ? (index.x === 0 ? [250, 252, 254] : [256, 258, 260]) : []
        return {...tile(), key: {...worldTileKey, ...index}, edges: [],
          positions: new Float64Array(xs.flatMap(x => [x, 100])),
          nodes: xs.map((x, index) => ({id: `sr:label-${x}.example.test`, label: `host-${x}.example.test`, kind: "device", index, count: 1})),
        }
      },
    })
    layer.state = {tileset}
    try {
      layer.context = {viewport: viewport(1)}
      // No glyph atlas should be initialized before any labels are admitted.
      expect(layer.renderLayers().flat(Infinity).filter(item => item?.id.endsWith("-labels"))).toHaveLength(0)
      const rendered = async zoom => {
        layer.context = {viewport: viewport(zoom)}
        tileset.update(layer.context.viewport)
        await vi.waitFor(() => expect(tileset.isLoaded).toBe(true))
        tileset.update(layer.context.viewport)
        const labels = layer.renderLayers().flat(Infinity).filter(item => item?.id.endsWith("-labels") && layer.filterSubLayer({layer: item}))
        const boxes = []
        for (const label of labels) {
          // Consume the label offset through deck's actual attribute allocator.
          // Zoom must retain a single broadcast row, not resize this buffer.
          const device = {type: "webgpu", createBuffer: vi.fn(props => ({...props, delete: vi.fn(), destroy: vi.fn(), write: vi.fn()}))}
          const attributes = new AttributeManager(device, {id: "label-offset"})
          attributes.addInstanced({instancePixelOffset: {size: 2, accessor: "getPixelOffset"}})
          try {
            attributes.update({data: label.props.data, numInstances: label.props.data.length, props: label.props})
            expect(attributes.getAttributes().instancePixelOffset.isConstant).toBe(true)
            for (const numInstances of [128, 1]) {
              attributes.invalidateAll()
              attributes.update({data: label.props.data, numInstances, props: label.props})
            }
            expect(device.createBuffer).toHaveBeenCalledTimes(1)
            expect(device.createBuffer.mock.calls[0][0].byteLength).toBe(8)
          } finally {
            attributes.finalize()
          }
          const value = (key, row) => typeof label.props[key] === "function" ? label.props[key](row) : label.props[key]
          for (const row of label.props.data) {
            const text = value("getText", row)
            if (!text) continue
            const [x, y] = layer.context.viewport.project(value("getPosition", row))
            const [dx, dy] = value("getPixelOffset", row)
            const width = text.length * 11
            const height = Math.ceil(11 * 1.25)
            const left = x + dx - ({start: 0, middle: width / 2, end: width}[value("getTextAnchor", row)])
            const top = y + dy - ({top: 0, center: height / 2, bottom: height}[value("getAlignmentBaseline", row)])
            const box = {left, top, right: left + width, bottom: top + height}
            for (const other of boxes) {
              expect(Math.min(box.right, other.right) <= Math.max(box.left, other.left) ||
                Math.min(box.bottom, other.bottom) <= Math.max(box.top, other.top)).toBe(true)
            }
            boxes.push(box)
          }
        }
        return boxes.length
      }
      const dense = await rendered(1)
      expect(dense).toBeGreaterThan(0)
      expect(dense).toBeLessThan(6)
      const hidden = layer.clone({filters: {unknown: false}})
      hidden.state = {tileset}
      hidden.context = layer.context
      expect(hidden.renderLayers().flat(Infinity).filter(item => item?.id.endsWith("-labels"))).toHaveLength(0)
      expect(await rendered(6)).toBe(6)
      expect(await rendered(1)).toBe(dense)
    } finally {
      tileset.finalize()
    }
  })

  it("prioritizes backbone labels using measured font bounds", async () => {
    const layer = new WorldTileLayer({
      id: "measured-labels", maxZoom: 0,
      measureText: () => ({width: 24, height: 12}),
    })
    const viewport = new OrthographicViewport({width: 160, height: 80, target: [256, 256, 0], zoom: 0})
    const tileset = new layer.props.TilesetClass({
      tileSize: 512, extent: layer.props.extent, minZoom: 0, maxZoom: 0,
      getTileData: () => ({...tile(),
        positions: new Float64Array([256, 256, 256, 256, 512, 256]),
        nodes: [
          {id: "sr:a-member.example.test", label: "member.example.test", kind: "device", index: 0, count: 1},
          {id: "sr:z-router.example.test", label: "router.example.test", kind: "device", index: 1, count: 1},
          {id: "boundary", kind: "boundary", index: 2, count: 0},
        ],
        edges: [{id: "physical", index: 0, source: 1, target: 2, topologyClass: "backbone"}],
      }),
    })
    layer.state = {tileset}
    layer.context = {viewport}
    try {
      tileset.update(viewport)
      await vi.waitFor(() => expect(tileset.isLoaded).toBe(true))
      tileset.update(viewport)
      const labels = layer.renderLayers().flat(Infinity).find(item => item?.id.endsWith("-labels"))
      expect(labels).toBeDefined()
      expect(labels.props.data[0].id).toBe("sr:z-router.example.test")
      expect(labels.props.data[0].box.right - labels.props.data[0].box.left).toBe(32)
      expect(labels.props.fontFamily).toBe("Inter, system-ui, sans-serif")
      expect(labels.props.fontWeight).toBe(600)
    } finally {
      tileset.finalize()
    }
  })

  it("prioritizes backbone labels using measured font bounds", async () => {
    const layer = new WorldTileLayer({
      id: "measured-labels", maxZoom: 0,
      measureText: () => ({width: 24, height: 12}),
    })
    const viewport = new OrthographicViewport({width: 160, height: 80, target: [256, 256, 0], zoom: 0})
    const tileset = new layer.props.TilesetClass({
      tileSize: 512, extent: layer.props.extent, minZoom: 0, maxZoom: 0,
      getTileData: () => ({...tile(),
        positions: new Float64Array([256, 256, 256, 256, 512, 256]),
        nodes: [
          {id: "sr:a-member.example.test", label: "member.example.test", kind: "device", index: 0, count: 1},
          {id: "sr:z-router.example.test", label: "router.example.test", kind: "device", index: 1, count: 1},
          {id: "boundary", kind: "boundary", index: 2, count: 0},
        ],
        edges: [{id: "physical", index: 0, source: 1, target: 2, topologyClass: "backbone"}],
      }),
    })
    layer.state = {tileset}
    layer.context = {viewport}
    try {
      tileset.update(viewport)
      await vi.waitFor(() => expect(tileset.isLoaded).toBe(true))
      tileset.update(viewport)
      const labels = layer.renderLayers().flat(Infinity).find(item => item?.id.endsWith("-labels"))
      expect(labels).toBeDefined()
      expect(labels.props.data[0].id).toBe("sr:z-router.example.test")
      expect(labels.props.data[0].box.right - labels.props.data[0].box.left).toBe(32)
      expect(labels.props.fontFamily).toBe("Inter, system-ui, sans-serif")
      expect(labels.props.fontWeight).toBe(600)
    } finally {
      tileset.finalize()
    }
  })

  it("retires cached parents during geometry invalidation while refinement is loading", async () => {
    const layer = new WorldTileLayer({id: "refinement", maxZoom: 16})
    const pending = new Map()
    const tileset = new layer.props.TilesetClass({
      tileSize: layer.props.tileSize, extent: layer.props.extent,
      minZoom: 0, maxZoom: 16, maxRequests: 0, maxCacheSize: 64,
      refinementStrategy: layer.props.refinementStrategy,
      getTileData: ({id}) => new Promise(resolve => pending.set(id, resolve)),
    })
    const viewport = zoom => new OrthographicViewport({width: 512, height: 512, target: [256, 256, 0], zoom})
    const finish = async selected => {
      await vi.waitFor(() => expect(selected.every(item => pending.has(item.id))).toBe(true))
      for (const item of selected) {pending.get(item.id)({byteLength: 1}); pending.delete(item.id)}
      await Promise.all(selected.map(item => item.data))
    }
    try {
      tileset.update(viewport(0))
      await finish(tileset.selectedTiles)
      tileset.update(viewport(0))
      const parents = tileset.tiles.filter(item => item.isVisible)
      expect(parents).toHaveLength(1)
      tileset.update(viewport(1))
      const children = [...tileset.selectedTiles]
      expect(children).toHaveLength(4)
      expect(tileset.tiles.filter(item => item.isVisible)).toEqual(parents)
      // A generation update reloads selected tiles while a cached parent is
      // still providing coverage. Exercise deck.gl's real invalidation path.
      tileset.reloadAll()
      tileset.update(viewport(1))
      expect(tileset.tiles.filter(item => tileset.isTileVisible(item))).toEqual(parents)
      await finish(children)
      tileset.update(viewport(1))
      const visible = tileset.tiles.filter(item => tileset.isTileVisible(item))
      expect(visible.map(item => item.id).sort()).toEqual(children.map(item => item.id).sort())
      expect(visible.length).toBeLessThanOrEqual(64)
      for (const child of children) {
        expect(visible.some(item => item !== child && item.index.z < child.index.z)).toBe(false)
      }
      // Settled reloads must preserve the selected representation as well.
      tileset.reloadAll()
      tileset.update(viewport(1))
      await finish(children)
      tileset.update(viewport(1))
      expect(tileset.tiles.filter(item => tileset.isTileVisible(item)).map(item => item.id).sort())
        .toEqual(children.map(item => item.id).sort())
    } finally {
      for (const resolve of pending.values()) resolve(null)
      tileset.finalize()
    }
  })

  it("toggles both inferred edge passes through the map topology control", () => {
    const renderer = new WorldMapRenderer({}, vi.fn(), vi.fn())
    renderer.cache.manifest = {layout_version: worldTileKey.layout_version, zmax: 16}
    renderer.deck = {setProps: vi.fn()}
    const detailControl = vi.fn()
    renderer.detailHandlers = new Map([["god_view:set_topology_layers", detailControl]])
    const geometry = tile()
    geometry.edges[0].topologyClass = "inferred"
    renderer.render()
    for (const enabled of [null, true, false]) {
      if (enabled !== null) {
        renderer.setSceneControl("god_view:set_topology_layers", {layers: {inferred: enabled}})
        expect(detailControl).toHaveBeenLastCalledWith({layers: {inferred: enabled}})
      }
      const layer = renderer.deck.setProps.mock.lastCall[0].layers[0]
      const passes = layer.renderSubLayers({id: "inferred-tile", data: geometry}).filter(Boolean)
      const edges = passes.filter(item => /-edges$|-edge-mantle$/.test(item.id))
      expect(edges).toHaveLength(2)
      for (const edge of edges) {
        expect(edge.props.getWidth(null, {index: 0}) > 0).toBe(enabled === true)
        expect(edge.props.getColor(null, {index: 0})[3] > 0).toBe(enabled === true)
      }
      expect(passes.some(item => item.id.endsWith("-packets"))).toBe(false)
    }
  })

  it("coarsens a large orthographic viewport without omitting any of its coverage", () => {
    const layer = new WorldTileLayer({id: "coverage", maxZoom: 16})
    const tileset = new layer.props.TilesetClass({tileSize: 512, extent: [0, 0, 512, 512]})
    const viewport = new OrthographicViewport({width: 10000, height: 10000, target: [256, 256, 0], zoom: 8})
    const indices = tileset.getTileIndices({viewport, maxZoom: 16, minZoom: 0})
    expect(indices.length).toBeGreaterThan(0)
    expect(indices.length).toBeLessThanOrEqual(64)
    expect(new Set(indices.map(index => index.z)).size).toBe(1)
    const z = indices[0].z
    const width = 512 / 2 ** z
    const requested = new Set(indices.map(index => `${index.x}/${index.y}`))
    // The viewport covers [236.46875, 275.53125] on both world axes.
    for (let x = Math.floor(236.46875 / width); x <= Math.floor(275.53125 / width); x += 1) {
      for (let y = Math.floor(236.46875 / width); y <= Math.floor(275.53125 / width); y += 1) {
        expect(requested.has(`${x}/${y}`)).toBe(true)
      }
    }
  })

  it("reuses geometry attributes across health refreshes and animates only complete measured flow", () => {
    const geometry = tile()
    const firstOverlay = overlay(geometry)
    const first = layers(geometry, firstOverlay)
    const changed = {...firstOverlay, health: {glyphs: [{id: geometry.nodes[0].id, counts: {total: 70000, unavailable: 1, unknown: 0}}]}}
    const next = layers(geometry, changed)
    const nodeLayer = list => list.find(layer => layer.id.endsWith("-nodes"))
    expect(nodeLayer(next).props.data).toBe(nodeLayer(first).props.data)
    expect(nodeLayer(first).props.getFillColor(null, {index: 0})).toEqual([65, 195, 156, 240])
    expect(nodeLayer(next).props.getFillColor(null, {index: 0})).toEqual([245, 117, 88, 240])
    expect(nodeLayer(next).props.data.length).toBe(1) // The boundary endpoint is not a pickable device.
    const packets = first.find(layer => layer.id.endsWith("-packets"))
    expect(packets.props.data.length).toBe(1)
    expect(Array.from(packets.props.data.attributes.instancePhase)).toEqual([0.25, 0.75])
    expect(Array.from(packets.props.data.attributes.instanceEndpoints)).toEqual([256, 0, 512, 256])
    const incomplete = overlay(geometry)
    incomplete.flow.edges[0].selected_relations = 89999
    expect(layers(geometry, incomplete).some(layer => layer.id.endsWith("-packets"))).toBe(false)
    expect(layers(geometry, {...firstOverlay, generation: 2}).some(layer => layer.id.endsWith("-packets"))).toBe(false)
  })

  it("draws a last-known link without packet flow", () => {
    const geometry = tile()
    geometry.edges[0].stale = true
    const drawn = layers(geometry, overlay(geometry))
    expect(drawn.some(layer => layer.id.endsWith("-packets"))).toBe(false)
    const color = drawn.find(layer => layer.id.endsWith("-edges")).props.getColor(null, {index: 0})
    expect(color.slice(0, 3)).toEqual([148, 163, 184])
    expect(color[3]).toBeGreaterThan(0)
    geometry.edges[0].topologyClass = "inferred"
    const hidden = layers(geometry, overlay(geometry)).filter(item => /-edges$|-edge-mantle$/.test(item.id))
    for (const layer of hidden) expect(layer.props.getColor(null, {index: 0})[3]).toBe(0)
  })

  it("forwards publication time, camera tier, and source counts", async () => {
    vi.useFakeTimers()
    const domNode = () => ({style: {}, append() {}, replaceChildren() {}, setAttribute() {}, addEventListener() {}})
    vi.stubGlobal("document", {createElement: domNode})
    vi.stubGlobal("window", {location: {pathname: "/topology"}, addEventListener() {}, removeEventListener() {}})
    vi.stubGlobal("ResizeObserver", class {observe() {} disconnect() {}})
    vi.spyOn(Deck.prototype, "_createDevice").mockReturnValue(new Promise(() => {}))
    vi.spyOn(Deck.prototype, "_createAnimationLoop").mockReturnValue({start() {}, stop() {}, destroy() {}, setProps() {}})
    const handlers = new Map()
    const pushEvent = vi.fn()
    const renderer = new WorldMapRenderer({...domNode(), clientWidth: 800, clientHeight: 600}, pushEvent, (name, callback) => handlers.set(name, callback))
    vi.spyOn(renderer, "poll").mockResolvedValue()
    const visible = [{index: {z: 1, x: 0, y: 0}, content: {nodes: [{}, {}], edges: [{}], byteLength: 32}}]
    const titles = []
    const notes = []
    let responseBody = null
    vi.stubGlobal("fetch", () => responseBody
      ? Promise.resolve({ok: true, headers: {get() { return null }}, arrayBuffer: async () => responseBody, body: null})
      : Promise.reject(new Error("stopped")))
    try {
      await renderer.mount()
      renderer.scheduleLocationUpdate = () => {}
      renderer.cache = {
        manifest: {
          layout_version: worldTileKey.layout_version, generation: 4, zmax: 16, node_count: 12, relation_count: 9,
          generated_at: "2026-03-01T00:00:00Z",
          pipeline_stats: {raw_links: 4, edge_class_observed: 0, note: "unmeasured"},
        },
        setVisible() {}, prefetch() {},
      }
      renderer.overlays = {setVisible() {}, poll() {}}
      renderer.scheduleWatch = () => {}
      renderer.status = () => {}
      renderer.render = () => {}
      renderer.deviceType = "webgpu"
      renderer.viewportLoaded(visible)
      const payload = pushEvent.mock.calls.at(-1)[1]
      expect(payload.generated_at).toBe("2026-03-01T00:00:00Z")
      expect(payload.zoom_mode).toBe("auto")
      expect(payload.zoom_tier).toBe("global")
      expect(payload.pipeline_stats).toEqual({raw_links: 4, edge_class_observed: 0})
      expect(payload.rendered_node_count).toBe(2)
      expect(payload.pipeline_stats.rendered_node_count).toBeUndefined()
      const select = mode => {
        handlers.get("god_view:set_zoom_mode")({mode})
        renderer.viewportLoaded(visible)
        return pushEvent.mock.calls.at(-1)[1]
      }
      expect(select("global")).toMatchObject({zoom_mode: "global", zoom_tier: "global"})
      expect(renderer.viewState.zoom).toBe(0)
      expect(select("regional")).toMatchObject({zoom_mode: "regional", zoom_tier: "regional"})
      expect(renderer.viewState.zoom).toBe(4)
      expect(select("local")).toMatchObject({zoom_mode: "local", zoom_tier: "local"})
      expect(renderer.viewState.zoom).toBe(10)
      renderer.viewState.zoom = 3
      renderer.viewportLoaded(visible)
      expect(pushEvent.mock.calls.at(-1)[1]).toMatchObject({zoom_mode: "local", zoom_tier: "regional"})
      renderer.viewState.zoom = 8
      renderer.viewportLoaded(visible)
      expect(pushEvent.mock.calls.at(-1)[1]).toMatchObject({zoom_mode: "local", zoom_tier: "local"})
      renderer.openPanel = node => {
        titles.push(node.textContent)
        notes.length = 0
        renderer.panel = {append(child) { notes.push(child.textContent) }}
      }
      await renderer.showSelection({kind: "edge", count: 3, stale: true, lastSeen: "2020-01-01T00:00:00Z"}, {layout_version: "layout", generation: "1", kind: "edge", id: "stale-ac"})
      expect(titles.at(-1)).toBe("3 relations · last known · 2020-01-01T00:00:00Z")
      await renderer.showSelection({kind: "edge", count: 3, stale: true}, {layout_version: "layout", generation: "1", kind: "edge", id: "stale-ac"})
      expect(titles.at(-1)).toBe("3 relations · last known")
      await renderer.showSelection({kind: "device", label: "access", id: "sr:access"}, {layout_version: "layout", generation: "1", kind: "device", id: "sr:access"})
      expect(titles.at(-1)).toBe("access")
      const json = value => {
        const bytes = new TextEncoder().encode(JSON.stringify(value))
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
      }
      responseBody = json({details: {relation: {stale: true, last_seen: "2020-01-01T00:00:00Z"}, device: {label: "access"}}})
      await renderer.showSelection({kind: "device", label: "access", id: "sr:access"}, {layout_version: "layout", generation: "1", kind: "device", id: "sr:access"})
      expect(notes).toEqual(["access", "last known · 2020-01-01T00:00:00Z", "Open neighborhood", "Share device"])
      responseBody = json({details: {relation: {last_seen: "2024-02-01T00:00:00Z"}, device: {label: "fresh"}}})
      await renderer.showSelection({kind: "device", label: "fresh", id: "sr:fresh"}, {layout_version: "layout", generation: "1", kind: "device", id: "sr:fresh"})
      expect(notes).toEqual(["fresh", "2024-02-01T00:00:00Z", "Open neighborhood", "Share device"])
      responseBody = json({details: {relation: {}, device: {label: "current"}}})
      await renderer.showSelection({kind: "device", label: "current", id: "sr:current"}, {layout_version: "layout", generation: "1", kind: "device", id: "sr:current"})
      expect(notes).toEqual(["current", "Open neighborhood", "Share device"])
    } finally {
      clearInterval(renderer.timer)
      vi.useRealTimers()
      vi.unstubAllGlobals()
      vi.restoreAllMocks()
    }
  })

  it("keeps graph classification stable when telemetry pages change or disappear", () => {
    const geometry = tile()
    const telemetry = overlay(geometry)
    telemetry.flow.edges[0].topology_class_counts = {backbone: 90000}
    const edgeLayer = () => layers(geometry, telemetry).find(layer => layer.id.endsWith("-edges"))
    expect(edgeLayer().props.getWidth(null, {index: 0})).toBe(1.5)
    geometry.edges[0].topologyClass = "endpoints"
    expect(edgeLayer().props.getWidth(null, {index: 0})).toBe(1.5 * 0.74)
    geometry.edges[0].topologyClass = "inferred"
    expect(edgeLayer().props.getWidth(null, {index: 0})).toBe(0)
    for (const layer of layers(geometry, telemetry).filter(item => /-edges$|-edge-mantle$/.test(item.id))) {
      expect(layer.props.getColor(null, {index: 0})[3]).toBe(0)
    }
    telemetry.flow.edges[0].selected_relations = 1
    telemetry.flow.edges[0].topology_class_counts = {backbone: 1}
    expect(edgeLayer().props.getWidth(null, {index: 0})).toBe(0)
    const unavailable = layers(geometry, null).find(layer => layer.id.endsWith("-edges"))
    expect(unavailable.props.getWidth(null, {index: 0})).toBe(0)
  })

  it("keeps canonical packet seeds across tile segments despite local row reordering", () => {
    const geometry = tile()
    const first = layers(geometry, overlay(geometry)).find(layer => layer.id.endsWith("-packets")).props.data
    const other = {...tile(), edges: [{...geometry.edges[0], start: 0.75, end: 1}]}
    // An unmeasured edge preceding the clipped edge must not change its phase seed.
    other.edges.unshift({...other.edges[0], id: "invented-unmeasured-relation", index: 1})
    const second = layers(other, overlay(geometry)).find(layer => layer.id.endsWith("-packets")).props.data
    expect(second.attributes.instanceShape[3]).toBe(first.attributes.instanceShape[3])
    expect(Array.from(second.attributes.instancePhase)).toEqual([0.75, 1])
  })

  it.each([
    {status: "partial", animate: true, observed_packets_per_second: 17, packets_per_second: null},
    {status: "unknown", animate: true, packets_per_second: null, octets_per_second: 250},
    {status: "partial", animate: true, observed_octets_per_second: 250, octets_per_second: null},
  ])("renders directional measured traffic without requiring a complete packet total: %j", direction => {
    const geometry = tile()
    const telemetry = overlay(geometry)
    telemetry.flow.edges[0].forward = direction
    const packets = layers(geometry, telemetry).find(layer => layer.id.endsWith("-packets"))
    expect(packets?.props.data.length).toBe(1)
    expect(Array.from(packets.props.data.attributes.instanceFlow).slice(1, 3)).toEqual([1, 0])

    const stopped = overlay(geometry)
    stopped.flow.edges[0].forward = {...direction, animate: false}
    expect(layers(geometry, stopped).some(layer => layer.id.endsWith("-packets"))).toBe(false)
  })
})
