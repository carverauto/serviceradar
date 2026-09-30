import {describe, expect, it} from "vitest"
import {OrthographicViewport} from "@deck.gl/core"
import WorldTileLayer from "./world_tile_layer"
import {decodeWorldTile} from "./world_tile_decode"
import {worldTileIpc, worldTileKey, worldTileRevision} from "./fixtures/world_tile_ipc"

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
